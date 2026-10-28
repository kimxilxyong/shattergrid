extends SceneTree
## The two remaining load paths split between GDScript and C++: static collision faces and brick
## uploads to the atlas. Measure both and verify that batch brick uploads produce exactly the same
## result as the individual uploads they replace.

var XML := VoxelProjectPaths.teardown_map_path()
const BRICK := 8
const BRICK_CELLS := BRICK * BRICK * BRICK
## Collision mesh for the entire map, measured with the full sweep before cropping it to occupied
## macrocells. It contains 72 M triangles; keep the reference here because recalculating it cheaply
## from GDScript is impossible, and without it cropping could introduce holes unnoticed.
const REFERENCE_VERTICES := 216533046
const REFERENCE_CHECKSUM := 2452818599.3419


func _initialize() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, XML, Vector3.INF, 1.0e9, Vector3.ZERO, false)
	var shapes := []
	for body in world.get_children():
		if body is VoxelBody3D:
			for shape in (body as VoxelBody3D).get_shapes():
				if shape.voxel_count() > 0:
					shapes.append(shape)
	print("shapes=%d" % shapes.size())

	print("--- collision faces ---")
	var blocks_usec := 0
	var faces_usec := 0
	var block_count := 0
	# Fingerprint of the mesh delivered to Jolt. Cropping the sweep to occupied macrocells cannot
	# change a single triangle—the skipped cells are air—so the result must be identical before and
	# after. This is the only check distinguishing correct cropping from a floor with holes the
	# player can fall through.
	var vertices := 0
	var checksum := 0.0
	var masked_vertices := 0
	var masked_usec := 0
	var empty_blocks := 0
	for shape: VoxelShape3D in shapes:
		var block := VoxelBody3D.collision_block_for(shape)
		var started := Time.get_ticks_usec()
		var macros := _blocks(shape, block)
		blocks_usec += Time.get_ticks_usec() - started
		var mask := TeardownPalette.mask_for(shape)
		for macro: Vector3i in macros:
			started = Time.get_ticks_usec()
			var faces := shape.data.build_macro_faces(macro, shape.voxel_size, block, 1)
			faces_usec += Time.get_ticks_usec() - started
			block_count += 1
			vertices += faces.size()
			for point: Vector3 in faces:
				checksum += absf(point.x) + absf(point.y) + absf(point.z)
			started = Time.get_ticks_usec()
			var walkable := shape.data.build_macro_faces(macro, shape.voxel_size, block, 1, mask)
			masked_usec += Time.get_ticks_usec() - started
			masked_vertices += walkable.size()
			if walkable.is_empty():
				empty_blocks += 1
	print("bloques=%d  listar=%.0f ms  caras=%.0f ms" % [
		block_count, blocks_usec / 1000.0, faces_usec / 1000.0
	])
	print("HUELLA vertices=%d checksum=%.4f" % [vertices, checksum])
	assert(vertices == REFERENCE_VERTICES, "macrocell cropping changed the collision mesh")
	assert(is_equal_approx(checksum, REFERENCE_CHECKSUM), "faces changed positions")
	print("WITH MASK vertices=%d (-%.1f %%)  faces=%.0f ms  blocks removed=%d" % [
		masked_vertices, 100.0 * (vertices - masked_vertices) / float(vertices),
		masked_usec / 1000.0, empty_blocks
	])
	assert(masked_vertices > 0 and masked_vertices < vertices, "the mask removed nothing")
	# 29.7 s measured at startup. The remaining cost is the sweep, not emitting triangles: the mask
	# produces 74% fewer vertices at nearly the same cost. The mask's benefit is in what follows—
	# Jolt builds 18.7 M triangles instead of 72 M—not here.
	assert(faces_usec / 1000.0 < 25000.0, "face generation is still too slow")
	print("--- brick upload ---")
	var pool := VoxelBrickPool.new()
	pool.configure(Vector3i(64, 64, 64))
	var batched_usec := 0
	var single_usec := 0
	var uploads := 0
	var bricks := 0
	for shape: VoxelShape3D in shapes:
		var base := pool.get_used()
		var table := pool.append_shape(shape.data)
		if table.is_empty():
			break
		var count := pool.get_used() - base
		var started := Time.get_ticks_usec()
		var batches: Array = pool.extract_uploads(base, count)
		batched_usec += Time.get_ticks_usec() - started
		uploads += batches.size()
		bricks += count
		_verify(pool, shape, table, base, batches)
		# The path being replaced, for comparison: one pass per macrocell and one separate brick for
		# each occupied region. The actual cost was on the GPU, not here, but the distribution is the same.
		var macro_dimensions := shape.data.get_macro_dimensions()
		started = Time.get_ticks_usec()
		for index in macro_dimensions.x * macro_dimensions.y * macro_dimensions.z:
			var slot: int = table[index]
			if slot < 0:
				continue
			pool.refresh_brick(shape.data, slot, Vector3i(
				index % macro_dimensions.x,
				(index / macro_dimensions.x) % macro_dimensions.y,
				index / (macro_dimensions.x * macro_dimensions.y)
			))
			pool.get_slot_origin(slot)
		single_usec += Time.get_ticks_usec() - started
	print("bricks=%d  GPU uploads: %d batched vs %d individual" % [
		bricks, uploads, bricks
	])
	print("packing %.0f ms vs %.0f ms for the per-macrocell loop" % [
		batched_usec / 1000.0, single_usec / 1000.0
	])
	print("OK")
	quit()


## Each brick in the batch must be byte-for-byte identical to what `refresh_brick` returned, and in
## the same texture location. If they become misaligned, the map is rendered with another Shape
## without producing any errors.
func _verify(
	pool: VoxelBrickPool, shape: VoxelShape3D, table: PackedInt32Array, base: int, batches: Array
) -> void:
	var macro_dimensions := shape.data.get_macro_dimensions()
	var macro_of := {}
	for index in table.size():
		if table[index] >= 0:
			macro_of[table[index]] = Vector3i(
				index % macro_dimensions.x,
				(index / macro_dimensions.x) % macro_dimensions.y,
				index / (macro_dimensions.x * macro_dimensions.y)
			)
	var cursor := 0
	for batch: Dictionary in batches:
		var bytes: PackedByteArray = batch.bytes
		var copies: Array = batch.copies
		assert(batch.source_size == Vector3i(BRICK, BRICK, copies.size() * BRICK))
		assert(bytes.size() == copies.size() * BRICK_CELLS)
		for i in copies.size():
			var slot := base + cursor
			cursor += 1
			var copy: Dictionary = copies[i]
			assert(copy.source == Vector3i(0, 0, i * BRICK), "brick %d source does not match" % i)
			assert(copy.destination == pool.get_slot_origin(slot), "slot %d destination" % slot)
			assert(copy.size == Vector3i(BRICK, BRICK, BRICK))
			var expected := pool.refresh_brick(shape.data, slot, macro_of[slot])
			assert(
				bytes.slice(i * BRICK_CELLS, (i + 1) * BRICK_CELLS) == expected,
				"brick in slot %d does not match refresh_brick" % slot
			)
	assert(cursor == pool.get_used() - base, "bricks are missing from the batches")


func _blocks(shape: VoxelShape3D, block: int) -> Array:
	var found := {}
	var dimensions := shape.data.get_macro_dimensions()
	var plane := dimensions.x * dimensions.y
	for macro_index in shape.data.get_occupied_macros():
		found[Vector3i(
			(macro_index % dimensions.x) / block,
			((macro_index / dimensions.x) % dimensions.y) / block,
			(macro_index / plane) / block
		)] = true
	return found.keys()
