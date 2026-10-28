extends CharacterBody3D
## First-person player with step climbing, floor snap, and physical grabbing of voxel props.

const SPEED := 5.5
const SPRINT := 9.0
const JUMP_SPEED := 5.0
const MOUSE_SENSITIVITY := 0.0022
const PITCH_LIMIT := deg_to_rad(89.0)
const GROUND_ACCELERATION := 42.0
const AIR_ACCELERATION := 13.0
const MAX_STEP_HEIGHT := 0.46
const MIN_STEP_HEIGHT := 0.045
const STEP_FORWARD_CLEARANCE := 0.3
const FLOOR_SNAP := 0.32
const COYOTE_TIME := 0.12
const JUMP_BUFFER_TIME := 0.12
const SWIM_SPEED := 4.3
const SWIM_ACCELERATION := 16.0
const SWIM_VERTICAL_ACCELERATION := 13.0
## With the CharacterBody origin at the feet, this value keeps the camera about 50 cm above the
## water surface so the player swims at the surface instead of sinking like a stone.
const SWIM_ORIGIN_DEPTH := 1.15
const SWIM_ENTER_DEPTH := 0.55
const SWIM_EXIT_DEPTH := 0.15

## The body snaps up the step, as it should: if the camera follows in the same frame, a one-voxel
## rise looks like a jolt. Store that jump as a view-height offset and ease it out over about
## 0.15 s, so physics remains stepped while the view rises smoothly. Source does this with
## `m_flStepSmoothingOffset`; it is free because collision geometry does not change.
##
## Known limitation: small jumps are noticeable on very uneven ground. The offset decays
## exponentially, so several consecutive steps accumulate faster than it decays and the view lags
## behind the body; when the terrain levels out, the sudden catch-up looks like a little hop. The
## better solution is a constant, speed-limited decay (m/s), as in Source's `SmoothStepView`, and to
## avoid accumulating offset while falling.
const VIEW_STEP_SMOOTH := 14.0
const VIEW_STEP_MAX := 0.55

## Teardown's `ConstrainPosition` attracts two points with maximum speed and impulse. Here it is
## modelled as a PD spring applied at the exact point on the compound: Jolt retains rotation,
## hinges, and collisions. Player force is absolute, not proportional to mass, so a light box lifts,
## a door feels heavy, and a huge piece barely moves.
const GRAB_RANGE := 3.25
const GRAB_STIFFNESS := 760.0
const GRAB_DAMPING_RATIO := 0.86
const GRAB_MAX_FORCE := 2200.0
const GRAB_MAX_ACCELERATION := 38.0
const GRAB_TARGET_MAX_SPEED := 13.0
const GRAB_BREAK_SLACK := 1.15
const GRAB_COMFORTABLE_MASS := 80.0
const GRAB_MIN_MOVE_SCALE := 0.42
const INTERACTION_REFRESH := 0.1

## Range of a direct shot. Beyond this distance, the bullet is lost.
const RANGE := 200.0

## Teardown-style `MakeHole` tools: `radius` is the hole size in soft material (wood, plaster,
## glass), and `energy` is penetration, divided by material hardness to get the actual radius. The
## cannon can pierce render but barely scratch concrete, while the bomb creates a stepped crater
## instead of erasing everything it touches as a perfect sphere.
const CANON := {"radius": 1.1, "energy": 1.1}
const BOMBA := {"radius": 2.3, "energy": 1.5}

## Speed at which the bomb leaves the player's hand.
const THROW_SPEED := 18.0

