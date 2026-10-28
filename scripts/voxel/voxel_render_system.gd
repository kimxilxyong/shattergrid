class_name VoxelRenderSystem
extends Node
## Product-facing owner of the selected dedicated DDA backend.
##
## Shapes are packed into persistent R8UI atlases. A compute upload writes only the dirty cuboid;
## adding a fragment consumes reserved atlas space and only refreshes GPU metadata/BVH.

const MIN_ATLAS_DEPTH := 256
const MAX_ATLAS_DEPTH := 2048

## Brick-atlas side length, measured in bricks rather than texels: 128 x 128 produces a 1024 x 1024
## texture and grows only in depth, the axis with headroom (2048 texels = 256 brick layers).
const BRICK_GRID_SIDE := 128

## Headroom beyond the bricks requested by the map, so fragments created by destruction fit without
## rebuilding the entire atlas.
const BRICK_HEADROOM := 13

## The BVH and Shape storage keep fixed leaves for runtime fragments. Activating a reserved leaf
## avoids rebuilding metadata for the complete map during destruction.
const FRAGMENT_ENTRY_HEADROOM := 256
const SMALL_MAP_INITIAL_ENTRY_HEADROOM := 512
const SMALL_MAP_SHAPE_THRESHOLD := 64

## Maximum cell count of the macro-cell atlas. It is the same grid divided by eight, so the entire
## map uses 885 K cells, well below the limit.
const MAX_MACRO_ATLAS_CELLS := 16_000_000

var world: VoxelWorld3D
var effect: DedicatedVoxelDDAEffect
var compositor: Compositor
var shadow_clipmaps: VoxelShadowClipmaps
var local_shadow_pool: VoxelLocalShadowPool
var _voxel_atlas := VoxelAtlas3D.new()
var _macro_atlas := VoxelAtlas3D.new()
var _bricks := VoxelBrickPool.new()
var _brick_table := PackedInt32Array()
var _brick_table_dirty := true
var _macros := PackedByteArray()
var _slots := {}
var _shapes: Array[VoxelShape3D] = []
var _transforms := {}
var _surface_animation_revisions := {}
var _animated_shapes: Array[VoxelShape3D] = []
var _entry_indices := {}
var _reserved_entry_indices := {}
## A leaf created in the glass BVH can hold any Shape; a leaf not created there can only be reused
## for opaque Shapes because the secondary topology remains fixed.
var _entry_glass_capable := {}
var _free_entry_indices := PackedInt32Array()
var _reserved_entry_headroom := FRAGMENT_ENTRY_HEADROOM
var _palette_rows := {}
var _glass_usage := {}
var _macro_atlas_dimensions := Vector3i.ZERO
var _cursor := Vector3i.ZERO
var _shelf_height := 0
var _layer_depth := 0
var _metadata_dirty := false
var _palette_dirty := false
var _camera: Camera3D
var last_metadata_sync_ms := 0.0
var last_transform_sync_ms := 0.0
var last_metadata_fallback_reason := ""
var last_damage_update_ms := 0.0
var damage_uploads_enabled := true
var entry_capacity_rebuilds := 0
var _entry_capacity_dirty := false
var _cleanup_elapsed := 0.0
var _transform_tracker := VoxelTransformTracker.new()
var _movable_transforms := {}


## Renderer startup takes about 3.6 s with the full map (atlas ~1 s, shadow volume ~2.6 s), after
## import. `setup_progressive` reports progress on the loading screen; `setup` remains the usual call
## for test harnesses.
func setup(voxel_world: VoxelWorld3D, camera: Camera3D) -> bool:
	# Call through `Callable` so the analyzer does not require `await`; without a loading screen,
	# `_setup` does not suspend.
	var result: Variant = _setup.call(voxel_world, camera, Callable())
	if result is bool:
		return result
	push_error("VoxelRenderSystem: startup without a loading screen was suspended")
	return false


func setup_progressive(
	voxel_world: VoxelWorld3D, camera: Camera3D, progress: Callable
) -> bool:
	return await _setup(voxel_world, camera, progress)


