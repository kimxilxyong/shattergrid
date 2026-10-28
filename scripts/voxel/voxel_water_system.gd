class_name VoxelWaterSystem
extends MeshInstance3D
## Map water: all lakes and the sea are combined into a single ArrayMesh and material.
##
## This is not a voxel volume or a second camera. The surface is rasterized once, and the shader
## reuses scene color/depth for refraction, foam, and a short SSR reflection. The normal texture is
## periodic and generated once at load time; it does not depend on external assets. Its spectrum
## avoids pure axes and 90-degree symmetry, so the tiling does not look like a grid.

const NORMAL_TEXTURE_SIZE := 128
const DEFAULT_COLOR := Color(0.018, 0.065, 0.072, 1.0)
const DEFAULT_VISIBILITY := 2.8
const GROUP := "voxel_water"
const SHORE_WIDTH := 0.48
const RIPPLE_CAPACITY := 24
const WATER_PHYSICS_INTERVAL := 1.0 / 30.0
## Each droplet is a cube half the size of a voxel, so a splash reads through the number of drops
## rather than the size of each one—just like smoke in `VoxelParticlePool`.
const SPLASH_DROP_SIZE := 0.05
const MAX_SPLASH_DROPS := 72

var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _uvs := PackedVector2Array()
var _uv2s := PackedVector2Array()
var _indices := PackedInt32Array()
var _polygons: Array[PackedVector3Array] = []
var _surface_records: Array[Dictionary] = []
var _shore_vertices := PackedVector3Array()
var _shore_colors := PackedColorArray()
var _shore_uvs := PackedVector2Array()
var _shore_indices := PackedInt32Array()
var _triangle_count := 0
var _total_area := 0.0
var _material: ShaderMaterial
var _world: VoxelWorld3D
var _shore_foam: MeshInstance3D
var _splash_particles: GPUParticles3D
var _ripple_mesh: MultiMeshInstance3D
var _ripples: Array[Dictionary] = []
var _ripple_cursor := 0
var _water_physics_elapsed := 0.0
var _body_wet := {}
var _rng := RandomNumberGenerator.new()
var splash_count := 0


func _init() -> void:
	name = "TeardownWater"
	add_to_group(GROUP)
	_rng.seed = 0x5741544552
	visible = not "--water-disabled" in OS.get_cmdline_user_args()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = ShaderMaterial.new()
	_material.shader = load("res://shaders/water/water.gdshader")
	_material.set_shader_parameter("wave_normal", _make_wave_texture(NORMAL_TEXTURE_SIZE))
	_material.set_shader_parameter(
		"reflections_enabled", not "--water-no-reflections" in OS.get_cmdline_user_args()
	)
	_material.render_priority = 20
	material_override = _material


## Receives points already expressed in VoxelWorld3D's local space. Returns false only when the
## polygon cannot be triangulated, avoiding a partially built surface in shared buffers.
func add_polygon(
	points: PackedVector3Array, color := DEFAULT_COLOR, visibility := DEFAULT_VISIBILITY,
	ripples := 1.0, authored_depth := 0.0, authored_foam := 1.0
) -> bool:
	if points.size() < 3:
		return false
	var polygon_2d := PackedVector2Array()
	for point in points:
		polygon_2d.append(Vector2(point.x, point.z))
	var triangles := Geometry2D.triangulate_polygon(polygon_2d)
	if triangles.size() < 3:
		push_warning("VoxelWaterSystem: degenerate water polygon (%d vertices)" % points.size())
		return false
	var first_vertex := _vertices.size()
	var ripple_amount := clampf(float(ripples), 0.0, 1.0)
	var attenuation_distance := maxf(float(visibility), 0.2)
	var depth_hint := maxf(float(authored_depth), 0.0)
	var foam_amount := clampf(float(authored_foam), 0.0, 1.0)
	for point in points:
		_vertices.append(point)
		_normals.append(Vector3.UP)
		# World-space UVs: wave phase does not change when the map is split into multiple polygons.
		_uvs.append(Vector2(point.x, point.z) * 0.055)
		_colors.append(Color(color.r, color.g, color.b, ripple_amount))
		_uv2s.append(Vector2(depth_hint, attenuation_distance))
	for index in triangles:
		_indices.append(first_vertex + index)
	# Exact XZ area of the triangles for importer metrics and regression tests.
	for triangle in range(0, triangles.size(), 3):
		var a := polygon_2d[triangles[triangle]]
		var b := polygon_2d[triangles[triangle + 1]]
		var c := polygon_2d[triangles[triangle + 2]]
		_total_area += absf((b - a).cross(c - a)) * 0.5
	_triangle_count += triangles.size() / 3
	_polygons.append(points)
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	var height := 0.0
	for point in points:
		var horizontal := Vector2(point.x, point.z)
		minimum = minimum.min(horizontal)
		maximum = maximum.max(horizontal)
		height += point.y
	_surface_records.append({
		"polygon": polygon_2d,
		"bounds": Rect2(minimum, maximum - minimum),
		"height": height / float(points.size()),
		"depth": depth_hint,
	})
	_append_shore_strip(points, polygon_2d, foam_amount)
	return true


