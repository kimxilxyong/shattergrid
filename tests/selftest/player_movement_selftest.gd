extends "res://tests/selftest/selftest.gd"
func _run() -> void:
	print("movement: recovery, snap, and stairs")
	var level := Node3D.new()
	root.add_child(level)
	make_box_body(level, Vector3(12.0, 0.2, 12.0), Vector3(0.0, -0.1, 0.0))
	# Four 20 cm voxel risers. The last box continues as a landing so floor snap also has a stable
	# surface after the ascent.
	for step in 4:
		var top := 0.2 * float(step + 1)
		var depth := 0.65 if step < 3 else 3.0
		var center_z := 0.95 - float(step) * 0.65
		if step == 3:
			center_z -= 1.15
		make_box_body(level, Vector3(2.2, top, depth), Vector3(0.0, top * 0.5, center_z))

	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load("res://scripts/core/player.gd"))
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	collision.shape = capsule
	collision.position.y = 0.9
	player.add_child(collision)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position.y = 1.65
	player.add_child(camera)
	level.add_child(player)
	player.position = Vector3(0.0, 0.03, 2.0)

	for _frame in 8:
		await physics_frame
	Input.action_press("move_forward")
	var body_jump := 0.0
	var view_jump := 0.0
	var max_horizontal_step := 0.0
	var previous_body := player.global_position.y
	var previous_view := camera.global_position.y
	var previous_horizontal := Vector2(player.global_position.x, player.global_position.z)
	for _frame in 45:
		await physics_frame
		body_jump = maxf(body_jump, absf(player.global_position.y - previous_body))
		view_jump = maxf(view_jump, absf(camera.global_position.y - previous_view))
		previous_body = player.global_position.y
		previous_view = camera.global_position.y
		var horizontal := Vector2(player.global_position.x, player.global_position.z)
		max_horizontal_step = maxf(max_horizontal_step, horizontal.distance_to(previous_horizontal))
		previous_horizontal = horizontal
	Input.action_release("move_forward")
	print("  final position ", player.position)
	_check(player.position.z < -0.65, "the controller climbs a four-step voxel staircase")
	_check(player.position.y > 0.68, "it ends on the landing instead of embedded in the floor")
	# `safe_margin` is intentionally tiny; see the comment in `_ready` in `player.gd`.
	_check(player.floor_snap_length >= 0.3 and player.safe_margin <= 0.01,
		"floor snap is active and the step probe uses a tiny margin")
	print("  maximum horizontal movement per frame %.3f m" % max_horizontal_step)
	_check(max_horizontal_step <= 0.11,
		"the step probe adds no distance or acceleration to movement")
	print("  per-frame step  body %.3f  view %.3f" % [body_jump, view_jump])
	_check(body_jump > 0.1, "the body climbs the step immediately, as expected")
	_check(view_jump < body_jump * 0.6, "the view spreads that step over several frames")

	if failures == 0:
		print("VOXEL_PLAYER_MOVEMENT_SELFTEST_OK")
	else:
		printerr("VOXEL_PLAYER_MOVEMENT_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
