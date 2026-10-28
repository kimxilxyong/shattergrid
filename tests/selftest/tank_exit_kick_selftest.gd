extends "res://tests/selftest/selftest.gd"
## Regression: exiting a vehicle must not push it.
##
## The player's capsule follows the seat inside the hull with collision disabled. If collision is
## restored in the same frame as the teleport out, Jolt interprets the jump as kinematic motion and
## sweeps the capsule through the vehicle from inside to outside. This produced a measured 220 m/s
## spike that launched the tank into the air and drove it into the ground.


func _make_player() -> CharacterBody3D:
	var player: CharacterBody3D = load("res://scripts/core/player.gd").new()
	player.collision_layer = 1
	player.collision_mask = 1
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	player.add_child(camera)
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	collision.shape = capsule
	collision.position.y = 0.9
	player.add_child(collision)
	return player


func _run() -> void:
	var world := make_world()

	make_box_body(world, Vector3(80, 1, 80), Vector3(0, -0.5, 0))

	var player := _make_player()
	root.add_child(player)
	var tank := VoxelTank3D.spawn(world, Vector3(0, 1.0, 0), player)
	if tank == null:
		printerr("TANK_EXIT_KICK_SELFTEST_SKIP failed to import the tank")
		quit(0)
		return
	for _frame in 90:
		await physics_frame

	player.global_position = tank.vehicle.get_seat_position()
	player.call("_toggle_vehicle")
	_check(bool(player.call("is_driving_vehicle")), "the player is driving the tank")
	for _frame in 60:
		await physics_frame

	var before_y := tank.vehicle.global_position.y
	player.call("_toggle_vehicle")
	_check(not bool(player.call("is_driving_vehicle")), "the player exits the tank")
	var exit_position := player.global_position
	_check(bool(player.call("_vehicle_exit_is_clear", exit_position,
			[player.get_rid()] as Array[RID])),
		"the selected exit position does not overlap anything")

	var peak_speed := 0.0
	for _frame in 90:
		await physics_frame
		peak_speed = maxf(peak_speed, tank.vehicle.linear_velocity.length())
	print("     y before=%.3f  y after=%.3f  peak speed=%.3f" % [
		before_y, tank.vehicle.global_position.y, peak_speed
	])
	_check(peak_speed < 1.5, "the tank is not pushed when the driver exits")
	_check(absf(tank.vehicle.global_position.y - before_y) < 0.35,
		"the tank neither sinks nor jumps in height when the driver exits")
	_check(player.global_position.distance_to(exit_position) < 0.5,
		"the player stays where they were left instead of being launched")
	print("TANK_EXIT_KICK_SELFTEST ", "OK" if failures == 0 else "FAILURES: %d" % failures)
	quit(1 if failures > 0 else 0)
