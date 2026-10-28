class_name MainDiagnostics
extends Node
## Captures, visual tests, and benchmarks activated from the command line. None of these paths
## are not part of the normal game loop; they live outside `main.gd` so the bootstrap does not load
## hundreds of lines of instrumentation.

var _world: VoxelWorld3D
var _renderer: VoxelRenderSystem
var _player: CharacterBody3D
var _hud: CanvasLayer

var _benchmark_gpu := PackedFloat64Array()
var _benchmark_cpu := PackedFloat64Array()
var _benchmark_frame_times := PackedFloat64Array()
var _benchmark_process_times := PackedFloat64Array()
var _benchmark_physics_times := PackedFloat64Array()
var _benchmark_physics_active := PackedFloat64Array()
var _benchmark_physics_pairs := PackedFloat64Array()
var _benchmark_physics_islands := PackedFloat64Array()
var _benchmark_frame := 0
var _walk_frame_times := PackedFloat64Array()
var _walk_upload_bytes := PackedFloat64Array()
var _walk_allocate_times := PackedFloat64Array()
var _walk_raster_times := PackedFloat64Array()
var _walk_region_upload_times := PackedFloat64Array()
var _destruction_frame := 0
var _destruction_frame_times := PackedFloat64Array()
var _destruction_impact_frame_times := PackedFloat64Array()
var _destruction_call_times := PackedFloat64Array()
var _destruction_impact_window := 0
var _destruction_impacts := 0
var _destruction_removed := 0
var _destruction_particles_peak := 0
var _destruction_gpu_times := PackedFloat64Array()
var _destruction_cpu_times := PackedFloat64Array()
var _destruction_transform_sync_times := PackedFloat64Array()
var _destruction_metadata_sync_times := PackedFloat64Array()
var _destruction_collision_flush_times := PackedFloat64Array()

var _benchmark_main := false
var _benchmark_walk := false
var _benchmark_destruction := false


func setup(
	world: VoxelWorld3D, renderer: VoxelRenderSystem, player: CharacterBody3D, hud: CanvasLayer
) -> void:
	_world = world
	_renderer = renderer
	_player = player
	_hud = hud
	var arguments := OS.get_cmdline_user_args()
	_benchmark_main = "--benchmark-main" in arguments
	_benchmark_walk = "--benchmark-walk" in arguments
	_benchmark_destruction = "--benchmark-destruction" in arguments \
		or "--benchmark-destruction-no-particles" in arguments \
		or "--benchmark-destruction-no-uploads" in arguments
	if _benchmark_main or _benchmark_walk or _benchmark_destruction:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0 if "--benchmark-uncapped" in arguments else 60
	if _benchmark_main or _benchmark_destruction:
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if "--benchmark-destruction-no-particles" in arguments:
		_world.impact_particles_enabled = false
	if "--benchmark-destruction-no-uploads" in arguments:
		_world.impact_particles_enabled = false
		_renderer.damage_uploads_enabled = false
		_renderer.shadow_clipmaps.damage_updates_enabled = false

	if "--capture" in arguments:
		capture_migrated_scene.call_deferred()
	if "--visibility-capture" in arguments:
		capture_map_visibility.call_deferred()
	if "--water-capture" in arguments:
		capture_water.call_deferred()
	if "--clipmap-test" in arguments:
		test_clipmaps.call_deferred()
	if "--damage-capture" in arguments:
		capture_damage.call_deferred()
	if "--local-shadow-test" in arguments:
		test_local_shadows.call_deferred()
	set_process(_benchmark_main or _benchmark_walk or _benchmark_destruction)


func _process(delta: float) -> void:
	if _benchmark_main:
		_tick_main_benchmark(delta)
	if _benchmark_walk:
		_tick_walk_benchmark(delta)
	if _benchmark_destruction:
		_tick_destruction_benchmark(delta)


