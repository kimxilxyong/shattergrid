extends Node3D
## Renderer feasibility gate for the dedicated RenderingDevice DDA path.
##
## Run interactively:
##   godot --path . res://prototype/dda_dedicated/dedicated_dda_prototype.tscn
## Run the repeatable gate:
##   godot --path . res://prototype/dda_dedicated/dedicated_dda_prototype.tscn -- --benchmark

const VOXEL_SIZE := 0.1
const VOLUME_SIZE := 64
const INSTANCE_COUNT := 200
const VOXEL_WARMUP_FRAMES := 120
const VOXEL_SAMPLE_FRAMES := 300
const BASELINE_WARMUP_FRAMES := 30
const BASELINE_SAMPLE_FRAMES := 120

var _shape: VoxelShapeData
var _atlas := preload("res://prototype/dda_dedicated/voxel_atlas_3d.gd").new()
var _macro_atlas := preload("res://prototype/dda_dedicated/voxel_atlas_3d.gd").new()
var _effect: DedicatedVoxelDDAEffect
var _compositor: Compositor
var _camera: Camera3D
var _status: Label
var _benchmark := false
var _inside := false
var _phase := "outside_voxel"
var _phase_frame := 0
var _finishing := false
var _damage_result := {}
var _damage_cpu_ms := 0.0
var _outside_gpu := PackedFloat64Array()
var _outside_cpu := PackedFloat64Array()
var _outside_baseline_gpu := PackedFloat64Array()
var _inside_gpu := PackedFloat64Array()
var _inside_cpu := PackedFloat64Array()
var _inside_baseline_gpu := PackedFloat64Array()
var _resize_tested := false


func _ready() -> void:
	_benchmark = "--benchmark" in OS.get_cmdline_user_args()
	if RenderingServer.get_current_rendering_method() != "forward_plus":
		push_error("Dedicated DDA prototype requires Forward+")
		get_tree().quit(2)
		return
	_create_world()
	_shape = VoxelShapeData.new()
	_shape.generate_prototype(VOLUME_SIZE)
	var native_test: Dictionary = _shape.self_test()
	if not native_test.get("ok", false):
		push_error("Native voxel storage failed its invariant check: %s" % native_test)
		get_tree().quit(3)
		return
	if not _atlas.create(_shape.get_dimensions(), _shape.get_cells(), true):
		get_tree().quit(4)
		return
	if not _macro_atlas.create(
		_shape.get_macro_dimensions(), _shape.get_macro_occupancy(), true
	):
		get_tree().quit(5)
		return

	var transforms := _build_instance_transforms()
	_effect = DedicatedVoxelDDAEffect.new()
	_effect.configure_upload_sources([_atlas, _macro_atlas])
	if not _effect.configure(
		_atlas.get_rd_rid(),
		_macro_atlas.get_rd_rid(),
		_shape.get_dimensions(),
		_shape.get_macro_dimensions(),
		transforms,
		VOXEL_SIZE
	):
		push_error(_effect.last_error)
		get_tree().quit(6)
		return
	_compositor = Compositor.new()
	_compositor.compositor_effects = [_effect]
	_camera.compositor = _compositor

	var viewport_rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	get_viewport().use_taa = true
	if _benchmark:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	print("DEDICATED_DDA_PROTOTYPE_START renderer=%s driver=%s instances=%d voxels=%d" % [
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_current_rendering_driver_name(),
		INSTANCE_COUNT,
		_shape.get_occupied_count(),
	])


func _create_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("9eb6d0")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("cad8e6")
	environment.ambient_light_energy = 0.6
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = false
	add_child(sun)

	var ground := MeshInstance3D.new()
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(220, 150)
	ground.mesh = ground_mesh
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color("424943")
	ground_material.roughness = 0.95
	ground.material_override = ground_material
	add_child(ground)

	_camera = Camera3D.new()
	_camera.position = Vector3(0, 56, 92)
	_camera.far = 400.0
	add_child(_camera)
	_camera.look_at(Vector3(0, 3, 0))

	var canvas := CanvasLayer.new()
	add_child(canvas)
	_status = Label.new()
	_status.position = Vector2(14, 12)
	_status.add_theme_font_size_override("font_size", 16)
	canvas.add_child(_status)
	_create_depth_references()


