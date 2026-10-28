class_name VoxelTank3D
extends Node
## Three-part drivable tank: the hull carries the tracks, the turret follows the sight on its
## vertical axis, and the cannon pitches on its trunnions.
##
## The turret ring and trunnions are physical hinges so the turret and cannon have real collision
## and mass, but neither is a breakable structural joint: the tank never comes apart. Accelerating,
## pivoting, driving through a wall, or taking an explosion leaves the turret in place.

const GROUP := "voxel_tanks"
const HULL_PATH := "res://assets/models/tank/tanque_casco.vox"
const TURRET_PATH := "res://assets/models/tank/tanque_torreta.vox"

## Pivot measured from the volume's minimum corner, not the `.vox` origin: the decoder crops each
## model to its contents, so the file origin is lost on import. `tools/make_tank_vox.py` prints
## these values if the geometry changes.
const HULL_RING_OFFSET := Vector3(4.15, 1.85, 1.90)
const TURRET_PIVOT_OFFSET := Vector3(3.35, 0.05, 1.60)

## The 10 cm voxel art is solid; these factors put the whole assembly near 60 tonnes.
const HULL_FILL := 0.13
const TURRET_FILL := 0.17

## Minimum distance at which the sight converges. The camera is above the cannon, so aiming at a
## wall three meters away demanded an absurd elevation and pointed the cannon at the sky: the
## classic parallax flaw of an arcade view. Below this radius, ignore the hit and aim along the
## line of sight, where the player expects to be aiming.
const AIM_MIN_CONVERGENCE := 15.0
const AIM_MAX_CONVERGENCE := 500.0

## Smoothing time constant for the aim point. Without it, crossing a wall's edge jumps from 4 m to
## 500 m in one frame and makes the turret whip around.
const AIM_SMOOTH := 9.0

## Track controls: A/D request angular velocity directly. Limiting acceleration preserves the sense
## of weight without relying on a small torque accidentally overcoming the friction of six wheels.
const TURN_MAX_YAW_SPEED := 1.05
const TURN_ACCELERATION := 2.8
const TURN_BRAKING := 4.2
const TRACK_FORWARD_SPEED := 10.5
const TRACK_REVERSE_SPEED := 5.5
const TRACK_ACCELERATION := 3.8
const TRACK_BRAKING := 5.0
## The road wheels are already drawn on the hull: seven 9-cell discs per track, spaced 9 cells
## apart. They are detached into their own Shapes so the suspension can move them. Cells follow the
## decoder's order: length, height, lateral.
const ROAD_WHEEL_SIZE_CELLS := Vector3i(9, 9, 5)
const ROAD_WHEEL_FIRST_CELL := Vector3i(10, 2, 1)
const ROAD_WHEEL_PITCH_CELLS := 9
const ROAD_WHEEL_COUNT := 7
## Lateral corner of each track. The outer cell is the flat track skirt, not the road wheel.
const ROAD_WHEEL_LATERAL_CELLS := [1, 32]
## Road-wheel tire and hub. The first and last boxes overlap the track ring and sprocket; filtering
## by material extracts the disc while leaving the track intact.
const ROAD_WHEEL_MATERIALS := [124, 125]
const ROAD_WHEEL_TRAVEL := "-0.08 0.42"
## The rendered road wheel does not reach the ground; the track supports the tank. The raycast needs
## a radius larger than the disc to keep the hull at its usual ride height (0.154 m above ground).
const ROAD_WHEEL_RADIUS := 0.804
## Spring compression while the tank is stationary on level ground. The physical axle is mounted
## this far above the rendered disc so the settled road wheel returns to its authored position.
## This is a calibration: if mass, spring, or wheel count changes, remeasure it with
## `tests/selftest/tank_road_wheel_selftest.gd`.
const ROAD_WHEEL_SAG := 0.364

