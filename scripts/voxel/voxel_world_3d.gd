class_name VoxelWorld3D
extends Node3D
## Owns voxel Bodies, spatial queries, destruction splitting and the Jolt physics budget.

signal voxels_changed(shape: VoxelShape3D, world_aabb: AABB, dirty_min: Vector3i, dirty_max: Vector3i)
signal body_split(source: VoxelBody3D, created: Array[VoxelBody3D])
signal body_unregistered(body: VoxelBody3D)
signal voxel_impact(center: Vector3, removed_voxels: int, blast_radius: float)
## Semantic event before voxel damage is applied. Mechanisms that react to an explosion (such as a
## turret being thrown clear) do not have to infer its cause from `voxel_impact`.
signal explosion_started(center: Vector3, radius: float, energy: float)

const GROUP := "voxel_world"

@export var physics_budget: VoxelPhysicsBudget
@export var renderer_settings: VoxelRendererSettings
@export var show_diagnostics := true
@export var impact_particles_enabled := true
@export var physics_impact_damage_enabled := true
## Development audit: periodically compare the incremental index against the legacy flood fill.
## This is opt-in because it materializes every index in large Shapes.
@export var verify_connectivity_in_debug := false

var awake_bodies := 0
var compound_boxes := 0
## Number of compound boxes on awake bodies, the only ones that cost Jolt solver time.
var awake_compound_boxes := 0
var collision_rebuild_ms := 0.0
var retired_bodies := 0
var structural_coalesces := 0
var impact_particles := 0
var damage_native_ms := 0.0
var damage_query_ms := 0.0
var damage_notify_ms := 0.0
var damage_particles_ms := 0.0
var damage_split_ms := 0.0
var damage_connectivity_ms := 0.0
var connectivity_macros_visited := 0
var connectivity_voxels_materialized := 0
var connectivity_fallbacks := 0
var damage_external_support_ms := 0.0
var damage_component_fill_ms := 0.0
var damage_support_contacts_ms := 0.0
var damage_component_contact_calls := 0
var damage_support_routes_ms := 0.0
var damage_support_seed_ms := 0.0
var damage_fragment_ms := 0.0
var damage_detach_ms := 0.0
var damage_body_ms := 0.0
var damage_fragments := 0
var _damage_grounded_by_shape := {}
## Shape-to-neighbor pairs whose material contact crossed the crater before the current damage.
## Revalidate only these links with strict tolerance; distant authored contacts retain the map's
## clearance and do not break when another area of the same Shape is hit.
var _damage_cut_contact_pairs := {}
## Maximum rigid bodies created per frame. Two preserves immediate response and defers the third:
## with a 64-box compound, this reduced Lee's destruction P95 frame time from 41.03 to 35.69 ms and
## the impact window from 45.58 to 41.27 ms.
const FRAGMENTS_PER_FRAME := 2
var _pending_fragments: Array[Dictionary] = []
var _pending_support_checks := {}
var _collision_handoffs := VoxelCollisionHandoffQueue.new()
var _next_detachment_transaction := 1
var _active_damage_epoch := 0
var _pending_structural_coalesce := {}
var _desync_recovery_queued := {}
var _connectivity_verification_counter := 0
var damage_connectivity_guard_ms := 0.0
var connectivity_skipped := 0
var damage_impulse_ms := 0.0
var damage_budget_ms := 0.0
var physics_impacts := 0
var physics_impact_damage_ms := 0.0
var last_physics_impact := {}
var motion_contact_ms := 0.0
var motion_contact_tests := 0
var motion_contact_hits := 0
var _bodies: Array[VoxelBody3D] = []
var _dynamic_bodies: Array[VoxelBody3D] = []
var _dynamic_shapes: Array[VoxelShape3D] = []
var _dynamic_grid := {}
## Shape -> contact island in which it was created, per Body. See `_capture_weld_baseline`.
var _weld_baseline := {}
## Reverse index of `_contact_cache`: Shape -> which Shapes list it as a neighbor. See
## `_invalidate_contacts`.
var _contact_users := {}
var _dynamic_grid_cells := {}
var _dynamic_grid_transforms := {}
var _collision_rebuild_queue: Array[VoxelBody3D] = []
var _collision_rebuild_queued := {}
## Initial collision mesh waiting to enter Jolt based on distance to the player. Stored per Shape
## (not per physics node) so it can be invalidated precisely if that geometry is damaged.
var _baked_collision_queue: Array[Dictionary] = []
var _baked_collision_pending_blocks := 0
var _baked_collision_priority_elapsed := 0.0
var _burst_budget_pending := false
var _maintenance_elapsed := 0.0
var _body_cleanup_elapsed := 0.0
var _physics_impact_queue := VoxelImpactQueue.new()
var _motion_damage_scanner := VoxelMotionDamageScanner.new()
var _motion_scan_elapsed := 0.0
var _particle_pool: VoxelParticlePool
var _diagnostics: Label
var _runtime_registry := VoxelRuntimeRegistry.new()
## Bodies without their own simulation whose Shapes are transformed by another controller. Wheel
## visuals are the main case: their auxiliary Body stays frozen to avoid the solver, but the
## renderer and shadows must track them while VehicleWheel3D animates them.
var _externally_transformed_body_ids := {}
var _structural_graph := VoxelStructuralGraph.new()
var _support_planner := VoxelSupportPlanner.new()
var _damage_planner := VoxelDamagePlanner.new()

const IDLE_MAINTENANCE_INTERVAL := 0.25
const ACTIVE_MAINTENANCE_INTERVAL := 0.10
const DYNAMIC_GRID_CELL_SIZE := 8.0
const BAKED_COLLISION_PREFETCH_RADIUS := 80.0
const BAKED_COLLISION_FRAME_BUDGET_USEC := 1500
## A frozen piece is worse than a small cooking burst: use a larger time budget only to remove old
## shards blocking active handoffs.
const COLLISION_HANDOFF_BUDGET_USEC := 5000
const COLLISION_REBUILD_BUDGET_USEC := 1500
const BAKED_COLLISION_PRIORITY_INTERVAL := 0.5
const PHYSICS_IMPACT_MIN_ENERGY := 180.0
const PHYSICS_IMPACTS_PER_FRAME := 2
const PHYSICS_IMPACT_FRAME_BUDGET_USEC := 4000
const MAX_PENDING_PHYSICS_IMPACTS := 16
const MOTION_DAMAGE_MIN_SPEED := 3.0
const MOTION_CONTACT_MARGIN := 0.08
const MAX_MOTION_BODIES_PER_TICK := 8
const MAX_MOTION_CONTACT_TESTS_PER_TICK := 8
const MOTION_CONTACT_COOLDOWN_MSEC := 220
const MOTION_SCAN_INTERVAL := 1.0 / 30.0


## Muzzle flash. It belongs to the world, not the weapon, because the particle pool is world-owned:
## a cannon does not need its own emitter or light.
func emit_muzzle_blast(
	origin: Vector3, direction: Vector3, power := 1.0, ground_y := -INF
) -> void:
	if _particle_pool != null and impact_particles_enabled:
		_particle_pool.emit_muzzle_blast(origin, direction, power, ground_y)


## Fireball. It is intentionally separate from `damage_sphere`: voxel damage is the physical part of
## an explosion, and this is the visual effect. A charge detonating in midair, with nothing to
## destroy, should still look the same.
func emit_explosion(center: Vector3, radius: float) -> void:
	if _particle_pool != null and impact_particles_enabled:
		_particle_pool.emit_explosion(center, radius)


func _ready() -> void:
	add_to_group(GROUP)
	ensure_physics_budget()
	if renderer_settings == null:
		renderer_settings = VoxelRendererSettings.new()
	_particle_pool = VoxelParticlePool.new()
	_particle_pool.name = "VoxelParticlePool"
	add_child(_particle_pool)
	if show_diagnostics:
		_create_diagnostics()
	for child in get_children():
		if child is VoxelBody3D:
			register_body(child)


## Importers and tests can populate the world on the same tick they add it to the tree, before Godot
## calls `_ready`. Lazy initialization here prevents that path from using a different configuration
## or reading a null Resource.
func ensure_physics_budget() -> VoxelPhysicsBudget:
	if physics_budget == null:
		physics_budget = VoxelPhysicsBudget.new()
	return physics_budget


## `make_dynamic()` replaces a StaticBody and its shards with a RigidBody. Old nodes are freed at the
## end of the frame; until then, the new body would collide with its own collision. This handles
## complete transitions (towers/posts), complementing the ticket used for partial detachments.
func queue_transition_collision_handoff(body: VoxelBody3D) -> void:
	if body == null or not is_instance_valid(body) or not body.collision_handoff_pending:
		return
	if _collision_handoffs.contains_fragment(body):
		return
	_collision_handoffs.enqueue({
		"transaction": _next_detachment_transaction,
		"fragment": body,
		"source_body": null,
		"source_shape": null,
		"source_revision": 0,
		"absorbed": [],
		"impulse_center": Vector3.ZERO,
		"impulse_energy": 0.0,
		"impulse_radius": 0.0,
		"ready_frame": -1,
	})
	_next_detachment_transaction += 1


func create_body_from_asset(source: String, body_transform := Transform3D.IDENTITY) -> VoxelBody3D:
	var asset := VoxelAssetImporter.load_asset(source) if source.ends_with(".vox") \
		else VoxelAssetImporter.load_legacy_blueprint(source)
	if asset.is_empty():
		return null
	var body := VoxelBody3D.new()
	body.name = source.get_file().get_basename().capitalize()
	body.transform = body_transform
	add_child(body)
	for entry: Dictionary in asset.shapes:
		body.add_voxel_shape(VoxelShape3D.from_asset(entry, asset.palette))
	register_body(body)
	return body


func register_body(body: VoxelBody3D) -> void:
	if _bodies.has(body):
		return
	if not body.has_meta("structural_family"):
		body.set_meta("structural_family", body.get_instance_id())
	_bodies.append(body)
	if body.state == VoxelBody3D.State.DYNAMIC:
		_dynamic_bodies.append(body)
	body.body_state_changed.connect(_on_body_state_changed)
	body.runtime_state_changed.connect(_on_runtime_state_changed)
	for shape in body.get_shapes():
		register_shape(shape)
	_capture_weld_baseline(body)
	_bind_runtime_sleep_signal(body)
	_sync_runtime_body(body)


## Which Shapes in one Body touched BEFORE any were modified. Two Shapes that never touched are
## welded by the map author, not by their geometry, so destruction cannot break that union; only
## geometry actually separated by destruction is split.
func _capture_weld_baseline(body: VoxelBody3D) -> void:
	var shapes := body.get_shapes()
	if body.state != VoxelBody3D.State.DYNAMIC or shapes.size() < 2:
		return
	var groups := _contact_groups(shapes, {})
	for index in groups.size():
		for shape: VoxelShape3D in groups[index]:
			_weld_baseline[shape.get_instance_id()] = index


func register_shape(shape: VoxelShape3D) -> void:
	if shape.structural_lineage == 0:
		shape.structural_lineage = shape.get_instance_id()
	shape.sync_revision_baseline()
	var body := _body_of(shape)
	if body != null and body.state == VoxelBody3D.State.DYNAMIC:
		_register_dynamic_shape(shape)
	else:
		_index_static_shape(shape)
	if not shape.voxels_changed.is_connected(_on_shape_changed.bind(shape)):
		shape.voxels_changed.connect(_on_shape_changed.bind(shape))
	if body != null:
		# Some importers register the Body before adding all its Shapes (for example, vehicle wheel
		# visuals). Update its total as well to avoid classifying it as empty later.
		_sync_runtime_body(body)


func unregister_body(body: VoxelBody3D) -> void:
	if body == null:
		return
	untrack_external_body_transforms(body)
	# Authored wheels live in a visual Body without collision so they do not contaminate the chassis
	# compound. They belong to the vehicle: if destruction empties the chassis, four ghost wheels
	# must not remain in the renderer or dynamic-body list.
	var vehicle_visual := body.get_meta("teardown_vehicle_visual_body") as VoxelBody3D \
		if body.has_meta("teardown_vehicle_visual_body") else null
	if vehicle_visual != null:
		body.remove_meta("teardown_vehicle_visual_body")
		if _bodies.has(vehicle_visual):
			unregister_body(vehicle_visual)
		vehicle_visual.queue_free()
	# Final ownership barrier. Consumers release any reference here that was not transferred by
	# `body_split`; the Body is still alive while callbacks run.
	body_unregistered.emit(body)
	_bodies.erase(body)
	_dynamic_bodies.erase(body)
	_collision_rebuild_queued.erase(body.get_instance_id())
	_collision_rebuild_queue.erase(body)
	if body.body_state_changed.is_connected(_on_body_state_changed):
		body.body_state_changed.disconnect(_on_body_state_changed)
	if body.runtime_state_changed.is_connected(_on_runtime_state_changed):
		body.runtime_state_changed.disconnect(_on_runtime_state_changed)
	for shape in body.get_shapes():
		_cancel_baked_collision(shape)
		_unregister_shape_spatial(shape)
		_runtime_registry.remove_shape(shape.get_instance_id())
		_weld_baseline.erase(shape.get_instance_id())
		_desync_recovery_queued.erase(shape.get_instance_id())
	for index in range(_pending_fragments.size() - 1, -1, -1):
		var pending: Dictionary = _pending_fragments[index]
		if pending.get("source_body") != body:
			continue
		var pending_shape_variant: Variant = pending.get("shape")
		var new_owner: VoxelBody3D = _body_of(pending_shape_variant as VoxelShape3D) \
			if is_instance_valid(pending_shape_variant) else null
		if new_owner != null and new_owner != body:
			pending.source_body = new_owner
		else:
			_pending_fragments.remove_at(index)
	_collision_handoffs.remove_body(body)
	_runtime_registry.remove_body(body.get_instance_id())
	_apply_runtime_metrics()


