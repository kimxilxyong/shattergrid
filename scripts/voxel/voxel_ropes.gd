class_name VoxelRopes
extends MeshInstance3D
## Scene adapter for native cable modules. Anchor and Node ownership remains here; Verlet
## integration, constraints, raycasts, tension, Jolt forces, and mesh preparation live in C++.

const SEGMENTS := 8
const ITERATIONS := 6
const GRAVITY := 9.8
const PINNED_DRAG_PER_SECOND := 3.7
const LOOSE_DRAG_PER_SECOND := 0.28
const SLEEP_EPSILON := 0.0015
const SLEEP_FRAMES := 20
const WAKE_PADDING := 1.5
const STIFFNESS := 20_000.0
const FORCE_PER_STRENGTH := 10_000.0
const DEFAULT_STRENGTH := 1.0
const TENSION_DAMPING := 2_000.0
const TENSION_SLACK := 0.02
const DEFAULT_MAX_STRETCH := 0.75
const MAX_ACCELERATION := 16.0
const ANCHOR_RADIUS := 0.6
const COLLISION_SKIN := 0.05
const COLLISION_FRICTION := 0.5
const DEAD_POINT := Vector3(0.0, -10_000.0, 0.0)

## Ownership metadata only. Point buffers and physics state are not duplicated here.
var _spans: Array[Dictionary] = []
var _solver := VoxelRopeSolver.new()
var _physics_bridge := VoxelRopePhysicsBridge.new()
var _solver_configured := false
var _mesh := ArrayMesh.new()
var pulling := 0
var last_physics_ms := 0.0
var last_raycasts := 0
var last_collision_hits := 0


func _ready() -> void:
	_configure_solver()
	mesh = _mesh
	var shader_material := ShaderMaterial.new()
	shader_material.shader = load("res://shaders/rope.gdshader")
	material_override = shader_material
	global_transform = Transform3D.IDENTITY
	set_physics_process(not _spans.is_empty())


func _configure_solver() -> void:
	if _solver_configured:
		return
	_solver.configure(
		SEGMENTS, ITERATIONS, GRAVITY, PINNED_DRAG_PER_SECOND, LOOSE_DRAG_PER_SECOND,
		SLEEP_EPSILON, SLEEP_FRAMES
	)
	_solver_configured = true


func add_span(
	from: Vector3, to: Vector3, slack: float,
	body_a: VoxelBody3D = null, body_b: VoxelBody3D = null,
	strength := DEFAULT_STRENGTH, max_stretch := DEFAULT_MAX_STRETCH
) -> void:
	_configure_solver()
	var solver_index := _solver.add_span(from, to, slack, strength, max_stretch)
	var hold_key := "rope:%d:%d" % [get_instance_id(), solver_index]
	_spans.append({
		"solver_index": solver_index,
		"body_a": body_a,
		"body_b": body_b,
		"local_a": _to_local(body_a, from),
		"local_b": _to_local(body_b, to),
		"pin_a": true,
		"pin_b": true,
		"physics_hold_key_a": hold_key + ":a",
		"physics_hold_key_b": hold_key + ":b",
	})
	if body_a != null:
		body_a.acquire_physics_hold(hold_key + ":a")
	if body_b != null:
		body_b.acquire_physics_hold(hold_key + ":b")
	if is_inside_tree():
		set_physics_process(true)


static func _to_local(body: VoxelBody3D, world_point: Vector3) -> Vector3:
	if body == null:
		return world_point
	var physics := body.get_physics_body()
	return world_point if physics == null \
		else physics.global_transform.affine_inverse() * world_point


static func _anchor_world(body: VoxelBody3D, local: Vector3) -> Vector3:
	if body == null or not is_instance_valid(body):
		return local
	var physics := body.get_physics_body()
	return local if physics == null else physics.global_transform * local


func settle() -> void:
	if _spans.is_empty():
		return
	for _step in 150:
		_solver.simulate(1.0 / 60.0)
	_solver.sleep_all()
	_rebuild()
	set_physics_process(true)


func setup(world: VoxelWorld3D) -> void:
	world.body_split.connect(_on_body_split)
	world.body_unregistered.connect(_on_body_unregistered)
	world.voxel_impact.connect(
		func(center: Vector3, _removed: int, blast_radius: float) -> void:
			on_impact(center, blast_radius)
	)