func _create_depth_references() -> void:
	# Opaque mesh: some pixels must be red and others voxel-colored according to real depth.
	var reference := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2.4, 2.4, 9.0)
	reference.mesh = mesh
	reference.position = Vector3(0, 2.0, 0)
	reference.rotation_degrees = Vector3(0, 32, 0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("df3f35")
	material.roughness = 0.45
	reference.material_override = material
	add_child(reference)

	# Transparent content is rendered after POST_OPAQUE and must depth-test against voxel depth.
	var glass := MeshInstance3D.new()
	var glass_mesh := BoxMesh.new()
	glass_mesh.size = Vector3(5.2, 2.8, 0.08)
	glass.mesh = glass_mesh
	glass.position = Vector3(0, 3.1, 3.65)
	var glass_material := StandardMaterial3D.new()
	glass_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_material.albedo_color = Color(0.18, 0.72, 0.92, 0.34)
	glass_material.roughness = 0.12
	glass.material_override = glass_material
	add_child(glass)


func _build_instance_transforms() -> Array[Transform3D]:
	var positions: Array[Vector3] = [Vector3.ZERO]
	var columns := 20
	var rows := 10
	var spacing := VOLUME_SIZE * VOXEL_SIZE + 1.2
	for row in rows:
		for column in columns:
			var instance_position := Vector3(
				(column - (columns - 1) * 0.5) * spacing,
				0.0,
				(row - (rows - 1) * 0.5) * spacing
			)
			if instance_position.length_squared() < 0.01:
				continue
			positions.append(instance_position)
			if positions.size() == INSTANCE_COUNT:
				break
		if positions.size() == INSTANCE_COUNT:
			break
	var transforms: Array[Transform3D] = []
	var base_height := _shape.get_dimensions().y * VOXEL_SIZE * 0.5
	for index in INSTANCE_COUNT:
		transforms.append(Transform3D(Basis.IDENTITY, positions[index] + Vector3.UP * base_height))
	return transforms


func _process(_delta: float) -> void:
	if _effect == null:
		return
	if not _effect.last_error.is_empty():
		push_error(_effect.last_error)
		get_tree().quit(7)
		return
	var viewport_rid := get_viewport().get_viewport_rid()
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
	var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid) \
		+ RenderingServer.get_frame_setup_time_cpu()
	_status.text = "DDA dedicado · %d Shapes · GPU %.2f ms · CPU render %.2f ms\n" % [
		INSTANCE_COUNT, gpu_ms, cpu_ms
	]
	_status.text += "voxels %d · regional upload %d / %d bytes · camera %s\n" % [
		_shape.get_occupied_count(),
		_atlas.last_uploaded_bytes,
		_shape.get_cells().size(),
		"interior" if _inside else "exterior",
	]
	_status.text += "phase %s · Space: crater · I: interior camera · V: visualize steps" % _phase

	if not _benchmark:
		return
	if _phase.ends_with("voxel") and not _effect.ready_for_render:
		return
	_phase_frame += 1
	if _phase == "outside_voxel" and _phase_frame == 8:
		DisplayServer.window_set_size(Vector2i(1280, 720))
	elif _phase == "outside_voxel" and _phase_frame == 24:
		DisplayServer.window_set_size(Vector2i(1600, 900))
		_resize_tested = true
	match _phase:
		"outside_voxel":
			if _phase_frame == VOXEL_WARMUP_FRAMES + 30:
				_apply_benchmark_damage()
			_collect_after_warmup(_outside_gpu, _outside_cpu, gpu_ms, cpu_ms, VOXEL_WARMUP_FRAMES)
			if _phase_frame >= VOXEL_WARMUP_FRAMES + VOXEL_SAMPLE_FRAMES:
				_save_viewport("res://benchmark/dedicated_dda_outside.png")
				_set_voxel_enabled(false)
				_change_phase("outside_baseline")
		"outside_baseline":
			_collect_gpu_after_warmup(_outside_baseline_gpu, gpu_ms, BASELINE_WARMUP_FRAMES)
			if _phase_frame >= BASELINE_WARMUP_FRAMES + BASELINE_SAMPLE_FRAMES:
				_toggle_inside()
				_set_voxel_enabled(true)
				_change_phase("inside_voxel")
		"inside_voxel":
			_collect_after_warmup(_inside_gpu, _inside_cpu, gpu_ms, cpu_ms, VOXEL_WARMUP_FRAMES)
			if _phase_frame >= VOXEL_WARMUP_FRAMES + VOXEL_SAMPLE_FRAMES:
				_set_voxel_enabled(false)
				_change_phase("inside_baseline")
		"inside_baseline":
			_collect_gpu_after_warmup(_inside_baseline_gpu, gpu_ms, BASELINE_WARMUP_FRAMES)
			if not _finishing and _phase_frame >= BASELINE_WARMUP_FRAMES + BASELINE_SAMPLE_FRAMES:
				_finishing = true
				_finish_benchmark.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				_apply_benchmark_damage()
			KEY_I:
				_toggle_inside()
			KEY_V:
				_effect.visualize_steps = not _effect.visualize_steps


