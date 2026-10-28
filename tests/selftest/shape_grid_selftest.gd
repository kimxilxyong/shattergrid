extends "res://tests/selftest/selftest.gd"
## The grid must return exactly the same results as scanning every Shape, including after moving
## and removing them. `_coalesce` must not merge distant boxes: that blind merge turned two debris
## piles at opposite ends of the map into a 250 m region.


func _shape(parent: Node3D, position: Vector3, size: Vector3i) -> VoxelShape3D:
	var body := VoxelBody3D.new()
	parent.add_child(body)
	body.position = position
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	cells.fill(1)
	shape.data.set_cells(size, cells)
	shape.palette = VoxelPalette.new()
	body.add_voxel_shape(shape)
	return shape


func _brute(shapes: Array, region: AABB) -> Array:
	var result := []
	for shape: VoxelShape3D in shapes:
		if shape.voxel_count() > 0 and shape.world_bounds().intersects(region):
			result.append(shape.get_instance_id())
	result.sort()
	return result


func _ids(shapes: Array) -> Array:
	var result := []
	for shape: VoxelShape3D in shapes:
		result.append(shape.get_instance_id())
	result.sort()
	return result


func _run() -> void:
	print("Shape grid")
	var level := Node3D.new()
	root.add_child(level)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var shapes: Array[VoxelShape3D] = []
	# Mix of sizes, including one that exceeds the cell limit and goes into the overflow list.
	for _i in 60:
		shapes.append(_shape(level, Vector3(
			rng.randf_range(-60.0, 60.0), rng.randf_range(-10.0, 10.0), rng.randf_range(-60.0, 60.0)
		), Vector3i(rng.randi_range(2, 40), rng.randi_range(2, 40), rng.randi_range(2, 40))))
	shapes.append(_shape(level, Vector3.ZERO, Vector3i(300, 60, 300)))
	await physics_frame

	var grid := VoxelShapeGrid.new()
	for shape in shapes:
		grid.insert(shape, shape.world_bounds())
	_check(grid.size() == shapes.size(), "all Shapes are inserted")

	var mismatches := 0
	for _consulta in 300:
		var center := Vector3(
			rng.randf_range(-70.0, 70.0), rng.randf_range(-15.0, 15.0), rng.randf_range(-70.0, 70.0)
		)
		var side := rng.randf_range(0.5, 30.0)
		var region := AABB(center - Vector3.ONE * side * 0.5, Vector3.ONE * side)
		if _ids(grid.query(region)) != _brute(shapes, region):
			mismatches += 1
	_check(mismatches == 0, "300 queries match the full scan (%d mismatches)" % mismatches)

	# Moving: reinsertion must leave the grid as if it had been rebuilt from scratch.
	for index in range(0, shapes.size(), 3):
		shapes[index].get_parent().position += Vector3(
			rng.randf_range(-40.0, 40.0), 0.0, rng.randf_range(-40.0, 40.0)
		)
	await physics_frame
	for index in range(0, shapes.size(), 3):
		grid.insert(shapes[index], shapes[index].world_bounds())
	mismatches = 0
	for _consulta in 300:
		var center := Vector3(
			rng.randf_range(-90.0, 90.0), rng.randf_range(-15.0, 15.0), rng.randf_range(-90.0, 90.0)
		)
		var region := AABB(center - Vector3.ONE * 8.0, Vector3.ONE * 16.0)
		if _ids(grid.query(region)) != _brute(shapes, region):
			mismatches += 1
	_check(mismatches == 0, "300 queries after moving one third match (%d mismatches)" % mismatches)

	# Removal: the gap must not remain in any bucket.
	var doomed := shapes[7]
	grid.remove_id(doomed.get_instance_id())
	_check(not grid.has_id(doomed.get_instance_id()), "a deleted Shape is removed from the grid")
	var still := grid.query(doomed.world_bounds())
	_check(not _ids(still).has(doomed.get_instance_id()),
		"and a query for its own box does not return it")

	# A Node can be freed before the periodic shadow sweep. The grid must be able to detect and
	# remove the dead Variant without first trying to cast it to VoxelShape3D.
	var stale := shapes[8]
	var stale_id := stale.get_instance_id()
	var stale_bounds := stale.world_bounds()
	(stale.get_parent().get_parent() as VoxelBody3D).free()
	var after_unexpected_free := grid.query(stale_bounds)
	_check(not _ids(after_unexpected_free).has(stale_id),
		"an unexpectedly freed reference is removed from the query")
	grid.remove_id(stale_id)
	_check(not grid.has_id(stale_id), "a freed reference can be removed by ID")

	# `_coalesce`: merge touching items, not distant ones.
	var clipmaps := VoxelShadowClipmaps.new()
	var juntas: Array[AABB] = [
		AABB(Vector3.ZERO, Vector3.ONE), AABB(Vector3(0.5, 0.5, 0.5), Vector3.ONE)
	]
	var lejanas: Array[AABB] = [
		AABB(Vector3.ZERO, Vector3.ONE), AABB(Vector3(200.0, 0.0, 200.0), Vector3.ONE)
	]
	_check((clipmaps.call("_coalesce", juntas) as Array).size() == 1,
		"two overlapping boxes are merged into one")
	var separadas: Array = clipmaps.call("_coalesce", lejanas)
	_check(separadas.size() == 2, "two boxes 200 m apart remain in separate regions")
	clipmaps.free()

	if failures == 0:
		print("VOXEL_SHAPE_GRID_SELFTEST_OK")
	else:
		printerr("VOXEL_SHAPE_GRID_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
