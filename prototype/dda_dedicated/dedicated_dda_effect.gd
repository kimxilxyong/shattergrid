class_name DedicatedVoxelDDAEffect
extends CompositorEffect
## Dedicated opaque voxel pass for the renderer viability gate.
##
## It rasterizes one procedural full-screen triangle in POST_OPAQUE, traverses a GPU BVH and
## writes both HDR color and reverse-Z depth into Godot's live scene buffers. No proxy geometry
## or per-Shape material is submitted to Godot's spatial renderer.

const SHADER_FILE := preload("res://shaders/voxel/voxel_dda_dedicated.glsl")

var visualize_steps := false

## Scene lighting, in the same push constant as the rest. Defaults match the sun direction and
## constant ambient light previously hard-coded in the shader, so a scene without an imported map
## continues to look the same.
var sun_direction := Vector3(-0.45, 0.82, 0.35).normalized()
var sun_color := Color.WHITE
var sun_energy := 1.05
var ambient_sky := Color(0.3, 0.3, 0.3)
var ambient_ground := Color(0.3, 0.3, 0.3)
var ready_for_render := false
var last_error := ""

var _rd: RenderingDevice
var _shader := RID()
var _sampler := RID()
var _palette := RID()
var _node_buffer := RID()
var _shape_buffer := RID()
var _glass_node_buffer := RID()
var _glass_shape_buffer := RID()
var _brick_buffer := RID()
var _shadow_metadata_buffer := RID()
var _local_shadow_metadata_buffer := RID()
var _dummy_shadow_texture := RID()
var _shadow_static: Array[RID] = []
var _shadow_dynamic: Array[RID] = []
var _local_shadows: Array[RID] = []
var _voxel_texture := RID()
var _macro_texture := RID()
var _framebuffer := RID()
var _framebuffer_color := RID()
var _framebuffer_depth := RID()
var _pipelines: Dictionary = {}
var _dimensions := Vector3i.ZERO
var _macro_dimensions := Vector3i.ZERO
var _node_count := 0
var _glass_node_count := 0
var _voxel_size := 0.1
var _has_glass := false
var _configuration_mutex := Mutex.new()
var _pending_configuration: Dictionary = {}
var _pending_shadow_configuration: Dictionary = {}
var _pending_local_shadow_configuration: Dictionary = {}
var _node_buffer_bytes := 0
var _shape_buffer_bytes := 0
var _glass_node_buffer_bytes := 0
var _glass_shape_buffer_bytes := 0
var _brick_buffer_bytes := 0
var _brick_grid := Vector2i(1, 1)
var _frame_index := 0
var _bvh_topology: Array[Dictionary] = []
var _glass_bvh_topology: Array[Dictionary] = []
var _entries: Array[Dictionary] = []
var _glass_entries: Array[Dictionary] = []
var _node_parents := PackedInt32Array()
var _shape_leaves := PackedInt32Array()
var _glass_node_parents := PackedInt32Array()
var _glass_shape_leaves := PackedInt32Array()
var _glass_original_to_compact := {}
var _pending_shape_updates := {}
var _pending_node_updates := {}
var _pending_glass_shape_updates := {}
var _pending_glass_node_updates := {}
var _pending_entry_updates_since_usec := 0
var _upload_sources: Array = []


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE
	access_resolved_color = true
	access_resolved_depth = true
	RenderingServer.call_on_render_thread(_initialize_render_resources)


func configure(
	voxel_texture: RID,
	macro_texture: RID,
	dimensions: Vector3i,
	macro_dimensions: Vector3i,
	transforms: Array[Transform3D],
	voxel_size: float
) -> bool:
	var built := DedicatedVoxelBVH.build(transforms, Vector3(dimensions) * voxel_size)
	if built.is_empty():
		last_error = "Dedicated DDA requires at least one Shape"
		return false
	_configuration_mutex.lock()
	_pending_configuration = {
		"voxel_texture": voxel_texture,
		"macro_texture": macro_texture,
		"dimensions": dimensions,
		"macro_dimensions": macro_dimensions,
		"voxel_size": voxel_size,
		"node_bytes": built.node_bytes,
		"shape_bytes": built.shape_bytes,
		"node_count": built.node_count,
		"has_glass": false,
	}
	_configuration_mutex.unlock()
	return true


## Atlases owned by gameplay enqueue compact uploads. The compositor drains them from the render
## callback, avoiding a synchronous main/render-thread rendezvous every time a clipmap scrolls.
func configure_upload_sources(sources: Array) -> void:
	for source in sources:
		if source != null and source.has_method("enable_deferred_updates"):
			source.enable_deferred_updates()
	_configuration_mutex.lock()
	_upload_sources = sources.duplicate()
	_configuration_mutex.unlock()


