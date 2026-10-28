extends SceneTree
## Why the game stutters while the GPU is at 10%: measure CPU frame cost with the full map loaded
## and the player moving. This measures the shadow clipmap's `_process`, the only part that responds
## to camera movement.

var XML := VoxelProjectPaths.teardown_map_path()
const FRAMES := 30
const SPEED := 5.5


func _initialize() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	var started := Time.get_ticks_msec()
	var report: Dictionary = TeardownMapImporter.import_map(
		world, XML, Vector3.INF, INF, Vector3.ZERO, true
	)
	print("importar %d ms" % (Time.get_ticks_msec() - started))

	var camera := Camera3D.new()
	root.add_child(camera)
	camera.global_position = report.get("drop_in", Vector3.ZERO)

	var clipmaps := VoxelShadowClipmaps.new()
	root.add_child(clipmaps)
	started = Time.get_ticks_msec()
	if not clipmaps.setup(world, camera):
		print("no RenderingDevice: cannot measure")
		quit()
		return
	print("initial clipmap %d ms" % (Time.get_ticks_msec() - started))

	var shapes_started := Time.get_ticks_usec()
	var shapes: Array = clipmaps.call("_all_shapes")
	var shapes_ms := (Time.get_ticks_usec() - shapes_started) / 1000.0
	print("_all_shapes(): %d shapes en %.2f ms" % [shapes.size(), shapes_ms])

	var total := 0.0
	var worst := 0.0
	for frame in FRAMES:
		camera.global_position += Vector3.FORWARD * SPEED / 60.0
		var frame_started := Time.get_ticks_usec()
		clipmaps._process(1.0 / 60.0)
		var frame_ms := (Time.get_ticks_usec() - frame_started) / 1000.0
		total += frame_ms
		worst = maxf(worst, frame_ms)
	print("clipmap per moving frame: avg %.1f ms  worst %.1f ms  -> %.0f fps ceiling"
		% [total / FRAMES, worst, 1000.0 / maxf(total / FRAMES, 0.001)])
	quit()
