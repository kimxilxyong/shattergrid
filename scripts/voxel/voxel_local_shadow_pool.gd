class_name VoxelLocalShadowPool
extends Node
## Lazy pool of up to eight packed 256^3 logical occupancy volumes for point/spot lights.

signal volumes_changed(textures: Array[RID], metadata: PackedFloat32Array)

const MAX_VOLUMES := 8
const MAX_LIGHTS := 32
const LOGICAL_RESOLUTION := 256
const PACKED_RESOLUTION := 128

var _world: VoxelWorld3D
var _camera: Camera3D
var _slots := {}
var _dirty_lights := {}
var _active_keys: Array[int] = []
var _light_keys: Array[int] = []
var _last_metadata := PackedFloat32Array()


func setup(voxel_world: VoxelWorld3D, camera: Camera3D) -> void:
	_world = voxel_world
	_camera = camera
	_world.voxels_changed.connect(_on_voxels_changed)


func get_shader_metadata() -> PackedFloat32Array:
	var metadata := PackedFloat32Array()
	metadata.resize(MAX_LIGHTS * 16 + 4)
	for light_index in mini(MAX_LIGHTS, _light_keys.size()):
		var key := _light_keys[light_index]
		var light := instance_from_id(key) as Light3D
		if not is_instance_valid(light):
			continue
		var light_range := _light_range(light)
		var cell_size := maxf(0.1, light_range * 2.0 / LOGICAL_RESOLUTION)
		if _slots.has(key):
			cell_size = float((_slots[key] as Dictionary).cell_size)
		var origin := Vector3(_volume_origin_cells(light, cell_size)) * cell_size
		var direction := -light.global_basis.z.normalized()
		var spot_cosine := -2.0
		if light is SpotLight3D:
			spot_cosine = cos(deg_to_rad((light as SpotLight3D).spot_angle))
		var base := light_index * 16
		_write_vec4(metadata, base, light.global_position.x, light.global_position.y,
			light.global_position.z, light_range)
		_write_vec4(metadata, base + 4, direction.x, direction.y, direction.z, spot_cosine)
		_write_vec4(metadata, base + 8, light.light_color.r, light.light_color.g,
			light.light_color.b, light.light_energy)
		_write_vec4(metadata, base + 12, origin.x, origin.y, origin.z, cell_size)
	metadata[MAX_LIGHTS * 16] = mini(MAX_LIGHTS, _light_keys.size())
	metadata[MAX_LIGHTS * 16 + 1] = mini(MAX_VOLUMES, _active_keys.size())
	return metadata


func get_texture_rids() -> Array[RID]:
	var textures: Array[RID] = []
	for key in _active_keys:
		if _slots.has(key):
			textures.append((_slots[key].texture as VoxelAtlas3D).get_rd_rid())
	return textures


func _process(_delta: float) -> void:
	if not is_instance_valid(_camera):
		return
	var candidates: Array[Light3D] = []
	for node in get_tree().get_nodes_in_group("voxel_shadow_lights"):
		if (node is OmniLight3D or node is SpotLight3D) \
				and node.visible and node.light_energy > 0.0:
			candidates.append(node)
	candidates.sort_custom(func(a: Light3D, b: Light3D) -> bool:
		return _score(a) > _score(b)
	)
	if candidates.size() > MAX_LIGHTS:
		candidates.resize(MAX_LIGHTS)
	# Moving vehicle lights still illuminate the DDA, but do not rebuild a 128³ volume every frame.
	# Add lights with volumes first to preserve the index ↔ texture mapping used by the shader, then
	# add up to 32 lights without shadows.
	var shadow_candidates: Array[Light3D] = []
	for light in candidates:
		if not bool(light.get_meta("voxel_shadowless", false)):
			shadow_candidates.append(light)
	var selected := {}
	var selected_keys: Array[int] = []
	var changed := false
	for index in mini(MAX_VOLUMES, shadow_candidates.size()):
		var light := shadow_candidates[index]
		var key := light.get_instance_id()
		selected[key] = light
		selected_keys.append(key)
		if not _slots.has(key):
			_allocate(light)
			changed = true
	for key in _slots.keys():
		if not selected.has(key):
			_release_slot(key)
			changed = true
	if selected_keys != _active_keys:
		_active_keys = selected_keys
		changed = true
	var ordered_lights: Array[Light3D] = []
	for key in selected_keys:
		ordered_lights.append(selected[key])
	for light in candidates:
		if not selected.has(light.get_instance_id()):
			ordered_lights.append(light)
		if ordered_lights.size() >= MAX_LIGHTS:
			break
	var light_keys: Array[int] = []
	for light in ordered_lights:
		light_keys.append(light.get_instance_id())
	if light_keys != _light_keys:
		_light_keys = light_keys
		changed = true
	for key in selected:
		var slot: Dictionary = _slots[key]
		var light: Light3D = selected[key]
		if slot.transform != light.global_transform:
			slot.transform = light.global_transform
			_dirty_lights[key] = true
		var current_range := _light_range(light)
		if not is_equal_approx(float(slot.range), current_range):
			slot.range = current_range
			slot.cell_size = maxf(0.1, current_range * 2.0 / LOGICAL_RESOLUTION)
			_dirty_lights[key] = true
		if _dirty_lights.has(key):
			_rebuild_slot(slot)
			_dirty_lights.erase(key)
			changed = true
	var metadata := get_shader_metadata()
	if metadata != _last_metadata:
		_last_metadata = metadata
		changed = true
	if changed:
		volumes_changed.emit(get_texture_rids(), metadata)