func configure_entries(
	voxel_texture: RID,
	macro_texture: RID,
	entries: Array[Dictionary],
	palette_texels: PackedColorArray,
	palette_rows: int,
	brick_table := PackedInt32Array(),
	brick_grid := Vector2i.ZERO
) -> bool:
	# A refit is valid only if it preserves exactly the same leaves. Previously, size was rebuilt
	# only when the palette changed: growing beyond the 256 reserved leaves could reuse a topology
	# of a different size and leave records outside the BVH.
	var rebuild_topology := _topology_must_rebuild(
		_bvh_topology.is_empty(), _entries.size(), entries.size(), not palette_texels.is_empty()
	)
	var built := DedicatedVoxelBVH.build_entries(entries) if rebuild_topology \
		else DedicatedVoxelBVH.refit_entries(entries, _bvh_topology)
	if built.is_empty():
		last_error = "Dedicated DDA requires at least one Shape"
		return false
	_bvh_topology.assign(built.nodes)
	_entries.assign(entries.duplicate(true))
	var refit_index := DedicatedVoxelBVH.build_refit_index(
		_bvh_topology, _entries.size()
	)
	_node_parents = refit_index.parents
	_shape_leaves = refit_index.leaves
	var glass_entries: Array[Dictionary] = []
	_glass_original_to_compact.clear()
	for entry_index in entries.size():
		var entry: Dictionary = entries[entry_index]
		if bool(entry.get("has_glass", false)):
			_glass_original_to_compact[entry_index] = glass_entries.size()
			glass_entries.append(entry)
	var rebuild_glass := _topology_must_rebuild(
		_glass_bvh_topology.is_empty(), _glass_entries.size(), glass_entries.size(),
		not palette_texels.is_empty()
	)
	var glass_built := (
		DedicatedVoxelBVH.build_entries(glass_entries) if rebuild_glass
		else DedicatedVoxelBVH.refit_entries(glass_entries, _glass_bvh_topology)
	) if not glass_entries.is_empty() else {}
	if glass_built.is_empty():
		_glass_bvh_topology.clear()
		_glass_entries.clear()
		_glass_node_parents = PackedInt32Array()
		_glass_shape_leaves = PackedInt32Array()
	else:
		_glass_bvh_topology.assign(glass_built.nodes)
		_glass_entries.assign(glass_entries.duplicate(true))
		var glass_refit_index := DedicatedVoxelBVH.build_refit_index(
			_glass_bvh_topology, _glass_entries.size()
		)
		_glass_node_parents = glass_refit_index.parents
		_glass_shape_leaves = glass_refit_index.leaves
	_configuration_mutex.lock()
	_pending_shape_updates.clear()
	_pending_node_updates.clear()
	_pending_glass_shape_updates.clear()
	_pending_glass_node_updates.clear()
	_pending_configuration = {
		"voxel_texture": voxel_texture,
		"macro_texture": macro_texture,
		"dimensions": Vector3i.ZERO,
		"macro_dimensions": Vector3i.ZERO,
		"voxel_size": 0.1,
		"node_bytes": built.node_bytes,
		"shape_bytes": built.shape_bytes,
		"node_count": built.node_count,
		"has_glass": not glass_built.is_empty(),
		"glass_node_bytes": glass_built.get("node_bytes", PackedByteArray()),
		"glass_shape_bytes": glass_built.get("shape_bytes", PackedByteArray()),
		"glass_node_count": int(glass_built.get("node_count", 0)),
	}
	if not palette_texels.is_empty():
		_pending_configuration["palette_texels"] = palette_texels
		_pending_configuration["palette_rows"] = maxi(1, palette_rows)
	# Upload the brick table only when it changes: it is several megabytes, while the other metadata
	# is resynchronized as soon as any Shape moves.
	if not brick_table.is_empty():
		_pending_configuration["brick_table"] = brick_table
	if brick_grid != Vector2i.ZERO:
		_pending_configuration["brick_grid"] = brick_grid
	_configuration_mutex.unlock()
	return true


func get_entry_count() -> int:
	return _entries.size()


## CPU mirror of the transform packed for a leaf. Allows auditing the final scene -> renderer
## stage without reading back the Vulkan buffer or introducing GPU synchronization.
func get_entry_transform(index: int) -> Transform3D:
	if index < 0 or index >= _entries.size():
		return Transform3D.IDENTITY
	return (_entries[index] as Dictionary).get("transform", Transform3D.IDENTITY)


## Metadata work already packed by the main thread but not yet consumed by the render callback.
## This does not read Vulkan memory back or block the GPU; it only distinguishes a genuinely pending
## pose from an update queue already submitted to the RenderingDevice.
func get_pending_gpu_update_count() -> int:
	_configuration_mutex.lock()
	var count := _pending_shape_updates.size() + _pending_node_updates.size() \
		+ _pending_glass_shape_updates.size() + _pending_glass_node_updates.size()
	if not _pending_configuration.is_empty():
		count += 1
	_configuration_mutex.unlock()
	return count