func _setup(voxel_world: VoxelWorld3D, camera: Camera3D, progress: Callable) -> bool:
	world = voxel_world
	_camera = camera
	effect = DedicatedVoxelDDAEffect.new()
	compositor = Compositor.new()
	compositor.compositor_effects = [effect]
	camera.compositor = compositor
	world.voxels_changed.connect(_on_voxels_changed)
	world.body_split.connect(_on_body_split)
	for body in world.get_children():
		if body is VoxelBody3D:
			for shape in (body as VoxelBody3D).get_shapes():
				_shapes.append(shape)
				_watch_shape_surface(shape)
	if _shapes.is_empty():
		return true
	# Five buildings plus 256 reserved leaves was the pathological case: ordinary destruction barely
	# exceeded capacity and triggered a rebuild during gameplay. Large maps already provide thousands
	# of recyclable leaves, so keep the reserve small to avoid increasing per-pixel traversal cost.
	_reserved_entry_headroom = SMALL_MAP_INITIAL_ENTRY_HEADROOM \
		if _shapes.size() <= SMALL_MAP_SHAPE_THRESHOLD else FRAGMENT_ENTRY_HEADROOM
	if progress.is_valid():
		progress.call(0.0, "Building voxel atlas…")
		await Engine.get_main_loop().process_frame
	if not _rebuild_atlases():
		return false
	shadow_clipmaps = VoxelShadowClipmaps.new()
	shadow_clipmaps.name = "VoxelShadowClipmaps"
	add_child(shadow_clipmaps)
	if world.renderer_settings.sun_shadows_enabled:
		# Shadow setup is most of startup, so it occupies 20% to 97% of the progress bar.
		var shadows := func(fraction: float, label: String) -> void:
			progress.call(0.20 + 0.77 * fraction, label)
		var started := false
		if progress.is_valid():
			started = await shadow_clipmaps.setup_progressive(world, camera, shadows)
		else:
			started = shadow_clipmaps.setup(world, camera)
		if not started:
			return false
		effect.configure_shadow_clipmaps(
			shadow_clipmaps.get_static_rids(),
			shadow_clipmaps.get_dynamic_rids(),
			shadow_clipmaps.get_shader_metadata()
		)
		# The clipmap used to notify here every time it moved. The volume is fixed: metadata is
		# provided once above and never changes.
	else:
		shadow_clipmaps.set_process(false)
	_refresh_effect_upload_sources()
	local_shadow_pool = VoxelLocalShadowPool.new()
	local_shadow_pool.name = "VoxelLocalShadowPool"
	add_child(local_shadow_pool)
	local_shadow_pool.setup(world, camera)
	local_shadow_pool.volumes_changed.connect(effect.configure_local_shadow_volumes)
	effect.configure_local_shadow_volumes([], local_shadow_pool.get_shader_metadata())
	if progress.is_valid():
		progress.call(1.0, "Ready")
	return true


func register_shape(shape: VoxelShape3D) -> void:
	if _shapes.has(shape):
		return
	_shapes.append(shape)
	_watch_shape_surface(shape)
	if not _can_allocate(shape):
		last_metadata_fallback_reason = "atlas_capacity:%s" % shape.name
		_rebuild_atlases()
		return
	_allocate_shape(shape)
	_upload_entire_shape(shape)
	if not _activate_reserved_entry(shape):
		var palette_key := shape.palette.get_instance_id()
		var palette_missing := not _palette_rows.has(palette_key)
		last_metadata_fallback_reason = (
			"new_palette:%s" % shape.name if palette_missing
			else "renderer_entry_capacity:%s" % shape.name
		)
		# Do not rebuild inside the destruction signal: an explosion can create hundreds of fragments.
		# Batch them all, then let `_process` rebuild once at the end of the frame. `_sync_metadata`
		# includes all live Shapes and restores HEADROOM free leaves, so capacity is no longer fixed
		# without adding startup cost for small maps.
		_metadata_dirty = true
		_palette_dirty = _palette_dirty or palette_missing
		if not palette_missing:
			# After growing, restore the normal headroom; all active Shapes are already part of the new
			# topology.
			_reserved_entry_headroom = FRAGMENT_ENTRY_HEADROOM
			_entry_capacity_dirty = true


func unregister_shape(shape: VoxelShape3D) -> void:
	_shapes.erase(shape)
	_animated_shapes.erase(shape)
	_deactivate_shape_entry(shape)
	_slots.erase(shape.get_instance_id())
	_transforms.erase(shape.get_instance_id())
	_surface_animation_revisions.erase(shape.get_instance_id())
	_glass_usage.erase(shape.get_instance_id())


## Shapes that may have moved since the previous frame: those belonging to dynamic bodies. Scanning
## all 2,312 map nodes every frame was pure GDScript overhead.
##
## Query the world on demand instead of maintaining a cache, which caused the bug: the cache was
## populated when the Shape was registered, so a Shape that became dynamic later (a tower losing
## support, or a loose section getting a new body) was never included. The body fell, but its
## transform was never uploaded to the GPU again: a standing ghost remained at its old position,
## passable and indestructible because the real voxels were elsewhere. Its shadow did move because
## the clipmap already read this same list.
func movable_shapes() -> Array[VoxelShape3D]:
	var result: Array[VoxelShape3D] = []
	_movable_transforms.clear()
	if world == null:
		return result
	var snapshot: Dictionary = _transform_tracker.collect(world.get_transform_tracked_body_ids())
	var snapshot_shapes: Array = snapshot.shapes
	var transforms: Array = snapshot.transforms
	for index in mini(snapshot_shapes.size(), transforms.size()):
		var shape := snapshot_shapes[index] as VoxelShape3D
		if shape == null:
			continue
		result.append(shape)
		_movable_transforms[shape.get_instance_id()] = transforms[index]
	return result


