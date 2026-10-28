class_name VoxelVehicle3D
extends VehicleBody3D
## Drivable vehicle built directly from a Teardown `<vehicle>`.
##
## The chassis remains part of VoxelBody3D, preserving voxel mass, destruction, water interaction,
## and impact damage. Wheels use VehicleWheel3D raycasts: four inexpensive constraints in one Body,
## not four RigidBodies and extra joints per car.

signal driver_changed(vehicle: VoxelVehicle3D, occupied: bool)
signal flooded(vehicle: VoxelVehicle3D)

const GROUP := "voxel_vehicles"
const ENTER_DISTANCE := 3.6
const MAX_HEADLIGHTS := 2
const MAX_BRAKE_LIGHTS := 2
const MAX_REVERSE_LIGHTS := 2
const IMPACT_MIN_IMPULSE := 24.0
const IMPACT_MIN_SPEED := 2.6
const IMPACT_COOLDOWN_FRAMES := 12
## The Lee SUV chassis produced 42 subshapes. With permanent CCD against static BVHs, this raised
## the measured physics step to 41.5 ms even after stopping against an obstacle.
const COLLISION_BOX_BUDGET := 16
const CCD_MIN_SPEED := 14.0
## The chassis-and-wheel shadow occupancy is rebaked at 10 Hz. Visible geometry retains per-frame
## interpolation; reducing this CPU task from 15 to 10 Hz cuts its average cost by one third.
const SHADOW_UPDATE_INTERVAL_FRAMES := 6
const FLOOD_SUBMERSION_RATIO := 0.58
const FLOOD_SEAT_MARGIN := 0.12

var voxel_owner: VoxelBody3D
var display_name := "vehicle"
var max_speed_kmh := 80.0
var acceleration := 4.0
## Resistance authored by `<vehicle strength="…">`. Besides describing the car's durability, it
## limits the opening profile needed by its front so it does not stop against a soft 10 cm wall as
## if it were concrete. It does not replace collision energy or pierce hard materials.
var impact_strength := 4.0
## Optional frontal radius for vehicles that do not fit through a car-sized opening (e.g. a tank).
## A negative value retains the automatic curve based on speed and `strength`.
var impact_radius := -1.0
var max_steer := 0.46
var min_steer := 0.12
var steer_speed := 4.5
var service_brake := 90.0
var coast_brake := 8.0

var _driver: Node3D
var _seat_local := Vector3(0.0, 1.4, 0.0)
var _wheels: Array[VehicleWheel3D] = []
var _wheel_visuals: Array[Dictionary] = []
var _visual_body: VoxelBody3D
var _headlights: Array[Light3D] = []
var _brake_lights: Array[Light3D] = []
var _reverse_lights: Array[Light3D] = []
var _last_report_frame := {}
var _control_override := false
var _override_throttle := 0.0
var _override_steer := 0.0
var _override_handbrake := false
var _last_mass := -1.0
var _water_disabled := false
var _joints: VoxelJoints
var _camera_distance_hint := -1.0
var _camera_height_hint := -1.0
var _camera_max_distance_hint := -1.0
var _camera_fov_hint := -1.0