## Age of the oldest unconsumed transform batch. A nonempty queue during movement is normal—it is
## prepared before the callback in the same frame—but a growing age indicates rendering has fallen
## behind physics.
func get_pending_gpu_update_age_ms() -> float:
	_configuration_mutex.lock()
	var since := _pending_entry_updates_since_usec
	_configuration_mutex.unlock()
	return (Time.get_ticks_usec() - since) / 1000.0 if since > 0 else 0.0


static func _topology_must_rebuild(
	topology_empty: bool, old_entry_count: int, new_entry_count: int, palette_changed: bool
) -> bool:
	return topology_empty or palette_changed or old_entry_count != new_entry_count


## Refit only moving leaves and their paths to the root. On Lee this replaces a full 2,247-Shape
## metadata/BVH repack per moving frame with one 240-byte Shape record and ~12 48-byte nodes.
func update_entry_transforms(updates: Array[Dictionary]) -> bool:
	var entry_updates: Array[Dictionary] = []
	for update: Dictionary in updates:
		entry_updates.append({
			"index": int(update.get("index", -1)),
			"transform": update.get("transform", Transform3D.IDENTITY),
		})
	return update_entries(entry_updates)


## Changes shading data only. It does not touch bounds or transforms, so refitting the BVH here
## would waste work every frame for any animated material.
func update_entry_visuals(updates: Array[Dictionary]) -> bool:
	if _entries.is_empty():
		return false
	var shape_updates := {}
	var glass_shape_updates := {}
	for update: Dictionary in updates:
		var entry_index := int(update.get("index", -1))
		if entry_index < 0 or entry_index >= _entries.size():
			return false
		var entry := (_entries[entry_index] as Dictionary).duplicate(true)
		entry.surface_animation = update.get("surface_animation", {})
		_entries[entry_index] = entry
		shape_updates[entry_index] = DedicatedVoxelBVH.pack_entry(entry)
		if _glass_original_to_compact.has(entry_index):
			var glass_index := int(_glass_original_to_compact[entry_index])
			var glass_entry := (_glass_entries[glass_index] as Dictionary).duplicate(true)
			glass_entry.surface_animation = entry.surface_animation
			_glass_entries[glass_index] = glass_entry
			glass_shape_updates[glass_index] = DedicatedVoxelBVH.pack_entry(glass_entry)
	_configuration_mutex.lock()
	_pending_shape_updates.merge(shape_updates, true)
	_pending_glass_shape_updates.merge(glass_shape_updates, true)
	_configuration_mutex.unlock()
	return true


## Updates complete reserved records as fragments appear/disappear, or transform-only records for
## bodies already present. Topology and buffer sizes remain fixed.
func update_entries(updates: Array[Dictionary]) -> bool:
	if _entries.is_empty() or _bvh_topology.is_empty():
		return false
	var shape_updates := {}
	var node_updates := {}
	var glass_shape_updates := {}
	var glass_node_updates := {}
	for update: Dictionary in updates:
		var entry_index := int(update.get("index", -1))
		if entry_index < 0 or entry_index >= _entries.size():
			return false
		var entry: Dictionary = (
			(update.entry as Dictionary).duplicate(true)
			if update.has("entry") else (_entries[entry_index] as Dictionary).duplicate(true)
		)
		if update.has("transform"):
			entry.transform = update.transform
		_entries[entry_index] = entry
		shape_updates[entry_index] = DedicatedVoxelBVH.pack_entry(entry)
		for node_index in DedicatedVoxelBVH.refit_entry(
			entry, entry_index, _bvh_topology, _node_parents, _shape_leaves
		):
			node_updates[node_index] = DedicatedVoxelBVH.pack_node(
				_bvh_topology[node_index]
			)
		if _glass_original_to_compact.has(entry_index):
			var glass_index := int(_glass_original_to_compact[entry_index])
			# Activating a reserved leaf changes dimensions, atlas, brick table, and palette, not just
			# the transform. Copying only the latter left glass fragments pointing to the 1³ placeholder,
			# retaining collision while disappearing from the transparent pass.
			var glass_entry := _glass_entry_after_update(
				_glass_entries[glass_index] as Dictionary, entry, update.has("entry")
			)
			_glass_entries[glass_index] = glass_entry
			glass_shape_updates[glass_index] = DedicatedVoxelBVH.pack_entry(glass_entry)
			for node_index in DedicatedVoxelBVH.refit_entry(
				glass_entry, glass_index, _glass_bvh_topology,
				_glass_node_parents, _glass_shape_leaves
			):
				glass_node_updates[node_index] = DedicatedVoxelBVH.pack_node(
					_glass_bvh_topology[node_index]
				)
	_configuration_mutex.lock()
	if _pending_shape_updates.is_empty() and _pending_node_updates.is_empty() \
			and _pending_glass_shape_updates.is_empty() \
			and _pending_glass_node_updates.is_empty():
		_pending_entry_updates_since_usec = Time.get_ticks_usec()
	_pending_shape_updates.merge(shape_updates, true)
	_pending_node_updates.merge(node_updates, true)
	_pending_glass_shape_updates.merge(glass_shape_updates, true)
	_pending_glass_node_updates.merge(glass_node_updates, true)
	_configuration_mutex.unlock()
	return true