func _process(delta: float) -> void:
	if effect == null:
		return
	last_metadata_sync_ms = 0.0
	last_transform_sync_ms = 0.0
	var transform_updates: Array[Dictionary] = []
	for shape in movable_shapes():
		var key := shape.get_instance_id()
		# The compositor is not a VisualInstance3D, so Godot does not interpolate these metadata for
		# us. Uploading the render sample prevents the chassis, wheels, and debris from stepping with
		# physics even when the camera is already smooth.
		var render_transform: Transform3D = _movable_transforms[key] \
			if _movable_transforms.has(key) else shape.get_global_transform_interpolated()
		if _transforms.has(key) and _transform_equal(_transforms[key], render_transform):
			continue
		_transforms[key] = render_transform
		if not _entry_indices.has(key) and shape.renderer_slot >= 0:
			_entry_indices[key] = shape.renderer_slot
		if not _entry_indices.has(key):
			_activate_reserved_entry(shape)
		if _entry_indices.has(key) and not _metadata_dirty:
			transform_updates.append({
				"index": int(_entry_indices[key]), "transform": render_transform,
			})
		else:
			last_metadata_fallback_reason = "moving_shape_without_entry:%s" % shape.name
			# A shape without atlas/entry metadata cannot be made visible by rebuilding every frame.
			# Leave it out and let registration/capacity handling resolve it explicitly.
	_cleanup_elapsed += delta
	var run_cleanup := _cleanup_elapsed >= 1.0
	if run_cleanup:
		_cleanup_elapsed = 0.0
		_append_settled_pose_repairs(transform_updates)
	if not transform_updates.is_empty() and not _metadata_dirty:
		var transform_started := Time.get_ticks_usec()
		if not effect.update_entry_transforms(transform_updates):
			last_metadata_fallback_reason = "effect_rejected_transform_batch"
		last_transform_sync_ms = (Time.get_ticks_usec() - transform_started) / 1000.0
	_sync_surface_animations()
	if run_cleanup:
		var live: Array[VoxelShape3D] = []
		var live_keys := {}
		for shape in _shapes:
			if is_instance_valid(shape) and shape.is_inside_tree() and shape.voxel_count() > 0:
				live.append(shape)
				live_keys[shape.get_instance_id()] = true
		_shapes = live
		# A freed Object cannot cross a function boundary with a typed parameter: the error occurs
		# before the `is_instance_valid` guard. Clear metadata by the stable ID already used by the
		# atlas without touching the dead Object again.
		for key: Variant in _entry_indices.keys():
			if not live_keys.has(key):
				_deactivate_entry_key(int(key))
	if _metadata_dirty:
		var started := Time.get_ticks_usec()
		_sync_metadata(_palette_dirty)
		last_metadata_sync_ms = (Time.get_ticks_usec() - started) / 1000.0
		if _entry_capacity_dirty:
			entry_capacity_rebuilds += 1
			last_metadata_fallback_reason = "entry_capacity_rebuilt:%d" % _entry_indices.size()
		_metadata_dirty = false
		_palette_dirty = false
		_entry_capacity_dirty = false


## Authored joints and controllers can move a Body after Jolt marks it asleep without emitting
## another awake transition. A canonical reconciliation at 1 Hz handles this without scanning 648
## props every frame; it only uploads poses that actually differ from the last upload.
func _append_settled_pose_repairs(updates: Array[Dictionary]) -> void:
	if world == null:
		return
	for body in world.get_dynamic_bodies():
		if not is_instance_valid(body) or body.state != VoxelBody3D.State.DYNAMIC \
				or body.is_awake() \
				or world.is_body_externally_transform_tracked(body.get_instance_id()):
			continue
		for shape in body.get_shapes():
			if not is_instance_valid(shape) or shape.voxel_count() <= 0:
				continue
			var key := shape.get_instance_id()
			var canonical := shape.global_transform
			if _transforms.has(key) and _transform_close(
				_transforms[key] as Transform3D, canonical, 0.02, 0.01
			):
				continue
			_transforms[key] = canonical
			if not _entry_indices.has(key) and shape.renderer_slot >= 0:
				_entry_indices[key] = shape.renderer_slot
			if not _entry_indices.has(key):
				_activate_reserved_entry(shape)
			if _entry_indices.has(key) and not _metadata_dirty:
				updates.append({
					"index": int(_entry_indices[key]), "transform": canonical,
				})
			else:
				last_metadata_fallback_reason = "settled_shape_without_entry:%s" % shape.name