## Lateral track grip. A track should not slide sideways: without this, the hull kept all its
## lateral velocity while turning and the tank drifted like a car on ice. This is the same idea as
## a wheel's `sideways slip`, limited by a deceleration so a strong side impact still pushes the tank
## instead of being canceled in one tick.
const TRACK_LATERAL_GRIP := 26.0
## Material 122 is used only for the continuous belt of both tracks: the side skirt and hull details
## that shared this index were moved to 123 with the same color and properties, so the pattern does
## not spill outside the loop.
const TRACK_MATERIAL := 122
## Cells in the cropped hull, in decoder order: length, height, lateral. The track loop occupies the
## first 13 height cells; above that is the hull.
const TRACK_CELL_BOUNDS := AABB(Vector3(0, 0, 0), Vector3(78, 13, 38))
const TRACK_LINK_PITCH_CELLS := 4.0
## The ends of the ring are not curves but 4-cell 45-degree chamfers: |dx|+|dy| is constant along
## each diagonal. This lets the shader distinguish the outer ring layer from the inner one.
const TRACK_PROFILE_CHAMFER_CELLS := 4.0
const TRACK_CELLS_PER_METRE := 10.0

const YAW_SPEED := 0.72
const YAW_GAIN := 3.4
const YAW_MAX_IMPULSE := 90000.0
const MOTOR_SIGN := -1.0
## Maximum hull-yaw compensation. This is not aiming speed (that is `YAW_SPEED`), but how much the
## turret ring may request just to stay still in world space while the hull turns, so it must exceed
## `TURN_MAX_YAW_SPEED`. It is capped so a bump that shakes the hull does not jerk the turret.
const YAW_COMPENSATION_LIMIT := 1.6

## Split point for the cannon inside the turret model: from x=61 onward, only the 6x6 voxel bore
## and muzzle remain. Everything before it (mantlet, basket, roof) stays with the turret.
const BARREL_SPLIT_X := 61
## Trunnions, measured from the turret volume's minimum corner like the other pivots: inside the
## mantlet and aligned with the bore.
const TURRET_TRUNNION_OFFSET := Vector3(5.6, 0.50, 1.60)
const BARREL_FILL := 0.20
## Elevation range of a real tank: high elevation, limited depression.
const BARREL_MIN_PITCH_DEG := -9.0
const BARREL_MAX_PITCH_DEG := 20.0
const PITCH_SPEED := 0.55
const PITCH_GAIN := 3.2
const PITCH_MAX_IMPULSE := 90000.0
## The hinge's internal angle increases opposite to measured elevation, just like the turret ring
## with `MOTOR_SIGN`. This affects the motor and limits equally, so both are negated here.
const PITCH_MOTOR_SIGN := -1.0

## Fire rate. A real tank takes longer to reload, but for now firing only produces a muzzle flash,
## and waiting six seconds to see it again would not help anyone.
const FIRE_COOLDOWN := 1.2
## Recoil. The real impulse of a 120 mm cannon on a 60-ton tank moves it twenty centimeters per
## second: accurate, but completely invisible. This is deliberately exaggerated and applied at the
## muzzle height so the tank rears on its suspension instead of merely sliding backward, which
## reads as power.
const RECOIL_IMPULSE := 45000.0
## The cannon recoils separately; the trunnion motor returns it to its original elevation.
const BARREL_RECOIL_IMPULSE := 9000.0

var target_yaw := 0.0
var target_pitch := 0.0
var hull: VoxelBody3D
var turret: VoxelBody3D
var barrel: VoxelBody3D
var vehicle: VoxelVehicle3D

var _aim_distance := AIM_MAX_CONVERGENCE
var _joint: HingeJoint3D
var _joint_record := {}
var _pitch_joint: HingeJoint3D
var _pitch_record := {}
var _joints: VoxelJoints
var _gunner: Node3D
var _track_surface: VoxelSurfaceAnimation
## Forward speed (m/s) and turn rate (rad/s) requested by the driver, using the same ramps as the
## drivetrain. Track animation uses these values, not the hull speed.
var _track_command := Vector2.ZERO
var _fire_cooldown := 0.0


