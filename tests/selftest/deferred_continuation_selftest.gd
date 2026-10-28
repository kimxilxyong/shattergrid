extends "res://tests/selftest/selftest.gd"
## Fragment queue: a shot that breaks something into many pieces cannot create every RigidBody in
## the same frame—eight with their compound shapes take 37 ms on Lee, over twice the 60 FPS
## budget—so only a few are created at a time and the rest wait their turn.
##
## Two regressions for this queue:
## - Suspended roof: the continuation reaches the fourth component, which must go through the queue.
##   The queue used to create its RigidBody but skip the support propagation performed for the
##   three immediate fragments.
## - Piece distribution must not lose fragments: all the same pieces, spread across several frames.


func _shape_body(world: VoxelWorld3D, dimensions: Vector3i, cells: PackedByteArray,
		position := Vector3.ZERO, hardness := 1.0) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.position = position
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.GRAY, "hardness": hardness, "density": 1000.0,
	})
	shape.anchored = false
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _run() -> void:
	print("static continuation in a deferred fragment")
	var world := make_world()

	var dimensions := Vector3i(32, 4, 4)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(0)
	var put := func(x: int, y: int, z: int) -> void:
		cells[x + y * dimensions.x + z * dimensions.x * dimensions.y] = 1
	# Anchored base and four 32-voxel components, above the cosmetic limit. The fourth is at x=20,
	# so it must go through the deferred Body queue.
	for x in range(0, 3):
		for y in 2:
			for z in 2:
				put.call(x, y, z)
	for start in [5, 10, 15, 20]:
		for x in range(start, start + 2):
			for y in 4:
				for z in 4:
					put.call(x, y, z)
	put.call(30, 1, 1) # sacrificial voxel that triggers classification
	var source := _shape_body(world, dimensions, cells)
	var source_shape := source.get_shapes()[0]
	source_shape.anchored = true
	source_shape.anchor_indices = PackedInt32Array([0])

	var roof_cells := PackedByteArray()
	roof_cells.resize(4 * 2 * 4)
	roof_cells.fill(1)
	var roof := _shape_body(world, Vector3i(4, 2, 4), roof_cells,
		Vector3(0.5, 0.1, -0.1))
	var roof_shape := roof.get_shapes()[0]
	for _frame in 3:
		await physics_frame

	var damage := world.damage_sphere(source_shape.voxel_center_world(
		30 + dimensions.x + dimensions.x * dimensions.y
	), 0.075, 100.0)
	var immediate: Array = damage[0].new_bodies if not damage.is_empty() else []
	_check(immediate.size() == VoxelWorld3D.FRAGMENTS_PER_FRAME,
		"the first %d components are created in the impact frame" \
			% VoxelWorld3D.FRAGMENTS_PER_FRAME)
	_check(world._body_of(roof_shape) == roof,
		"the roof touching the fourth component is still waiting for its fragment")

	for _frame in 16:
		await physics_frame
		world._process(1.0 / 60.0)
	var roof_owner := world._body_of(roof_shape)
	_check(roof_owner != null and roof_owner != roof,
		"the deferred path transfers the static continuation")
	_check(roof_owner != null and roof_owner.state == VoxelBody3D.State.DYNAMIC,
		"the roof ends up in a dynamic Body")
	_check(world._pending_fragments.is_empty(), "the fragment queue is drained")
	_check(world.get_metrics().pending_collision_handoffs == 0,
		"the collision handoff is also drained")

	# Lossless distribution: a solid core with a thin tail and eight 32-voxel islands around it.
	# Cutting the tail also releases the nearby islands: nine pieces at once, all of which must
	# eventually exist even though the shot frame can create only FRAGMENTS_PER_FRAME.
	var world_budget := make_world()
	var budget_dimensions := Vector3i(25, 3, 25)
	var budget_cells := PackedByteArray()
	budget_cells.resize(budget_dimensions.x * budget_dimensions.y * budget_dimensions.z)
	var put_budget := func(x: int, y: int, z: int) -> void:
		budget_cells[x + y * budget_dimensions.x
			+ z * budget_dimensions.x * budget_dimensions.y] = 1
	for x in range(10, 15):
		for y in 3:
			for z in range(10, 15):
				put_budget.call(x, y, z)
	for x in range(15, 18):
		put_budget.call(x, 1, 12)
	var islands := 0
	for corner: Vector2i in [
		Vector2i(19, 3), Vector2i(19, 15), Vector2i(6, 3), Vector2i(6, 15),
		Vector2i(3, 3), Vector2i(3, 15), Vector2i(22, 3), Vector2i(22, 15),
	]:
		islands += 1
		for x in range(corner.x, corner.x + 2):
			for y in 2:
				for z in range(corner.y, corner.y + 8):
					put_budget.call(x, y, z)
	# High hardness and low energy: the crater is one voxel wide, so it cuts the tail without touching
	# the islands, but the radius—which determines which pieces count as "nearby"—remains large.
	var chunk := _shape_body(world_budget, budget_dimensions, budget_cells, Vector3.ZERO, 20.0)
	var chunk_shape := chunk.get_shapes()[0]
	for _frame in 4:
		await physics_frame
	var crater := chunk_shape.voxel_center_world(
		15 + budget_dimensions.x + 12 * budget_dimensions.x * budget_dimensions.y
	)
	var spawned := 0
	for entry: Dictionary in world_budget.damage_sphere(crater, 1.0, 2.0):
		spawned += (entry.new_bodies as Array).size()
	_check(spawned > 0 and spawned <= VoxelWorld3D.FRAGMENTS_PER_FRAME,
		"the shot frame creates no more than %d bodies" % VoxelWorld3D.FRAGMENTS_PER_FRAME)
	for _frame in 12:
		await physics_frame
		world_budget._process(1.0 / 60.0)
	var total := world_budget.get_dynamic_bodies().size()
	print("  distribution: %d in the shot frame, %d after draining the queue (loose islands: %d)" % [
		spawned, total, islands,
	])
	_check(total > spawned, "the remaining pieces arrive in subsequent frames")
	_check(total >= islands, "no pieces are lost along the way (%d of %d)" % [total, islands])

	if failures == 0:
		print("VOXEL_DEFERRED_CONTINUATION_SELFTEST_OK")
	else:
		printerr("VOXEL_DEFERRED_CONTINUATION_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