## On-demand static collision. The full map takes 15.5 s, and 95% is geometry where the player is
## not present: build a radius around the entry point before releasing them, then load the rest by
## proximity under a per-frame budget during play.
## Bodies the clipmap must track every frame. The rest are static and do not move.
func get_dynamic_bodies() -> Array[VoxelBody3D]:
	return _dynamic_bodies


## Incremental view for per-frame consumers. Prevents water, clipmaps, and the grid from scanning
## every sleeping prop only to discard them immediately.
func get_awake_dynamic_bodies() -> Array[VoxelBody3D]:
	var result: Array[VoxelBody3D] = []
	for body_id: int in _runtime_registry.get_awake_body_ids():
		var body := instance_from_id(body_id) as VoxelBody3D
		if body != null and is_instance_valid(body) and body.state == VoxelBody3D.State.DYNAMIC:
			result.append(body)
	return result


## Direct IDs for native per-frame consumers. Avoid rebuilding Arrays of Nodes in GDScript before
## the tracker iterates them again.
func get_awake_dynamic_body_ids() -> PackedInt64Array:
	return _runtime_registry.get_awake_body_ids()


## Transform source for visual consumers. Kept separate from `get_awake_dynamic_body_ids`: a visual
## Body without collision must not inflate Jolt budgets or the awake-body count just so the renderer
## can track it.
func get_transform_tracked_body_ids() -> PackedInt64Array:
	var result := get_awake_dynamic_body_ids()
	for body_id: int in _externally_transformed_body_ids:
		result.append(body_id)
	return result


func track_external_body_transforms(body: VoxelBody3D) -> void:
	if body != null and is_instance_valid(body):
		_externally_transformed_body_ids[body.get_instance_id()] = true


func untrack_external_body_transforms(body: VoxelBody3D) -> void:
	if body != null:
		_externally_transformed_body_ids.erase(body.get_instance_id())


func is_body_externally_transform_tracked(body_id: int) -> bool:
	return _externally_transformed_body_ids.has(body_id)


func queue_collision_rebuild(body: VoxelBody3D) -> void:
	var key := body.get_instance_id()
	if _collision_rebuild_queued.has(key):
		return
	_collision_rebuild_queued[key] = true
	_collision_rebuild_queue.append(body)


func prioritize_collision_rebuild(body: VoxelBody3D) -> void:
	if body == null or not is_instance_valid(body) or not body.has_pending_collision_rebuild():
		return
	var key := body.get_instance_id()
	_collision_rebuild_queue.erase(body)
	_collision_rebuild_queue.push_front(body)
	_collision_rebuild_queued[key] = true


func queue_baked_static_collision(
	body: VoxelBody3D, shape: VoxelShape3D, records: Array
) -> void:
	if body == null or shape == null \
			or body.state == VoxelBody3D.State.DYNAMIC or not body.collision_enabled:
		return
	# A Shape can be visually dense without producing physical faces (pass-through material in a
	# shared palette). A valid cache with zero blocks is a completed result, not delayed collision:
	# leaving its revision at zero caused `coherence DESYNC` from startup.
	if records.is_empty():
		body.acknowledge_static_collision_revision(shape)
		_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), false)
		_sync_runtime_shape(shape, body)
		return
	_baked_collision_queue.append({
		"body": body,
		"shape": shape,
		"records": records,
		"cursor": 0,
		"distance_squared": INF,
	})
	_baked_collision_pending_blocks += records.size()
	_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), true)
	_sync_runtime_shape(shape, body)


## Synchronously installs only the area where the player can land on spawn. Returns metrics to
## separate this necessary cost from the rest of the map, which remains streamed.
func prime_baked_static_collision(center: Vector3, radius: float) -> Dictionary:
	var started := Time.get_ticks_usec()
	var installed := 0
	for index in range(_baked_collision_queue.size() - 1, -1, -1):
		var entry: Dictionary = _baked_collision_queue[index]
		var shape := entry.shape as VoxelShape3D
		var body := entry.body as VoxelBody3D
		if not is_instance_valid(shape) or not is_instance_valid(body):
			if is_instance_valid(shape):
				_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), false)
			_baked_collision_pending_blocks -= (entry.records as Array).size() - int(entry.cursor)
			_baked_collision_queue.remove_at(index)
			continue
		var bounds := shape.world_bounds()
		var closest := center.clamp(bounds.position, bounds.end)
		if closest.distance_squared_to(center) > radius * radius:
			continue
		var remaining: Array = (entry.records as Array).slice(int(entry.cursor))
		body.import_baked_static_collision(shape, remaining)
		body.acknowledge_static_collision_revision(shape)
		installed += remaining.size()
		_baked_collision_pending_blocks -= remaining.size()
		_baked_collision_queue.remove_at(index)
		_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), false)
		_sync_runtime_body(body)
	_prioritize_baked_collision(center)
	return {
		"blocks": installed,
		"pending_blocks": _baked_collision_pending_blocks,
		"ms": (Time.get_ticks_usec() - started) / 1000.0,
	}


## Completes the immutable part of the broad phase while the map is still loading. Otherwise the
## first shot has to sort every static Shape before it can even discover what was hit.
func finalize_spatial_index() -> void:
	# Indexing accesses `_static_grid`, so it stays on the main thread. The connectivity index only
	# writes to its own VoxelShapeData and can therefore run across worker threads. It was 41% of map
	# loading when measured serially (8.5 s out of 20.6 s).
	var pending := {}
	for body in _bodies:
		if not is_instance_valid(body) or body.state == VoxelBody3D.State.DYNAMIC:
			continue
		for shape in body.get_shapes():
			_index_static_shape(shape)
			if shape.data != null:
				# Multiple Shapes may share a resource: create one task per instance.
				pending[shape.data.get_instance_id()] = shape.data
	if pending.is_empty():
		return
	# Build this outside the gameplay frame. Small Shapes still build it on demand; large ones avoid
	# making the first cut pay to scan all their macro-cells.
	var shapes := pending.values()
	var group := WorkerThreadPool.add_group_task(
		func(index: int) -> void: shapes[index].prepare_connectivity_index(),
		shapes.size(), -1, true, "voxel_connectivity_index"
	)
	# Wait here: an impact cannot arrive while a worker is rebuilding the index.
	WorkerThreadPool.wait_for_group_task_completion(group)


## Grid of static Shapes, used by foundation searches. The AABB tree is not used because destruction
## marks it dirty, and the next query rebuilds all 2,312 sorted Shapes (measured at 56 ms per shot).
## Static Shapes do not move, so insert them once and remove them when they become dynamic or are
## freed.
func _index_static_shape(shape: VoxelShape3D) -> void:
	if not is_instance_valid(shape) or not shape.is_inside_tree() or shape.data == null:
		return
	_static_grid.insert(shape, shape.world_bounds())
	# Pay the linear count once when registering/importing the Shape, never on the first shot's frame.
	# Native damage then subtracts exactly the foundation voxels it removes.
	shape.foundation_voxel_count(FOUNDATION_HARDNESS)


## Applies material-aware damage and returns one record per affected Shape.
func damage_sphere(
	center: Vector3, radius: float, energy: float, options: Dictionary = {}
) -> Array[Dictionary]:
	if String(options.get("cause", "impact")) == "explosion":
		explosion_started.emit(center, radius, energy)
	# Multiple charges can detonate in the same frame. They share an epoch so authored pieces still
	# touching end up in one Body; damage from different frames is never welded together.
	_active_damage_epoch = Engine.get_process_frames()
	_pending_structural_coalesce[_active_damage_epoch] = true
	var affected: Array[Dictionary] = []
	var total_removed := 0
	impact_particles = 0
	damage_native_ms = 0.0
	damage_query_ms = 0.0
	damage_notify_ms = 0.0
	damage_particles_ms = 0.0
	damage_split_ms = 0.0
	damage_connectivity_ms = 0.0
	connectivity_macros_visited = 0
	connectivity_voxels_materialized = 0
	connectivity_fallbacks = 0
	damage_external_support_ms = 0.0
	damage_component_fill_ms = 0.0
	damage_support_contacts_ms = 0.0
	damage_component_contact_calls = 0
	damage_support_routes_ms = 0.0
	damage_support_seed_ms = 0.0
	damage_fragment_ms = 0.0
	damage_detach_ms = 0.0
	damage_body_ms = 0.0
	damage_fragments = 0
	_damage_grounded_by_shape.clear()
	_damage_cut_contact_pairs.clear()
	damage_connectivity_guard_ms = 0.0
	connectivity_skipped = 0
	damage_impulse_ms = 0.0
	damage_budget_ms = 0.0
	# The cut and structural re-evaluation use the exact crater region. The outer band is only used
	# for the impulse; it must not trigger flood fills for buildings that did not change.
	var query_started := Time.get_ticks_usec()
	var damage_shapes := _query_shapes(center, radius)
	# The dynamic grid refreshes at 10 Hz. A fast object may impact outside its previous cell, so add
	# both Bodies reported by the solver explicitly to avoid missing it.
	for extra_variant: Variant in options.get("extra_bodies", []):
		var extra := extra_variant as VoxelBody3D
		if extra == null or not is_instance_valid(extra):
			continue
		for extra_shape in extra.get_shapes():
			if not damage_shapes.has(extra_shape):
				damage_shapes.append(extra_shape)
	# Some impacts have an unambiguous material owner. A car's front should break the soft wall in
	# front of it, not punch through its own body with the same sphere. Apply the filter after adding
	# solver-reported Bodies so it does not depend on the 10 Hz grid.
	var only_body_ids := {}
	for only_variant: Variant in options.get("only_bodies", []):
		var only_body := only_variant as VoxelBody3D
		if only_body != null and is_instance_valid(only_body):
			only_body_ids[only_body.get_instance_id()] = true
	if not only_body_ids.is_empty():
		var filtered_shapes: Array[VoxelShape3D] = []
		for candidate in damage_shapes:
			var candidate_body := _body_of(candidate)
			if candidate_body != null and only_body_ids.has(candidate_body.get_instance_id()):
				filtered_shapes.append(candidate)
		damage_shapes = filtered_shapes
	var apply_radial_impulse := bool(options.get("apply_impulse", true))
	var nearby_shapes: Array[VoxelShape3D] = []
	if apply_radial_impulse:
		nearby_shapes = _query_shapes(center, radius * 3.0)
	damage_query_ms = (Time.get_ticks_usec() - query_started) / 1000.0
	var support_seed_map := {}
	var finalized_impulse_bodies := {}
	var seed_started := Time.get_ticks_usec()
	# The change invalidates the cache by emitting `voxels_changed`. Save both ends of each link that
	# may disappear beforehand so a beam outside the radius is reevaluated too.
	for candidate in damage_shapes:
		var candidate_body := _body_of(candidate)
		if candidate_body == null or candidate_body.state != VoxelBody3D.State.STATIC \
				or candidate.anchored:
			continue
		for old_neighbour in _local_static_contacts(candidate, center, radius):
			support_seed_map[old_neighbour.get_instance_id()] = old_neighbour
			_damage_cut_contact_pairs[_contact_pair_key(candidate, old_neighbour)] = true
	damage_support_seed_ms = (Time.get_ticks_usec() - seed_started) / 1000.0
	for shape in damage_shapes:
		var body := _body_of(shape)
		if body == null:
			continue
		var was_static := body.state == VoxelBody3D.State.STATIC
		if body.state == VoxelBody3D.State.RETIRED_STATIC:
			body.reactivate(_box_allowance_for_new_body())
		var damage: Dictionary = shape.damage_sphere(
			center, radius, energy, FOUNDATION_HARDNESS
		)
		damage_native_ms += shape.last_damage_native_ms
		damage_notify_ms += shape.last_damage_notify_ms
		if int(damage.get("removed", 0)) <= 0:
			continue
		body.set_meta("damage_epoch", _active_damage_epoch)
		support_seed_map[shape.get_instance_id()] = shape
		total_removed += int(damage.removed)
		var particle_started := Time.get_ticks_usec()
		if impact_particles_enabled and bool(options.get("particles", true)):
			impact_particles += _particle_pool.emit_damage(
				shape, damage, center, energy, radius, String(options.get("cause", "impact"))
			)
		damage_particles_ms += (Time.get_ticks_usec() - particle_started) / 1000.0
		var split_started := Time.get_ticks_usec()
		var created: Array[VoxelBody3D] = []
		# Losing root material requires reclassification even if only one island remains; removing
		# rock from another area does not. Forcing a flood fill for every shallow terrain crater cost 107 ms.
		var should_classify := bool(damage.get("should_classify", false))
		damage_connectivity_guard_ms += float(damage.get("guard_usec", 0)) / 1000.0
		if should_classify:
			created = _split_disconnected(body, shape, center, radius)
			# `_split_disconnected` has already decided all affected components of this Shape and
			# their external paths. Passing the source Shape through `_drop_unsupported` again repeated
			# a voxel-by-voxel BFS immediately afterward (measured at up to 4.6 ms). Keep the neighbor
			# seeds captured before damage; they are the ones that may have lost this support.
			support_seed_map.erase(shape.get_instance_id())
		else:
			connectivity_skipped += 1
		damage_split_ms += (Time.get_ticks_usec() - split_started) / 1000.0
		# A multi-Shape `<body dynamic>` may also have split into two islands still joined to the same
		# rigid body. This previously left pipe sections floating in formation with a gap between them.
		var loose := _split_loose_shapes(body)
		if not loose.is_empty():
			created.append_array(loose)
			damage_fragments += loose.size()
		created = _finalize_detached_bodies(
			body, shape, created, was_static, center, radius, finalized_impulse_bodies
		)
		affected.append({"shape": shape, "damage": damage, "new_bodies": created})
		# A dynamic Shape can be emptied completely by a second impact. Its old compound remained
		# until the deferred rebuild (and if it was the only Shape, the Body never disappeared):
		# in Lee, we observed a ghost with 0 voxels, 56 boxes, and 7 tonnes. A static source waits for
		# handoff; an already dynamic source protects no old collision and is cleaned up here.
		if not was_static and is_instance_valid(shape) and shape.voxel_count() == 0:
			_cleanup_empty_source(shape)
	var support_seeds: Array[VoxelShape3D] = []
	for support_seed: Variant in support_seed_map.values():
		if is_instance_valid(support_seed):
			support_seeds.append(support_seed as VoxelShape3D)
	if _pending_fragments.is_empty():
		_drop_unsupported(support_seeds)
	else:
		# A continuation touching the fourth fragment still looks like a rootless static chain.
		# Dropping it here would create another RigidBody before the deferred fragment can claim it.
		for support_shape in support_seeds:
			_pending_support_checks[support_shape.get_instance_id()] = {
				"shape": support_shape, "epoch": _active_damage_epoch,
			}
	var impulse_started := Time.get_ticks_usec()
	var impulse_bodies := {}
	# The impulse radius is larger than the cut radius, but is still local. Iterating all imported
	# Bodies and reading each RigidBody's center of mass used to cost about 200 ms per shot.
	for shape in nearby_shapes:
		var impulse_body := _body_of(shape)
		if impulse_body != null and impulse_body.state == VoxelBody3D.State.DYNAMIC:
			impulse_bodies[impulse_body] = true
	for body: VoxelBody3D in impulse_bodies:
		if finalized_impulse_bodies.has(body.get_instance_id()):
			continue
		# `apply_explosion_impulse` wakes a body only if its center of mass receives an impulse.
		# Previously, mere AABB overlap woke it first: a long cable/post nine meters away could enter
		# the solver even when its center was outside the blast, multiplying Bodies during collapse.
		# If the Shape was damaged, its signal already woke the Body; if it was static, the finalizer
		# created and woke the fragment. No structural transition is lost.
		# Push comes from blast size, not `energy`: since `energy` represents penetration against
		# hardness and is around 1, using it here left debris motionless.
		body.apply_explosion_impulse(center, radius * 5.0, radius * 3.0)
	damage_impulse_ms = (Time.get_ticks_usec() - impulse_started) / 1000.0
	var budget_started := Time.get_ticks_usec()
	# New bodies are allowed to exist inside the documented 192-Body burst window. Enforcing and
	# recounting the complete dynamic list inside every shot cost ~3 ms; the existing 10 Hz budget
	# tick performs the same work outside the destruction call.
	_burst_budget_pending = true
	damage_budget_ms = (Time.get_ticks_usec() - budget_started) / 1000.0
	if total_removed > 0 and bool(options.get("emit_impact_signal", true)):
		voxel_impact.emit(center, total_removed, radius)
	return affected


