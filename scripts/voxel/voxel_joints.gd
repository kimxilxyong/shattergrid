class_name VoxelJoints
extends Node
## Map `<joint>`s: they survive when a `PhysicsBody` is replaced underneath them, transfer to the
## fragment that retains the anchor when something breaks, and break only when their supporting
## voxels disappear or force breaks them.
##
## This follows Teardown's model: during destruction, "joints can be transferred to other Shapes,
## released, or deactivated entirely," and each break is an explicit event. Transfer was the missing
## piece. A Godot `Joint3D` stores two NodePaths to `PhysicsBody3D`s, and `VoxelBody3D.make_dynamic()`
## replaces the body entirely. Blowing away a post's base made it dynamic and silently broke its
## connection to the pipe, even when the joint remained intact three meters above. It is now
## rebound to the new body in the same frame.
##
## Doors already broke their hinges independently ([VoxelDoor3D]) and share this same registry, so
## each system sees breaks made by the other.

signal record_broken(record: Dictionary)

## Separation between the two anchors at which the joint is considered broken. A healthy joint
## keeps them closer; this much separation occurs only when the solver cannot handle the load. This
## approximates Teardown's `strength` using the only constraint violation Godot exposes.
const BREAK_SEPARATION := 0.5

## Importer-created `{joint, attributes, transform, owner_body, other_body, broken}` records, plus
## `local_a`/`local_b`: each anchor's position in its `PhysicsBody3D` space, used to find it after
## the body moves and reconstruct the frame when rebinding.
var _records: Array[Dictionary] = []
var _by_body := {}
var broken_by_destruction := 0
var broken_by_force := 0
var _world: VoxelWorld3D


func setup(world: VoxelWorld3D) -> void:
	_world = world
	world.body_split.connect(_on_body_split)
	world.body_unregistered.connect(_on_body_unregistered)
	world.voxel_impact.connect(
		func(center: Vector3, _removed: int, blast_radius: float) -> void:
			on_impact(center, blast_radius)
	)


func add_records(records: Array[Dictionary]) -> void:
	for record in records:
		_bind(record)
	_records.append_array(records)


func count() -> int:
	return _records.size()


func live_count() -> int:
	var live := 0
	for record in _records:
		if VoxelDoor3D._record_joint_is_live(record):
			live += 1
	return live


## Wakes the constraint island of a mechanism/vehicle without global polling. This is especially
## important for trailers: the engine explicitly wakes the tractor, while the trailer was imported
## sleeping and relies on the backend to propagate wake through the joint.
func wake_connected(source: VoxelBody3D, maximum_bodies := 24) -> int:
	var bodies := connected_bodies(source, maximum_bodies)
	for body in bodies:
		body.wake_for_interaction()
	return bodies.size()


## The island of bodies connected to `source` by live joints, including the source itself. Vehicles
## use it to identify their components: a tank turret or trailer must count as part of the vehicle
## for the camera, driver exit position, and wake-up logic.
func connected_bodies(source: VoxelBody3D, maximum_bodies := 24) -> Array[VoxelBody3D]:
	var result: Array[VoxelBody3D] = []
	if source == null or not is_instance_valid(source) or maximum_bodies <= 0:
		return result
	var pending: Array[VoxelBody3D] = [source]
	var visited := {}
	while not pending.is_empty() and visited.size() < maximum_bodies:
		var body := pending.pop_front() as VoxelBody3D
		if body == null or not is_instance_valid(body) or visited.has(body.get_instance_id()):
			continue
		visited[body.get_instance_id()] = true
		result.append(body)
		for record: Dictionary in _by_body.get(body.get_instance_id(), []):
			if not VoxelDoor3D._record_joint_is_live(record):
				continue
			var neighbour := record.get("other_body") as VoxelBody3D \
				if record.get("owner_body") == body else record.get("owner_body") as VoxelBody3D
			if neighbour != null and is_instance_valid(neighbour) \
					and not visited.has(neighbour.get_instance_id()):
				pending.append(neighbour)
	return result