func configure(owner: VoxelBody3D, descriptor: Dictionary) -> void:
	voxel_owner = owner
	voxel_owner.acquire_physics_hold("vehicle_runtime:%d" % get_instance_id())
	add_to_group(GROUP)
	contact_monitor = true
	max_contacts_reported = 8
	# CCD is a vehicle capability, not a permanent state; `VoxelBody3D` enables it when the vehicle
	# travels farther than the thickness of a thin wall for several ticks.
	continuous_cd = false
	if not sleeping_state_changed.is_connected(_on_sleeping_state_changed):
		sleeping_state_changed.connect(_on_sleeping_state_changed)
	var attributes: Dictionary = descriptor.get("attributes", {})
	var tags := String(attributes.get("tags", "")).strip_edges()
	display_name = _vehicle_name(tags, String(attributes.get("sound", "")))
	max_speed_kmh = clampf(float(attributes.get("topspeed", 80.0)), 8.0, 180.0)
	acceleration = clampf(float(attributes.get("acceleration", 4.0)), 0.4, 12.0)
	impact_strength = clampf(float(attributes.get("strength", 4.0)), 0.5, 16.0)
	impact_radius = float(attributes.get("impact_radius", -1.0))
	_camera_distance_hint = float(attributes.get("camera_distance", -1.0))
	_camera_height_hint = float(attributes.get("camera_height", -1.0))
	_camera_max_distance_hint = float(attributes.get("camera_max_distance", -1.0))
	_camera_fov_hint = float(attributes.get("camera_fov", -1.0))
	var steer_assist := clampf(float(attributes.get("steerassist", 0.15)), 0.0, 1.0)
	steer_speed = lerpf(3.4, 6.2, steer_assist)
	_visual_body = descriptor.get("visual_body") as VoxelBody3D
	# The visible transform still updates every frame. Only volumetric shadow occupancy updates at
	# 10 Hz: rasterizing the chassis and wheels at all four levels took 5.7 ms per refresh.
	# Both Bodies share a phase so their five boxes merge into one small region.
	var shadow_phase := get_instance_id() % SHADOW_UPDATE_INTERVAL_FRAMES
	voxel_owner.set_meta("voxel_shadow_interval_frames", SHADOW_UPDATE_INTERVAL_FRAMES)
	voxel_owner.set_meta("voxel_shadow_phase", shadow_phase)
	if _visual_body != null and is_instance_valid(_visual_body):
		_visual_body.set_meta("voxel_shadow_interval_frames", SHADOW_UPDATE_INTERVAL_FRAMES)
		_visual_body.set_meta("voxel_shadow_phase", shadow_phase)
	var seat_transform: Transform3D = descriptor.get("seat_transform", Transform3D.IDENTITY)
	if seat_transform != Transform3D.IDENTITY:
		_seat_local = global_transform.affine_inverse() * seat_transform.origin
	_create_wheels(descriptor)
	# This Body does not participate in physics; it only owns the wheel voxels. Marking it explicitly
	# avoids the bug where its Shapes disappeared from tracking when frozen.
	var world := voxel_owner.get_parent() as VoxelWorld3D
	if world != null and _visual_body != null and is_instance_valid(_visual_body):
		world.track_external_body_transforms(_visual_body)
	# Place the visuals once even if the vehicle was imported asleep. Without this initial pass, the
	# wheels remained at their authored transforms from before the VehicleBody was recentered.
	_sync_wheel_visuals(true)
	_create_lights(descriptor.get("lights", []))
	_retune_for_mass(true)
	_set_lights(false, false, false)
	if _visual_body != null and is_instance_valid(_visual_body):
		var visual_rigid := _visual_body.get_physics_body() as RigidBody3D
		if visual_rigid != null:
			visual_rigid.freeze = true
			visual_rigid.can_sleep = true
			visual_rigid.sleeping = true