static func _glass_entry_after_update(
	existing: Dictionary, updated: Dictionary, complete_entry: bool
) -> Dictionary:
	var result := updated.duplicate(true) if complete_entry else existing.duplicate(true)
	result.transform = updated.transform
	return result


func update_brick_table(brick_table: PackedInt32Array, brick_grid: Vector2i) -> void:
	_configuration_mutex.lock()
	_pending_configuration["brick_table"] = brick_table.duplicate()
	_pending_configuration["brick_grid"] = brick_grid
	_configuration_mutex.unlock()


func configure_shadow_clipmaps(
	static_textures: Array[RID], dynamic_textures: Array[RID], metadata: PackedFloat32Array
) -> void:
	_configuration_mutex.lock()
	_pending_shadow_configuration = {
		"static": static_textures.duplicate(),
		"dynamic": dynamic_textures.duplicate(),
		"metadata": metadata.duplicate(),
	}
	_configuration_mutex.unlock()


func update_shadow_metadata(metadata: PackedFloat32Array) -> void:
	_configuration_mutex.lock()
	_pending_shadow_configuration = {"metadata": metadata.duplicate()}
	_configuration_mutex.unlock()


func configure_local_shadow_volumes(
	textures: Array[RID], metadata: PackedFloat32Array
) -> void:
	_configuration_mutex.lock()
	_pending_local_shadow_configuration = {
		"textures": textures.duplicate(),
		"metadata": metadata.duplicate(),
	}
	_configuration_mutex.unlock()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# Keep cleanup inline: during PREDELETE the script instance must not dispatch another method
		# through itself because the engine may already have detached the script from the resource.
		if _rd != null:
			if _rd.framebuffer_is_valid(_framebuffer):
				_rd.free_rid(_framebuffer)
			for pipeline: RID in _pipelines.values():
				if pipeline.is_valid():
					_rd.free_rid(pipeline)
			if _node_buffer.is_valid():
				_rd.free_rid(_node_buffer)
			if _shape_buffer.is_valid():
				_rd.free_rid(_shape_buffer)
			if _glass_node_buffer.is_valid():
				_rd.free_rid(_glass_node_buffer)
			if _glass_shape_buffer.is_valid():
				_rd.free_rid(_glass_shape_buffer)
			if _brick_buffer.is_valid():
				_rd.free_rid(_brick_buffer)
			if _shadow_metadata_buffer.is_valid():
				_rd.free_rid(_shadow_metadata_buffer)
			if _local_shadow_metadata_buffer.is_valid():
				_rd.free_rid(_local_shadow_metadata_buffer)
			if _dummy_shadow_texture.is_valid():
				_rd.free_rid(_dummy_shadow_texture)
			if _palette.is_valid():
				_rd.free_rid(_palette)
			if _sampler.is_valid():
				_rd.free_rid(_sampler)
			if _shader.is_valid():
				_rd.free_rid(_shader)


# Everything below this point executes on Godot's render thread.
func _initialize_render_resources() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_fail("The dedicated DDA backend requires the global RenderingDevice")
		return
	var spirv: RDShaderSPIRV = SHADER_FILE.get_spirv()
	if spirv == null:
		_fail("Godot did not import the dedicated DDA GLSL shader")
		return
	if not spirv.compile_error_vertex.is_empty():
		_fail("Dedicated DDA vertex shader: %s" % spirv.compile_error_vertex)
		return
	if not spirv.compile_error_fragment.is_empty():
		_fail("Dedicated DDA fragment shader: %s" % spirv.compile_error_fragment)
		return
	_shader = _rd.shader_create_from_spirv(spirv, "Voxel DDA dedicated")
	if not _shader.is_valid():
		_fail("RenderingDevice could not create the dedicated DDA shader")
		return

	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler_state)
	_palette = _create_palette_texture(PackedColorArray(), 1)
	_dummy_shadow_texture = _create_dummy_shadow_texture()
	# Empty slot so the uniform set is valid before the first table arrives.
	_brick_buffer = _rd.storage_buffer_create(4, PackedInt32Array([-1]).to_byte_array())
	_brick_buffer_bytes = 4
	_shadow_static = [_dummy_shadow_texture, _dummy_shadow_texture, _dummy_shadow_texture, _dummy_shadow_texture]
	_shadow_dynamic = _shadow_static.duplicate()
	_local_shadows.resize(8)
	_local_shadows.fill(_dummy_shadow_texture)
	var disabled_shadow := PackedFloat32Array()
	disabled_shadow.resize(20)
	_shadow_metadata_buffer = _rd.uniform_buffer_create(80, disabled_shadow.to_byte_array())
	var disabled_local_shadow := PackedFloat32Array()
	disabled_local_shadow.resize(516)
	_local_shadow_metadata_buffer = _rd.uniform_buffer_create(
		2064, disabled_local_shadow.to_byte_array()
	)
	_apply_pending_configuration()
	_apply_pending_shadow_configuration()
	_apply_pending_local_shadow_configuration()


