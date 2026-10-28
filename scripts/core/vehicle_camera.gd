class_name VehicleCamera
extends RefCounted
## World of Tanks-style arcade aiming camera, independent of the on-foot player.
##
## Rig rules, in order of importance:
##  1. The pivot inherits only the hull POSITION and yaw. Chassis roll and pitch are discarded:
##     every bump used to rotate the entire base and move the pivot, indirectly shaking the reticle
##     even when orientation was not smoothed.
##  2. Height is INSIDE the pivot, not a world offset added after the orbit. This keeps framing the
##     same at any pitch and makes the reticle pass through the orbit target.
##  3. Yaw is absolute in world space: turning the tank does not pull the view along.

const DISTANCE := 6.2
const MAX_DISTANCE := 9.0
const ZOOM_STEP := 0.9
const HEIGHT := 2.0
const SMOOTH := 11.0
const ZOOM_SMOOTH := 13.0
const COCKPIT_BLEND_START := 1.45
const COCKPIT_BLEND_END := 0.45
const COCKPIT_FOV := 82.0
const PITCH_MIN := -0.42
const PITCH_MAX := 0.72

## Reference FOV for sensitivity. As the actual FOV moves away from this value, the mouse moves
## fewer radians per pixel; without this, the same gesture cannot aim at both near and far targets.
const SENSITIVITY_REFERENCE_FOV := 78.0

var yaw := 0.0
var pitch := 0.12
var distance := DISTANCE
var target_distance := DISTANCE
var max_distance := MAX_DISTANCE
var height := HEIGHT
var fov := 90.0


## A car fits within the default 6.2 m; a tank is 7.8 m across the hull and 9.6 m with the cannon,
## so the fixed camera distance placed the camera inside the vehicle. Fit to the actual footprint—
## including turret and barrel—once, when entering.
func fit(vehicle: VoxelVehicle3D, fallback_fov: float) -> void:
	var bounds := vehicle.get_world_bounds()
	var span := maxf(bounds.size.x, bounds.size.z)
	var profile := vehicle.get_camera_profile()
	var authored_distance := float(profile.get("distance", -1.0))
	var authored_height := float(profile.get("height", -1.0))
	var authored_max := float(profile.get("max_distance", -1.0))
	var authored_fov := float(profile.get("fov", -1.0))
	target_distance = authored_distance if authored_distance > 0.0 \
		else clampf(span * 0.95, DISTANCE, 16.0)
	max_distance = authored_max if authored_max > 0.0 \
		else maxf(MAX_DISTANCE, target_distance * 1.6)
	height = authored_height if authored_height > 0.0 else maxf(HEIGHT, bounds.size.y * 0.9)
	fov = authored_fov if authored_fov > 0.0 else fallback_fov
	distance = target_distance


## Places the camera without smoothing when entering a vehicle.
func snap(camera: Camera3D, vehicle: VoxelVehicle3D) -> void:
	yaw = yaw_from_forward(vehicle.forward_direction())
	pitch = 0.12
	distance = target_distance
	camera.top_level = true
	var aim := aim_direction(yaw, pitch)
	camera.global_position = pivot(vehicle.get_camera_pivot(vehicle.global_transform), height) \
		- aim * distance
	camera.look_at(camera.global_position + aim * 100.0, Vector3.UP)
	camera.fov = fov
	camera.reset_physics_interpolation()


## Returns `true` if the event belonged to the orbit camera and was consumed.
func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		var amount := ZOOM_STEP * maxf(0.25, absf(button.factor))
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			target_distance = maxf(0.0, target_distance - amount)
			return true
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			target_distance = minf(max_distance, target_distance + amount)
			return true
		return false
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		var sensitivity := aim_sensitivity(fov)
		yaw -= motion.relative.x * sensitivity
		# The previous controller's vertical axis was inverted relative to the on-foot camera: moving
		# the mouse down put the camera under the car and forced the player to look upward.
		pitch = pitch_after_input(pitch, motion.relative.y, sensitivity)
		return true
	return false


func update(delta: float, camera: Camera3D, vehicle: VoxelVehicle3D, exclude: Array[RID]) -> void:
	var zoom_blend := 1.0 - exp(-ZOOM_SMOOTH * delta)
	distance = lerpf(distance, target_distance, zoom_blend)
	if absf(distance - target_distance) < 0.002:
		distance = target_distance
	var vehicle_transform := vehicle.get_global_transform_interpolated()
	var orbit := pivot(vehicle.get_camera_pivot(vehicle_transform), height)
	var aim := aim_direction(yaw, pitch)
	var exterior := orbit - aim * distance
	# The interior view uses the XML-authored `<location tags="player">`, not the center of mass.
	# Blending avoids a camera jump when the wheel crosses the final zoom step.
	var cockpit := vehicle.get_driver_view_from_transform(vehicle_transform)
	var interior_weight := 1.0 - smoothstep(COCKPIT_BLEND_END, COCKPIT_BLEND_START, distance)
	var desired := exterior.lerp(cockpit, interior_weight)
	var smoothed := camera.global_position.lerp(desired, 1.0 - exp(-SMOOTH * delta))
	if interior_weight < 0.999:
		# Resolving collision after smoothing prevents the spring from passing through a wall for a
		# couple of frames, even if the final destination was already correctly cropped.
		var query := PhysicsRayQueryParameters3D.create(orbit, smoothed)
		query.collide_with_areas = false
		query.exclude = exclude
		var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			smoothed = (hit.position as Vector3) + (hit.normal as Vector3) * 0.22
	# Framing is smoothed; aim direction is not. Lerp on orientation turns every hull bump into
	# reticle shake, making aiming impossible.
	camera.global_position = smoothed
	camera.look_at(camera.global_position + aim * 100.0, Vector3.UP)
	camera.fov = lerpf(fov, COCKPIT_FOV, interior_weight)


func is_interior() -> bool:
	return target_distance <= COCKPIT_BLEND_END


## Point shown at the center of the screen: the flat hull pivot, raised. Height is applied here,
## not after the orbit, or the vertical offset remains fixed in world space and framing slides when
## pitch changes.
static func pivot(flat_pivot: Vector3, pivot_height: float) -> Vector3:
	return flat_pivot + Vector3.UP * pivot_height


## Camera aim direction. Yaw is absolute in world space: turning the tank does not pull the reticle
## along and force the player to reposition the mouse on every turn.
static func aim_direction(camera_yaw: float, camera_pitch: float) -> Vector3:
	return Vector3(
		-sin(camera_yaw) * cos(camera_pitch),
		-sin(camera_pitch),
		-cos(camera_yaw) * cos(camera_pitch)
	).normalized()


static func yaw_from_forward(forward: Vector3) -> float:
	return atan2(-forward.x, -forward.z)


## Radians per mouse pixel. Scales with `tan(fov/2)` so the same gesture covers the same fraction
## of the screen: when zooming in, the world gets larger and each pixel must rotate less.
static func aim_sensitivity(current_fov: float) -> float:
	var reference := tan(deg_to_rad(SENSITIVITY_REFERENCE_FOV) * 0.5)
	var actual := tan(deg_to_rad(clampf(current_fov, 5.0, 170.0)) * 0.5)
	return 0.0022 * (actual / reference)


static func pitch_after_input(current: float, relative_y: float, sensitivity: float) -> float:
	return clampf(current + relative_y * sensitivity, PITCH_MIN, PITCH_MAX)
