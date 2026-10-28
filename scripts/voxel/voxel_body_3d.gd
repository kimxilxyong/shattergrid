class_name VoxelBody3D
extends Node3D
## Public Body in the World -> Body -> Shape model.

signal body_state_changed(body: VoxelBody3D)
signal runtime_state_changed(body: VoxelBody3D)

enum State { STATIC, DYNAMIC, RETIRED_STATIC }

const GROUP := "voxel_bodies"

var state := State.STATIC
var structural := true
## Bodies with live gameplay constraints (doors, mechanisms) must keep the same PhysicsBody RID.
## Retiring them to a replacement StaticBody3D would silently invalidate their joints.
## `physics_persistent` remains as a compatibility/manual pin. Runtime constraints use the counted
## holds below so one broken cable cannot unprotect a Body that still owns a live joint.
var physics_persistent := false
var physics_generation := 0
var collision_handoff_pending := false
## Only bodies created from static geometry need CCD. The 632 authored props that start asleep do
## not pay this cost; posts, beams, and long fragments still avoid passing through thin supports.
var continuous_collision := false
## Can be disabled to measure the engine without Jolt's cost: concave meshes account for 96% of a
## large map's loading time, so disabling them isolates the cost of everything else.
var collision_enabled := true
## A moving part mounted on a vehicle can delegate its impact profile to the chassis. This lets a
## turret break through a wall with the tank's force without damaging itself as a loose prop.
var vehicle_impact_owner: VoxelBody3D
var compound_boxes := 0
var collision_rebuild_ms := 0.0
var last_faces_ms := 0.0
var last_interaction_msec := 0
var _physics_body: PhysicsBody3D
var _collision_nodes: Array[CollisionShape3D] = []
var _macro_collisions := {}
## Static collision is divided into regional bodies. One StaticBody with thousands of Shapes has an
## AABB the size of the terrain, forcing the narrowphase to test them all against a falling tower;
## shards let the broadphase discard distant regions.
var _static_collision_shards := {}
var _pending_static_collisions: Array[Dictionary] = []
var _pending_static_collision_keys := {}
var _pending_dynamic_collision := false
var _constraint_holds := {}
var _handoff_collision_layer := 1
var _handoff_collision_mask := 1
var _handoff_impulses: Array[Dictionary] = []
var _vehicle_descriptor := {}
var _collision_installer := VoxelCollisionInstaller.new()
var _mass_properties := VoxelMassProperties.new()

const LARGE_BODY_CCD_BOX_THRESHOLD := 20
const LARGE_BODY_CCD_MASS_THRESHOLD := 2000.0
const LARGE_BODY_CCD_SPEED_THRESHOLD := 14.0


func _init() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	if _physics_body == null:
		_create_physics_body(state == State.DYNAMIC)


func add_voxel_shape(
	shape: VoxelShape3D, preserve_global := false, rebuild_collision := true
) -> void:
	if _physics_body == null:
		_create_physics_body(state == State.DYNAMIC)
	var desired_global := shape.global_transform if shape.is_inside_tree() else shape.transform
	var desired_local := shape.transform
	if shape.get_parent() != null:
		shape.reparent(_physics_body, preserve_global)
	else:
		_physics_body.add_child(shape)
		if preserve_global:
			shape.global_transform = desired_global
		else:
			shape.transform = desired_local
	shape.voxels_changed.connect(_on_shape_voxels_changed.bind(shape))
	if state == State.DYNAMIC and rebuild_collision:
		rebuild_dynamic_collision()
	elif state != State.DYNAMIC and rebuild_collision:
		rebuild_static_collision(shape)


## Removes a Shape from this Body without destroying it, so it can be transferred elsewhere. This
## is needed to split a Body whose Shapes are no longer touching.
func release_voxel_shape(shape: VoxelShape3D) -> void:
	var listener := _on_shape_voxels_changed.bind(shape)
	if shape.voxels_changed.is_connected(listener):
		shape.voxels_changed.disconnect(listener)
	if shape.get_parent() == _physics_body:
		_physics_body.remove_child(shape)


func get_shapes() -> Array[VoxelShape3D]:
	var result: Array[VoxelShape3D] = []
	if _physics_body == null:
		return result
	for child in _physics_body.get_children():
		if child is VoxelShape3D:
			result.append(child)
	return result