## Queues a physical collision without mutating Shapes during `_integrate_forces`. Two RigidBodies
## report the same contact from opposite sides; the canonical key merges them and keeps the larger
## impulse.
func queue_physics_impact(
	source: VoxelBody3D, collider: Object, point: Vector3,
	impulse: float, relative_speed: float
) -> void:
	if not physics_impact_damage_enabled:
		return
	if source == null or not is_instance_valid(source) or source.state != VoxelBody3D.State.DYNAMIC:
		return
	var target := _voxel_body_from_collision_object(collider)
	if target == source:
		return
	# The base ground, non-voxel StaticBodies, and wheel raycasts are not damage targets. Discarding
	# them here avoids even building a queue key for every bump in the road.
	if source.get_physics_body() is VoxelVehicle3D and target == null:
		return
	_physics_impact_queue.enqueue(
		source, target, collider, point, impulse, relative_speed, MAX_PENDING_PHYSICS_IMPACTS
	)


static func _voxel_body_from_collision_object(collider: Object) -> VoxelBody3D:
	var node := collider as Node
	while node != null:
		if node is VoxelBody3D:
			return node as VoxelBody3D
		node = node.get_parent()
	return null


func _process_physics_impacts() -> void:
	var processed := 0
	var frame_damage_ms := 0.0
	while processed < PHYSICS_IMPACTS_PER_FRAME and not _physics_impact_queue.is_empty():
		var record: Dictionary = _physics_impact_queue.pop_front()
		# An impact may wait several frames, during which destruction can remove the Body. Casting the
		# Variant pointing to the freed Node directly fails before a null check can run.
		var source_variant: Variant = record.source
		if not is_instance_valid(source_variant):
			continue
		var source := source_variant as VoxelBody3D
		if source == null:
			continue
		var target_variant: Variant = record.target
		var target := target_variant as VoxelBody3D if is_instance_valid(target_variant) else null
		var profile_source := source.vehicle_impact_owner \
			if source.vehicle_impact_owner != null \
				and is_instance_valid(source.vehicle_impact_owner) else source
		var profile := physics_impact_profile(
			profile_source, float(record.impulse), float(record.speed)
		)
		if not bool(profile.valid):
			continue
		var impact_energy := float(profile.energy)
		var radius := float(profile.radius)
		var penetration := float(profile.penetration)
		var vehicle_impact := bool(profile.vehicle)
		# Same rule as `queue_physics_impact`: a vehicle damages only the body it hit. If destruction
		# removed that body while the impact was queued, there is nothing left to break, and a sphere
		# without `only_bodies` would damage the attacking vehicle's own chassis.
		if vehicle_impact and target == null:
			continue
		var extra_bodies: Array[VoxelBody3D] = [source]
		if target != null and is_instance_valid(target):
			extra_bodies.append(target)
		last_physics_impact = {
			"point": record.point, "impulse": record.impulse, "speed": record.speed,
			"energy": impact_energy, "radius": radius, "penetration": penetration,
			"kind": "vehicle" if vehicle_impact else "body",
			"strength": float(profile.strength),
		}
		# Count the attempt before damage: indestructible material still consumed a query and must not
		# open the gate to drain all 16 queued events in one frame.
		processed += 1
		var started := Time.get_ticks_usec()
		var damage_options := {
			"apply_impulse": false,
			"emit_impact_signal": false,
			"particles": true,
			"extra_bodies": extra_bodies,
			"cause": "vehicle_impact" if vehicle_impact else "physics_impact",
		}
		if vehicle_impact and target != null and is_instance_valid(target):
			damage_options["only_bodies"] = [target]
		var affected := damage_sphere(record.point, radius, penetration, damage_options)
		frame_damage_ms += (Time.get_ticks_usec() - started) / 1000.0
		physics_impact_damage_ms = frame_damage_ms
		if not affected.is_empty():
			physics_impacts += 1
		if frame_damage_ms * 1000.0 >= PHYSICS_IMPACT_FRAME_BUDGET_USEC:
			break


## Material impact profile. Ordinary bodies retain the existing curve and bidirectional damage.
## A vehicle must clear roughly the width of its front in wood at city speed: mass contributes
## energy and XML `strength` scales the radius, while material hardness still reduces range inside
## `damage_sphere_material`.
static func physics_impact_profile(
	source: VoxelBody3D, impulse: float, normal_speed: float
) -> Dictionary:
	var impulse_energy := 0.5 * maxf(0.0, impulse) * maxf(0.0, normal_speed)
	var vehicle := source.get_physics_body() as VoxelVehicle3D \
		if source != null and is_instance_valid(source) else null
	if vehicle != null:
		var kinetic_energy := 0.5 * maxf(vehicle.mass, 1.0) * normal_speed * normal_speed
		var effective_energy := maxf(impulse_energy, kinetic_energy * 0.10)
		if effective_energy < PHYSICS_IMPACT_MIN_ENERGY:
			return {"valid": false}
		var strength := vehicle.impact_strength
		var automatic_radius := clampf(
			0.55 + normal_speed * 0.10 + strength * 0.035, 0.75, 1.45
		)
		return {
			"valid": true,
			"vehicle": true,
			"energy": effective_energy,
			"strength": strength,
			"radius": clampf(vehicle.impact_radius, 0.75, 3.2) \
				if vehicle.impact_radius > 0.0 else automatic_radius,
			"penetration": clampf(
				0.95 + normal_speed * 0.035 + strength * 0.07, 1.05, 2.35
			),
		}
	if impulse_energy < PHYSICS_IMPACT_MIN_ENERGY:
		return {"valid": false}
	return {
		"valid": true,
		"vehicle": false,
		"energy": impulse_energy,
		"strength": 0.0,
		"radius": clampf(0.10 + sqrt(impulse_energy) * 0.0065, 0.16, 1.25),
		"penetration": clampf(
			0.55 + log(maxf(impulse_energy, PHYSICS_IMPACT_MIN_ENERGY) / 250.0) * 0.28,
			0.45, 2.3
		),
	}


## Foliage and `unphysical` scenery do not generate Jolt faces, allowing the player to pass through.
## This exact, bounded pass preserves destructive interaction: a fast tower queries only static
## Shapes whose AABBs it touches, then confirms voxel contact in C++ before generating an impact.
func _physics_process(delta: float) -> void:
	if not physics_impact_damage_enabled:
		return
	_motion_scan_elapsed += delta
	if _motion_scan_elapsed < MOTION_SCAN_INTERVAL:
		return
	_motion_scan_elapsed = 0.0
	var started := Time.get_ticks_usec()
	var scan: Dictionary = _motion_damage_scanner.scan(
		self, _static_grid, get_awake_dynamic_bodies(), Time.get_ticks_msec(),
		MOTION_DAMAGE_MIN_SPEED, MOTION_CONTACT_MARGIN, MAX_MOTION_BODIES_PER_TICK,
		MAX_MOTION_CONTACT_TESTS_PER_TICK, MOTION_CONTACT_COOLDOWN_MSEC
	)
	motion_contact_ms = (Time.get_ticks_usec() - started) / 1000.0
	motion_contact_tests = int(scan.tests)
	motion_contact_hits += int(scan.hits)


func get_metrics() -> Dictionary:
	return {
		"awake_bodies": awake_bodies,
		"compound_boxes": compound_boxes,
		"awake_compound_boxes": awake_compound_boxes,
		"collision_rebuild_ms": collision_rebuild_ms,
		"retired_bodies": retired_bodies,
		"structural_coalesces": structural_coalesces,
		"impact_particles": impact_particles,
		"active_particles": _particle_pool.get_active_count() if _particle_pool != null else 0,
		"damage_native_ms": damage_native_ms,
		"damage_query_ms": damage_query_ms,
		"damage_notify_ms": damage_notify_ms,
		"damage_particles_ms": damage_particles_ms,
		"damage_split_ms": damage_split_ms,
		"damage_connectivity_ms": damage_connectivity_ms,
		"connectivity_macros_visited": connectivity_macros_visited,
		"connectivity_voxels_materialized": connectivity_voxels_materialized,
		"connectivity_fallbacks": connectivity_fallbacks,
		"damage_external_support_ms": damage_external_support_ms,
		"damage_component_fill_ms": damage_component_fill_ms,
		"damage_support_contacts_ms": damage_support_contacts_ms,
		"damage_component_contact_calls": damage_component_contact_calls,
		"damage_support_routes_ms": damage_support_routes_ms,
		"damage_support_seed_ms": damage_support_seed_ms,
		"support_search_ms": support_search_ms,
		"support_touch_ms": support_touch_ms,
		"support_grid_ms": support_grid_ms,
		"support_touch_calls": support_touch_calls,
		"support_nodes": support_nodes,
		"support_candidates": support_candidates,
		"damage_fragment_ms": damage_fragment_ms,
		"damage_connectivity_guard_ms": damage_connectivity_guard_ms,
		"connectivity_skipped": connectivity_skipped,
		"damage_impulse_ms": damage_impulse_ms,
		"damage_budget_ms": damage_budget_ms,
		"physics_impacts": physics_impacts,
		"physics_impact_damage_ms": physics_impact_damage_ms,
		"pending_physics_impacts": _physics_impact_queue.size(),
		"last_physics_impact": last_physics_impact,
		"motion_contact_ms": motion_contact_ms,
		"motion_contact_tests": motion_contact_tests,
		"motion_contact_hits": motion_contact_hits,
		"pending_collision_rebuilds": _collision_rebuild_queue.size(),
		"pending_collision_blocks": _pending_collision_block_count(),
		"pending_collision_handoffs": _collision_handoffs.size(),
		"pending_fragments": _pending_fragments.size(),
		"pending_baked_collision_shapes": _baked_collision_queue.size(),
		"pending_baked_collision_blocks": _baked_collision_pending_blocks,
		"dynamic_shapes": _dynamic_shapes.size(),
	}