## Break joints reached by the blast that no longer have material on both sides. Only joints within
## the radius are checked, so a shot costs only as much as the nearby joints.
func on_impact(center: Vector3, blast_radius: float) -> int:
	var broken := 0
	for record in _records:
		if not VoxelDoor3D._record_joint_is_live(record):
			continue
		# Some constraints belong to gameplay-controlled mechanisms. A tank turret, for example, is
		# not a beam the solver can break by passing it through a wall; its controller releases it
		# explicitly when the tank is hit by an explosion.
		if not bool(record.get("breakable", true)):
			continue
		var point := VoxelDoor3D._record_position(record)
		var size := VoxelDoor3D._record_size(record)
		if center.distance_to(point) > blast_radius + size:
			continue
		# A joint remains live while material exists on both sides. If one side has no voxels around
		# the anchor, there is nothing left to attach to.
		if _side_has_material(record.get("owner_body"), point, size) \
				and _side_has_material(record.get("other_body"), point, size):
			continue
		break_record(record)
		broken_by_destruction += 1
		broken += 1
	return broken


## Force is the only thing that breaks an intact joint. Godot does not expose constraint force, but
## it does expose constraint error: anchor separation is proportional to the load the solver cannot
## withstand.
func _physics_process(_delta: float) -> void:
	for record in _records:
		if not VoxelDoor3D._record_joint_is_live(record):
			continue
		if not bool(record.get("breakable", true)):
			continue
		var owner_body := record.get("owner_body") as VoxelBody3D
		var other_body := record.get("other_body") as VoxelBody3D
		if owner_body == null or other_body == null:
			continue
		# Two sleeping bodies are not separating.
		if not owner_body.is_awake() and not other_body.is_awake():
			continue
		var a := _anchor_world(owner_body, record.get("local_a"))
		var b := _anchor_world(other_body, record.get("local_b"))
		if a.distance_to(b) <= BREAK_SEPARATION:
			continue
		break_record(record)
		broken_by_force += 1


func break_record(record: Dictionary) -> bool:
	if bool(record.get("broken", false)):
		return false
	var joint: Joint3D = record.get("joint")
	if joint != null and is_instance_valid(joint):
		joint.queue_free()
	record["joint"] = null
	record["broken"] = true
	# Both bodies must be notified: the released one falls, and the one holding it loses weight.
	# Sleeping bodies would notice nothing, leaving them floating.
	for side in [record.get("owner_body"), record.get("other_body")]:
		var body := side as VoxelBody3D
		if body != null and is_instance_valid(body):
			body.release_physics_hold(record.get("physics_hold_key", ""))
			_unindex(record, body)
			body.wake_for_interaction()
			# `wake_for_interaction` only revives retired bodies. A STATIC piece supported only by this
			# joint remains static until its support is checked again.
			if _world != null and is_instance_valid(_world):
				_world.queue_support_check(body)
	record_broken.emit(record)
	return true


## A body becoming dynamic—or being retired as static—gets a new `PhysicsBody3D`, leaving the joint's
## NodePaths pointing at the old, now-dead body. Rebind immediately, before the body moves, so the
## frame remains correct.
func _on_body_state_changed(body: VoxelBody3D) -> void:
	for record: Dictionary in _by_body.get(body.get_instance_id(), []):
		_rebind(record)