func make_dynamic(max_boxes := 128, rebuild_collision := true) -> void:
	if state == State.DYNAMIC:
		return
	continuous_collision = true
	for shape in get_shapes():
		shape.calibrate_for_dynamic_structure()
	state = State.DYNAMIC
	structural = get_total_voxels() >= 64
	_replace_physics_body(true)
	if rebuild_collision:
		rebuild_dynamic_collision(max_boxes)
	var voxel_world := _find_voxel_world()
	if voxel_world != null:
		begin_collision_handoff()
		voxel_world.queue_transition_collision_handoff(self)
	last_interaction_msec = Time.get_ticks_msec()
	body_state_changed.emit(self)
	runtime_state_changed.emit(self)


func retire_to_static() -> void:
	if state != State.DYNAMIC:
		return
	state = State.RETIRED_STATIC
	_replace_physics_body(false)
	for shape in get_shapes():
		rebuild_static_collision(shape)
	body_state_changed.emit(self)
	runtime_state_changed.emit(self)


func reactivate(max_boxes := 128) -> void:
	if state != State.RETIRED_STATIC:
		return
	make_dynamic(max_boxes)


func is_awake() -> bool:
	return state == State.DYNAMIC and _physics_body is RigidBody3D \
		and not (_physics_body as RigidBody3D).sleeping


## CCD on a compound Shape is expensive: continuously sweeping the tower's 29 boxes against
## regional concave meshes explains the bimodal 7/26 ms spikes. Posts, small parts, and fast bodies
## retain it; a large structure moving less than 23 cm per tick uses discrete collision.
func update_adaptive_ccd() -> void:
	var rigid := _physics_body as RigidBody3D
	if rigid == null:
		return
	var speed := rigid.linear_velocity.length()
	var needs_ccd := continuous_collision and (
		speed >= VoxelVehicle3D.CCD_MIN_SPEED if rigid is VoxelVehicle3D else (
			compound_boxes <= LARGE_BODY_CCD_BOX_THRESHOLD
			or rigid.mass <= LARGE_BODY_CCD_MASS_THRESHOLD
			or speed >= LARGE_BODY_CCD_SPEED_THRESHOLD
		)
	)
	if rigid.continuous_cd != needs_ccd:
		rigid.continuous_cd = needs_ccd


## Puts the body to sleep without removing it from the simulation. Teardown props start at rest, and
## sleeping them prevents Jolt from solving 628 bodies during the first seconds of play. They remain
## real dynamic bodies and wake automatically when touched, pulled by a joint, or pushed by a force.
## Previously, `freeze` was used instead; it does the opposite, turning the prop into dead static
## geometry that neither the player nor a nearby explosion could move.
func sleep() -> void:
	if not _physics_body is RigidBody3D:
		return
	# Jolt ignores `sleeping` until the body has taken a step in the space, so sleeping it in the
	# frame it is created does nothing; measured result: the prop still woke up and fell.
	if not is_inside_tree():
		(_physics_body as RigidBody3D).sleeping = true
		if _physics_body is VoxelVehicle3D:
			(_physics_body as VoxelVehicle3D).park_after_sleep()
		return
	var tree := get_tree()
	await tree.physics_frame
	await tree.physics_frame
	if is_instance_valid(self) and _physics_body is RigidBody3D:
		(_physics_body as RigidBody3D).sleeping = true
		if _physics_body is VoxelVehicle3D:
			(_physics_body as VoxelVehicle3D).park_after_sleep()
		# Jolt does not guarantee `sleeping_state_changed` when the property is set from a script.
		# Without this notification, the registry kept all 632 props marked awake, the budget tried
		# to simplify them, and that rebuild actually woke them a few frames later.
		runtime_state_changed.emit(self)


## Explicitly wake for interactions Jolt cannot anticipate: grabbing an object, opening a door, or
## reactivating a body retired to static state by the physics budget.
func wake_for_interaction() -> void:
	if state == State.RETIRED_STATIC:
		reactivate()
	if _physics_body is RigidBody3D:
		(_physics_body as RigidBody3D).sleeping = false
	last_interaction_msec = Time.get_ticks_msec()
	runtime_state_changed.emit(self)


func get_total_voxels() -> int:
	var total := 0
	for shape in get_shapes():
		total += shape.voxel_count()
	return total


func get_physics_body() -> PhysicsBody3D:
	return _physics_body


