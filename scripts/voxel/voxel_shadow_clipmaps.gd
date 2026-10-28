class_name VoxelShadowClipmaps
extends Node
## Full-map occupancy volume for sun and AO rays, with four resolution levels. Each R8UI texel
## stores a 2x2x2 block of cells, one bit per cell.
##
## Previously, these were four camera-centered clipmaps that moved with the camera, causing hitches
## while walking: whenever the camera crossed a level boundary, the newly entered slice had to be
## rasterized on the CPU. On Lee, that took 82–144 ms in a single frame. The volume is now fixed and
## covers the entire map, as in Teardown (1252x128x1252 texels with three mips). It never moves, so
## nothing is rasterized during play except changes caused by destruction or moving objects.
##
## Static and dynamic layers are combined in one volume. Keeping them separate would double memory
##—impractical for the full map—and require the shader to read two textures per sample and OR them
## together. The tradeoff is that moving an object requires rerasterizing its region, including
## nearby static geometry, but that region is small.
##
## Keep the `VoxelShadowClipmaps` class name for compatibility with the renderer and existing bindings.

const LEVELS := 4
## Level 0 cell size. Each level doubles: 0.2 / 0.4 / 0.8 / 1.6 m.
##
## At 0.1 m, all of Lee (329 x 73 x 367 m) required 1 GB. At 0.2 m, it uses 133 MB—the same as the
## previous four clipmaps—and resolution is reduced only in the first 51 m (the only region level 0
## previously covered at 0.1 m), in exchange for eliminating hitches.
const BASE_CELL_SIZE := 0.2
## Level 0 memory ceiling. For maps larger than Lee, increase cell size instead of exhausting VRAM.
const MAX_LEVEL0_BYTES := 192 * 1024 * 1024
## Padding around the map so rays leaving an edge do not read invalid data.
const VOLUME_PADDING := 2.0
## Hard per-frame limit on dynamic refreshes. Deferred work carries over: a shadow one frame late is
## invisible, while a 100 ms frame is not.
## Number of moving Shapes whose shadows refresh per frame. This is a hard limit, not a time budget:
## the previous version queued work it could not rasterize, and with 65 awake props, more regions
## were added per frame than removed. The queue grew without limit, and `_coalesce` (O(n^2) over
## that queue) climbed from 21 to 191 ms while nothing was touched.
const SHAPES_PER_FRAME := 12
## Squared deadband threshold. A fine-level cell is 10 cm.
const SHADOW_DEADBAND_SQ := 0.01
## Number of frames between sweeps for deleted Shapes.
const SWEEP_EVERY_FRAMES := 15

var last_upload_bytes := 0
var last_damage_upload_bytes := 0
var last_dynamic_update_ms := 0.0
var last_region_allocate_ms := 0.0
var last_region_raster_ms := 0.0
var last_region_upload_ms := 0.0
var last_damage_update_ms := 0.0
var total_memory_bytes := 0
var damage_updates_enabled := true

var _world: VoxelWorld3D
var _camera: Camera3D
var _textures: Array[VoxelAtlas3D] = []
## Cell coordinates (not meters) of the volume's lower corner, per level. All levels start at the
## same world position, expressed in their respective cell coordinates.
var _origins: Array[Vector3i] = []
var _logical_sizes: Array[Vector3i] = []
var _packed_sizes: Array[Vector3i] = []
var _base_cell_size := BASE_CELL_SIZE
var _transform_tracker := VoxelTransformTracker.new()
var _update_planner := VoxelShadowUpdatePlanner.new()
var _movable_bounds := {}
var _shape_cache: Array[VoxelShape3D] = []
var _shape_cache_frame := -1
## Finds Shapes intersecting a box without scanning all 2,312 map Shapes for every region.
var _grid := VoxelShapeGrid.new()
## Dirty boxes that did not fit within the previous frame's budget.
## Round-robin starting point: without rotation, the first Shapes in the list use the quota every
## frame and the last ones never receive a shadow update.
## Pending damage boxes per level, merged only up to `MERGE_MAX_SIDE`.
var _pending_damage_regions: Array = []
var _damage_level_cursor := 1