func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec()
	last_raycasts = 0
	last_collision_hits = 0
	_follow_anchors()
	if _solver.get_awake_count() > 0:
		_solver.simulate(delta)
		var result: Dictionary = _physics_bridge.step(
			get_world_3d(), _solver, _spans, COLLISION_SKIN, COLLISION_FRICTION,
			TENSION_SLACK, STIFFNESS, TENSION_DAMPING, FORCE_PER_STRENGTH, MAX_ACCELERATION
		)
		for span_index: int in result.break_indices:
			_break_span(span_index)
		pulling = int(result.pulling)
		last_raycasts = int(result.raycasts)
		last_collision_hits = int(result.hits)
	if _solver.consume_mesh_dirty():
		_rebuild()
	last_physics_ms = (Time.get_ticks_usec() - started) / 1000.0


func _on_body_split(source: VoxelBody3D, created: Array[VoxelBody3D]) -> void:
	if source == null:
		return
	for span in _spans:
		var solver_index := int(span.solver_index)
		for side in ["a", "b"]:
			if span["body_" + side] != source or not bool(span["pin_" + side]):
				continue
			var at := _solver.get_point(solver_index, 0 if side == "a" else SEGMENTS)
			if VoxelDoor3D._body_has_material_near(source, at, ANCHOR_RADIUS):
				continue
			for candidate in created:
				if not VoxelDoor3D._body_has_material_near(candidate, at, ANCHOR_RADIUS):
					continue
				var hold_key := String(span.get("physics_hold_key_" + side, ""))
				source.release_physics_hold(hold_key)
				candidate.acquire_physics_hold(hold_key)
				span["body_" + side] = candidate
				span["local_" + side] = _to_local(candidate, at)
				break


func _on_body_unregistered(body: VoxelBody3D) -> void:
	if body == null:
		return
	for span in _spans:
		for side in ["a", "b"]:
			if span["body_" + side] == body:
				release_anchor(span, side)


func _follow_anchors() -> void:
	for span in _spans:
		var solver_index := int(span.solver_index)
		if _solver.is_span_dead(solver_index):
			continue
		if not _solver.is_span_awake(solver_index) \
				and not _body_can_move_now(span.body_a) and not _body_can_move_now(span.body_b):
			continue
		if bool(span.pin_a) and bool(span.pin_b) and span.body_a != null \
				and span.body_a == span.body_b:
			_follow_same_body_span(span)
			continue
		span.erase("same_body_locals")
		span.erase("same_body_generation")
		if bool(span.pin_a) and span.body_a != null:
			_solver.move_anchor(solver_index, true, _anchor_world(span.body_a, span.local_a))
		if bool(span.pin_b) and span.body_b != null:
			_solver.move_anchor(solver_index, false, _anchor_world(span.body_b, span.local_b))


func _follow_same_body_span(span: Dictionary) -> void:
	var body := span.body_a as VoxelBody3D
	if body == null or not is_instance_valid(body):
		return
	var physics := body.get_physics_body()
	if physics == null:
		return
	var solver_index := int(span.solver_index)
	var locals: PackedVector3Array = span.get("same_body_locals", PackedVector3Array())
	if locals.size() != SEGMENTS + 1 \
			or int(span.get("same_body_generation", -1)) != body.physics_generation:
		locals = PackedVector3Array()
		var inverse := physics.global_transform.affine_inverse()
		for point_value: Vector3 in _solver.get_span_points(solver_index):
			locals.append(inverse * point_value)
		span.same_body_locals = locals
		span.same_body_generation = body.physics_generation
	var rigid_points := PackedVector3Array()
	for local_point in locals:
		rigid_points.append(physics.global_transform * local_point)
	_solver.set_span_rigid_points(solver_index, rigid_points)


static func _body_can_move_now(candidate: Variant) -> bool:
	var body := candidate as VoxelBody3D
	return body != null and is_instance_valid(body) and body.state == VoxelBody3D.State.DYNAMIC \
		and body.is_awake()


static func elastic_tension_for_extension(extension: float) -> float:
	return maxf(0.0, extension - TENSION_SLACK) * STIFFNESS


func _break_span(span_index: int) -> void:
	var span: Dictionary = _spans[span_index]
	var pulling_a := _is_dynamic(span.body_a) and bool(span.pin_a)
	release_anchor(span, "a" if pulling_a else "b")


func release_anchor(span: Dictionary, side: String) -> void:
	var pin := "pin_" + side
	if not bool(span[pin]):
		return
	var body_key := "body_" + side
	var anchor_body := span.get(body_key) as VoxelBody3D
	if anchor_body != null and is_instance_valid(anchor_body):
		anchor_body.release_physics_hold(span.get("physics_hold_key_" + side, ""))
	span[body_key] = null
	span[pin] = false
	_solver.release_pin(int(span.solver_index), side == "a")