## Creates the tank and all its infrastructure inside `world`. The main scene only decides where it
## appears; the camera, aiming, tracks, turret ring, and explosion response belong to the tank.
static func spawn(
	world: VoxelWorld3D, origin: Vector3, gunner: Node3D = null
) -> VoxelTank3D:
	var tank := VoxelTank3D.new()
	tank.name = "VoxelTank3D"
	tank.add_to_group(GROUP)
	tank._gunner = gunner
	tank._joints = _tank_joints(world)
	tank.hull = world.create_body_from_asset(
		HULL_PATH, Transform3D(Basis.IDENTITY, origin)
	)
	tank.turret = world.create_body_from_asset(TURRET_PATH)
	if tank.hull == null or tank.turret == null or tank._joints == null:
		tank.free()
		return null

	var pivot := _shape_point(tank.hull, HULL_RING_OFFSET)
	tank.turret.transform.origin += pivot - _shape_point(tank.turret, TURRET_PIVOT_OFFSET)
	tank.turret.force_update_transform()

	# The .vox contains the turret and cannon as one piece; split the cannon here so it can pitch on
	# its trunnions. Measure the pivot before splitting: afterward, the turret Shape no longer
	# contains the bore voxels, so its bounds are no longer a valid reference.
	var trunnion := _shape_point(tank.turret, TURRET_TRUNNION_OFFSET)
	tank.barrel = _split_barrel(world, tank.turret)

	var road_wheels := _detach_road_wheels(tank.hull)
	_make_dynamic(tank.hull, HULL_FILL)
	tank._configure_track_surface()
	_make_dynamic(tank.turret, TURRET_FILL)
	if tank.barrel != null:
		_make_dynamic(tank.barrel, BARREL_FILL)
	tank.vehicle = tank.hull.configure_vehicle(
		_tank_vehicle_descriptor(tank.hull, road_wheels)
	)
	if tank.vehicle != null:
		tank.vehicle.display_name = "tank"
		tank.vehicle.set_joint_registry(tank._joints)
		# Both tracks press many boxes against the ground. Eight contacts were entirely consumed by
		# that flat base, leaving Jolt unable to report the nose hitting a wall.
		tank.vehicle.max_contacts_reported = 32
		tank.turret.vehicle_impact_owner = tank.hull
		if tank.barrel != null:
			tank.barrel.vehicle_impact_owner = tank.hull
		# The tracks are part of the voxel art/collider and touch the ground in addition to the
		# invisible suspension wheels. A slippery hull material prevents this double contact from
		# jamming the tank; longitudinal grip still comes from the six drive wheels.
		var skid_material := PhysicsMaterial.new()
		skid_material.friction = 0.12
		skid_material.bounce = 0.0
		tank.vehicle.physics_material_override = skid_material

	var hinge := HingeJoint3D.new()
	hinge.name = "TorretaHinge"
	world.add_child(hinge)
	# A Godot hinge uses its local +Z axis; the turret rotates around world +Y.
	var frame := Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), pivot)
	hinge.global_transform = frame
	hinge.node_a = hinge.get_path_to(tank.hull.get_physics_body())
	hinge.node_b = hinge.get_path_to(tank.turret.get_physics_body())
	hinge.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	hinge.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, YAW_MAX_IMPULSE)
	tank._joint = hinge

	tank._joint_record = {
		"joint": hinge,
		"attributes": {"type": "hinge", "size": "0.9"},
		"transform": frame,
		"owner_body": tank.hull,
		"other_body": tank.turret,
		"broken": false,
		# The turret ring never breaks: not from separation, material damage, or explosions.
		"breakable": false,
	}
	tank._joints.add_records([tank._joint_record] as Array[Dictionary])
	tank._mount_barrel(world, trunnion)

	world.add_child(tank)
	tank.set_process(gunner != null)
	# Aiming needs `_process` only when there is a player; the tracks always need their physics clock,
	# even if the tank starts empty and is occupied several seconds later.
	tank.set_physics_process(true)
	return tank


## Separates the bore from the rest of the turret and gives it its own Body. `detach_component`
## already returns the Shape in world coordinates, so the Body starts with an identity transform.
static func _split_barrel(world: VoxelWorld3D, turret: VoxelBody3D) -> VoxelBody3D:
	var shape := turret.get_shapes()[0]
	var barrel_shape := shape.detach_component(
		shape.data.get_live_indices_region(
			Vector3i(BARREL_SPLIT_X, 0, 0), shape.data.get_dimensions()
		)
	)
	if barrel_shape == null:
		push_warning("VoxelTank3D: turret has no barrel to detach")
		return null
	var body := VoxelBody3D.new()
	body.name = "TankCannon"
	world.add_child(body)
	body.add_voxel_shape(barrel_shape)
	world.register_body(body)
	return body