@onready var camera: Camera3D = $Camera3D
@onready var interaction_label: Label = get_node_or_null("../HUD/Interaction") as Label

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _camera_rest_position := Vector3.ZERO
var _view_step_offset := 0.0
var _impact_trauma := 0.0
var _shake_phase := 0.0
var _coyote_remaining := 0.0
var _jump_buffer_remaining := 0.0
var _grabbed_door: VoxelDoor3D
var _grabbed_voxel_body: VoxelBody3D
var _grabbed_shape: VoxelShape3D
var _grabbed_body: RigidBody3D
var _grab_shape_local_point := Vector3.ZERO
var _grab_distance := 0.0
var _grab_previous_can_sleep := true
var _grab_last_target := Vector3.ZERO
var _grab_hold_key := ""
var _grab_line: Line2D
var _interaction_elapsed := 0.0
var _water: VoxelWaterSystem
var _was_swimming := false
var _driving_vehicle: VoxelVehicle3D
var _saved_collision_layer := 1
## Physics frames remaining before restoring capsule collision after exiting a vehicle. Jolt needs
## one full step with the exit pose applied: restoring earlier—even at the start of the next
## `_physics_process`—still sweeps from the seat.
var _collision_restore_delay := 0
var _saved_collision_mask := 1
var _saved_camera_position := Vector3.ZERO
var _saved_camera_rotation := Vector3.ZERO
var _saved_camera_fov := 75.0
var _saved_vehicle_entry_position := Vector3.ZERO
var _vehicle_camera := VehicleCamera.new()


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_camera_rest_position = camera.position
	# The camera manually consumes the vehicle's interpolated transform in `_process`; it must not
	# also receive local interpolation, which would add a tick of latency and feedback.
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# Conservative static collision LOD can turn 10 cm voxel stairs into 20–40 cm risers. Godot's
	# snap handles descents; `_try_step_up` handles the matching ascent without a ramp mesh.
	floor_snap_length = FLOOR_SNAP
	floor_max_angle = deg_to_rad(52.0)
	floor_stop_on_slope = true
	floor_constant_speed = true
	floor_block_on_wall = true
	max_slides = 8
	# Jolt: the margin must be tiny or it swallows the collision detection. At 0.035, the wall probe
	# in `_try_step_up` was shorter than the margin itself—the previous frame's slide had already
	# cancelled velocity—and returned "clear path" in front of a 25 cm step.
	safe_margin = 0.001
	_grab_hold_key = "player_grab:%d" % get_instance_id()
	_ensure_grab_line()
	_connect_voxel_impacts.call_deferred()
	_find_water.call_deferred()


func _process(delta: float) -> void:
	if _driving_vehicle != null:
		if not is_instance_valid(_driving_vehicle) or not _driving_vehicle.is_inside_tree():
			_leave_vehicle(false)
		else:
			_vehicle_camera.update(delta, camera, _driving_vehicle, _camera_exclusions())
			if _grab_line != null:
				_grab_line.visible = false
			return
	_impact_trauma = maxf(0.0, _impact_trauma - delta * 1.8)
	_shake_phase += delta * 34.0
	var amplitude := _impact_trauma * _impact_trauma
	camera.position = _camera_rest_position + Vector3(
		sin(_shake_phase * 1.71), cos(_shake_phase * 1.19), 0.0
	) * amplitude * 0.035 + Vector3(0.0, _view_step_offset, 0.0)
	camera.rotation.z = sin(_shake_phase * 1.43) * amplitude * 0.012
	_update_grab_line()


func _unhandled_input(event: InputEvent) -> void:
	if _driving_vehicle != null and event is InputEventMouseButton \
			and _vehicle_camera.handle_input(event):
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		if _driving_vehicle != null:
			_vehicle_camera.handle_input(motion)
		else:
			rotate_y(-motion.relative.x * MOUSE_SENSITIVITY)
			camera.rotation.x = clampf(
				camera.rotation.x - motion.relative.y * MOUSE_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT
			)
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)
	elif event.is_action_pressed("interact"):
		_toggle_vehicle()
	elif _driving_vehicle != null:
		# VoxelVehicle3D continuously reads WASD/Space. While in the car, those controls must not
		# accidentally fire, grab, or throw a bomb.
		return
	elif event.is_action_pressed("fire"):
		_fire()
	elif event.is_action_pressed("grab"):
		_begin_grab()
	elif event.is_action_released("grab"):
		_end_grab()
	elif event.is_action_pressed("throw"):
		_throw()
	elif event.is_action_pressed("jump"):
		_jump_buffer_remaining = JUMP_BUFFER_TIME