func _apply_pending_configuration() -> void:
	if _rd == null:
		return
	_configuration_mutex.lock()
	var configuration := _pending_configuration.duplicate()
	_pending_configuration.clear()
	var shape_updates := _pending_shape_updates.duplicate()
	var node_updates := _pending_node_updates.duplicate()
	var glass_shape_updates := _pending_glass_shape_updates.duplicate()
	var glass_node_updates := _pending_glass_node_updates.duplicate()
	_pending_shape_updates.clear()
	_pending_node_updates.clear()
	_pending_glass_shape_updates.clear()
	_pending_glass_node_updates.clear()
	_pending_entry_updates_since_usec = 0
	_configuration_mutex.unlock()
	if configuration.is_empty() and shape_updates.is_empty() and node_updates.is_empty() \
			and glass_shape_updates.is_empty() and glass_node_updates.is_empty():
		return

	if configuration.has("node_bytes"):
		var node_bytes: PackedByteArray = configuration.node_bytes
		var shape_bytes: PackedByteArray = configuration.shape_bytes
		if _node_buffer.is_valid() and node_bytes.size() == _node_buffer_bytes:
			_rd.buffer_update(_node_buffer, 0, node_bytes.size(), node_bytes)
		else:
			_free_buffer(_node_buffer)
			_node_buffer = _rd.storage_buffer_create(node_bytes.size(), node_bytes)
			_node_buffer_bytes = node_bytes.size()
		if _shape_buffer.is_valid() and shape_bytes.size() == _shape_buffer_bytes:
			_rd.buffer_update(_shape_buffer, 0, shape_bytes.size(), shape_bytes)
		else:
			_free_buffer(_shape_buffer)
			_shape_buffer = _rd.storage_buffer_create(shape_bytes.size(), shape_bytes)
			_shape_buffer_bytes = shape_bytes.size()
	_apply_buffer_updates(_shape_buffer, 240, shape_updates)
	_apply_buffer_updates(_node_buffer, 48, node_updates)
	var glass_node_bytes: PackedByteArray = configuration.get(
		"glass_node_bytes", PackedByteArray()
	)
	var glass_shape_bytes: PackedByteArray = configuration.get(
		"glass_shape_bytes", PackedByteArray()
	)
	if not glass_node_bytes.is_empty():
		if _glass_node_buffer.is_valid() \
				and glass_node_bytes.size() == _glass_node_buffer_bytes:
			_rd.buffer_update(
				_glass_node_buffer, 0, glass_node_bytes.size(), glass_node_bytes
			)
		else:
			_free_buffer(_glass_node_buffer)
			_glass_node_buffer = _rd.storage_buffer_create(
				glass_node_bytes.size(), glass_node_bytes
			)
			_glass_node_buffer_bytes = glass_node_bytes.size()
	if not glass_shape_bytes.is_empty():
		if _glass_shape_buffer.is_valid() \
				and glass_shape_bytes.size() == _glass_shape_buffer_bytes:
			_rd.buffer_update(
				_glass_shape_buffer, 0, glass_shape_bytes.size(), glass_shape_bytes
			)
		else:
			_free_buffer(_glass_shape_buffer)
			_glass_shape_buffer = _rd.storage_buffer_create(
				glass_shape_bytes.size(), glass_shape_bytes
			)
			_glass_shape_buffer_bytes = glass_shape_bytes.size()
	_apply_buffer_updates(_glass_shape_buffer, 240, glass_shape_updates)
	_apply_buffer_updates(_glass_node_buffer, 48, glass_node_updates)
	if configuration.has("brick_table"):
		var brick_bytes: PackedByteArray = (configuration.brick_table as PackedInt32Array).to_byte_array()
		if _brick_buffer.is_valid() and brick_bytes.size() == _brick_buffer_bytes:
			_rd.buffer_update(_brick_buffer, 0, brick_bytes.size(), brick_bytes)
		else:
			_free_buffer(_brick_buffer)
			_brick_buffer = _rd.storage_buffer_create(brick_bytes.size(), brick_bytes)
			_brick_buffer_bytes = brick_bytes.size()
	_brick_grid = configuration.get("brick_grid", _brick_grid)
	if configuration.has("palette_texels"):
		if _palette.is_valid():
			_rd.free_rid(_palette)
		_palette = _create_palette_texture(
			configuration.palette_texels, int(configuration.palette_rows)
		)
	if configuration.has("voxel_texture"):
		_voxel_texture = configuration.voxel_texture
		_macro_texture = configuration.macro_texture
		_dimensions = configuration.dimensions
		_macro_dimensions = configuration.macro_dimensions
		_node_count = configuration.node_count
		_glass_node_count = int(configuration.get("glass_node_count", 0))
		_has_glass = bool(configuration.get("has_glass", _has_glass)) \
			and _glass_node_buffer.is_valid() and _glass_shape_buffer.is_valid()
		_voxel_size = configuration.voxel_size
	ready_for_render = _shader.is_valid() and _sampler.is_valid() and _palette.is_valid() \
		and _node_buffer.is_valid() and _shape_buffer.is_valid() and _brick_buffer.is_valid() \
		and _voxel_texture.is_valid() and _macro_texture.is_valid()
	if not ready_for_render:
		_fail("Dedicated DDA configuration produced an invalid GPU resource")