func _collect_after_warmup(
	gpu_target: PackedFloat64Array,
	cpu_target: PackedFloat64Array,
	gpu_ms: float,
	cpu_ms: float,
	warmup: int
) -> void:
	if _phase_frame >= warmup and gpu_ms > 0.0:
		gpu_target.append(gpu_ms)
	if _phase_frame >= warmup and cpu_ms > 0.0:
		cpu_target.append(cpu_ms)


func _collect_gpu_after_warmup(
	target: PackedFloat64Array, gpu_ms: float, warmup: int
) -> void:
	if _phase_frame >= warmup and gpu_ms > 0.0:
		target.append(gpu_ms)


func _change_phase(next: String) -> void:
	_phase = next
	_phase_frame = 0
	print("DEDICATED_DDA_PHASE %s" % next)


func _set_voxel_enabled(value: bool) -> void:
	_effect.enabled = value


func _apply_benchmark_damage() -> void:
	var center := Vector3(VOLUME_SIZE * 0.5, VOLUME_SIZE * 0.38, VOLUME_SIZE * 0.08)
	var started := Time.get_ticks_usec()
	_damage_result = _shape.damage_sphere(center, 28.0, 1.0)
	var dirty_min: Vector3i = _damage_result.get("dirty_min", Vector3i(-1, -1, -1))
	var dirty_max: Vector3i = _damage_result.get("dirty_max", Vector3i(-1, -1, -1))
	var copied := _atlas.update_region(_shape.get_cells(), dirty_min, dirty_max)
	if copied and dirty_min.x >= 0:
		_macro_atlas.update_region(
			_shape.get_macro_occupancy(),
			dirty_min / 8,
			dirty_max / 8
		)
	_damage_cpu_ms = (Time.get_ticks_usec() - started) / 1000.0
	print("DEDICATED_DDA_DAMAGE removed=%d dirty=%s..%s uploaded=%d full=%d cpu_ms=%.3f copied=%s" % [
		int(_damage_result.get("removed", 0)), dirty_min, dirty_max,
		_atlas.last_uploaded_bytes, _shape.get_cells().size(), _damage_cpu_ms, copied,
	])


func _toggle_inside() -> void:
	_inside = not _inside
	if _inside:
		_camera.position = Vector3(0, VOLUME_SIZE * VOXEL_SIZE * 0.5, 0)
		_camera.look_at(Vector3(1, VOLUME_SIZE * VOXEL_SIZE * 0.5, -1))
	else:
		_camera.position = Vector3(0, 56, 92)
		_camera.look_at(Vector3(0, 3, 0))