## Promotes the RigidBody authored by `<vehicle>` before building its compound. Shapes are preserved
## in world space while recentering the Body in the car's frame, so steering, suspension, and center
## of mass no longer depend on the map being far from the origin.
func configure_vehicle(descriptor: Dictionary) -> VoxelVehicle3D:
	if state != State.DYNAMIC or descriptor.is_empty():
		return null
	# An authored car reaches 20–50 m/s and must sweep against thin posts and walls. Parked cars sleep,
	# so enabling CCD here costs only the vehicles that are actually moving.
	continuous_collision = true
	_vehicle_descriptor = descriptor
	# If the compound is already built when this runs, replacing the Body discards it and leaves the
	# body without collision: the importer builds it afterward, but a body promoted at runtime does not.
	var had_collision := compound_boxes > 0
	_replace_physics_body(true)
	var vehicle := _physics_body as VoxelVehicle3D
	if vehicle != null:
		vehicle.configure(self, descriptor)
	if had_collision:
		rebuild_dynamic_collision()
	return vehicle


## A static Body distributes its collision across several regional StaticBody3Ds. Godot joints only
## know the root `JoltBody`, so consumers that need a consistent collision exception (such as doors
## while clearing their frame) must include those shards too.
func get_collision_objects() -> Array[CollisionObject3D]:
	var result: Array[CollisionObject3D] = []
	for child: Node in get_children():
		if child is CollisionObject3D and is_instance_valid(child):
			result.append(child as CollisionObject3D)
	return result


func acquire_physics_hold(owner: Variant) -> void:
	_constraint_holds[_hold_key(owner)] = true


func release_physics_hold(owner: Variant) -> void:
	_constraint_holds.erase(_hold_key(owner))


func is_physics_persistent() -> bool:
	return physics_persistent or not _constraint_holds.is_empty() or collision_handoff_pending


func physics_hold_count() -> int:
	return _constraint_holds.size() + (1 if physics_persistent else 0)


func has_physics_hold(owner: Variant) -> bool:
	return _constraint_holds.has(_hold_key(owner))


static func _hold_key(owner: Variant) -> String:
	if owner is Object:
		return "object:%d" % (owner as Object).get_instance_id()
	return str(owner)


func begin_collision_handoff() -> void:
	if not _physics_body is RigidBody3D or collision_handoff_pending:
		return
	var rigid := _physics_body as RigidBody3D
	_handoff_collision_layer = rigid.collision_layer
	_handoff_collision_mask = rigid.collision_mask
	rigid.collision_layer = 0
	rigid.collision_mask = 0
	rigid.freeze = true
	rigid.sleeping = false
	_handoff_impulses.clear()
	collision_handoff_pending = true


func complete_collision_handoff(
	impulse_center := Vector3.ZERO, impulse_energy := 0.0, impulse_radius := 0.0
) -> void:
	if not collision_handoff_pending:
		return
	collision_handoff_pending = false
	if not _physics_body is RigidBody3D:
		return
	var rigid := _physics_body as RigidBody3D
	rigid.collision_layer = _handoff_collision_layer
	rigid.collision_mask = _handoff_collision_mask
	rigid.freeze = false
	rigid.sleeping = false
	last_interaction_msec = Time.get_ticks_msec()
	if impulse_energy > 0.0 and impulse_radius > 0.0:
		apply_explosion_impulse(impulse_center, impulse_energy, impulse_radius)
	var queued_impulses := _handoff_impulses.duplicate()
	_handoff_impulses.clear()
	for queued: Dictionary in queued_impulses:
		apply_explosion_impulse(
			queued.center as Vector3, float(queued.energy), float(queued.radius)
		)
	runtime_state_changed.emit(self)


## Closes a ticket because this Body is about to disappear. Do not restore layers or unfreeze it:
## doing so during `unregister_body` would reactivate for one frame the ghost static collision that
## the handoff was isolating.
func cancel_collision_handoff() -> void:
	if not collision_handoff_pending:
		return
	collision_handoff_pending = false
	_handoff_impulses.clear()
	runtime_state_changed.emit(self)


func get_collision_revision(shape: VoxelShape3D) -> int:
	return shape.collision_revision if is_instance_valid(shape) else 0


func is_static_collision_revision_pending(shape: VoxelShape3D, target_revision: int) -> bool:
	if shape == null or not is_instance_valid(shape) or shape.data == null:
		return false
	if get_collision_revision(shape) >= target_revision:
		return false
	return _has_pending_static_collision_for_shape(shape)