## CPU census of the four registries that must describe exactly the same Shapes. It turns a
## potential future visual bug into a concrete cause and also supports stress tests.
func get_coherence_snapshot() -> Dictionary:
	var effect_entry_count := effect.get_entry_count() if effect != null else 0
	var pending_gpu_updates := effect.get_pending_gpu_update_count() if effect != null else 0
	var pending_gpu_update_age_ms := effect.get_pending_gpu_update_age_ms() \
		if effect != null else 0.0
	var live_keys := {}
	var missing_slots: Array[String] = []
	var missing_entries: Array[String] = []
	var invalid_entries: Array[String] = []
	var stale_renderer_slots: Array[String] = []
	var effect_pose_mismatches: Array[String] = []
	var settled_pose_mismatches: Array[String] = []
	for shape in _shapes:
		if not is_instance_valid(shape) or not shape.is_inside_tree() or shape.voxel_count() <= 0:
			continue
		var key := shape.get_instance_id()
		live_keys[key] = true
		if not _slots.has(key):
			missing_slots.append(shape.name)
		if not _entry_indices.has(key):
			missing_entries.append(shape.name)
			continue
		var entry_index := int(_entry_indices[key])
		if entry_index < 0 or entry_index >= effect_entry_count:
			invalid_entries.append(shape.name)
		if shape.renderer_slot != entry_index:
			stale_renderer_slots.append(shape.name)
		var scheduled: Transform3D = _transforms.get(key, shape.global_transform)
		if effect != null and entry_index >= 0 and entry_index < effect_entry_count \
				and not _transform_close(
					scheduled, effect.get_entry_transform(entry_index), 0.001, 0.001
				):
			effect_pose_mismatches.append(shape.name)
		var owner := _body_of_shape(shape)
		# An awake body can move between the physics tick and this census. When asleep, that ambiguity
		# is gone: if the final scene pose and upload differ, a visible ghost remains.
		if owner != null and owner.state == VoxelBody3D.State.DYNAMIC and not owner.is_awake() \
				and (world == null or not world.is_body_externally_transform_tracked(
					owner.get_instance_id()
				)) \
				and not _transform_close(scheduled, shape.global_transform, 0.02, 0.01):
			settled_pose_mismatches.append(shape.name)
	var orphan_slots := 0
	for key in _slots:
		if not live_keys.has(key):
			orphan_slots += 1
	var status := "COHERENT"
	if not missing_slots.is_empty() or not missing_entries.is_empty() \
			or not invalid_entries.is_empty() or not stale_renderer_slots.is_empty() \
			or not effect_pose_mismatches.is_empty() or not settled_pose_mismatches.is_empty() \
			or orphan_slots > 0:
		status = "DESYNC"
	elif _metadata_dirty or pending_gpu_update_age_ms > 50.0:
		status = "PENDING"
	return {
		"status": status,
		"live_shapes": live_keys.size(),
		"atlas_slots": _slots.size(),
		"renderer_entries": _entry_indices.size(),
		"free_entries": _free_entry_indices.size(),
		"gpu_entry_records": effect_entry_count,
		"pending_gpu_updates": pending_gpu_updates,
		"pending_gpu_update_age_ms": snappedf(pending_gpu_update_age_ms, 0.001),
		"missing_slots": missing_slots,
		"missing_entries": missing_entries,
		"invalid_entries": invalid_entries,
		"stale_renderer_slots": stale_renderer_slots,
		"effect_pose_mismatches": effect_pose_mismatches,
		"settled_pose_mismatches": settled_pose_mismatches,
		"orphan_slots": orphan_slots,
		"metadata_rebuild_pending": _metadata_dirty,
		"entry_capacity_rebuilds": entry_capacity_rebuilds,
	}


## Snapshot for movement regressions. `scheduled` is what the system believes it uploaded, and
## `effect` is the exact entry the compositor packed for the corresponding leaf.
func get_shape_pose_snapshot(shape: VoxelShape3D) -> Dictionary:
	if shape == null or not is_instance_valid(shape):
		return {"valid": false}
	var key := shape.get_instance_id()
	var entry_index := int(_entry_indices.get(key, -1))
	var scene_pose := shape.get_global_transform_interpolated()
	var scheduled: Transform3D = _transforms.get(key, Transform3D.IDENTITY)
	var effect_pose := effect.get_entry_transform(entry_index) \
		if effect != null and entry_index >= 0 else Transform3D.IDENTITY
	var pending_gpu_updates := effect.get_pending_gpu_update_count() if effect != null else 0
	var pending_gpu_update_age_ms := effect.get_pending_gpu_update_age_ms() \
		if effect != null else 0.0
	return {
		"valid": _transforms.has(key) and entry_index >= 0,
		"entry": entry_index,
		"scene": scene_pose,
		"scheduled": scheduled,
		"effect": effect_pose,
		"scene_error_m": scene_pose.origin.distance_to(scheduled.origin),
		"canonical_error_m": shape.global_transform.origin.distance_to(scheduled.origin),
		"effect_error_m": scheduled.origin.distance_to(effect_pose.origin),
		"pending_gpu_updates": pending_gpu_updates,
		"pending_gpu_update_age_ms": pending_gpu_update_age_ms,
	}


static func _body_of_shape(shape: VoxelShape3D) -> VoxelBody3D:
	var node: Node = shape.get_parent()
	while node != null:
		if node is VoxelBody3D:
			return node as VoxelBody3D
		node = node.get_parent()
	return null