## Rasterizing all four levels of the full map takes ~21 s of C++ on the main thread. With a loading
## screen connected, use `setup_progressive` to yield a frame between levels so something can be
## drawn; without one, `setup` remains a normal call and does not yield.
func setup(voxel_world: VoxelWorld3D, camera: Camera3D) -> bool:
	# Use a `Callable` because the parser requires `await` for every coroutine, and `_setup` never
	# suspends without a loading screen. Same reason as `TeardownMapImporter.import_map`.
	var result: Variant = _setup.call(voxel_world, camera, Callable())
	if result is bool:
		return result
	push_error("VoxelShadowClipmaps: startup without a loading screen was suspended")
	return false


func setup_progressive(
	voxel_world: VoxelWorld3D, camera: Camera3D, progress: Callable
) -> bool:
	return await _setup(voxel_world, camera, progress)


func _setup(voxel_world: VoxelWorld3D, camera: Camera3D, progress: Callable) -> bool:
	_world = voxel_world
	_camera = camera
	if not _measure_volume():
		return false
	total_memory_bytes = 0
	# Rasterize before creating the texture and use those bytes as initial `texture_create` data.
	# Creating an empty texture and uploading it later took 16.7 s of the 21 s startup: `update_region`
	# extracts the dirty region byte by byte in GDScript (here the dirty region is the entire volume,
	# 155 MB at level 0), copies it again to round up to a power of two, then copies it into a staging
	# buffer of the same size—all to produce the same bytes.
	var group := _shape_group()
	if progress.is_valid():
		progress.call(0.0, "Tracing shadow volume…  %d levels" % LEVELS)
		await Engine.get_main_loop().process_frame
	# The four levels are independent: they read the same Shapes without modifying them, and each
	# writes to its own buffer. Sequentially they take 4.7 s of startup; in parallel, they take as
	# long as the slowest one.
	var layers: Array[PackedByteArray] = []
	layers.resize(LEVELS)
	var task := WorkerThreadPool.add_group_task(
		_rasterize_into.bind(group, layers), LEVELS, LEVELS, true, "voxel_shadow_clipmaps"
	)
	WorkerThreadPool.wait_for_group_task_completion(task)
	for level in LEVELS:
		# The CPU copy is needed only to create the texture; nothing reads it afterward. At level 0,
		# it occupies 155 MB of unused RAM, so release it when the loop ends.
		var texture := VoxelAtlas3D.new()
		if not texture.create(_packed_sizes[level], layers[level], true):
			return false
		_textures.append(texture)
		total_memory_bytes += layers[level].size()
		_pending_damage_regions.append([] as Array[AABB])
	layers.clear()
	_track_shapes()
	_world.voxels_changed.connect(_on_voxels_changed)
	set_process(true)
	return true


## Fit the volume to the map. All levels share a corner, aligned to the coarsest cell size so cells
## in each level line up exactly without per-level rounding; the shader then needs only one origin.
func _measure_volume() -> bool:
	var bounds := AABB()
	var first := true
	for shape in _all_shapes():
		var box := shape.world_bounds()
		bounds = box if first else bounds.merge(box)
		first = false
	if first:
		return false
	bounds = bounds.grow(VOLUME_PADDING)
	_base_cell_size = BASE_CELL_SIZE
	while true:
		var coarse := _base_cell_size * float(1 << (LEVELS - 1))
		var low := Vector3(
			floorf(bounds.position.x / coarse) * coarse,
			floorf(bounds.position.y / coarse) * coarse,
			floorf(bounds.position.z / coarse) * coarse
		)
		var high := Vector3(
			ceilf(bounds.end.x / coarse) * coarse,
			ceilf(bounds.end.y / coarse) * coarse,
			ceilf(bounds.end.z / coarse) * coarse
		)
		_origins.clear()
		_logical_sizes.clear()
		_packed_sizes.clear()
		for level in LEVELS:
			var cell := _cell_size(level)
			_origins.append(Vector3i(
				roundi(low.x / cell), roundi(low.y / cell), roundi(low.z / cell)
			))
			var logical := Vector3i(
				roundi((high.x - low.x) / cell),
				roundi((high.y - low.y) / cell),
				roundi((high.z - low.z) / cell)
			)
			_logical_sizes.append(logical)
			_packed_sizes.append(logical / 2)
		var level0 := _packed_sizes[0]
		if level0.x * level0.y * level0.z <= MAX_LEVEL0_BYTES:
			break
		# The map is larger than expected: double the cell size and measure again instead of trying
		# to allocate a texture that will not fit.
		_base_cell_size *= 2.0
	return true


