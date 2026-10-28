class_name VoxelDoor3D
extends Node3D
## Runtime representation of a Teardown door.
##
## Teardown authors a door as one dynamic Body plus joints placed on its Shapes. Two vertically
## aligned ball joints form a hinge axis; some assets use explicit hinge joints instead. A third
## joint on the opposite edge is the latch. This node keeps those authored connections breakable
## and exposes a physical grab interaction without teleporting the RigidBody.

signal latch_changed(door: VoxelDoor3D, latched: bool)
signal connection_broken(door: VoxelDoor3D, kind: String, position: Vector3)

const BODY_META := &"voxel_door"
const DEFAULT_JOINT_SIZE := 0.16
## A door's voxel geometry describes its visual envelope, but a real door is a hollow panel. The
## importer already applies the prop volume fraction; this area-based limit is a second safeguard
## for authored doors with exceptional `density`. It is stored on the Shapes through
## `physical_fill_scale`, so it persists after damage and ownership changes.
const MASS_PER_SQUARE_METER := 28.0
const MIN_DOOR_MASS := 28.0
const MAX_DOOR_MASS := 160.0
const FRAME_CLEARANCE_ANGLE := 12.0

var voxel_body: VoxelBody3D
var bounds := AABB()
var hinge_records: Array[Dictionary] = []
var latch_record: Dictionary = {}
var held := false

var _rigid: RigidBody3D
var _latch_intact := false
var _latched := false
var _physics_hold_key := ""
var _joints: VoxelJoints
var _fully_released := false
var _frame_clearance_active := false
var _clearance_hinge_axis := Vector3.UP
var _clearance_hinge_center := Vector3.ZERO
var _clearance_initial_radial := Vector3.ZERO
var _clearance_local_point := Vector3.ZERO
var _frame_collision_exceptions := {}


func configure(
	world: VoxelWorld3D, body: VoxelBody3D, hinges: Array[Dictionary], latch: Dictionary,
	door_bounds: AABB
) -> void:
	voxel_body = body
	bounds = door_bounds
	hinge_records.assign(hinges)
	latch_record = latch
	_rigid = body.get_physics_body() as RigidBody3D
	if _rigid == null:
		push_error("VoxelDoor3D requires a dynamic VoxelBody3D")
		return
	_cap_hollow_leaf_mass()
	_physics_hold_key = "door:%d" % get_instance_id()
	_joints = world.get_node_or_null("TeardownJoints") as VoxelJoints
	if _joints != null and not _joints.record_broken.is_connected(_on_joint_record_broken):
		_joints.record_broken.connect(_on_joint_record_broken)
	body.structural = true
	_rigid.set_meta(BODY_META, self)
	_latch_intact = not latch_record.is_empty() and _record_joint_is_live(latch_record)
	_latched = _latch_intact
	_refresh_physics_hold()
	if not world.voxel_impact.is_connected(_on_voxel_impact):
		world.voxel_impact.connect(_on_voxel_impact)
	world.body_split.connect(_on_body_split)
	world.body_unregistered.connect(_on_body_unregistered)
	body.body_state_changed.connect(_on_body_state_changed)
	set_physics_process(false)


func _cap_hollow_leaf_mass() -> void:
	if _rigid == null or _rigid.mass <= 0.0:
		return
	var frontal_area := maxf(bounds.size.x, bounds.size.z) * bounds.size.y
	var target_mass := clampf(
		frontal_area * MASS_PER_SQUARE_METER, MIN_DOOR_MASS, MAX_DOOR_MASS
	)
	if _rigid.mass <= target_mass:
		return
	var density_factor := target_mass / _rigid.mass
	for shape: VoxelShape3D in voxel_body.get_shapes():
		shape.physical_fill_scale *= density_factor
	voxel_body.refresh_mass_properties()


func is_latched() -> bool:
	return _latched and _latch_intact and _record_joint_is_live(latch_record)


func has_live_hinges() -> bool:
	return live_hinge_count() > 0