## The handoff only needs to know whether any OLD collision remains enabled. The full rebuild may
## still be pending while new faces are baked; crater blocks are disabled when queued and Jolt
## removes them on the safe tick already required by the ticket.
func is_static_collision_handoff_pending(shape: VoxelShape3D, _target_revision: int) -> bool:
	if shape == null or not is_instance_valid(shape):
		return false
	var prefix := "%d:" % shape.get_instance_id()
	for key: String in _pending_static_collision_keys:
		if not key.begins_with(prefix):
			continue
		var collision := _macro_collisions.get(key) as CollisionShape3D
		if collision != null and is_instance_valid(collision) and not collision.disabled:
			return true
	return false


func acknowledge_static_collision_revision(shape: VoxelShape3D) -> void:
	if shape != null and shape.data != null:
		shape.collision_revision = shape.content_revision()


## RIDs that physically represent this Body. A dynamic Body has one; a static Body includes its
## regional shards so internal raycasts (for example, a cable attached to the post itself) can
## exclude all its collision, not just the logical node with no Shapes.
func get_collision_rids() -> Array[RID]:
	var result: Array[RID] = []
	if _physics_body != null and is_instance_valid(_physics_body):
		result.append(_physics_body.get_rid())
	for shard: StaticBody3D in _static_collision_shards.values():
		if is_instance_valid(shard):
			result.append(shard.get_rid())
	return result


func rebuild_all_collision(max_boxes := 128) -> void:
	if state == State.DYNAMIC:
		rebuild_dynamic_collision(max_boxes)
	else:
		_clear_collisions()
		for shape in get_shapes():
			rebuild_static_collision(shape)


## Number of 8-voxel macro-cells in each static collision mesh.
##
## Each block becomes a `ConcavePolygonShape3D` with its own BVH. Godot/Jolt recommend keeping the
## Shape count low; one per macro-cell created thousands of small BVHs and made Lee take 6–14 seconds
## to load. Adaptive blocks preserve exact 10 cm faces while grouping their spatial index into
## 0.8/1.6/3.2 m regions based on occupancy. The 3.2 m cap keeps each destructive rebuild under one
## frame without greatly increasing the total Shape count: Lee goes from 30,321 to 31,549 blocks
## (+4.1%) compared with the former 6.4 m cap.
const TARGET_STATIC_COLLISION_BLOCKS := 32
const MAX_STATIC_MACRO_BLOCK := 4
## Two blocks per axis: each regional StaticBody contains at most 2³ = 8 concave Shapes.
const STATIC_COLLISION_SHARD_SPAN := 2


static func collision_block_for(shape: VoxelShape3D) -> int:
	var occupied := shape.data.get_occupied_macros().size()
	var block := 1
	while block < MAX_STATIC_MACRO_BLOCK \
			and ceili(float(occupied) / float(block * block * block)) \
			> TARGET_STATIC_COLLISION_BLOCKS:
		block *= 2
	return block


## Static collision is always generated at voxel resolution. Previously, Shapes over 16 K voxels
## used blocks of 4; in a real map, that includes every ground Shape. `coarse_occupied` marks an
## entire block as full if it contains a single voxel, expanding the surface up to 30 cm above what
## is rendered and turning every uneven spot into a 40 cm step. While walking, this caused invisible
## walls and places where the player became stuck and could not descend.
##
## Coplanar faces are merged in C++ to preserve this precision without sending two triangles per
## voxel face to Jolt. Ground precision is non-negotiable.
static func static_collision_lod_for(_shape: VoxelShape3D) -> int:
	return 1


func rebuild_static_collision(
	shape: VoxelShape3D, dirty_min := Vector3i(-1, -1, -1), dirty_max := Vector3i(-1, -1, -1)
) -> void:
	if _physics_body == null or _physics_body is RigidBody3D or shape.data == null \
			or not collision_enabled:
		return
	var started := Time.get_ticks_usec()
	var block := collision_block_for(shape)
	var collision_lod := static_collision_lod_for(shape)
	var faces_usec := 0
	for macro: Vector3i in _static_collision_blocks(shape, dirty_min, dirty_max, block):
		var faces_started := Time.get_ticks_usec()
		_rebuild_static_collision_block(shape, macro, block, collision_lod)
		faces_usec += Time.get_ticks_usec() - faces_started
	compound_boxes = 0
	collision_rebuild_ms = (Time.get_ticks_usec() - started) / 1000.0
	# Split work between what can run on a worker thread (generating faces, pure C++) and what cannot
	# (creating the shape and passing it to Jolt, which requires the main thread).
	last_faces_ms = faces_usec / 1000.0
	shape.collision_revision = shape.content_revision()