func _create_wheels(descriptor: Dictionary) -> void:
	var spring := clampf(float((descriptor.attributes as Dictionary).get("spring", 1.0)), 0.1, 3.0)
	var damping := clampf(float((descriptor.attributes as Dictionary).get("damping", 1.0)), 0.1, 3.0)
	var friction := clampf(float((descriptor.attributes as Dictionary).get("friction", 1.0)), 0.5, 2.5)
	var antiroll := clampf(float((descriptor.attributes as Dictionary).get("antiroll", 0.25)), 0.0, 1.0)
	for index in (descriptor.get("wheels", []) as Array).size():
		var record: Dictionary = descriptor.wheels[index]
		var wheel := VehicleWheel3D.new()
		wheel.name = "Wheel%d" % index
		var source_transform: Transform3D = record.get("transform", global_transform)
		var local_position := global_transform.affine_inverse() * source_transform.origin
		var visual_shapes: Array = record.get("shapes", [])
		# A vehicle can declare its radius: on a tank, the rendered road wheel does not touch the
		# ground; the track does, so the raycast must extend below the disc.
		var radius := float((record.attributes as Dictionary).get("radius", 0.0))
		if radius <= 0.0:
			radius = _wheel_radius(visual_shapes)
		if not visual_shapes.is_empty() and is_instance_valid(visual_shapes[0]):
			local_position = global_transform.affine_inverse() * (
				(visual_shapes[0] as VoxelShape3D).world_bounds().get_center()
			)
		wheel.position = local_position
		wheel.wheel_radius = radius
		var travel := _travel(record.attributes as Dictionary)
		wheel.wheel_rest_length = clampf(maxf(0.16, travel.y), 0.16, 0.42)
		wheel.suspension_travel = clampf(travel.x + travel.y, 0.18, 0.48)
		wheel.use_as_steering = String((record.attributes as Dictionary).get("steer", "0")) != "0"
		wheel.use_as_traction = String((record.attributes as Dictionary).get("drive", "0")) != "0"
		wheel.wheel_friction_slip = friction * 1.25
		wheel.suspension_stiffness = 23.0 + spring * 7.0
		wheel.damping_compression = 3.0 + damping
		wheel.damping_relaxation = 5.0 + damping * 1.6
		wheel.wheel_roll_influence = lerpf(0.48, 0.24, antiroll)
		add_child(wheel)
		_wheels.append(wheel)
		# VehicleWheel3D needs the chassis basis so traction and steering point correctly, while the
		# Shape may have its own authored mirror/rotation (for example, a hubcap on one face only).
		# Measure the visual offset from the initial physics pose, not the XML: the first sync is then
		# an identity transform and later wheel changes apply as deltas.
		var physical_rest_transform := wheel.global_transform
		for shape_variant: Variant in visual_shapes:
			var shape := shape_variant as VoxelShape3D
			if shape == null or not is_instance_valid(shape):
				continue
			_orient_wheel_face_outward(shape, wheel)
			_wheel_visuals.append({
				"wheel": wheel,
				"shape": shape,
				"local": physical_rest_transform.affine_inverse() * shape.global_transform,
			})
	# Some mods omit `drive`. A car with no drive wheels looks broken even if its XML is merely
	# incomplete; default to rear-wheel drive without inventing wheels or making a `nodrive` vehicle
	# drivable.
	if not _wheels.any(func(candidate: VehicleWheel3D) -> bool: return candidate.use_as_traction):
		for wheel in _wheels:
			wheel.use_as_traction = wheel.position.z < 0.0


## Teardown wheel `.vox` files often model the tire/hubcap on only one face. The left and right
## objects are already mirrored in their cells, but axis conversion can leave that face pointing
## toward the center of the car. Choose the face with more materials/detail and rotate the visual
## 180° around its local Y only if it points inward. VehicleWheel3D is untouched: suspension,
## traction, and steering retain the axes expected by Jolt.
func _orient_wheel_face_outward(shape: VoxelShape3D, wheel: VehicleWheel3D) -> void:
	var detail_face := _wheel_detail_face(shape)
	if detail_face == 0 or is_zero_approx(wheel.position.x):
		return
	var detail_normal := shape.global_basis.x.normalized() * float(detail_face)
	var outward := global_basis.x.normalized() * signf(wheel.position.x)
	if detail_normal.dot(outward) >= 0.0:
		return
	shape.global_basis = shape.global_basis * Basis(Vector3.UP, PI)


## -1: minimum x face; +1: maximum x face; 0: both faces have the same detail.
static func _wheel_detail_face(shape: VoxelShape3D) -> int:
	if shape == null or shape.data == null:
		return 0
	var dimensions := shape.data.get_dimensions()
	if dimensions.x <= 0 or dimensions.x >= mini(dimensions.y, dimensions.z):
		return 0
	var low_materials := {}
	var high_materials := {}
	var low_occupied := 0
	var high_occupied := 0
	var cells := shape.data.get_cells()
	for cell_index in cells.size():
		var material := int(cells[cell_index])
		if material == 0:
			continue
		var x := cell_index % dimensions.x
		if x == 0:
			low_occupied += 1
			low_materials[material] = true
		elif x == dimensions.x - 1:
			high_occupied += 1
			high_materials[material] = true
	var low_score := low_materials.size() * 1_000_000 + low_occupied
	var high_score := high_materials.size() * 1_000_000 + high_occupied
	return -1 if low_score > high_score else (1 if high_score > low_score else 0)