func live_hinge_count() -> int:
	var count := 0
	for record: Dictionary in hinge_records:
		count += 1 if _record_joint_is_live(record) else 0
	return count


func get_rigid_body() -> RigidBody3D:
	return _rigid


## Grabbing never unlocks a closed latch. The player can pull and rattle the door, but the authored
## third joint remains in place until destruction removes the material around that connection.
func begin_grab() -> void:
	if _rigid == null or not is_instance_valid(_rigid):
		return
	held = true
	_refresh_physics_hold()
	voxel_body.wake_for_interaction()
	if not is_latched() and not _fully_released and _frame_clearance_angle() \
			< deg_to_rad(FRAME_CLEARANCE_ANGLE):
		_begin_frame_clearance()


func end_grab() -> void:
	held = false
	_refresh_physics_hold()


func _destroy_latch() -> void:
	if not _latch_intact:
		return
	_break_record(latch_record)
	_mark_latch_broken()


func _mark_latch_broken() -> void:
	if not _latch_intact:
		return
	_latched = false
	_latch_intact = false
	if voxel_body != null and is_instance_valid(voxel_body):
		# Removing a constraint does not guarantee that Jolt will wake an already sleeping body.
		# Without this wake, the panel stayed exactly in its wall pose after the latch was destroyed.
		voxel_body.wake_for_interaction()
	_begin_frame_clearance()
	latch_changed.emit(self, false)
	connection_broken.emit(self, "latch", _record_position(latch_record))
	_refresh_physics_hold()


func _on_voxel_impact(center: Vector3, _removed_voxels: int, blast_radius: float) -> void:
	if voxel_body == null or not is_instance_valid(voxel_body):
		return
	if _latch_intact and _impact_reaches_record(center, blast_radius, latch_record) \
			and not _connection_has_material(latch_record):
		_destroy_latch()
	for index in hinge_records.size():
		var record: Dictionary = hinge_records[index]
		if not _record_joint_is_live(record):
			continue
		if not _impact_reaches_record(center, blast_radius, record):
			continue
		if _connection_has_material(record):
			continue
		_break_hinge(record)
	if not has_live_hinges() and not _record_joint_is_live(latch_record):
		voxel_body.wake_for_interaction()
		_mark_fully_released(center)


## Also handles breaks from separation/force, where there is no `voxel_impact`. It is event-driven:
## a stationary door performs no per-frame polling.
func _on_joint_record_broken(record: Dictionary) -> void:
	if record == latch_record:
		_mark_latch_broken()
	elif hinge_records.has(record):
		_report_broken_hinge(record)
	else:
		return
	if not has_live_hinges() and not _record_joint_is_live(latch_record):
		_mark_fully_released(_record_position(record))


func _break_hinge(record: Dictionary) -> void:
	_break_record(record)
	_report_broken_hinge(record)


func _report_broken_hinge(record: Dictionary) -> void:
	if bool(record.get("door_reported", false)):
		return
	record["door_reported"] = true
	if voxel_body != null and is_instance_valid(voxel_body):
		voxel_body.wake_for_interaction()
	connection_broken.emit(self, "hinge", _record_position(record))
	_refresh_physics_hold()


func _mark_fully_released(impact_center: Vector3) -> void:
	if _fully_released:
		return
	_fully_released = true
	_end_frame_clearance()
	_nudge_after_joint_removal(impact_center)


## While the latch is live, Joint3D excludes only the root static `JoltBody`. Actual map collision
## is on sibling shards, so the panel starts touching four frame colliders and Jolt cancels all
## opening torque. When the latch breaks, exclude only the Bodies connected to that door; after it
## passes 12 degrees there is enough clearance, so restore those collisions and let the wall stop
## it again. Only a door in this transition processes physics.
func _begin_frame_clearance() -> void:
	if _fully_released or _rigid == null or not is_instance_valid(_rigid) \
			or hinge_records.size() < 2:
		return
	var first := _record_position(hinge_records.front())
	var last := _record_position(hinge_records.back())
	var axis := last - first
	if axis.length_squared() < 0.0001:
		return
	_clearance_hinge_axis = axis.normalized()
	_clearance_hinge_center = (first + last) * 0.5
	var reference_point := _record_position(latch_record) \
		if not latch_record.is_empty() else bounds.get_center()
	_clearance_local_point = _rigid.to_local(reference_point)
	_clearance_initial_radial = reference_point - _clearance_hinge_center
	_clearance_initial_radial -= _clearance_hinge_axis * _clearance_initial_radial.dot(
		_clearance_hinge_axis
	)
	if _clearance_initial_radial.length_squared() < 0.0001:
		return
	_frame_clearance_active = true
	_sync_frame_collision_exceptions()
	set_physics_process(true)


