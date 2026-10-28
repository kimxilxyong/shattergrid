extends "res://tests/selftest/selftest.gd"
## Unified grab regression: whether an object can be grabbed is determined by the dynamic state of the
## VoxelBody, not by whether the collider has a door label.


func _make_body(
	world: VoxelWorld3D, position: Vector3, state: VoxelBody3D.State, density := 120.0
) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.state = state
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(6, 6, 6)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.SADDLE_BROWN, "hardness": 2.0, "density": density,
	})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, position)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _run() -> void:
	print("grabbing doors, props, and debris")
	var level := Node3D.new()
	root.add_child(level)
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	level.add_child(world)

	var hud := CanvasLayer.new()
	hud.name = "HUD"
	level.add_child(hud)
	var interaction := Label.new()
	interaction.name = "Interaction"
	hud.add_child(interaction)

	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load("res://scripts/core/player.gd"))
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position.y = 1.0
	camera.current = true
	player.add_child(camera)
	level.add_child(player)
	player._gravity = 0.0

	var wall := _make_body(world, Vector3(0, 1.0, -2.0), VoxelBody3D.State.STATIC)
	for _frame in 3:
		await physics_frame
	_check(player._pick_grabbable().is_empty(),
		"a STATIC wall under the reticle does not become dynamic when clicked")
	wall.position.x = 2.0

	var crate := _make_body(world, Vector3(0, 1.0, -2.0), VoxelBody3D.State.DYNAMIC)
	crate.sleep()
	for _frame in 4:
		await physics_frame
	var pick: Dictionary = player._pick_grabbable()
	_check(not pick.is_empty() and pick.voxel_body == crate,
		"a `<body dynamic=\"true\">` box is selectable without door metadata")
	player._begin_grab()
	var rigid := crate.get_physics_body() as RigidBody3D
	_check(crate.has_physics_hold(player._grab_hold_key),
		"the player retains the Body so the budget does not retire it while held")
	_check(crate.is_awake() and not rigid.can_sleep,
		"grabbing wakes the box and prevents it from sleeping mid-drag")
	player._update_grab_line()
	var line := hud.get_node_or_null("GrabLine") as Line2D
	_check(line != null and line.visible and line.points.size() == 2,
		"the HUD draws a line between the screen center and the grabbed point")
	var old_owner := crate
	var held_shape := crate.get_shapes()[0] as VoxelShape3D
	var heir := VoxelBody3D.new()
	heir.state = VoxelBody3D.State.DYNAMIC
	world.add_child(heir)
	old_owner.release_voxel_shape(held_shape)
	old_owner.rebuild_dynamic_collision()
	heir.add_voxel_shape(held_shape, true, false)
	heir.rebuild_dynamic_collision()
	world.register_body(heir)
	world.body_split.emit(old_owner, [heir] as Array[VoxelBody3D])
	player._apply_grab_force(1.0 / 60.0)
	_check(player._grabbed_voxel_body == heir \
			and not old_owner.has_physics_hold(player._grab_hold_key) \
			and heir.has_physics_hold(player._grab_hold_key),
		"the grabbed point and its hold follow the Shape when its Body changes")
	world.unregister_body(old_owner)
	old_owner.queue_free()
	crate = heir
	rigid = heir.get_physics_body() as RigidBody3D

	var before_x := crate.get_shapes()[0].world_bounds().get_center().x
	player.position.x = 0.75
	for _frame in 30:
		await physics_frame
	var after_x := crate.get_shapes()[0].world_bounds().get_center().x
	_check(after_x > before_x + 0.05,
		"the spring applies force in Jolt without teleporting the prop")
	player._end_grab()
	_check(not crate.has_physics_hold(player._grab_hold_key) and rigid.can_sleep,
		"releasing drops the hold and restores sleeping")

	# Destruction debris uses the same State.DYNAMIC. The name is irrelevant to the decision; also
	# verify that a dynamic body removed by the budget can be reactivated.
	crate.retire_to_static()
	var crate_center := crate.get_shapes()[0].world_bounds().get_center()
	camera.look_at(crate_center)
	for _frame in 3:
		await physics_frame
	player._begin_grab()
	_check(crate.state == VoxelBody3D.State.DYNAMIC and player._grabbed_shape != null,
		"a RETIRED_STATIC prop/debris returns to Jolt when grabbed")
	player._end_grab()

	var light_limit: float = player.grab_force_limit_for_mass(20.0)
	var heavy_limit: float = player.grab_force_limit_for_mass(500.0)
	_check(light_limit / 20.0 > heavy_limit / 500.0 * 4.0,
		"absolute force makes a 500 kg object accelerate much less than a 20 kg object")
	_check(player.grab_movement_scale_for_mass(500.0) \
			< player.grab_movement_scale_for_mass(20.0),
		"the player walks more slowly while dragging a heavy load")

	if failures == 0:
		print("VOXEL_GRAB_SYSTEM_SELFTEST_OK")
	else:
		printerr("VOXEL_GRAB_SYSTEM_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
