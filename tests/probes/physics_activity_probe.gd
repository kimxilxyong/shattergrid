extends SceneTree
## Diagnose Lee map's persistent physics cost without a renderer.

var MAP := VoxelProjectPaths.teardown_map_path()
const SAMPLE_FRAMES := [1, 10, 60, 180]


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	if not FileAccess.file_exists(MAP):
		print("PHYSICS_ACTIVITY_PROBE_SKIPPED missing_map")
		quit(0)
		return
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	root.add_child(world)
	var started := Time.get_ticks_msec()
	var report := TeardownMapImporter.import_map(
		world, MAP, Vector3.INF, INF, Vector3.ZERO, true
	)
	var driven_vehicle: VoxelVehicle3D
	if "--vehicle" in OS.get_cmdline_user_args():
		for node in get_nodes_in_group(VoxelVehicle3D.GROUP):
			var candidate := node as VoxelVehicle3D
			if candidate != null and candidate.display_name == "SUV":
				driven_vehicle = candidate
				break
		if driven_vehicle != null:
			var probe_driver := Node3D.new()
			root.add_child(probe_driver)
			driven_vehicle.set_driver(probe_driver)
			driven_vehicle.set_control_override(true, 1.0, 0.0, false)
	if "--player" in OS.get_cmdline_user_args():
		var player := CharacterBody3D.new()
		var collision := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.38
		capsule.height = 1.8
		collision.shape = capsule
		player.add_child(collision)
		root.add_child(player)
		player.global_position = report.get("drop_in", Vector3.UP * 30.0)
	var renderer: VoxelRenderSystem
	if "--renderer" in OS.get_cmdline_user_args():
		world.renderer_settings.sun_shadows_enabled = true
		var camera := Camera3D.new()
		root.add_child(camera)
		camera.global_position = (
			driven_vehicle.get_camera_target() - driven_vehicle.forward_direction() * 6.0
			+ Vector3.UP * 2.0
			if driven_vehicle != null else report.get("drop_in", Vector3.UP * 30.0)
		)
		renderer = VoxelRenderSystem.new()
		root.add_child(renderer)
		assert(renderer.setup(world, camera))
	print("PHYSICS_ACTIVITY_IMPORT ms=%d bodies=%d joints=%d" % [
		Time.get_ticks_msec() - started, int(report.bodies), int(report.joints),
	])
	var joints := world.get_node_or_null("TeardownJoints") as VoxelJoints
	var physics_samples := PackedFloat64Array()
	var transform_samples := PackedFloat64Array()
	var shadow_samples := PackedFloat64Array()
	for frame in range(1, SAMPLE_FRAMES[-1] + 1):
		await physics_frame
		if frame >= 30:
			physics_samples.append(
				Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			)
			if renderer != null:
				transform_samples.append(renderer.last_transform_sync_ms)
				shadow_samples.append(renderer.shadow_clipmaps.last_dynamic_update_ms)
		if frame in SAMPLE_FRAMES:
			_report(world, joints, renderer, frame)
	print("PHYSICS_ACTIVITY_SUMMARY ", JSON.stringify({
		"physics_p50_ms": snappedf(_percentile(physics_samples, 0.50), 0.001),
		"physics_p95_ms": snappedf(_percentile(physics_samples, 0.95), 0.001),
		"transform_mean_ms": snappedf(_mean(transform_samples), 0.001),
		"dynamic_shadow_mean_ms": snappedf(_mean(shadow_samples), 0.001),
		"dynamic_shadow_p95_ms": snappedf(_percentile(shadow_samples, 0.95), 0.001),
		"pending_impacts": int(world.get_metrics().pending_physics_impacts),
	}))
	quit(0)


static func _mean(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / values.size()


static func _percentile(values: PackedFloat64Array, fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(roundi((sorted.size() - 1) * fraction), 0, sorted.size() - 1)]


func _report(
	world: VoxelWorld3D, joints: VoxelJoints, renderer: VoxelRenderSystem, frame: int
) -> void:
	world._update_metrics()
	var awake_with_joints := 0
	var awake_without_joints := 0
	var moving := 0
	var worst: Array[Dictionary] = []
	for body in world.get_dynamic_bodies():
		if not is_instance_valid(body) or not body.is_awake():
			continue
		var rigid := body.get_physics_body() as RigidBody3D
		if rigid == null:
			continue
		var body_joints: Array = joints._by_body.get(body.get_instance_id(), []) if joints != null else []
		if body_joints.is_empty():
			awake_without_joints += 1
		else:
			awake_with_joints += 1
		var speed := rigid.linear_velocity.length()
		var angular_speed := rigid.angular_velocity.length()
		if speed > 0.01 or angular_speed > 0.01:
			moving += 1
		worst.append({
			"name": body.name,
			"speed": snappedf(speed, 0.001),
			"angular_speed": snappedf(angular_speed, 0.001),
			"joints": body_joints.size(),
			"boxes": body.compound_boxes,
			"voxels": body.get_total_voxels(),
		})
	worst.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.speed) + float(a.angular_speed) > float(b.speed) + float(b.angular_speed)
	)
	print("PHYSICS_ACTIVITY_SAMPLE ", JSON.stringify({
		"frame": frame,
		"awake": world.awake_bodies,
		"awake_with_joints": awake_with_joints,
		"awake_without_joints": awake_without_joints,
		"moving": moving,
		"pending_impacts": int(world.get_metrics().pending_physics_impacts),
		"physics_impacts": world.physics_impacts,
		"physics_ms": snappedf(
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.001
		),
		"transform_ms": snappedf(renderer.last_transform_sync_ms, 0.001) \
			if renderer != null else 0.0,
		"dynamic_shadow_ms": snappedf(renderer.shadow_clipmaps.last_dynamic_update_ms, 0.001) \
			if renderer != null and renderer.shadow_clipmaps != null else 0.0,
		"worst": worst.slice(0, mini(12, worst.size())),
	}))
