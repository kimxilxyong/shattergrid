extends "res://tests/selftest/selftest.gd"
## A fast structural post must not pass through a thin plate/support between physics ticks.


func _run() -> void:
	print("CCD for posts and structural fragments")
	make_box_body(root, Vector3(8.0, 0.04, 8.0))

	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_impact_damage_enabled = false
	root.add_child(world)
	var body := VoxelBody3D.new()
	body.position = Vector3(0.0, 3.0, 0.0)
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(2 * 20 * 2)
	cells.fill(1)
	shape.data.set_cells(Vector3i(2, 20, 2), cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.GRAY, "hardness": 1.0, "density": 7800.0,
	})
	body.add_voxel_shape(shape)
	world.register_body(body)
	body.make_dynamic(16)
	var rigid := body.get_physics_body() as RigidBody3D
	for _frame in 8:
		await process_frame
		await physics_frame
		if not body.collision_handoff_pending:
			break
	_check(not body.collision_handoff_pending and rigid.continuous_cd,
		"the post enters the solver with CCD active after the handoff")
	rigid.linear_velocity = Vector3(0.0, -80.0, 0.0)
	rigid.sleeping = false
	var minimum_y := rigid.global_position.y
	for _frame in 10:
		await physics_frame
		minimum_y = minf(minimum_y, rigid.global_position.y)
	print("  minimum post center: %.3f m" % minimum_y)
	_check(minimum_y > 0.8,
		"a post moving at 80 m/s does not pass through a 4 cm support")
	_check(rigid.global_position.y > 0.8,
		"the post remains on the correct side of the support")

	if failures == 0:
		print("VOXEL_STRUCTURAL_CCD_SELFTEST_OK")
	else:
		printerr("VOXEL_STRUCTURAL_CCD_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