func get_static_rids() -> Array[RID]:
	var result: Array[RID] = []
	for texture in _textures:
		result.append(texture.get_rd_rid())
	return result


## Static and dynamic data share a volume. The shader reads only the "static" set; these bindings
## point to the same textures to avoid renumbering the entire uniform set. These four slots use no
## additional memory. Removing them would require renumbering shader and effect bindings 15–23.
func get_dynamic_rids() -> Array[RID]:
	return get_static_rids()


func get_upload_sources() -> Array:
	var result: Array = []
	result.append_array(_textures)
	return result


## Five vec4 values, exactly the size of the existing buffer:
##   [0] xyz = volume corner in meters, w = 1 if shadows are enabled
##   [1..4] xyz = logical level size in cells, w = meters per cell
func get_shader_metadata() -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(20)
	if _origins.is_empty():
		return values
	var origin_world := Vector3(_origins[0]) * _cell_size(0)
	values[0] = origin_world.x
	values[1] = origin_world.y
	values[2] = origin_world.z
	values[3] = 1.0
	for level in LEVELS:
		values[4 + level * 4 + 0] = float(_logical_sizes[level].x)
		values[4 + level * 4 + 1] = float(_logical_sizes[level].y)
		values[4 + level * 4 + 2] = float(_logical_sizes[level].z)
		values[4 + level * 4 + 3] = _cell_size(level)
	return values


## The four levels are RenderingDevice textures. Release them manually or Godot reports leaked RIDs
## on exit.
func _exit_tree() -> void:
	for texture: VoxelAtlas3D in _textures:
		texture.release()
	_textures.clear()


func _process(_delta: float) -> void:
	# The volume is fixed: nothing moves here. Process only changes.
	last_upload_bytes = 0
	last_region_allocate_ms = 0.0
	last_region_raster_ms = 0.0
	last_region_upload_ms = 0.0
	_flush_pending_damage_level()
	_update_dynamic_shapes()


func _track_shapes() -> void:
	var tracked_shapes: Array = []
	var tracked_bounds: Array = []
	var tracked_dynamic: Array = []
	for shape: VoxelShape3D in _all_shapes():
		var body := _body_of(shape)
		var dynamic := body != null and body.state == VoxelBody3D.State.DYNAMIC
		var bounds := shape.world_bounds()
		_grid.insert(shape, bounds)
		tracked_shapes.append(shape)
		tracked_bounds.append(bounds)
		tracked_dynamic.append(dynamic)
	_update_planner.reset(tracked_shapes, tracked_bounds, tracked_dynamic)
	last_upload_bytes = total_memory_bytes


## All Shapes in one group: the volume no longer separates static and dynamic data.
func _shape_group() -> Dictionary:
	var group := {"shapes": [], "transforms": [], "voxel_sizes": PackedFloat32Array()}
	for shape in _all_shapes():
		group.shapes.append(shape.data)
		group.transforms.append(shape.global_transform)
		group.voxel_sizes.append(shape.voxel_size)
	return group


func _rasterize_into(level: int, group: Dictionary, layers: Array) -> void:
	layers[level] = _rasterize_level(group, level)


## Fill an entire level in C++. In GDScript, this was a loop over every live voxel at every level:
## 79.3 M x 4 = 317 M iterations at 1.58 M/s on Lee, or 201 s of a black startup screen.
func _rasterize_level(group: Dictionary, level: int) -> PackedByteArray:
	var packed := _packed_sizes[level]
	if group.shapes.is_empty():
		var empty := PackedByteArray()
		empty.resize(packed.x * packed.y * packed.z)
		return empty
	return VoxelShapeData.rasterize_occupancy_level(
		group.shapes, group.transforms, group.voxel_sizes,
		_origins[level], _logical_sizes[level], _cell_size(level), packed
	)


