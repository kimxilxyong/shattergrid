extends SceneTree
## Import and batching regression. Does not require the licensed map or build voxels.

const XML := "res://tests/fixtures/water_map.xml"


func _initialize() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	var report := TeardownMapImporter.import_map(
		world, XML, Vector3.ZERO, INF, Vector3.ZERO, false
	)
	assert(int(report.water_surfaces) == 3, "the three surfaces were not imported")
	assert(int(report.water_triangles) == 6, "unexpected triangulation")
	assert(absf(float(report.water_area_m2) - 16.0) < 0.01, "incorrect water area")
	assert(int(report.authored_dynamic_bodies) == 1 \
		and int(report.imported_dynamic_bodies) == 1,
		"XML dynamic=true did not reach the Body's initial state")
	assert(int(report.density_overrides) == 1,
		"the authored density multiplier did not reach the Shape")
	var imported_prop: VoxelBody3D
	for candidate: VoxelBody3D in world.get_dynamic_bodies():
		imported_prop = candidate
		break
	assert(imported_prop != null and is_equal_approx(
		(imported_prop.get_shapes()[0] as VoxelShape3D).density_scale, 0.25
	), "the dynamic prop lost density=0.25")

	var water := world.get_node_or_null("TeardownWater") as VoxelWaterSystem
	assert(water != null, "the importer did not create VoxelWaterSystem")
	assert(water.mesh is ArrayMesh, "the water does not use ArrayMesh")
	assert((water.mesh as ArrayMesh).get_surface_count() == 1,
		"the map surfaces were not combined into one draw call")
	var shore := water.get_node_or_null("ShoreFoam") as MeshInstance3D
	assert(shore != null and shore.mesh is ArrayMesh \
		and (shore.mesh as ArrayMesh).get_surface_count() == 1,
		"the shorelines were not grouped into one foam strip")
	var arrays := (water.mesh as ArrayMesh).surface_get_arrays(0)
	assert((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == 12,
		"vertices were lost during grouping")
	assert((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() == 18,
		"incorrect water indices")
	var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	for index in 4:
		assert(is_equal_approx(vertices[index].y, 2.0),
			"Y rotation tilted a horizontal surface")

	var material := water.material_override as ShaderMaterial
	assert(material != null and material.shader != null, "water shader is missing")
	var normal_texture := material.get_shader_parameter("wave_normal") as Texture2D
	assert(normal_texture != null and normal_texture.get_width() == 128,
		"compact procedural normal is missing")
	var normal_image := normal_texture.get_image()
	var transpose_difference := 0.0
	for y in range(0, 128, 8):
		for x in range(0, 128, 8):
			var a := normal_image.get_pixel(x, y)
			var b := normal_image.get_pixel(y, x)
			transpose_difference += absf(a.r - b.r) + absf(a.b - b.b)
	assert(transpose_difference > 4.0,
		"the normal retains overly visible diagonal/square symmetry")
	water.set_reflections_enabled(false)
	assert(not bool(material.get_shader_parameter("reflections_enabled")),
		"the economical mode does not disable SSR")
	water.configure_environment(Color(0.2, 0.3, 0.4), Vector3.UP, Color(1, 0.8, 0.5))
	assert((material.get_shader_parameter("sky_reflection_color") as Vector3).is_equal_approx(
		Vector3(0.2, 0.3, 0.4)
	), "the fallback does not receive the map's sky")
	var surface := water.sample_surface(Vector3(10.0, 8.0, 20.0))
	assert(not surface.is_empty() and is_equal_approx(float(surface.surface_y), 2.0),
		"the physics query does not find the exact water height")
	assert(water.is_point_in_water(Vector3(10.0, 1.5, 20.0)) \
		and not water.is_point_in_water(Vector3(10.0, 0.5, 20.0)),
		"IsPointInWater does not respect depth=1")
	assert(water.sample_surface(Vector3(100.0, 0.0, 100.0)).is_empty(),
		"the water query extends beyond the polygon")
	water.emit_splash(Vector3(10.0, 2.02, 20.0), 1.0)
	water._process(0.1)
	assert(water.splash_count == 1 \
		and (water.get_node("WaterRipples") as MultiMeshInstance3D).visible,
		"entering the water does not create a splash and ripple in the pool")

	# A zero radius is used by several tests that only read the environment: it must not create
	# water or force the shader to compile in those helper processes.
	var empty_world := VoxelWorld3D.new()
	root.add_child(empty_world)
	var cropped := TeardownMapImporter.import_map(
		empty_world, XML, Vector3.ZERO, 0.0, Vector3.ZERO, false
	)
	assert(int(cropped.water_surfaces) == 0, "spatial cropping did not exclude the water")
	assert(empty_world.get_node_or_null("TeardownWater") == null,
		"an empty renderer was created outside the crop")
	print("WATER_SYSTEM_OK surfaces=%d triangles=%d area=%.1f water_draw=1 shore_draw=1 normal=128"
		% [report.water_surfaces, report.water_triangles, report.water_area_m2])
	quit()