func _rebuild_atlases() -> bool:
	var live: Array[VoxelShape3D] = []
	var max_macro_x := 1
	var max_macro_y := 1
	var total_macro_volume := 0
	var total_bricks := 0
	for shape in _shapes:
		if not is_instance_valid(shape) or shape.data == null or shape.voxel_count() == 0:
			continue
		live.append(shape)
		var macro_dimensions := shape.data.get_macro_dimensions()
		max_macro_x = maxi(max_macro_x, macro_dimensions.x)
		max_macro_y = maxi(max_macro_y, macro_dimensions.y)
		total_macro_volume += macro_dimensions.x * macro_dimensions.y * macro_dimensions.z
		total_bricks += shape.data.get_occupied_macros().size()
	_shapes = live
	if _shapes.is_empty():
		return true
	# Rebuilding is transactional. Keep the pool, slots, and textures still drawn by the previous
	# frame until both candidate atlases are complete. The old code removed Shapes that did not fit
	# from the render registry even though their collision remained active.
	var previous_bricks = _bricks
	var previous_brick_table := _brick_table
	var previous_brick_table_dirty := _brick_table_dirty
	var previous_macros := _macros
	var previous_slots := _slots
	var previous_dimensions := _macro_atlas_dimensions
	var previous_cursor := _cursor
	var previous_shelf_height := _shelf_height
	var previous_layer_depth := _layer_depth
	var brick_grid := _plan_brick_grid(total_bricks)
	_bricks = VoxelBrickPool.new()
	if not _bricks.configure(brick_grid):
		push_error("VoxelRenderSystem: could not reserve the %d-brick pool" % total_bricks)
		_bricks = previous_bricks
		return false
	# Request four times the required volume: shelf packing wastes a lot with 2,312 differently sized
	# Shapes, and each cell here covers 512 voxels, so the extra room costs megabytes instead of
	# hundreds.
	var candidate_dimensions := _plan_atlas(
		max_macro_x, max_macro_y, total_macro_volume * 4, MAX_MACRO_ATLAS_CELLS, 512
	)
	var layout_ready := false
	for attempt in 6:
		_macro_atlas_dimensions = candidate_dimensions
		_macros = PackedByteArray()
		_macros.resize(candidate_dimensions.x * candidate_dimensions.y * candidate_dimensions.z)
		_macros.fill(0)
		_slots = {}
		_brick_table = PackedInt32Array()
		_brick_table_dirty = true
		_bricks.configure(brick_grid)
		_reset_packer()
		layout_ready = true
		for shape in _shapes:
			if not _allocate_shape(shape):
				layout_ready = false
				break
			_copy_macros_to_cpu_atlas(shape)
		if layout_ready:
			break
		candidate_dimensions = _grow_macro_atlas(candidate_dimensions)
		if candidate_dimensions == Vector3i.ZERO:
			break
	if not layout_ready:
		push_error(
			"VoxelRenderSystem: rebuild cancelled; %d Shapes do not fit without losing synchronization"
			% _shapes.size()
		)
		_bricks = previous_bricks
		_brick_table = previous_brick_table
		_brick_table_dirty = previous_brick_table_dirty
		_macros = previous_macros
		_slots = previous_slots
		_macro_atlas_dimensions = previous_dimensions
		_cursor = previous_cursor
		_shelf_height = previous_shelf_height
		_layer_depth = previous_layer_depth
		return false
	var candidate_voxels := VoxelAtlas3D.new()
	var candidate_macros := VoxelAtlas3D.new()
	if not candidate_voxels.create(_bricks.get_dimensions(), _bricks.get_bytes(), true) \
			or not candidate_macros.create(_macro_atlas_dimensions, _macros, true):
		candidate_voxels.release()
		candidate_macros.release()
		_bricks = previous_bricks
		_brick_table = previous_brick_table
		_brick_table_dirty = previous_brick_table_dirty
		_macros = previous_macros
		_slots = previous_slots
		_macro_atlas_dimensions = previous_dimensions
		_cursor = previous_cursor
		_shelf_height = previous_shelf_height
		_layer_depth = previous_layer_depth
		return false
	var previous_voxel_atlas := _voxel_atlas
	var previous_macro_atlas := _macro_atlas
	_voxel_atlas = candidate_voxels
	_macro_atlas = candidate_macros
	_sync_metadata(true)
	_refresh_effect_upload_sources()
	previous_voxel_atlas.release()
	previous_macro_atlas.release()
	return true


func _refresh_effect_upload_sources() -> void:
	if effect == null:
		return
	var sources: Array = [_voxel_atlas, _macro_atlas]
	if world != null and world.renderer_settings.sun_shadows_enabled \
			and shadow_clipmaps != null and is_instance_valid(shadow_clipmaps):
		sources.append_array(shadow_clipmaps.get_upload_sources())
	effect.configure_upload_sources(sources)


static func _grow_macro_atlas(current: Vector3i) -> Vector3i:
	var cells := current.x * current.y * current.z
	if current.z < MAX_ATLAS_DEPTH and cells * 2 <= MAX_MACRO_ATLAS_CELLS:
		return Vector3i(current.x, current.y, current.z * 2)
	if current.x < 512 and current.y < 512 and cells * 4 <= MAX_MACRO_ATLAS_CELLS:
		return Vector3i(current.x * 2, current.y * 2, current.z)
	return Vector3i.ZERO


## Brick-pool grid for a given number of occupied bricks. It grows only along Z: X and Y remain
## fixed at 128 bricks (1,024 texels), where the texture-size limit applies.
static func _plan_brick_grid(brick_count: int) -> Vector3i:
	var per_layer := BRICK_GRID_SIDE * BRICK_GRID_SIDE
	var wanted := maxi(1, brick_count * BRICK_HEADROOM / 10)
	var layers := clampi((wanted + per_layer - 1) / per_layer, 1, MAX_ATLAS_DEPTH / 8)
	return Vector3i(BRICK_GRID_SIDE, BRICK_GRID_SIDE, layers)


## Choose the macro-cell atlas size for a given volume. Find a power-of-two cube with enough room
## for packing waste, without exceeding the limit.
static func _plan_atlas(max_x: int, max_y: int, volume: int, cell_budget: int, side_cap: int) -> Vector3i:
	var side := maxi(1, _next_power_of_two(maxi(max_x, max_y)))
	# 1.6x headroom: shelf packing leaves gaps, and falling short means invisible Shapes.
	while side < side_cap and side * side * side < volume * 16 / 10:
		side *= 2
	var depth := clampi(
		_next_power_of_two(maxi(1, volume * 16 / 10 / maxi(1, side * side))),
		MIN_ATLAS_DEPTH, MAX_ATLAS_DEPTH
	)
	while side * side * depth > cell_budget and depth > 1:
		depth /= 2
	return Vector3i(side, side, depth)


func _reset_packer() -> void:
	_cursor = Vector3i.ZERO
	_shelf_height = 0
	_layer_depth = 0


