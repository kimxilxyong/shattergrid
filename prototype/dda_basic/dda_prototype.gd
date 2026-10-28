extends Node3D
## Renderer feasibility gate for the Teardown-style spatial DDA path.
##
## Run interactively:
##   godot --path . res://prototype/dda_basic/dda_prototype.tscn
## Run the repeatable gate:
##   godot --path . res://prototype/dda_basic/dda_prototype.tscn -- --benchmark

const VOXEL_SIZE := 0.1
const VOLUME_SIZE := 64
const INSTANCE_COUNT := 200
const WARMUP_FRAMES := 120
const SAMPLE_FRAMES := 300
const BASELINE_WARMUP_FRAMES := 30
const BASELINE_SAMPLE_FRAMES := 120

var _shape: VoxelShapeData
var _atlas := preload("res://prototype/dda_dedicated/voxel_atlas_3d.gd").new()
var _macro_atlas := preload("res://prototype/dda_dedicated/voxel_atlas_3d.gd").new()
var _material: ShaderMaterial
var _dda_view: MultiMeshInstance3D
var _camera: Camera3D
var _status: Label
var _benchmark := false
var _frame := 0
var _finishing := false
var _inside := false
var _gpu_samples := PackedFloat64Array()
var _cpu_samples := PackedFloat64Array()
var _baseline_gpu_samples := PackedFloat64Array()
var _baseline_frame := -1
var _damage_result := {}
var _damage_cpu_ms := 0.0
var _live_capture_saved := false


