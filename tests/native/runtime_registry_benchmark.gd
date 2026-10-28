extends SceneTree
## Scale test for Lee's map without paying import costs: 2,252 Shapes and pending baked work.


func _init() -> void:
	var registry := VoxelRuntimeRegistry.new()
	var data := VoxelShapeData.new()
	for body_id in 2214:
		registry.upsert_body(body_id + 1, true, body_id < 7, true, false, 6, 100, body_id)
	for shape_index in 2252:
		var shape_id := 10_000 + shape_index
		registry.upsert_shape(
			shape_id, data, 1 + shape_index % 2214, 0, 0, -1, true, false, false
		)
		registry.set_baked_collision_pending(shape_id, true)
	var coherence_started := Time.get_ticks_usec()
	for _sample in 2000:
		registry.get_coherence_snapshot()
	var coherence_average_us := (Time.get_ticks_usec() - coherence_started) / 2000.0
	var metrics_started := Time.get_ticks_usec()
	for _sample in 100_000:
		registry.get_metrics()
	var metrics_average_us := (Time.get_ticks_usec() - metrics_started) / 100_000.0
	print("VOXEL_RUNTIME_REGISTRY_BENCHMARK ", JSON.stringify({
		"shapes": 2252,
		"bodies": 2214,
		"coherence_average_us": snappedf(coherence_average_us, 0.001),
		"metrics_average_us": snappedf(metrics_average_us, 0.001),
	}))
	quit(0)
