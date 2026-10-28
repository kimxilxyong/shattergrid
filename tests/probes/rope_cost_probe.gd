extends SceneTree
## Cost of Lee's cables while stationary (their usual state) and with all of them awake
## simultaneously, which is the worst imaginable case and never occurs.
var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)
	var started := Time.get_ticks_usec()
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)
	var import_ms := (Time.get_ticks_usec() - started) / 1000.0
	var ropes := world.get_node_or_null("TeardownRopes") as VoxelRopes
	if ropes == null:
		print("no cables")
		quit(1)
		return
	print("%d spans, imported with the map in %.0f ms" % [ropes.span_count(), import_ms])

	# Stationary: only the `if` checking for awake spans runs.
	for _frame in 10:
		await physics_frame
	print("awake at rest: %d" % ropes.awake_count())
	var quiet := Time.get_ticks_usec()
	for _step in 600:
		ropes._physics_process(1.0 / 60.0)
	print("  stationary  %.4f ms per frame" % ((Time.get_ticks_usec() - quiet) / 1000.0 / 600.0))

	# Worst case: all 79 spans active, simulating and rebuilding the mesh every frame.
	# Actually push them: marking them awake without movement put them to sleep after 20 frames, making
	# the measurement false (cheaper than the real case of four oscillating cables).
	ropes.force_all_awake_for_probe(Vector3(0.0, 0.0, 0.02))
	var busy := Time.get_ticks_usec()
	for _step in 120:
		ropes._physics_process(1.0 / 60.0)
	print("  all active   %.4f ms per frame  (%d points, %d iterations)" % [
		(Time.get_ticks_usec() - busy) / 1000.0 / 120.0,
		ropes.span_count() * (VoxelRopes.SEGMENTS + 1), VoxelRopes.ITERATIONS])

	# What actually happens: an explosion in the middle of the map.
	ropes.sleep_all_for_probe()
	var spawn := Vector3(-64.4, 3.0, -81.0)
	ropes.on_impact(spawn, 1.0)
	print("  one explosion wakes %d of %d spans" % [ropes.awake_count(), ropes.span_count()])
	var shot := Time.get_ticks_usec()
	for _step in 60:
		ropes._physics_process(1.0 / 60.0)
	print("  after the shot %.4f ms per frame" % ((Time.get_ticks_usec() - shot) / 1000.0 / 60.0))
	quit()
