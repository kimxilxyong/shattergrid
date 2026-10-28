extends "res://tests/selftest/selftest.gd"
## Full tank regression: aiming on both axes, differential steering, and the turret ring under load.
## The turret never detaches, not even in an explosion.
##
## The final scenario tests hull yaw: the turret-ring motor commands velocity relative to the
## hull, and `target_yaw` is relative too. With the reticle fixed on a world point, the target moves
## at -omega while the hull rotates at omega. A pure proportional controller can only track this
## with a persistent omega/YAW_GAIN error, making the turret appear to rotate with the hull.


class Gunner:
	extends Node3D
	var camera: Camera3D

	func _init() -> void:
		camera = Camera3D.new()
		add_child(camera)


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


func _discard_test_tank(world: VoxelWorld3D, tank: VoxelTank3D) -> void:
	# Each scenario must leave the physics space clear for the next one; the Bodies are siblings
	# of the controller inside VoxelWorld, not children that disappear when `tank` is deleted.
	if tank._joints != null and is_instance_valid(tank._joints):
		tank._joints.break_record(tank._joint_record)
	for body in [tank.hull, tank.turret, tank.barrel]:
		if body != null and is_instance_valid(body):
			world.unregister_body(body)
	for node in [tank.hull, tank.turret, tank.barrel, tank]:
		if node != null and is_instance_valid(node):
			node.queue_free()


## Rumbo absoluto en el mundo, con el mismo convenio que `VoxelTank3D._plane_yaw`.
static func _turret_world_yaw(tank: VoxelTank3D) -> float:
	var basis := tank.turret.get_physics_body().global_basis
	return atan2(-basis.x.z, basis.x.x)


static func _hull_world_yaw(tank: VoxelTank3D) -> float:
	var basis := tank.hull_transform().basis
	return atan2(-basis.x.z, basis.x.x)


