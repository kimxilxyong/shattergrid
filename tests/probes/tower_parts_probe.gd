extends SceneTree
## Three fixes tested against Lee's real data: cables attached to bodies, the tower falling as one
## piece, and the pipe pole's joints surviving its transition to a dynamic body.
var MAP := VoxelProjectPaths.teardown_map_path()
var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FAIL ", message)


func _bodies_near(world: VoxelWorld3D, probe: Vector3, radius: float) -> Array[VoxelBody3D]:
	var near: Array[VoxelBody3D] = []
	for body in world.get_children():
		if not body is VoxelBody3D or not is_instance_valid(body):
			continue
		for shape in (body as VoxelBody3D).get_shapes():
			var bounds := shape.world_bounds()
			if probe.distance_to(probe.clamp(bounds.position, bounds.end)) < radius \
					and not near.has(body):
				near.append(body)
	return near


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	world.renderer_settings = VoxelRendererSettings.new()
	world.renderer_settings.sun_shadows_enabled = false
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)
	var renderer: VoxelRenderSystem
	if "--renderer" in OS.get_cmdline_user_args():
		_check(RenderingServer.get_rendering_device() != null,
			"the visual test has a RenderingDevice available")
		var camera := Camera3D.new()
		root.add_child(camera)
		renderer = VoxelRenderSystem.new()
		root.add_child(renderer)
		_check(renderer.setup(world, camera), "the renderer loads the full map")
	for _frame in 10:
		await physics_frame

	var ropes := world.get_node_or_null("TeardownRopes") as VoxelRopes
	print("\ncables: %d spans, %d with an endpoint attached to a body" % [
		ropes.span_count(), ropes.attached_count()])
	var joints := world.get_node_or_null("TeardownJoints") as VoxelJoints
	print("joints: %d registrados, %d vivos" % [joints.count(), joints.live_count()])

	# The power tower's mast (Body35) and head (Body34) are separate `<vox>` elements, each with its
	# own body. When the base is destroyed, they must fall together, not separately.
	print("\n=== power tower ===")
	var tower := _bodies_near(world, Vector3(-3.9, 14.7, 70.9), 2.0)
	var head := _bodies_near(world, Vector3(-3.9, 25.5, 70.9), 1.0)
	print("  before: mast=%s head=%s" % [tower[0].name, head[0].name])
	var head_shape := head[0].get_shapes()[0]
	var head_y := head_shape.world_bounds().get_center().y
	for step in 3:
		world.damage_sphere(Vector3(-3.92, 3.0 + float(step) * 0.8, 70.95), 3.2, 400.0)
	for _frame in 30:
		await physics_frame
	var mast_after := _bodies_near(world, Vector3(-3.9, 14.7, 70.9), 3.0)
	var mast_body: VoxelBody3D
	for candidate in mast_after:
		if candidate.state == VoxelBody3D.State.DYNAMIC:
			mast_body = candidate
			break
	var head_body := world._body_of(head_shape)
	var head_rigid := head_body.get_physics_body() as RigidBody3D if head_body != null else null
	print("  after: mast state=%d  head state=%d  same body=%s" % [
		mast_body.state if mast_body != null else -1,
		head_body.state if head_body != null else -1,
		mast_body == head_body])
	print("  handoff=%s freeze=%s sleeping=%s boxes=%d holds=%d queues=%s" % [
		head_body.collision_handoff_pending if head_body != null else false,
		head_rigid.freeze if head_rigid != null else false,
		head_rigid.sleeping if head_rigid != null else false,
		head_body.compound_boxes if head_body != null else -1,
		head_body.physics_hold_count() if head_body != null else -1,
		world.get_metrics(),
	])
	var tower_mass := head_rigid.mass if head_rigid != null else -1.0
	print("  dynamic mass=%.1f kg  CCD=%s  active world boxes=%d/%d" % [
		tower_mass,
		head_rigid.continuous_cd if head_rigid != null else false,
		int(world.get_metrics().awake_compound_boxes),
		world.physics_budget.max_active_boxes,
	])
	var awake_records: Array[Dictionary] = []
	for awake_body: VoxelBody3D in world.get_dynamic_bodies():
		if not awake_body.is_awake():
			continue
		var awake_rigid := awake_body.get_physics_body() as RigidBody3D
		awake_records.append({
			"name": awake_body.name,
			"boxes": awake_body.compound_boxes,
			"voxels": awake_body.get_total_voxels(),
			"mass": snappedf(awake_rigid.mass, 0.1) if awake_rigid != null else -1.0,
			"holds": awake_body.physics_hold_count(),
			"structural": awake_body.structural,
		})
	awake_records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.boxes) > int(b.boxes)
	)
	print("  awake Bodies: ", JSON.stringify(awake_records))
	_check(head_body != null and head_body.state == VoxelBody3D.State.DYNAMIC,
		"the head stops being static after all supports are destroyed")
	_check(mast_body == head_body,
		"the head and its supporting section remain in one Body")
	_check(not head_body.collision_handoff_pending,
		"the handoff is not left pending")
	_check(head_rigid != null and (
			not head_rigid.continuous_cd
			or head_body.compound_boxes <= VoxelBody3D.LARGE_BODY_CCD_BOX_THRESHOLD
		), "CCD remains active only if the compound is below the adaptive threshold")
	_check(tower_mass > 500.0 and tower_mass < 20_000.0,
		"the remaining tower weighs less than 20 t, not over 100 t as a solid block")
	_check(head_body.compound_boxes <= world.physics_budget.max_boxes_per_body,
		"moving collision stays within the per-Body budget")
	var transform_sync_ms := PackedFloat64Array()
	for _frame in 90:
		await physics_frame
		if renderer != null:
			transform_sync_ms.append(renderer.last_transform_sync_ms)
	var head_drop := head_y - head_shape.world_bounds().get_center().y
	if renderer != null and is_instance_valid(head_shape):
		renderer._process(0.0)
		var pose := renderer.get_shape_pose_snapshot(head_shape)
		var render_audit := renderer.get_coherence_snapshot()
		print("  render pose scene=%.4f m effect=%.4f m sync P95=%.3f ms audit=%s" % [
			float(pose.get("scene_error_m", INF)), float(pose.get("effect_error_m", INF)),
			_percentile(transform_sync_ms, 0.95), JSON.stringify(render_audit),
		])
		_check(bool(pose.get("valid", false)) and float(pose.scene_error_m) < 0.02,
			"the tower's rendered pose follows Jolt")
		_check(float(pose.get("effect_error_m", INF)) < 0.001,
			"the GPU sheet does not retain an upright copy")
		_check(String(render_audit.get("status", "DESYNC")) == "COHERENT" \
			and float(render_audit.get("pending_gpu_update_age_ms", INF)) < 50.0,
			"the full map's atlas, entries, poses, and Vulkan queue remain coherent")
	var recovery_physics_ms := PackedFloat64Array()
	for _frame in 60:
		await physics_frame
		if renderer != null:
			transform_sync_ms.append(renderer.last_transform_sync_ms)
		recovery_physics_ms.append(
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		)
	var recovery_p95 := _percentile(recovery_physics_ms, 0.95)
	var rope_diagnostics := ropes.get_diagnostics()
	print("  head fell %.2f m; physics min/median/P95/max %.2f/%.2f/%.2f/%.2f ms; ropes %s" % [
		head_drop, Array(recovery_physics_ms).min(), _percentile(recovery_physics_ms, 0.50),
		recovery_p95, Array(recovery_physics_ms).max(), JSON.stringify(rope_diagnostics),
	])
	_check(int(rope_diagnostics.same_body_awake) == 0,
		"no internal rope simulates a spring or injects torque into the tower")
	_check(head_drop > 0.5, "the head physically falls; it does not merely change state")
	_check(world.get_metrics().pending_fragments == 0 \
		and world.get_metrics().pending_collision_handoffs == 0,
		"critical queues are drained")
	var empty_dynamic := 0
	for dynamic_body: VoxelBody3D in world.get_dynamic_bodies():
		empty_dynamic += 1 if dynamic_body.get_total_voxels() == 0 else 0
	_check(empty_dynamic == 0,
		"no ghost Body survives with zero voxels and stale collision")

	# The pipe pole: two joints at the connection point, which remains intact.
	print("\n=== pipe pole ===")
	var post := _bodies_near(world, Vector3(4.22, 6.4, -27.0), 0.3)[0]
	var mine: Array[Dictionary] = []
	for record in joints._records:
		if record.get("owner_body") == post or record.get("other_body") == post:
			mine.append(record)
	print("  pole joints: %d" % mine.size())
	world.damage_sphere(Vector3(4.22, 2.2, -27.0), 1.6, 200.0)
	for _frame in 30:
		await physics_frame
	var live := 0
	for record in mine:
		if VoxelDoor3D._record_joint_is_live(record):
			live += 1
	print("  after destroying the base: %d of %d remain live" % [live, mine.size()])
	_check(live == mine.size(), "intact joints survive the post transition")
	for _drain_frame in 120:
		var metrics := world.get_metrics()
		if int(metrics.pending_fragments) == 0 \
				and int(metrics.pending_collision_handoffs) == 0 \
				and int(metrics.pending_collision_rebuilds) == 0 \
				and int(metrics.pending_collision_blocks) == 0:
			break
		await physics_frame
	var drained := world.get_metrics()
	_check(int(drained.pending_fragments) == 0 \
		and int(drained.pending_collision_handoffs) == 0 \
		and int(drained.pending_collision_rebuilds) == 0 \
		and int(drained.pending_collision_blocks) == 0,
		"no handoffs or rebuilds remain after draining Lee")
	if failures == 0:
		print("VOXEL_LEE_PHYSICS_REGRESSION_OK")
	else:
		printerr("VOXEL_LEE_PHYSICS_REGRESSION_FAIL count=", failures)
	quit(1 if failures > 0 else 0)


static func _percentile(source: PackedFloat64Array, fraction: float) -> float:
	if source.is_empty():
		return INF
	var sorted := Array(source)
	sorted.sort()
	return float(sorted[clampi(ceili((sorted.size() - 1) * fraction), 0, sorted.size() - 1)])
