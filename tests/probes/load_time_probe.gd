extends SceneTree
## Reparto del tiempo de arranque por fases, para saber que merece la pena hornear offline.

var XML := VoxelProjectPaths.teardown_map_path()


func _initialize() -> void:
	var total := Time.get_ticks_msec()
	var world := VoxelWorld3D.new()
	root.add_child(world)

	# 1. Import: read XML, decode .vox files, create VoxelShapeData and collision shapes.
	var t := Time.get_ticks_msec()
	var report := TeardownMapImporter.import_map(world, XML, Vector3.INF, 1.0e9, Vector3.ZERO, true)
	var import_ms := Time.get_ticks_msec() - t
	var shapes := []
	for body in world.get_children():
		if body is VoxelBody3D:
			for shape in (body as VoxelBody3D).get_shapes():
				if shape.voxel_count() > 0:
					shapes.append(shape)

	# 3. Pool de bricks: reservar y empaquetar todo el atlas.
	var pool := VoxelBrickPool.new()
	pool.configure(Vector3i(64, 64, 64))
	t = Time.get_ticks_msec()
	var bricks := 0
	for shape: VoxelShape3D in shapes:
		var base := pool.get_used()
		if pool.append_shape(shape.data).is_empty():
			break
		bricks += pool.get_used() - base
		pool.extract_uploads(base, pool.get_used() - base)
	var atlas_ms := Time.get_ticks_msec() - t

	# 4. Shadow clipmap: four levels covering the entire map.
	var group := {"shapes": [], "transforms": [], "voxel_sizes": PackedFloat32Array()}
	for shape: VoxelShape3D in shapes:
		group.shapes.append(shape.data)
		group.transforms.append((shape.get_parent() as Node3D).transform * shape.transform)
		group.voxel_sizes.append(shape.voxel_size)
	t = Time.get_ticks_msec()
	for level in 4:
		VoxelShapeData.rasterize_occupancy_level(
			group.shapes, group.transforms, group.voxel_sizes,
			Vector3i.ONE * -256, Vector3i.ONE * 512, 0.1 * float(1 << level), Vector3i.ONE * 256
		)
	var clipmap_ms := Time.get_ticks_msec() - t

	print("shapes=%d voxels=%s bricks=%d" % [
		shapes.size(), report.get("voxels", "?"), bricks
	])
	print("--- startup breakdown ---")
	print("import (with collision) %6d ms" % import_ms)
	print("  of which collision    %6s ms" % report.get("collision_ms", "?"))
	print("brick atlas             %6d ms" % atlas_ms)
	print("shadow clipmap          %6d ms" % clipmap_ms)
	print("--> ready to play       %6d ms" % (import_ms + atlas_ms + clipmap_ms))
	print("total probe time        %6d ms" % (Time.get_ticks_msec() - total))
	# Loading is intentionally slow: everything is built during import to avoid gameplay stutter.
	assert(shapes.size() > 0, "nothing was imported")
	print("OK")
	quit()
