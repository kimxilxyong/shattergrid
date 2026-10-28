extends "res://tests/selftest/selftest.gd"
## Regression for the two parked cars: the first synchronization must not turn the detailed wheel
## faces inward and make them look like black holes.

var MAP := VoxelProjectPaths.teardown_map_path()
const PARKING_CENTER := Vector3(3.0, 0.0, -55.8)


func _run() -> void:
	if not FileAccess.file_exists(MAP):
		print("VOXEL_VEHICLE_WHEEL_ORIENTATION_SKIP local copy of Lee is missing")
		quit()
		return
	var world := make_world(false)
	TeardownMapImporter.import_map(world, MAP, PARKING_CENTER, 8.0, Vector3.ZERO, false)
	var vehicles := get_nodes_in_group(VoxelVehicle3D.GROUP)
	_check(vehicles.size() == 2, "the red pickup and blue station wagon are imported")
	var visual_shape_count := 0
	for vehicle_variant: Variant in vehicles:
		var vehicle := vehicle_variant as VoxelVehicle3D
		var visual_body := vehicle.voxel_owner.get_meta(
			"teardown_vehicle_visual_body"
		) as VoxelBody3D
		if visual_body != null:
			visual_shape_count += visual_body.get_shapes().size()
		_check(vehicle.wheel_visual_faces_outward(),
			"%s has tires and hubcaps facing outward" % vehicle.display_name)
	_check(visual_shape_count == 8, "both cars retain their eight wheel Shapes")
	# The bug appeared only on the first physics tick. Wait for the two frames the importer uses to
	# put the cars to sleep, then check the orientation published to the renderer again.
	for _frame in 3:
		await physics_frame
	for vehicle_variant: Variant in vehicles:
		var vehicle := vehicle_variant as VoxelVehicle3D
		_check(vehicle.wheel_visual_faces_outward(),
			"the first physics synchronization preserves the outer faces")
		var visual_body := vehicle.voxel_owner.get_meta(
			"teardown_vehicle_visual_body"
		) as VoxelBody3D
		if visual_body != null:
			for shape: VoxelShape3D in visual_body.get_shapes():
				_check(shape.global_position.distance_to(
					shape.get_global_transform_interpolated().origin
				) < 0.05, "the pose published to the renderer matches the parked wheel")
	var tracker := VoxelTransformTracker.new()
	var tracked: Dictionary = tracker.collect(world.get_transform_tracked_body_ids())
	var tracked_wheels := 0
	for shape_variant: Variant in tracked.shapes:
		var shape := shape_variant as VoxelShape3D
		if shape != null and shape.has_meta("vehicle_wheel_visual"):
			tracked_wheels += 1
	_check(tracked_wheels == 8,
		"the renderer continues receiving all eight wheels after the vehicles sleep")
	if failures == 0:
		print("VOXEL_VEHICLE_WHEEL_ORIENTATION_OK")
	else:
		printerr("VOXEL_VEHICLE_WHEEL_ORIENTATION_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