func _physics_process(delta: float) -> void:
	if _driving_vehicle != null:
		if is_instance_valid(_driving_vehicle):
			global_position = _driving_vehicle.get_seat_position()
			velocity = _driving_vehicle.linear_velocity
			_interaction_elapsed += delta
			if _interaction_elapsed >= INTERACTION_REFRESH:
				_interaction_elapsed = 0.0
				_update_interaction_hint()
		else:
			_leave_vehicle(false)
		return
	if not _apply_pending_collision_restore():
		return
	var was_on_floor := is_on_floor()
	var previous_y := global_position.y
	var water_sample := _sample_water()
	var immersion := float(water_sample.get("surface_y", -INF)) - global_position.y \
		if not water_sample.is_empty() else -INF
	var swimming := not water_sample.is_empty() and (
		immersion > SWIM_ENTER_DEPTH or (_was_swimming and immersion > SWIM_EXIT_DEPTH)
	)
	if swimming and not _was_swimming and _water != null:
		_water.emit_splash(
			Vector3(global_position.x, float(water_sample.surface_y) + 0.025, global_position.z),
			clampf(absf(velocity.y) * 0.38, 0.45, 2.5)
		)
	_coyote_remaining = COYOTE_TIME if was_on_floor and not swimming \
		else maxf(0.0, _coyote_remaining - delta)
	_jump_buffer_remaining = maxf(0.0, _jump_buffer_remaining - delta)
	if Input.is_action_just_pressed("jump"):
		_jump_buffer_remaining = JUMP_BUFFER_TIME
	var jumped := not swimming and _jump_buffer_remaining > 0.0 and _coyote_remaining > 0.0
	if jumped:
		velocity.y = JUMP_SPEED
		_jump_buffer_remaining = 0.0
		_coyote_remaining = 0.0
	elif swimming:
		var target_y := float(water_sample.surface_y) - SWIM_ORIGIN_DEPTH
		var target_vertical_speed := clampf((target_y - global_position.y) * 4.2, -1.8, 3.0)
		if Input.is_action_pressed("jump"):
			target_vertical_speed = maxf(target_vertical_speed, 1.8)
		velocity.y = move_toward(
			velocity.y, target_vertical_speed, SWIM_VERTICAL_ACCELERATION * delta
		)
	elif not was_on_floor:
		velocity.y -= _gravity * delta
	else:
		velocity.y = minf(velocity.y, 0.0)
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input.x, 0.0, input.y)).normalized()
	var speed := SWIM_SPEED if swimming else (
		SPRINT if Input.is_action_pressed("sprint") else SPEED
	)
	if _grabbed_body != null and is_instance_valid(_grabbed_body):
		speed *= grab_movement_scale_for_mass(_grabbed_body.mass)
	var acceleration := SWIM_ACCELERATION if swimming else (
		GROUND_ACCELERATION if was_on_floor else AIR_ACCELERATION
	)
	velocity.x = move_toward(velocity.x, direction.x * speed, acceleration * delta)
	velocity.z = move_toward(velocity.z, direction.z * speed, acceleration * delta)
	var horizontal_motion := Vector3(velocity.x, 0.0, velocity.z) * delta
	var stepped := not swimming and not jumped and was_on_floor and _try_step_up(horizontal_motion)
	if not stepped:
		move_and_slide()
	# Apply the offset at the physics rate, not the render rate, so smoothing lasts the same at 30
	# and 144 fps regardless of how many frames are drawn in between.
	_view_step_offset *= exp(-VIEW_STEP_SMOOTH * delta)
	# Smooth only the step height while walking: jumps and falls should still feel like jumps and falls.
	if was_on_floor and is_on_floor() and not jumped and not swimming:
		_view_step_offset = clampf(
			_view_step_offset - (global_position.y - previous_y), -VIEW_STEP_MAX, VIEW_STEP_MAX
		)
	# Apply it now: if deferred to `_process`, the frame where the body rises would render with the
	# camera still uncompensated, causing the very jolt this code removes.
	camera.position.y = _camera_rest_position.y + _view_step_offset
	_apply_grab_force(delta)
	_interaction_elapsed += delta
	if _interaction_elapsed >= INTERACTION_REFRESH:
		_interaction_elapsed = 0.0
		_update_interaction_hint()
	_was_swimming = swimming


func _find_water() -> void:
	_water = get_tree().get_first_node_in_group(VoxelWaterSystem.GROUP) as VoxelWaterSystem


func _sample_water() -> Dictionary:
	if _water == null or not is_instance_valid(_water):
		_find_water()
	if _water == null:
		return {}
	var sample := _water.sample_surface(global_position)
	if sample.is_empty():
		return {}
	var depth := float(sample.depth)
	if depth > 0.0 and global_position.y < float(sample.surface_y) - depth:
		return {}
	return sample