## Lightweight import audit, used by the real-map regression test.
func wheel_visual_faces_outward() -> bool:
	for record: Dictionary in _wheel_visuals:
		var wheel := record.get("wheel") as VehicleWheel3D
		var shape := record.get("shape") as VoxelShape3D
		if wheel == null or shape == null:
			continue
		var detail_face := _wheel_detail_face(shape)
		if detail_face == 0:
			continue
		var detail_normal := shape.global_basis.x.normalized() * float(detail_face)
		var outward := global_basis.x.normalized() * signf(wheel.position.x)
		if detail_normal.dot(outward) < 0.0:
			return false
	return true


func _create_lights(records: Array) -> void:
	for record_variant: Variant in records:
		var record := record_variant as Dictionary
		var attributes: Dictionary = record.get("attributes", {})
		var type := String(attributes.get("type", "area"))
		var color := _parse_color(String(attributes.get("color", "1 1 1")))
		if type == "cone" and _headlights.size() < MAX_HEADLIGHTS:
			var spot := SpotLight3D.new()
			spot.name = "Headlight%d" % _headlights.size()
			spot.light_color = color
			spot.light_energy = clampf(float(attributes.get("scale", 20.0)) * 0.14, 2.2, 6.5)
			spot.spot_range = clampf(float(attributes.get("reach", 20.0)), 12.0, 34.0)
			spot.spot_angle = clampf(float(attributes.get("angle", 42.0)) * 0.5, 18.0, 38.0)
			spot.spot_angle_attenuation = 1.2
			_setup_projected_light(spot, record.get("transform", global_transform), true)
			_headlights.append(spot)
		elif color.r > color.g * 1.8 and color.r > color.b * 1.8 \
				and _brake_lights.size() < MAX_BRAKE_LIGHTS:
			var tail := OmniLight3D.new()
			tail.name = "BrakeLight%d" % _brake_lights.size()
			tail.light_color = Color(1.0, 0.035, 0.02)
			tail.light_energy = 3.2
			tail.omni_range = clampf(float(attributes.get("reach", 4.5)), 3.0, 7.0)
			_setup_projected_light(tail, record.get("transform", global_transform), false)
			_brake_lights.append(tail)
		elif color.r > 0.65 and color.g > 0.65 and color.b > 0.65 \
				and _reverse_lights.size() < MAX_REVERSE_LIGHTS:
			var reverse := OmniLight3D.new()
			reverse.name = "ReverseLight%d" % _reverse_lights.size()
			reverse.light_color = Color(0.82, 0.9, 1.0)
			reverse.light_energy = 2.1
			reverse.omni_range = clampf(float(attributes.get("reach", 4.5)), 3.0, 6.0)
			_setup_projected_light(reverse, record.get("transform", global_transform), false)
			_reverse_lights.append(reverse)


func _setup_projected_light(light: Light3D, source_transform: Transform3D, cone: bool) -> void:
	add_child(light)
	# Teardown points cones along +Z; SpotLight3D shines along -Z.
	light.global_transform = source_transform * Transform3D(
		Basis(Quaternion(Vector3.UP, PI)) if cone else Basis.IDENTITY, Vector3.ZERO
	)
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 26.0 if cone else 12.0
	light.distance_fade_length = 12.0 if cone else 6.0
	light.set_meta("voxel_shadowless", true)
	light.add_to_group("voxel_shadow_lights")


func set_driver(driver: Node3D) -> bool:
	if driver == null or _driver != null or _wheels.size() < 2 or _water_disabled:
		return false
	_driver = driver
	set_physics_process(true)
	can_sleep = false
	sleeping = false
	if voxel_owner != null:
		voxel_owner.acquire_physics_hold("vehicle_driver:%d" % get_instance_id())
	_wake_attached_bodies()
	_set_lights(true, false, false)
	driver_changed.emit(self, true)
	return true


func clear_driver(driver: Node3D = null) -> void:
	if _driver == null or (driver != null and driver != _driver):
		return
	_driver = null
	engine_force = 0.0
	brake = 0.0 if _water_disabled else coast_brake
	can_sleep = true
	if voxel_owner != null and is_instance_valid(voxel_owner):
		voxel_owner.release_physics_hold("vehicle_driver:%d" % get_instance_id())
	_set_lights(false, false, false)
	driver_changed.emit(self, false)