func _apply_buffer_updates(buffer: RID, stride: int, updates: Dictionary) -> void:
	if not buffer.is_valid():
		return
	for key in updates:
		var bytes: PackedByteArray = updates[key]
		_rd.buffer_update(buffer, int(key) * stride, bytes.size(), bytes)


func _apply_pending_shadow_configuration() -> void:
	if _rd == null:
		return
	_configuration_mutex.lock()
	var configuration := _pending_shadow_configuration.duplicate()
	_pending_shadow_configuration.clear()
	_configuration_mutex.unlock()
	if configuration.is_empty():
		return
	if configuration.has("static") and (configuration.static as Array).size() == 4:
		_shadow_static.assign(configuration.static)
	if configuration.has("dynamic") and (configuration.dynamic as Array).size() == 4:
		_shadow_dynamic.assign(configuration.dynamic)
	if configuration.has("metadata"):
		var metadata: PackedFloat32Array = configuration.metadata
		if metadata.size() == 20 and _shadow_metadata_buffer.is_valid():
			_rd.buffer_update(_shadow_metadata_buffer, 0, 80, metadata.to_byte_array())


func _apply_pending_local_shadow_configuration() -> void:
	if _rd == null:
		return
	_configuration_mutex.lock()
	var configuration := _pending_local_shadow_configuration.duplicate()
	_pending_local_shadow_configuration.clear()
	_configuration_mutex.unlock()
	if configuration.is_empty():
		return
	if configuration.has("textures"):
		var textures: Array = configuration.textures
		for index in 8:
			_local_shadows[index] = textures[index] if index < textures.size() \
				and (textures[index] as RID).is_valid() else _dummy_shadow_texture
	if configuration.has("metadata"):
		var metadata: PackedFloat32Array = configuration.metadata
		if metadata.size() == 516 and _local_shadow_metadata_buffer.is_valid():
			_rd.buffer_update(_local_shadow_metadata_buffer, 0, 2064, metadata.to_byte_array())