## Destruction must not hand several new triangle BVHs to Jolt in the same frame. The visual atlas
## is updated immediately, while these collision blocks are deduplicated and consumed globally by
## VoxelWorld3D at one block per frame.
func queue_static_collision_rebuild(
	shape: VoxelShape3D, dirty_min: Vector3i, dirty_max: Vector3i
) -> void:
	if _physics_body == null or _physics_body is RigidBody3D or shape.data == null \
			or not collision_enabled or dirty_min.x < 0:
		return
	var block := collision_block_for(shape)
	var lod := static_collision_lod_for(shape)
	for macro: Vector3i in _static_collision_blocks(shape, dirty_min, dirty_max, block):
		var key := _static_collision_key(shape, macro)
		# Remove the old geometry first. A fragment then does not wait for hundreds of bakes before
		# falling and cannot collide with the voxels it just left behind.
		var stale := _macro_collisions.get(key) as CollisionShape3D
		if stale != null and is_instance_valid(stale):
			stale.disabled = true
		if _pending_static_collision_keys.has(key):
			_pending_static_collision_keys[key] = shape.content_revision()
			continue
		_pending_static_collision_keys[key] = shape.content_revision()
		_pending_static_collisions.append({
			"key": key, "shape": shape, "macro": macro, "block": block, "lod": lod,
		})
	var voxel_world := _find_voxel_world()
	if voxel_world != null and not _pending_static_collisions.is_empty():
		voxel_world.queue_collision_rebuild(self)


func has_pending_static_collision_rebuild() -> bool:
	return not _pending_static_collisions.is_empty()


func pending_static_collision_rebuild_count() -> int:
	return _pending_static_collisions.size()


func flush_one_static_collision_rebuild() -> float:
	while not _pending_static_collisions.is_empty():
		var pending: Dictionary = _pending_static_collisions.pop_front()
		var target_revision := int(_pending_static_collision_keys.get(pending.key, 0))
		_pending_static_collision_keys.erase(pending.key)
		# Check `is_instance_valid` first on purpose: assigning a freed Object to a typed variable
		# fails immediately, before reaching the guard.
		var shape: VoxelShape3D = pending.shape if is_instance_valid(pending.shape) else null
		if shape == null or shape.data == null or state == State.DYNAMIC:
			continue
		var started := Time.get_ticks_usec()
		var faces_started := Time.get_ticks_usec()
		_rebuild_static_collision_block(
			shape, pending.macro, int(pending.block), int(pending.lod)
		)
		last_faces_ms = (Time.get_ticks_usec() - faces_started) / 1000.0
		collision_rebuild_ms = (Time.get_ticks_usec() - started) / 1000.0
		if not _has_pending_static_collision_for_shape(shape):
			shape.collision_revision = maxi(target_revision, shape.content_revision())
		return collision_rebuild_ms
	return 0.0


func _has_pending_static_collision_for_shape(shape: VoxelShape3D) -> bool:
	var prefix := "%d:" % shape.get_instance_id()
	for key: String in _pending_static_collision_keys:
		if key.begins_with(prefix):
			return true
	return false


## Damage to multiple voxels/Shapes in one Body can emit many signals per frame. Rebuild the dynamic
## compound only once from the global budget, just like static collision by macro-cell.
func queue_dynamic_collision_rebuild() -> void:
	if _pending_dynamic_collision:
		return
	_pending_dynamic_collision = true
	var voxel_world := _find_voxel_world()
	if voxel_world != null:
		voxel_world.queue_collision_rebuild(self)
	else:
		flush_one_collision_rebuild.call_deferred()


func has_pending_collision_rebuild() -> bool:
	return _pending_dynamic_collision or has_pending_static_collision_rebuild()


func pending_collision_rebuild_count() -> int:
	return (1 if _pending_dynamic_collision else 0) + pending_static_collision_rebuild_count()


func flush_one_collision_rebuild(max_boxes := 128) -> float:
	if _pending_dynamic_collision:
		_pending_dynamic_collision = false
		rebuild_dynamic_collision(max_boxes)
		return collision_rebuild_ms
	return flush_one_static_collision_rebuild()