static func _is_dynamic(body: Variant) -> bool:
	var voxel_body := body as VoxelBody3D
	return voxel_body != null and is_instance_valid(voxel_body) \
		and voxel_body.state == VoxelBody3D.State.DYNAMIC


static func _velocity_at(body: Variant, world_point: Vector3) -> Vector3:
	return VoxelRopePhysicsBridge.new().velocity_at(body, world_point)


func on_impact(center: Vector3, blast_radius: float) -> void:
	for span_index in _spans.size():
		if _solver.is_span_dead(span_index):
			continue
		var a := _solver.get_point(span_index, 0)
		var b := _solver.get_point(span_index, SEGMENTS)
		if _distance_to_segment(center, a, b) > blast_radius + WAKE_PADDING:
			continue
		var span: Dictionary = _spans[span_index]
		if bool(span.pin_a) and span.body_a != null \
				and not VoxelDoor3D._body_has_material_near(span.body_a, a, ANCHOR_RADIUS):
			release_anchor(span, "a")
		if bool(span.pin_b) and span.body_b != null \
				and not VoxelDoor3D._body_has_material_near(span.body_b, b, ANCHOR_RADIUS):
			release_anchor(span, "b")
		if _solver.is_span_dead(span_index):
			continue
		var push := (_solver.get_span_center(span_index) - center).normalized() \
			* blast_radius * 0.35
		_solver.wake_span(span_index, push)


static func _distance_to_segment(point_value: Vector3, a: Vector3, b: Vector3) -> float:
	var segment := b - a
	var length_squared := segment.length_squared()
	if length_squared <= 0.000001:
		return point_value.distance_to(a)
	var fraction := clampf((point_value - a).dot(segment) / length_squared, 0.0, 1.0)
	return point_value.distance_to(a + segment * fraction)


func force_all_awake_for_probe(previous_offset := Vector3.ZERO) -> void:
	_solver.force_all_awake(previous_offset)


func sleep_all_for_probe() -> void:
	_solver.sleep_all()


func _rebuild() -> void:
	if _spans.is_empty():
		return
	var data: Dictionary = _solver.build_mesh_data(DEAD_POINT)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data.vertices
	arrays[Mesh.ARRAY_NORMAL] = data.normals
	arrays[Mesh.ARRAY_TEX_UV] = data.uvs
	arrays[Mesh.ARRAY_INDEX] = data.indices
	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


func span_count() -> int:
	return _solver.get_span_count()


func awake_count() -> int:
	return _solver.get_awake_count()


func get_diagnostics() -> Dictionary:
	var same_body_awake := 0
	var loose_awake := 0
	var external_awake := 0
	for index in _spans.size():
		if _solver.is_span_dead(index) or not _solver.is_span_awake(index):
			continue
		var span: Dictionary = _spans[index]
		if not bool(span.pin_a) or not bool(span.pin_b):
			loose_awake += 1
		elif span.body_a != null and span.body_a == span.body_b:
			same_body_awake += 1
		else:
			external_awake += 1
	return {
		"awake": awake_count(),
		"same_body_awake": same_body_awake,
		"loose_awake": loose_awake,
		"external_awake": external_awake,
		"pulling": pulling,
		"physics_ms": snappedf(last_physics_ms, 0.001),
		"raycasts": last_raycasts,
		"collision_hits": last_collision_hits,
	}


func bound_ends() -> int:
	var bound := 0
	for span in _spans:
		bound += 1 if span.body_a != null else 0
		bound += 1 if span.body_b != null else 0
	return bound


func has_body(span_index: int, side: String) -> bool:
	return _spans[span_index]["body_" + side] != null


func orphan_ends(span_index: int) -> int:
	var span := _spans[span_index]
	var orphans := 0
	for side in ["a", "b"]:
		var body = span["body_" + side]
		if bool(span["pin_" + side]) and body != null and not is_instance_valid(body):
			orphans += 1
	return orphans


func anchor_pinned(span_index: int, side: String) -> bool:
	return _solver.is_pin_a(span_index) if side == "a" else _solver.is_pin_b(span_index)


func attached_count() -> int:
	var attached := 0
	for span in _spans:
		if span.body_a != null or span.body_b != null:
			attached += 1
	return attached


func point(span_index: int, step: int) -> Vector3:
	return _solver.get_point(span_index, step)


func maximum_separation(span_index: int) -> float:
	return _solver.get_maximum_separation(span_index)