func _tick_main_benchmark(delta: float) -> void:
	_benchmark_frame += 1
	if _benchmark_frame >= 120 and _benchmark_frame < 420:
		var viewport_rid := get_viewport().get_viewport_rid()
		_benchmark_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid))
		_benchmark_cpu.append(
			RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
				+ RenderingServer.get_frame_setup_time_cpu()
		)
		_benchmark_frame_times.append(delta * 1000.0)
		_benchmark_process_times.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		_benchmark_physics_times.append(
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		)
		_benchmark_physics_active.append(
			PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ACTIVE_OBJECTS)
		)
		_benchmark_physics_pairs.append(
			PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_COLLISION_PAIRS)
		)
		_benchmark_physics_islands.append(
			PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ISLAND_COUNT)
		)
	elif _benchmark_frame == 420:
		_finish_main_benchmark.call_deferred()


func _tick_walk_benchmark(delta: float) -> void:
	_benchmark_frame += 1
	if _benchmark_frame >= 60 and _benchmark_frame < 360:
		_player.global_position.x += 0.08
		_walk_frame_times.append(delta * 1000.0)
		_walk_upload_bytes.append(_renderer.shadow_clipmaps.last_upload_bytes)
		_walk_allocate_times.append(_renderer.shadow_clipmaps.last_region_allocate_ms)
		_walk_raster_times.append(_renderer.shadow_clipmaps.last_region_raster_ms)
		_walk_region_upload_times.append(_renderer.shadow_clipmaps.last_region_upload_ms)
	elif _benchmark_frame == 360:
		_finish_walk_benchmark.call_deferred()


func _tick_destruction_benchmark(delta: float) -> void:
	_destruction_frame += 1
	if _destruction_frame >= 90 and _destruction_frame < 330:
		var frame_ms := delta * 1000.0
		_destruction_frame_times.append(frame_ms)
		var viewport_rid := get_viewport().get_viewport_rid()
		_destruction_gpu_times.append(
			RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
		)
		_destruction_cpu_times.append(
			RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
				+ RenderingServer.get_frame_setup_time_cpu()
		)
		_destruction_transform_sync_times.append(_renderer.last_transform_sync_ms)
		_destruction_metadata_sync_times.append(_renderer.last_metadata_sync_ms)
		_destruction_collision_flush_times.append(_world.collision_rebuild_ms)
		if _destruction_impact_window > 0:
			_destruction_impact_frame_times.append(frame_ms)
			_destruction_impact_window -= 1
		var metrics := _world.get_metrics()
		_destruction_particles_peak = maxi(
			_destruction_particles_peak, int(metrics.active_particles)
		)
		if _destruction_frame <= 222 and (_destruction_frame - 90) % 12 == 0:
			_run_benchmark_impact()
	elif _destruction_frame == 330:
		_finish_destruction_benchmark.call_deferred()


func capture_migrated_scene() -> void:
	var warmup_frames := 12 if "--capture-fast" in OS.get_cmdline_user_args() else 180
	for _frame in warmup_frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("res://benchmark/main_migrated.png")
	var error := get_viewport().get_texture().get_image().save_png(path)
	print("VOXEL_MAIN_CAPTURE path=%s error=%s metrics=%s" % [
		path, error, JSON.stringify(_world.get_metrics())
	])
	get_tree().quit(0 if error == OK else 20)


