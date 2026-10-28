extends "res://tests/selftest/selftest.gd"
## A Body with no voxels must not retain mass, a compound shape, or references in the World.


func _run() -> void:
	print("empty physics Body cleanup")
	var world := make_world(false)
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.DYNAMIC
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(2 * 2 * 2)
	cells.fill(1)
	shape.data.set_cells(Vector3i(2, 2, 2), cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.GRAY, "hardness": 1.0, "density": 1000.0,
	})
	body.add_voxel_shape(shape)
	world.register_body(body)
	_check(body.compound_boxes > 0 and body.get_total_voxels() == 8,
		"the fixture starts as a real physics Body")
	var affected := world.damage_sphere(shape.world_bounds().get_center(), 1.0, 100.0)
	_check(not affected.is_empty(), "the impact empties the dynamic Shape")
	_check(not world.get_dynamic_bodies().has(body),
		"the transaction unregisters the empty Body immediately")
	await process_frame
	_check(not is_instance_valid(body),
		"the node with the old mass and compound is removed from the tree")

	# Defensive guard: future code might accidentally register an already-empty Body. Metrics
	# updates must repair it without counting it as active physics.
	var stale := VoxelBody3D.new()
	stale.state = VoxelBody3D.State.DYNAMIC
	world.add_child(stale)
	var empty_shape := VoxelShape3D.new()
	empty_shape.data = VoxelShapeData.new()
	empty_shape.data.set_cells(Vector3i(1, 1, 1), PackedByteArray([0]))
	empty_shape.palette = VoxelPalette.new()
	stale.add_voxel_shape(empty_shape)
	world.register_body(stale)
	world._update_metrics()
	_check(not world.get_dynamic_bodies().has(stale),
		"the metrics barrier also removes an injected ghost")

	if failures == 0:
		print("VOXEL_EMPTY_BODY_CLEANUP_SELFTEST_OK")
	else:
		printerr("VOXEL_EMPTY_BODY_CLEANUP_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