func _refresh_world_cell_region(level: int, logical_region: AABB) -> void:
	var logical_low := Vector3i(logical_region.position)
	var logical_size := Vector3i(logical_region.size)
	var packed_size := logical_size / 2
	if packed_size.x <= 0 or packed_size.y <= 0 or packed_size.z <= 0:
		return
	var allocation_started := Time.get_ticks_usec()
	var region := PackedByteArray()
	region.resize(packed_size.x * packed_size.y * packed_size.z)
	last_region_allocate_ms += (Time.get_ticks_usec() - allocation_started) / 1000.0
	var raster_started := Time.get_ticks_usec()
	var cell_size := _cell_size(level)
	var world_region := AABB(logical_region.position * cell_size, logical_region.size * cell_size)
	for shape in _grid.query(world_region):
		region = shape.data.rasterize_occupancy_region(
			shape.global_transform, shape.voxel_size, logical_low, logical_size,
			cell_size, packed_size, region
		)
	last_region_raster_ms += (Time.get_ticks_usec() - raster_started) / 1000.0
	var upload_started := Time.get_ticks_usec()
	# The volume does not wrap: the entire region fits inside the texture, so this is a single copy.
	var copies: Array[Dictionary] = [{
		"destination": (logical_low - _origins[level]) / 2,
		"source": Vector3i.ZERO,
		"size": packed_size,
	}]
	_textures[level].update_compact_regions(region, packed_size, copies)
	last_upload_bytes += region.size()
	last_region_upload_ms += (Time.get_ticks_usec() - upload_started) / 1000.0


func _update_dynamic_shapes() -> void:
	var started := Time.get_ticks_usec()
	var movable := _movable_shapes()
	var plan: Dictionary = _update_planner.plan(
		movable, _movable_bounds, Engine.get_process_frames(), SHAPES_PER_FRAME,
		SHADOW_DEADBAND_SQ, _base_cell_size, SWEEP_EVERY_FRAMES, MERGE_MAX_SIDE
	)
	for update: Dictionary in plan.grid_updates:
		_grid.insert(update.shape, update.bounds)
	for key in plan.removals:
		_grid.remove_id(key)
	# Each moving object refreshes ITS box at all four levels. They used to be merged into one region
	# to make the cost O(Shapes) rather than O(Shapes x levels). That made sense when each scan took
	# 10 ms; it no longer does with the grid, and blind merging was also disastrous: two debris piles
	# at opposite ends produced a 250 m box, requiring 106 s of rasterization.
	for region in plan.dirty:
		for level in LEVELS:
			_refresh_world_aabb(level, region)
	last_dynamic_update_ms = (Time.get_ticks_usec() - started) / 1000.0


func _on_voxels_changed(
	shape: VoxelShape3D, _world_aabb: AABB, dirty_min: Vector3i, dirty_max: Vector3i
) -> void:
	var started := Time.get_ticks_usec()
	if not damage_updates_enabled:
		last_damage_upload_bytes = 0
		last_damage_update_ms = 0.0
		return
	var dimensions := shape.data.get_dimensions()
	var local_low := (Vector3(dirty_min) - Vector3(dimensions) * 0.5) * shape.voxel_size
	var local_high := (Vector3(dirty_max + Vector3i.ONE) - Vector3(dimensions) * 0.5) \
		* shape.voxel_size
	var changed := AABB(shape.global_transform * local_low, Vector3.ZERO)
	for corner in 8:
		var point := shape.global_transform * Vector3(
			local_high.x if corner & 1 else local_low.x,
			local_high.y if corner & 2 else local_low.y,
			local_high.z if corner & 4 else local_low.z
		)
		changed = changed.expand(point)
	# Level 0 follows the crater immediately. Queue the three coarser levels and process one per
	# frame to avoid four driver uploads in the same presentation interval.
	_refresh_world_aabb(0, changed.grow(_cell_size(0)))
	for level in range(1, LEVELS):
		# Blind merging is still disastrous: a bomb hitting objects 50 m apart produced one 50 m box,
		# whose rasterization caused 120 ms spikes. Keep separate boxes and merge only those that
		# remain within `MERGE_MAX_SIDE`.
		var pending: Array[AABB] = _pending_damage_regions[level]
		pending.append(changed.grow(_cell_size(level)))
		_pending_damage_regions[level] = _coalesce(pending)
	last_damage_upload_bytes = last_upload_bytes
	last_damage_update_ms = (Time.get_ticks_usec() - started) / 1000.0


