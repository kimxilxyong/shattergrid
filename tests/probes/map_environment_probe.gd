extends SceneTree
## Checks that the map's `<environment>` reaches the report and that the property names used by
## `TeardownEnvironment.apply` actually exist in Godot.

var XML := VoxelProjectPaths.teardown_map_path()


func _initialize() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	# Radius 0: geometry is irrelevant; only the `<environment>` matters, as a child of the XML root.
	var report := TeardownMapImporter.import_map(world, XML, Vector3.ZERO, 0.0, Vector3.ZERO, false)
	var attributes: Dictionary = report.get("environment", {})
	assert(not attributes.is_empty(), "the report has no <environment>")
	print("ENVIRONMENT ", attributes)

	var environment := Environment.new()
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_depth_begin = 80.0
	environment.fog_depth_end = 280.0
	environment.fog_depth_curve = 6.0
	environment.fog_density = 1.0
	environment.fog_light_color = Color(0.3, 0.2, 0.08)
	assert(is_equal_approx(environment.fog_depth_end, 280.0))

	var sky := ProceduralSkyMaterial.new()
	sky.sky_top_color = Color(0.35, 0.17, 0.07)
	sky.ground_bottom_color = Color(0.25, 0.12, 0.05)
	var sun := DirectionalLight3D.new()
	sun.light_angular_distance = 4.5
	sun.basis = Basis.looking_at(Vector3(-0.58, -0.14, -0.80))
	assert(is_equal_approx(sun.light_angular_distance, 4.5))
	environment.sky = Sky.new()
	environment.sky.sky_material = PanoramaSkyMaterial.new()
	environment.sky_rotation.y = deg_to_rad(130.0)

	# Converted panorama: same sun reported by the converter, with 7.8° elevation and 143.9°
	# azimuth before applying `skyboxrot`.
	var panorama := XML.get_base_dir() + "/sky_%s.png" % String(attributes.skybox).get_basename()
	assert(FileAccess.file_exists(panorama), "converted panorama is missing")
	var image := Image.load_from_file(panorama)
	var direction := TeardownEnvironment.brightest_direction(image)
	var elevation := rad_to_deg(asin(direction.y))
	var azimuth := rad_to_deg(atan2(direction.x, -direction.z))
	print("SUN elevation=%.1f azimuth=%.1f" % [elevation, azimuth])
	assert(absf(elevation - 7.8) < 3.0, "the sun is not where the converter placed it")
	assert(absf(azimuth - 143.9) < 3.0, "incorrect azimuth")

	# Lighting passed to the voxel shader: sun tint and hemispheric ambient.
	var small := image.duplicate() as Image
	small.resize(128, 64, Image.INTERPOLATE_BILINEAR)
	var sun_color := TeardownEnvironment.brightest_color(small)
	var sky_ambient := TeardownEnvironment.average_color(small, 0, 32)
	var night := TeardownEnvironment.night_ambient_pair(sky_ambient)
	var graded_sky: Color = night.sky
	var ground_ambient: Color = night.ground
	print("SUN color=%.2f %.2f %.2f" % [sun_color.r, sun_color.g, sun_color.b])
	print("AMBIENT sky=%.3f %.3f %.3f ground=%.3f %.3f %.3f" % [
		graded_sky.r, graded_sky.g, graded_sky.b,
		ground_ambient.r, ground_ambient.g, ground_ambient.b,
	])
	# Rescaled to the shader's chosen night exposure.
	var mixed := (graded_sky + ground_ambient) * 0.5
	assert(absf(mixed.get_luminance() - TeardownEnvironment.AMBIENT_LEVEL) < 0.01,
		"exposure changed")
	# The sky must remain brighter than ground bounce to provide depth.
	assert(graded_sky.get_luminance() > ground_ambient.get_luminance(), "sky is darker than the ground")
	assert(graded_sky.b > graded_sky.r, "night ambience is not blue-tinted")
	# The lower HDRI hemisphere is brighter than the upper one; verify this to document why it is
	# not used as bounce lighting.
	assert(TeardownEnvironment.average_color(small, 32, 64).get_luminance()
		> sky_ambient.get_luminance(), "lower fog is no longer brighter")
	print("OK")
	quit()
