extends SceneTree
## Cost of rasterizing the shadow clipmap in GDScript, which leaves startup black with the full map.
## Measure a subset and extrapolate; measuring the whole map would hang.

var XML := VoxelProjectPaths.teardown_map_path()
const FULL_MAP_VOXELS := 79_344_317
const LEVELS := 4


func _initialize() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, XML, Vector3.INF, 25.0, Vector3.ZERO, false)

	# VoxelShape3D is not a tree node, so `global_transform` warns and returns identity; compose it
	# manually from the body's transform.
	var shapes: Array[VoxelShape3D] = []
	var transforms: Array[Transform3D] = []
	for body in world.get_children():
		if body is VoxelBody3D:
			for shape in (body as VoxelBody3D).get_shapes():
				shapes.append(shape)
				transforms.append((body as Node3D).transform * shape.transform)

	# Same loop body as `_rasterize_shape_level`, without writing to the texture.
	var target := PackedByteArray()
	target.resize(256 * 256 * 256)
	var cell_size := 0.1
	var voxels := 0
	var started := Time.get_ticks_usec()
	for shape_index in shapes.size():
		var shape: VoxelShape3D = shapes[shape_index]
		var dimensions := shape.data.get_dimensions()
		var plane := dimensions.x * dimensions.y
		var transform: Transform3D = transforms[shape_index]
		for index in shape.data.get_live_indices():
			var z := index / plane
			var rest := index - z * plane
			var y := rest / dimensions.x
			var x := rest - y * dimensions.x
			var local := (Vector3(x + 0.5, y + 0.5, z + 0.5) - Vector3(dimensions) * 0.5) \
				* shape.voxel_size
			var world_position: Vector3 = transform * local
			var cell := Vector3i(
				floori(world_position.x / cell_size),
				floori(world_position.y / cell_size),
				floori(world_position.z / cell_size)
			)
			var logical := Vector3i(posmod(cell.x, 512), posmod(cell.y, 512), posmod(cell.z, 512))
			var packed := logical / 2
			var bit := (logical.x & 1) | ((logical.y & 1) << 1) | ((logical.z & 1) << 2)
			target[packed.x + packed.y * 256 + packed.z * 65536] |= 1 << bit
			voxels += 1
	var elapsed := (Time.get_ticks_usec() - started) / 1e6

	var rate := voxels / elapsed
	print("CROP %d shapes  %d voxels  %.2f s  = %.2f M voxels/s" % [
		shapes.size(), voxels, elapsed, rate / 1e6
	])
	print("FULL MAP %d voxels x %d levels = %.0f s startup" % [
		FULL_MAP_VOXELS, LEVELS, FULL_MAP_VOXELS * LEVELS / rate
	])
	quit()