func _flush_pending_damage_level() -> void:
	for _attempt in range(1, LEVELS):
		var level := _damage_level_cursor
		_damage_level_cursor += 1
		if _damage_level_cursor >= LEVELS:
			_damage_level_cursor = 1
		var pending: Array[AABB] = _pending_damage_regions[level]
		if pending.is_empty():
			continue
		# One box per frame and level. The crater is immediately visible at level 0; the coarser
		# levels provide distant shadows and can lag by a couple of frames without being noticed.
		_refresh_world_aabb(level, pending.pop_back())
		break


func _refresh_world_aabb(level: int, world_region: AABB) -> void:
	var cell_size := _cell_size(level)
	var low := Vector3i(
		floori(world_region.position.x / cell_size),
		floori(world_region.position.y / cell_size),
		floori(world_region.position.z / cell_size)
	)
	var high_position := world_region.end
	var high := Vector3i(
		ceili(high_position.x / cell_size),
		ceili(high_position.y / cell_size),
		ceili(high_position.z / cell_size)
	)
	# Packed-byte uploads start and end on two-cell boundaries, also aligned with the volume origin
	# so the destination uses whole texels.
	var origin := _origins[level]
	low = origin + Vector3i(
		floori((low.x - origin.x) / 2.0) * 2,
		floori((low.y - origin.y) / 2.0) * 2,
		floori((low.z - origin.z) / 2.0) * 2
	)
	high = origin + Vector3i(
		ceili((high.x - origin.x) / 2.0) * 2,
		ceili((high.y - origin.y) / 2.0) * 2,
		ceili((high.z - origin.z) / 2.0) * 2
	)
	low = low.max(origin)
	high = high.min(origin + _logical_sizes[level])
	if high.x <= low.x or high.y <= low.y or high.z <= low.z:
		return
	_refresh_world_cell_region(level, AABB(Vector3(low), Vector3(high - low)))


## Merge boxes only while the result remains small. The measured limit is based on cost: a 4 m
## region takes 0.36 ms to rasterize, while a 16 m region takes 7 ms because the loop visits source
## voxels inside it. Previously everything was merged blindly, so two debris piles at opposite
## ends of the map produced a 250 m box—106 s in one frame.
const MERGE_MAX_SIDE := 8.0


func _coalesce(regions: Array[AABB]) -> Array[AABB]:
	# The native planner returns an untyped `Array`; storing it directly left the slot untyped and
	# the next `_flush_pending_damage_level` failed when reading it.
	var merged: Array[AABB] = []
	merged.assign(_update_planner.coalesce(regions, MERGE_MAX_SIDE))
	return merged


func _cell_size(level: int) -> float:
	return _base_cell_size * float(1 << level)


## Only Shapes that may have moved since the previous frame.
func _movable_shapes() -> Array[VoxelShape3D]:
	var result: Array[VoxelShape3D] = []
	_movable_bounds.clear()
	if _world == null:
		return result
	var snapshot: Dictionary = _transform_tracker.collect(_world.get_transform_tracked_body_ids())
	var snapshot_shapes: Array = snapshot.shapes
	var bounds: Array = snapshot.bounds
	for index in mini(snapshot_shapes.size(), bounds.size()):
		var shape := snapshot_shapes[index] as VoxelShape3D
		if shape == null:
			continue
		result.append(shape)
		_movable_bounds[shape.get_instance_id()] = bounds[index]
	return result


## Called several times per frame during region refresh. The list does not change within a frame, so
## compute it only once.
## A Shape created halfway through a frame enters the volume on the next frame. This produces one
## frame of shadow latency, not a permanent gap.
func _all_shapes() -> Array[VoxelShape3D]:
	var frame := Engine.get_process_frames()
	if frame == _shape_cache_frame:
		return _shape_cache
	var result: Array[VoxelShape3D] = []
	for body in get_tree().get_nodes_in_group(VoxelBody3D.GROUP):
		for shape in (body as VoxelBody3D).get_shapes():
			if shape.voxel_count() > 0:
				result.append(shape)
	_shape_cache = result
	_shape_cache_frame = frame
	return result


static func _body_of(shape: VoxelShape3D) -> VoxelBody3D:
	var node: Node = shape.get_parent()
	while node != null:
		if node is VoxelBody3D:
			return node
		node = node.get_parent()
	return null