## When a body splits, the anchor goes with the fragment that retained its material. This implements
## Teardown's rule that "joints can be transferred to other Shapes": splitting the body does not
## break the joint; ownership changes.
func _on_body_split(source: VoxelBody3D, created: Array[VoxelBody3D]) -> void:
	if source == null:
		return
	for record: Dictionary in _by_body.get(source.get_instance_id(), []).duplicate():
		if not VoxelDoor3D._record_joint_is_live(record):
			continue
		var point := VoxelDoor3D._record_position(record)
		var size := VoxelDoor3D._record_size(record)
		var heir := source
		if not VoxelDoor3D._body_has_material_near(source, point, size):
			heir = null
			for candidate in created:
				if VoxelDoor3D._body_has_material_near(candidate, point, size):
					heir = candidate
					break
		if heir == null or heir == source:
			continue
		var side := "owner_body" if record.get("owner_body") == source else "other_body"
		record[side] = heir
		source.release_physics_hold(record.get("physics_hold_key", ""))
		_unindex(record, source)
		heir.acquire_physics_hold(record.get("physics_hold_key", ""))
		_index(record, heir)
		_rebind(record)


func _on_body_unregistered(body: VoxelBody3D) -> void:
	if body == null:
		return
	# A record that survives `body_split` has no material heir. Keeping it would leave a NodePath and
	# hold pointing to a Body that is about to disappear.
	for record: Dictionary in _by_body.get(body.get_instance_id(), []).duplicate():
		break_record(record)
	_by_body.erase(body.get_instance_id())


func _bind(record: Dictionary) -> void:
	var owner_body := record.get("owner_body") as VoxelBody3D
	var other_body := record.get("other_body") as VoxelBody3D
	if owner_body == null or other_body == null:
		return
	var frame: Transform3D = record.get("transform", Transform3D.IDENTITY)
	if not record.has("physics_hold_key"):
		var joint := record.get("joint") as Joint3D
		record["physics_hold_key"] = "joint:%d" % (
			joint.get_instance_id() if joint != null else Time.get_ticks_usec()
		)
	record["local_a"] = _to_local(owner_body, frame)
	record["local_b"] = _to_local(other_body, frame)
	for body in [owner_body, other_body]:
		body.acquire_physics_hold(record.physics_hold_key)
		_index(record, body)
		if not body.body_state_changed.is_connected(_on_body_state_changed):
			body.body_state_changed.connect(_on_body_state_changed)


func _index(record: Dictionary, body: VoxelBody3D) -> void:
	var key := body.get_instance_id()
	var records: Array = _by_body.get(key, [])
	if not records.has(record):
		records.append(record)
	_by_body[key] = records


func _unindex(record: Dictionary, body: VoxelBody3D) -> void:
	var key := body.get_instance_id()
	var records: Array = _by_body.get(key, [])
	records.erase(record)
	if records.is_empty():
		_by_body.erase(key)
	else:
		_by_body[key] = records


func _rebind(record: Dictionary) -> void:
	var joint := record.get("joint") as Joint3D
	if joint == null or not is_instance_valid(joint):
		return
	var owner_body := record.get("owner_body") as VoxelBody3D
	var other_body := record.get("other_body") as VoxelBody3D
	if owner_body == null or other_body == null:
		return
	var a := owner_body.get_physics_body()
	var b := other_body.get_physics_body()
	if a == null or b == null or a == b:
		break_record(record)
		return
	# Derive the frame from the anchor as it is NOW, not from its import-time position: Godot
	# rebuilds the constraint using the node's transform when assigning NodePaths, and reconnecting
	# with the old frame would jerk the bodies back to their original pose.
	joint.global_transform = (a.global_transform * (record.get("local_a") as Transform3D)) \
		.orthonormalized()
	joint.node_a = joint.get_path_to(a)
	joint.node_b = joint.get_path_to(b)


static func _to_local(body: VoxelBody3D, frame: Transform3D) -> Transform3D:
	var physics := body.get_physics_body()
	return frame if physics == null else physics.global_transform.affine_inverse() * frame


static func _anchor_world(body: VoxelBody3D, local: Variant) -> Vector3:
	var physics := body.get_physics_body()
	if physics == null or not (local is Transform3D):
		return Vector3.ZERO
	return (physics.global_transform * (local as Transform3D)).origin


static func _side_has_material(side: Variant, point: Vector3, radius: float) -> bool:
	var body := side as VoxelBody3D
	return VoxelDoor3D._body_has_material_near(body, point, radius)