## Tests a three-part motion (up, forward, down) before committing it. It only activates when the
## direct horizontal path is blocked; the elevated cast keeps ordinary walls from causing hops.
func _try_step_up(horizontal_motion: Vector3) -> bool:
	if horizontal_motion.length_squared() < 0.000001:
		return false
	var wall_collision := KinematicCollision3D.new()
	if not test_move(global_transform, horizontal_motion, wall_collision, safe_margin, false, 2):
		return false
	# A capsule reports an upward-slanted normal when its rounded toe reaches a square stair edge;
	# rejecting that normal was precisely what made 20 cm voxel stairs impassable. The raised
	# forward cast below is the actual guard against climbing a full wall.
	if wall_collision.get_collision_count() == 0:
		return false

	# Rising and moving forward are not all-or-nothing: if something blocks the way, keep whatever
	# distance was covered and continue. Aborting was exactly what prevented climbing steps over
	# 20 cm—the forward probe at 46 cm elevation hits the step after the next as soon as the riser
	# exceeds 23 cm, then gives up even though the next step is perfectly walkable.
	var up_motion := Vector3.UP * MAX_STEP_HEIGHT
	var up_collision := KinematicCollision3D.new()
	if test_move(global_transform, up_motion, up_collision, safe_margin, false, 2):
		up_motion = up_collision.get_travel()
	if up_motion.y < MIN_STEP_HEIGHT:
		return false
	# The rounded foot of a capsule first touches a stair before its centre crosses the riser. Probe
	# one capsule-radius into the tread; otherwise the downward cast hits that rounded corner again
	# and reports a slope instead of the flat step top.
	# The clearance belongs only to the PROBE. Applying it afterward as actual displacement added
	# 30 cm per step to the requested movement, causing the false acceleration on stairs and uneven
	# voxel ground.
	var probe_motion := horizontal_motion \
		+ horizontal_motion.normalized() * STEP_FORWARD_CLEARANCE
	var raised := global_transform
	raised.origin += up_motion
	var forward_collision := KinematicCollision3D.new()
	if test_move(raised, probe_motion, forward_collision, safe_margin, false, 2):
		probe_motion = forward_collision.get_travel()
	# If the raised probe cannot move as far as requested this frame, it is a wall, not a step; this
	# is the only guard that prevents climbing walls.
	if probe_motion.length() < horizontal_motion.length():
		return false
	var advanced := raised
	advanced.origin += probe_motion
	var down_collision := KinematicCollision3D.new()
	var down_motion := Vector3.DOWN * (up_motion.y + FLOOR_SNAP)
	if not test_move(advanced, down_motion, down_collision, safe_margin, false, 4):
		return false
	# Do NOT judge by the normal here. When landing on a stair edge—which is normal when the forward
	# probe falls short—Jolt returns the edge's normal, about 53 degrees, and a perfectly walkable
	# landing was rejected as a wall. That made 15 cm and 20 cm stairs, exactly one- and two-voxel
	# steps on the map, impassable. Height is decisive: `rise` must be within the allowed step range.
	# The higher forward probe above, not this one, prevents climbing a wall.
	if down_collision.get_collision_count() == 0:
		return false
	var down_travel := down_collision.get_travel()
	var rise := up_motion.y + down_travel.y
	if rise < MIN_STEP_HEIGHT or rise > MAX_STEP_HEIGHT + 0.01:
		return false
	# The extra sweep finds a stable horizontal surface, while the frame preserves exactly the
	# horizontal distance integrated from `velocity`.
	global_position += up_motion + horizontal_motion + down_travel
	velocity.y = 0.0
	return true


func _begin_grab() -> void:
	if _grabbed_voxel_body != null:
		return
	var pick := _pick_grabbable()
	if pick.is_empty():
		return
	_grabbed_voxel_body = pick.voxel_body
	_grabbed_shape = pick.shape
	_grabbed_door = pick.get("door") as VoxelDoor3D
	# A retired body returns to RigidBody before references are kept; the previous StaticBody is
	# removed later and must not receive forces.
	_grabbed_voxel_body.wake_for_interaction()
	_grabbed_body = _grabbed_voxel_body.get_physics_body() as RigidBody3D
	if _grabbed_body == null:
		_clear_grab_state()
		return
	_grab_shape_local_point = _grabbed_shape.to_local(pick.position)
	_grab_distance = clampf(camera.global_position.distance_to(pick.position), 0.8, GRAB_RANGE)
	_grabbed_voxel_body.acquire_physics_hold(_grab_hold_key)
	_grab_previous_can_sleep = _grabbed_body.can_sleep
	_grabbed_body.can_sleep = false
	_grabbed_body.sleeping = false
	if _grabbed_door != null and is_instance_valid(_grabbed_door):
		_grabbed_door.begin_grab()
	_grab_last_target = camera.global_position - camera.global_basis.z * _grab_distance
	if _grab_line != null:
		_grab_line.visible = true
	_update_interaction_hint()


func _end_grab() -> void:
	if _grabbed_door != null and is_instance_valid(_grabbed_door):
		_grabbed_door.end_grab()
	if _grabbed_voxel_body != null and is_instance_valid(_grabbed_voxel_body):
		_grabbed_voxel_body.release_physics_hold(_grab_hold_key)
	if _grabbed_body != null and is_instance_valid(_grabbed_body):
		_grabbed_body.can_sleep = _grab_previous_can_sleep
	_clear_grab_state()
	_update_interaction_hint()