## Upload the mesh once import is complete. Lee's three surfaces = one draw call.
func finish() -> void:
	var built := ArrayMesh.new()
	if not _vertices.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = _vertices
		arrays[Mesh.ARRAY_NORMAL] = _normals
		arrays[Mesh.ARRAY_COLOR] = _colors
		arrays[Mesh.ARRAY_TEX_UV] = _uvs
		arrays[Mesh.ARRAY_TEX_UV2] = _uv2s
		arrays[Mesh.ARRAY_INDEX] = _indices
		built.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = built
	_build_shore_foam()
	_setup_ripples()
	_setup_splash_particles()


## Enable physical interaction after the importer has registered all Bodies.
func setup(world: VoxelWorld3D) -> void:
	_world = world
	if world != null and not world.body_unregistered.is_connected(_on_body_unregistered):
		world.body_unregistered.connect(_on_body_unregistered)
	set_physics_process(world != null and not _surface_records.is_empty())


## Cheap equivalent of `IsPointInWater`: check Rect2 first, then the exact polygon.
func sample_surface(world_point: Vector3) -> Dictionary:
	var local := to_local(world_point) if is_inside_tree() else world_point
	var horizontal := Vector2(local.x, local.z)
	var best := {}
	var best_height := -INF
	for record: Dictionary in _surface_records:
		var bounds := record.bounds as Rect2
		if not bounds.grow(0.001).has_point(horizontal) \
				or not Geometry2D.is_point_in_polygon(horizontal, record.polygon):
			continue
		var height := float(record.height)
		if height <= best_height:
			continue
		best_height = height
		var global_surface := to_global(Vector3(local.x, height, local.z)) if is_inside_tree() \
			else Vector3(local.x, height, local.z)
		best = {
			"inside": true,
			"surface_y": global_surface.y,
			"depth": float(record.depth),
		}
	return best


func is_point_in_water(world_point: Vector3) -> bool:
	var sample := sample_surface(world_point)
	if sample.is_empty() or world_point.y > float(sample.surface_y):
		return false
	var depth := float(sample.depth)
	return depth <= 0.0 or world_point.y >= float(sample.surface_y) - depth


func _physics_process(delta: float) -> void:
	if _world == null:
		return
	_water_physics_elapsed += delta
	if _water_physics_elapsed < WATER_PHYSICS_INTERVAL:
		return
	var step := _water_physics_elapsed
	_water_physics_elapsed = 0.0
	for body: VoxelBody3D in _world.get_awake_dynamic_bodies():
		if body.collision_handoff_pending:
			continue
		_apply_body_water(body, step)


