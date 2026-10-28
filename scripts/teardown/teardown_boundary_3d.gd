class_name TeardownBoundary3D
extends Node3D
## Playable boundary authored by a Teardown map's `<boundary>`.
##
## The physical barrier uses thin boxes, one per polygon edge. The full representation is combined
## into one ArrayMesh, and the shader visually discards everything except a window around the point
## the player is approaching. Even Lee (31 edges) costs one draw call and 31 inexpensive 2D tests
## per frame; there are no particles, lights, or visual nodes per segment.

const WALL_BOTTOM := -64.0
const WALL_HEIGHT := 192.0
const WALL_THICKNESS := 0.32
const REVEAL_DISTANCE := 7.5
const REVEAL_RADIUS := 6.5
const PREDICTION_SECONDS := 0.9
const MIN_PREDICTION_LENGTH := 0.35
const VISUAL_RESPONSE := 11.0

const BARRIER_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, fog_disabled;

uniform vec3 reveal_position = vec3(0.0);
uniform float reveal_strength : hint_range(0.0, 1.0) = 0.0;
uniform float reveal_radius = 6.5;
uniform float active_segment = 0.0;

varying vec3 boundary_world_position;
varying float segment_selected;

void vertex() {
	segment_selected = 1.0 - step(0.1, abs(UV2.x - active_segment));
	// Unselected edges become degenerate triangles before rasterization. The full boundary remains
	// one mesh, but the GPU shades only the wall the player will touch.
	if (segment_selected < 0.5) {
		VERTEX = vec3(0.0);
	}
	boundary_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float horizontal_distance = distance(boundary_world_position.xz, reveal_position.xz);
	float radial = 1.0 - smoothstep(reveal_radius * 0.52, reveal_radius, horizontal_distance);
	float vertical_distance = abs(boundary_world_position.y - reveal_position.y);
	float vertical = 1.0 - smoothstep(3.8, 9.0, vertical_distance);

	// Yellow dots and a soft sweep communicate a boundary without raising an opaque wall.
	vec2 lattice = fract(vec2(UV.x * 1.15, boundary_world_position.y * 0.82));
	float dots = 1.0 - smoothstep(0.12, 0.23, length(lattice - vec2(0.5)));
	float scan_coord = fract(boundary_world_position.y * 0.115 - TIME * 0.42);
	float scan = pow(max(0.0, 1.0 - abs(scan_coord - 0.5) * 2.0), 7.0);
	float edge_glow = 0.055 + dots * 0.58 + scan * 0.22;
	float alpha = clamp(
		reveal_strength * segment_selected * radial * vertical * edge_glow, 0.0, 0.78
	);

	vec3 yellow = mix(vec3(1.0, 0.48, 0.025), vec3(1.0, 0.91, 0.30), dots);
	ALBEDO = yellow;
	EMISSION = yellow * (1.25 + dots * 1.8 + scan * 0.7);
	ALPHA = alpha;
}
"""

var _points := PackedVector2Array()
var _tracked_actor: Node3D
var _collision_body: StaticBody3D
var _barrier_mesh: MeshInstance3D
var _material: ShaderMaterial
var _reveal_point_local := Vector2.ZERO
var _reveal_strength := 0.0
var _last_actor_position := Vector3.INF


func setup(points: PackedVector3Array, tracked_actor: Node3D = null, collision := true) -> bool:
	_points.clear()
	for point in points:
		var point_2d := Vector2(point.x, point.z)
		if _points.is_empty() or not _points[-1].is_equal_approx(point_2d):
			_points.append(point_2d)
	if _points.size() > 1 and _points[0].is_equal_approx(_points[-1]):
		_points.resize(_points.size() - 1)
	if _points.size() < 3:
		set_process(false)
		return false

	_build_visual_mesh()
	if collision:
		_build_collision()
	set_tracked_actor(tracked_actor)
	return true


func set_tracked_actor(actor: Node3D) -> void:
	_tracked_actor = actor
	_last_actor_position = Vector3.INF
	set_process(_tracked_actor != null)
	if _barrier_mesh != null:
		_barrier_mesh.visible = false


func get_collision_segment_count() -> int:
	return 0 if _collision_body == null else _collision_body.get_child_count()


func get_reveal_strength() -> float:
	return _reveal_strength


func get_reveal_point() -> Vector3:
	return to_global(Vector3(_reveal_point_local.x, 0.0, _reveal_point_local.y))


func contains_world_point(point: Vector3) -> bool:
	var local := to_local(point)
	return Geometry2D.is_point_in_polygon(Vector2(local.x, local.z), _points)


func _process(delta: float) -> void:
	if _tracked_actor == null or not is_instance_valid(_tracked_actor):
		set_tracked_actor(null)
		return
	var actor_local_3d := to_local(_tracked_actor.global_position)
	var actor_local := Vector2(actor_local_3d.x, actor_local_3d.z)
	var nearest := _closest_point(actor_local)
	if nearest.is_empty():
		return

	var velocity_world := _actor_velocity()
	var velocity_local_3d := global_basis.inverse() * velocity_world
	var velocity := Vector2(velocity_local_3d.x, velocity_local_3d.z)
	var reveal_point: Vector2 = nearest.point
	var reveal_segment: int = nearest.segment
	var distance: float = nearest.distance
	var approach := 0.0
	if velocity.length() > 0.05 and distance > 0.001:
		approach = clampf(
			(velocity.normalized().dot((reveal_point - actor_local).normalized()) - 0.03) / 0.67,
			0.0, 1.0
		)
		var prediction_length := maxf(
			MIN_PREDICTION_LENGTH, velocity.length() * PREDICTION_SECONDS
		)
		var predicted := _first_intersection(
			actor_local, actor_local + velocity.normalized() * prediction_length
		)
		if not predicted.is_empty():
			reveal_point = predicted.point
			reveal_segment = predicted.segment
			distance = actor_local.distance_to(reveal_point)
			approach = 1.0

	var proximity := clampf((REVEAL_DISTANCE - distance) / REVEAL_DISTANCE, 0.0, 1.0)
	proximity *= proximity
	# It must remain readable while pressed against the wall, even after Jolt cancels velocity.
	var contact_linger := clampf((2.2 - distance) / 2.2, 0.0, 1.0)
	var target_strength := proximity * maxf(approach, contact_linger)
	var response := 1.0 - exp(-VISUAL_RESPONSE * maxf(delta, 0.0))
	_reveal_point_local = _reveal_point_local.lerp(reveal_point, response) \
		if _reveal_strength > 0.002 else reveal_point
	_reveal_strength = lerpf(_reveal_strength, target_strength, response)

	var reveal_world := to_global(Vector3(
		_reveal_point_local.x, actor_local_3d.y + 1.0, _reveal_point_local.y
	))
	_material.set_shader_parameter("reveal_position", reveal_world)
	_material.set_shader_parameter("reveal_strength", _reveal_strength)
	_material.set_shader_parameter("active_segment", float(reveal_segment))
	_barrier_mesh.visible = _reveal_strength > 0.003 or target_strength > 0.003
	_last_actor_position = _tracked_actor.global_position


func _actor_velocity() -> Vector3:
	if _tracked_actor is CharacterBody3D:
		return (_tracked_actor as CharacterBody3D).velocity
	if _tracked_actor is RigidBody3D:
		return (_tracked_actor as RigidBody3D).linear_velocity
	if _last_actor_position != Vector3.INF:
		return (_tracked_actor.global_position - _last_actor_position) \
			/ maxf(get_process_delta_time(), 0.0001)
	return Vector3.ZERO


func _closest_point(point: Vector2) -> Dictionary:
	var best_distance_squared := INF
	var best_point := Vector2.ZERO
	var best_segment := -1
	for index in _points.size():
		var start := _points[index]
		var end := _points[(index + 1) % _points.size()]
		var candidate := Geometry2D.get_closest_point_to_segment(point, start, end)
		var distance_squared := point.distance_squared_to(candidate)
		if distance_squared < best_distance_squared:
			best_distance_squared = distance_squared
			best_point = candidate
			best_segment = index
	if best_segment < 0:
		return {}
	return {
		"point": best_point,
		"distance": sqrt(best_distance_squared),
		"segment": best_segment,
		"inside": Geometry2D.is_point_in_polygon(point, _points),
	}


func _first_intersection(start: Vector2, end: Vector2) -> Dictionary:
	var best_distance_squared := INF
	var best_point := Vector2.ZERO
	var best_segment := -1
	for index in _points.size():
		var intersection: Variant = Geometry2D.segment_intersects_segment(
			start, end, _points[index], _points[(index + 1) % _points.size()]
		)
		if not intersection is Vector2:
			continue
		var distance_squared := start.distance_squared_to(intersection as Vector2)
		if distance_squared < best_distance_squared:
			best_distance_squared = distance_squared
			best_point = intersection
			best_segment = index
	return {} if best_segment < 0 else {
		"point": best_point, "distance": sqrt(best_distance_squared), "segment": best_segment,
	}


func _build_collision() -> void:
	_collision_body = StaticBody3D.new()
	_collision_body.name = "BoundaryCollision"
	var physics_material := PhysicsMaterial.new()
	physics_material.friction = 0.08
	physics_material.bounce = 0.0
	_collision_body.physics_material_override = physics_material
	add_child(_collision_body)
	for index in _points.size():
		var start := _points[index]
		var end := _points[(index + 1) % _points.size()]
		var direction := end - start
		var length := direction.length()
		if length < 0.01:
			continue
		var box := BoxShape3D.new()
		box.size = Vector3(length + WALL_THICKNESS * 2.0, WALL_HEIGHT, WALL_THICKNESS)
		var collision := CollisionShape3D.new()
		collision.name = "Edge%d" % index
		collision.shape = box
		collision.position = Vector3(
			(start.x + end.x) * 0.5,
			WALL_BOTTOM + WALL_HEIGHT * 0.5,
			(start.y + end.y) * 0.5
		)
		collision.rotation.y = -direction.angle()
		_collision_body.add_child(collision)


func _build_visual_mesh() -> void:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()
	var accumulated_length := 0.0
	for index in _points.size():
		var start := _points[index]
		var end := _points[(index + 1) % _points.size()]
		var length := start.distance_to(end)
		if length < 0.01:
			continue
		var base := vertices.size()
		vertices.append(Vector3(start.x, WALL_BOTTOM, start.y))
		vertices.append(Vector3(end.x, WALL_BOTTOM, end.y))
		vertices.append(Vector3(end.x, WALL_BOTTOM + WALL_HEIGHT, end.y))
		vertices.append(Vector3(start.x, WALL_BOTTOM + WALL_HEIGHT, start.y))
		uvs.append(Vector2(accumulated_length, 0.0))
		uvs.append(Vector2(accumulated_length + length, 0.0))
		uvs.append(Vector2(accumulated_length + length, WALL_HEIGHT))
		uvs.append(Vector2(accumulated_length, WALL_HEIGHT))
		var segment_id := float(index)
		for _vertex in 4:
			uv2s.append(Vector2(segment_id, 0.0))
		indices.append_array(PackedInt32Array([
			base, base + 1, base + 2, base, base + 2, base + 3,
		]))
		accumulated_length += length

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var shader := Shader.new()
	shader.code = BARRIER_SHADER
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter("reveal_radius", REVEAL_RADIUS)
	_barrier_mesh = MeshInstance3D.new()
	_barrier_mesh.name = "BoundaryWarning"
	_barrier_mesh.mesh = mesh
	_barrier_mesh.material_override = _material
	_barrier_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_barrier_mesh.extra_cull_margin = REVEAL_RADIUS
	_barrier_mesh.visible = false
	add_child(_barrier_mesh)