func _can_allocate(shape: VoxelShape3D) -> bool:
	if not _voxel_atlas.get_rd_rid().is_valid():
		return false
	if _bricks.get_used() + shape.data.get_occupied_macros().size() > _bricks.get_capacity():
		return false
	return not _fit(shape.data.get_macro_dimensions()).is_empty()


## Three-dimensional shelf packing on the macro-cell atlas: advance along X to fill a row, move up
## along Y to fill a layer, then advance along Z. Stacking only along Z, as before, exhausts depth
## with two dozen large Shapes.
##
## Intentionally do not sort by height: although standard for shelf packing, this puts large Shapes
## first and fills the atlas sooner. In the dense atlas, 619 unsorted Shapes fit versus only 308
## sorted Shapes. World order distributes them better.
func _fit(dimensions: Vector3i) -> Dictionary:
	var cursor := _cursor
	var shelf := _shelf_height
	var layer := _layer_depth
	if cursor.x + dimensions.x > _macro_atlas_dimensions.x:
		cursor = Vector3i(0, cursor.y + shelf, cursor.z)
		shelf = 0
	if cursor.y + dimensions.y > _macro_atlas_dimensions.y:
		cursor = Vector3i(0, 0, cursor.z + layer)
		layer = 0
	if cursor.z + dimensions.z > _macro_atlas_dimensions.z \
			or cursor.x + dimensions.x > _macro_atlas_dimensions.x \
			or cursor.y + dimensions.y > _macro_atlas_dimensions.y:
		return {}
	return {
		"origin": cursor,
		"cursor": Vector3i(cursor.x + dimensions.x, cursor.y, cursor.z),
		"shelf": maxi(shelf, dimensions.y),
		"layer": maxi(layer, dimensions.z),
	}


func _allocate_shape(shape: VoxelShape3D) -> bool:
	var macro_dimensions := shape.data.get_macro_dimensions()
	var placement := _fit(macro_dimensions)
	if placement.is_empty():
		return false
	# The pool reserves one brick per occupied macro-cell and returns the table queried by the shader.
	# It returns empty when there is no space left, and the Shape cannot be placed.
	var pool_base := _bricks.get_used()
	var table := _bricks.append_shape(shape.data)
	if table.is_empty():
		return false
	_cursor = placement.cursor
	_shelf_height = placement.shelf
	_layer_depth = placement.layer
	_slots[shape.get_instance_id()] = {
		"atlas_origin": Vector3i.ZERO,
		"macro_origin": placement.origin as Vector3i,
		"dimensions": shape.data.get_dimensions(),
		"macro_dimensions": macro_dimensions,
		"brick_table_base": _brick_table.size(),
		"pool_base": pool_base,
		"pool_count": _bricks.get_used() - pool_base,
	}
	_brick_table.append_array(table)
	_brick_table_dirty = true
	return true


func _copy_macros_to_cpu_atlas(shape: VoxelShape3D) -> void:
	var slot: Dictionary = _slots[shape.get_instance_id()]
	var macro_dimensions: Vector3i = slot.macro_dimensions
	var macro_source := shape.data.get_macro_occupancy()
	var macro_origin: Vector3i = slot.macro_origin
	for z in macro_dimensions.z:
		for y in macro_dimensions.y:
			var source_offset := y * macro_dimensions.x + z * macro_dimensions.x * macro_dimensions.y
			var target_offset := macro_origin.x + (macro_origin.y + y) * _macro_atlas_dimensions.x \
				+ (macro_origin.z + z) * _macro_atlas_dimensions.x * _macro_atlas_dimensions.y
			for x in macro_dimensions.x:
				_macros[target_offset + x] = macro_source[source_offset + x]


func _upload_entire_shape(shape: VoxelShape3D) -> void:
	_copy_macros_to_cpu_atlas(shape)
	var slot: Dictionary = _slots[shape.get_instance_id()]
	var macro_dimensions: Vector3i = slot.macro_dimensions
	# A Shape's bricks are contiguous in the pool but not in the texture. Previously, GDScript scanned
	# the macro-cells and uploaded each brick separately: 549,804 iterations on the Teardown map
	# (53% over empty macro-cells) and 260,672 individual uploads, each with a staging texture.
	# `append_shape` has already written the bytes into the pool, so extract them in batches and let
	# the atlas copy each brick from a single source. A newly broken fragment is still one batch.
	for upload: Dictionary in _bricks.extract_uploads(slot.pool_base, slot.pool_count):
		_voxel_atlas.update_compact_regions(upload.bytes, upload.source_size, upload.copies)
	_macro_atlas.update_region(
		_macros, slot.macro_origin, slot.macro_origin + macro_dimensions - Vector3i.ONE
	)