func _apply_body_water(body: VoxelBody3D, delta: float) -> void:
	var rigid := body.get_physics_body() as RigidBody3D
	var shapes := body.get_shapes()
	if rigid == null or shapes.is_empty():
		return
	var bounds := shapes[0].world_bounds()
	for index in range(1, shapes.size()):
		bounds = bounds.merge(shapes[index].world_bounds())
	var center := rigid.to_global(rigid.center_of_mass)
	var sample := sample_surface(center)
	var key := body.get_instance_id()
	if sample.is_empty():
		_body_wet[key] = false
		if rigid is VoxelVehicle3D:
			(rigid as VoxelVehicle3D).update_water_submersion(0.0, -INF)
		return
	var surface_y := float(sample.surface_y)
	var bottom := bounds.position.y
	var top := bounds.end.y
	var authored_depth := float(sample.depth)
	var overlaps := bottom < surface_y and top > surface_y - (
		authored_depth if authored_depth > 0.0 else 1000.0
	)
	if not overlaps:
		_body_wet[key] = false
		if rigid is VoxelVehicle3D:
			(rigid as VoxelVehicle3D).update_water_submersion(0.0, surface_y)
		return
	var submerged := clampf((surface_y - bottom) / maxf(bounds.size.y, 0.12), 0.0, 1.0)
	if rigid is VoxelVehicle3D:
		(rigid as VoxelVehicle3D).update_water_submersion(submerged, surface_y)
	var was_wet := bool(_body_wet.get(key, false))
	if not was_wet and (rigid.linear_velocity.y < -0.8 or rigid.linear_velocity.length() > 2.2):
		emit_splash(
			Vector3(center.x, surface_y + 0.025, center.z),
			clampf(sqrt(maxf(rigid.mass, 1.0)) * rigid.linear_velocity.length() * 0.055, 0.4, 5.0)
		)
	_body_wet[key] = true
	# Nothing floats except the player, who swims independently in `player.gd`. Buoyancy on the box
	# exterior dejaba los escombros y las cajas haciendo corcho en la superficie del mapa entero:
	# here, a Body that falls into the water sinks; only drag reduces its downward velocity.
	var velocity := rigid.linear_velocity
	var drag_fraction := minf(0.82, submerged * delta * (1.4 + velocity.length() * 0.22))
	rigid.apply_central_impulse(-velocity * rigid.mass * drag_fraction)


func emit_splash(position: Vector3, intensity := 1.0) -> void:
	if _splash_particles == null or _ripple_mesh == null:
		return
	var strength := clampf(float(intensity), 0.2, 5.0)
	var drops := clampi(ceili(16.0 + strength * 11.0), 16, MAX_SPLASH_DROPS)
	for _drop in drops:
		var angle := _rng.randf_range(0.0, TAU)
		var horizontal := Vector3(cos(angle), 0.0, sin(angle))
		var velocity := horizontal * _rng.randf_range(0.25, 1.1 + strength * 0.24) \
			+ Vector3.UP * _rng.randf_range(1.4, 3.2 + strength * 0.48)
		# Align to the droplet grid, like any cube in the world.
		var spawn := (position + horizontal * _rng.randf_range(0.0, 0.22)) \
			.snapped(Vector3.ONE * SPLASH_DROP_SIZE)
		_splash_particles.emit_particle(
			Transform3D(Basis.IDENTITY, spawn),
			velocity, Color(0.74, 0.88, 0.9, 1.0), Color(0, 0, 0, 0),
			GPUParticles3D.EMIT_FLAG_POSITION | GPUParticles3D.EMIT_FLAG_VELOCITY \
				| GPUParticles3D.EMIT_FLAG_COLOR
		)
	var slot := _ripple_cursor
	_ripple_cursor = (_ripple_cursor + 1) % RIPPLE_CAPACITY
	_ripples[slot] = {
		"active": true,
		"position": (to_local(position) if is_inside_tree() else position) + Vector3.UP * 0.012,
		"age": 0.0, "life": 1.15 + strength * 0.12,
		"start_radius": 0.18 + strength * 0.04,
		"end_radius": 1.1 + strength * 0.42,
		"strength": minf(1.0, 0.38 + strength * 0.16),
	}
	splash_count += 1
	_ripple_mesh.visible = true
	set_process(true)


func _process(delta: float) -> void:
	if _ripple_mesh == null:
		return
	var active := false
	for index in _ripples.size():
		var ripple: Dictionary = _ripples[index]
		if not bool(ripple.active):
			continue
		ripple.age = float(ripple.age) + delta
		var ratio := float(ripple.age) / float(ripple.life)
		if ratio >= 1.0:
			ripple.active = false
			_hide_ripple(index)
			continue
		active = true
		var radius := lerpf(float(ripple.start_radius), float(ripple.end_radius), ratio)
		_ripple_mesh.multimesh.set_instance_transform(
			index, Transform3D(Basis.IDENTITY.scaled(Vector3(radius, 1.0, radius)), ripple.position)
		)
		_ripple_mesh.multimesh.set_instance_color(
			index, Color(0.74, 0.88, 0.90, float(ripple.strength) * (1.0 - ratio))
		)
	_ripple_mesh.visible = active
	set_process(active)


