class_name VoxelImpactRigidBody3D
extends RigidBody3D
## Captures the impulse resolved by Jolt without running destruction inside the physics callback.
## Reports only the dominant contact per collider and lets VoxelWorld deduplicate and budget it.

const MIN_REPORT_IMPULSE := 24.0
const MIN_REPORT_SPEED := 2.6
const REPORT_COOLDOWN_FRAMES := 12

var voxel_owner: VoxelBody3D
var _last_report_frame := {}


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if voxel_owner == null or not is_instance_valid(voxel_owner) \
			or voxel_owner.collision_handoff_pending:
		return
	if state.get_contact_count() == 0:
		return
	var contacts := {}
	for index in state.get_contact_count():
		var collider := state.get_contact_collider_object(index)
		var collider_id := collider.get_instance_id() if collider != null else 0
		# `local` identifies the contact's local side, not its coordinate frame: Godot returns this
		# position in global coordinates. Applying `state.transform` again would duplicate the
		# Body's translation.
		var contact_world := state.get_contact_local_position(index)
		var collider_velocity := state.get_contact_collider_velocity_at_position(index)
		var relative_velocity := state.get_contact_local_velocity_at_position(index) \
			- collider_velocity
		var normal := state.get_contact_local_normal(index)
		var speed := contact_normal_speed(relative_velocity, normal)
		# An articulated vehicle part may touch first: on a tank, the cannon extends several meters
		# beyond the hull. Jolt may resolve its local velocity near zero while the hinge transmits
		# the collision; velocity of the whole assembly at that point preserves impact energy.
		var impact_owner := voxel_owner.vehicle_impact_owner
		if impact_owner != null and is_instance_valid(impact_owner):
			var owner_rigid := impact_owner.get_physics_body() as RigidBody3D
			if owner_rigid != null:
				var owner_velocity := owner_rigid.linear_velocity \
					+ owner_rigid.angular_velocity.cross(contact_world - owner_rigid.global_position)
				speed = maxf(speed, contact_normal_speed(owner_velocity - collider_velocity, normal))
		if speed < MIN_REPORT_SPEED:
			continue
		var impulse := state.get_contact_impulse(index).length()
		if impulse <= 0.0:
			continue
		var record: Dictionary = contacts.get(collider_id, {
			"collider": collider, "impulse": 0.0, "speed": 0.0,
			"point": contact_world,
		})
		record.impulse = float(record.impulse) + impulse
		if speed > float(record.speed):
			record.speed = speed
			record.point = contact_world
		contacts[collider_id] = record
	var frame := Engine.get_physics_frames()
	for collider_id: int in contacts:
		var record: Dictionary = contacts[collider_id]
		if float(record.impulse) < MIN_REPORT_IMPULSE \
				or frame - int(_last_report_frame.get(collider_id, -REPORT_COOLDOWN_FRAMES)) \
				< REPORT_COOLDOWN_FRAMES:
			continue
		_last_report_frame[collider_id] = frame
		voxel_owner.report_physics_impact.call_deferred(
			record.collider, record.point, float(record.impulse), float(record.speed)
		)


static func contact_normal_speed(
	relative_velocity: Vector3, contact_normal: Vector3
) -> float:
	return absf(relative_velocity.dot(contact_normal.normalized()))