func _on_voxels_changed(
	shape: VoxelShape3D, _world_aabb: AABB, dirty_min: Vector3i, dirty_max: Vector3i
) -> void:
	var started := Time.get_ticks_usec()
	# Free the source volume's slot before registering its fragments. Previously, cleanup waited for
	# a one-second sweep; bursts could exhaust the 256 reserved leaves, making debris keep its
	# collision but disappear until another slot was freed.
	if shape.voxel_count() == 0:
		unregister_shape(shape)
		return
	if not _slots.has(shape.get_instance_id()) or dirty_min.x < 0:
		return
	if not damage_uploads_enabled:
		last_damage_update_ms = 0.0
		return
	var slot: Dictionary = _slots[shape.get_instance_id()]
	var macro_dimensions: Vector3i = slot.macro_dimensions
	var base: int = slot.brick_table_base
	var low := dirty_min / 8
	var high := dirty_max / 8
	# A crater touches only a few bricks: rewrite and upload each whole brick separately, which is
	# cheaper than cropping a dirty cuboid from a sparse pool.
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var brick_slot: int = _brick_table[
					base + x + macro_dimensions.x * (y + macro_dimensions.y * z)
				]
				if brick_slot < 0:
					continue
				_voxel_atlas.update_compact_region(
					_bricks.refresh_brick(shape.data, brick_slot, Vector3i(x, y, z)),
					_bricks.get_slot_origin(brick_slot), Vector3i(8, 8, 8)
				)
	# Macro-cell occupancy is derived and tiny; copy only the dirty cuboid.
	var macro_source := shape.data.get_macro_occupancy()
	var macro_origin: Vector3i = slot.macro_origin
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var source_index := x + y * macro_dimensions.x \
					+ z * macro_dimensions.x * macro_dimensions.y
				var target := macro_origin + Vector3i(x, y, z)
				var target_index := target.x + target.y * _macro_atlas_dimensions.x \
					+ target.z * _macro_atlas_dimensions.x * _macro_atlas_dimensions.y
				_macros[target_index] = macro_source[source_index]
	_macro_atlas.update_region(_macros, macro_origin + low, macro_origin + high)
	last_damage_update_ms = (Time.get_ticks_usec() - started) / 1000.0


func _on_body_split(_source: VoxelBody3D, created: Array[VoxelBody3D]) -> void:
	for body in created:
		for shape in body.get_shapes():
			register_shape(shape)


func _sync_metadata(include_palette: bool) -> void:
	if effect == null or not _voxel_atlas.get_rd_rid().is_valid():
		return
	var entries: Array[Dictionary] = []
	_entry_indices.clear()
	_reserved_entry_indices.clear()
	_entry_glass_capable.clear()
	_free_entry_indices = PackedInt32Array()
	var palette_texels := PackedColorArray()
	if include_palette:
		_palette_rows.clear()
		# Each row contains 256 sRGB colors followed by 256 property texels:
		# roughness, metallic, emission/32. The shader keeps them separate to avoid applying the
		# sRGB conversion to linear data.
		palette_texels.resize(maxi(1, _shapes.size()) * 512)
	for index in _shapes.size():
		var shape := _shapes[index]
		if not _slots.has(shape.get_instance_id()):
			continue
		var palette_key := shape.palette.get_instance_id()
		if not _palette_rows.has(palette_key):
			_palette_rows[palette_key] = index
		var palette_row := int(_palette_rows[palette_key])
		_entry_indices[shape.get_instance_id()] = entries.size()
		shape.renderer_slot = entries.size()
		_entry_glass_capable[entries.size()] = _shape_has_glass(shape)
		entries.append(_entry_for_shape(shape, palette_row))
		_transforms[shape.get_instance_id()] = shape.global_transform
		if include_palette:
			var colors := shape.palette.get_colors()
			var properties := shape.palette.get_render_properties()
			for material in mini(256, colors.size()):
				palette_texels[palette_row * 512 + material] = colors[material]
			for material in mini(256, properties.size()):
				palette_texels[palette_row * 512 + 256 + material] = properties[material]
	for reserve_offset in _reserved_entry_headroom:
		var entry_index := entries.size()
		entries.append(_placeholder_entry(entry_index))
		_reserved_entry_indices[entry_index] = true
		_entry_glass_capable[entry_index] = true
		_free_entry_indices.append(entry_index)
	var grid := _bricks.get_grid()
	effect.configure_entries(
		_voxel_atlas.get_rd_rid(), _macro_atlas.get_rd_rid(), entries,
		palette_texels, maxi(1, _shapes.size()),
		_brick_table if _brick_table_dirty else PackedInt32Array(),
		Vector2i(grid.x, grid.y)
	)
	_brick_table_dirty = false


func _entry_for_shape(shape: VoxelShape3D, palette_row: int) -> Dictionary:
	var slot: Dictionary = _slots[shape.get_instance_id()]
	return {
		"transform": shape.global_transform,
		"dimensions": slot.dimensions,
		"voxel_size": shape.voxel_size,
		"atlas_origin": slot.atlas_origin,
		"macro_origin": slot.macro_origin,
		"macro_dimensions": slot.macro_dimensions,
		"brick_table_base": slot.brick_table_base,
		"palette_row": palette_row,
		"has_glass": _shape_has_glass(shape),
		"surface_animation": _surface_parameters(shape),
	}


static func _placeholder_entry(entry_index: int) -> Dictionary:
	return {
		"transform": Transform3D(Basis.IDENTITY, Vector3(1_000_000.0 + entry_index * 2.0, 0, 0)),
		"dimensions": Vector3i.ONE,
		"voxel_size": 0.1,
		"atlas_origin": Vector3i.ZERO,
		"macro_origin": Vector3i.ZERO,
		"macro_dimensions": Vector3i.ONE,
		"brick_table_base": 0,
		"palette_row": 0,
		# Reserved leaves also exist in the glass BVH, so either material class can occupy them later.
		"has_glass": true,
		"surface_animation": {},
	}