## Mounts the cannon on the trunnions. It is a limited hinge: the motor follows the sight within the
## allowed range, and the limits stop gravity from leaving it hanging down.
func _mount_barrel(world: VoxelWorld3D, trunnion: Vector3) -> void:
	if barrel == null or not is_instance_valid(barrel):
		return
	var turret_physics := turret.get_physics_body()
	var barrel_physics := barrel.get_physics_body()
	if turret_physics == null or barrel_physics == null:
		return
	# The cannon and mantlet remain touching after the split. Without this exception, Jolt resolves
	# their face-to-face contact against the hinge itself and the cannon vibrates.
	barrel_physics.add_collision_exception_with(turret_physics)
	var hull_physics := hull.get_physics_body()
	if hull_physics != null:
		barrel_physics.add_collision_exception_with(hull_physics)

	var hinge := HingeJoint3D.new()
	hinge.name = "CanonHinge"
	# A Godot hinge uses its local +Z axis, and pitch occurs around the model's lateral axis, which is
	# exactly the turret's +Z: the frame needs no rotation here.
	var frame := Transform3D(Basis.IDENTITY, trunnion)
	world.add_child(hinge)
	hinge.global_transform = frame
	hinge.node_a = hinge.get_path_to(turret_physics)
	hinge.node_b = hinge.get_path_to(barrel_physics)
	hinge.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	hinge.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, deg_to_rad(-BARREL_MAX_PITCH_DEG))
	hinge.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(-BARREL_MIN_PITCH_DEG))
	hinge.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	hinge.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, PITCH_MAX_IMPULSE)
	_pitch_joint = hinge
	_pitch_record = {
		"joint": hinge,
		"attributes": {"type": "hinge", "size": "0.4"},
		"transform": frame,
		"owner_body": turret,
		"other_body": barrel,
		"broken": false,
		"breakable": false,
	}
	_joints.add_records([_pitch_record] as Array[Dictionary])


static func _tank_joints(world: VoxelWorld3D) -> VoxelJoints:
	var joints := world.get_node_or_null("VoxelTankJoints") as VoxelJoints
	if joints != null:
		return joints
	joints = VoxelJoints.new()
	joints.name = "VoxelTankJoints"
	world.add_child(joints)
	joints.setup(world)
	return joints


func hull_transform() -> Transform3D:
	if hull == null or not is_instance_valid(hull):
		return Transform3D.IDENTITY
	var physics := hull.get_physics_body()
	return Transform3D.IDENTITY if physics == null else physics.global_transform


func yaw() -> float:
	if hull == null or turret == null or not is_instance_valid(hull) \
			or not is_instance_valid(turret):
		return 0.0
	var a := hull.get_physics_body()
	var b := turret.get_physics_body()
	if a == null or b == null:
		return 0.0
	return wrapf(_plane_yaw(b.global_basis.x) - _plane_yaw(a.global_basis.x), -PI, PI)


## Hull yaw in rad/s. `_plane_yaw` measures on the XZ plane, so its derivative is exactly the
## vertical component of the hull's angular velocity.
func _hull_yaw_rate() -> float:
	if hull == null or not is_instance_valid(hull):
		return 0.0
	var physics := hull.get_physics_body() as RigidBody3D
	if physics == null:
		return 0.0
	return clampf(physics.angular_velocity.y, -YAW_COMPENSATION_LIMIT, YAW_COMPENSATION_LIMIT)


func is_turret_attached() -> bool:
	return not _joint_record.is_empty() and not bool(_joint_record.get("broken", false)) \
		and _joint != null and is_instance_valid(_joint)


## Distance between the turret ring's two physical anchors, useful for checking the tank under load.
func turret_anchor_separation() -> float:
	if _joint_record.is_empty() or not is_instance_valid(hull) or not is_instance_valid(turret):
		return INF
	var hull_physics := hull.get_physics_body()
	var turret_physics := turret.get_physics_body()
	if hull_physics == null or turret_physics == null:
		return INF
	var local_a: Transform3D = _joint_record.get("local_a", Transform3D.IDENTITY)
	var local_b: Transform3D = _joint_record.get("local_b", Transform3D.IDENTITY)
	return (hull_physics.global_transform * local_a).origin.distance_to(
		(turret_physics.global_transform * local_b).origin
	)


static func _plane_yaw(direction: Vector3) -> float:
	return atan2(-direction.z, direction.x)