func _static_collision_blocks(
	shape: VoxelShape3D, dirty_min: Vector3i, dirty_max: Vector3i, block: int
) -> Array[Vector3i]:
	var blocks := {}
	if dirty_min.x >= 0:
		var span := 8 * block
		var low := dirty_min / span
		var high := dirty_max / span
		for z in range(low.z, high.z + 1):
			for y in range(low.y, high.y + 1):
				for x in range(low.x, high.x + 1):
					blocks[Vector3i(x, y, z)] = true
	else:
		# A full rebuild only needs macro-cells that contain something. Scanning the entire volume
		# meant about 1.9 M empty calls per imported map.
		var dimensions := shape.data.get_macro_dimensions()
		var plane := dimensions.x * dimensions.y
		for macro_index in shape.data.get_occupied_macros():
			blocks[Vector3i(
				(macro_index % dimensions.x) / block,
				((macro_index / dimensions.x) % dimensions.y) / block,
				(macro_index / plane) / block
			)] = true
	var result: Array[Vector3i] = []
	result.assign(blocks.keys())
	return result


func _rebuild_static_collision_block(
	shape: VoxelShape3D, macro: Vector3i, block: int, lod: int
) -> void:
	# The mask comes from the converted Teardown palette and excludes non-physical decoration and
	# foliage: see `TeardownPalette.WALK_THROUGH`. Third-party `.vox` files do not include it and
	# entero.
	var faces := shape.data.build_macro_faces(
		macro, shape.voxel_size, block, lod, TeardownPalette.mask_for(shape)
	)
	_install_static_collision_faces(shape, macro, faces)


## Installs a pre-meshed block. Normal imports and the compiled cache converge here, producing
## exactly the same shards, keys, and Jolt resources. When a macro-cell is destroyed,
## `_rebuild_static_collision_block` regenerates only that block from live voxels.
func _install_static_collision_faces(
	shape: VoxelShape3D, macro: Vector3i, faces: PackedVector3Array
) -> void:
	var key := _static_collision_key(shape, macro)
	var collision: CollisionShape3D = _macro_collisions.get(key)
	if faces.is_empty():
		if collision != null:
			var shard := collision.get_parent() as StaticBody3D
			var shard_key := String(collision.get_meta("static_shard_key", ""))
			_collision_nodes.erase(collision)
			collision.queue_free()
			_macro_collisions.erase(key)
			# The child remains counted until `queue_free` runs; one means this region is empty and its
			# Body can also leave the broadphase.
			if shard != null and shard != _physics_body and shard.get_child_count() <= 1:
				_static_collision_shards.erase(shard_key)
				shard.queue_free()
		return
	var shard_key := _static_collision_shard_key(shape, macro)
	var parent: Node = collision.get_parent() if collision != null \
		else _static_collision_shard(shape, macro)
	var installed := _collision_installer.install_concave(
		parent, collision, shape, faces, shard_key, macro
	)
	if collision == null and installed != null:
		collision = installed
		_collision_nodes.append(collision)
		_macro_collisions[key] = collision
	if collision != null and is_instance_valid(collision):
		collision.disabled = false