func _sync_surface_animations() -> void:
	if _metadata_dirty:
		return
	var updates: Array[Dictionary] = []
	for shape in _animated_shapes:
		if not is_instance_valid(shape) or shape.surface_animation == null:
			continue
		var key := shape.get_instance_id()
		var revision := shape.surface_animation.revision
		if int(_surface_animation_revisions.get(key, -1)) == revision:
			continue
		_surface_animation_revisions[key] = revision
		if _entry_indices.has(key):
			updates.append({
				"index": int(_entry_indices[key]),
				"surface_animation": shape.surface_animation.gpu_parameters(),
			})
	if not updates.is_empty() and not effect.update_entry_visuals(updates):
		last_metadata_fallback_reason = "effect_rejected_surface_animation_batch"


static func _surface_parameters(shape: VoxelShape3D) -> Dictionary:
	return shape.surface_animation.gpu_parameters() if shape.surface_animation != null else {}


func _watch_shape_surface(shape: VoxelShape3D) -> void:
	if not shape.surface_animation_changed.is_connected(_on_shape_surface_animation_changed):
		shape.surface_animation_changed.connect(_on_shape_surface_animation_changed)
	_on_shape_surface_animation_changed(shape)


func _on_shape_surface_animation_changed(shape: VoxelShape3D) -> void:
	if shape.surface_animation != null:
		if not _animated_shapes.has(shape):
			_animated_shapes.append(shape)
	else:
		_animated_shapes.erase(shape)
	_surface_animation_revisions.erase(shape.get_instance_id())


func _deactivate_shape_entry(shape: VoxelShape3D) -> void:
	if not is_instance_valid(shape):
		return
	var key := shape.get_instance_id()
	_deactivate_entry_key(key)
	shape.renderer_slot = -1


func _deactivate_entry_key(key: int) -> void:
	if not _entry_indices.has(key):
		return
	var entry_index := int(_entry_indices[key])
	effect.update_entries([{"index": entry_index, "entry": _placeholder_entry(entry_index)}])
	# An initial leaf whose Shape was freed is as reusable as an original reserve. Convert it to a
	# reserve to keep BVH topology fixed, avoid increasing traversal cost, and let a split Shape reuse
	# its own leaf in the same event.
	_reserved_entry_indices[entry_index] = true
	if not _free_entry_indices.has(entry_index):
		_free_entry_indices.append(entry_index)
	_entry_indices.erase(key)
	_transforms.erase(key)
	_surface_animation_revisions.erase(key)
	_slots.erase(key)
	_glass_usage.erase(key)


func _activate_reserved_entry(shape: VoxelShape3D) -> bool:
	if not is_instance_valid(shape) or not _slots.has(shape.get_instance_id()):
		return false
	var key := shape.get_instance_id()
	if _entry_indices.has(key):
		return true
	var palette_key := shape.palette.get_instance_id()
	var free_offset := _find_free_entry_offset(_shape_has_glass(shape))
	if free_offset < 0 or not _palette_rows.has(palette_key):
		return false
	var entry_index := _free_entry_indices[free_offset]
	_free_entry_indices.remove_at(free_offset)
	_entry_indices[key] = entry_index
	shape.renderer_slot = entry_index
	_reserved_entry_indices[entry_index] = true
	_transforms[key] = shape.global_transform
	if not effect.update_entries([{
		"index": entry_index,
		"entry": _entry_for_shape(shape, int(_palette_rows[palette_key])),
	}]):
		_entry_indices.erase(key)
		shape.renderer_slot = -1
		_free_entry_indices.append(entry_index)
		last_metadata_fallback_reason = "effect_rejected_entry:%s" % shape.name
		return false
	if _brick_table_dirty:
		var grid := _bricks.get_grid()
		effect.update_brick_table(_brick_table, Vector2i(grid.x, grid.y))
		_brick_table_dirty = false
	return true


func _find_free_entry_offset(needs_glass: bool) -> int:
	for offset in range(_free_entry_indices.size() - 1, -1, -1):
		var entry_index := _free_entry_indices[offset]
		if not needs_glass or bool(_entry_glass_capable.get(entry_index, false)):
			return offset
	return -1


func _shape_has_glass(shape: VoxelShape3D) -> bool:
	var key := shape.get_instance_id()
	if _glass_usage.has(key):
		return bool(_glass_usage[key])
	var used: PackedByteArray = shape.data.get_used_materials()
	var colors := shape.palette.get_colors()
	for material in mini(256, mini(used.size(), colors.size())):
		if used[material] != 0 and colors[material].a < 0.995:
			_glass_usage[key] = true
			return true
	_glass_usage[key] = false
	return false


static func _transform_equal(a: Transform3D, b: Transform3D) -> bool:
	return a.origin.is_equal_approx(b.origin) and a.basis.is_equal_approx(b.basis)


static func _transform_close(
	a: Transform3D, b: Transform3D, position_epsilon: float, basis_epsilon: float
) -> bool:
	return a.origin.distance_to(b.origin) <= position_epsilon \
		and a.basis.x.distance_to(b.basis.x) <= basis_epsilon \
		and a.basis.y.distance_to(b.basis.y) <= basis_epsilon \
		and a.basis.z.distance_to(b.basis.z) <= basis_epsilon


static func _next_power_of_two(value: int) -> int:
	var result := 1
	while result < value:
		result <<= 1
	return result


func _exit_tree() -> void:
	if is_instance_valid(_camera):
		_camera.compositor = null
	compositor = null
	effect = null
	_voxel_atlas.release()
	_macro_atlas.release()
