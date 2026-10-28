extends SceneTree
## Measure the same import twice in separate processes:
##
## godot --headless --path . -s tests/compiled_map_cache_probe.gd -- --rebuild-teardown-cache
## godot --headless --path . -s tests/compiled_map_cache_probe.gd

var MAP := VoxelProjectPaths.teardown_map_path()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	root.add_child(world)
	var started := Time.get_ticks_msec()
	var report := TeardownMapImporter.import_map(
		world, MAP, Vector3.INF, INF, Vector3.ZERO, true
	)
	var elapsed := Time.get_ticks_msec() - started
	var collision_shapes := 0
	for body: VoxelBody3D in get_nodes_in_group(VoxelBody3D.GROUP):
		collision_shapes += body._collision_nodes.size()
	var cache_status := String(report.get("cache_status", ""))
	var metrics := world.get_metrics()
	var pending_before_stream := int(metrics.get("pending_baked_collision_blocks", 0))
	var coherence_started := Time.get_ticks_usec()
	for _sample in 200:
		world.get_physics_coherence_snapshot()
	var coherence_average_us := (Time.get_ticks_usec() - coherence_started) / 200.0
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 10.0, 0.0)
	camera.current = true
	world.add_child(camera)
	# A warm load must return control without inserting all collision into Jolt. Then, the per-frame
	# budget must make real progress around the camera.
	for frame in 6:
		await process_frame
	var pending_after_stream := int(
		world.get_metrics().get("pending_baked_collision_blocks", 0)
	)
	var streaming_progressed := cache_status != "hit" \
		or pending_after_stream < pending_before_stream
	var collision_ready := collision_shapes > 30000 if cache_status == "built" \
		else collision_shapes >= int(report.get("cache_prime_blocks", 0)) \
			and int(metrics.get("pending_baked_collision_blocks", 0)) > 0
	var passed := int(report.get("shapes", 0)) > 2000 \
		and int(report.get("joints", 0)) > 400 \
		and collision_ready and streaming_progressed \
		and cache_status in ["built", "hit"]
	print("COMPILED_MAP_CACHE_PROBE ", JSON.stringify({
		"elapsed_ms": elapsed,
		"cache_status": report.get("cache_status", ""),
		"cache_load_ms": report.get("cache_load_ms", 0),
		"cache_save_ms": report.get("cache_save_ms", 0),
		"cache_bytes": report.get("cache_bytes", 0),
		"cache_face_blocks": report.get("cache_face_blocks", 0),
		"cache_prime_ms": report.get("cache_prime_ms", 0),
		"cache_prime_blocks": report.get("cache_prime_blocks", 0),
		"cache_pending_blocks": pending_before_stream,
		"cache_pending_after_6_frames": pending_after_stream,
		"coherence_average_us": snappedf(coherence_average_us, 0.001),
		"collision_ms": report.get("collision_ms", 0),
		"faces_ms": report.get("faces_ms", 0),
		"collision_shapes": collision_shapes,
		"bodies": report.get("bodies", 0),
		"shapes": report.get("shapes", 0),
		"joints": report.get("joints", 0),
		"ropes": report.get("ropes", 0),
		"pass": passed,
	}))
	quit(0 if passed else 1)
