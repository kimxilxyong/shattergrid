extends "res://tests/selftest/selftest.gd"
## Like `vehicle_extract_probe.gd`, but through the complete flow: a dynamic Shape -> VoxelBody3D
## registered in a real VoxelWorld3D, falling under gravity. This is what `--teardown-vehicles` in
## main.gd does for physics tests.
var VOX_DIR := VoxelProjectPaths.teardown_vox_dir()


func _run() -> void:
	print("vehicles extracted from the map as test bodies")
	var world := make_world()

	var floor_shape := VoxelShape3D.new()
	floor_shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(60, 4, 60)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	floor_shape.data.set_cells(dimensions, cells)
	floor_shape.palette = VoxelPalette.new()
	floor_shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 1000000.0, "density": 2700.0})
	floor_shape.anchored = false
	var ground := VoxelBody3D.new()
	world.add_child(ground)
	ground.add_voxel_shape(floor_shape)
	world.register_body(ground)

	var vehicles := [
		["small car", "palette22.vox", "shape473", 1.5],
		["suv", "palette24.vox", "shape500", 2.0],
		["muscle car", "palette25.vox", "shape527", 2.0],
	]
	var bodies: Array[VoxelBody3D] = []
	var offset := 0
	for entry in vehicles:
		var shape := TeardownMapImporter.load_named_shape(
			VOX_DIR + entry[1], entry[2], float(entry[3])
		)
		_check(shape != null and shape.voxel_count() > 500,
			"%s decodes into actual voxels" % entry[0])
		if shape == null:
			continue
		var body := VoxelBody3D.new()
		body.state = VoxelBody3D.State.DYNAMIC
		world.add_child(body)
		body.add_voxel_shape(shape)
		body.global_position = Vector3(float(offset) * 6.0, 6.0, 0.0)
		world.register_body(body)
		body.wake_for_interaction()
		bodies.append(body)
		offset += 1
	_check(bodies.size() == 3, "all three bodies are registered")
	var expected_masses := [846.7, 1532.9, 1820.0]
	for index in bodies.size():
		var measured := (bodies[index].get_physics_body() as RigidBody3D).mass
		print("  mass %s: %.1f kg" % [vehicles[index][0], measured])
		_check(absf(measured - expected_masses[index]) < expected_masses[index] * 0.02,
			"%s retains a plausible vehicle mass" % vehicles[index][0])

	var before: Array[float] = []
	for body in bodies:
		before.append(body.get_physics_body().global_position.y)
	for _frame in 90:
		await physics_frame
	var landed := 0
	for index in bodies.size():
		var fell := before[index] - bodies[index].get_physics_body().global_position.y
		if fell > 1.0:
			landed += 1
	print("  %d of %d landed" % [landed, bodies.size()])
	_check(landed == bodies.size(), "all three land on the ground like normal dynamic bodies")

	if failures == 0:
		print("VOXEL_VEHICLE_EXTRACT_SELFTEST_OK")
	else:
		printerr("VOXEL_VEHICLE_EXTRACT_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
