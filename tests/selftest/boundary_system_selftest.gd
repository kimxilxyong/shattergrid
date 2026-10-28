extends SceneTree
## Regression test for the full XML -> recentering -> collision -> localized reveal flow.

const XML := "res://tests/fixtures/boundary_map.xml"
var LEE_XML := VoxelProjectPaths.teardown_map_path()
const TeardownBoundary := preload("res://scripts/teardown/teardown_boundary_3d.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var level := Node3D.new()
	root.add_child(level)
	var player := CharacterBody3D.new()
	player.name = "Player"
	var player_collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	player_collision.shape = capsule
	player_collision.position.y = 0.9
	player.add_child(player_collision)
	level.add_child(player)
	var world := VoxelWorld3D.new()
	world.name = "VoxelWorld"
	world.show_diagnostics = false
	level.add_child(world)

	# Recenter the raw [0,10] square by subtracting (2,3), then add the offset (10,-5).
	var report := TeardownMapImporter.import_map(
		world, XML, Vector3(2.0, 0.0, 3.0), INF, Vector3(10.0, 0.0, -5.0), true
	)
	assert(int(report.boundary_vertices) == 4 and int(report.boundary_segments) == 4,
		"the boundary did not produce its four walls")
	assert(is_equal_approx(float(report.boundary_area_m2), 100.0),
		"the authored area changed when recentered")
	assert(is_equal_approx(float(report.boundary_width), 10.0) \
		and is_equal_approx(float(report.boundary_depth), 10.0),
		"the imported bounds are not 10 x 10")
	var boundary := world.get_node_or_null("TeardownBoundary") as TeardownBoundary
	assert(boundary != null, "TeardownBoundary3D was not created")
	assert(boundary.get_collision_segment_count() == 4,
		"the physics barrier does not match the polygon")
	var warning := boundary.get_node_or_null("BoundaryWarning") as MeshInstance3D
	assert(warning != null and warning.mesh is ArrayMesh \
		and (warning.mesh as ArrayMesh).get_surface_count() == 1,
		"the warning was not batched into one draw call")
	var warning_arrays := (warning.mesh as ArrayMesh).surface_get_arrays(0)
	assert((warning_arrays[Mesh.ARRAY_TEX_UV2] as PackedVector2Array).size() == 16,
		"each visual vertex lost its edge index")
	assert(boundary.contains_world_point(Vector3(13.0, 0.0, -3.0)) \
		and not boundary.contains_world_point(Vector3(19.0, 0.0, -3.0)),
		"point-in-polygon does not use recentered coordinates")

	player.global_position = Vector3(16.4, 0.0, -3.0)
	player.velocity = Vector3(5.0, 0.0, 0.0)
	boundary._process(0.1)
	assert(boundary.get_reveal_strength() > 0.2 and warning.visible,
		"the local section does not appear when approached")
	assert(absf(boundary.get_reveal_point().x - 18.0) < 0.05,
		"the warning does not mark where the player will collide")
	var warning_material := warning.material_override as ShaderMaterial
	assert(is_equal_approx(float(warning_material.get_shader_parameter("active_segment")), 1.0),
		"the shader did not discard distant edges")

	player.global_position = Vector3(13.0, 0.0, -6.4)
	await physics_frame
	var collision := player.move_and_collide(Vector3(0.0, 0.0, -4.0))
	assert(collision != null and player.global_position.z > -8.1,
		"the capsule passed through the invisible wall")

	# Census the real file without decoding its geometry (zero radius and collision disabled). This
	# also catches changes to Lee's boundary or confusion with shadowVolume.
	if FileAccess.file_exists(LEE_XML):
		var lee_world := VoxelWorld3D.new()
		lee_world.show_diagnostics = false
		root.add_child(lee_world)
		var lee := TeardownMapImporter.import_map(
			lee_world, LEE_XML, Vector3.INF, 0.0, Vector3.ZERO, false
		)
		assert(int(lee.boundary_vertices) == 31,
			"Lee no longer imports all 31 boundary vertices")
		assert(absf(float(lee.boundary_width) - 222.8) < 0.02 \
			and absf(float(lee.boundary_depth) - 217.9) < 0.02,
			"Lee's bounds do not match main.xml")
		var lee_boundary := lee_world.get_node("TeardownBoundary") as TeardownBoundary
		assert(lee_boundary.contains_world_point(Vector3.ZERO),
			"default recentering left the entry point outside Lee")
	print("BOUNDARY_SYSTEM_OK vertices=4 area=100 draw_calls=1 collision_segments=4 lee=31")
	quit()
