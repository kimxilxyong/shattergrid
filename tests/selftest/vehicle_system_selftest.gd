extends "res://tests/selftest/selftest.gd"
## Regression test for Lee's authored SUV: XML -> VehicleBody -> suspension -> DDA lights.

var MAP := VoxelProjectPaths.teardown_map_path()
const SUV_CENTER := Vector3(-16.1, 0.0, 21.5)


func _make_wood_wall(
	world: VoxelWorld3D, origin: Vector3, basis := Basis.IDENTITY
) -> Dictionary:
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.STATIC
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(30, 24, 3)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color(0.42, 0.25, 0.11), "hardness": 1.0, "density": 700.0,
	})
	shape.anchored = false
	shape.transform = Transform3D(basis, origin)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return {"body": body, "shape": shape}


func _run() -> void:
	if not FileAccess.file_exists(MAP):
		printerr("VOXEL_VEHICLE_SELFTEST_SKIP local copy of Lee is missing")
		quit(0)
		return
	var world := VoxelWorld3D.new()
	world.name = "World"
	world.show_diagnostics = false
	root.add_child(world)
	var report := TeardownMapImporter.import_map(world, MAP, SUV_CENTER, 8.0, Vector3.ZERO, true)
	_check(int(report.get("vehicles_declared", 0)) >= 20, "vehicles are counted from main.xml")
	_check(int(report.get("vehicles_drivable", 0)) >= 1, "the cropped SUV is made drivable")
	var vehicles := get_nodes_in_group(VoxelVehicle3D.GROUP)
	_check(not vehicles.is_empty(), "a real VehicleBody3D exists")
	if vehicles.is_empty():
		_finish()
		return
	var vehicle := vehicles[0] as VoxelVehicle3D
	# Cropping by Shape origin can exclude the large terrain crossing this area even when the SUV is
	# included. A local plane at the authored elevation isolates the drivetrain test from that detail.
	make_box_body(root, Vector3(30.0, 0.4, 30.0), Vector3(0.0, 0.9, 0.0))
	_check(vehicle.get_child_count() >= 4, "all four suspension raycasts are created")
	_check(vehicle.voxel_owner != null and vehicle.voxel_owner.get_physics_body() == vehicle,
		"the destructible chassis and vehicle share a single source of physical truth")
	var wheel_visual_body := vehicle.voxel_owner.get_meta(
		"teardown_vehicle_visual_body"
	) as VoxelBody3D
	var wheel_visual_shapes := wheel_visual_body.get_shapes() \
		if wheel_visual_body != null else [] as Array[VoxelShape3D]
	_check(wheel_visual_shapes.size() >= 4,
		"the four authored wheels retain their visual Shapes")
	_check(wheel_visual_body != null and world.get_transform_tracked_body_ids().has(
		wheel_visual_body.get_instance_id()
	), "the renderer tracks the wheels even when their auxiliary Body is frozen")
	var transform_probe := VoxelTransformTracker.new()
	var tracked_snapshot := transform_probe.collect(world.get_transform_tracked_body_ids())
	var tracked_wheel_shapes := 0
	var initial_wheel_origins := {}
	for shape_variant: Variant in tracked_snapshot.shapes:
		if wheel_visual_shapes.has(shape_variant):
			tracked_wheel_shapes += 1
			initial_wheel_origins[(shape_variant as VoxelShape3D).get_instance_id()] = (
				shape_variant as VoxelShape3D
			).global_position
	_check(tracked_wheel_shapes == wheel_visual_shapes.size(),
		"all wheel Shapes reach the native transform batch")
	_check(vehicle.wheel_visual_faces_outward(),
		"authored tires and hubcaps remain oriented outward")
	_check(vehicle.voxel_owner.continuous_collision,
		"the vehicle retains CCD against thin walls")
	_check(vehicle.voxel_owner.compound_boxes <= VoxelVehicle3D.COLLISION_BOX_BUDGET,
		"the chassis uses at most %d Jolt boxes (uses %d)" % [
			VoxelVehicle3D.COLLISION_BOX_BUDGET, vehicle.voxel_owner.compound_boxes,
		])
	_check(int(vehicle.voxel_owner.get_meta("voxel_shadow_interval_frames", 1)) \
			== VoxelVehicle3D.SHADOW_UPDATE_INTERVAL_FRAMES,
		"vehicle volumetric shadows are limited to 10 Hz without limiting geometry")
	vehicle.linear_velocity = Vector3(2.0, 0.0, 0.0)
	vehicle.voxel_owner.update_adaptive_ccd()
	_check(not vehicle.continuous_cd, "CCD remains disabled at low speed")
	vehicle.linear_velocity = Vector3(VoxelVehicle3D.CCD_MIN_SPEED + 1.0, 0.0, 0.0)
	vehicle.voxel_owner.update_adaptive_ccd()
	_check(vehicle.continuous_cd, "CCD is enabled when there is a risk of passing through a wall")
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.voxel_owner.update_adaptive_ccd()
	_check(vehicle.mass > 900.0 and vehicle.mass < 2600.0,
		"vehicle mass is within a plausible range (%.1f kg)" % vehicle.mass)
	_check(is_equal_approx(vehicle.impact_strength, 8.0),
		"the authored strength=8 is retained for the SUV's crash profile")
	_check(vehicle.center_of_mass.y < 0.7,
		"the center of mass is low enough to prevent rollover while turning")
	_check(vehicle.projected_light_count() >= 6,
		"headlights, brake lights, and reverse lights are projected Light3D nodes")
	var driver := Node3D.new()
	root.add_child(driver)
	_check(vehicle.set_driver(driver), "a driver can take the seat")
	_check(vehicle.headlights_active(), "the headlights turn on when entering")
	vehicle.set_control_override(true, 1.0, 0.35, false)
	for _frame in 3:
		await physics_frame
	_check(vehicle.engine_force > 0.0, "W accelerates and applies force to the drivetrain")
	_check(absf(vehicle.steering) > 0.01, "A/D move the steering")
	var drive_start := Vector2(vehicle.global_position.x, vehicle.global_position.z)
	for _frame in 90:
		await physics_frame
	var planar_distance := drive_start.distance_to(
		Vector2(vehicle.global_position.x, vehicle.global_position.z)
	)
	_check(planar_distance > 0.35,
		"the suspension transfers force to the ground (travel %.2f m)" % planar_distance)
	var moved_snapshot := transform_probe.collect(world.get_transform_tracked_body_ids())
	var moved_wheel_visuals := 0
	for index in mini(moved_snapshot.shapes.size(), moved_snapshot.transforms.size()):
		var moved_shape := moved_snapshot.shapes[index] as VoxelShape3D
		if moved_shape == null or not initial_wheel_origins.has(moved_shape.get_instance_id()):
			continue
		var moved_transform := moved_snapshot.transforms[index] as Transform3D
		if moved_transform.origin.distance_to(initial_wheel_origins[moved_shape.get_instance_id()]) \
				> 0.35:
			moved_wheel_visuals += 1
	_check(moved_wheel_visuals == wheel_visual_shapes.size(),
		"the wheel visuals move with the car in the renderer")
	var contacts := 0
	for wheel: Dictionary in vehicle.get_wheel_telemetry():
		contacts += 1 if bool(wheel.contact) else 0
	_check(contacts >= 2, "at least two wheels maintain contact while turning")
	_check(vehicle.global_basis.y.normalized().dot(Vector3.UP) > 0.55,
		"the lowered center of mass prevents an immediate rollover")
	_check(is_zero_approx(VoxelVehicle3D.contact_normal_speed(
		Vector3(14.0, 0.0, 0.0), Vector3.UP
	)), "rolling tangentially across the ground does not cause voxel damage")
	_check(is_equal_approx(VoxelVehicle3D.contact_normal_speed(
		Vector3(0.0, -4.0, 0.0), Vector3.UP
	), 4.0), "velocity along the normal is recognized as an impact")
	var impact_profile := VoxelWorld3D.physics_impact_profile(
		vehicle.voxel_owner, 400.0, 3.0
	)
	_check(bool(impact_profile.get("vehicle", false)) \
			and float(impact_profile.get("radius", 0.0)) >= 1.0,
		"the SUV makes a vehicle-sized opening at urban speeds")
	vehicle.set_control_override(true, 0.0, 0.0, true)
	await physics_frame
	_check(vehicle.brake > vehicle.coast_brake and vehicle.brake_lights_active(),
		"the handbrake applies force and projects red light")
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.set_control_override(true, -1.0, 0.0, false)
	await physics_frame
	_check(vehicle.engine_force < 0.0 and vehicle.reverse_lights_active(),
		"reverse gear applies force and lights up white")

	# A real collision (not a direct damage call): accelerate the SUV into a 30 cm wooden wall.
	# This covers Jolt contact -> normal velocity -> deferred queue -> vehicle profile -> crater.
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	var crash_forward := vehicle.forward_direction()
	var crash_right := Vector3.UP.cross(crash_forward).normalized()
	var wall_basis := Basis(crash_right, Vector3.UP, crash_forward).orthonormalized()
	var wall_center := vehicle.global_position + crash_forward * 4.2
	wall_center.y = 2.1
	var wall := _make_wood_wall(world, wall_center, wall_basis)
	var wall_shape := wall.shape as VoxelShape3D
	var wall_before := wall_shape.voxel_count()
	var vehicle_before := vehicle.voxel_owner.get_total_voxels()
	var impacts_before := world.physics_impacts
	vehicle.set_control_override(true, 1.0, 0.0, false)
	for _frame in 180:
		await physics_frame
		if is_instance_valid(wall_shape) and wall_shape.voxel_count() < wall_before:
			break
	var wall_after := wall_shape.voxel_count() if is_instance_valid(wall_shape) else 0
	print("  vehicle collision: wall %d→%d position=%s wall_pos=%s speed=%.2f" % [
		wall_before, wall_after, vehicle.global_position, wall_center, vehicle.linear_velocity.length(),
	])
	_check(world.physics_impacts > impacts_before and wall_after < wall_before,
		"the car breaks through ordinary wood via real Jolt contact")
	_check(vehicle.voxel_owner.get_total_voxels() == vehicle_before,
		"the frontal profile does not pierce its own chassis when breaking wood")
	_check(String(world.last_physics_impact.get("kind", "")) == "vehicle",
		"diagnostics identify the vehicle impact")
	vehicle.set_control_override(true, 0.0, 0.0, true)
	await physics_frame

	var camera := Camera3D.new()
	root.add_child(camera)
	camera.global_position = vehicle.global_position + Vector3.UP * 3.0
	var pool := VoxelLocalShadowPool.new()
	root.add_child(pool)
	pool.setup(world, camera)
	for _frame in 3:
		await process_frame
	var metadata := pool.get_shader_metadata()
	_check(int(metadata[VoxelLocalShadowPool.MAX_LIGHTS * 16]) >= 2,
		"the headlights reach the voxel DDA pass")
	_check(int(metadata[VoxelLocalShadowPool.MAX_LIGHTS * 16 + 1]) == 0,
		"moving headlights do not rebake 128^3 volumes every frame")
	vehicle.clear_driver(driver)
	vehicle.set_control_override(false)
	_check(not vehicle.headlights_active(), "exiting turns off the headlights")
	var level := Node3D.new()
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	var interaction := Label.new()
	interaction.name = "Interaction"
	hud.add_child(interaction)
	level.add_child(hud)
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load("res://scripts/core/player.gd"))
	var player_camera := Camera3D.new()
	player_camera.name = "Camera3D"
	player_camera.position = Vector3(0.0, 1.65, 0.0)
	player.add_child(player_camera)
	var player_collision := CollisionShape3D.new()
	player_collision.position.y = 0.9
	var player_capsule := CapsuleShape3D.new()
	player_capsule.radius = 0.38
	player_capsule.height = 1.8
	player_collision.shape = player_capsule
	player.add_child(player_collision)
	level.add_child(player)
	root.add_child(level)
	await process_frame
	player.global_position = vehicle.get_seat_position()
	var original_fov := player_camera.fov
	player.call("_toggle_vehicle")
	_check(bool(player.call("is_driving_vehicle")) and player.collision_layer == 0,
		"E enters the vehicle and disables the player's capsule")
	_check(vehicle.headlights_active(), "the actual E input also turns on the headlights")
	var rig := player.get("_vehicle_camera") as VehicleCamera
	var pitch_before := rig.pitch
	_check(VehicleCamera.pitch_after_input(pitch_before, 12.0, 0.0022) > pitch_before,
		"the orbit camera's vertical axis was inverted")
	# Sensitivity scales with tan(fov/2): zooming in should make the same gesture turn less.
	_check(VehicleCamera.aim_sensitivity(30.0) < VehicleCamera.aim_sensitivity(78.0),
		"sensitivity decreases when zooming in")
	var zoom_in := InputEventMouseButton.new()
	zoom_in.button_index = MOUSE_BUTTON_WHEEL_UP
	zoom_in.pressed = true
	for _step in 8:
		player.call("_unhandled_input", zoom_in)
	_check(rig.is_interior(), "the wheel zooms all the way to the interior view")
	rig.update(1.0, player_camera, vehicle, [] as Array[RID])
	_check(player_camera.global_position.distance_to(vehicle.get_driver_view_position()) < 0.15,
		"the interior view uses the XML-authored driver position")
	player.call("_toggle_vehicle")
	_check(not bool(player.call("is_driving_vehicle")),
		"a second E makes the player exit the vehicle")
	# The capsule exits with collision deliberately disabled, and `_restore_vehicle_collision` restores it
	# Two `_physics_process` calls later: checking in the same tick measured the deactivation, not restoration.
	for _frame in 3:
		await physics_frame
	_check(player.collision_layer != 0,
		"the capsule regains collision after exiting")
	_check(is_equal_approx(player_camera.fov, original_fov),
		"exiting restores the on-foot camera FOV")

	# Regression test for the capture: when the car is on its side, its local X axis points into the
	# ground. The old exit code added that axis to the seat position and placed the capsule under the
	# map when pressing E while moving.
	vehicle.freeze = true
	vehicle.global_position = Vector3(0.0, 2.0, 0.0)
	vehicle.rotation = Vector3(0.0, 0.0, PI * 0.5)
	await physics_frame
	player.global_position = vehicle.get_seat_position()
	player.call("_toggle_vehicle")
	vehicle.linear_velocity = Vector3(9.0, 0.0, 0.0)
	player.call("_toggle_vehicle")
	_check(player.global_position.y >= 1.1 \
			and player.global_position.distance_to(vehicle.global_position) > 1.5,
		"exiting a moving, overturned car leaves the player above the floor and outside the compound")
	vehicle.freeze = false

	vehicle.sleeping = true
	vehicle.park_after_sleep()
	_check(not vehicle.is_physics_processing(),
		"the parked car suspends its GDScript controller")
	vehicle.apply_central_impulse(Vector3(120.0, 0.0, 0.0))
	for _frame in 2:
		await physics_frame
	_check(vehicle.is_physics_processing(), "un contacto/despertar reactiva el controlador")
	world.unregister_body(vehicle.voxel_owner)
	vehicle.voxel_owner.queue_free()
	await process_frame
	_check(not is_instance_valid(wheel_visual_body),
		"destroying the chassis also cleans up the visual wheels")
	_finish()


func _finish() -> void:
	if failures == 0:
		print("VOXEL_VEHICLE_SELFTEST_OK")
	else:
		printerr("VOXEL_VEHICLE_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
