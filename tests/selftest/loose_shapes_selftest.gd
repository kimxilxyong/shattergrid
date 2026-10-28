extends "res://tests/selftest/selftest.gd"
## A Teardown `<body dynamic>` can contain several Shapes in one rigid body. If a shot removes the
## middle one, the end sections no longer touch and must split into separate bodies. Otherwise they
## remain welded together, floating in formation with a gap between them.


func _add_section(body: VoxelBody3D, origin: Vector3) -> VoxelShape3D:
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(10, 4, 4)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 0.4, "density": 400.0})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, origin)
	body.add_voxel_shape(shape)
	return shape


func _run() -> void:
	print("bodies with multiple Shapes")
	var world := make_world()

	# Three connected pipe sections in one rigid body, as imported from the map.
	var pipe := VoxelBody3D.new()
	pipe.state = VoxelBody3D.State.DYNAMIC
	world.add_child(pipe)
	_add_section(pipe, Vector3(0.0, 8.0, 0.0))
	var middle := _add_section(pipe, Vector3(1.0, 8.0, 0.0))
	_add_section(pipe, Vector3(2.0, 8.0, 0.0))
	world.register_body(pipe)
	for _frame in 5:
		await physics_frame
	_check(pipe.get_shapes().size() == 3, "the body starts with three sections")
	_check(world.get_dynamic_bodies().size() == 1, "and a single rigid body")

	# Destroy the middle section: the ends no longer touch.
	var center := middle.world_bounds().get_center()
	world.damage_sphere(center, 1.2, 60.0)
	for _frame in 10:
		await physics_frame
		world._process(1.0 / 60.0)
	print("  middle section: %d voxels remaining" % (
		middle.voxel_count() if is_instance_valid(middle) else 0
	))
	var bodies := world.get_dynamic_bodies().size()
	print("  dynamic bodies after the cut: %d" % bodies)
	_check(bodies >= 2, "sections that no longer touch split into separate bodies")

	# Each body must now fall independently, not in formation.
	var heights: Array[float] = []
	for body: VoxelBody3D in world.get_dynamic_bodies():
		var shapes := body.get_shapes()
		if not shapes.is_empty():
			heights.append(shapes[0].world_bounds().get_center().y)
	for _frame in 60:
		await physics_frame
	var moved := 0
	var index := 0
	for body: VoxelBody3D in world.get_dynamic_bodies():
		var shapes := body.get_shapes()
		if shapes.is_empty() or index >= heights.size():
			continue
		if heights[index] - shapes[0].world_bounds().get_center().y > 0.5:
			moved += 1
		index += 1
	print("  bodies that fell: %d of %d" % [moved, heights.size()])
	_check(moved >= 2, "and they fall instead of remaining suspended")

	# Conversely, two Shapes in the same body that NEVER touched were welded together by the map
	# author. Breaking voxels in one must not separate them because there was nothing between them
	# to break.
	var welded := VoxelBody3D.new()
	welded.state = VoxelBody3D.State.DYNAMIC
	world.add_child(welded)
	var left := _add_section(welded, Vector3(20.0, 8.0, 0.0))
	var right := _add_section(welded, Vector3(24.0, 8.0, 0.0))
	world.register_body(welded)
	for _frame in 5:
		await physics_frame
	world.damage_sphere(left.world_bounds().position + Vector3(0.05, 0.05, 0.05), 0.2, 60.0)
	for _frame in 5:
		await physics_frame
		world._process(1.0 / 60.0)
	_check(world._body_of(left) == world._body_of(right),
		"parts that never touched do not split when hit")

	# Lee's case: the same three-section body, but with a hanging joint. The constraint's hold
	# prevented a split, leaving half a post floating and "connected" by the RigidBody to the half
	# held by the joint.
	var jointed := VoxelBody3D.new()
	jointed.state = VoxelBody3D.State.DYNAMIC
	world.add_child(jointed)
	_add_section(jointed, Vector3(40.0, 8.0, 0.0))
	var jointed_middle := _add_section(jointed, Vector3(41.0, 8.0, 0.0))
	_add_section(jointed, Vector3(42.0, 8.0, 0.0))
	world.register_body(jointed)
	jointed.acquire_physics_hold("joint:test")
	for _frame in 5:
		await physics_frame
	var before := world.get_dynamic_bodies().size()
	world.damage_sphere(jointed_middle.world_bounds().get_center(), 1.2, 60.0)
	for _frame in 10:
		await physics_frame
		world._process(1.0 / 60.0)
	var after := world.get_dynamic_bodies().size()
	print("  with joint: bodies %d -> %d" % [before, after])
	_check(after > before, "a joint does not prevent sections that no longer touch from splitting")

	if failures == 0:
		print("VOXEL_LOOSE_SHAPES_SELFTEST_OK")
	else:
		printerr("VOXEL_LOOSE_SHAPES_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