func _physics_process(_delta: float) -> void:
	if not _frame_clearance_active:
		set_physics_process(false)
		return
	_sync_frame_collision_exceptions()
	if _frame_clearance_angle() >= deg_to_rad(FRAME_CLEARANCE_ANGLE):
		_end_frame_clearance()
	elif not held and _rigid != null and _rigid.sleeping:
		# Keep the exception, but do not poll forever for a broken door no one is moving.
		# `begin_grab()` syncs any new shards and reactivates this process.
		set_physics_process(false)


func _frame_clearance_angle() -> float:
	if _rigid == null or not is_instance_valid(_rigid) \
			or _clearance_initial_radial.length_squared() < 0.0001:
		return INF
	var current := _rigid.to_global(_clearance_local_point) - _clearance_hinge_center
	current -= _clearance_hinge_axis * current.dot(_clearance_hinge_axis)
	if current.length_squared() < 0.0001:
		return 0.0
	return absf(atan2(
		_clearance_hinge_axis.dot(_clearance_initial_radial.cross(current)),
		_clearance_initial_radial.dot(current)
	))


func _sync_frame_collision_exceptions() -> void:
	if _rigid == null or not is_instance_valid(_rigid):
		return
	var records: Array[Dictionary] = hinge_records.duplicate()
	if not latch_record.is_empty():
		records.append(latch_record)
	for record: Dictionary in records:
		for side_name in ["owner_body", "other_body"]:
			var frame_body := record.get(side_name) as VoxelBody3D
			if frame_body == null or not is_instance_valid(frame_body) or frame_body == voxel_body:
				continue
			for collision_object: CollisionObject3D in frame_body.get_collision_objects():
				var key := collision_object.get_instance_id()
				if _frame_collision_exceptions.has(key):
					continue
				_rigid.add_collision_exception_with(collision_object)
				_frame_collision_exceptions[key] = weakref(collision_object)


func _end_frame_clearance() -> void:
	if _rigid != null and is_instance_valid(_rigid):
		for reference: WeakRef in _frame_collision_exceptions.values():
			var collision_object := reference.get_ref() as CollisionObject3D
			if collision_object != null and is_instance_valid(collision_object):
				_rigid.remove_collision_exception_with(collision_object)
	_frame_collision_exceptions.clear()
	_frame_clearance_active = false
	set_physics_process(false)


## A vertical panel without constraints can remain in exact equilibrium, squeezed by frame
## collisions and resting on the floor. The hit that destroys the last support gives it a maximum
## horizontal speed of 12 cm/s: enough to escape static equilibrium, far below an explosion.
## For two ticks it does not collide with the old frame, using the same handoff window as
## static-to-dynamic fragments, bounded here to one panel and 33 ms.
func _nudge_after_joint_removal(impact_center: Vector3) -> void:
	# `queue_free()` removes the Joint at the end of the frame. Applying the impulse earlier let the
	# constraint we had just broken absorb all of it, returning the door to zero velocity.
	await get_tree().physics_frame
	if not is_instance_valid(self) or not _fully_released:
		return
	_nudge_out_of_frame(impact_center)