func _clear_grab_state() -> void:
	_grabbed_door = null
	_grabbed_voxel_body = null
	_grabbed_shape = null
	_grabbed_body = null
	if _grab_line != null:
		_grab_line.visible = false


func _apply_grab_force(delta: float) -> void:
	if _grabbed_voxel_body == null:
		return
	if not _refresh_grab_owner():
		_end_grab()
		return
	var grab_point := _grabbed_shape.to_global(_grab_shape_local_point)
	if camera.global_position.distance_to(grab_point) > GRAB_RANGE + GRAB_BREAK_SLACK:
		_end_grab()
		return
	var target := camera.global_position - camera.global_basis.z * _grab_distance
	var target_velocity := ((target - _grab_last_target) / maxf(delta, 0.0001)).limit_length(
		GRAB_TARGET_MAX_SPEED
	)
	_grab_last_target = target
	var center_of_mass := _grabbed_body.to_global(_grabbed_body.center_of_mass)
	var point_velocity := _grabbed_body.linear_velocity + _grabbed_body.angular_velocity.cross(
		grab_point - center_of_mass
	)
	var mass := maxf(_grabbed_body.mass, 0.001)
	var damping := 2.0 * sqrt(GRAB_STIFFNESS * mass) * GRAB_DAMPING_RATIO
	var force := (target - grab_point) * GRAB_STIFFNESS \
		+ (target_velocity - point_velocity) * damping
	var force_limit := grab_force_limit_for_mass(mass)
	force = force.limit_length(force_limit)
	_grabbed_body.apply_force(force, grab_point - _grabbed_body.global_position)
	_grabbed_body.sleeping = false


func _refresh_grab_owner() -> bool:
	if _grabbed_shape == null or not is_instance_valid(_grabbed_shape) \
			or _grabbed_shape.is_queued_for_deletion():
		return false
	var current := _voxel_body_from_node(_grabbed_shape)
	if current == null or current.state == VoxelBody3D.State.STATIC:
		return false
	if current != _grabbed_voxel_body:
		if _grabbed_voxel_body != null and is_instance_valid(_grabbed_voxel_body):
			_grabbed_voxel_body.release_physics_hold(_grab_hold_key)
		_grabbed_voxel_body = current
		current.wake_for_interaction()
		current.acquire_physics_hold(_grab_hold_key)
	var current_rigid := current.get_physics_body() as RigidBody3D
	if current_rigid == null:
		return false
	if current_rigid != _grabbed_body:
		if _grabbed_body != null and is_instance_valid(_grabbed_body):
			_grabbed_body.can_sleep = _grab_previous_can_sleep
		_grabbed_body = current_rigid
		_grab_previous_can_sleep = current_rigid.can_sleep
		current_rigid.can_sleep = false
	current_rigid.sleeping = false
	return true


func _pick_grabbable() -> Dictionary:
	var from := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(
		from, from - camera.global_basis.z * GRAB_RANGE
	)
	query.exclude = [get_rid()]
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	var collider := hit.get("collider") as CollisionObject3D
	if collider == null:
		return {}
	var voxel_body := _voxel_body_from_node(collider)
	# XML and fragmentation are the only sources that authorize dynamic state. Clicking never
	# promotes a STATIC wall; RETIRED_STATIC is a dynamic body sleeping due to the budget and can be
	# reactivated.
	if voxel_body == null or voxel_body.state == VoxelBody3D.State.STATIC:
		return {}
	var shape := _shape_from_hit(voxel_body, collider, hit)
	if shape == null:
		return {}
	var door := collider.get_meta(VoxelDoor3D.BODY_META) as VoxelDoor3D \
		if collider.has_meta(VoxelDoor3D.BODY_META) else null
	if door != null and not is_instance_valid(door):
		door = null
	return {
		"door": door, "voxel_body": voxel_body, "shape": shape,
		"body": collider as RigidBody3D, "position": hit.position,
	}


static func _voxel_body_from_node(start: Node) -> VoxelBody3D:
	var node := start
	while node != null:
		if node is VoxelBody3D:
			return node as VoxelBody3D
		node = node.get_parent()
	return null


