extends SceneTree
## Comprueba que el atlas de bricks devuelve el mismo voxel que la Shape original.
##
## This is what the shader cannot verify by itself: if the `macrocell -> slot` table or the 8x8x8
## packing were wrong, the map would look incorrect without any console errors. Repeat the
## indirection exactly as the shader does and compare it with `get_cell`.

const BRICK := 8


func _init() -> void:
	var failures := 0
	var pool := VoxelBrickPool.new()
	var shapes: Array[VoxelShapeData] = [
		_noise_shape(Vector3i(17, 9, 23), 7), # dimensions not divisible by 8: partial bricks
		_noise_shape(Vector3i(32, 32, 32), 3),
		_noise_shape(Vector3i(8, 8, 8), 11),
	]
	# Three exactly-sized bricks per Shape would be fragile; allocate extra capacity and verify usage.
	# `assert` is removed in release builds; count failures so they are reflected in the exit code.
	if not pool.configure(Vector3i(4, 4, 8)):
		failures += 1
		printerr("  FAIL: the brick pool does not accept the requested capacity")
	var tables: Array[PackedInt32Array] = []
	for shape in shapes:
		var table := pool.append_shape(shape)
		if table.is_empty():
			print("BRICK_POOL_FAIL append_shape returned an empty table")
			failures += 1
		tables.append(table)

	var bytes := pool.get_bytes()
	var texture := pool.get_dimensions()
	for index in shapes.size():
		var shape := shapes[index]
		var table := tables[index]
		if table.is_empty():
			continue
		var size := shape.get_dimensions()
		var macro_size := shape.get_macro_dimensions()
		for z in size.z:
			for y in size.y:
				for x in size.x:
					var macro := Vector3i(x, y, z) / BRICK
					var slot: int = table[
						macro.x + macro_size.x * (macro.y + macro_size.y * macro.z)
					]
					var expected := shape.get_cell(x, y, z)
					if slot < 0:
						# Without a reserved brick, the shader never reaches this point; the macrocell is empty.
						if expected != 0:
							print("BRICK_POOL_FAIL full voxel in macrocell without a brick %v" % Vector3i(x, y, z))
							failures += 1
						continue
					var origin := pool.get_slot_origin(slot)
					var texel := origin + Vector3i(x % BRICK, y % BRICK, z % BRICK)
					var found: int = bytes[
						texel.x + texel.y * texture.x + texel.z * texture.x * texture.y
					]
					if found != expected:
						print("BRICK_POOL_FAIL shape=%d %v expected %d, found %d"
							% [index, Vector3i(x, y, z), expected, found])
						failures += 1
						if failures > 8:
							quit(1)
							return

	# After an impact, the brick is rewritten: the pool must reflect the new gap.
	var damaged := shapes[1]
	damaged.set_cell(9, 9, 9, 0)
	var macro_hit := Vector3i(9, 9, 9) / BRICK
	var slot_hit: int = tables[1][
		macro_hit.x + damaged.get_macro_dimensions().x
			* (macro_hit.y + damaged.get_macro_dimensions().y * macro_hit.z)
	]
	var brick := pool.refresh_brick(damaged, slot_hit, macro_hit)
	if brick.size() != BRICK * BRICK * BRICK:
		print("BRICK_POOL_FAIL refresh_brick returned %d bytes" % brick.size())
		failures += 1
	elif brick[1 + 1 * BRICK + 1 * BRICK * BRICK] != 0:
		print("BRICK_POOL_FAIL rewritten brick still contains the destroyed voxel")
		failures += 1

	print("BRICK_POOL_SELFTEST failures=%d used=%d capacity=%d dimensions=%v"
		% [failures, pool.get_used(), pool.get_capacity(), texture])
	quit(0 if failures == 0 else 1)


func _noise_shape(size: Vector3i, seed_step: int) -> VoxelShapeData:
	var data := VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	for index in cells.size():
		# This pattern is intentionally sparse: it leaves entire macrocells empty, which the dense
		# atlas wasted space on and the brick atlas must skip.
		cells[index] = ((index * seed_step) % 13) if (index / 64) % 3 != 0 else 0
	data.set_cells(size, cells)
	return data