func _render_callback(callback_type: EffectCallbackType, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_OPAQUE or _rd == null:
		return
	# These methods are already executing on the render thread. Applying queued metadata and texture
	# copies here prevents gameplay movement and damage from waiting for the renderer.
	_apply_pending_configuration()
	_apply_pending_shadow_configuration()
	_apply_pending_local_shadow_configuration()
	_configuration_mutex.lock()
	var upload_sources := _upload_sources.duplicate()
	_configuration_mutex.unlock()
	if not ready_for_render:
		_flush_upload_sources(upload_sources)
		return
	var buffers = render_data.get_render_scene_buffers()
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null:
		return
	var size: Vector2i = buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return

	var scene_uniform := RDUniform.new()
	scene_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	scene_uniform.binding = 0
	scene_uniform.add_id(scene_data.get_uniform_buffer())
	var voxel_uniform := _sampled_texture_uniform(1, _voxel_texture)
	var macro_uniform := _sampled_texture_uniform(2, _macro_texture)
	var palette_uniform := _sampled_texture_uniform(3, _palette)
	var node_uniform := _storage_buffer_uniform(4, _node_buffer)
	var shape_uniform := _storage_buffer_uniform(5, _shape_buffer)
	var shadow_uniforms: Array[RDUniform] = []
	for level in 4:
		shadow_uniforms.append(_sampled_texture_uniform(6 + level, _shadow_static[level]))
	for level in 4:
		shadow_uniforms.append(_sampled_texture_uniform(10 + level, _shadow_dynamic[level]))
	var shadow_metadata_uniform := RDUniform.new()
	shadow_metadata_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	shadow_metadata_uniform.binding = 14
	shadow_metadata_uniform.add_id(_shadow_metadata_buffer)
	var local_shadow_uniforms: Array[RDUniform] = []
	for level in 8:
		local_shadow_uniforms.append(_sampled_texture_uniform(15 + level, _local_shadows[level]))
	var brick_uniform := _storage_buffer_uniform(24, _brick_buffer)
	var local_shadow_metadata_uniform := RDUniform.new()
	local_shadow_metadata_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	local_shadow_metadata_uniform.binding = 23
	local_shadow_metadata_uniform.add_id(_local_shadow_metadata_buffer)
	var uniforms: Array[RDUniform] = [
		scene_uniform,
		voxel_uniform,
		macro_uniform,
		palette_uniform,
		node_uniform,
		shape_uniform,
		shadow_uniforms[0], shadow_uniforms[1], shadow_uniforms[2], shadow_uniforms[3],
		shadow_uniforms[4], shadow_uniforms[5], shadow_uniforms[6], shadow_uniforms[7],
		shadow_metadata_uniform,
		local_shadow_uniforms[0], local_shadow_uniforms[1], local_shadow_uniforms[2],
		local_shadow_uniforms[3], local_shadow_uniforms[4], local_shadow_uniforms[5],
		local_shadow_uniforms[6], local_shadow_uniforms[7], local_shadow_metadata_uniform,
		brick_uniform,
	]
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, uniforms)

	var view_count: int = buffers.get_view_count()
	_frame_index = (_frame_index + 1) % 4096
	for view in view_count:
		var color: RID = buffers.get_color_layer(view)
		var depth: RID = buffers.get_depth_layer(view)
		var framebuffer := _framebuffer_for(color, depth)
		if not framebuffer.is_valid():
			continue
		var pipeline := _pipeline_for(framebuffer, buffers.get_texture_samples(), false)
		if not pipeline.is_valid():
			continue
		var push_values := PackedFloat32Array([
			float(size.x), float(size.y), float(view), float(_node_count),
			256.0, 1.0 if visualize_steps else 0.0, 0.0, 0.0,
			float(_frame_index), float(_brick_grid.x), float(_brick_grid.y), 0.0,
			sun_direction.x, sun_direction.y, sun_direction.z, sun_energy,
			sun_color.r, sun_color.g, sun_color.b, 0.0,
			ambient_sky.r, ambient_sky.g, ambient_sky.b, 0.0,
			ambient_ground.r, ambient_ground.g, ambient_ground.b, 0.0,
		])
		var draw_list := _rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_DEFAULT_ALL)
		_rd.draw_list_bind_render_pipeline(draw_list, pipeline)
		_rd.draw_list_bind_uniform_set(draw_list, uniform_set, 0)
		_rd.draw_list_set_push_constant(draw_list, push_values.to_byte_array(), 112)
		_rd.draw_list_draw(draw_list, false, 1, 3)
		_rd.draw_list_end()
		if _has_glass:
			push_values[6] = 1.0
			push_values[3] = float(_glass_node_count)
			var glass_pipeline := _pipeline_for(framebuffer, buffers.get_texture_samples(), true)
			if not glass_pipeline.is_valid():
				continue
			var glass_uniforms := uniforms.duplicate()
			glass_uniforms[4] = _storage_buffer_uniform(4, _glass_node_buffer)
			glass_uniforms[5] = _storage_buffer_uniform(5, _glass_shape_buffer)
			var glass_uniform_set := UniformSetCacheRD.get_cache(
				_shader, 0, glass_uniforms
			)
			var glass_list := _rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_DEFAULT_ALL)
			_rd.draw_list_bind_render_pipeline(glass_list, glass_pipeline)
			_rd.draw_list_bind_uniform_set(glass_list, glass_uniform_set, 0)
			_rd.draw_list_set_push_constant(glass_list, push_values.to_byte_array(), 112)
			_rd.draw_list_draw(glass_list, false, 1, 3)
			_rd.draw_list_end()
	# Copy after the voxel draw has sampled the current atlas. This removes the image write→read
	# hazard from the visible pass; edits become visible on the following frame without stalling it.
	_flush_upload_sources(upload_sources)


func _flush_upload_sources(sources: Array) -> void:
	for source in sources:
		if source != null and source.has_method("flush_pending_render_thread"):
			source.flush_pending_render_thread()


