extends Node3D
## Graphical acceptance benchmark: warm the DDA first, then activate 256 Jolt voxel Bodies at once.

const BODY_COUNT := 256
const WARMUP_FRAMES := 120
const SAMPLE_FRAMES := 300

var _world: VoxelWorld3D
var _renderer: VoxelRenderSystem
var _bodies: Array[VoxelBody3D] = []
var _frame := 0
var _activated := false
var _activation_msec := 0
var _recovery_seconds := -1.0
var _frame_times := PackedFloat64Array()
var _gpu_times := PackedFloat64Array()
var _clipmap_times := PackedFloat64Array()
var _metadata_times := PackedFloat64Array()


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_create_scene()
	_create_static_bodies()
	_renderer = VoxelRenderSystem.new()
	add_child(_renderer)
	if not _renderer.setup(_world, $Camera3D):
		push_error("Could not start DDA for the burst benchmark")
		get_tree().quit(70)
		return
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	get_viewport().use_taa = true


func _create_scene() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("8295a8")
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0, 18, 32)
	add_child(camera)
	camera.look_at(Vector3(0, 3, 0))
	var ground := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	collision.shape = WorldBoundaryShape3D.new()
	ground.add_child(collision)
	add_child(ground)
	_world = VoxelWorld3D.new()
	_world.show_diagnostics = false
	add_child(_world)


func _create_static_bodies() -> void:
	var palette := VoxelPalette.new()
	var cells := PackedByteArray()
	cells.resize(8)
	cells.fill(1)
	for index in BODY_COUNT:
		var data := VoxelShapeData.new()
		data.set_cells(Vector3i(2, 2, 2), cells)
		var shape := VoxelShape3D.new()
		shape.data = data
		shape.palette = palette
		shape.anchored = false
		var body := VoxelBody3D.new()
		body.structural = false
		body.position = Vector3(
			(index % 16 - 8) * 0.65,
			2.0 + (index / 16) * 0.27,
			(index % 4 - 2) * 0.55
		)
		_world.add_child(body)
		body.add_voxel_shape(shape)
		_world.register_body(body)
		_bodies.append(body)


func _process(delta: float) -> void:
	if not _activated:
		_frame += 1
		if _frame >= WARMUP_FRAMES and _renderer.effect.ready_for_render:
			_activate_burst()
		return
	_frame += 1
	_frame_times.append(delta * 1000.0)
	_gpu_times.append(RenderingServer.viewport_get_measured_render_time_gpu(
		get_viewport().get_viewport_rid()
	))
	_clipmap_times.append(_renderer.shadow_clipmaps.last_dynamic_update_ms)
	_metadata_times.append(_renderer.last_metadata_sync_ms)
	if _recovery_seconds < 0.0 and _frame >= 5:
		# Five consecutive frames below budget are enough to exclude a one-frame dip while keeping
		# the recovery measurement independent of the current refresh rate.
		var recent := _tail(_frame_times, 5)
		if int(_world.get_metrics().awake_bodies) <= _world.physics_budget.target_awake_bodies \
			and _percentile(recent, 0.95) <= 16.7:
			_recovery_seconds = (Time.get_ticks_msec() - _activation_msec) / 1000.0
	if _frame >= SAMPLE_FRAMES:
		_finish.call_deferred()


func _activate_burst() -> void:
	_activated = true
	_frame = 0
	_activation_msec = Time.get_ticks_msec()
	for body in _bodies:
		body.make_dynamic(1)


func _finish() -> void:
	var frame_p95 := _percentile(_frame_times, 0.95)
	var gpu_p95 := _percentile(_gpu_times, 0.95)
	var metrics := _world.get_metrics()
	var passed := frame_p95 <= 33.3 and _recovery_seconds >= 0.0 \
		and _recovery_seconds < 2.0 \
		and int(metrics.awake_compound_boxes) <= _world.physics_budget.max_active_boxes
	print("VOXEL_PHYSICS_BURST_RESULT ", JSON.stringify({
		"bodies": BODY_COUNT,
		"frame_p95_ms": snappedf(frame_p95, 0.001),
		"gpu_p95_ms": snappedf(gpu_p95, 0.001),
		"clipmap_cpu_p95_ms": snappedf(_percentile(_clipmap_times, 0.95), 0.001),
		"metadata_cpu_p95_ms": snappedf(_percentile(_metadata_times, 0.95), 0.001),
		"recovery_seconds": snappedf(_recovery_seconds, 0.001),
		"awake_bodies_final": metrics.awake_bodies,
		"awake_compound_boxes": metrics.awake_compound_boxes,
		"total_compound_boxes": metrics.compound_boxes,
		"pass": passed,
	}))
	get_tree().quit(0 if passed else 71)


static func _tail(source: PackedFloat64Array, count: int) -> PackedFloat64Array:
	return source.slice(maxi(0, source.size() - count), source.size())


static func _percentile(source: PackedFloat64Array, fraction: float) -> float:
	if source.is_empty():
		return INF
	var sorted := Array(source)
	sorted.sort()
	return float(sorted[clampi(ceili((sorted.size() - 1) * fraction), 0, sorted.size() - 1)])
