extends SceneTree
## Reproduce Lee's full startup and audit two invariants surfaced by the HUD:
## collision revisions must be consistent, and authored props must sleep after import completes.
## Keep this as a regression test because both failures cost FPS from the first frame.

var MAP := VoxelProjectPaths.teardown_map_path()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	root.add_child(world)
	var report := TeardownMapImporter.import_map(
		world, MAP, Vector3.INF, INF, Vector3.ZERO, true
	)
	print("STARTUP_REPORT ", JSON.stringify({
		"bodies": report.get("bodies", 0),
		"dynamic": report.get("imported_dynamic_bodies", 0),
		"shapes": report.get("shapes", 0),
		"cache": report.get("cache_status", ""),
	}))
	_dump(world, 0)
	for frame in 35:
		await physics_frame
		if frame in [0, 1, 2, 4, 9, 19, 34]:
			_dump(world, frame + 1)
	var final_metrics := world.get_metrics()
	var final_coherence := world.get_physics_coherence_snapshot()
	var final_actual_awake := 0
	for body: VoxelBody3D in world.get_dynamic_bodies():
		final_actual_awake += int(body.is_awake())
	var passed := int(final_metrics.get("awake_bodies", -1)) == final_actual_awake \
		and final_actual_awake == 0 \
		and int(final_metrics.get("awake_compound_boxes", -1)) == 0 \
		and String(final_coherence.get("status", "DESYNC")) != "DESYNC"
	print("STARTUP_PHYSICS_STATE_%s registry=%s actual=%d coherence=%s" % [
		"OK" if passed else "FAIL",
		final_metrics.get("awake_bodies", -1), final_actual_awake,
		final_coherence.get("status", "DESYNC"),
	])
	quit(0 if passed else 1)


func _dump(world: VoxelWorld3D, frame: int) -> void:
	var metrics := world.get_metrics()
	var coherence := world.get_physics_coherence_snapshot()
	var actual_awake := 0
	var vehicles_awake := 0
	for body: VoxelBody3D in world.get_dynamic_bodies():
		if not body.is_awake():
			continue
		actual_awake += 1
		if body.has_meta("teardown_vehicle"):
			vehicles_awake += 1
	var detail := {}
	if coherence.get("status") == "DESYNC":
		var shape := instance_from_id(int(coherence.get("shape", 0))) as VoxelShape3D
		var body := instance_from_id(int(coherence.get("body", 0))) as VoxelBody3D
		if shape != null and body != null:
			detail = {
				"body_name": body.name,
				"body_state": body.state,
				"body_awake": body.is_awake(),
				"collision_enabled": body.collision_enabled,
				"collision_revision_direct": body.get_collision_revision(shape),
				"source": shape.get_meta("teardown_source", ""),
				"attributes": shape.get_meta("teardown_attributes", {}),
				"body_attributes": body.get_meta("teardown_body_attributes", {}),
				"voxel_count": shape.voxel_count(),
				"collision_nodes": body._collision_nodes.size(),
			}
	print("STARTUP_STATE ", JSON.stringify({
		"frame": frame,
		"awake_registry": metrics.get("awake_bodies", -1),
		"awake_actual": actual_awake,
		"vehicles_awake": vehicles_awake,
		"active_boxes": metrics.get("awake_compound_boxes", -1),
		"coherence": coherence,
		"detail": detail,
	}))