## Anything no longer connected to the ground must fall; that is literally Teardown's model: there
## is no stress analysis ("if you knock down all the walls of a house but there's one voxel still
## standing, it will stay up"). The only question is whether a piece remains connected to a
## foundation, and that connection is INDIRECT: `IsBodyJointedToStatic` defines it as "either by
## being static itself or by being directly or indirectly jointed to something static".
##
## Here, rock is the foundation. Teardown ground is `rock`, hardness 1e6, and cannot be destroyed,
## so a Shape containing live rock is a foundation by definition. Everything else needs a chain of
## real contacts leading to one.
##
## Without this, nothing in the map ever fell: every imported Shape has `anchored = false`, and an
## unanchored Shape that remains one connected island exits `_split_disconnected` without any checks.
## A pipe section, fence, and tower are each a single island.
##
## There is no size rule. There used to be one—"anything larger than 30 m is terrain"—and it left a
## tower suspended in the air: a rotated Shape's bounds expand, and in Lee 34 non-terrain Shapes
## exceeded 30 m, with cubic AABBs 44 and 51 m across. Measured. Terrain needs no such rule because
## it is already rock: 516 map Shapes qualify by material.
const FOUNDATION_HARDNESS := 1000.0
## Authored clearance between separate Shapes. Lee places some pieces that form one object (for
## example, the mast and head of the power tower) up to 12 cm apart on their grids. Reducing this
## global margin separates the object prematurely and leaves its handoff waiting for two bodies
## that should fall as one.
const CONTACT_MARGIN := 0.12
## A newly classified component within a Shape has no authored clearance: its voxels come from the
## same exact grid. Using the global 12 cm margin here bridges a newly removed cell and makes a fence
## continue "touching" a pillar after their connection is destroyed.
const COMPONENT_CONTACT_MARGIN := 0.09

var _static_grid := VoxelShapeGrid.new()
## Shape id -> exact number of live root voxels.
## Cached contacts, keyed by Shape ID. Contacts between two static Shapes remain unchanged unless
## one is damaged, and the same corner is hit repeatedly during a session.
var _contact_cache := {}
var _support_searches := 0
var support_search_ms := 0.0
var support_touch_calls := 0
var support_dropped := 0
var support_touch_ms := 0.0
var support_grid_ms := 0.0
var support_nodes := 0
var support_candidates := 0
var support_foundation_tests := 0
var support_foundation_ms := 0.0


## `true` if the Shape still contains live foundation material. Size, AABB, and collision contact
## do not make a piece a root.
func _is_foundation(shape: VoxelShape3D) -> bool:
	var started := Time.get_ticks_usec()
	support_foundation_tests += 1
	var result := shape.foundation_voxel_count(FOUNDATION_HARDNESS)
	support_foundation_ms += (Time.get_ticks_usec() - started) / 1000.0
	return result > 0


## Static Shapes whose live voxels actually touch this Shape's voxels. Overlapping bounding boxes
## do not count as contact: AABBs of entire neighborhoods overlap, making everything appear
## connected to everything else. The box only generates candidates; `touches` makes the decision.
## Splits a dynamic Body whose Shapes are no longer touching.
##
## A Teardown `<body dynamic="true">` can contain multiple Shapes in one rigid body: Lee's pipe
## sections come in groups of four. If a shot removes one completely, the remaining sections stay
## welded together and float in formation with a gap between them, with nothing to release them.
## `_split_disconnected` cannot detect this because it only examines one Shape at a time.
##
## Runs only on the Body that was just damaged and its few Shapes, so it does not show up in the
## profile.
func _split_loose_shapes(body: VoxelBody3D) -> Array[VoxelBody3D]:
	# A joint is NOT a reason to avoid splitting. `is_physics_persistent()` counts constraint holds,
	# and in Lee 20 of the 40 multi-Shape dynamic bodies have one: these were exactly the bodies left
	# with half a post floating, welded by the RigidBody to the half held by the joint. Do preserve a
	# vehicle (its Shapes form a chassis) and an incomplete handoff, which has no collision to decide
	# anything yet.
	if body.state != VoxelBody3D.State.DYNAMIC or body.physics_persistent \
			or body.collision_handoff_pending or body.get_physics_body() is VoxelVehicle3D:
		return []
	var shapes: Array[VoxelShape3D] = []
	for shape in body.get_shapes():
		if shape.data != null and shape.voxel_count() > 0:
			shapes.append(shape)
	if shapes.size() < 2:
		return []
	var groups := _contact_groups(shapes, _weld_baseline)
	if groups.size() < 2:
		return []
	var created: Array[VoxelBody3D] = []
	# The first group keeps the original Body; each remaining group gets a new one.
	for index in range(1, groups.size()):
		var piece := VoxelBody3D.new()
		piece.name = "%s_suelto%d" % [body.name, index]
		piece.state = VoxelBody3D.State.DYNAMIC
		piece.structural = body.structural
		piece.collision_enabled = body.collision_enabled
		piece.set_meta("structural_family", body.get_meta(
			"structural_family", body.get_instance_id()
		))
		add_child(piece)
		for shape: VoxelShape3D in groups[index]:
			_unregister_shape_spatial(shape)
			body.release_voxel_shape(shape)
			piece.add_voxel_shape(shape, true, false)
		piece.rebuild_dynamic_collision(_box_allowance_for_new_body())
		register_body(piece)
		piece.wake_for_interaction()
		created.append(piece)
	body.rebuild_dynamic_collision(_box_allowance_for_new_body())
	body.wake_for_interaction()
	return created


## Groups Shapes in the same Body by real voxel contact and unbreakable authored welds. An empty
## `weld` gives the raw grouping used to establish the baseline.
func _contact_groups(shapes: Array[VoxelShape3D], weld: Dictionary) -> Array:
	var edges := PackedInt32Array()
	for first in shapes.size():
		for second in range(first + 1, shapes.size()):
			if _linked(shapes[first], shapes[second], weld):
				edges.append(first)
				edges.append(second)
	var groups: Array = []
	for native_group: PackedInt32Array in _structural_graph.connected_groups(shapes.size(), edges):
		var group: Array[VoxelShape3D] = []
		for shape_index in native_group:
			group.append(shapes[shape_index])
		groups.append(group)
	return groups


func _linked(a: VoxelShape3D, b: VoxelShape3D, weld: Dictionary) -> bool:
	if a == b:
		return false
	var key_a := a.get_instance_id()
	var key_b := b.get_instance_id()
	# Islands separate at birth never touched, so there is no geometry between them to destroy.
	if weld.has(key_a) and weld.has(key_b) and int(weld[key_a]) != int(weld[key_b]):
		return true
	return _shapes_touch(a, b)


func _shapes_touch(a: VoxelShape3D, b: VoxelShape3D) -> bool:
	return _shapes_touch_with_margin(a, b, CONTACT_MARGIN)


func _shapes_touch_with_margin(a: VoxelShape3D, b: VoxelShape3D, margin: float) -> bool:
	if a == b or a.data == null or b.data == null:
		return false
	if not a.world_bounds().grow(margin).intersects(b.world_bounds()):
		return false
	# `touches` scans the cells in the volume it is called on, so call it on the smaller one.
	var self_smaller := a.voxel_count() <= b.voxel_count()
	var from := a if self_smaller else b
	var to := b if self_smaller else a
	# `touches` expects other -> self: the transform that maps a point from the OTHER volume into
	# this one. Reversing it works while both Shapes are near the origin but fails badly at a
	# distance: in Lee, a 24 m tower 70 m from the center did not "touch" the ground directly below
	# even with a 2 m margin; with the correct transform, it touches at 12 cm.
	var relative := from.global_transform.affine_inverse() * to.global_transform
	return from.data.touches(
		to.data, relative, from.voxel_size, to.voxel_size, margin, 0
	)


## Join only structural pieces created or awakened by the same damage batch that still have voxel
## contact. This is not a collision-based merge: Bodies from different frames, or two fragments of
## the same volume separated by the crater, are never welded together.
func _coalesce_ready_structural_bodies() -> void:
	for epoch_variant: Variant in _pending_structural_coalesce.keys():
		var epoch := int(epoch_variant)
		var fragments_pending := false
		for pending_fragment: Dictionary in _pending_fragments:
			if int(pending_fragment.get("damage_epoch", -1)) == epoch:
				fragments_pending = true
				break
		if fragments_pending:
			continue
		var candidates: Array[VoxelBody3D] = []
		for body in _dynamic_bodies:
			if not is_instance_valid(body) or body.state != VoxelBody3D.State.DYNAMIC \
					or not body.structural or int(body.get_meta("damage_epoch", -1)) != epoch \
					or body.get_total_voxels() == 0:
				continue
			candidates.append(body)
		# Group before releasing handoffs. All compounds already exist, and the host is rebuilt once
		# after absorption; waiting until every Body receives its impulse separates them physically
		# during the same frame and makes it impossible to recognize them later as one tower.
		var unassigned := candidates.duplicate()
		while not unassigned.is_empty():
			var group: Array[VoxelBody3D] = [unassigned.pop_back()]
			var cursor := 0
			while cursor < group.size():
				var current := group[cursor]
				cursor += 1
				for index in range(unassigned.size() - 1, -1, -1):
					if not _structural_bodies_touch(current, unassigned[index]):
						continue
					group.append(unassigned[index])
					unassigned.remove_at(index)
			if group.size() < 2:
				continue
			var host := group[0]
			for candidate in group:
				if candidate.get_total_voxels() > host.get_total_voxels():
					host = candidate
			_absorb_bodies_into(host, group)
			host.set_meta("damage_epoch", epoch)
			host.continuous_collision = true
			host.rebuild_dynamic_collision(_box_allowance_for_new_body())
			host.wake_for_interaction()
			structural_coalesces += group.size() - 1
		_pending_structural_coalesce.erase(epoch)


func _structural_bodies_touch(a: VoxelBody3D, b: VoxelBody3D) -> bool:
	if a == b:
		return false
	# Regroup only a family that shared a Body before this cut. Two buildings or debris pieces that
	# merely collide during the same explosion are never welded together.
	var family_a := int(a.get_meta("structural_family", -1))
	if family_a < 0 or family_a != int(b.get_meta("structural_family", -2)):
		return false
	for shape_a in a.get_shapes():
		if shape_a.voxel_count() == 0:
			continue
		for shape_b in b.get_shapes():
			if shape_b.voxel_count() == 0:
				continue
			# Same lineage means parts of the same cut volume: numerical tolerance only. Different
			# lineages mean authored pieces whose placement allows CONTACT_MARGIN.
			var same_lineage := shape_a.structural_lineage != 0 \
				and shape_a.structural_lineage == shape_b.structural_lineage
			var margin := 0.005 if same_lineage else CONTACT_MARGIN
			if _shapes_touch_with_margin(shape_a, shape_b, margin):
				return true
	return false


func _static_contacts(shape: VoxelShape3D) -> Array[VoxelShape3D]:
	var cache_key := shape.get_instance_id()
	if _contact_cache.has(cache_key):
		var cache_entry := _contact_cache[cache_key] as Dictionary
		if _contact_cache_entry_valid(shape, cache_entry):
			var cached: Array[VoxelShape3D] = []
			for cached_shape: VoxelShape3D in cache_entry.get("contacts", []):
				cached.append(cached_shape)
			return cached
		_invalidate_contacts(shape)
	var result: Array[VoxelShape3D] = []
	support_nodes += 1
	var bounds := shape.world_bounds()
	var grown := bounds.grow(CONTACT_MARGIN)
	var grid_started := Time.get_ticks_usec()
	var candidates := _static_grid.query(grown)
	support_grid_ms += (Time.get_ticks_usec() - grid_started) / 1000.0
	support_candidates += candidates.size()
	for candidate in candidates:
		if candidate == shape or candidate.data == null:
			continue
		var body := _body_of(candidate)
		if body == null or body.state != VoxelBody3D.State.STATIC:
			continue
		# Scan the smaller of the two volumes: `touches` iterates the cells of the receiver.
		var self_smaller := shape.voxel_count() <= candidate.voxel_count()
		var from := shape if self_smaller else candidate
		var to := candidate if self_smaller else shape
		# other -> self, as in `_shapes_touch`; reversing it makes distant contacts fail.
		var relative := from.global_transform.affine_inverse() * to.global_transform
		var contact_margin := COMPONENT_CONTACT_MARGIN \
			if _damage_cut_contact_pairs.has(_contact_pair_key(shape, candidate)) \
			else CONTACT_MARGIN
		support_touch_calls += 1
		var touch_started := Time.get_ticks_usec()
		var hit: bool = from.data.touches(
			to.data, relative, from.voxel_size, to.voxel_size, contact_margin, 0
		)
		support_touch_ms += (Time.get_ticks_usec() - touch_started) / 1000.0
		if hit:
			result.append(candidate)
	var contact_revisions := {}
	for neighbour in result:
		var neighbour_body := _body_of(neighbour)
		contact_revisions[neighbour.get_instance_id()] = {
			"revision": neighbour.content_revision(),
			"generation": neighbour_body.physics_generation if neighbour_body != null else 0,
			"pose": neighbour.global_transform,
		}
	var source_body := _body_of(shape)
	_contact_cache[cache_key] = {
		"source_revision": shape.content_revision(),
		"source_generation": source_body.physics_generation if source_body != null else 0,
		"source_pose": shape.global_transform,
		"contacts": result,
		"contact_revisions": contact_revisions,
	}
	# Reverse index: which Shapes have each neighbor in THEIR list. A contact has two endpoints, but
	# the cache is per Shape and `_reaches_foundation` stops as soon as it finds a foundation, so a
	# neighbor could otherwise remain without its own entry forever.
	for neighbour in result:
		var neighbour_key := neighbour.get_instance_id()
		var users: Dictionary = _contact_users.get(neighbour_key, {})
		users[cache_key] = true
		_contact_users[neighbour_key] = users
	return result


