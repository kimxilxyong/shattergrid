extends "res://tests/selftest/selftest.gd"
## The fragment does not enter the solver until the source's static collision reflects the cut.


func _run() -> void:
	print("collision handoff and coherence")
	var world := make_world()
	var body := VoxelBody3D.new()
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(26, 2, 2)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.GRAY, "hardness": 1.0, "density": 1000.0,
	})
	shape.anchored = true
	shape.anchor_indices = PackedInt32Array([0])
	body.add_voxel_shape(shape)
	world.register_body(body)
	for _frame in 3:
		await physics_frame

	# x=12 is the neck; even after removing several layers, the right side exceeds the cosmetic limit.
	var result := world.damage_sphere(shape.voxel_center_world(12), 0.25, 100.0)
	var created: Array = result[0].new_bodies if not result.is_empty() else []
	_check(created.size() == 1, "the cut creates a structural fragment")
	if created.is_empty():
		quit(1)
		return
	var fragment := created[0] as VoxelBody3D
	var rigid := fragment.get_physics_body() as RigidBody3D
	_check(fragment.collision_handoff_pending and rigid.freeze,
		"the fragment spawns frozen while old collision exists")
	_check(rigid.collision_layer == 0 and rigid.collision_mask == 0,
		"it cannot collide with its own static voxels")
	_check(world.get_physics_coherence_snapshot().status == "PENDING",
		"the mismatch with queued work is reported as PENDING")
	var initial_y := fragment.get_shapes()[0].world_bounds().get_center().y

	for _frame in 20:
		await physics_frame
		world._process(1.0 / 60.0)
	_check(not fragment.collision_handoff_pending and not rigid.freeze,
		"it activates after draining and waiting one physics tick")
	_check(rigid.collision_layer != 0 and rigid.collision_mask != 0,
		"it restores its original collision filters")
	_check(world.get_physics_coherence_snapshot().status == "COHERENT",
		"the physics revision catches up to the voxel revision")
	var final_y := fragment.get_shapes()[0].world_bounds().get_center().y
	_check(final_y <= initial_y + 0.05,
		"it receives no upward bounce from ghost collision")

	# The full STATIC -> DYNAMIC transition (intact towers and posts falling) replaces the StaticBody.
	# It must also wait for the old node to leave the physics server.
	var transition_body := VoxelBody3D.new()
	world.add_child(transition_body)
	var transition_shape := VoxelShape3D.new()
	transition_shape.data = VoxelShapeData.new()
	var transition_cells := PackedByteArray()
	transition_cells.resize(4 * 12 * 4)
	transition_cells.fill(1)
	transition_shape.data.set_cells(Vector3i(4, 12, 4), transition_cells)
	transition_shape.palette = shape.palette
	transition_shape.position = Vector3(4.0, 3.0, 0.0)
	transition_body.add_voxel_shape(transition_shape)
	world.register_body(transition_body)
	await physics_frame
	transition_body.make_dynamic(16)
	var transition_rigid := transition_body.get_physics_body() as RigidBody3D
	_check(transition_body.collision_handoff_pending and transition_rigid.freeze \
		and transition_rigid.collision_layer == 0 and transition_rigid.collision_mask == 0,
		"a whole tower does not overlap its old StaticBody for even one frame")
	_check(transition_rigid.continuous_cd,
		"the falling tower uses CCD so it does not pass through a thin post or support")
	for _frame in 4:
		await physics_frame
	_check(not transition_body.collision_handoff_pending and not transition_rigid.freeze \
		and transition_rigid.collision_layer != 0 and transition_rigid.collision_mask != 0,
		"the full transition activates after a safe physics tick")

	# If a fragment is absorbed or removed before completion, cancelling its ticket must not
	# reactivate ghost collision during the frame in which the node awaits `queue_free`.
	var cancelled := VoxelBody3D.new()
	world.add_child(cancelled)
	var cancelled_shape := VoxelShape3D.new()
	cancelled_shape.data = VoxelShapeData.new()
	var cancelled_cells := PackedByteArray()
	cancelled_cells.resize(8)
	cancelled_cells.fill(1)
	cancelled_shape.data.set_cells(Vector3i(2, 2, 2), cancelled_cells)
	cancelled_shape.palette = shape.palette
	cancelled.add_voxel_shape(cancelled_shape)
	world.register_body(cancelled)
	cancelled.make_dynamic(4)
	var cancelled_rigid := cancelled.get_physics_body() as RigidBody3D
	world.unregister_body(cancelled)
	_check(not cancelled.collision_handoff_pending and cancelled_rigid.freeze \
		and cancelled_rigid.collision_layer == 0 and cancelled_rigid.collision_mask == 0,
		"cancelling a retired handoff does not revive its ghost collider")
	cancelled.queue_free()

	# A direct write to the Resource does not emit the wrapper's signal; it must be detected immediately.
	var direct_changed := shape.data.set_cell(0, 0, 0, 0)
	var desync := world.get_physics_coherence_snapshot()
	_check(direct_changed and desync.status == "DESYNC" \
		and desync.consumer == "voxel_change_signal",
		"a mutation that bypasses the wrapper is diagnosed as DESYNC")
	# Querying the snapshot schedules the full repair for later; the test does not call the wrapper
	# or rebuild collision manually.
	for _frame in 6:
		await process_frame
		await physics_frame
		world._process(1.0 / 60.0)
	_check(world.get_physics_coherence_snapshot().status == "COHERENT",
		"automatic recovery returns to COHERENT")

	if failures == 0:
		print("VOXEL_COLLISION_HANDOFF_SELFTEST_OK")
	else:
		printerr("VOXEL_COLLISION_HANDOFF_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
