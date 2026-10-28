class_name TeardownEnvironment
extends RefCounted
## Translates Teardown's `<environment>` into Godot lighting and preserves the result consumed by
## the voxel renderer. It does not depend on the main scene or `$...` paths.

const AMBIENT_LEVEL := 0.12
const DAYLIGHT_AMBIENT_LEVEL := 0.30
const GROUND_BOUNCE := 0.45
const NIGHT_BACKGROUND_ENERGY := 0.18
const NIGHT_TONEMAP_EXPOSURE := 0.78
const NIGHT_SUN_ENERGY := 0.22
const NIGHT_FOG_COLOR := Color(0.035, 0.055, 0.105, 1.0)
const NIGHT_MOON_COLOR := Color(0.42, 0.57, 0.92, 1.0)
const NIGHT_AMBIENT_TARGET := Color(0.075, 0.14, 0.31, 1.0)

var sun_direction := Vector3.INF
var sun_color := Color.WHITE
var ambient_sky := Color.BLACK
var ambient_ground := Color.BLACK


func apply(
	world_environment: WorldEnvironment,
	sun: DirectionalLight3D,
	voxel_world: VoxelWorld3D,
	attributes: Dictionary,
	folder: String,
	notice: String
) -> void:
	if attributes.is_empty() or world_environment == null or sun == null:
		return
	var environment := world_environment.environment
	var night := not "--daylight" in OS.get_cmdline_user_args()
	environment.background_energy_multiplier = NIGHT_BACKGROUND_ENERGY if night else 1.0
	environment.tonemap_exposure = NIGHT_TONEMAP_EXPOSURE if night else 1.0
	var tint := color_from_text(attributes.get("skyboxtint", "1 1 1"))
	var panorama := "%s/sky_%s.png" % [
		folder, attributes.get("skybox", "").get_file().get_basename()
	]
	if FileAccess.file_exists(panorama):
		var texture := ImageTexture.create_from_image(Image.load_from_file(panorama))
		var sky := PanoramaSkyMaterial.new()
		sky.panorama = texture
		environment.sky.sky_material = sky
		environment.sky_rotation.y = deg_to_rad(float(attributes.get("skyboxrot", "0")))
		_aim_sun_at_brightest(sun, texture.get_image(), environment.sky_rotation.y, notice)
	else:
		var sky := environment.sky.sky_material as ProceduralSkyMaterial
		if night:
			sky.sky_top_color = Color(0.006, 0.012, 0.035)
			sky.sky_horizon_color = Color(0.025, 0.055, 0.12)
			sky.ground_horizon_color = Color(0.018, 0.032, 0.064)
			sky.ground_bottom_color = Color(0.004, 0.007, 0.015)
		else:
			sky.sky_top_color = tint * 0.35
			sky.sky_horizon_color = tint
			sky.ground_horizon_color = tint * 0.6
			sky.ground_bottom_color = tint * 0.25

	var fog := floats_from_text(attributes.get("fogParams", ""))
	if fog.size() == 4:
		environment.fog_mode = Environment.FOG_MODE_DEPTH
		environment.fog_depth_begin = fog[0]
		environment.fog_depth_end = fog[1]
		environment.fog_density = fog[2]
		environment.fog_depth_curve = fog[3]
	var authored_fog := color_from_text(attributes.get("fogColor", "1 1 1"))
	environment.fog_light_color = authored_fog.lerp(NIGHT_FOG_COLOR, 0.88) \
		if night else authored_fog
	environment.fog_sky_affect = 0.16 if night else 0.0
	var ambient := color_from_text(attributes.get("constant", "0 0 0"))
	if night:
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_color = NIGHT_MOON_COLOR
		environment.ambient_light_energy = AMBIENT_LEVEL
	else:
		environment.ambient_light_color = ambient
		environment.ambient_light_energy = maxf(ambient.r, maxf(ambient.g, ambient.b))

	sun.light_energy = float(attributes.get("sunBrightness", "1")) * (
		NIGHT_SUN_ENERGY if night else 1.0
	)
	if night:
		sun_color = NIGHT_MOON_COLOR
		sun.light_color = sun_color
	sun.light_angular_distance = float(attributes.get("sunSpread", "0")) * 90.0
	var water := voxel_world.get_node_or_null("TeardownWater") as VoxelWaterSystem
	if water != null:
		var reflected_sky := tint * 0.38
		if ambient_sky.get_luminance() > 0.001:
			reflected_sky = ambient_sky * 1.35
		var water_sun_direction := sun_direction \
			if sun_direction != Vector3.INF else sun.global_basis.z
		water.configure_environment(
			reflected_sky, water_sun_direction, sun_color * sun.light_energy
		)


