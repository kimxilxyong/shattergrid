extends SceneTree
## Measure the map's actual size to determine whether the four moving clipmaps can be replaced by
## a single static volume for the entire map, as Teardown does (1252x128x1252, 3 mips).

var XML := VoxelProjectPaths.teardown_map_path()


func _initialize() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	# No collision: only the bounds matter here, and collision adds another 15 seconds.
	TeardownMapImporter.import_map(world, XML, Vector3.INF, INF, Vector3.ZERO, false)
	var bounds := AABB()
	var first := true
	var shapes := 0
	for body in world.get_children():
		if not body is VoxelBody3D:
			continue
		for shape in (body as VoxelBody3D).get_shapes():
			if shape.voxel_count() == 0:
				continue
			shapes += 1
			# `world_bounds()` uses `global_transform`, but Shapes are not in the tree during import;
			# compose the transform manually, as `clipmap_cost_probe` does.
			var to_world: Transform3D = (body as Node3D).transform * shape.transform
			var size := Vector3(shape.data.get_dimensions()) * shape.voxel_size
			var local := AABB(-size * 0.5, size)
			var minimum := Vector3(INF, INF, INF)
			var maximum := Vector3(-INF, -INF, -INF)
			for corner_index in 8:
				var corner := local.position + Vector3(
					local.size.x if corner_index & 1 else 0.0,
					local.size.y if corner_index & 2 else 0.0,
					local.size.z if corner_index & 4 else 0.0
				)
				var world_corner: Vector3 = to_world * corner
				minimum = minimum.min(world_corner)
				maximum = maximum.max(world_corner)
			var box := AABB(minimum, maximum - minimum)
			bounds = box if first else bounds.merge(box)
			first = false
	print("shapes=%d" % shapes)
	print("map extent: %.1f x %.1f x %.1f m  from %s" % [
		bounds.size.x, bounds.size.y, bounds.size.z, bounds.position
	])
	for cell: float in [0.1, 0.2, 0.4]:
		var cells: Vector3 = (bounds.size / cell).ceil()
		# One R8UI texel stores 2x2x2 cells, as it does now.
		var texels: Vector3 = (cells / 2.0).ceil()
		var bytes: float = texels.x * texels.y * texels.z
		print("  %.2f m cells -> %d x %d x %d texels = %.0f MB (with mips %.0f MB)" % [
			cell, texels.x, texels.y, texels.z, bytes / 1048576.0, bytes * 1.14 / 1048576.0
		])
	print("current: 4 levels x 2 layers x 256^3 = %.0f MB" % (8.0 * 256 * 256 * 256 / 1048576.0))
	quit()