func _contact_cache_entry_valid(shape: VoxelShape3D, entry: Dictionary) -> bool:
	var source_body := _body_of(shape)
	if source_body == null or source_body.state != VoxelBody3D.State.STATIC \
			or int(entry.get("source_revision", -1)) != shape.content_revision() \
			or int(entry.get("source_generation", -1)) != source_body.physics_generation \
			or not (entry.get("source_pose", Transform3D.IDENTITY) as Transform3D) \
				.is_equal_approx(shape.global_transform):
		return false
	var revisions := entry.get("contact_revisions", {}) as Dictionary
	for neighbour_variant: Variant in entry.get("contacts", []):
		if not is_instance_valid(neighbour_variant):
			return false
		var neighbour := neighbour_variant as VoxelShape3D
		var neighbour_body := _body_of(neighbour)
		var recorded := revisions.get(neighbour.get_instance_id(), {}) as Dictionary
		if neighbour.voxel_count() <= 0 or neighbour_body == null \
				or neighbour_body.state != VoxelBody3D.State.STATIC \
				or int(recorded.get("revision", -1)) != neighbour.content_revision() \
				or int(recorded.get("generation", -1)) != neighbour_body.physics_generation \
				or not (recorded.get("pose", Transform3D.IDENTITY) as Transform3D) \
					.is_equal_approx(neighbour.global_transform):
			return false
	return true


## Material contacts that cross only the region about to change. Saves both endpoints of edges the
## crater may remove without scanning every contact on a terrain Shape hundreds of meters wide.
func _local_static_contacts(
	shape: VoxelShape3D, world_center: Vector3, radius: float
) -> Array[VoxelShape3D]:
	var center := shape.world_to_voxel(world_center)
	var reach := ceili((radius + CONTACT_MARGIN) / shape.voxel_size) + 1
	var low := Vector3i(floori(center.x), floori(center.y), floori(center.z)) \
		- Vector3i.ONE * reach
	var high := Vector3i(ceili(center.x), ceili(center.y), ceili(center.z)) \
		+ Vector3i.ONE * (reach + 1)
	var local_indices: PackedInt32Array = shape.data.get_live_indices_region(low, high)
	if local_indices.is_empty():
		return []
	var result: Array[VoxelShape3D] = []
	var world_reach := radius + CONTACT_MARGIN + shape.voxel_size
	var region := AABB(
		world_center - Vector3.ONE * world_reach, Vector3.ONE * world_reach * 2.0
	)
	for neighbour in _static_grid.query(region):
		if neighbour == shape or neighbour.data == null:
			continue
		var body := _body_of(neighbour)
		if body == null or body.state != VoxelBody3D.State.STATIC:
			continue
		var relative := shape.global_transform.affine_inverse() * neighbour.global_transform
		if shape.data.component_touches(
			local_indices, neighbour.data, relative, shape.voxel_size,
			neighbour.voxel_size, CONTACT_MARGIN
		):
			result.append(neighbour)
	return result


## Search for a foundation from `shape`, following contact links. Return the visited Shapes and
## whether any reaches the ground; one search resolves the entire chain.
func _reaches_foundation(
	shape: VoxelShape3D, excluded: VoxelShape3D = null
) -> Dictionary:
	var excluded_id := excluded.get_instance_id() if excluded != null else 0
	return _support_planner.route(
		_structural_graph,
		shape.get_instance_id(), excluded_id,
		_native_is_foundation_id, _native_static_contact_ids, _native_touches_foundation_directly
	)


func _native_is_foundation_id(shape_id: int) -> bool:
	var shape_variant := instance_from_id(shape_id)
	return is_instance_valid(shape_variant) and _is_foundation(shape_variant as VoxelShape3D)


func _native_static_contact_ids(shape_id: int) -> PackedInt64Array:
	var result := PackedInt64Array()
	var shape_variant := instance_from_id(shape_id)
	if not is_instance_valid(shape_variant):
		return result
	for neighbour in _static_contacts(shape_variant as VoxelShape3D):
		result.append(neighbour.get_instance_id())
	return result


func _native_body_for_shape_id(shape_id: int) -> VoxelBody3D:
	var shape_variant := instance_from_id(shape_id)
	return _body_of(shape_variant as VoxelShape3D) if is_instance_valid(shape_variant) else null


func _native_touches_foundation_directly(shape_id: int, excluded_id: int) -> bool:
	if _contact_cache.has(shape_id):
		return false
	var shape_variant := instance_from_id(shape_id)
	if not is_instance_valid(shape_variant):
		return false
	var excluded_variant := instance_from_id(excluded_id) if excluded_id != 0 else null
	var excluded := excluded_variant as VoxelShape3D if is_instance_valid(excluded_variant) else null
	return _touches_foundation_directly(shape_variant as VoxelShape3D, excluded)


func _touches_foundation_directly(shape: VoxelShape3D, excluded: VoxelShape3D) -> bool:
	var started := Time.get_ticks_usec()
	var candidates := _static_grid.query(shape.world_bounds().grow(CONTACT_MARGIN))
	for candidate in candidates:
		if candidate == shape or candidate == excluded or candidate.data == null \
				or not _is_foundation(candidate):
			continue
		var body := _body_of(candidate)
		var contact_margin := COMPONENT_CONTACT_MARGIN \
			if _damage_cut_contact_pairs.has(_contact_pair_key(shape, candidate)) \
			else CONTACT_MARGIN
		if body != null and body.state == VoxelBody3D.State.STATIC \
				and _shapes_touch_with_margin(shape, candidate, contact_margin):
			damage_support_contacts_ms += (Time.get_ticks_usec() - started) / 1000.0
			return true
	damage_support_contacts_ms += (Time.get_ticks_usec() - started) / 1000.0
	return false


func _component_reaches_external_foundation(
	shape: VoxelShape3D, component: Dictionary, grounded_by_shape: Dictionary
) -> bool:
	var dimensions := shape.data.get_dimensions()
	var minimum := Vector3(component.get("minimum", Vector3i.ZERO)) - Vector3(dimensions) * 0.5
	var maximum := Vector3(component.get("maximum", Vector3i.ZERO) + Vector3i.ONE) \
		- Vector3(dimensions) * 0.5
	var component_bounds := shape.global_transform * AABB(
		minimum * shape.voxel_size, (maximum - minimum) * shape.voxel_size
	)
	var contacts_usec := 0
	var grid_started := Time.get_ticks_usec()
	var candidates := _static_grid.query(component_bounds.grow(CONTACT_MARGIN))
	contacts_usec += Time.get_ticks_usec() - grid_started
	for neighbour in candidates:
		if neighbour == shape or neighbour.data == null:
			continue
		var neighbour_body := _body_of(neighbour)
		if neighbour_body == null or neighbour_body.state != VoxelBody3D.State.STATIC:
			continue
		var relative := shape.global_transform.affine_inverse() * neighbour.global_transform
		var touch_started := Time.get_ticks_usec()
		damage_component_contact_calls += 1
		var existing_indices: PackedInt32Array = component.get("indices", PackedInt32Array())
		var seed_index := int(component.get("seed_index", -1))
		# If the connection crossed the removed area, it must not survive because of import clearance.
		# Distant authored connections retain the original 12 cm margin.
		var contact_margin := COMPONENT_CONTACT_MARGIN \
			if _damage_cut_contact_pairs.has(_contact_pair_key(shape, neighbour)) \
			else CONTACT_MARGIN
		var touches: bool
		if existing_indices.is_empty() and seed_index >= 0:
			touches = shape.data.component_seed_touches(
				seed_index, neighbour.data, relative, shape.voxel_size,
				neighbour.voxel_size, contact_margin
			)
		else:
			_ensure_component_indices(shape, component)
			touches = shape.data.component_touches(
				component.indices, neighbour.data, relative, shape.voxel_size,
				neighbour.voxel_size, contact_margin
			)
		contacts_usec += Time.get_ticks_usec() - touch_started
		if not touches:
			continue
		# Even if the neighbor does not reach a foundation, this component is its physical support. It
		# must not be reduced to chips because it is small: it must first become a Body and absorb the
		# continuation (an 8-voxel post supporting an authored 50-voxel head).
		component["external_contact"] = true
		var neighbour_key := neighbour.get_instance_id()
		var route_cache_key := "%d:%d" % [shape.get_instance_id(), neighbour_key]
		var grounded: bool
		if grounded_by_shape.has(route_cache_key):
			grounded = bool(grounded_by_shape[route_cache_key])
		else:
			var route_started := Time.get_ticks_usec()
			var search := _reaches_foundation(neighbour, shape)
			damage_support_routes_ms += (Time.get_ticks_usec() - route_started) / 1000.0
			grounded = bool(search.grounded)
			# Contacts from several neighbors often converge on the same island. Cache the entire
			# traversal to avoid repeating the same exact BFS for every contact point on the building.
			for visited_key in (search.visited as Dictionary):
				if int(visited_key) != shape.get_instance_id():
					grounded_by_shape["%d:%d" % [shape.get_instance_id(), int(visited_key)]] = grounded
			grounded_by_shape[route_cache_key] = grounded
		if grounded:
			damage_support_contacts_ms += contacts_usec / 1000.0
			return true
	damage_support_contacts_ms += contacts_usec / 1000.0
	return false


static func _contact_pair_key(a: VoxelShape3D, b: VoxelShape3D) -> String:
	return "%d:%d" % [a.get_instance_id(), b.get_instance_id()]


func _drop_unsupported(shapes: Array[VoxelShape3D]) -> Array[VoxelBody3D]:
	var dropped: Array[VoxelBody3D] = []
	_support_searches = 0
	support_touch_calls = 0
	support_foundation_tests = 0
	support_foundation_ms = 0.0
	support_touch_ms = 0.0
	support_grid_ms = 0.0
	support_nodes = 0
	support_candidates = 0
	var support_started := Time.get_ticks_usec()
	var plan: Dictionary = _support_planner.plan_drop_chains(
		shapes, _structural_graph, _native_body_for_shape_id, _native_is_foundation_id,
		_native_static_contact_ids, _native_touches_foundation_directly
	)
	_support_searches = int(plan.searches)
	# Each loose island falls as a single body; the Nodes/Jolt commit stays here and runs once per
	# chain already planned in C++.
	for chain_variant: Variant in plan.chains:
		var chain: Array[VoxelBody3D] = []
		for body_variant: Variant in chain_variant as Array:
			var body := body_variant as VoxelBody3D
			if body != null:
				chain.append(body)
		var merged := _merge_dropped_chain(chain)
		if merged != null:
			dropped.append(merged)
	support_search_ms = (Time.get_ticks_usec() - support_started) / 1000.0
	support_dropped = dropped.size()
	return dropped




## Drop a chain of static Shapes as one dynamic body. The largest acts as the host, and the compound
## is rebuilt ONCE at the end. The old cutoff at 12 turned a long, 40-section pipe into 40
## RigidBody3Ds during the worst frame of the collapse.


func _merge_dropped_chain(chain: Array[VoxelBody3D]) -> VoxelBody3D:
	if chain.is_empty():
		return null
	var host := chain[0]
	for body in chain:
		if body.get_total_voxels() > host.get_total_voxels():
			host = body
	# The host is not complete yet. Building its compound here and rebuilding it after absorbing the
	# other Shapes doubled the peak cost in the collapse frame.
	host.make_dynamic(_box_allowance_for_new_body(), false)
	host.set_meta("damage_epoch", _active_damage_epoch)
	_absorb_bodies_into(host, chain)
	host.rebuild_dynamic_collision(_box_allowance_for_new_body())
	host.wake_for_interaction()
	return host


## Transfer authored bodies to the same rigid component without rebuilding collision for every
## Shape. This also preserves joints and cables when ownership changes.
func _absorb_bodies_into(host: VoxelBody3D, bodies: Array[VoxelBody3D]) -> void:
	for body in bodies:
		if body == host:
			continue
		for shape in body.get_shapes():
			_unregister_shape_spatial(shape)
			body.release_voxel_shape(shape)
			if host.state == VoxelBody3D.State.DYNAMIC:
				shape.calibrate_for_dynamic_structure()
			host.add_voxel_shape(shape, true, false)
			register_shape(shape)
		# Anything attached to the absorbed body—joints and cables—must be notified of its new owner.
		# This is the same "transfer" event already used when splitting a Body.
		body_split.emit(body, [host] as Array[VoxelBody3D])
		unregister_body(body)
		body.queue_free()