func _nudge_out_of_frame(impact_center: Vector3) -> void:
	if _rigid == null or not is_instance_valid(_rigid):
		return
	var released_rigid := _rigid
	var collision_layer := released_rigid.collision_layer
	var collision_mask := released_rigid.collision_mask
	released_rigid.collision_layer = 0
	released_rigid.collision_mask = 0
	var center := bounds.get_center()
	var direction := center - impact_center
	direction.y = 0.0
	if direction.length_squared() < 0.0001 and not voxel_body.get_shapes().is_empty():
		direction = voxel_body.get_shapes()[0].global_basis.z
		direction.y = 0.0
	if direction.length_squared() < 0.0001:
		direction = Vector3.FORWARD
	var impulse := direction.normalized() * minf(released_rigid.mass * 0.12, 260.0)
	released_rigid.apply_central_impulse(impulse)
	# The angular component tips the panel out of vertical equilibrium. Apply it around the
	# horizontal axis from the destroyed support to the center, not around the former hinge.
	released_rigid.apply_torque_impulse(
		direction.normalized() * minf(released_rigid.mass * 0.22, 420.0)
	)
	released_rigid.sleeping = false
	await get_tree().physics_frame
	await get_tree().physics_frame
	if is_instance_valid(released_rigid) and released_rigid == _rigid:
		released_rigid.collision_layer = collision_layer
		released_rigid.collision_mask = collision_mask
		released_rigid.sleeping = false


## VoxelJoints normally owns this transition because it also releases holds on both endpoints and
## removes them from the index. The fallback covers only synthetic tests/scenes without the
## manager; even there, the same invariant of waking and releasing holds is maintained.
func _break_record(record: Dictionary) -> bool:
	if _joints != null and is_instance_valid(_joints):
		return _joints.break_record(record)
	if bool(record.get("broken", false)):
		return false
	var joint := record.get("joint") as Joint3D
	if joint != null and is_instance_valid(joint):
		joint.queue_free()
	record["joint"] = null
	record["broken"] = true
	for side_name in ["owner_body", "other_body"]:
		var side := record.get(side_name) as VoxelBody3D
		if side != null and is_instance_valid(side):
			side.release_physics_hold(record.get("physics_hold_key", ""))
			side.wake_for_interaction()
	return true


func _refresh_physics_hold() -> void:
	if voxel_body == null or not is_instance_valid(voxel_body) or _physics_hold_key.is_empty():
		return
	# Authored joints already hold both endpoints through VoxelJoints. This additional hold is only
	# for interactive grabbing and is released when the door is let go.
	if held:
		voxel_body.acquire_physics_hold(_physics_hold_key)
	else:
		voxel_body.release_physics_hold(_physics_hold_key)


func _on_body_split(source: VoxelBody3D, created: Array[VoxelBody3D]) -> void:
	if source == null or source != voxel_body:
		return
	var candidates: Array[VoxelBody3D] = [source]
	candidates.append_array(created)
	var records: Array[Dictionary] = hinge_records.duplicate()
	if not latch_record.is_empty():
		records.append(latch_record)
	var heir := source
	var best_score := -1
	for candidate in candidates:
		if candidate == null or not is_instance_valid(candidate):
			continue
		var score := 0
		for record in records:
			if _body_has_material_near(candidate, _record_position(record), _record_size(record)):
				score += 1
		if score > best_score:
			best_score = score
			heir = candidate
	if heir != source:
		_set_voxel_body(heir)


func _on_body_unregistered(body: VoxelBody3D) -> void:
	if body != voxel_body:
		return
	_set_voxel_body(null)
	queue_free()


func _set_voxel_body(body: VoxelBody3D) -> void:
	var old_body := voxel_body
	if old_body != null and is_instance_valid(old_body) \
			and old_body.body_state_changed.is_connected(_on_body_state_changed):
		old_body.body_state_changed.disconnect(_on_body_state_changed)
	if held and old_body != null and is_instance_valid(old_body):
		old_body.release_physics_hold(_physics_hold_key)
	if _rigid != null and is_instance_valid(_rigid) and _rigid.get_meta(BODY_META, null) == self:
		_rigid.remove_meta(BODY_META)
	voxel_body = body
	_rigid = body.get_physics_body() as RigidBody3D \
		if body != null and is_instance_valid(body) else null
	if _rigid != null:
		_rigid.set_meta(BODY_META, self)
	if held and body != null and is_instance_valid(body):
		body.acquire_physics_hold(_physics_hold_key)
	elif body == null:
		held = false
	if body != null and is_instance_valid(body) \
			and not body.body_state_changed.is_connected(_on_body_state_changed):
		body.body_state_changed.connect(_on_body_state_changed)


