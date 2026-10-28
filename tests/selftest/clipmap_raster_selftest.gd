extends SceneTree
## Compare the C++ clipmap rasterizer with the GDScript loop it replaces, and measure its runtime
## on the full map.
##
## The fine level must match bit-for-bit. Coarse levels use macrocells and are intentionally
## conservative—they overmark, never undermark—so a superset is required there.

var XML := VoxelProjectPaths.teardown_map_path()
## Use a small grid for comparison: counting bits in the real 16 MB grid from GDScript takes longer
## than everything being measured. The same code paths are exercised.
const LOGICAL := 64
const PACKED := 32
const FULL_LOGICAL := 512
const FULL_PACKED := 256
const BASE_CELL := 0.1


func _initialize() -> void:
	# SceneTree has not entered the tree during `_initialize`. Importing here caused global-transform
	# queries and the initial prop sleep to emit thousands of errors without
	# that caused the test to fail. The deferred path exercises the same importer in its actual runtime state.
	_run.call_deferred()


func _run() -> void:
	var world: VoxelWorld3D = VoxelWorld3D.new()
	root.add_child(world)

	print("--- correctness, 25 m crop ---")
	TeardownMapImporter.import_map(world, XML, Vector3.INF, 25.0, Vector3.ZERO, false)
	assert(world.physics_budget != null, "the importer must initialize its budget before _ready")
	var group := _collect(world)
	print("shapes=%d voxels=%d" % [group.shapes.size(), _count_voxels(group)])
	# A Shape uses the macrocell path when the level cell covers its 8 voxels. With a 10 cm cell,
	# these are Shapes with voxels <= 1.25 cm, which exist in Teardown: `scale` in the
	# XML is the voxel size multiplied by ten.
	var tiny := 0
	for size in group.voxel_sizes:
		if size <= BASE_CELL / 8.0:
			tiny += 1
	print("shapes with voxel <= 1.25 cm (use macrocells at level 0): %d" % tiny)
	# Center the origin on the geometry so level 0 is not empty.
	var origin := Vector3i(-LOGICAL / 2, -LOGICAL / 2, -LOGICAL / 2)
	for level in 4:
		var cell: float = BASE_CELL * float(1 << level)
		var fast: PackedByteArray = VoxelShapeData.rasterize_occupancy_level(
			group.shapes, group.transforms, group.voxel_sizes,
			origin, Vector3i.ONE * LOGICAL, cell, Vector3i.ONE * PACKED
		)
		var reference := _reference(group, origin, cell)
		var missing := 0
		var extra := 0
		var reference_bits := 0
		for index in reference.size():
			var a: int = reference[index]
			var b: int = fast[index]
			reference_bits += _popcount(a)
			missing += _popcount(a & ~b)
			extra += _popcount(b & ~a)
		# The important invariant for a shadow is not to lose occluders. Overmarking only thickens
		# the shadow; undermarking lets light pass through a wall.
		assert(missing == 0, "level %d is missing %d cells" % [level, missing])
		print("level %d cell=%.1f cm  reference=%d  missing=%d  extra=%d (+%.1f %%)" % [
			level, cell * 100.0, reference_bits, missing, extra,
			100.0 * extra / maxf(reference_bits, 1.0),
		])
		if level == 0 and tiny == 0:
			assert(fast == reference, "without tiny Shapes, level 0 must match exactly")

	print("--- performance, full map ---")
	# Do not reuse the World: its spatial indexes and caches retain references to registered Bodies,
	# as they should during gameplay. Freeing only the children created artificial dangling references
	# and hid the results behind cast errors.
	world.free()
	world = VoxelWorld3D.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, XML, Vector3.INF, 1.0e9, Vector3.ZERO, false)
	var full := _collect(world)
	var voxels := _count_voxels(full)
	var started := Time.get_ticks_usec()
	for level in 4:
		VoxelShapeData.rasterize_occupancy_level(
			full.shapes, full.transforms, full.voxel_sizes,
			Vector3i.ONE * (-FULL_LOGICAL / 2), Vector3i.ONE * FULL_LOGICAL,
			BASE_CELL * float(1 << level), Vector3i.ONE * FULL_PACKED
		)
	var elapsed := (Time.get_ticks_usec() - started) / 1000.0
	print("shapes=%d voxels=%d  4 levels in %.0f ms" % [full.shapes.size(), voxels, elapsed])
	print("previously in GDScript: 201000 ms  ->  %.0fx" % (201000.0 / maxf(elapsed, 1.0)))
	assert(elapsed < 3000.0, "still too expensive to enable by default")
	print("OK")
	quit()


## Compose this manually so rasterization explicitly uses the Body and Shape transforms.
func _collect(world: VoxelWorld3D) -> Dictionary:
	var group := {"shapes": [], "transforms": [], "voxel_sizes": PackedFloat32Array()}
	for body in world.get_children():
		if body is VoxelBody3D:
			for shape in (body as VoxelBody3D).get_shapes():
				if shape.voxel_count() == 0:
					continue
				group.shapes.append(shape.data)
				group.transforms.append((body as Node3D).transform * shape.transform)
				group.voxel_sizes.append(shape.voxel_size)
	return group


func _count_voxels(group: Dictionary) -> int:
	var total := 0
	for data: VoxelShapeData in group.shapes:
		total += data.get_occupied_count()
	return total


## The original loop from `_rasterize_shape_level`, unchanged, for reference.
func _reference(group: Dictionary, origin: Vector3i, cell_size: float) -> PackedByteArray:
	var target := PackedByteArray()
	target.resize(PACKED * PACKED * PACKED)
	for shape_index in group.shapes.size():
		var data: VoxelShapeData = group.shapes[shape_index]
		var transform: Transform3D = group.transforms[shape_index]
		var voxel_size: float = group.voxel_sizes[shape_index]
		var dimensions := data.get_dimensions()
		var plane := dimensions.x * dimensions.y
		for index in data.get_live_indices():
			var z := index / plane
			var rest := index - z * plane
			var y := rest / dimensions.x
			var x := rest - y * dimensions.x
			var local := (Vector3(x + 0.5, y + 0.5, z + 0.5) - Vector3(dimensions) * 0.5) \
				* voxel_size
			var world: Vector3 = transform * local
			var world_cell := Vector3i(
				floori(world.x / cell_size), floori(world.y / cell_size), floori(world.z / cell_size)
			)
			var logical := world_cell - origin
			if logical.x < 0 or logical.y < 0 or logical.z < 0 \
				or logical.x >= LOGICAL or logical.y >= LOGICAL or logical.z >= LOGICAL:
				continue
			var packed := logical / 2
			var bit := (logical.x & 1) | ((logical.y & 1) << 1) | ((logical.z & 1) << 2)
			target[packed.x + packed.y * PACKED + packed.z * PACKED * PACKED] |= 1 << bit
	return target


func _popcount(value: int) -> int:
	var total := 0
	while value != 0:
		total += value & 1
		value >>= 1
	return total