func has_driver() -> bool:
	return _driver != null and is_instance_valid(_driver)


func can_enter(point: Vector3, maximum_distance := ENTER_DISTANCE) -> bool:
	return not _water_disabled and not has_driver() and _wheels.size() >= 2 \
		and get_seat_position().distance_to(point) <= maximum_distance


func get_seat_position() -> Vector3:
	return to_global(_seat_local)


func get_exit_candidates() -> PackedVector3Array:
	var right := Vector3(global_basis.x.x, 0.0, global_basis.x.z)
	if right.length_squared() < 0.01:
		right = Vector3.RIGHT
	right = right.normalized()
	var forward := Vector3(global_basis.z.x, 0.0, global_basis.z.z)
	if forward.length_squared() < 0.01:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var bounds := get_world_bounds()
	var radius := maxf(2.1, maxf(bounds.size.x, bounds.size.z) * 0.5 + 0.75)
	var origin := Vector3(bounds.get_center().x, bounds.end.y + 1.8, bounds.get_center().z)
	return PackedVector3Array([
		origin + right * radius,
		origin - right * radius,
		origin + forward * radius,
		origin - forward * radius,
		origin + (right + forward).normalized() * radius,
		origin + (right - forward).normalized() * radius,
		origin,
	])


func get_world_bounds() -> AABB:
	var bounds := AABB()
	var started := false
	for body in attached_bodies():
		for shape in body.get_shapes():
			bounds = shape.world_bounds() if not started else bounds.merge(shape.world_bounds())
			started = true
	if not started:
		return AABB(global_position - Vector3.ONE, Vector3.ONE * 2.0)
	return bounds


func update_water_submersion(submerged_ratio: float, surface_y: float) -> void:
	if _water_disabled or not should_flood(
		submerged_ratio, get_seat_position().y, surface_y
	):
		return
	_water_disabled = true
	linear_damp = maxf(linear_damp, 2.2)
	angular_damp = maxf(angular_damp, 5.0)
	_apply_flooded_running_gear()
	_set_lights(false, false, false)
	set_physics_process(true)
	flooded.emit(self)
	if has_driver() and _driver.has_method("on_vehicle_flooded"):
		_driver.call_deferred("on_vehicle_flooded", self)


func is_water_disabled() -> bool:
	return _water_disabled


static func should_flood(submerged_ratio: float, seat_y: float, surface_y: float) -> bool:
	return submerged_ratio >= FLOOD_SUBMERSION_RATIO \
		or surface_y >= seat_y - FLOOD_SEAT_MARGIN


func get_camera_target() -> Vector3:
	return get_seat_position() + Vector3.UP * 0.35


## The camera and DDA renderer run on the render clock. Godot interpolates the VehicleBody for
## rendering, but querying `global_transform` from `_process` returns the latest physics tick and
## reintroduces the stepping that interpolation is meant to remove. These variants receive one
## interpolated sample and derive all camera points from it consistently.
##
## Orbit-camera pivot: discard chassis roll and pitch, keeping only yaw. The seat still rotates with
## the vehicle, but a bump that rocks the chassis no longer moves the point around which the view
## orbits. That rocking caused the shake that made aiming impossible, affecting position even when
## aim direction was not smoothed.
func get_camera_pivot(vehicle_transform: Transform3D) -> Vector3:
	var forward := vehicle_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		# If the chassis is overturned onto its nose, the Z axis does not project onto the plane.
		# Fall back to another axis before normalizing a zero vector.
		forward = Vector3(vehicle_transform.basis.y.x, 0.0, vehicle_transform.basis.y.z)
		if forward.length_squared() < 0.0001:
			forward = Vector3.BACK
	var yaw_only := Basis(Vector3.UP, atan2(forward.x, forward.z))
	return vehicle_transform.origin + yaw_only * _seat_local


func get_driver_view_position() -> Vector3:
	# In Teardown XML, `player` is usually at head height (1.25–2.2 m). A slight forward offset
	# avoids z-fighting with the seatback without placing the view over the hood.
	return get_seat_position() + forward_direction() * 0.08