func _on_body_state_changed(body: VoxelBody3D) -> void:
	if body != voxel_body:
		return
	var old_rigid := _rigid
	if old_rigid != null and is_instance_valid(old_rigid) \
			and old_rigid.get_meta(BODY_META, null) == self:
		old_rigid.remove_meta(BODY_META)
	_rigid = body.get_physics_body() as RigidBody3D
	if _rigid == null:
		return
	_rigid.set_meta(BODY_META, self)
	if held:
		_rigid.sleeping = false


func _impact_reaches_record(center: Vector3, blast_radius: float, record: Dictionary) -> bool:
	return center.distance_to(_record_position(record)) <= blast_radius + _record_size(record)


func _connection_has_material(record: Dictionary) -> bool:
	if record.is_empty():
		return false
	var point := _record_position(record)
	var radius := _record_size(record)
	var owner: VoxelBody3D = record.get("owner_body")
	var other: VoxelBody3D = record.get("other_body")
	return _body_has_material_near(owner, point, radius) \
		and _body_has_material_near(other, point, radius)


static func _body_has_material_near(body: VoxelBody3D, point: Vector3, radius: float) -> bool:
	if body == null or not is_instance_valid(body):
		return false
	for shape: VoxelShape3D in body.get_shapes():
		if not shape.world_bounds().grow(radius).has_point(point):
			continue
		var voxel := shape.world_to_voxel(point)
		# A voxel counts if its cube touches the joint sphere, not merely because it belongs to the
		# AABB cube being searched. The previous test accepted diagonal corners and left a live panel
		# even if no material was still visibly present next to the anchor.
		var half_diagonal := shape.voxel_size * sqrt(3.0) * 0.5
		var effective_radius := radius + half_diagonal
		var reach := maxi(1, ceili(effective_radius / shape.voxel_size))
		var dimensions := shape.data.get_dimensions()
		var low := Vector3i(floori(voxel.x), floori(voxel.y), floori(voxel.z)) \
			- Vector3i.ONE * reach
		var high := Vector3i(floori(voxel.x), floori(voxel.y), floori(voxel.z)) \
			+ Vector3i.ONE * reach
		low = low.max(Vector3i.ZERO)
		high = high.min(dimensions - Vector3i.ONE)
		for z in range(low.z, high.z + 1):
			for y in range(low.y, high.y + 1):
				for x in range(low.x, high.x + 1):
					if shape.data.get_cell(x, y, z) == 0:
						continue
					var local_center := (
						Vector3(x + 0.5, y + 0.5, z + 0.5) - Vector3(dimensions) * 0.5
					) * shape.voxel_size
					if shape.to_global(local_center).distance_squared_to(point) \
							<= effective_radius * effective_radius:
						return true
	return false


static func _record_joint_is_live(record: Dictionary) -> bool:
	if record.is_empty() or bool(record.get("broken", false)):
		return false
	# A Node queued with `queue_free` may remain stored as a Variant until the end of the frame.
	# Check it before the typed cast to prevent a removed joint from logging "freed instance" every tick.
	var joint_variant: Variant = record.get("joint")
	if not is_instance_valid(joint_variant):
		return false
	var joint := joint_variant as Joint3D
	return joint != null and is_instance_valid(joint) and not joint.is_queued_for_deletion()


static func _record_position(record: Dictionary) -> Vector3:
	return (record.get("transform", Transform3D.IDENTITY) as Transform3D).origin


static func _record_size(record: Dictionary) -> float:
	var attributes: Dictionary = record.get("attributes", {})
	return maxf(DEFAULT_JOINT_SIZE, float(attributes.get("size", DEFAULT_JOINT_SIZE)))