func _aim_sun_at_brightest(
	sun: DirectionalLight3D, panorama: Image, sky_rotation: float, notice: String
) -> void:
	var image := panorama.duplicate() as Image
	image.resize(128, 64, Image.INTERPOLATE_BILINEAR)
	var direction := Basis(Vector3.UP, sky_rotation) * brightest_direction(panorama)
	sun.basis = Basis.looking_at(-direction)
	sun_direction = direction
	sun_color = brightest_color(image)
	sun.light_color = sun_color
	var source_sky := average_color(image, 0, image.get_height() / 2)
	if "--daylight" in OS.get_cmdline_user_args():
		var source_ground := source_sky * GROUND_BOUNCE
		var source_level := (
			source_sky.get_luminance() + source_ground.get_luminance()
		) * 0.5
		var daylight_scale := DAYLIGHT_AMBIENT_LEVEL / maxf(source_level, 0.001)
		ambient_sky = source_sky * daylight_scale
		ambient_ground = source_ground * daylight_scale
	else:
		var ambient := night_ambient_pair(source_sky)
		ambient_sky = ambient.sky
		ambient_ground = ambient.ground
	print("[%s] sun elevation %.1f°, azimuth %.1f°" % [
		notice,
		rad_to_deg(asin(direction.y)),
		rad_to_deg(atan2(direction.x, -direction.z)),
	])


static func night_ambient_pair(source_sky: Color) -> Dictionary:
	var sky := source_sky.lerp(NIGHT_AMBIENT_TARGET, 0.78)
	var ground := sky * GROUND_BOUNCE * Color(0.62, 0.72, 0.92, 1.0)
	var level := (sky.get_luminance() + ground.get_luminance()) * 0.5
	var scale := AMBIENT_LEVEL / maxf(level, 0.001)
	return {"sky": sky * scale, "ground": ground * scale}


static func brightest_color(image: Image) -> Color:
	var best := Color.BLACK
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if pixel.r + pixel.g + pixel.b > best.r + best.g + best.b:
				best = pixel
	var peak := maxf(best.r, maxf(best.g, best.b))
	if peak <= 0.0:
		return Color.WHITE
	return (best / peak).srgb_to_linear()


static func average_color(image: Image, from_row: int, to_row: int) -> Color:
	var total := Color(0, 0, 0)
	var count := 0
	for y in range(from_row, to_row):
		for x in image.get_width():
			total += image.get_pixel(x, y).srgb_to_linear()
			count += 1
	return total / maxi(count, 1)


static func brightest_direction(panorama: Image) -> Vector3:
	var image := panorama.duplicate() as Image
	image.resize(128, 64, Image.INTERPOLATE_BILINEAR)
	var best := Vector2i.ZERO
	var best_luminance := -1.0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			var luminance := pixel.r + pixel.g + pixel.b
			if luminance > best_luminance:
				best_luminance = luminance
				best = Vector2i(x, y)
	var theta := (best.y + 0.5) / float(image.get_height()) * PI
	var phi := (best.x + 0.5) / float(image.get_width()) * TAU
	return Vector3(sin(theta) * sin(phi), cos(theta), sin(theta) * -cos(phi))


static func color_from_text(text: String) -> Color:
	var parts := floats_from_text(text)
	if parts.size() < 3:
		return Color.WHITE
	return Color(parts[0], parts[1], parts[2])


static func floats_from_text(text: String) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for part in text.split(" ", false):
		values.append(float(part))
	return values