## Completes a separation across intact contacts far from the crater. Called only after a dynamic
## component has been created, so the full scan is paid once per detachment, not per surface impact.
func _absorb_static_continuations(
	created: Array[VoxelBody3D], source_body: VoxelBody3D
) -> Array[VoxelBody3D]:
	var claimed := {}
	var all_absorbed: Array[VoxelBody3D] = []
	for host in created:
		if not is_instance_valid(host) or host.state != VoxelBody3D.State.DYNAMIC:
			continue
		var seeds: Array[VoxelShape3D] = []
		for moving_shape in host.get_shapes():
			for neighbour in _static_contacts(moving_shape):
				# The internal flood fill has already determined that the source Body's remainder is
				# separate. The tolerant margin between Shapes must not weld across the newly removed voxel.
				if _body_of(neighbour) == source_body:
					continue
				if not claimed.has(neighbour.get_instance_id()):
					seeds.append(neighbour)
		var absorbed: Array[VoxelBody3D] = []
		for continuation_seed in seeds:
			if not is_instance_valid(continuation_seed) \
					or claimed.has(continuation_seed.get_instance_id()):
				continue
			var search := _reaches_foundation(continuation_seed)
			var visited := search.visited as Dictionary
			for key in visited:
				claimed[key] = true
			if bool(search.grounded):
				continue
			for key in visited:
				var continuation := visited[key] as VoxelShape3D
				var continuation_body := _body_of(continuation)
				if continuation_body != null \
						and continuation_body.state == VoxelBody3D.State.STATIC \
						and not absorbed.has(continuation_body):
					absorbed.append(continuation_body)
		if absorbed.is_empty():
			continue
		for absorbed_body in absorbed:
			if not all_absorbed.has(absorbed_body):
				all_absorbed.append(absorbed_body)
		_absorb_bodies_into(host, absorbed)
		host.rebuild_dynamic_collision(_box_allowance_for_new_body())
		host.wake_for_interaction()
	return all_absorbed


## The only commit point for a detachment. Both the immediate path and deferred queue arrive here
## with the original context, so no static continuation, signal, or impulse depends on how many
## fragments fit in the firing frame.
func _finalize_detached_bodies(
	source_body: VoxelBody3D, source_shape: VoxelShape3D,
	created: Array[VoxelBody3D], source_was_static: bool,
	impulse_center: Vector3, blast_radius: float, impulse_registry := {}, transaction := -1
) -> Array[VoxelBody3D]:
	var live: Array[VoxelBody3D] = []
	for fragment in created:
		if is_instance_valid(fragment) and fragment.state == VoxelBody3D.State.DYNAMIC:
			live.append(fragment)
	if live.is_empty():
		return live
	var transaction_id := int(transaction)
	if transaction_id < 0:
		transaction_id = _next_detachment_transaction
		_next_detachment_transaction += 1

	for fragment in live:
		if not fragment.has_meta("damage_epoch"):
			fragment.set_meta("damage_epoch", _active_damage_epoch)
		if source_was_static:
			fragment.begin_collision_handoff()
	var absorbed: Array[VoxelBody3D] = []
	if source_was_static and is_instance_valid(source_body):
		absorbed = _absorb_static_continuations(live, source_body)

	if is_instance_valid(source_body):
		body_split.emit(source_body, live)
	for fragment in live:
		impulse_registry[fragment.get_instance_id()] = true
		if source_was_static and fragment.collision_handoff_pending:
			_collision_handoffs.enqueue({
				"transaction": transaction_id,
				"fragment": fragment,
				"source_body": source_body,
				"source_shape": source_shape,
				"source_revision": source_shape.content_revision() \
					if is_instance_valid(source_shape) else 0,
				"absorbed": absorbed.duplicate(),
				"impulse_center": impulse_center,
				"impulse_energy": blast_radius * 5.0,
				"impulse_radius": blast_radius * 3.0,
				"ready_frame": -1,
			})
		else:
			fragment.wake_for_interaction()
			fragment.apply_explosion_impulse(
				impulse_center, blast_radius * 5.0, blast_radius * 3.0
			)
	if source_was_static and is_instance_valid(source_body):
		prioritize_collision_rebuild(source_body)
	return live

## Cuts a component from its Shape and converts it to a rigid body. This is the expensive part of
## destruction: the cut runs in C++, but creating the node, box compound, and Jolt body costs about
## 2.6 ms per piece. This cannot be optimized away, so it is spread across frames.
func _spawn_fragment(shape: VoxelShape3D, indices: PackedInt32Array,
		retained_anchors: PackedInt32Array, count: int, damage_epoch := -1) -> VoxelBody3D:
	if not is_instance_valid(shape) or shape.data == null:
		return null
	var source_owner := _body_of(shape)
	var structural_family: Variant = source_owner.get_meta(
		"structural_family", source_owner.get_instance_id()
	) if source_owner != null else shape.structural_lineage
	var detach_started := Time.get_ticks_usec()
	var detached := shape.detach_component_preserving(indices, retained_anchors)
	damage_detach_ms += (Time.get_ticks_usec() - detach_started) / 1000.0
	if detached == null:
		return null
	damage_fragments += 1
	var body_started := Time.get_ticks_usec()
	var fragment := VoxelBody3D.new()
	fragment.name = "VoxelFragment_%d" % Time.get_ticks_usec()
	# The detached Shape is dynamic from birth. Building a full static concave collision and
	# replacing it with a box compound one line later doubled split cost on large fragments.
	fragment.state = VoxelBody3D.State.DYNAMIC
	fragment.structural = count >= physics_budget.structural_voxel_threshold
	fragment.continuous_collision = true
	fragment.set_meta("structural_family", structural_family)
	fragment.set_meta("damage_epoch", _active_damage_epoch if damage_epoch < 0 else damage_epoch)
	detached.calibrate_for_dynamic_structure()
	add_child(fragment)
	fragment.add_voxel_shape(detached, true)
	damage_body_ms += (Time.get_ticks_usec() - body_started) / 1000.0
	fragment.last_interaction_msec = Time.get_ticks_msec()
	register_body(fragment)
	return fragment


## Pieces that could not be created during the shot's frame. Their indices may have become stale if
## the Shape took more damage in the meantime: `detach_component_preserving` ignores cells that are
## already air, so the piece may be smaller or not appear, but is never incorrect.
func _flush_pending_fragments() -> void:
	var made := 0
	while made < FRAGMENTS_PER_FRAME and not _pending_fragments.is_empty():
		var entry: Dictionary = _pending_fragments.pop_front()
		var shape := entry.shape as VoxelShape3D
		if not is_instance_valid(shape):
			continue
		made += 1
		var fragment := _spawn_fragment(
			shape, entry.indices, entry.retained, int(entry.count),
			int(entry.get("damage_epoch", _active_damage_epoch))
		)
		if fragment != null:
			var source_variant: Variant = entry.get("source_body")
			var source_body: VoxelBody3D = source_variant as VoxelBody3D \
				if is_instance_valid(source_variant) else _body_of(shape)
			_finalize_detached_bodies(
				source_body, shape, [fragment] as Array[VoxelBody3D],
				bool(entry.get("source_was_static", false)),
				entry.get("impulse_center", Vector3.ZERO) as Vector3,
				float(entry.get("blast_radius", 0.0)), {},
				int(entry.get("transaction", -1))
			)
		if shape.voxel_count() == 0:
			_unregister_shape_spatial(shape)


func _split_disconnected(
	_body: VoxelBody3D, shape: VoxelShape3D, impulse_center: Vector3, blast_radius: float
) -> Array[VoxelBody3D]:
	var connectivity_started := Time.get_ticks_usec()
	var root_started := Time.get_ticks_usec()
	var use_material_foundation := not shape.anchored and _is_foundation(shape)
	damage_external_support_ms += (Time.get_ticks_usec() - root_started) / 1000.0
	var fill_started := Time.get_ticks_usec()
	var components: Array = shape.classified_components_by_hardness(FOUNDATION_HARDNESS) \
		if use_material_foundation else shape.classified_components()
	_connectivity_verification_counter += 1
	if verify_connectivity_in_debug and _connectivity_verification_counter % 16 == 1:
		var reference_anchors := shape.data.get_indices_hardness_at_least(
			shape.palette.get_hardnesses(), FOUNDATION_HARDNESS
		) if use_material_foundation else (
			shape.anchor_indices if shape.anchored else PackedInt32Array()
		)
		var reference := shape.data.find_components_6_with_anchors_reference(reference_anchors)
		if _component_signatures(components) != _component_signatures(reference):
			push_error(
				"DESYNC connectivity: incremental index differs from flood fill in Shape #%d; "
				+ "using reference result" % shape.get_instance_id()
			)
			components = reference
			connectivity_fallbacks += 1
	var connectivity_metrics := shape.data.get_connectivity_metrics()
	connectivity_macros_visited += int(connectivity_metrics.get("macros_visited", 0))
	connectivity_voxels_materialized += int(
		connectivity_metrics.get("voxels_materialized", 0)
	)
	connectivity_fallbacks += int(connectivity_metrics.get("fallbacks", 0))
	damage_component_fill_ms += (Time.get_ticks_usec() - fill_started) / 1000.0
	if components.size() == 1 and not _has_structural_support(components[0]):
		var external_started := Time.get_ticks_usec()
		if _component_reaches_external_foundation(
			shape, components[0] as Dictionary, _damage_grounded_by_shape
		):
			(components[0] as Dictionary)["anchored"] = true
		damage_external_support_ms += (
			Time.get_ticks_usec() - external_started
		) / 1000.0
	elif components.size() > 1:
		var grounded_by_shape := _damage_grounded_by_shape
		for component: Dictionary in components:
			if _has_structural_support(component):
				continue
			var external_started := Time.get_ticks_usec()
			if _component_reaches_external_foundation(shape, component, grounded_by_shape):
				component["anchored"] = true
			damage_external_support_ms += (
				Time.get_ticks_usec() - external_started
			) / 1000.0
	damage_connectivity_ms += (Time.get_ticks_usec() - connectivity_started) / 1000.0
	var fragment_started := Time.get_ticks_usec()
	if components.is_empty():
		_unregister_shape_spatial(shape)
		damage_fragment_ms += (Time.get_ticks_usec() - fragment_started) / 1000.0
		return []
	# A building can remain one connected island after its last foundation voxel is removed.
	# Connectivity alone is therefore not enough to early-out: an anchored Shape whose sole
	# component no longer reaches a live anchor must detach in its entirety.
	if components.size() == 1:
		var only_component: Dictionary = components[0]
		if _has_structural_support(only_component):
			damage_fragment_ms += (Time.get_ticks_usec() - fragment_started) / 1000.0
			return []

	var created: Array[VoxelBody3D] = []
	var component_plan := _damage_planner.plan_detached_components(
		components, physics_budget.particle_voxel_limit
	)
	for decision: Dictionary in component_plan:
		var component: Dictionary = components[int(decision.component_index)]
		_ensure_component_indices(shape, component)
		var indices: PackedInt32Array = component.indices
		# Supported components have already been skipped. A component without a path detaches in full:
		# retaining voxels by percentage was what removed visually intact foundations.
		var retained_anchors := PackedInt32Array()
		var count := indices.size() - retained_anchors.size()
		if count <= 0:
			continue
		if bool(decision.particle_candidate) \
				and not bool(component.get("external_contact", false)):
			var discarded := shape.detach_component_preserving(indices, retained_anchors)
			if discarded != null:
				# The detached Shape is not in the SceneTree yet. Particles need its world transform to
				# sample centers, so preserve it explicitly.
				var discarded_transform := discarded.transform
				add_child(discarded)
				discarded.global_transform = discarded_transform
				_particle_pool.emit_component(
					discarded, discarded.data.get_live_indices(), impulse_center
				)
				discarded.queue_free()
			continue
		# The first pieces are created immediately; the rest wait their turn. Creating eight
		# RigidBody3Ds with box compounds in one frame took 37 ms; when spread out, the only visible
		# effect is that debris starts falling one frame later.
		if created.size() >= FRAGMENTS_PER_FRAME:
			_pending_fragments.append({
				"shape": shape, "indices": indices, "retained": retained_anchors,
				"count": count, "source_body": _body,
				"source_was_static": _body.state == VoxelBody3D.State.STATIC,
				"source_revision": shape.content_revision(),
				"dirty_min": component.get("minimum", Vector3i.ZERO),
				"dirty_max": component.get("maximum", Vector3i.ZERO),
				"impulse_center": impulse_center, "blast_radius": blast_radius,
				"damage_epoch": _active_damage_epoch,
				"transaction": _next_detachment_transaction,
			})
			continue
		var fragment := _spawn_fragment(shape, indices, retained_anchors, count)
		if fragment != null:
			created.append(fragment)
	if shape.voxel_count() == 0:
		_unregister_shape_spatial(shape)
	# Damage and each detach already rebuilt precisely the touched static macrocells through the
	# Shape signal; a full-body rebuild here would repeat that work for every split.
	damage_fragment_ms += (Time.get_ticks_usec() - fragment_started) / 1000.0
	return created


static func _has_structural_support(component: Dictionary) -> bool:
	return bool(component.get("anchored", false))