## Extracts the initially merged faces for offline map compilation. Do not save RIDs or PhysicsServer
## nodes: those identifiers are valid only during this process. Persist the pure geometry input so
## they can be rebuilt without repeating `build_macro_faces`.
func export_baked_static_collision(shape: VoxelShape3D) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var prefix := "%d:" % shape.get_instance_id()
	for key: String in _macro_collisions:
		if not key.begins_with(prefix):
			continue
		var collision := _macro_collisions[key] as CollisionShape3D
		if collision == null or not collision.shape is ConcavePolygonShape3D:
			continue
		result.append({
			"macro": collision.get_meta("static_macro", Vector3i.ZERO),
			"faces": (collision.shape as ConcavePolygonShape3D).get_faces(),
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left: Vector3i = a.macro
		var right: Vector3i = b.macro
		return left.z < right.z or (left.z == right.z and (
			left.y < right.y or (left.y == right.y and left.x < right.x)
		))
	)
	return result


## Restores the output of `export_baked_static_collision`. Shapes remain destructible: the cache
## replaces only the initial build and does not participate in later updates.
func import_baked_static_collision(
	shape: VoxelShape3D, records: Array
) -> void:
	if state == State.DYNAMIC or not collision_enabled:
		return
	last_faces_ms = 0.0
	for record: Dictionary in records:
		var faces: PackedVector3Array = record.get("faces", PackedVector3Array())
		if faces.is_empty():
			continue
		_install_static_collision_faces(
			shape, record.get("macro", Vector3i.ZERO) as Vector3i, faces
		)


static func _static_collision_key(shape: VoxelShape3D, macro: Vector3i) -> String:
	return "%d:%d:%d:%d" % [shape.get_instance_id(), macro.x, macro.y, macro.z]


static func _static_collision_shard_key(shape: VoxelShape3D, macro: Vector3i) -> String:
	var region := Vector3i(
		macro.x / STATIC_COLLISION_SHARD_SPAN,
		macro.y / STATIC_COLLISION_SHARD_SPAN,
		macro.z / STATIC_COLLISION_SHARD_SPAN
	)
	return "%d:%d:%d:%d" % [shape.get_instance_id(), region.x, region.y, region.z]


func _static_collision_shard(shape: VoxelShape3D, macro: Vector3i) -> StaticBody3D:
	var key := _static_collision_shard_key(shape, macro)
	var existing := _static_collision_shards.get(key) as StaticBody3D
	if existing != null and is_instance_valid(existing):
		return existing
	var shard := StaticBody3D.new()
	shard.name = "StaticCollisionRegion"
	if _physics_body is CollisionObject3D:
		shard.collision_layer = (_physics_body as CollisionObject3D).collision_layer
		shard.collision_mask = (_physics_body as CollisionObject3D).collision_mask
	add_child(shard)
	_static_collision_shards[key] = shard
	return shard


func _find_voxel_world() -> VoxelWorld3D:
	var node: Node = get_parent()
	while node != null:
		if node is VoxelWorld3D:
			return node
		node = node.get_parent()
	return null


func rebuild_dynamic_collision(max_boxes := 128) -> void:
	if not _physics_body is RigidBody3D or not collision_enabled:
		return
	if _physics_body is VoxelVehicle3D:
		max_boxes = mini(max_boxes, VoxelVehicle3D.COLLISION_BOX_BUDGET)
	_pending_dynamic_collision = false
	var started := Time.get_ticks_usec()
	_clear_collisions()
	var shapes := get_shapes()
	var installed: Dictionary = _collision_installer.install_dynamic_boxes(
		_physics_body, shapes, max_boxes
	)
	for collision_variant: Variant in installed.nodes:
		var collision := collision_variant as CollisionShape3D
		if collision != null:
			_collision_nodes.append(collision)
	compound_boxes = int(installed.count)
	_apply_mass_properties()
	# Seal every Shape in the Body, not only those the installer added: a Shape truncated by the box
	# budget stayed at revision 0, and the registry reported it as desynchronized forever.
	for shape in shapes:
		shape.collision_revision = shape.content_revision()
	collision_rebuild_ms = (Time.get_ticks_usec() - started) / 1000.0
	runtime_state_changed.emit(self)


## Recalculates mass, center, and inertia without touching the compound. Intentionally public for
## semantic import adjustments—for example, a voxel door represents a hollow panel, not a solid
## block—that change neither cells nor collision boxes.
func refresh_mass_properties() -> void:
	_apply_mass_properties()


func apply_explosion_impulse(center: Vector3, energy: float, radius: float) -> void:
	if not _physics_body is RigidBody3D:
		return
	if collision_handoff_pending:
		_handoff_impulses.append({"center": center, "energy": energy, "radius": radius})
		return
	var rigid := _physics_body as RigidBody3D
	# Fragment Bodies keep Shapes in world-preserving local transforms, so the RigidBody origin can
	# remain at the VoxelWorld origin. Use its actual center of mass or distant buildings never
	# receive the impulse that should make a newly fractured support topple.
	var world_center_of_mass := rigid.to_global(rigid.center_of_mass)
	var offset := world_center_of_mass - center
	var distance := offset.length()
	var structural_detachment := structural and continuous_collision
	var surface_distance := INF
	if structural_detachment:
		for shape in get_shapes():
			var bounds := shape.world_bounds()
			surface_distance = minf(
				surface_distance,
				center.distance_to(center.clamp(bounds.position, bounds.end))
			)
	var effective_distance := minf(distance, surface_distance) \
		if structural_detachment else distance
	if effective_distance >= radius or distance < 0.001:
		return
	var falloff := 1.0 - effective_distance / radius
	rigid.apply_central_impulse(offset / distance * energy * rigid.mass * falloff * 0.12)
	if structural_detachment:
		# A perfectly vertical post can land on its stump again if it receives only central force.
		# A deterministic horizontal component represents the actual asymmetry of the break and
		# provides enough torque to topple, without depending on Body order or random noise.
		var horizontal := Vector3(offset.x, 0.0, offset.z)
		if horizontal.length_squared() < 0.0001:
			var angle := float(get_instance_id() % 6283) * 0.001
			horizontal = Vector3(cos(angle), 0.0, sin(angle))
		var tip_axis := Vector3.UP.cross(horizontal.normalized()).normalized()
		rigid.apply_torque_impulse(tip_axis * energy * rigid.mass * falloff * 0.25)
	rigid.sleeping = false
	last_interaction_msec = Time.get_ticks_msec()
	runtime_state_changed.emit(self)


## The RigidBody only captures solver data. Voxel mutation is deferred to the World, which removes
## duplicate contacts and limits how many physical craters can be processed per frame.
func report_physics_impact(
	collider: Object, point: Vector3, impulse: float, relative_speed: float
) -> void:
	if state != State.DYNAMIC or collision_handoff_pending or impulse <= 0.0:
		return
	var voxel_world := _find_voxel_world()
	if voxel_world != null:
		voxel_world.queue_physics_impact(self, collider, point, impulse, relative_speed)


func _create_physics_body(dynamic: bool) -> void:
	if dynamic:
		if not _vehicle_descriptor.is_empty():
			var vehicle := VoxelVehicle3D.new()
			vehicle.voxel_owner = self
			vehicle.continuous_cd = continuous_collision
			_physics_body = vehicle
		else:
			var impact_body := VoxelImpactRigidBody3D.new()
			impact_body.voxel_owner = self
			impact_body.continuous_cd = continuous_collision
			# Eight contacts are enough to cover one full compound face without the cost of reporting
			# the dozens of points generated when a tower lands.
			impact_body.contact_monitor = true
			impact_body.max_contacts_reported = 8
			_physics_body = impact_body
	else:
		_physics_body = StaticBody3D.new()
	_physics_body.name = "JoltBody"
	add_child(_physics_body)
	physics_generation += 1


func _replace_physics_body(dynamic: bool) -> void:
	var shapes := get_shapes()
	for shape in shapes:
		shape.reparent(self, true)
	_clear_collisions()
	# The collision that sealed these revisions just left with the previous body.
	for shape in shapes:
		shape.collision_revision = 0
	if _physics_body != null:
		_physics_body.queue_free()
	_create_physics_body(dynamic)
	if dynamic and not _vehicle_descriptor.is_empty():
		var vehicle_transform: Transform3D = _vehicle_descriptor.get(
			"physics_transform", Transform3D.IDENTITY
		)
		_physics_body.global_transform = vehicle_transform
	for shape in shapes:
		shape.reparent(_physics_body, true)


func _clear_collisions() -> void:
	_collision_installer.queue_free_nodes(_collision_nodes)
	for shard: StaticBody3D in _static_collision_shards.values():
		if is_instance_valid(shard):
			shard.queue_free()
	_collision_nodes.clear()
	_macro_collisions.clear()
	_static_collision_shards.clear()
	_pending_static_collisions.clear()
	_pending_static_collision_keys.clear()
	compound_boxes = 0


func _apply_mass_properties() -> void:
	if not _physics_body is RigidBody3D:
		return
	_mass_properties.apply(
		_physics_body as RigidBody3D, get_shapes(), _physics_body is VoxelVehicle3D
	)


## Posts have very low inertia around their long axis and high inertia around the other two. This
## anisotropy identifies them without map tags and damps rope/collision pendulum motion without
## damping boxes, vehicles, or compact rubble.
static func structural_damping_for_inertia(body_inertia: Vector3) -> Vector2:
	return VoxelMassProperties.damping_for_inertia(body_inertia)


func _on_shape_voxels_changed(
	_world_aabb: AABB, dirty_min: Vector3i, dirty_max: Vector3i, shape: VoxelShape3D
) -> void:
	last_interaction_msec = Time.get_ticks_msec()
	# Removing voxels from a prop wakes it: losing mass changes its equilibrium.
	if state == State.DYNAMIC:
		(_physics_body as RigidBody3D).sleeping = false
		queue_dynamic_collision_rebuild()
	else:
		queue_static_collision_rebuild(shape, dirty_min, dirty_max)
	runtime_state_changed.emit(self)
