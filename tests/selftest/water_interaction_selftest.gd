extends "res://tests/selftest/selftest.gd"
## Gameplay regression: a RigidBody entering the water, floating/drag, and the player held at the surface.


func _make_water(parent: Node) -> VoxelWaterSystem:
	var water := VoxelWaterSystem.new()
	parent.add_child(water)
	water.add_polygon(PackedVector3Array([
		Vector3(-10, 0, -10), Vector3(10, 0, -10),
		Vector3(10, 0, 10), Vector3(-10, 0, 10),
	]), Color(0.02, 0.08, 0.1), 3.0, 1.0, 10.0, 1.0)
	water.finish()
	return water


func _make_prop(world: VoxelWorld3D) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.DYNAMIC
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(6 * 6 * 6)
	cells.fill(1)
	shape.data.set_cells(Vector3i(6, 6, 6), cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.BROWN, "hardness": 1.0, "density": 700.0,
	})
	shape.physical_fill_scale = 0.025
	shape.anchored = false
	shape.position = Vector3(0, 3.0, 0)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _run() -> void:
	print("water interaction")
	var world := make_world(false)
	var water := _make_water(world)
	water.setup(world)
	var prop := _make_prop(world)
	var rigid := prop.get_physics_body() as RigidBody3D
	rigid.sleeping = false
	# The volume is 10 m deep: the object sinks and, after passing through it, resumes free fall
	# because there is no bottom below. Measure only the portion inside the water.
	var minimum_y := INF
	var maximum_speed_inside := 0.0
	for _frame in 240:
		await physics_frame
		var center_y := prop.get_shapes()[0].world_bounds().get_center().y
		minimum_y = minf(minimum_y, center_y)
		if center_y > -9.0:
			maximum_speed_inside = maxf(maximum_speed_inside, rigid.linear_velocity.length())
	_check(water.splash_count >= 1, "an object entering the water creates a splash and ripple")
	_check(minimum_y < -1.0, "an object falling into the water sinks instead of bobbing")
	# In free fall, those 12 m would produce ~15 m/s on leaving the volume; drag reduces that to
	# ~7.3 m/s, meaning the object enters the water and stops accelerating.
	_check(maximum_speed_inside < 9.0,
		"drag slows the fall while the object is inside the volume")

	# The player starts submerged and falling. Without swimming, they would be at -6 m after one
	# second; the controller moves them to the surface target (origin ≈ -1.15 m, camera above water).
	var player := CharacterBody3D.new()
	player.name = "PlayerSwimProbe"
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0, 1.65, 0)
	player.add_child(camera)
	var player_collision := CollisionShape3D.new()
	player_collision.name = "Collision"
	var player_capsule := CapsuleShape3D.new()
	player_capsule.radius = 0.4
	player_capsule.height = 1.8
	player_collision.position.y = 0.9
	player_collision.shape = player_capsule
	player.add_child(player_collision)
	player.set_script(load("res://scripts/core/player.gd"))
	root.add_child(player)
	player.global_position = Vector3(4.0, -1.0, 0.0)
	player.velocity = Vector3(0.0, -5.0, 0.0)
	var splashes_before := water.splash_count
	for _frame in 90:
		await physics_frame
	_check(player.global_position.y > -1.8,
		"the player keeps swimming near the surface")
	_check(water.splash_count > splashes_before,
		"the player's entry also generates water feedback")

	# A car with its seat below the waterline stalls permanently and ejects the player into a
	# swimming position. Two minimal wheels are enough to test this without importing a whole map.
	var vehicle := VoxelVehicle3D.new()
	vehicle.position = Vector3(-3.0, -0.25, 0.0)
	vehicle.rotation.z = PI
	var vehicle_collision := CollisionShape3D.new()
	var vehicle_box := BoxShape3D.new()
	vehicle_box.size = Vector3(2.0, 1.0, 4.0)
	vehicle_collision.shape = vehicle_box
	vehicle.add_child(vehicle_collision)
	root.add_child(vehicle)
	vehicle.add_to_group(VoxelVehicle3D.GROUP)
	for index in 2:
		var wheel := VehicleWheel3D.new()
		wheel.position.x = -0.7 if index == 0 else 0.7
		vehicle.add_child(wheel)
		vehicle._wheels.append(wheel)
	player.global_position = vehicle.get_seat_position()
	player.call("_toggle_vehicle")
	_check(bool(player.call("is_driving_vehicle")), "the player occupies the test vehicle")
	vehicle.engine_force = 5000.0
	vehicle.update_water_submersion(0.7, 0.0)
	await process_frame
	await physics_frame
	_check(vehicle.is_water_disabled() and is_zero_approx(vehicle.engine_force),
		"the engine stays off after flooding")
	_check(is_zero_approx(vehicle.brake) \
			and vehicle._wheels.all(func(wheel: VehicleWheel3D) -> bool:
				return is_zero_approx(wheel.suspension_max_force)),
		"the flooded train does not fight the bottom with suspension or wheel brakes")
	_check(not bool(player.call("is_driving_vehicle")) and player.global_position.is_finite() \
			and player.global_position.y > -1.5,
		"the driver exits an overturned car inside the swim volume, not below the map")
	_check(not vehicle.can_enter(player.global_position, 20.0),
		"a flooded vehicle cannot be driven again")

	make_box_body(root, Vector3(20.0, 0.4, 20.0), Vector3(0.0, -2.8, 0.0))
	var late_angular_peak := 0.0
	for frame in 240:
		await physics_frame
		if frame >= 180:
			late_angular_peak = maxf(late_angular_peak, vehicle.angular_velocity.length())
	_check(vehicle.global_position.is_finite() and vehicle.global_position.y > -2.3,
		"the chassis rests on the bed without embedding into it")
	_check(late_angular_peak < 1.0,
		"the flooded vehicle settles without bouncing against the bed")

	if failures == 0:
		print("VOXEL_WATER_INTERACTION_SELFTEST_OK")
	else:
		printerr("VOXEL_WATER_INTERACTION_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