func _run() -> void:
	print("tank turret")
	var world := make_world()

	make_box_body(world, Vector3(40, 1, 40), Vector3(0, -0.5, 0))

	var gunner := Gunner.new()
	root.add_child(gunner)
	var tank := VoxelTank3D.spawn(world, Vector3(0, 1.0, 0), gunner)
	_check(tank != null, "the tank imports successfully")
	if tank == null:
		quit(1)
		return

	for _frame in 20:
		await physics_frame
	var joints := world.get_node_or_null("VoxelTankJoints") as VoxelJoints
	_check(joints != null, "the tank owns its turret-ring joint registry")
	_check(joints.live_count() == 2, "the turret ring and trunnions start live")
	_check(tank.vehicle.attached_bodies().size() == 3,
		"camera and collision treat hull, turret, and cannon as one tank")
	var camera_profile := tank.vehicle.get_camera_profile()
	_check(is_equal_approx(float(camera_profile.distance), 8.4)
		and is_equal_approx(float(camera_profile.fov), 78.0),
		"the tank exposes its arcade camera profile")
	# Check the aim, not the raw angle: the hull's physics frame is rotated relative to the model,
	# so `yaw()` is an internal value. The cannon must end up following the camera line controlled
	# by the mouse.
	var target := Vector3(20, 1, -14)
	gunner.camera.global_position = Vector3(-10, 5, 12)
	gunner.camera.look_at(target)
	_check(tank.vehicle.set_driver(gunner), "the gunner enters the tank")
	for _frame in 420:
		await physics_frame
	# The model's cannon points along the turret's +X axis, which starts unrotated.
	var barrel := tank.turret.get_physics_body().global_basis.x
	var wanted := target - tank.hull_transform().origin
	barrel.y = 0.0
	wanted.y = 0.0
	var off := absf(barrel.normalized().angle_to(wanted.normalized()))
	print("  cannon deviation: %.1f degrees" % rad_to_deg(off))
	_check(off < 0.15, "the turret follows the camera reticle")

	# The cannon pitches on its trunnions, not with the whole turret: when aiming at a high target,
	# it must elevate and stay within the range of a real tank.
	_check(tank.barrel != null, "the cannon is a separate piece from the turret")
	gunner.camera.look_at(Vector3(20, 14, -14))
	for _frame in 180:
		await physics_frame
	var high_pitch := tank.barrel_pitch()
	gunner.camera.global_position = Vector3(-10, 2, 12)
	gunner.camera.look_at(Vector3(20, -6, -14))
	for _frame in 180:
		await physics_frame
	var low_pitch := tank.barrel_pitch()
	print("  pitch: high %.1f°, low %.1f°" % [
		rad_to_deg(high_pitch), rad_to_deg(low_pitch),
	])
	_check(high_pitch - low_pitch > deg_to_rad(8.0), "the cannon elevates and depresses with the reticle")
	_check(high_pitch < deg_to_rad(VoxelTank3D.BARREL_MAX_PITCH_DEG + 1.0)
		and low_pitch > deg_to_rad(VoxelTank3D.BARREL_MIN_PITCH_DEG - 1.0),
		"pitch stays within the tank's elevation limits")
	tank.vehicle.clear_driver(gunner)

	# The cannon remains horizontal: if the hinge axis were wrong, the turret would have
	# cabeceado en vez de rotar.
	var up := tank.turret.get_physics_body().global_basis.y
	_check(up.dot(Vector3.UP) > 0.95, "the turret does not pitch: its axis is vertical")

	# The map drops the player from 30 m, and the tank falls with them. If the impact separates the
	# two anchors by more than `BREAK_SEPARATION`, `VoxelJoints` breaks the ring and the tank lands
	# without its turret.
	var dropped := VoxelTank3D.spawn(world, Vector3(12, 30.0, 0))
	for _frame in 300:
		if not is_instance_valid(dropped.hull) or not is_instance_valid(dropped.turret):
			break
		# Without the player, the physics budget removes distant bodies; keep them awake manually
		# so the fall actually happens.
		dropped.hull.wake_for_interaction()
		dropped.turret.wake_for_interaction()
		await physics_frame
	_check(joints.live_count() == 4, "the turret ring survives a 30 m fall")
	print("  height after fall: %.2f" % dropped.hull_transform().origin.y)

	# Differential steering must pivot while stationary. The override uses exactly the same input as
	# A/D during gameplay; previously, the tank read Input again, making this path impossible to verify.
	var driver := Node3D.new()
	root.add_child(driver)
	_check(tank.vehicle.set_driver(driver), "the driver enters the tank")
	var forward_before := tank.vehicle.forward_direction()
	tank.vehicle.set_control_override(true, 0.0, 1.0, false)
	var worst_separation := 0.0
	for _frame in 120:
		await physics_frame
		worst_separation = maxf(worst_separation, tank.turret_anchor_separation())
	var turn_angle := forward_before.angle_to(tank.vehicle.forward_direction())
	print("  A/D turn: %.1f degrees; turret-ring separation: %.3f m" % [
		rad_to_deg(turn_angle), worst_separation,
	])
	_check(turn_angle > 0.7, "A/D pivot the tracks even from a standstill")
	_check(tank.is_turret_attached(), "turning does not detach the turret")
	_check(worst_separation < VoxelJoints.BREAK_SEPARATION,
		"the turret ring remains physically sealed during rotation")

	# W applies traction without turning A/D into car-style steering.
	var drive_start := tank.vehicle.global_position
	tank.vehicle.set_control_override(true, 1.0, 0.0, false)
	for _frame in 120:
		await physics_frame
	_check(tank.vehicle.global_position.distance_to(drive_start) > 0.5,
		"W moves the tank forward")
	_check(tank.is_turret_attached(), "accelerating does not detach the turret")

	# Track grip: while turning, the tank changes direction instead of sliding sideways along its
	# previous trajectory. Measure lateral velocity relative to forward velocity.
	tank.vehicle.set_control_override(true, 1.0, 1.0, false)
	var worst_skid := 0.0
	for _frame in 90:
		await physics_frame
		var speed := tank.vehicle.linear_velocity.length()
		if speed > 1.0:
			worst_skid = maxf(worst_skid,
				absf(tank.vehicle.linear_velocity.dot(tank.vehicle.global_basis.x)) / speed)
	print("  maximum lateral skid: %.0f%% of speed" % (worst_skid * 100.0))
	_check(worst_skid < 0.35, "the tracks grip sideways instead of sliding")
	tank.vehicle.set_control_override(false)
	tank.vehicle.clear_driver(driver)
	_discard_test_tank(world, tank)
	_discard_test_tank(world, dropped)
	for _frame in 3:
		await physics_frame

	# Product test: build the wall perpendicular to the tank's physical orientation once it has
	# settled. This measures a real collision without assuming the VOX model's axis.
	var rammer := VoxelTank3D.spawn(world, Vector3(-10.0, 1.0, -10.0))
	for _frame in 60:
		await physics_frame
	rammer.vehicle.linear_velocity = Vector3.ZERO
	rammer.vehicle.angular_velocity = Vector3.ZERO
	var crash_forward := rammer.vehicle.forward_direction()
	var crash_right := Vector3.UP.cross(crash_forward).normalized()
	var wall_basis := Basis(crash_right, Vector3.UP, crash_forward).orthonormalized()
	# The cannon extends well beyond the hull. Leave a gap from the end of the entire assembly so
	# the test does not start with the turret embedded in the wall.
	var wall_center := rammer.vehicle.get_world_bounds().get_support(crash_forward) \
		+ crash_forward * 1.5
	wall_center.y = 1.2
	var wall_parts := _make_wood_wall(world, wall_center, wall_basis)
	var wall := wall_parts.body as VoxelBody3D
	var wall_shape := wall_parts.shape as VoxelShape3D
	var wall_voxels := wall_shape.voxel_count()
	var hull_voxels := rammer.hull.get_total_voxels()
	var impacts_before := world.physics_impacts
	var rammer_driver := Node3D.new()
	root.add_child(rammer_driver)
	_check(rammer.vehicle.set_driver(rammer_driver), "the ramming tank can be driven")
	rammer.vehicle.set_control_override(true, 1.0, 0.0, false)
	var crossed_wall := false
	# `last_physics_impact` is a single global slot: wall debris colliding with itself overwrites it
	# with `body` impacts as soon as the wall gives way, so the ramming profile must be
	# observe it when it happens, not at the end.
	var vehicle_impact_seen := false
	for _frame in 360:
		await physics_frame
		vehicle_impact_seen = vehicle_impact_seen \
			or String(world.last_physics_impact.get("kind", "")) == "vehicle"
		var beyond := (rammer.vehicle.global_position - wall_center).dot(crash_forward)
		crossed_wall = crossed_wall or beyond > 0.5
		if crossed_wall and (not is_instance_valid(wall_shape) \
				or wall_shape.voxel_count() < wall_voxels):
			break
	var wall_after := wall_shape.voxel_count() if is_instance_valid(wall_shape) else 0
	print("  wall: %d -> %d voxels; hull: %d -> %d; tank=%s; impact=%s" % [
		wall_voxels, wall_after, hull_voxels, rammer.hull.get_total_voxels(),
		rammer.vehicle.global_position,
		JSON.stringify(world.last_physics_impact),
	])
	_check(world.physics_impacts > impacts_before and wall_after < wall_voxels,
		"the tank opens a hole through real Jolt contact")
	_check(vehicle_impact_seen, "the collision uses the tank's high-impact profile")
	_check(rammer.hull.get_total_voxels() == hull_voxels,
		"breaking through the wall does not damage the hull")
	_check(crossed_wall,
		"the tank breaks through the wall without getting stuck")
	_check(rammer.is_turret_attached(), "breaking through a wall does not detach the turret")
	rammer.vehicle.set_control_override(false)
	rammer.vehicle.clear_driver(rammer_driver)

	# Not even an explosion on the assembly separates the turret: the ring is `breakable: false`.
	var explosive := VoxelTank3D.spawn(world, Vector3(10.0, 1.0, 12.0))
	for _frame in 24:
		await physics_frame
	var armour_voxels := explosive.hull.get_total_voxels()
	var blast := explosive.vehicle.get_world_bounds().get_center()
	world.damage_sphere(blast, 0.4, 0.01, {"cause": "explosion"})
	for _frame in 8:
		await physics_frame
	print("  turret-ring separation after explosion: %.3f m" % explosive.turret_anchor_separation())
	_check(explosive.is_turret_attached(), "an explosion does not detach the turret")
	_check(explosive.turret_anchor_separation() < VoxelJoints.BREAK_SEPARATION,
		"the turret ring remains sealed after the explosion")
	# The armor uses `heavymetal`: an explosion that opens a wooden wall does not remove a single
	# voxels from the tank.
	_check(explosive.hull.get_total_voxels() == armour_voxels,
		"the hull does not lose armor from the explosion")

	# The aiming camera uses world yaw: turning the hull must not drag the reticle.
	var yaw := VehicleCamera.yaw_from_forward(Vector3(0.6, 0.0, -0.8))
	var back := VehicleCamera.aim_direction(yaw, 0.0)
	_check(back.distance_to(Vector3(0.6, 0.0, -0.8)) < 0.01, "camera yaw returns to its original direction")
	_check(VehicleCamera.aim_direction(0.0, 0.5).y < -0.4, "positive pitch aims downward")

	# The orbital pivot inherits only position and yaw: hull roll must not move it.
	var level_pivot := VehicleCamera.pivot(
		explosive.vehicle.get_camera_pivot(Transform3D(Basis.IDENTITY, Vector3(3.0, 1.0, -2.0))), 1.55
	)
	var rolled_pivot := VehicleCamera.pivot(explosive.vehicle.get_camera_pivot(
		Transform3D(Basis(Vector3.BACK, 0.35), Vector3(3.0, 1.0, -2.0))
	), 1.55)
	_check(level_pivot.distance_to(rolled_pivot) < 0.001,
		"hull roll moves the camera pivot")
	var turned_pivot := VehicleCamera.pivot(explosive.vehicle.get_camera_pivot(
		Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(3.0, 1.0, -2.0))
	), 1.55)
	# The pivot is `origin + yaw * local_seat`: yaw only moves it if the seat has a horizontal offset.
	# The tank's seat is centered (0, 1.4, 0), so yaw should not change it there; comparing the
	# entire vector to zero would have accepted any result.
	var seat_offset := explosive.vehicle.get_camera_pivot(Transform3D.IDENTITY)
	var seat_radius := Vector2(seat_offset.x, seat_offset.z).length()
	_check(
		(level_pivot.distance_to(turned_pivot) > 0.001) == (seat_radius > 0.001),
		"hull yaw rotates the pivot if and only if the seat is off-center"
	)

	# Turning the hull must not drag the turret. The hull rotates on its axis at 0.9 rad/s: faster
	# than a pure proportional controller can track without lag, but below the compensation limit.
	var yawing := VoxelTank3D.spawn(world, Vector3(-14.0, 1.0, 10.0))
	if yawing != null:
		var aim_point := Vector3(-14.0, 1.5, -50.0)
		var yawing_body := yawing.hull.get_physics_body() as RigidBody3D
		for _frame in 90:
			await physics_frame
		# The ring is already aimed at the target: measure drift while the hull rotates, not the
		# time it takes to acquire the target.
		for _frame in 120:
			var hull_now := yawing.hull_transform()
			yawing.target_yaw = VoxelTank3D.aim_yaw(aim_point - hull_now.origin, hull_now.basis)
			await physics_frame
		var settled_yaw := _turret_world_yaw(yawing)
		var yaw_start := _hull_world_yaw(yawing)
		var peak_drift := 0.0
		for _frame in 150:
			yawing_body.angular_velocity = Vector3(0.0, 0.9, 0.0)
			var hull_now := yawing.hull_transform()
			yawing.target_yaw = VoxelTank3D.aim_yaw(aim_point - hull_now.origin, hull_now.basis)
			await physics_frame
			peak_drift = maxf(peak_drift,
				absf(wrapf(_turret_world_yaw(yawing) - settled_yaw, -PI, PI)))
		var hull_turned := absf(wrapf(_hull_world_yaw(yawing) - yaw_start, -PI, PI))
		print("  hull rotated %.1f degrees · maximum turret drift %.1f degrees" % [
			rad_to_deg(hull_turned), rad_to_deg(peak_drift),
		])
		_check(hull_turned > 0.7, "the hull actually rotated during the test")
		_check(peak_drift < deg_to_rad(4.0),
			"the turret stays aimed at the world point while the hull rotates")
		_discard_test_tank(world, yawing)
		await physics_frame

	print("failures: %d" % failures)
	quit(1 if failures > 0 else 0)
