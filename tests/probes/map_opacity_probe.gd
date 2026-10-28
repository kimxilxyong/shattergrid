extends SceneTree
## Count how many map voxels end up translucent and identify their physical material.
##
## The shader determines glass per voxel using `alpha < 0.995`, so a transparent-looking wall can
## only come from the palette. Compare final opacity with Teardown's index band to see whether glass
## appears where it should (windows) or is consuming structural material.

var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 25.0, Vector3.ZERO, false)

	var por_material := {}
	var total := 0
	var translucidos := 0
	for body in world.get_children():
		if not (body is VoxelBody3D):
			continue
		for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
			var counts := _histogram(shape.data)
			var imap: PackedByteArray = shape.palette.get_meta("imap", PackedByteArray())
			for index: int in counts:
				var opacity := float(shape.palette.get_material(index).get("opacity", 1.0))
				total += counts[index]
				if opacity >= 0.995:
					continue
				translucidos += counts[index]
				var key := "%s@%.2f" % [TeardownPalette.material_name(index, imap), opacity]
				por_material[key] = int(por_material.get(key, 0)) + counts[index]

	print("VOXELS total=%d translucent=%d (%.2f %%)"
		% [total, translucidos, 100.0 * translucidos / maxi(1, total)])
	var claves := por_material.keys()
	claves.sort_custom(func(a, b): return por_material[a] > por_material[b])
	for key: String in claves.slice(0, 15):
		print("  %-24s %d" % [key, por_material[key]])
	quit(0)


func _histogram(data: VoxelShapeData) -> Dictionary:
	var counts := {}
	var size := data.get_dimensions()
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var index := data.get_cell(x, y, z)
				if index != 0:
					counts[index] = int(counts.get(index, 0)) + 1
	return counts