static func _shape_from_hit(
	voxel_body: VoxelBody3D, collider: CollisionObject3D, hit: Dictionary
) -> VoxelShape3D:
	var shape_index := int(hit.get("shape", -1))
	if shape_index >= 0:
		var owner_id := collider.shape_find_owner(shape_index)
		var collision_owner := collider.shape_owner_get_owner(owner_id)
		if collision_owner is CollisionShape3D:
			var collision_shape := collision_owner as CollisionShape3D
			var exact := collision_shape.get_meta("voxel_shape") as VoxelShape3D \
				if collision_shape.has_meta("voxel_shape") else null
			if exact != null and is_instance_valid(exact):
				return exact
	var point := hit.get("position", Vector3.ZERO) as Vector3
	var best: VoxelShape3D
	var best_distance := INF
	for candidate: VoxelShape3D in voxel_body.get_shapes():
		if not candidate.world_bounds().grow(candidate.voxel_size * 0.75).has_point(point):
			continue
		var distance := candidate.world_bounds().get_center().distance_squared_to(point)
		if distance < best_distance:
			best = candidate
			best_distance = distance
	return best


static func grab_force_limit_for_mass(mass: float) -> float:
	return minf(GRAB_MAX_FORCE, maxf(mass, 0.001) * GRAB_MAX_ACCELERATION)


static func grab_movement_scale_for_mass(mass: float) -> float:
	if mass <= GRAB_COMFORTABLE_MASS:
		return 1.0
	return clampf(sqrt(GRAB_COMFORTABLE_MASS / mass), GRAB_MIN_MOVE_SCALE, 1.0)


func _ensure_grab_line() -> void:
	var hud := get_node_or_null("../HUD")
	if hud == null:
		return
	_grab_line = Line2D.new()
	_grab_line.name = "GrabLine"
	_grab_line.width = 2.0
	_grab_line.default_color = Color(0.86, 0.94, 1.0, 0.82)
	_grab_line.antialiased = true
	_grab_line.z_index = 20
	_grab_line.visible = false
	hud.add_child(_grab_line)


func _update_grab_line() -> void:
	if _grab_line == null or _grabbed_shape == null or not is_instance_valid(_grabbed_shape):
		return
	var point := _grabbed_shape.to_global(_grab_shape_local_point)
	if camera.is_position_behind(point):
		_grab_line.visible = false
		return
	var screen_center := get_viewport().get_visible_rect().size * 0.5
	_grab_line.points = PackedVector2Array([screen_center, camera.unproject_position(point)])
	_grab_line.visible = true


func _update_interaction_hint() -> void:
	if interaction_label == null:
		return
	if _driving_vehicle != null and is_instance_valid(_driving_vehicle):
		interaction_label.text = "E · exit  |  WASD drive  |  Wheel zoom/interior  |  Space brake  |  %.0f km/h" \
			% _driving_vehicle.speed_kmh()
		return
	if _grabbed_voxel_body != null and is_instance_valid(_grabbed_voxel_body):
		var mass := _grabbed_body.mass if _grabbed_body != null else 0.0
		if _grabbed_door != null and is_instance_valid(_grabbed_door) \
				and _grabbed_door.is_latched():
			interaction_label.text = "Door is latched · destroy the panel"
		elif mass > GRAB_MAX_FORCE / maxf(_gravity, 0.001):
			interaction_label.text = "Holding %.0f kg · too heavy to lift" % mass
		else:
			interaction_label.text = "Holding %.0f kg · release right click" % mass
		return
	if _grabbed_door != null and is_instance_valid(_grabbed_door):
		interaction_label.text = (
			"Door is latched · destroy the panel" if _grabbed_door.is_latched()
			else "Holding door · release right click"
		)
		return
	var nearby_vehicle := _nearest_vehicle()
	if nearby_vehicle != null:
		interaction_label.text = "E · drive %s" % nearby_vehicle.display_name
		return
	var pick := _pick_grabbable()
	if pick.is_empty():
		interaction_label.text = ""
		return
	var door := pick.get("door") as VoxelDoor3D
	if door != null and is_instance_valid(door):
		interaction_label.text = (
			"Door is latched · destroy the panel" if door.is_latched()
			else "Right click · grab door"
		)
	else:
		var rigid := (pick.voxel_body as VoxelBody3D).get_physics_body() as RigidBody3D
		interaction_label.text = "Right click · grab%s" % (
			" (%.0f kg)" % rigid.mass if rigid != null else ""
		)


