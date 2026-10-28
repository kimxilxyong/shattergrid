extends SceneTree
## Verify that joint breakage works on Lee's real data, not only in the synthetic test.
var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)
	var joints := world.get_node_or_null("TeardownJoints") as VoxelJoints
	if joints == null:
		print("no joint node")
		quit(1)
		return
	print("registered joints %d, live %d" % [joints.count(), joints.live_count()])
	for _frame in 20:
		await physics_frame

	# Pipe spans are at (4.2, 6.4, -19..-41). Fire along that line.
	var before := joints.live_count()
	var awake_before := world.awake_bodies
	for z in [-19.1, -23.1, -27.1, -31.0, -35.0]:
		world.damage_sphere(Vector3(4.22, 6.4, z), 1.5, 40.0)
	for _frame in 20:
		await physics_frame
	world._update_metrics()
	print("after five shots at the pipe: live %d (broken %d), awake %d -> %d" % [
		joints.live_count(), before - joints.live_count(), awake_before, world.awake_bodies])
	quit(0 if joints.live_count() < before else 1)