## Detaches the road wheels from the hull art into their own Shapes on the same Body. They remain
## hull geometry for rendering, mass, and destruction; each disc only gains its own transform, which
## `_sync_wheel_visuals` can move. They are returned in wheel declaration order.
static func _detach_road_wheels(hull: VoxelBody3D) -> Array:
	var shape := hull.get_shapes()[0]
	var discs: Array = []
	for lateral: int in ROAD_WHEEL_LATERAL_CELLS:
		for index in ROAD_WHEEL_COUNT:
			var low := Vector3i(
				ROAD_WHEEL_FIRST_CELL.x + index * ROAD_WHEEL_PITCH_CELLS,
				ROAD_WHEEL_FIRST_CELL.y,
				lateral
			)
			var cells := shape.data.get_cells()
			var indices := PackedInt32Array()
			for cell_index in shape.data.get_live_indices_region(
				low, low + ROAD_WHEEL_SIZE_CELLS
			):
				if ROAD_WHEEL_MATERIALS.has(cells[cell_index]):
					indices.append(cell_index)
			var disc := shape.detach_component(indices)
			if disc == null:
				push_warning("VoxelTank3D: missing hull road wheel %d" % discs.size())
				continue
			# The disc is mounted recessed: `_create_wheels` places the axle at its center and the
			# wheel node hangs by the spring's length, so raising it here returns it to its authored
			# position once the tank settles.
			disc.transform.origin += Vector3.UP * ROAD_WHEEL_SAG
			hull.add_voxel_shape(disc, true, false)
			discs.append(disc)
	return discs


## Each rendered road wheel is the wheel: `VehicleWheel3D` places it at the center of its Shape and
## `_sync_wheel_visuals` keeps it attached, so it rotates and follows the suspension without custom
## code.
static func _tank_vehicle_descriptor(body: VoxelBody3D, road_wheels: Array) -> Dictionary:
	var bounds := body.get_shapes()[0].world_bounds()
	var wheels: Array = []
	for disc: VoxelShape3D in road_wheels:
		wheels.append({
			"attributes": {
				"steer": "0", "drive": "1", "travel": ROAD_WHEEL_TRAVEL,
				"radius": str(ROAD_WHEEL_RADIUS),
			},
			"transform": Transform3D(Basis.IDENTITY, disc.world_bounds().get_center()),
			"shapes": [disc],
		})
	return {
		"attributes": {
			"topspeed": 45.0,
			"acceleration": 7.2,
			"strength": 12.0,
			# The hull is 3.8 m wide: the car profile (up to 2.9 m in diameter) leaves two invisible
			# wall posts gripping the tracks even after the wall's center is gone.
			"impact_radius": 2.35,
			"spring": 2.2,
			"damping": 2.0,
			"friction": 2.2,
			"antiroll": 0.9,
			# Custom arcade profile: close enough to feel the weight, with less FOV distortion and a
			# wide zoom range. Authored cars retain the automatic profile.
			"camera_distance": 8.4,
			"camera_height": 1.55,
			"camera_max_distance": 14.0,
			"camera_fov": 78.0,
		},
		# The model's nose points along +X, while `VehicleBody3D` moves along this frame's +Z.
		"physics_transform": Transform3D(
			Basis(Quaternion(Vector3.UP, PI * 0.5)), bounds.get_center()
		),
		"seat_transform": Transform3D(Basis.IDENTITY, bounds.position + Vector3(
			bounds.size.x * 0.5, bounds.size.y + 0.6, bounds.size.z * 0.5
		)),
		"body": body,
		"visual_body": null,
		"wheels": wheels,
		"lights": [],
		"drivable": true,
	}


func _process(delta: float) -> void:
	if _gunner == null or not is_instance_valid(_gunner) or not is_turret_attached():
		return
	if vehicle == null or not is_instance_valid(vehicle) or not vehicle.has_driver():
		return
	# Read firing here, not in `Player`: the player intentionally ignores "fire" inside a vehicle,
	# and the tank knows where its muzzle is.
	_fire_cooldown = maxf(0.0, _fire_cooldown - delta)
	if Input.is_action_just_pressed("fire"):
		fire()
	var camera := _gunner.get("camera") as Camera3D
	if camera == null or not is_instance_valid(camera):
		return
	var hull_now := hull_transform()
	var aim_point := _camera_aim_point(camera, delta)
	target_yaw = aim_yaw(aim_point - hull_now.origin, hull_now.basis)
	target_pitch = _aim_pitch(aim_point)