func _ready() -> void:
	_benchmark = "--benchmark" in OS.get_cmdline_user_args()
	if RenderingServer.get_current_rendering_method() != "forward_plus":
		push_error("DDA prototype requires Forward+")
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
	if not _atlas.create(_shape.get_dimensions(), _shape.get_cells()):
		get_tree().quit(4)
		return
	if not _macro_atlas.create(_shape.get_macro_dimensions(), _shape.get_macro_occupancy()):
		get_tree().quit(5)
		return

	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/voxel/voxel_dda.gdshader")
	_material.set_shader_parameter("voxel_texture", _atlas.texture)
	_material.set_shader_parameter("macro_texture", _macro_atlas.texture)
	_material.set_shader_parameter("palette_texture", _create_palette())
	_material.set_shader_parameter("volume_dimensions", _shape.get_dimensions())
	_material.set_shader_parameter("macro_dimensions", _shape.get_macro_dimensions())
	_material.set_shader_parameter("voxel_size", VOXEL_SIZE)
	_material.set_shader_parameter("max_steps", VOLUME_SIZE * 3)
	_create_instances()
	_create_depth_reference()

	var viewport_rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	get_viewport().use_taa = true
	if _benchmark:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	print("DDA_PROTOTYPE_READY renderer=%s driver=%s instances=%d voxels=%d" % [
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
	sun.shadow_enabled = false # The proxy cube must never enter Godot's shadow maps.
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


func _create_instances() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(_shape.get_dimensions()) * VOXEL_SIZE

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = box
	multimesh.instance_count = INSTANCE_COUNT

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

	var base_height := _shape.get_dimensions().y * VOXEL_SIZE * 0.5
	for index in INSTANCE_COUNT:
		var instance_transform := Transform3D(Basis.IDENTITY, positions[index] + Vector3.UP * base_height)
		multimesh.set_instance_transform(index, instance_transform)

	_dda_view = MultiMeshInstance3D.new()
	_dda_view.name = "DDAInstances"
	_dda_view.multimesh = multimesh
	_dda_view.material_override = _material
	_dda_view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_dda_view)


func _create_depth_reference() -> void:
	# A conventional red mesh penetrates the central voxel volume. Correct custom DEPTH makes the
	# nearer representation win on each pixel instead of exposing the bounding cube.
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


func _create_palette() -> ImageTexture:
	var image := Image.create(256, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.set_pixel(1, 0, Color("b85a36"))
	image.set_pixel(2, 0, Color("a8a9ad"))
	image.set_pixel(3, 0, Color("59636e"))
	return ImageTexture.create_from_image(image)


func _process(_delta: float) -> void:
	_frame += 1
	var viewport_rid := get_viewport().get_viewport_rid()
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
	var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid) \
		+ RenderingServer.get_frame_setup_time_cpu()

	if _baseline_frame < 0 and _frame >= WARMUP_FRAMES and _frame < WARMUP_FRAMES + SAMPLE_FRAMES:
		if gpu_ms > 0.0:
			_gpu_samples.append(gpu_ms)
		if cpu_ms > 0.0:
			_cpu_samples.append(cpu_ms)
	elif _baseline_frame >= 0:
		_baseline_frame += 1
		if _baseline_frame >= BASELINE_WARMUP_FRAMES \
			and _baseline_frame < BASELINE_WARMUP_FRAMES + BASELINE_SAMPLE_FRAMES \
			and gpu_ms > 0.0:
			_baseline_gpu_samples.append(gpu_ms)

	if _frame == WARMUP_FRAMES + 30:
		_apply_benchmark_damage()
	if not _live_capture_saved and _frame >= 90:
		_live_capture_saved = true
		_save_viewport("res://benchmark/dda_live.png")

	_status.text = "DDA espacial · %d instancias · GPU %.2f ms · CPU render %.2f ms\n" % [
		INSTANCE_COUNT, gpu_ms, cpu_ms
	]
	_status.text += "voxels %d · regional upload %d / %d bytes · camera %s\n" % [
		_shape.get_occupied_count(),
		_atlas.last_uploaded_bytes,
		_shape.get_cells().size(),
		"interior" if _inside else "exterior",
	]
	_status.text += "Space: crater · I: interior camera · V: visualize DDA steps"

	if _benchmark and _baseline_frame < 0 and _frame >= WARMUP_FRAMES + SAMPLE_FRAMES:
		_baseline_frame = 0
		_dda_view.visible = false
	elif _benchmark and not _finishing and _baseline_frame >= BASELINE_WARMUP_FRAMES + BASELINE_SAMPLE_FRAMES:
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
				var current := bool(_material.get_shader_parameter("visualize_steps"))
				_material.set_shader_parameter("visualize_steps", not current)


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
	print("DDA_DAMAGE removed=%d dirty=%s..%s uploaded=%d full=%d cpu_ms=%.3f copied=%s" % [
		int(_damage_result.get("removed", 0)),
		dirty_min,
		dirty_max,
		_atlas.last_uploaded_bytes,
		_shape.get_cells().size(),
		_damage_cpu_ms,
		copied,
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
	_dda_view.visible = true
	for _index in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_save_viewport("res://benchmark/dda_outside.png")
	_toggle_inside()
	for _index in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_save_viewport("res://benchmark/dda_inside.png")

	var gpu_median := _percentile(_gpu_samples, 0.5)
	var gpu_p95 := _percentile(_gpu_samples, 0.95)
	var baseline_gpu_median := _percentile(_baseline_gpu_samples, 0.5)
	var voxel_gpu_median := maxf(0.0, gpu_median - baseline_gpu_median)
	var voxel_gpu_p95 := maxf(0.0, gpu_p95 - baseline_gpu_median)
	var cpu_median := _percentile(_cpu_samples, 0.5)
	var regional_upload := _atlas.last_uploaded_bytes > 0 \
		and _atlas.last_uploaded_bytes < _shape.get_cells().size()
	var result := {
		"renderer": RenderingServer.get_current_rendering_method(),
		"driver": RenderingServer.get_current_rendering_driver_name(),
		"instances": INSTANCE_COUNT,
		"samples": _gpu_samples.size(),
		"gpu_total_median_ms": snappedf(gpu_median, 0.001),
		"gpu_total_p95_ms": snappedf(gpu_p95, 0.001),
		"gpu_baseline_median_ms": snappedf(baseline_gpu_median, 0.001),
		"gpu_voxel_estimated_median_ms": snappedf(voxel_gpu_median, 0.001),
		"gpu_voxel_estimated_p95_ms": snappedf(voxel_gpu_p95, 0.001),
		"cpu_render_median_ms": snappedf(cpu_median, 0.001),
		"damage_cpu_ms": snappedf(_damage_cpu_ms, 0.001),
		"damage_removed": int(_damage_result.get("removed", 0)),
		"regional_upload_bytes": _atlas.last_uploaded_bytes,
		"full_volume_bytes": _shape.get_cells().size(),
		"regional_upload": regional_upload,
		"pass_gpu": voxel_gpu_median <= 8.0 and voxel_gpu_p95 <= 10.0,
		"pass_cpu": cpu_median <= 2.0,
		"pass_damage_volume": int(_damage_result.get("removed", 0)) >= 10000,
	}
	result["pass"] = result["pass_gpu"] and result["pass_cpu"] \
		and result["pass_damage_volume"] and regional_upload
	print("DDA_BENCHMARK_RESULT ", JSON.stringify(result))
	_dda_view.visible = false
	_dda_view.material_override = null
	_material = null
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_atlas.release()
	_macro_atlas.release()
	get_tree().quit(0 if result["pass"] else 10)


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
	# The global RenderingDevice owns queued material draws until the render thread finishes this
	# frame. Let process shutdown release these prototype RIDs instead of invalidating a live set.
	_material = null