func _finish_benchmark() -> void:
	_set_voxel_enabled(true)
	for _index in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_save_viewport("res://benchmark/dedicated_dda_inside.png")

	var outside_total_median := _percentile(_outside_gpu, 0.5)
	var outside_total_p95 := _percentile(_outside_gpu, 0.95)
	var outside_baseline := _percentile(_outside_baseline_gpu, 0.5)
	var inside_total_median := _percentile(_inside_gpu, 0.5)
	var inside_total_p95 := _percentile(_inside_gpu, 0.95)
	var inside_baseline := _percentile(_inside_baseline_gpu, 0.5)
	var outside_voxel_median := maxf(0.0, outside_total_median - outside_baseline)
	var outside_voxel_p95 := maxf(0.0, outside_total_p95 - outside_baseline)
	var inside_voxel_median := maxf(0.0, inside_total_median - inside_baseline)
	var inside_voxel_p95 := maxf(0.0, inside_total_p95 - inside_baseline)
	var outside_cpu := _percentile(_outside_cpu, 0.5)
	var inside_cpu := _percentile(_inside_cpu, 0.5)
	var regional_upload := _atlas.last_uploaded_bytes > 0 \
		and _atlas.last_uploaded_bytes < _shape.get_cells().size()
	var result := {
		"backend": "rendering_device_post_opaque",
		"api": "Vulkan 1.2 via Godot Forward+",
		"renderer": RenderingServer.get_current_rendering_method(),
		"driver": RenderingServer.get_current_rendering_driver_name(),
		"instances": INSTANCE_COUNT,
		"outside_gpu_total_median_ms": snappedf(outside_total_median, 0.001),
		"outside_gpu_total_p95_ms": snappedf(outside_total_p95, 0.001),
		"outside_gpu_voxel_median_ms": snappedf(outside_voxel_median, 0.001),
		"outside_gpu_voxel_p95_ms": snappedf(outside_voxel_p95, 0.001),
		"inside_gpu_total_median_ms": snappedf(inside_total_median, 0.001),
		"inside_gpu_total_p95_ms": snappedf(inside_total_p95, 0.001),
		"inside_gpu_voxel_median_ms": snappedf(inside_voxel_median, 0.001),
		"inside_gpu_voxel_p95_ms": snappedf(inside_voxel_p95, 0.001),
		"outside_cpu_render_median_ms": snappedf(outside_cpu, 0.001),
		"inside_cpu_render_median_ms": snappedf(inside_cpu, 0.001),
		"damage_cpu_ms": snappedf(_damage_cpu_ms, 0.001),
		"damage_removed": int(_damage_result.get("removed", 0)),
		"regional_upload_bytes": _atlas.last_uploaded_bytes,
		"full_volume_bytes": _shape.get_cells().size(),
		"regional_upload": regional_upload,
		"resize_tested": _resize_tested,
	}
	result["pass_gpu"] = outside_voxel_median <= 8.0 and outside_voxel_p95 <= 10.0 \
		and inside_voxel_median <= 8.0 and inside_voxel_p95 <= 10.0
	result["pass_cpu"] = outside_cpu <= 2.0 and inside_cpu <= 2.0
	result["pass_damage_volume"] = result.damage_removed >= 10000
	result["pass"] = result.pass_gpu and result.pass_cpu \
		and result.pass_damage_volume and regional_upload and _resize_tested
	print("DEDICATED_DDA_BENCHMARK_RESULT ", JSON.stringify(result))
	_camera.compositor = null
	_compositor = null
	_effect = null
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_atlas.release()
	_macro_atlas.release()
	get_tree().quit(0 if result.pass else 10)


func _percentile(source: PackedFloat64Array, fraction: float) -> float:
	if source.is_empty():
		return INF
	var sorted := Array(source)
	sorted.sort()
	var index := clampi(ceili((sorted.size() - 1) * fraction), 0, sorted.size() - 1)
	return float(sorted[index])


func _save_viewport(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	var error := get_viewport().get_texture().get_image().save_png(absolute)
	if error != OK:
		push_error("Could not save %s (%s)" % [absolute, error])


func _exit_tree() -> void:
	_camera = null
	_compositor = null
	_effect = null