func capture_water() -> void:
	var water := _world.get_node_or_null("TeardownWater") as VoxelWaterSystem
	if water == null or water.get_surface_count_imported() == 0:
		push_error("--water-capture: the map has no water surfaces")
		get_tree().quit(23)
		return
	var water_bounds := water.get_smallest_surface_bounds()
	var target := water_bounds.get_center()
	var camera := _player.get_node("Camera3D") as Camera3D
	_hud.visible = false
	_world.show_diagnostics = false
	_player.set_process(false)
	_player.set_physics_process(false)
	var shore_distance := water_bounds.size.z * 0.5 + maxf(3.5, water_bounds.size.z * 0.12)
	var camera_height := clampf(maxf(water_bounds.size.x, water_bounds.size.z) * 0.13, 2.8, 5.5)
	camera.global_position = target + Vector3(0.0, camera_height, shore_distance)
	camera.look_at(target + Vector3(0.0, 0.08, 0.0))
	for _frame in 45:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var capture_name := "water_lee_no_reflections.png" \
		if "--water-no-reflections" in OS.get_cmdline_user_args() else "water_lee.png"
	var path := ProjectSettings.globalize_path("res://benchmark/" + capture_name)
	var error := get_viewport().get_texture().get_image().save_png(path)
	print("VOXEL_WATER_CAPTURE path=%s target=%s error=%s surfaces=%d triangles=%d" % [
		path, target, error, water.get_surface_count_imported(), water.get_triangle_count(),
	])
	get_tree().quit(0 if error == OK else 24)


func capture_map_visibility() -> void:
	for _frame in 4:
		await get_tree().process_frame
	var best_shape: VoxelShape3D = null
	var best_distance := INF
	for body: VoxelBody3D in get_tree().get_nodes_in_group(VoxelBody3D.GROUP):
		for shape in body.get_shapes():
			var distance := shape.world_bounds().get_center().distance_squared_to(Vector3.ZERO)
			if distance < best_distance:
				best_distance = distance
				best_shape = shape
	if best_shape == null:
		get_tree().quit(21)
		return
	var target := best_shape.world_bounds().get_center()
	var camera := _player.get_node("Camera3D") as Camera3D
	_player.set_process(false)
	_player.set_physics_process(false)
	camera.global_position = target + Vector3(0.0, 3.0, 9.0)
	camera.look_at(target)
	for _frame in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("res://benchmark/map_visibility.png")
	var error := get_viewport().get_texture().get_image().save_png(path)
	print("VOXEL_VISIBILITY_CAPTURE path=%s shape=%s error=%s" % [
		path, best_shape.name, error,
	])
	get_tree().quit(0 if error == OK else 22)


func _finish_main_benchmark() -> void:
	var gpu_p95 := percentile(_benchmark_gpu, 0.95)
	var frame_p95 := percentile(_benchmark_frame_times, 0.95)
	var result := {
		"resolution": get_viewport().get_visible_rect().size,
		"render_scale": get_viewport().scaling_3d_scale,
		"gpu_median_ms": snappedf(percentile(_benchmark_gpu, 0.5), 0.001),
		"gpu_p95_ms": snappedf(gpu_p95, 0.001),
		"cpu_render_median_ms": snappedf(percentile(_benchmark_cpu, 0.5), 0.001),
		"process_median_ms": snappedf(percentile(_benchmark_process_times, 0.5), 0.001),
		"process_p95_ms": snappedf(percentile(_benchmark_process_times, 0.95), 0.001),
		"physics_median_ms": snappedf(percentile(_benchmark_physics_times, 0.5), 0.001),
		"physics_p95_ms": snappedf(percentile(_benchmark_physics_times, 0.95), 0.001),
		"physics_active_median": int(percentile(_benchmark_physics_active, 0.5)),
		"physics_active_max": int(percentile(_benchmark_physics_active, 1.0)),
		"physics_pairs_median": int(percentile(_benchmark_physics_pairs, 0.5)),
		"physics_pairs_max": int(percentile(_benchmark_physics_pairs, 1.0)),
		"physics_islands_median": int(percentile(_benchmark_physics_islands, 0.5)),
		"physics_islands_max": int(percentile(_benchmark_physics_islands, 1.0)),
		"frame_median_ms": snappedf(percentile(_benchmark_frame_times, 0.5), 0.001),
		"frame_p95_ms": snappedf(frame_p95, 0.001),
		"voxel_count": total_voxel_count(),
		"clipmap_memory_bytes": _renderer.shadow_clipmaps.total_memory_bytes,
		"pass": gpu_p95 <= 16.7 and frame_p95 <= 16.7,
	}
	print("VOXEL_MAIN_BENCHMARK_RESULT ", JSON.stringify(result))
	get_tree().quit(0 if result.pass else 30)