func _append_shore_strip(
	points: PackedVector3Array, polygon_2d: PackedVector2Array, foam_amount: float
) -> void:
	if foam_amount <= 0.0:
		return
	var clockwise := Geometry2D.is_polygon_clockwise(polygon_2d)
	for index in points.size():
		var a := points[index]
		var b := points[(index + 1) % points.size()]
		var edge_2d := Vector2(b.x - a.x, b.z - a.z)
		if edge_2d.length_squared() < 0.000001:
			continue
		var inward_2d := Vector2(edge_2d.y, -edge_2d.x).normalized() if clockwise \
			else Vector2(-edge_2d.y, edge_2d.x).normalized()
		var inward := Vector3(inward_2d.x, 0.0, inward_2d.y) * SHORE_WIDTH
		var first := _shore_vertices.size()
		_shore_vertices.append_array([
			a + Vector3.UP * 0.026, b + Vector3.UP * 0.026,
			a + inward + Vector3.UP * 0.026, b + inward + Vector3.UP * 0.026,
		])
		_shore_uvs.append_array([
			Vector2(0.0, 0.0), Vector2(0.0, edge_2d.length()),
			Vector2(1.0, 0.0), Vector2(1.0, edge_2d.length()),
		])
		for _vertex in 4:
			_shore_colors.append(Color(0.78, 0.88, 0.86, foam_amount))
		_shore_indices.append_array([
			first, first + 1, first + 2, first + 1, first + 3, first + 2,
		])


func _build_shore_foam() -> void:
	if _shore_vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _shore_vertices
	arrays[Mesh.ARRAY_COLOR] = _shore_colors
	arrays[Mesh.ARRAY_TEX_UV] = _shore_uvs
	arrays[Mesh.ARRAY_INDEX] = _shore_indices
	var shore_mesh := ArrayMesh.new()
	shore_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_shore_foam = MeshInstance3D.new()
	_shore_foam.name = "ShoreFoam"
	_shore_foam.mesh = shore_mesh
	_shore_foam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var foam_material := ShaderMaterial.new()
	foam_material.shader = load("res://shaders/water/water_foam.gdshader")
	foam_material.render_priority = 21
	_shore_foam.material_override = foam_material
	add_child(_shore_foam)


func _setup_ripples() -> void:
	_ripple_mesh = MultiMeshInstance3D.new()
	_ripple_mesh.name = "WaterRipples"
	var plane := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, 1), Vector3(-1, 0, 1),
	])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	plane.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var ripple_material := ShaderMaterial.new()
	ripple_material.shader = load("res://shaders/water/water_ripple.gdshader")
	plane.surface_set_material(0, ripple_material)
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.mesh = plane
	multi.instance_count = RIPPLE_CAPACITY
	_ripple_mesh.multimesh = multi
	_ripple_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ripple_mesh.visible = false
	add_child(_ripple_mesh)
	for index in RIPPLE_CAPACITY:
		_ripples.append({"active": false})
		_hide_ripple(index)
	set_process(false)


func _hide_ripple(index: int) -> void:
	if _ripple_mesh != null:
		_ripple_mesh.multimesh.set_instance_transform(
			index, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3.DOWN * 10_000.0)
		)
		_ripple_mesh.multimesh.set_instance_color(index, Color(0, 0, 0, 0))


func _setup_splash_particles() -> void:
	_splash_particles = GPUParticles3D.new()
	_splash_particles.name = "WaterSplashes"
	_splash_particles.amount = 1024
	_splash_particles.lifetime = 1.25
	_splash_particles.local_coords = false
	_splash_particles.emitting = false
	_splash_particles.fixed_fps = 30
	_splash_particles.visibility_aabb = AABB(Vector3.ONE * -180.0, Vector3.ONE * 360.0)
	var process := ParticleProcessMaterial.new()
	process.gravity = Vector3(0.0, -9.8, 0.0)
	process.damping_min = 0.1
	process.damping_max = 0.35
	# No scale variation: a drop has a fixed size, just as a voxel has a fixed size.
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.14, 0.82, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 1.0), Color(0.82, 0.93, 0.95, 1.0),
		Color(0.6, 0.8, 0.84, 0.85), Color(0.5, 0.72, 0.78, 0.0),
	])
	var ramp_texture := GradientTexture1D.new()
	ramp_texture.gradient = ramp
	process.color_ramp = ramp_texture
	_splash_particles.process_material = process
	# Billboard droplets with blended alpha over a world of cubes looked like flat cutouts and
	# sorted inconsistently. They are now cubes with normals, shaded by the same light as the map,
	# and dissolve using hashed screen-door transparency instead of fading to nothing.
	var droplet := BoxMesh.new()
	droplet.size = Vector3.ONE * SPLASH_DROP_SIZE
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.12
	material.metallic = 0.0
	droplet.material = material
	_splash_particles.draw_pass_1 = droplet
	add_child(_splash_particles)