func get_driver_view_from_transform(vehicle_transform: Transform3D) -> Vector3:
	return vehicle_transform * _seat_local + vehicle_transform.basis.z.normalized() * 0.08


func get_camera_collision_rids() -> Array[RID]:
	var result: Array[RID] = []
	for body in attached_bodies():
		result.append_array(body.get_collision_rids())
	if _visual_body != null and is_instance_valid(_visual_body):
		result.append_array(_visual_body.get_collision_rids())
	return result


## Everything that moves with the vehicle: the chassis and anything attached by joints (such as a
## tank turret or trailer). The camera must not collide with them, and the driver must not exit
## inside them.
func attached_bodies() -> Array[VoxelBody3D]:
	var result: Array[VoxelBody3D] = []
	if voxel_owner == null or not is_instance_valid(voxel_owner):
		return result
	var joints := _find_joints()
	if joints == null:
		result.append(voxel_owner)
		return result
	return joints.connected_bodies(voxel_owner)


func _find_joints() -> VoxelJoints:
	if _joints != null and is_instance_valid(_joints):
		return _joints
	var world := voxel_owner.get_parent() if is_instance_valid(voxel_owner) else null
	if world == null:
		return null
	for child in world.get_children():
		if child is VoxelJoints:
			_joints = child
			return _joints
	return null


## A mechanism created at runtime can have its own registry even if the map already has one.
## Injecting it prevents accidentally choosing the world's first `VoxelJoints`.
func set_joint_registry(joints: VoxelJoints) -> void:
	_joints = joints


func forward_direction() -> Vector3:
	return global_basis.z.normalized()


func speed_kmh() -> float:
	return linear_velocity.length() * 3.6


## Effective drivetrain input. Exposing it prevents specialized controllers (such as tank tracks)
## from reading `Input` again on their own and allows the same path to be tested with overrides.
func control_throttle_input() -> float:
	if _control_override:
		return _override_throttle
	if not has_driver():
		return 0.0
	return Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")


func control_steer_input() -> float:
	if _control_override:
		return _override_steer
	if not has_driver():
		return 0.0
	return Input.get_action_strength("move_left") - Input.get_action_strength("move_right")


func has_active_controls() -> bool:
	return _control_override or has_driver()


func get_camera_profile() -> Dictionary:
	return {
		"distance": _camera_distance_hint,
		"height": _camera_height_hint,
		"max_distance": _camera_max_distance_hint,
		"fov": _camera_fov_hint,
	}


func set_control_override(enabled: bool, throttle := 0.0, steer_input := 0.0, handbrake := false) -> void:
	_control_override = enabled
	_override_throttle = clampf(throttle, -1.0, 1.0)
	_override_steer = clampf(steer_input, -1.0, 1.0)
	_override_handbrake = handbrake
	set_physics_process(enabled or has_driver() or not sleeping)


func headlights_active() -> bool:
	return not _headlights.is_empty() and _headlights[0].visible


func brake_lights_active() -> bool:
	return not _brake_lights.is_empty() and _brake_lights[0].visible


func reverse_lights_active() -> bool:
	return not _reverse_lights.is_empty() and _reverse_lights[0].visible


func projected_light_count() -> int:
	return _headlights.size() + _brake_lights.size() + _reverse_lights.size()


func get_wheel_telemetry() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for wheel in _wheels:
		result.append({
			"position": wheel.position,
			"radius": wheel.wheel_radius,
			"rest": wheel.wheel_rest_length,
			"contact": wheel.is_in_contact(),
			"steer": wheel.use_as_steering,
			"drive": wheel.use_as_traction,
		})
	return result


func park_after_sleep() -> void:
	if has_driver() or _control_override:
		return
	engine_force = 0.0
	brake = coast_brake
	_set_lights(false, false, false)
	# `sleep()` changes the state before calling this; force the final suspension pose so the car
	# does not park with its wheels one tick behind.
	_sync_wheel_visuals(true)
	set_physics_process(false)