func _physics_process(delta: float) -> void:
	_drive_tracks(delta)
	if not is_turret_attached() or not is_instance_valid(hull) or not is_instance_valid(turret):
		return
	var error := wrapf(target_yaw - yaw(), -PI, PI)
	# The turret-ring motor commands speed RELATIVE to the hull, and `target_yaw` is relative too:
	# with the sight fixed in world space, turning the hull at omega makes the target move at -omega.
	# A purely proportional controller can only follow this with a permanent error of omega/YAW_GAIN
	# (17 degrees at 1 rad/s), making the turret appear to rotate with the hull. Add the hull yaw with
	# the opposite sign to cancel it exactly, leaving the proportional term to handle aiming error.
	# Clamp the terms separately: aim speed to the turret-ring speed, and compensation to a higher
	# limit, since the hull can turn faster (1.05 rad/s) than the turret can compensate (0.72).
	var command := clampf(error * YAW_GAIN, -YAW_SPEED, YAW_SPEED) - _hull_yaw_rate()
	_joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, MOTOR_SIGN * command)
	if absf(error) > 0.01 or absf(command) > 0.01:
		hull.wake_for_interaction()
		turret.wake_for_interaction()
	_aim_barrel()


## Loaded ammunition. There is only one type for now; if HE or HEAT is added, this will change the
## gunner's selector, not the firing code.
const AMMO_KIND := "ap"


## Fires a muzzle flash, recoil, and a projectile. Returns `false` while the cannon is reloading.
func fire() -> bool:
	if _fire_cooldown > 0.0 or barrel == null or not is_instance_valid(barrel):
		return false
	var world := hull.get_parent() as VoxelWorld3D if is_instance_valid(hull) else null
	if world == null:
		return false
	var muzzle := muzzle_transform()
	var forward := -muzzle.basis.z
	# The hull bottom rests on the ground, so no raycast is needed to determine how high to raise dust.
	world.emit_muzzle_blast(
		muzzle.origin, forward, 1.0, hull.get_shapes()[0].world_bounds().position.y
	)
	_apply_recoil(forward, muzzle.origin)
	Projectile.spawn(world, muzzle, AMMO_KIND, _own_collision_rids(), _hull_velocity())
	_fire_cooldown = FIRE_COOLDOWN
	return true


## Everything belonging to the tank itself. The muzzle is half a meter ahead of the cannon, inside
## the turret's bounds: without this list, the projectile's first ray hits its shooter.
func _own_collision_rids() -> Array[RID]:
	var rids: Array[RID] = []
	for part: VoxelBody3D in [hull, turret, barrel]:
		if part != null and is_instance_valid(part):
			rids.append_array(part.get_collision_rids())
	return rids


## Weapon velocity, inherited by the projectile. Firing while moving deflects the shot as it would
## in reality, at no extra cost: the hull already provides the velocity.
func _hull_velocity() -> Vector3:
	var hull_physics := hull.get_physics_body() as RigidBody3D if is_instance_valid(hull) else null
	return hull_physics.linear_velocity if hull_physics != null else Vector3.ZERO


func _apply_recoil(forward: Vector3, muzzle_origin: Vector3) -> void:
	var hull_physics := hull.get_physics_body()
	if hull_physics != null:
		hull.wake_for_interaction()
		hull_physics.apply_impulse(
			-forward * RECOIL_IMPULSE, muzzle_origin - hull_physics.global_position
		)
	var barrel_physics := barrel.get_physics_body()
	if barrel_physics != null:
		barrel.wake_for_interaction()
		barrel_physics.apply_impulse(
			-forward * BARREL_RECOIL_IMPULSE, muzzle_origin - barrel_physics.global_position
		)


## Cannon muzzle, oriented along the bore using Godot's convention (`-basis.z` points forward).
func muzzle_transform() -> Transform3D:
	if barrel == null or not is_instance_valid(barrel):
		return Transform3D.IDENTITY
	var shape := barrel.get_shapes()[0]
	var bounds := shape.local_bounds()
	var center := shape.global_transform * bounds.get_center()
	# The bore was split along the model's x axis, but the sign depends on the turret's orientation:
	# the muzzle is simply the end farther from the turret.
	var half := shape.global_basis.x * (bounds.size.x * 0.5)
	if is_instance_valid(turret) and (center - turret.get_shapes()[0].world_bounds().get_center()) \
			.dot(half) < 0.0:
		half = -half
	var forward := half.normalized()
	# Half a meter in front of the muzzle: if spawned right at the opening, the first muzzle-flash
	# frame would remain half inside the cannon.
	return Transform3D(Basis.looking_at(forward, Vector3.UP), center + half + forward * 0.5)


