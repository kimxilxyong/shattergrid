extends SceneTree
## How much the greedy merge actually combines. The total face area divided by the area of emitted
## quads gives the merge factor. If it is ~1, little is being merged and the mesh could be reduced
## substantially; if it is high, the mesh is already minimal and should be baked or left as is.

var XML := VoxelProjectPaths.teardown_map_path()


func _initialize() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, XML, Vector3.INF, 60.0, Vector3.ZERO, false)
	var quads := 0
	var voxel_faces := 0.0
	for body in world.get_children():
		if not body is VoxelBody3D:
			continue
		for shape in (body as VoxelBody3D).get_shapes():
			if shape.data == null or shape.voxel_count() == 0:
				continue
			var block := VoxelBody3D.collision_block_for(shape)
			var mask := TeardownPalette.mask_for(shape)
			var area := shape.voxel_size * shape.voxel_size
			for macro: Vector3i in _blocks(shape, block):
				var faces := shape.data.build_macro_faces(
					macro, shape.voxel_size, block, 1, mask
				)
				quads += faces.size() / 6
				for i in range(0, faces.size(), 3):
					voxel_faces += (faces[i + 1] - faces[i]).cross(
						faces[i + 2] - faces[i]
					).length() * 0.5 / area
	print("quads=%d  caras de voxel cubiertas=%.0f  fusion=%.2fx" % [
		quads, voxel_faces, voxel_faces / maxf(quads, 1)
	])
	quit()


func _blocks(shape: VoxelShape3D, block: int) -> Array:
	var found := {}
	var d := shape.data.get_macro_dimensions()
	var plane := d.x * d.y
	for m in shape.data.get_occupied_macros():
		found[Vector3i((m % d.x) / block, ((m / d.x) % d.y) / block, (m / plane) / block)] = true
	return found.keys()