func _finish_walk_benchmark() -> void:
	var result := {
		"distance_m": 24.0,
		"frame_median_ms": snappedf(percentile(_walk_frame_times, 0.5), 0.001),
		"frame_p95_ms": snappedf(percentile(_walk_frame_times, 0.95), 0.001),
		"frame_max_ms": snappedf(percentile(_walk_frame_times, 1.0), 0.001),
		"upload_p95_bytes": int(percentile(_walk_upload_bytes, 0.95)),
		"allocate_p95_ms": snappedf(percentile(_walk_allocate_times, 0.95), 0.001),
		"raster_p95_ms": snappedf(percentile(_walk_raster_times, 0.95), 0.001),
		"region_upload_p95_ms": snappedf(percentile(_walk_region_upload_times, 0.95), 0.001),
	}
	result["pass"] = result.frame_p95_ms <= 16.7 and result.frame_max_ms <= 33.3
	print("VOXEL_WALK_BENCHMARK_RESULT ", JSON.stringify(result))
	get_tree().quit(0 if result.pass else 80)


func _run_benchmark_impact() -> void:
	var bodies := get_tree().get_nodes_in_group(VoxelBody3D.GROUP)
	if bodies.is_empty():
		return
	var body := bodies[_destruction_impacts % bodies.size()] as VoxelBody3D
	var shapes := body.get_shapes()
	if shapes.is_empty():
		return
	var shape := shapes[_destruction_impacts % shapes.size()]
	var live := shape.data.get_live_indices()
	if live.is_empty():
		return
	var fraction := float((_destruction_impacts * 37) % 89 + 5) / 100.0
	var voxel_index := live[clampi(int(live.size() * fraction), 0, live.size() - 1)]
	var target := shape.voxel_center_world(voxel_index)
	var started := Time.get_ticks_usec()
	var affected := _world.damage_sphere(target, 0.72, 10.0)
	var call_ms := (Time.get_ticks_usec() - started) / 1000.0
	_destruction_call_times.append(call_ms)
	var profile := _world.get_metrics()
	print("SHATTERGRID_IMPACT_PROFILE ", JSON.stringify({
		"body": body.name,
		"dimensions": shape.data.get_dimensions(),
		"call_ms": snappedf(call_ms, 0.001),
		"query_ms": snappedf(float(profile.damage_query_ms), 0.001),
		"native_ms": snappedf(float(profile.damage_native_ms), 0.001),
		"notify_ms": snappedf(float(profile.damage_notify_ms), 0.001),
		"particles_ms": snappedf(float(profile.damage_particles_ms), 0.001),
		"split_ms": snappedf(float(profile.damage_split_ms), 0.001),
		"connectivity_ms": snappedf(float(profile.damage_connectivity_ms), 0.001),
		"external_support_ms": snappedf(float(profile.damage_external_support_ms), 0.001),
		"component_fill_ms": snappedf(float(profile.damage_component_fill_ms), 0.001),
		"support_contacts_ms": snappedf(float(profile.damage_support_contacts_ms), 0.001),
		"support_routes_ms": snappedf(float(profile.damage_support_routes_ms), 0.001),
		"support_seed_ms": snappedf(float(profile.damage_support_seed_ms), 0.001),
		"support_search_ms": snappedf(float(profile.support_search_ms), 0.001),
		"support_touch_ms": snappedf(float(profile.support_touch_ms), 0.001),
		"support_grid_ms": snappedf(float(profile.support_grid_ms), 0.001),
		"support_touch_calls": int(profile.support_touch_calls),
		"support_nodes": int(profile.support_nodes),
		"support_candidates": int(profile.support_candidates),
		"fragment_ms": snappedf(float(profile.damage_fragment_ms), 0.001),
		"connectivity_guard_ms": snappedf(float(profile.damage_connectivity_guard_ms), 0.001),
		"connectivity_skipped": int(profile.connectivity_skipped),
		"impulse_ms": snappedf(float(profile.damage_impulse_ms), 0.001),
		"budget_ms": snappedf(float(profile.damage_budget_ms), 0.001),
		"clipmap_ms": snappedf(_renderer.shadow_clipmaps.last_damage_update_ms, 0.001),
		"atlas_ms": snappedf(_renderer.last_damage_update_ms, 0.001),
		"collision_ms": snappedf(body.collision_rebuild_ms, 0.001),
		"pending_collision_rebuilds": int(profile.pending_collision_rebuilds),
	}))
	if not affected.is_empty():
		_destruction_impacts += 1
		for record: Dictionary in affected:
			_destruction_removed += int((record.damage as Dictionary).get("removed", 0))
		_destruction_impact_window = 4