## Follow `target_pitch` with the trunnion motor. The cannon is separate from the hull, so wake it
## separately to prevent the physics budget from leaving it asleep halfway through elevation.
func _aim_barrel() -> void:
	if _pitch_joint == null or not is_instance_valid(_pitch_joint) \
			or barrel == null or not is_instance_valid(barrel):
		return
	var error := target_pitch - barrel_pitch()
	_pitch_joint.set_param(
		HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY,
		PITCH_MOTOR_SIGN * clampf(error * PITCH_GAIN, -PITCH_SPEED, PITCH_SPEED)
	)
	if absf(error) > 0.01:
		barrel.wake_for_interaction()
		turret.wake_for_interaction()


## Current cannon elevation relative to the turret, in radians and positive upward.
func barrel_pitch() -> float:
	if turret == null or barrel == null or not is_instance_valid(turret) \
			or not is_instance_valid(barrel):
		return 0.0
	var turret_physics := turret.get_physics_body()
	var barrel_physics := barrel.get_physics_body()
	if turret_physics == null or barrel_physics == null:
		return 0.0
	return _pitch_in_frame(barrel_physics.global_basis.x, turret_physics.global_basis)


## Trunnion elevation needed to aim at `aim_point`, clamped to the tank's actual range. Measure it
## from the cannon itself: for a nearby target, measuring from the hull made the shot a few degrees
## too high.
## The firing line starts at the turret's center of mass, not the cannon Body's origin: that Body
## starts with an identity transform (`detach_component` leaves the voxels in world space), placing
## its origin below ground. Aiming at nearby ground would therefore request elevation instead of
## depression.
func _aim_pitch(aim_point: Vector3) -> float:
	if turret == null or not is_instance_valid(turret):
		return 0.0
	var turret_physics := turret.get_physics_body()
	if turret_physics == null:
		return 0.0
	return clampf(
		_pitch_in_frame(aim_point - turret_physics.global_position, turret_physics.global_basis),
		deg_to_rad(BARREL_MIN_PITCH_DEG), deg_to_rad(BARREL_MAX_PITCH_DEG)
	)


static func _pitch_in_frame(direction: Vector3, turret_basis: Basis) -> float:
	var local := turret_basis.inverse() * direction
	return atan2(local.y, Vector2(local.x, local.z).length())


## Track differential: W/S provide longitudinal drive; A/D request yaw even from a standstill.
func _drive_tracks(delta: float) -> void:
	if vehicle == null or not is_instance_valid(vehicle) or not vehicle.has_active_controls():
		_command_tracks(delta, 0.0, 0.0, TRACK_BRAKING, TURN_BRAKING)
		return
	# VehicleWheel3D provides suspension and contact, but a track does not transmit force like a free
	# wheel. Applying a capped longitudinal acceleration to the hull provides reliable starts while
	# preserving the rigid body's mass, inertia, and impact response (the tank is not teleported).
	var throttle := vehicle.control_throttle_input()
	var forward := vehicle.forward_direction()
	var longitudinal_speed := vehicle.linear_velocity.dot(forward)
	var speed_limit := TRACK_FORWARD_SPEED if throttle >= 0.0 else TRACK_REVERSE_SPEED
	var target_speed := throttle * speed_limit
	var drive_acceleration := TRACK_ACCELERATION \
		if not is_zero_approx(throttle) else TRACK_BRAKING
	var next_speed := move_toward(
		longitudinal_speed, target_speed, drive_acceleration * delta
	)
	vehicle.linear_velocity += forward * (next_speed - longitudinal_speed)
	# Track grip: dissipate lateral velocity at a capped rate instead of preserving it. Without this,
	# the tank would slide sideways out of every turn with its previous trajectory unchanged.
	var right := vehicle.global_basis.x.normalized()
	var lateral := vehicle.linear_velocity.dot(right)
	vehicle.linear_velocity += right * (
		move_toward(lateral, 0.0, TRACK_LATERAL_GRIP * delta) - lateral
	)
	var steer := vehicle.control_steer_input()
	var up := vehicle.global_basis.y.normalized()
	var current := vehicle.angular_velocity.dot(up)
	var target := steer * TURN_MAX_YAW_SPEED
	var acceleration := TURN_ACCELERATION if not is_zero_approx(steer) else TURN_BRAKING
	var next := move_toward(current, target, acceleration * delta)
	if not is_equal_approx(current, next):
		vehicle.angular_velocity += up * (next - current)
		vehicle.sleeping = false
	_command_tracks(delta, target_speed, target, drive_acceleration, acceleration)