func _on_body_unregistered(body: VoxelBody3D) -> void:
	if body != null:
		_body_wet.erase(body.get_instance_id())


func get_surface_count_imported() -> int:
	return _polygons.size()


func get_triangle_count() -> int:
	return _triangle_count


func get_total_area() -> float:
	return _total_area


func get_smallest_surface_bounds() -> AABB:
	var best_area := INF
	var best_bounds := AABB()
	for points in _polygons:
		if points.is_empty():
			continue
		var minimum := Vector2(INF, INF)
		var maximum := Vector2(-INF, -INF)
		var minimum_y := INF
		var maximum_y := -INF
		for point in points:
			minimum = minimum.min(Vector2(point.x, point.z))
			maximum = maximum.max(Vector2(point.x, point.z))
			minimum_y = minf(minimum_y, point.y)
			maximum_y = maxf(maximum_y, point.y)
		var bounds_area := (maximum.x - minimum.x) * (maximum.y - minimum.y)
		if bounds_area < best_area:
			best_area = bounds_area
			best_bounds = AABB(
				Vector3(minimum.x, minimum_y, minimum.y),
				Vector3(maximum.x - minimum.x, maximum_y - minimum_y, maximum.y - minimum.y)
			)
	return best_bounds


func set_reflections_enabled(enabled: bool) -> void:
	if _material != null:
		_material.set_shader_parameter("reflections_enabled", enabled)


func configure_environment(sky_color: Color, sun_direction: Vector3, authored_sun: Color) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("sky_reflection_color", Vector3(
		sky_color.r, sky_color.g, sky_color.b
	))
	if sun_direction.length_squared() > 0.001:
		_material.set_shader_parameter("sun_direction_world", sun_direction.normalized())
	_material.set_shader_parameter("sun_color", Vector3(
		authored_sun.r, authored_sun.g, authored_sun.b
	))


## Small, repeatable, deterministic normal texture. It is composed as an oblique wave spectrum
## with low-frequency domain warping. All frequencies are integers, so it remains tileable, but
## avoids the square wavefronts from the previous crossing of three sine waves. It is calculated
## once, and the per-frame cost remains exactly two texture samples.
static func _make_wave_texture(size: int) -> ImageTexture:
	var heights := PackedFloat32Array()
	heights.resize(size * size)
	var waves := [
		Vector4(1.0, 3.0, 0.27, 0.31), Vector4(2.0, -5.0, 0.21, 2.17),
		Vector4(5.0, 4.0, 0.16, 4.02), Vector4(-7.0, 2.0, 0.13, 1.24),
		Vector4(9.0, -6.0, 0.095, 5.13), Vector4(-11.0, -8.0, 0.072, 3.38),
		Vector4(13.0, 5.0, 0.043, 0.88), Vector4(-4.0, 15.0, 0.028, 5.81),
	]
	for y in size:
		for x in size:
			var u := float(x) / float(size)
			var v := float(y) / float(size)
			# The warp is also periodic at the edges. It shifts the crests, not the runtime UV texture,
			# so it adds no reads or ALU to the water shader.
			var warped_u := u + sin(TAU * (2.0 * u + v) + 0.73) * 0.022 \
				+ sin(TAU * (u - 3.0 * v) + 2.41) * 0.011
			var warped_v := v + sin(TAU * (-u + 2.0 * v) + 1.37) * 0.019 \
				+ sin(TAU * (3.0 * u + v) + 4.63) * 0.009
			var height := 0.0
			for wave: Vector4 in waves:
				height += sin(TAU * (wave.x * warped_u + wave.y * warped_v) + wave.w) \
					* wave.z
			heights[y * size + x] = height
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var left := heights[y * size + posmod(x - 1, size)]
			var right := heights[y * size + posmod(x + 1, size)]
			var down := heights[posmod(y - 1, size) * size + x]
			var up := heights[posmod(y + 1, size) * size + x]
			var dhdu := (right - left) * float(size) * 0.5
			var dhdv := (up - down) * float(size) * 0.5
			var normal := Vector3(-dhdu * 0.034, 1.0, -dhdv * 0.034).normalized()
			var height := heights[y * size + x]
			image.set_pixel(x, y, Color(
				normal.x * 0.5 + 0.5, normal.y * 0.5 + 0.5,
				normal.z * 0.5 + 0.5, clampf(height * 0.24 + 0.5, 0.0, 1.0)
			))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)