func _physics_process(delta: float) -> void:
	_retune_for_mass(false)
	if _water_disabled:
		_apply_flooded_running_gear()
		steering = move_toward(steering, 0.0, steer_speed * delta)
		_set_lights(false, false, false)
		_sync_wheel_visuals()
		return
	if not has_driver() and not _control_override:
		engine_force = 0.0
		brake = coast_brake
		_set_lights(false, false, false)
		_sync_wheel_visuals()
		return
	var throttle := control_throttle_input()
	var steer_input := control_steer_input()
	var handbrake := _override_handbrake if _control_override else Input.is_action_pressed("jump")
	var longitudinal_speed := linear_velocity.dot(forward_direction())
	var opposing := absf(longitudinal_speed) > 1.0 and throttle * longitudinal_speed < -0.15
	var speed_fraction := clampf(speed_kmh() / max_speed_kmh, 0.0, 1.0)
	var engine_limit := mass * acceleration * 0.52
	engine_force = 0.0 if opposing or handbrake \
		else throttle * engine_limit * maxf(0.0, 1.0 - speed_fraction)
	if handbrake:
		brake = service_brake * 1.35
	elif opposing:
		brake = service_brake
	elif is_zero_approx(throttle):
		brake = coast_brake
	else:
		brake = 0.0
	var steer_limit := lerpf(max_steer, min_steer, speed_fraction)
	steering = move_toward(steering, steer_input * steer_limit, steer_speed * delta)
	sleeping = false
	_set_lights(true, handbrake or opposing, throttle < -0.05 and longitudinal_speed < 1.0)
	_sync_wheel_visuals()


func _on_sleeping_state_changed() -> void:
	# A parked car does not need to run GDScript. Jolt wakes it on contact, and this signal then
	# reactivates the controller/visual tracking without global polling.
	set_physics_process(has_driver() or _control_override or not sleeping)


## An authored trailer is another RigidBody joined to the tractor. Both start asleep on import to
## save solver time; waking only the VehicleBody does not guarantee every backend immediately wakes
## the rest of the island. Traverse it once on entry, not every tick.
func _wake_attached_bodies() -> void:
	if voxel_owner == null or not is_instance_valid(voxel_owner):
		return
	var joints := _find_joints()
	if joints != null:
		joints.wake_connected(voxel_owner)


func _sync_wheel_visuals(force := false) -> void:
	if _wheel_visuals.is_empty():
		return
	var moving := has_driver() or _control_override or not sleeping
	var visual_rigid := _visual_body.get_physics_body() as RigidBody3D \
		if _visual_body != null and is_instance_valid(_visual_body) else null
	if visual_rigid != null:
		visual_rigid.sleeping = not moving
	if not moving and not force:
		return
	for record: Dictionary in _wheel_visuals:
		# Visuals belong to the voxel Body and may be freed later during teardown. A typed cast of an
		# already freed Object fails before `is_instance_valid` can protect it.
		var wheel_variant: Variant = record.get("wheel")
		var shape_variant: Variant = record.get("shape")
		if not is_instance_valid(wheel_variant) or not is_instance_valid(shape_variant):
			continue
		var wheel := wheel_variant as VehicleWheel3D
		var shape := shape_variant as VoxelShape3D
		if is_instance_valid(wheel) and is_instance_valid(shape):
			shape.global_transform = wheel.global_transform * (record.local as Transform3D)


func _set_lights(headlights: bool, braking: bool, reversing: bool) -> void:
	for light in _headlights:
		light.visible = headlights
	for light in _brake_lights:
		light.visible = braking
	for light in _reverse_lights:
		light.visible = reversing


func _retune_for_mass(force := false) -> void:
	if not force and is_equal_approx(_last_mass, mass):
		return
	_last_mass = mass
	service_brake = clampf(mass * 0.055, 55.0, 260.0)
	coast_brake = clampf(mass * 0.0045, 5.0, 24.0)
	var per_wheel := mass * 9.8 / maxf(1.0, float(_wheels.size()))
	for wheel in _wheels:
		wheel.suspension_max_force = 0.0 if _water_disabled \
			else maxf(6000.0, per_wheel * 4.0)