func _toggle_vehicle() -> void:
	if _driving_vehicle != null:
		_leave_vehicle(true)
		return
	var vehicle := _nearest_vehicle()
	if vehicle == null:
		return
	_end_grab()
	if not vehicle.set_driver(self):
		return
	_driving_vehicle = vehicle
	_saved_vehicle_entry_position = global_position
	if _collision_restore_delay <= 0:
		_saved_collision_layer = collision_layer
		_saved_collision_mask = collision_mask
	_collision_restore_delay = 0
	_saved_camera_position = camera.position
	_saved_camera_rotation = camera.rotation
	_saved_camera_fov = camera.fov
	collision_layer = 0
	collision_mask = 0
	velocity = Vector3.ZERO
	# Use world yaw, not chassis-relative yaw: keep the view where the player left it even if the
	# tank turns underneath. Start by facing the vehicle's current direction.
	_vehicle_camera.fit(vehicle, _saved_camera_fov)
	_vehicle_camera.snap(camera, vehicle)
	_update_interaction_hint()


## Restores collision after exiting a vehicle. Must run in a `_physics_process` after the exit
## teleport, never in the same one; see the comment in `_leave_vehicle`.
func _apply_pending_collision_restore() -> bool:
	if _collision_restore_delay <= 0:
		return true
	_collision_restore_delay -= 1
	if _collision_restore_delay > 0:
		# Keep the capsule still and disabled this frame so Jolt records the exit pose. This is
		# 1/60 s without gravity: invisible to the player, and it prevents pushing the vehicle.
		return false
	collision_layer = _saved_collision_layer
	collision_mask = _saved_collision_mask
	return true


func _leave_vehicle(place_player: bool) -> void:
	var vehicle := _driving_vehicle
	_driving_vehicle = null
	if vehicle != null and is_instance_valid(vehicle):
		vehicle.clear_driver(self)
	# The capsule stays attached to the seat inside the hull for the whole ride. Restoring collision
	# in the same frame as the teleport made Jolt treat that jump as kinematic motion: the body swept
	# through the vehicle from inside to outside and pushed it along (measured peak: 220 m/s, higher
	# for a more distant exit). This sent the tank flying into the ground. Place the player while
	# collision is still disabled and restore it during the next `_physics_process`, after Jolt has
	# recorded the correct pose.
	# `_safe_vehicle_exit` casts with `collision_mask`, so restore the mask while finding a position.
	collision_mask = _saved_collision_mask
	if place_player and vehicle != null and is_instance_valid(vehicle):
		var exit_position := _safe_vehicle_exit(vehicle)
		global_position = exit_position
		var facing := vehicle.forward_direction()
		facing.y = 0.0
		look_at(exit_position + (facing.normalized() if facing.length_squared() > 0.01 \
			else Vector3.FORWARD), Vector3.UP)
	collision_mask = 0
	_collision_restore_delay = 2
	camera.top_level = false
	camera.position = _saved_camera_position if _saved_camera_position != Vector3.ZERO \
		else _camera_rest_position
	camera.rotation = _saved_camera_rotation
	camera.fov = _saved_camera_fov
	camera.reset_physics_interpolation()
	velocity = Vector3.ZERO
	_update_interaction_hint()


func on_vehicle_removed(vehicle: VoxelVehicle3D) -> void:
	if vehicle == _driving_vehicle:
		_leave_vehicle(true)


func on_vehicle_flooded(vehicle: VoxelVehicle3D) -> void:
	if vehicle == _driving_vehicle:
		_leave_vehicle(true)


