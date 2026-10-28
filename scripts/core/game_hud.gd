class_name GameHud
extends CanvasLayer
## World status display. This class decides how often each metric is resampled: text refreshes at
## 4 Hz, the renderer coherence audit at 1 Hz, and the voxel count at 0.5 Hz. Their costs differ by
## orders of magnitude, so sampling all of them at the cheapest metric's rate caused CPU spikes.

## Time in seconds between text refreshes, renderer audits, full world recounts, and PERF log lines.
const REFRESH_PERIOD := 0.25
const RENDER_AUDIT_PERIOD := 1.0
const RECOUNT_PERIOD := 2.0
const PERF_LOG_PERIOD := 3.0

@onready var _counter: Label = $Counter

var _world: VoxelWorld3D
var _renderer: VoxelRenderSystem
var _camera: Camera3D
var _player: Node3D
var _refresh_elapsed := 0.0
var _render_audit_elapsed := 0.0
var _recount_elapsed := 0.0
var _perf_log_elapsed := 0.0
var _cached_render_audit := {}
var _cached_voxel_total := 0


## `renderer` may be null: the HUD starts before the renderer and continues measuring the world,
## omitting only the coherence line.
func setup(world: VoxelWorld3D, renderer: VoxelRenderSystem, player: Node3D, camera: Camera3D) -> void:
	_world = world
	_renderer = renderer
	_player = player
	_camera = camera
	_cached_voxel_total = _total_voxel_count()
	if not _world.voxel_impact.is_connected(_on_voxel_impact):
		_world.voxel_impact.connect(_on_voxel_impact)
	refresh()


## On-screen watermark while an imported map is loaded.
func show_watermark(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3, 0.85))
	label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT, true)
	label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	label.position -= Vector2(16, 12)
	add_child(label)


func refresh() -> void:
	if _world == null:
		return
	var metrics := _world.get_metrics()
	var viewport_rid := get_viewport().get_viewport_rid()
	var fps := Engine.get_frames_per_second()
	_counter.text = ("%d voxels · %d awake Bodies · %d active boxes (%d total) · %d fps\n"
		+ "frame %.1f ms · physics %.1f ms · GPU %.1f ms · render CPU %.1f ms · ropes %d active/%d under tension") % [
		_cached_voxel_total,
		int(metrics.awake_bodies),
		int(metrics.awake_compound_boxes),
		int(metrics.compound_boxes),
		fps,
		1000.0 / maxf(1.0, float(fps)),
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid),
		RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
			+ RenderingServer.get_frame_setup_time_cpu(),
		_ropes_awake(),
		_ropes_pulling(),
	]
	if _renderer != null:
		if _cached_render_audit.is_empty():
			_cached_render_audit = _renderer.get_coherence_snapshot()
		var render_audit := _cached_render_audit
		_counter.text += "\nrender %s · Shapes %d/%d · poses %d/%d" % [
			String(render_audit.get("status", "DESYNC")),
			int(render_audit.get("renderer_entries", 0)),
			int(render_audit.get("live_shapes", 0)),
			(render_audit.get("effect_pose_mismatches", []) as Array).size(),
			(render_audit.get("settled_pose_mismatches", []) as Array).size(),
		]
	if "--physics-probe" in OS.get_cmdline_user_args():
		_counter.text += "\n" + _probe_under_crosshair()


func _process(delta: float) -> void:
	if _world == null:
		return
	_perf_log_elapsed += delta
	if _perf_log_elapsed >= PERF_LOG_PERIOD:
		_perf_log_elapsed = 0.0
		_log_perf()
	_render_audit_elapsed += delta
	if _renderer != null and _render_audit_elapsed >= RENDER_AUDIT_PERIOD:
		_render_audit_elapsed = 0.0
		_cached_render_audit = _renderer.get_coherence_snapshot()
	_refresh_elapsed += delta
	if _refresh_elapsed >= REFRESH_PERIOD:
		_refresh_elapsed = 0.0
		refresh()
	_recount_elapsed += delta
	if _recount_elapsed >= RECOUNT_PERIOD:
		_recount_elapsed = 0.0
		_cached_voxel_total = _total_voxel_count()


## Log the per-frame cost breakdown to the console. This is separate from the counter because it is
## useful to review after a session rather than watch live.
func _log_perf() -> void:
	var rid := get_viewport().get_viewport_rid()
	var clip := _renderer.shadow_clipmaps if _renderer != null else null
	print(("PERF fps=%.0f gpu=%.2f cpu_render=%.2f | clipmap raster=%.2f upload=%.2f"
		+ " dynamic=%.2f | awake=%d ropes=%d/%d") % [
		Engine.get_frames_per_second(),
		RenderingServer.viewport_get_measured_render_time_gpu(rid),
		RenderingServer.viewport_get_measured_render_time_cpu(rid)
			+ RenderingServer.get_frame_setup_time_cpu(),
		clip.last_region_raster_ms if clip != null else 0.0,
		clip.last_region_upload_ms if clip != null else 0.0,
		clip.last_dynamic_update_ms if clip != null else 0.0,
		_world.awake_bodies,
		_ropes_pulling(), _ropes_awake(),
	])


## Report what is under the crosshair: the physics body returned by Jolt and whether actual voxels
## are present there. This distinguishes two causes of visual artifacts: a Jolt hit without voxels
## indicates a stray collider; voxels without a Jolt hit indicate incorrectly rendered geometry.
func _probe_under_crosshair() -> String:
	var from := _camera.global_position
	var to := from - _camera.global_basis.z * 60.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [(_player as CollisionObject3D).get_rid()]
	var hit := _camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return "crosshair: nothing within 60 m · pos %.1f %.1f %.1f" % [from.x, from.y, from.z]
	var collider: Node = hit.collider
	var owner_name := collider.name
	var parent := collider.get_parent()
	if parent != null:
		owner_name = "%s/%s" % [parent.name, owner_name]
	var point: Vector3 = hit.position
	return "crosshair: %s at %.1f m · point %.1f %.1f %.1f · pos %.1f %.1f %.1f" % [
		owner_name, from.distance_to(point), point.x, point.y, point.z, from.x, from.y, from.z
	]


func _ropes_node() -> VoxelRopes:
	return _world.get_node_or_null("TeardownRopes") as VoxelRopes if _world != null else null


func _ropes_pulling() -> int:
	var ropes := _ropes_node()
	return 0 if ropes == null else ropes.pulling


func _ropes_awake() -> int:
	var ropes := _ropes_node()
	return 0 if ropes == null else ropes.awake_count()


func _total_voxel_count() -> int:
	var total := 0
	for body: VoxelBody3D in get_tree().get_nodes_in_group(VoxelBody3D.GROUP):
		total += body.get_total_voxels()
	return total


func _on_voxel_impact(_center: Vector3, removed_voxels: int, _radius: float) -> void:
	_cached_voxel_total = maxi(0, _cached_voxel_total - removed_voxels)