func _finish_destruction_benchmark() -> void:
	var frame_max := percentile(_destruction_frame_times, 1.0)
	var impact_p95 := percentile(_destruction_impact_frame_times, 0.95)
	var call_p95 := percentile(_destruction_call_times, 0.95)
	var metrics := _world.get_metrics()
	var result := {
		"impacts": _destruction_impacts,
		"removed_voxels": _destruction_removed,
		"particles_peak": _destruction_particles_peak,
		"frame_median_ms": snappedf(percentile(_destruction_frame_times, 0.5), 0.001),
		"frame_p95_ms": snappedf(percentile(_destruction_frame_times, 0.95), 0.001),
		"frame_max_ms": snappedf(frame_max, 0.001),
		"impact_window_p95_ms": snappedf(impact_p95, 0.001),
		"damage_call_p95_ms": snappedf(call_p95, 0.001),
		"gpu_p95_ms": snappedf(percentile(_destruction_gpu_times, 0.95), 0.001),
		"gpu_max_ms": snappedf(percentile(_destruction_gpu_times, 1.0), 0.001),
		"cpu_render_p95_ms": snappedf(percentile(_destruction_cpu_times, 0.95), 0.001),
		"transform_sync_p95_ms": snappedf(percentile(_destruction_transform_sync_times, 0.95), 0.001),
		"transform_sync_max_ms": snappedf(percentile(_destruction_transform_sync_times, 1.0), 0.001),
		"metadata_sync_max_ms": snappedf(percentile(_destruction_metadata_sync_times, 1.0), 0.001),
		"metadata_fallback_reason": _renderer.last_metadata_fallback_reason,
		"renderer_coherence": _renderer.get_coherence_snapshot(),
		"collision_flush_p95_ms": snappedf(percentile(_destruction_collision_flush_times, 0.95), 0.001),
		"collision_flush_max_ms": snappedf(percentile(_destruction_collision_flush_times, 1.0), 0.001),
		"awake_bodies": int(metrics.awake_bodies),
		"awake_compound_boxes": int(metrics.awake_compound_boxes),
		"total_compound_boxes": int(metrics.compound_boxes),
	}
	result["pass"] = _destruction_impacts >= 8 and _destruction_removed > 0 \
		and _destruction_particles_peak > 0 and impact_p95 <= 33.3 \
		and frame_max <= 66.7 and call_p95 <= 33.3
	print("SHATTERGRID_BENCHMARK_RESULT ", JSON.stringify(result))
	get_tree().quit(0 if result.pass else 81)


static func percentile(source: PackedFloat64Array, fraction: float) -> float:
	if source.is_empty():
		return 0.0
	var sorted := Array(source)
	sorted.sort()
	return float(sorted[clampi(ceili((sorted.size() - 1) * fraction), 0, sorted.size() - 1)])


