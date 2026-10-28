extends SceneTree
## Move the player up stairs with different riser heights and verify that they cannot climb walls.
##
## Teardown's map uses 10 cm voxels, so a real step is 1, 2, or 3 voxels high. If the controller
## cannot climb 20 cm, it cannot climb any stairs on the map, which was the original problem. Also
## verify that the camera matches Teardown's 90-degree horizontal field of view.

const TREAD := 0.3
const STEPS := 10
const SECONDS := 3.0


func _initialize() -> void:
	_run()


func _run() -> void:
	var results := []
	for riser: float in [0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.45, 2.0]:
		results.append(await _climb(riser))
	_check_fov()
	print("riser  expected  reached  verdict")
	for row: Dictionary in results:
		var ok: bool = row.reached < 0.2 if row.riser >= 1.0 \
			else row.reached >= row.expected - 0.05
		print("%5.0f cm  %7.2f m  %8.2f m  %s" % [
			row.riser * 100.0, row.expected, row.reached,
			"OK" if ok else ("CLIMBS WALLS" if row.riser >= 1.0 else "FAIL")
		])
		assert(ok, "%.0f cm riser" % (row.riser * 100.0))
	print("OK")
	quit()


## Teardown uses 90 HORIZONTAL degrees. By default, Godot interprets `fov` as vertical, and 75
## vertical degrees at 16:9 equals 107 horizontal—much wider than Teardown. With
## `keep_aspect = KEEP_WIDTH`, the value becomes the horizontal field of view, as in the game.
func _check_fov() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var state := scene.get_state()
	var found := false
	for i in state.get_node_count():
		if state.get_node_name(i) != "Camera3D":
			continue
		var properties := {}
		for p in state.get_node_property_count(i):
			properties[state.get_node_property_name(i, p)] = state.get_node_property_value(i, p)
		found = true
		assert(properties.get("fov", 75.0) == 90.0, "the FOV is not 90")
		assert(properties.get("keep_aspect", 1) == Camera3D.KEEP_WIDTH,
			"with KEEP_HEIGHT, the FOV would be vertical and produce 107 horizontal degrees")
		print("camera: horizontal FOV=%.0f (Teardown: 90)" % properties.fov)
	assert(found, "camera not found in main.tscn")


func _climb(riser: float) -> Dictionary:
	var world := Node3D.new()
	root.add_child(world)
	var stairs := StaticBody3D.new()
	world.add_child(stairs)
	# Generous ground plus the stairs; each step is a solid box extending to the ground.
	var ground := CollisionShape3D.new()
	var ground_box := BoxShape3D.new()
	ground_box.size = Vector3(20.0, 1.0, 20.0)
	ground.shape = ground_box
	ground.position = Vector3(0.0, -0.5, 0.0)
	stairs.add_child(ground)
	for i in STEPS:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var height := riser * (i + 1)
		box.size = Vector3(4.0, height, TREAD)
		shape.shape = box
		shape.position = Vector3(0.0, height * 0.5, -1.0 - TREAD * i)
		stairs.add_child(shape)

	var player: CharacterBody3D = load("res://scripts/core/player.gd").new()
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	collision.shape = capsule
	collision.position = Vector3(0.0, 0.9, 0.0)
	player.add_child(collision)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0.0, 1.65, 0.0)
	player.add_child(camera)
	world.add_child(player)
	player.global_position = Vector3(0.0, 0.1, 0.5)

	Input.action_press("move_forward")
	var highest := 0.0
	for frame in int(SECONDS * 60.0):
		await physics_frame
		highest = maxf(highest, player.global_position.y)
	Input.action_release("move_forward")
	var result := {"riser": riser, "expected": riser * STEPS, "reached": highest}
	world.queue_free()
	await physics_frame
	return result