func _allocate(light: Light3D) -> void:
	var bytes := PackedByteArray()
	bytes.resize(PACKED_RESOLUTION * PACKED_RESOLUTION * PACKED_RESOLUTION)
	var texture := VoxelAtlas3D.new()
	texture.create(Vector3i.ONE * PACKED_RESOLUTION, bytes, true)
	var diameter := _light_range(light) * 2.0
	_slots[light.get_instance_id()] = {
		"light": light,
		"texture": texture,
		"bytes": bytes,
		"cell_size": maxf(0.1, diameter / LOGICAL_RESOLUTION),
		"range": _light_range(light),
		"transform": light.global_transform,
	}
	_dirty_lights[light.get_instance_id()] = true


## Origin of a light volume, in integer cells. The C++ rasterizer works in cells; rounding here and
## storing the same value in metadata keeps the volume and shader data in sync. The offset from the
## unadjusted origin is less than one cell.
static func _volume_origin_cells(light: Light3D, cell_size: float) -> Vector3i:
	var half_extent := cell_size * LOGICAL_RESOLUTION * 0.5
	return Vector3i(((light.global_position - Vector3.ONE * half_extent) / cell_size).floor())


func _rebuild_slot(slot: Dictionary) -> void:
	var light := slot.light as Light3D
	var cell_size: float = slot.cell_size
	var origin_cells := _volume_origin_cells(light, cell_size)
	var bounds := AABB(
		Vector3(origin_cells) * cell_size, Vector3.ONE * cell_size * LOGICAL_RESOLUTION
	)
	# Only Shapes that intersect the light bounds. The rasterizer also rejects them, but doing it
	# here avoids passing thousands of irrelevant Shapes to it.
	var shapes := []
	var transforms := []
	var voxel_sizes := PackedFloat32Array()
	for body in get_tree().get_nodes_in_group(VoxelBody3D.GROUP):
		for shape in (body as VoxelBody3D).get_shapes():
			if not shape.world_bounds().intersects(bounds):
				continue
			shapes.append(shape.data)
			transforms.append(shape.global_transform)
			voxel_sizes.append(shape.voxel_size)
	# This used the same live-voxel loop as the sun shadow clipmap, with the same problem:
	# 1.58 M voxels/s in GDScript. There it only hurt during loading; here it rebuilt at runtime
	# whenever a light became dirty, causing a stutter during gameplay.
	var bytes: PackedByteArray = slot.bytes
	if shapes.is_empty():
		bytes.fill(0)
	else:
		bytes = VoxelShapeData.rasterize_occupancy_level(
			shapes, transforms, voxel_sizes, origin_cells,
			Vector3i.ONE * LOGICAL_RESOLUTION, cell_size, Vector3i.ONE * PACKED_RESOLUTION
		)
		slot.bytes = bytes
	(slot.texture as VoxelAtlas3D).update_region(
		bytes, Vector3i.ZERO, Vector3i.ONE * (PACKED_RESOLUTION - 1)
	)


func _on_voxels_changed(
	_shape: VoxelShape3D, world_aabb: AABB, _dirty_min: Vector3i, _dirty_max: Vector3i
) -> void:
	for key in _slots:
		var light := (_slots[key] as Dictionary).light as Light3D
		var reach := _light_range(light)
		if world_aabb.intersects(AABB(
			light.global_position - Vector3.ONE * reach, Vector3.ONE * reach * 2.0
		)):
			_dirty_lights[key] = true


func _score(light: Light3D) -> float:
	var distance_squared := maxf(1.0, light.global_position.distance_squared_to(_camera.global_position))
	var priority := float(light.get_meta("voxel_shadow_priority", 0.0))
	var reach := _light_range(light)
	return priority * 1000.0 + reach * reach / distance_squared


static func _light_range(light: Light3D) -> float:
	if light is OmniLight3D:
		return (light as OmniLight3D).omni_range
	if light is SpotLight3D:
		return (light as SpotLight3D).spot_range
	return 0.0


func _release_slot(key: int) -> void:
	var slot: Dictionary = _slots[key]
	(slot.texture as VoxelAtlas3D).release()
	_slots.erase(key)
	_dirty_lights.erase(key)


static func _write_vec4(
	array: PackedFloat32Array, offset: int, x: float, y: float, z: float, w: float
) -> void:
	array[offset] = x
	array[offset + 1] = y
	array[offset + 2] = z
	array[offset + 3] = w


func _exit_tree() -> void:
	for slot: Dictionary in _slots.values():
		(slot.texture as VoxelAtlas3D).release()