func total_voxel_count() -> int:
	var total := 0
	for body: VoxelBody3D in get_tree().get_nodes_in_group(VoxelBody3D.GROUP):
		total += body.get_total_voxels()
	return total


func test_clipmaps() -> void:
	var clipmaps := _renderer.shadow_clipmaps
	for _frame in 3:
		await get_tree().process_frame
	var first_body := get_tree().get_nodes_in_group(VoxelBody3D.GROUP)[0] as VoxelBody3D
	var first_shape := first_body.get_shapes()[0]
	var live := first_shape.data.get_live_indices()
	var damage_center := first_shape.voxel_center_world(live[live.size() / 2])
	_world.damage_sphere(damage_center, 0.25, 20.0)
	var damage_bytes := clipmaps.last_damage_upload_bytes
	var passed := damage_bytes > 0 and damage_bytes < clipmaps.total_memory_bytes
	print("VOXEL_CLIPMAP_TEST_RESULT ", JSON.stringify({
		"damage_upload_bytes": damage_bytes,
		"full_memory_bytes": clipmaps.total_memory_bytes,
		"pass": passed,
	}))
	get_tree().quit(0 if passed else 40)


func capture_damage() -> void:
	for _frame in 90:
		await get_tree().process_frame
	var camera := _player.get_node("Camera3D") as Camera3D
	var target_body := get_tree().get_nodes_in_group(VoxelBody3D.GROUP)[0] as VoxelBody3D
	var target_shape := target_body.get_shapes()[0]
	var live := target_shape.data.get_live_indices()
	var target := target_shape.voxel_center_world(live[live.size() / 2])
	camera.global_position = target + Vector3(0, 2.5, 12.0)
	camera.look_at(target)
	var affected := _world.damage_sphere(target, 1.0, 20.0)
	for _frame in 18:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("res://benchmark/main_damage.png")
	var error := get_viewport().get_texture().get_image().save_png(path)
	var metrics := _world.get_metrics()
	print("VOXEL_DAMAGE_CAPTURE affected=%d bodies=%d particles=%d active=%d error=%s" % [
		affected.size(), get_tree().get_nodes_in_group(VoxelBody3D.GROUP).size(),
		int(metrics.impact_particles), int(metrics.active_particles), error,
	])
	get_tree().quit(0 if error == OK and not affected.is_empty() \
		and int(metrics.impact_particles) > 0 and int(metrics.active_particles) > 0 else 51)


func test_local_shadows() -> void:
	for index in 9:
		var light := OmniLight3D.new()
		light.position = Vector3(-20.0 + index * 5.0, 3.0, 3.0)
		light.omni_range = 14.0
		light.light_color = Color(1.0, 0.55, 0.25)
		light.light_energy = 2.0
		light.shadow_enabled = false
		add_child(light)
		light.add_to_group("voxel_shadow_lights")
	for _frame in 8:
		await get_tree().process_frame
	var pool := _renderer.local_shadow_pool
	var textures := pool.get_texture_rids()
	var metadata := pool.get_shader_metadata()
	var passed := textures.size() == VoxelLocalShadowPool.MAX_VOLUMES \
		and textures.all(func(texture: RID) -> bool: return texture.is_valid()) \
		and int(metadata[VoxelLocalShadowPool.MAX_LIGHTS * 16]) == 9 \
		and int(metadata[VoxelLocalShadowPool.MAX_LIGHTS * 16 + 1]) \
			== VoxelLocalShadowPool.MAX_VOLUMES
	print("VOXEL_LOCAL_SHADOW_TEST_RESULT ", JSON.stringify({
		"lights": 9,
		"active_volumes": textures.size(),
		"logical_resolution": VoxelLocalShadowPool.LOGICAL_RESOLUTION,
		"packed_resolution": VoxelLocalShadowPool.PACKED_RESOLUTION,
		"pass": passed,
	}))
	get_tree().quit(0 if passed else 60)