func _apply_flooded_running_gear() -> void:
	engine_force = 0.0
	brake = 0.0
	for wheel in _wheels:
		# An active suspension raycast against the seabed fights the weight and buoyancy of a flooded
		# chassis. With no force or grip, the compound rests like any other RigidBody.
		wheel.suspension_max_force = 0.0
		wheel.wheel_friction_slip = 0.05


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if voxel_owner == null or not is_instance_valid(voxel_owner) \
			or voxel_owner.collision_handoff_pending or _water_disabled:
		return
	if state.get_contact_count() == 0:
		return
	var contacts := {}
	for index in state.get_contact_count():
		var collider := state.get_contact_collider_object(index)
		var collider_id := collider.get_instance_id() if collider != null else 0
		var relative_velocity := state.get_contact_local_velocity_at_position(index) \
			- state.get_contact_collider_velocity_at_position(index)
		var speed := contact_normal_speed(relative_velocity, state.get_contact_local_normal(index))
		if speed < IMPACT_MIN_SPEED:
			continue
		var impulse := state.get_contact_impulse(index).length()
		if impulse <= 0.0:
			continue
		# Despite the historical name, Godot documents this position in global coordinates.
		# Transforming it again moved the crater far from a rotated car away from the origin.
		var point := state.get_contact_local_position(index)
		var record: Dictionary = contacts.get(collider_id, {
			"collider": collider, "impulse": 0.0, "speed": 0.0, "point": point,
		})
		record.impulse = float(record.impulse) + impulse
		if speed > float(record.speed):
			record.speed = speed
			record.point = point
		contacts[collider_id] = record
	var frame := Engine.get_physics_frames()
	for collider_id: int in contacts:
		var record: Dictionary = contacts[collider_id]
		if float(record.impulse) < IMPACT_MIN_IMPULSE \
				or frame - int(_last_report_frame.get(collider_id, -IMPACT_COOLDOWN_FRAMES)) \
				< IMPACT_COOLDOWN_FRAMES:
			continue
		_last_report_frame[collider_id] = frame
		voxel_owner.report_physics_impact.call_deferred(
			record.collider, record.point, float(record.impulse), float(record.speed)
		)


## Only the component closing the contact can break voxels. Using `velocity.length()` meant a car
## traveling at 60 km/h on a flat road dealt damage every 12 frames even when its velocity against
## the ground normal was nearly zero; that trail of craters caused the FPS drop.
static func contact_normal_speed(
	relative_velocity: Vector3, contact_normal: Vector3
) -> float:
	# In this API, "local" identifies this body's side of the contact pair; the vector is already in
	# the global velocity frame (like `get_contact_local_position`, which is documented as global).
	return absf(relative_velocity.dot(contact_normal.normalized()))


func _exit_tree() -> void:
	if has_driver() and _driver.has_method("on_vehicle_removed"):
		_driver.call_deferred("on_vehicle_removed", self)


static func _travel(attributes: Dictionary) -> Vector2:
	var parts := String(attributes.get("travel", "-0.1 0.2")).split(" ", false)
	if parts.size() < 2:
		return Vector2(0.1, 0.2)
	return Vector2(absf(float(parts[0])), absf(float(parts[1])))


static func _wheel_radius(shapes: Array) -> float:
	if shapes.is_empty() or not is_instance_valid(shapes[0]):
		return 0.42
	var bounds := (shapes[0] as VoxelShape3D).world_bounds()
	return clampf(maxf(bounds.size.y, minf(bounds.size.x, bounds.size.z)) * 0.5, 0.24, 0.78)


static func _parse_color(text: String) -> Color:
	var parts := text.split(" ", false)
	return Color(
		float(parts[0]) if parts.size() > 0 else 1.0,
		float(parts[1]) if parts.size() > 1 else 1.0,
		float(parts[2]) if parts.size() > 2 else 1.0,
		1.0
	)


static func _vehicle_name(tags: String, sound: String) -> String:
	for candidate in ["suv", "truck", "van", "car", "bus", "tractor"]:
		if candidate in tags.to_lower():
			return candidate.to_upper() if candidate == "suv" else candidate
	var clean := sound.get_slice(" ", 0).strip_edges()
	return clean if not clean.is_empty() else "vehicle"
