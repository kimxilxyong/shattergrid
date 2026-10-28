extends SceneTree
## Import the entire map without cropping and report what is lost along the way and whether the atlas can handle it.
##
## Distinguishes two causes that look the same on screen: the importer discarding Shapes (radius or
## cell budget), or the brick atlas running out of space and the renderer failing to place them.
## Disable collision, which takes 96% of the time and adds nothing here.

var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	var started := Time.get_ticks_msec()
	var report := TeardownMapImporter.import_map(
		world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true
	)
	print("IMPORT_MS ", Time.get_ticks_msec() - started)
	print("REPORT ", JSON.stringify(report))

	# Teardown's walk-through scenery must reach Jolt with collision truly disabled; otherwise, it
	# creates invisible walls throughout the map.
	var sin_colision := 0
	var cables := 0
	for node in world.get_children():
		if node is VoxelBody3D and not (node as VoxelBody3D).collision_enabled:
			# A car's four visual wheels now share one Body without collision. The importer metric
			# has always counted Shapes, not Bodies, so compare the same unit.
			sin_colision += (node as VoxelBody3D).get_shapes().size()
		elif node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			cables += (node as MeshInstance3D).mesh.get_surface_count()
	assert(sin_colision == int(report.no_collide),
		"Shapes without collision %d != no_collide %d" % [sin_colision, report.no_collide])
	assert(int(report.ropes) == 0 or world.get_node_or_null("TeardownRopes") is VoxelRopes,
		"the cables did not reach the scene")
	assert(int(report.skipped_far) == 0 and int(report.skipped_budget) == 0,
		"the importer is discarding Shapes")
	print("CHECKS ok no_collision=%d cables=%d" % [sin_colision, report.ropes])

	var shapes := 0
	var bricks := 0
	var macros := 0
	for body in world.get_children():
		if body is VoxelBody3D:
			for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
				shapes += 1
				bricks += shape.data.get_occupied_macros().size()
				var macro := shape.data.get_macro_dimensions()
				macros += macro.x * macro.y * macro.z
	var per_layer := VoxelRenderSystem.BRICK_GRID_SIDE * VoxelRenderSystem.BRICK_GRID_SIDE
	var layers := (bricks * VoxelRenderSystem.BRICK_HEADROOM / 10 + per_layer - 1) / per_layer
	var cap := VoxelRenderSystem.MAX_ATLAS_DEPTH / 8
	print("ATLAS shapes=%d bricks=%d macroceldas=%d capas=%d tope=%d mb=%.1f"
		% [shapes, bricks, macros, layers, cap,
			per_layer * mini(layers, cap) * 512.0 / 1048576.0])

	# Packing the macrocell atlas is pure CPU work, so it can be repeated here without a GPU. A Shape
	# that does not fit stops rendering but keeps its collider: the signature of an "invisible wall."
	print("PACKER ", JSON.stringify(_simulate_packer(world)))
	quit(0)


func _simulate_packer(world: VoxelWorld3D) -> Dictionary:
	var sizes: Array[Vector3i] = []
	var max_x := 1
	var max_y := 1
	var volume := 0
	for body in world.get_children():
		if body is VoxelBody3D:
			for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
				var macro := shape.data.get_macro_dimensions()
				sizes.append(macro)
				max_x = maxi(max_x, macro.x)
				max_y = maxi(max_y, macro.y)
				volume += macro.x * macro.y * macro.z
	var atlas := VoxelRenderSystem._plan_atlas(
		max_x, max_y, volume * 4, VoxelRenderSystem.MAX_MACRO_ATLAS_CELLS, 512
	)
	var cursor := Vector3i.ZERO
	var shelf := 0
	var layer := 0
	var dropped := 0
	for size in sizes:
		if cursor.x + size.x > atlas.x:
			cursor = Vector3i(0, cursor.y + shelf, cursor.z)
			shelf = 0
		if cursor.y + size.y > atlas.y:
			cursor = Vector3i(0, 0, cursor.z + layer)
			layer = 0
		if cursor.z + size.z > atlas.z or cursor.x + size.x > atlas.x \
				or cursor.y + size.y > atlas.y:
			dropped += 1
			continue
		shelf = maxi(shelf, size.y)
		layer = maxi(layer, size.z)
		cursor = Vector3i(cursor.x + size.x, cursor.y, cursor.z)
	return {
		"atlas": "%dx%dx%d" % [atlas.x, atlas.y, atlas.z],
		"celdas": atlas.x * atlas.y * atlas.z,
		"volumen_util": volume,
		"shapes": sizes.size(),
		"invisibles_con_collider": dropped,
	}