static func _component_signatures(components: Array) -> Array[String]:
	var signatures: Array[String] = []
	for component: Dictionary in components:
		signatures.append("%d:%d:%s:%s" % [
			int(component.get("voxel_count", 0)),
			int(component.get("anchor_count", 0)),
			str(component.get("minimum", Vector3i.ZERO)),
			str(component.get("maximum", Vector3i.ZERO)),
		])
	signatures.sort()
	return signatures


func _ensure_component_indices(shape: VoxelShape3D, component: Dictionary) -> void:
	var indices: PackedInt32Array = component.get("indices", PackedInt32Array())
	if not indices.is_empty() or int(component.get("voxel_count", 0)) <= 0:
		return
	var started := Time.get_ticks_usec()
	indices = shape.data.get_component_6(int(component.get("seed_index", -1)))
	component["indices"] = indices
	component["indices_materialized"] = true
	connectivity_voxels_materialized += indices.size()
	damage_component_fill_ms += (Time.get_ticks_usec() - started) / 1000.0


## A broken joint does not change any voxels: neither the damage planner nor connectivity checks
## revisit the piece it supported. Re-evaluate its support explicitly, or a disconnected fence
## remains floating.
func queue_support_check(body: VoxelBody3D) -> void:
	if body == null or not is_instance_valid(body) or body.state != VoxelBody3D.State.STATIC:
		return
	for shape in body.get_shapes():
		if shape.anchored:
			continue
		_pending_support_checks[shape.get_instance_id()] = {"shape": shape, "epoch": -1}


## A deferred support check waits only for fragments from its own or an earlier damage wave.
## Previously, it waited for the entire queue to empty; with sustained destruction and two
## fragments per frame, that never happened and nothing fell.
func _flush_ready_support_checks() -> void:
	if _pending_support_checks.is_empty():
		return
	var oldest_pending := 9223372036854775807
	for pending: Dictionary in _pending_fragments:
		oldest_pending = mini(oldest_pending, int(pending.get("damage_epoch", 0)))
	var ready: Array[VoxelShape3D] = []
	for key: int in _pending_support_checks.keys():
		var entry: Dictionary = _pending_support_checks[key]
		if int(entry.epoch) >= oldest_pending:
			continue
		_pending_support_checks.erase(key)
		var shape_variant: Variant = entry.shape
		if is_instance_valid(shape_variant):
			ready.append(shape_variant as VoxelShape3D)
	if not ready.is_empty():
		_drop_unsupported(ready)


func _process(delta: float) -> void:
	_process_physics_impacts()
	_flush_pending_fragments()
	_flush_ready_support_checks()
	_flush_one_collision_rebuild()
	_flush_collision_handoff_budget()
	_coalesce_ready_structural_bodies()
	_process_collision_handoffs()
	_baked_collision_priority_elapsed += delta
	if _baked_collision_priority_elapsed >= BAKED_COLLISION_PRIORITY_INTERVAL:
		_baked_collision_priority_elapsed = 0.0
		var camera := get_viewport().get_camera_3d()
		if camera != null:
			_prioritize_baked_collision(camera.global_position)
	_flush_baked_collision_budget()
	_body_cleanup_elapsed += delta
	if _body_cleanup_elapsed >= 2.0:
		_body_cleanup_elapsed = 0.0
		_cleanup_body_list()
	_maintenance_elapsed += delta
	var interval := ACTIVE_MAINTENANCE_INTERVAL if awake_bodies > 0 \
		else IDLE_MAINTENANCE_INTERVAL
	if _maintenance_elapsed < interval:
		return
	_maintenance_elapsed = 0.0
	_enforce_physics_budget(_burst_budget_pending)
	_burst_budget_pending = false
	_update_metrics()
	_refresh_awake_dynamic_grid()
	if _diagnostics != null:
		var coherence := get_physics_coherence_snapshot()
		_diagnostics.text = (
			"Voxel/Jolt  awake_bodies %d / %d\nactive_boxes %d / %d  total_boxes %d\n"
			+ "collision_rebuild_ms %.2f  pendientes %d  handoffs %d  retired_bodies %d\n"
			+ "coherence %s  shape %s  consumer %s\n"
			+ "impact_particles %d  active_particles %d"
		) % [
			awake_bodies, physics_budget.target_awake_bodies,
			awake_compound_boxes, physics_budget.max_active_boxes, compound_boxes,
			collision_rebuild_ms, _collision_rebuild_queue.size(), _collision_handoffs.size(),
			retired_bodies, coherence.status, str(coherence.get("shape", "-")),
			str(coherence.get("consumer", "-")),
			impact_particles, _particle_pool.get_active_count(),
		]


func _process_collision_handoffs() -> void:
	for shape_variant: Variant in _collision_handoffs.process(Engine.get_physics_frames()):
		if is_instance_valid(shape_variant):
			_cleanup_empty_source(shape_variant as VoxelShape3D)


func _flush_collision_handoff_budget() -> void:
	# `size/is_empty` count only fragments that are still frozen. A ticket that has already been
	# released may remain here only to prioritize rebuilding the source's physics.
	var started := Time.get_ticks_usec()
	while not _collision_rebuild_queue.is_empty():
		var selected := _collision_handoffs.select_pending_source() as VoxelBody3D
		var budget := COLLISION_HANDOFF_BUDGET_USEC if selected != null \
			else COLLISION_REBUILD_BUDGET_USEC
		if Time.get_ticks_usec() - started >= budget:
			return
		if selected != null:
			prioritize_collision_rebuild(selected)
		var before := _pending_collision_block_count()
		_flush_one_collision_rebuild()
		if _pending_collision_block_count() >= before:
			return


func _cleanup_empty_source(shape: VoxelShape3D) -> void:
	if shape == null or not is_instance_valid(shape) or shape.voxel_count() > 0:
		return
	var body := _body_of(shape)
	_unregister_shape_spatial(shape)
	_weld_baseline.erase(shape.get_instance_id())
	if body == null:
		shape.queue_free()
		return
	body.release_voxel_shape(shape)
	shape.queue_free()
	if body.get_shapes().is_empty():
		unregister_body(body)
		body.queue_free()


func get_physics_coherence_snapshot() -> Dictionary:
	# The registry updates revisions and pending state on writes. Previously, this query scanned each
	# Shape and then the entire baked queue for each one: O(shapes * queue) every 100 ms, while bodies
	# were awake. In Lee, that meant about 2,200 * 17,000 GDScript comparisons.
	var snapshot: Dictionary = _runtime_registry.get_coherence_snapshot()
	if snapshot.get("status") == "DESYNC":
		var shape := instance_from_id(int(snapshot.get("shape", 0))) as VoxelShape3D
		if shape != null and is_instance_valid(shape):
			snapshot["support_route"] = get_support_route_trace(shape)
			if snapshot.get("consumer") == "voxel_change_signal":
				_queue_desync_recovery(shape)
		return snapshot
	if snapshot.get("status") == "COHERENT" and (
			not _pending_fragments.is_empty() or not _collision_handoffs.is_empty()
	):
		return {
			"status": "PENDING", "shape": "-", "body": "-",
			"consumer": "fragment_queue",
		}
	return snapshot


func _queue_desync_recovery(shape: VoxelShape3D) -> void:
	var key := shape.get_instance_id()
	if _desync_recovery_queued.has(key):
		return
	_desync_recovery_queued[key] = true
	_recover_desynced_shape.call_deferred(shape, key)


func _recover_desynced_shape(shape: VoxelShape3D, key: int) -> void:
	_desync_recovery_queued.erase(key)
	if not is_instance_valid(shape) or shape.data == null \
			or shape.last_notified_revision == shape.content_revision():
		return
	shape.recover_unnotified_mutation()


## Calculated only when diagnostics are requested; it adds no cost to the normal support BFS.
func get_support_route_trace(shape: VoxelShape3D) -> Array[int]:
	if shape == null or not is_instance_valid(shape):
		return []
	var predecessor := {shape.get_instance_id(): 0}
	var frontier: Array[VoxelShape3D] = [shape]
	var target := 0
	while not frontier.is_empty():
		var current: VoxelShape3D = frontier.pop_front()
		if _is_foundation(current):
			target = current.get_instance_id()
			break
		for neighbour in _static_contacts(current):
			var key := neighbour.get_instance_id()
			if predecessor.has(key):
				continue
			predecessor[key] = current.get_instance_id()
			frontier.append(neighbour)
	if target == 0:
		return []
	var route: Array[int] = []
	while target != 0:
		route.push_front(target)
		target = int(predecessor.get(target, 0))
	return route


func _enforce_physics_budget(burst: bool) -> void:
	var now := Time.get_ticks_msec()
	var plan: Dictionary = _runtime_registry.plan_budget(
		physics_budget.target_awake_bodies, physics_budget.burst_awake_bodies,
		physics_budget.max_active_boxes, physics_budget.max_boxes_per_body, burst
	)
	# The census, aggregation, and sorting run in C++. GDScript only handles Node and Jolt mutations,
	# which must run on the main thread under Godot's contract.
	for body_id: int in plan.simplify_ids:
		var body := instance_from_id(body_id) as VoxelBody3D
		if body == null or not is_instance_valid(body):
			continue
		body.rebuild_dynamic_collision(int(plan.allowance))
		_sync_runtime_body(body)
	plan = _runtime_registry.plan_budget(
		physics_budget.target_awake_bodies, physics_budget.burst_awake_bodies,
		physics_budget.max_active_boxes, physics_budget.max_boxes_per_body, burst
	)
	if not bool(plan.over_budget):
		return
	for body_id: int in plan.retirement_order:
		if not bool(plan.over_budget):
			break
		var body := instance_from_id(body_id) as VoxelBody3D
		if body == null or not is_instance_valid(body) \
				or body.state != VoxelBody3D.State.DYNAMIC:
			continue
		# Replacing the PhysicsBody invalidates every Joint3D connected to it. Door and mechanism
		# bodies therefore remain dynamic (they can still sleep normally and cost almost nothing).
		if body.is_physics_persistent():
			continue
		var was_awake := body.is_awake()
		# Fragments below the structural threshold are cosmetic. If the burst already exceeds the
		# measured limit, keeping them as RigidBodies also degrades important pieces; move them
		# directly to the visual pool until budget recovers. Never freeze or simplify a structural
		# component to hide the cost.
		if not body.structural:
			_retire_debris_to_particles(body)
			plan = _runtime_registry.plan_budget(
				physics_budget.target_awake_bodies, physics_budget.burst_awake_bodies,
				physics_budget.max_active_boxes, physics_budget.max_boxes_per_body, burst
			)
			continue
		# A prop that has slept since import has never been interacted with and costs nothing; retiring
		# it to static would only kill it. Retire bodies that were active and have just stopped.
		if body.last_interaction_msec == 0 and not was_awake:
			continue
		var inactive_long_enough := not body.is_awake() and (
			now - body.last_interaction_msec >= int(physics_budget.retire_after_seconds * 1000.0)
		)
		if inactive_long_enough:
			body.retire_to_static()
			retired_bodies += 1
			_sync_runtime_body(body)
		elif _can_degrade_to_particles(body, now):
			_retire_debris_to_particles(body)
		plan = _runtime_registry.plan_budget(
			physics_budget.target_awake_bodies, physics_budget.burst_awake_bodies,
			physics_budget.max_active_boxes, physics_budget.max_boxes_per_body, burst
		)


## Box allowance for a newly created or newly dynamic body.
##
## Count only awake bodies, as `_enforce_physics_budget` does. Counting all bodies included 13,903
## boxes from Lee's 632 sleeping props against an 8,192 limit, always yielding a negative value.
## The allowance then became 1: a 24 m tower with 9,640 voxels became dynamic with ONE collision
## box. That caused the "does not fall" bug: the resulting block remained supported by the ground
## and was the only collidable part, so it neither fell nor could be hit properly.
func _box_allowance_for_new_body() -> int:
	var available := maxi(1, physics_budget.max_active_boxes - awake_compound_boxes)
	return mini(physics_budget.max_boxes_per_body, available)


func _can_degrade_to_particles(body: VoxelBody3D, now: int) -> bool:
	# Cosmetic debris may leave the rigid-body budget before the 1.5 s structural retirement
	# threshold; it has no gameplay role and only degrades when it is also far from the camera.
	var debris_delay_msec := int(minf(1.0, physics_budget.retire_after_seconds) * 1000.0)
	if body.structural or now - body.last_interaction_msec < debris_delay_msec:
		return false
	var camera := get_viewport().get_camera_3d()
	var shapes := body.get_shapes()
	if camera == null or shapes.is_empty():
		return false
	var center := shapes[0].world_bounds().get_center()
	return center.distance_to(camera.global_position) > 30.0


func _retire_debris_to_particles(body: VoxelBody3D) -> void:
	for shape in body.get_shapes():
		_particle_pool.emit_component(shape, shape.data.get_live_indices(), body.global_position)
	unregister_body(body)
	body.queue_free()
	retired_bodies += 1


func _update_metrics() -> void:
	_apply_runtime_metrics()
	# The self-healing invariant checks only IDs marked during writes. It no longer re-sums or counts
	# the voxels in every dynamic body during each maintenance pass.
	for body_id: int in _runtime_registry.get_zero_voxel_body_ids():
		var body := instance_from_id(body_id) as VoxelBody3D
		if body == null or not is_instance_valid(body):
			_runtime_registry.remove_body(body_id)
			continue
		unregister_body(body)
		body.queue_free()
	_apply_runtime_metrics()