func _framebuffer_for(color: RID, depth: RID) -> RID:
	if _rd.framebuffer_is_valid(_framebuffer) \
		and color == _framebuffer_color and depth == _framebuffer_depth:
		return _framebuffer
	if _rd.framebuffer_is_valid(_framebuffer):
		_rd.free_rid(_framebuffer)
	_framebuffer = _rd.framebuffer_create([color, depth])
	_framebuffer_color = color
	_framebuffer_depth = depth
	return _framebuffer


func _pipeline_for(framebuffer: RID, sample_count: int, glass: bool) -> RID:
	var framebuffer_format := _rd.framebuffer_get_format(framebuffer)
	var key := "%d:%d:%d" % [framebuffer_format, sample_count, int(glass)]
	if _pipelines.has(key):
		return _pipelines[key]

	var rasterization := RDPipelineRasterizationState.new()
	rasterization.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var multisample := RDPipelineMultisampleState.new()
	multisample.sample_count = sample_count as RenderingDevice.TextureSamples
	var depth_state := RDPipelineDepthStencilState.new()
	depth_state.enable_depth_test = true
	depth_state.enable_depth_write = not glass
	# Forward+ uses reverse Z: larger values are closer to the camera.
	depth_state.depth_compare_operator = RenderingDevice.COMPARE_OP_GREATER
	var blend_attachment := RDPipelineColorBlendStateAttachment.new()
	blend_attachment.enable_blend = glass
	if glass:
		blend_attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_SRC_ALPHA
		blend_attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
		blend_attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		blend_attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [blend_attachment]
	var pipeline := _rd.render_pipeline_create(
		_shader,
		framebuffer_format,
		RenderingDevice.INVALID_ID,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
		rasterization,
		multisample,
		depth_state,
		blend
	)
	if not pipeline.is_valid():
		_fail("RenderingDevice rejected the dedicated DDA render pipeline")
	_pipelines[key] = pipeline
	return pipeline


func _sampled_texture_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(_sampler)
	uniform.add_id(texture)
	return uniform


func _storage_buffer_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func _create_palette_texture(texels: PackedColorArray, rows: int) -> RID:
	var bytes := PackedByteArray()
	bytes.resize(512 * rows * 4)
	if texels.is_empty():
		_set_palette_color(bytes, 1, Color("b85a36"))
		_set_palette_color(bytes, 2, Color("a8a9ad"))
		_set_palette_color(bytes, 3, Color("59636e"))
		_set_palette_color(bytes, 256 + 1, Color(0.82, 0.0, 0.0, 0.0))
		_set_palette_color(bytes, 256 + 2, Color(0.82, 0.0, 0.0, 0.0))
		_set_palette_color(bytes, 256 + 3, Color(0.35, 0.55, 0.0, 0.0))
	else:
		for index in mini(texels.size(), 512 * rows):
			_set_palette_color(bytes, index, texels[index])
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.width = 512
	format.height = rows
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var initial: Array[PackedByteArray] = [bytes]
	return _rd.texture_create(format, RDTextureView.new(), initial)


func _create_dummy_shadow_texture() -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R8_UINT
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var initial: Array[PackedByteArray] = [PackedByteArray([0])]
	return _rd.texture_create(format, RDTextureView.new(), initial)


func _set_palette_color(bytes: PackedByteArray, index: int, color: Color) -> void:
	var offset := index * 4
	bytes[offset + 0] = int(round(color.r * 255.0))
	bytes[offset + 1] = int(round(color.g * 255.0))
	bytes[offset + 2] = int(round(color.b * 255.0))
	bytes[offset + 3] = int(round(color.a * 255.0))


func _palette_has_glass(colors: PackedColorArray) -> bool:
	for index in colors.size():
		if index % 256 != 0 and colors[index].a < 0.995:
			return true
	return false


func _free_buffer(buffer: RID) -> void:
	if _rd != null and buffer.is_valid():
		_rd.free_rid(buffer)


func _release_render_resources() -> void:
	if _rd == null:
		return
	if _rd.framebuffer_is_valid(_framebuffer):
		_rd.free_rid(_framebuffer)
	for pipeline: RID in _pipelines.values():
		if pipeline.is_valid():
			_rd.free_rid(pipeline)
	_free_buffer(_node_buffer)
	_free_buffer(_shape_buffer)
	_free_buffer(_glass_node_buffer)
	_free_buffer(_glass_shape_buffer)
	_free_buffer(_brick_buffer)
	_free_buffer(_shadow_metadata_buffer)
	_free_buffer(_local_shadow_metadata_buffer)
	if _dummy_shadow_texture.is_valid():
		_rd.free_rid(_dummy_shadow_texture)
	if _palette.is_valid():
		_rd.free_rid(_palette)
	if _sampler.is_valid():
		_rd.free_rid(_sampler)
	if _shader.is_valid():
		_rd.free_rid(_shader)
	ready_for_render = false


func _fail(message: String) -> void:
	last_error = message
	ready_for_render = false
	push_error(message)