func _safe_vehicle_exit(vehicle: VoxelVehicle3D) -> Vector3:
	var space := get_world_3d().direct_space_state
	var exclusions: Array[RID] = [get_rid()]
	exclusions.append_array(vehicle.get_camera_collision_rids())
	var clearance_exclusions: Array[RID] = [get_rid()]
	var boundary: Node = null
	if vehicle.voxel_owner != null and is_instance_valid(vehicle.voxel_owner):
		var world := vehicle.voxel_owner.get_parent()
		if world != null:
			boundary = world.get_node_or_null("TeardownBoundary")
	var bounds := vehicle.get_world_bounds()
	var ray_depth := maxf(10.0, bounds.size.y + 6.0)
	for high_point in vehicle.get_exit_candidates():
		if boundary != null and boundary.has_method("contains_world_point") \
				and not bool(boundary.call("contains_world_point", high_point)):
			continue
		var ray := PhysicsRayQueryParameters3D.create(
			high_point, high_point - Vector3.UP * ray_depth
		)
		ray.exclude = exclusions
		ray.collision_mask = collision_mask
		var hit := space.intersect_ray(ray)
		if not hit.is_empty() and (hit.normal as Vector3).dot(Vector3.UP) >= 0.45:
			var grounded := (hit.position as Vector3) + Vector3.UP * 0.055
			if _vehicle_exit_is_clear(grounded, clearance_exclusions):
				return grounded
		if _water == null or not is_instance_valid(_water):
			_find_water()
		if _water != null:
			var water_sample := _water.sample_surface(high_point)
			if not water_sample.is_empty():
				var swimming_exit := Vector3(
					high_point.x,
					float(water_sample.surface_y) - SWIM_ORIGIN_DEPTH + 0.12,
					high_point.z
				)
				if _vehicle_exit_is_clear(swimming_exit, clearance_exclusions):
					return swimming_exit
	# The entry point was clear when the player got in, but after driving for a while the vehicle
	# may be parked directly on top of it. Returning there without checking placed the capsule
	# inside the compound; Jolt resolved the penetration by launching the player and slamming the
	# vehicle into the ground. This was especially visible with the tank: its large hull blocks the
	# first seven candidates, so this fallback is used more often.
	if _vehicle_exit_is_clear(_saved_vehicle_entry_position, clearance_exclusions):
		return _saved_vehicle_entry_position
	# Last resort: above the compound roof. It is clear by construction—the bounds' top plus 1.8 m—
	# so the player falls onto the vehicle instead of spawning inside it.
	var candidates := vehicle.get_exit_candidates()
	return candidates[candidates.size() - 1]


func _vehicle_exit_is_clear(position: Vector3, exclusions: Array[RID]) -> bool:
	var collision := get_node_or_null("Collision") as CollisionShape3D
	if collision == null or collision.shape == null:
		return true
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = collision.shape
	query.transform = Transform3D(Basis.IDENTITY, position) * collision.transform
	query.collision_mask = collision_mask
	query.exclude = exclusions
	query.collide_with_areas = false
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func is_driving_vehicle() -> bool:
	return _driving_vehicle != null and is_instance_valid(_driving_vehicle)


func _nearest_vehicle() -> VoxelVehicle3D:
	var best: VoxelVehicle3D
	var best_distance := VoxelVehicle3D.ENTER_DISTANCE
	for node in get_tree().get_nodes_in_group(VoxelVehicle3D.GROUP):
		var vehicle := node as VoxelVehicle3D
		if vehicle == null or not is_instance_valid(vehicle) or not vehicle.can_enter(
			global_position, VoxelVehicle3D.ENTER_DISTANCE
		):
			continue
		var distance := vehicle.get_seat_position().distance_to(global_position)
		if distance < best_distance:
			best = vehicle
			best_distance = distance
	return best


## RIDs that the orbit camera must not treat as obstacles: the player and the vehicle they are
## driving. This lives here because the player knows its own body.
func _camera_exclusions() -> Array[RID]:
	var exclusions: Array[RID] = [get_rid()]
	if _driving_vehicle != null and is_instance_valid(_driving_vehicle):
		exclusions.append_array(_driving_vehicle.get_camera_collision_rids())
	return exclusions


## Cannon: direct shot. Opens a crater where it hits.
func _fire() -> void:
	var from := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from - camera.global_basis.z * RANGE)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	# Nudge slightly into the surface: impact lands on the voxel face, and without this the crater
	# center would sit half a voxel outside and remove less material than intended.
	var center: Vector3 = hit["position"] - (hit["normal"] as Vector3) * Vox.VOXEL_SIZE * 0.5
	Explosion.at(self, center, CANON["radius"], CANON["energy"])


## Bomb: launches from the camera and explodes on contact.
func _throw() -> void:
	var bomb := Bomb.new()
	bomb.radius = BOMBA["radius"]
	bomb.energy = BOMBA["energy"]
	get_parent().add_child(bomb)
	bomb.global_position = camera.global_position - camera.global_basis.z * 1.0
	bomb.linear_velocity = velocity - camera.global_basis.z * THROW_SPEED


func _connect_voxel_impacts() -> void:
	for world: VoxelWorld3D in get_tree().get_nodes_in_group(VoxelWorld3D.GROUP):
		if not world.voxel_impact.is_connected(_on_voxel_impact):
			world.voxel_impact.connect(_on_voxel_impact)


func _on_voxel_impact(center: Vector3, removed_voxels: int, blast_radius: float) -> void:
	var distance_falloff := clampf(1.0 - camera.global_position.distance_to(center) / 36.0, 0.0, 1.0)
	var strength := clampf(sqrt(float(removed_voxels)) / 34.0 + blast_radius / 8.0, 0.08, 0.72)
	_impact_trauma = minf(1.0, _impact_trauma + strength * distance_falloff)