func _configure_track_surface() -> void:
	if hull == null or not is_instance_valid(hull):
		return
	_track_surface = VoxelSurfaceAnimation.create(
		TRACK_MATERIAL, TRACK_CELL_BOUNDS, TRACK_LINK_PITCH_CELLS,
		TRACK_PROFILE_CHAMFER_CELLS
	)
	for shape in hull.get_shapes():
		shape.surface_animation = _track_surface


## The tracks follow the driver's command, not the hull's motion. Integrating actual velocity made
## them run whenever an explosion launched the tank or a wall pushed it, even with the engine off:
## it looked like a bug, not traction. Use the same ramps as `_drive_tracks`, so releasing the
## controls slows the tracks at the same rate as the tank.
func _command_tracks(
	delta: float, target_speed: float, target_yaw: float,
	drive_acceleration: float, yaw_acceleration: float
) -> void:
	_track_command = Vector2(
		move_toward(_track_command.x, target_speed, drive_acceleration * delta),
		move_toward(_track_command.y, target_yaw, yaw_acceleration * delta)
	)
	# Without input, the tracks cannot run faster than the hull: hitting a wall stops them immediately,
	# like a track engaged with its sprocket, instead of letting them coast for two seconds. This
	# clamp only reduces magnitude, never increases it, so an explosion cannot move tracks with the
	# engine off. Holding the throttle against a wall does make them slip, as on a real tank.
	if vehicle != null and is_instance_valid(vehicle):
		if is_zero_approx(target_speed):
			var speed := absf(vehicle.linear_velocity.dot(vehicle.forward_direction()))
			_track_command.x = clampf(_track_command.x, -speed, speed)
		if is_zero_approx(target_yaw):
			var spin := absf(vehicle.angular_velocity.dot(vehicle.global_basis.y.normalized()))
			_track_command.y = clampf(_track_command.y, -spin, spin)
	if _track_surface == null:
		return
	# A stationary pivot adds speed to one track and subtracts it from the other, so they run in
	# opposite directions. The sign follows v = v_forward + ω × r, with r on the hull's lateral axis:
	# the +Z track gains ω·half-width, and `offsets.x` is the low-lateral-index track on -Z.
	var half_width := TRACK_CELL_BOUNDS.size.z * 0.5 / TRACK_CELLS_PER_METRE
	var cells := delta * TRACK_CELLS_PER_METRE
	_track_surface.advance(
		(_track_command.x - _track_command.y * half_width) * cells,
		(_track_command.x + _track_command.y * half_width) * cells
	)


func _camera_aim_point(camera: Camera3D, delta: float) -> Vector3:
	var from := camera.global_position
	var direction := -camera.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(
		from, from + direction * AIM_MAX_CONVERGENCE
	)
	query.collide_with_areas = false
	if vehicle != null and is_instance_valid(vehicle):
		query.exclude = vehicle.get_camera_collision_rids()
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	var raw := AIM_MAX_CONVERGENCE if hit.is_empty() \
		else from.distance_to(hit.position as Vector3)
	_aim_distance = lerpf(
		_aim_distance,
		clampf(raw, AIM_MIN_CONVERGENCE, AIM_MAX_CONVERGENCE),
		1.0 - exp(-AIM_SMOOTH * delta)
	)
	return from + direction * _aim_distance


## Yaw to request from the turret ring so the cannon (+X in the model) points toward `aim`.
static func aim_yaw(aim: Vector3, hull_basis: Basis) -> float:
	return wrapf(_plane_yaw(aim) - _plane_yaw(hull_basis.x), -PI, PI)


static func _shape_point(body: VoxelBody3D, offset: Vector3) -> Vector3:
	return body.get_shapes()[0].world_bounds().position + offset


static func _make_dynamic(body: VoxelBody3D, fill: float) -> void:
	for shape in body.get_shapes():
		shape.physical_fill_scale = fill
	body.make_dynamic()