func _apply_runtime_metrics() -> void:
	var metrics: Dictionary = _runtime_registry.get_metrics()
	awake_bodies = int(metrics.awake_bodies)
	compound_boxes = int(metrics.compound_boxes)
	awake_compound_boxes = int(metrics.awake_compound_boxes)


func _cleanup_body_list() -> void:
	var live: Array[VoxelBody3D] = []
	for body in _bodies:
		if is_instance_valid(body):
			live.append(body)
	_bodies = live


func _body_of(shape: VoxelShape3D) -> VoxelBody3D:
	var node: Node = shape.get_parent()
	while node != null:
		if node is VoxelBody3D:
			return node
		node = node.get_parent()
	return null


func _on_shape_changed(
	world_aabb: AABB, dirty_min: Vector3i, dirty_max: Vector3i, shape: VoxelShape3D
) -> void:
	_cancel_baked_collision(shape)
	_invalidate_contacts(shape)
	_sync_runtime_shape(shape)
	var body := _body_of(shape)
	if body != null:
		_sync_runtime_body(body)
	voxels_changed.emit(shape, world_aabb, dirty_min, dirty_max)


func _cancel_baked_collision(shape: VoxelShape3D) -> void:
	for index in range(_baked_collision_queue.size() - 1, -1, -1):
		var entry: Dictionary = _baked_collision_queue[index]
		if entry.shape != shape:
			continue
		_baked_collision_pending_blocks -= (entry.records as Array).size() - int(entry.cursor)
		_baked_collision_queue.remove_at(index)
	_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), false)
	_sync_runtime_shape(shape)


func _prioritize_baked_collision(center: Vector3) -> void:
	for entry: Dictionary in _baked_collision_queue:
		var shape := entry.shape as VoxelShape3D
		if not is_instance_valid(shape) or not shape.is_inside_tree():
			entry.distance_squared = INF
			continue
		var bounds := shape.world_bounds()
		var closest := center.clamp(bounds.position, bounds.end)
		entry.distance_squared = closest.distance_squared_to(center)
	_baked_collision_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.distance_squared) < float(b.distance_squared)
	)


func _flush_baked_collision_budget() -> void:
	var started := Time.get_ticks_usec()
	var radius_squared := BAKED_COLLISION_PREFETCH_RADIUS * BAKED_COLLISION_PREFETCH_RADIUS
	while not _baked_collision_queue.is_empty() \
			and Time.get_ticks_usec() - started < BAKED_COLLISION_FRAME_BUDGET_USEC:
		var entry: Dictionary = _baked_collision_queue[0]
		if float(entry.distance_squared) > radius_squared:
			return
		var body := entry.body as VoxelBody3D
		var shape := entry.shape as VoxelShape3D
		var records := entry.records as Array
		var cursor := int(entry.cursor)
		if not is_instance_valid(body) or not is_instance_valid(shape) or cursor >= records.size():
			if is_instance_valid(shape):
				_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), false)
			_baked_collision_pending_blocks -= maxi(0, records.size() - cursor)
			_baked_collision_queue.pop_front()
			continue
		body.import_baked_static_collision(shape, [records[cursor]])
		entry.cursor = cursor + 1
		_baked_collision_pending_blocks -= 1
		if int(entry.cursor) >= records.size():
			body.acknowledge_static_collision_revision(shape)
			_baked_collision_queue.pop_front()
			_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), false)
			_sync_runtime_body(body)


## Breaking voxels can remove a contact, so discard this Shape's cache entry and those of any Shapes
## that list it as a neighbor; otherwise a neighbor would still consider itself supported by it.
##
## Invalidate both directions. Checking only this Shape's list is insufficient because
## `_reaches_foundation` stops as soon as it finds a foundation and may never expand to the neighbor.
## A support may therefore have no entry of its own even though the object above it does. After a
## hole was blown in the support, the contact disappeared but the upper object still considered
## itself supported until another impact cleared the cache: "it won't fall until I shoot something
## else."
func _invalidate_contacts(shape: VoxelShape3D) -> void:
	var key := shape.get_instance_id()
	var cached := _contact_cache.get(key, {}) as Dictionary
	for neighbour_variant: Variant in cached.get("contacts", []):
		if is_instance_valid(neighbour_variant):
			_contact_cache.erase((neighbour_variant as VoxelShape3D).get_instance_id())
	for user_key in _contact_users.get(key, {}):
		_contact_cache.erase(user_key)
	_contact_users.erase(key)
	_contact_cache.erase(key)


func _on_body_state_changed(body: VoxelBody3D) -> void:
	for shape in body.get_shapes():
		_invalidate_contacts(shape)
		if body.state == VoxelBody3D.State.DYNAMIC:
			_cancel_baked_collision(shape)
			_static_grid.remove_id(shape.get_instance_id())
			_register_dynamic_shape(shape)
		else:
			_unregister_dynamic_shape(shape)
			_index_static_shape(shape)
	if body.state == VoxelBody3D.State.DYNAMIC:
		if not _dynamic_bodies.has(body):
			_dynamic_bodies.append(body)
	else:
		_dynamic_bodies.erase(body)
	_bind_runtime_sleep_signal(body)
	_sync_runtime_body(body)


func _on_runtime_state_changed(body: VoxelBody3D) -> void:
	_sync_runtime_body(body)


func _on_runtime_sleeping_changed(body: VoxelBody3D) -> void:
	_sync_runtime_body(body)


func _bind_runtime_sleep_signal(body: VoxelBody3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	var rigid := body.get_physics_body() as RigidBody3D
	if rigid == null:
		return
	var callback := _on_runtime_sleeping_changed.bind(body)
	if not rigid.sleeping_state_changed.is_connected(callback):
		rigid.sleeping_state_changed.connect(callback)


func _sync_runtime_body(body: VoxelBody3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	_runtime_registry.upsert_body(
		body.get_instance_id(), body.state == VoxelBody3D.State.DYNAMIC, body.is_awake(),
		body.structural, body.is_physics_persistent(), body.compound_boxes,
		body.get_total_voxels(), body.last_interaction_msec
	)
	for shape in body.get_shapes():
		_sync_runtime_shape(shape, body)
	_apply_runtime_metrics()


func _sync_runtime_shape(shape: VoxelShape3D, owner: VoxelBody3D = null) -> void:
	if shape == null or not is_instance_valid(shape) or shape.data == null:
		return
	var body := owner if owner != null else _body_of(shape)
	if body == null or not is_instance_valid(body):
		return
	var revision := shape.content_revision()
	_runtime_registry.upsert_shape(
		shape.get_instance_id(), shape.data, body.get_instance_id(), revision,
		shape.last_notified_revision,
		body.get_collision_revision(shape) if body.collision_enabled else revision,
		body.collision_enabled, body.has_pending_collision_rebuild(),
		body.collision_handoff_pending
	)


## Destruction broad phase. Previously, it queried the AABB tree, causing the performance spike:
## destruction marks the tree dirty, and the next query rebuilt it in full—measured at 54–59 ms per
## shot, more than everything else combined. A static Shape does not move, and its bounds do not
## shrink when voxels break, so rebuilding provided no benefit. Index the grid once.
##
## The grid queries by box, not sphere: this creates a wider band at the corners, which is fine
## because each Shape's `damage_sphere` already returns zero when the crater does not touch it.
func _query_shapes(center: Vector3, radius: float) -> Array[VoxelShape3D]:
	var result := _static_grid.query(AABB(center - Vector3.ONE * radius, Vector3.ONE * radius * 2.0))
	var low := _dynamic_grid_cell(center - Vector3.ONE * radius)
	var high := _dynamic_grid_cell(center + Vector3.ONE * radius)
	var visited := {}
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var bucket: Array = _dynamic_grid.get(Vector3i(x, y, z), [])
				for shape_variant: Variant in bucket:
					# The dynamic grid refreshes at 10 Hz; a destroyed Shape may remain in the bucket
					# for a few ticks. Validate the Variant before casting to avoid accessing a freed instance.
					if not is_instance_valid(shape_variant):
						continue
					var shape := shape_variant as VoxelShape3D
					if shape == null or not shape.is_inside_tree() \
							or shape.voxel_count() == 0:
						continue
					var key := shape.get_instance_id()
					if visited.has(key):
						continue
					visited[key] = true
					var bounds := shape.world_bounds()
					var closest := center.clamp(bounds.position, bounds.end)
					if closest.distance_squared_to(center) <= radius * radius:
						result.append(shape)
	return result


func _unregister_shape_spatial(shape: VoxelShape3D) -> void:
	_pending_support_checks.erase(shape.get_instance_id())
	_invalidate_contacts(shape)
	_static_grid.remove_id(shape.get_instance_id())
	_unregister_dynamic_shape(shape)
	_runtime_registry.remove_shape(shape.get_instance_id())


func _register_dynamic_shape(shape: VoxelShape3D) -> void:
	if not _dynamic_shapes.has(shape):
		_dynamic_shapes.append(shape)
	_update_dynamic_grid_shape(shape, true)


func _unregister_dynamic_shape(shape: VoxelShape3D) -> void:
	_dynamic_shapes.erase(shape)
	var key := shape.get_instance_id()
	var old_cells: Array = _dynamic_grid_cells.get(key, [])
	for cell: Vector3i in old_cells:
		var bucket: Array = _dynamic_grid.get(cell, [])
		bucket.erase(shape)
		if bucket.is_empty():
			_dynamic_grid.erase(cell)
	_dynamic_grid_cells.erase(key)
	_dynamic_grid_transforms.erase(key)


func _refresh_awake_dynamic_grid() -> void:
	# Imported props enter the grid when registered and sleep there. Only an awake body may have
	# moved, so a damage query does not scan all 628 sleeping Shapes.
	for body in get_awake_dynamic_bodies():
		for shape in body.get_shapes():
			_update_dynamic_grid_shape(shape)


func _update_dynamic_grid_shape(shape: VoxelShape3D, force := false) -> void:
	if not is_instance_valid(shape) or not shape.is_inside_tree() or shape.data == null:
		return
	var key := shape.get_instance_id()
	var current_transform := shape.global_transform
	if not force and _dynamic_grid_transforms.has(key) \
			and (_dynamic_grid_transforms[key] as Transform3D).is_equal_approx(current_transform):
		return
	var old_cells: Array = _dynamic_grid_cells.get(key, [])
	for cell: Vector3i in old_cells:
		var old_bucket: Array = _dynamic_grid.get(cell, [])
		old_bucket.erase(shape)
		if old_bucket.is_empty():
			_dynamic_grid.erase(cell)
	var bounds := shape.world_bounds()
	var low := _dynamic_grid_cell(bounds.position)
	var high := _dynamic_grid_cell(bounds.end - Vector3.ONE * 0.0001)
	var new_cells: Array[Vector3i] = []
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var cell := Vector3i(x, y, z)
				var bucket: Array = _dynamic_grid.get(cell, [])
				bucket.append(shape)
				_dynamic_grid[cell] = bucket
				new_cells.append(cell)
	_dynamic_grid_cells[key] = new_cells
	_dynamic_grid_transforms[key] = current_transform


static func _dynamic_grid_cell(position: Vector3) -> Vector3i:
	return Vector3i(
		floori(position.x / DYNAMIC_GRID_CELL_SIZE),
		floori(position.y / DYNAMIC_GRID_CELL_SIZE),
		floori(position.z / DYNAMIC_GRID_CELL_SIZE)
	)


func _flush_one_collision_rebuild() -> void:
	collision_rebuild_ms = 0.0
	while not _collision_rebuild_queue.is_empty():
		# As in `flush_one_static_collision_rebuild`, assigning a freed Object to a typed variable
		# fails before reaching the guard, so check the Variant first.
		var pending: Variant = _collision_rebuild_queue.pop_front()
		if not is_instance_valid(pending):
			continue
		var body := pending as VoxelBody3D
		_collision_rebuild_queued.erase(body.get_instance_id())
		collision_rebuild_ms = body.flush_one_collision_rebuild(
			_box_allowance_for_new_body() if body.state == VoxelBody3D.State.DYNAMIC \
			else physics_budget.max_boxes_per_body
		)
		if body.has_pending_collision_rebuild():
			queue_collision_rebuild(body)
		_sync_runtime_body(body)
		return


func _pending_collision_block_count() -> int:
	var count := 0
	for body in _collision_rebuild_queue:
		if is_instance_valid(body):
			count += body.pending_collision_rebuild_count()
	return count


func _create_diagnostics() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 90
	add_child(canvas)
	_diagnostics = Label.new()
	# Anchor at the bottom left and grow upward. With a fixed position at the top, we had to guess
	# how many lines the `main.gd` counter used; once it grew to three lines, they overlapped. From
	# the bottom, either can grow freely; leave 40 px for the help line.
	_diagnostics.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_diagnostics.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_diagnostics.offset_left = 12.0
	_diagnostics.offset_top = -40.0
	_diagnostics.offset_bottom = -40.0
	_diagnostics.add_theme_font_size_override("font_size", 13)
	_diagnostics.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.88))
	_diagnostics.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.95))
	_diagnostics.add_theme_constant_override("shadow_offset_x", 1)
	_diagnostics.add_theme_constant_override("shadow_offset_y", 1)
	_diagnostics.add_theme_constant_override("shadow_outline_size", 2)
	canvas.add_child(_diagnostics)
