extends "res://tests/selftest/selftest.gd"
## Anything no longer connected to a foundation falls; anything still connected does not. This is
## Teardown's model: no stress analysis, only an INDIRECT connection to something that cannot fall.
##
## A map Shape starts with `anchored = false`, and an unanchored Shape that remains one connected
## island used to leave `_split_disconnected` without any checks. That is why fences, pipe sections,
## and towers remained suspended in Lee.
##
## The decisive case is a chain of pipes: each section touches its neighbors, so asking only "does
## it touch anything?" treated them all as supported. The chain must be followed to the ground.
##
## The final scenario is an island FAR from the crater: `_split_disconnected` used to inspect only
## components near the impact, leaving a disconnected wall fragment suspended in the air forever.


func _slab(world: VoxelWorld3D, position: Vector3, size: Vector3i,
		hardness := 1.0) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	world.add_child(body)
	body.position = position
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	cells.fill(1)
	shape.data.set_cells(size, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": hardness, "density": 1000.0})
	# Like map Shapes: no anchors. This was the condition that kept everything from falling.
	shape.anchored = false
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


## The fragment is created at the origin; its height is stored in the Shape, not the node.
static func _body_height(body: VoxelBody3D) -> float:
	var shapes := body.get_shapes()
	return shapes[0].world_bounds().get_center().y if not shapes.is_empty() else 0.0


## A wall with a rock base at one end and a loose brick section at the other, with nothing between
## them: two components from the first frame, much farther apart than the shot radius.
func _island_wall(world: VoxelWorld3D) -> VoxelShape3D:
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(40, 8, 4)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	for z in dimensions.z:
		for y in dimensions.y:
			for x in dimensions.x:
				var material := 0
				if x < 4:
					material = 2 if y < 3 else 1
				elif x >= 30:
					material = 1
				cells[x + y * dimensions.x + z * dimensions.x * dimensions.y] = material
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.RED, "hardness": 0.4, "density": 400.0})
	shape.palette.set_material(2, {
		"color": Color.GRAY, "hardness": VoxelWorld3D.FOUNDATION_HARDNESS, "density": 2400.0,
	})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 6.0, 0.0))
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.STATIC
	world.add_child(body)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return shape


func _run() -> void:
	print("unsupported components fall")
	var world := make_world()

	# Rock floor: the foundation. The Teardown palette assigns `rock` a hardness of 1e6.
	var ground := _slab(world, Vector3(0.0, 0.0, 0.0), Vector3i(60, 4, 60), 1000000.0)
	var resting := _slab(world, Vector3(0.0, 0.5, 0.0), Vector3i(8, 6, 8))
	var floating := _slab(world, Vector3(1.5, 4.0, 0.0), Vector3i(24, 4, 24))
	for _frame in 6:
		await physics_frame
	# `RigidBody3D` is a child of `VoxelBody3D`, and the Shapes are children of the latter: the
	# Shape moves, not its wrapper node.
	var height := floating.get_shapes()[0].world_bounds().get_center().y
	_check(ground.state == VoxelBody3D.State.STATIC
		and resting.state == VoxelBody3D.State.STATIC
		and floating.state == VoxelBody3D.State.STATIC, "all three start static")

	# An impact near the fence triggers the support check.
	# A small hit in one corner: the fence survives, which is what this test checks.
	world.damage_sphere(Vector3(0.6, 4.0, -0.9), 0.2, 20.0)
	_check(floating.get_shapes()[0].voxel_count() > 0, "the fence survives the impact")
	_check(floating.state == VoxelBody3D.State.DYNAMIC, "the unsupported fence becomes dynamic")
	_check(resting.state == VoxelBody3D.State.STATIC, "the slab supported by the ground does not move")
	_check(ground.state == VoxelBody3D.State.STATIC, "neither does the ground")

	for _frame in 40:
		await physics_frame
	var fallen := height - floating.get_shapes()[0].world_bounds().get_center().y
	print("  fence dropped %.2f m" % fallen)
	_check(fallen > 0.3, "and it actually falls")
	# Each scenario needs a clean space. Leaving the first scenario's dynamic fence in the same
	# World3D made it hit and destroy the next scenario's pipes while the test was being set up.
	world.queue_free()
	await process_frame
	await physics_frame

	# Pipe chain: six consecutive, touching sections. The first is supported by the ground, so the
	# entire chain is supported; if the connection is cut, the rest must fall.
	var world2 := make_world()
	# A 4.4 m rock pillar and a cantilevered pipe: only the first section touches the pillar; the
	# other five hang in the air and reach the ground only through the chain.
	_slab(world2, Vector3(0.0, 0.0, 0.0), Vector3i(6, 44, 6), 1000000.0)
	# Coalescence may absorb the authored Bodies before this check. Shapes are
	# is the stable identity; its current Body is resolved when used, as it is during gameplay.
	var pipe_shapes: Array[VoxelShape3D] = []
	for section in 6:
		var pipe := _slab(world2, Vector3(0.55 + float(section) * 1.0, 2.0, 0.0),
			Vector3i(10, 3, 6))
		pipe_shapes.append(pipe.get_shapes()[0])
	for _frame in 6:
		await physics_frame
	var all_static := true
	for pipe_shape in pipe_shapes:
		var pipe_owner := world2._body_of(pipe_shape)
		all_static = all_static and pipe_owner != null \
			and pipe_owner.state == VoxelBody3D.State.STATIC
	_check(all_static, "the pipe chain supported by rock stays still")

	# Split the third pipe: the three at the end lose their path to the ground.
	var tail_shapes: Array[VoxelShape3D] = []
	for section in range(3, 6):
		tail_shapes.append(pipe_shapes[section])
	var cut := pipe_shapes[2]
	world2.damage_sphere(cut.world_bounds().get_center(), 1.2, 100.0)
	var tail_dynamic := 0
	var hosts := {}
	for shape in tail_shapes:
		var owner_body := world2._body_of(shape)
		if owner_body != null and owner_body.state == VoxelBody3D.State.DYNAMIC:
			tail_dynamic += 1
			hosts[owner_body] = true
	_check(tail_dynamic == 3, "the end pipes fall when the chain is cut (%d/3)" % tail_dynamic)
	# They fall together. Anything destruction has not separated remains one piece; with one body per
	# Shape, a tower head used to float while the mast fell.
	_check(hosts.size() == 1, "as one body, not separate fragments (%d)" % hosts.size())
	var root_pipe_owner := world2._body_of(pipe_shapes[0])
	_check(root_pipe_owner != null and root_pipe_owner.state == VoxelBody3D.State.STATIC,
		"the pipe touching the rock remains in place")

	# Repeat the test away from the origin. The contact test uses the relative transform between the
	# two Shapes; constructing it incorrectly gives correct results near the origin and invalid
	# results farther away. In Lee, a 24 m tower 70 m from the center did not "touch" the ground
	# beneath it even with a 2 m margin, so a test near the origin would not catch this.
	var world3 := make_world()
	var far := Vector3(-3.9, 0.0, 70.9)
	_slab(world3, far, Vector3i(20, 20, 20), 1000000.0)
	var mast := _slab(world3, far + Vector3(0.0, 2.05, 0.0), Vector3i(4, 20, 4))
	for _frame in 6:
		await physics_frame
	_check(mast.state == VoxelBody3D.State.STATIC,
		"a tower far from the origin is recognized as supported by the rock beneath it")
	world3.damage_sphere(far + Vector3(0.0, 1.05, 0.0), 1.4, 1000000.0)
	for _frame in 4:
		await physics_frame
	_check(mast.state == VoxelBody3D.State.DYNAMIC,
		"and falls when its support is destroyed")

	# Unified post without an explicit anchor, as imported posts are. The top is larger than the
	# base: keeping "the largest component" left the top static and released the foot that still
	# touched the world. The external root must determine support instead.
	var world_post := make_world()
	_slab(world_post, Vector3.ZERO, Vector3i(20, 4, 20), 1000000.0)
	var post := _slab(world_post, Vector3(0.0, 0.8, 0.0), Vector3i(1, 12, 1))
	var post_shape := post.get_shapes()[0]
	# Separate Shape touching the tip, equivalent to the authored head of the power tower. It is not
	# near the crater, so support must propagate from the newly created upper fragment.
	var post_head := _slab(world_post, Vector3(0.0, 1.5, 0.0), Vector3i(5, 2, 5))
	var post_head_shape := post_head.get_shapes()[0]
	var post_cut := world_post.damage_sphere(
		post_shape.voxel_center_world(3), 0.075, 100.0
	)
	var post_fragments: Array = post_cut[0].new_bodies if not post_cut.is_empty() else []
	_check(post.state == VoxelBody3D.State.STATIC and post_shape.voxel_count() == 3,
		"the post's small base retains its ground anchor")
	_check(post_fragments.size() == 1 \
		and (post_fragments[0] as VoxelBody3D).get_total_voxels() == 58 \
		and (post_fragments[0] as VoxelBody3D).state == VoxelBody3D.State.DYNAMIC,
		"only the unsupported upper section becomes dynamic")
	_check(world_post._body_of(post_head_shape) == post_fragments[0],
		"the distant head transfers to the same body as its supporting section")

	# A Shape can contain both foundation material and the structure it supports. Checking once that
	# it "is a foundation" and then destroying all the rock must not cache that answer forever.
	var world_brick := make_world()
	var brick_body := VoxelBody3D.new()
	world_brick.add_child(brick_body)
	var brick_shape := VoxelShape3D.new()
	brick_shape.data = VoxelShapeData.new()
	var brick_cells := PackedByteArray()
	brick_cells.resize(3 * 8 * 3)
	brick_cells.fill(1)
	for z in 3:
		for x in 3:
			brick_cells[x + z * 3 * 8] = 2
	brick_shape.data.set_cells(Vector3i(3, 8, 3), brick_cells)
	brick_shape.palette = VoxelPalette.new()
	brick_shape.palette.set_material(1, {
		"color": Color(0.5, 0.2, 0.1), "hardness": 1.0, "density": 1800.0,
	})
	brick_shape.palette.set_material(2, {
		"color": Color.GRAY, "hardness": 1000.0, "density": 2600.0,
	})
	brick_body.add_voxel_shape(brick_shape)
	world_brick.register_body(brick_body)
	_check(world_brick._is_foundation(brick_shape),
		"the rock base of the brick tower is initially recognized")
	var root_center := brick_shape.voxel_center_world(1)
	var brick_damage := world_brick.damage_sphere(root_center, 0.5, 1000000000.0)
	var brick_fragments: Array = brick_damage[0].new_bodies \
		if not brick_damage.is_empty() else []
	_check(not world_brick._is_foundation(brick_shape),
		"removing all rock invalidates the cached root")
	_check(brick_fragments.size() == 1 \
		and (brick_fragments[0] as VoxelBody3D).state == VoxelBody3D.State.DYNAMIC,
		"the brick tower with no roots falls in that same impact")

	# A support whose contact is broken without destroying it. The contact cache is per Shape, and
	# the foundation search stops as soon as it finds one. The support may therefore have no cache
	# entry of its own while the beam has one; after damaging it, the beam still considered itself
	# supported until another impact cleared the cache.
	var world4 := make_world()
	_slab(world4, Vector3(0.0, 0.0, 0.0), Vector3i(40, 10, 40), 1000000.0)
	var column := _slab(world4, Vector3(0.0, 1.05, 0.0), Vector3i(4, 20, 4))
	var beam := _slab(world4, Vector3(0.0, 2.25, 0.0), Vector3i(30, 4, 4))
	var beam_shape := beam.get_shapes()[0] as VoxelShape3D
	for _frame in 6:
		await physics_frame
	_check(beam.state == VoxelBody3D.State.STATIC, "the beam above the column stays still")
	# A scrape at the beam's tip, far from the column, breaks nothing but populates the contact cache,
	# reproducing the conditions under which the bug appeared.
	world4.damage_sphere(Vector3(1.35, 2.25, 0.0), 0.2, 60.0)
	for _frame in 4:
		await physics_frame
	_check(beam.state == VoxelBody3D.State.STATIC, "it remains still after a scrape at its tip")
	# Now break the column-beam contact without hitting the beam or removing the column.
	var top := column.get_shapes()[0].world_bounds().end.y
	# The center is low enough to remove the entire pillar section without reaching the beam's voxel
	# centers: this test must measure support loss, not destroy the subject.
	world4.damage_sphere(Vector3(0.0, top - 0.35, 0.0), 0.38, 100.0)
	for _frame in 4:
		await physics_frame
	print("  column: %d voxels remain" % column.get_shapes()[0].voxel_count())
	_check(column.get_shapes()[0].voxel_count() > 0, "the column is still there; only its cap is gone")
	var beam_owner := world4._body_of(beam_shape)
	_check(beam_owner != null and beam_owner.state == VoxelBody3D.State.DYNAMIC,
		"the beam falls in that same shot, not the next one")

	# Collision-box reservations for a newly dynamic body are calculated from awake bodies. Counting
	# all dynamic bodies, Lee's 632 sleeping props already total 13,761 boxes against a limit of
	# 8,192, reducing the reservation to 1: a 24 m tower fell as a single box, with incorrect physics
	# and no usable interactions.
	world4.compound_boxes = 20_000
	world4.awake_compound_boxes = 0
	_check(world4._box_allowance_for_new_body() == world4.physics_budget.max_boxes_per_body,
		"a falling body gets detailed collision even when sleeping bodies exceed the limit")

	# Longer than the old fail-open limit of 32 Shapes. An inconclusive search must not report
	# "supported": the chain has no root and must fall even if the component is large. Explore only
	# this island created by the modified edge, not the entire map.
	var world5 := make_world()
	var long_chain: Array[VoxelBody3D] = []
	var long_chain_shapes: Array[VoxelShape3D] = []
	for section in 40:
		var section_body := _slab(
			world5, Vector3(float(section), 8.0, 0.0), Vector3i(10, 3, 3)
		)
		long_chain.append(section_body)
		long_chain_shapes.append(section_body.get_shapes()[0])
	var last_shape := long_chain[-1].get_shapes()[0]
	world5.damage_sphere(last_shape.world_bounds().get_center(), 0.12, 20.0)
	var dynamic_sections := 0
	var long_chain_hosts := {}
	for section_shape in long_chain_shapes:
		var owner := world5._body_of(section_shape)
		if owner != null and owner.state == VoxelBody3D.State.DYNAMIC:
			dynamic_sections += 1
			long_chain_hosts[owner] = true
	_check(dynamic_sections == 40,
		"an unrooted chain of more than 32 Shapes falls intact (%d/40)" % dynamic_sections)
	_check(long_chain_hosts.size() == 1,
		"the long chain uses one RigidBody instead of forty (%d)" % long_chain_hosts.size())

	# Lee's fence: an authored bar supported only by being embedded in a rock pillar. The player
	# destroys the connecting voxel and the fence remains suspended. Contact is queried with a range
	# of `ceil(CONTACT_MARGIN / voxel_size)` voxels: at 0.12 for 0.1 m voxels, that range was TWO,
	# meaning an entire layer of air between the pieces still counted as a connection. Destroying
	# the connection released nothing because no disconnection was detected.
	var world_fence := make_world()
	_slab(world_fence, Vector3.ZERO, Vector3i(20, 4, 20), 1000000.0)
	_slab(world_fence, Vector3(0.0, 2.2, 0.0), Vector3i(4, 40, 4), 1000000.0)
	# A 3 m bar attached to the pillar face, 3 m above the ground: the pillar is its only path to the foundation.
	var fence := _slab(world_fence, Vector3(1.7, 3.0, 0.0), Vector3i(30, 2, 2))
	var fence_shape := fence.get_shapes()[0]
	for _frame in 6:
		await physics_frame
	var fence_height := fence_shape.world_bounds().get_center().y
	_check(fence.state == VoxelBody3D.State.STATIC, "the fence embedded in the pillar stays still")
	# Remove exactly the connecting column (0.25 m) without touching the rock pillar.
	world_fence.damage_sphere(Vector3(0.25, 3.0, 0.0), 0.11, 100.0)
	for _frame in 4:
		await physics_frame
	var fence_owner := world_fence._body_of(fence_shape)
	_check(fence_owner != null and fence_owner.state == VoxelBody3D.State.DYNAMIC,
		"it falls when the connection is destroyed, while the pillar remains standing")
	for _frame in 40:
		await physics_frame
	var fence_fallen := fence_height - fence_shape.world_bounds().get_center().y
	print("  fence dropped %.2f m" % fence_fallen)
	_check(fence_fallen > 0.3, "it actually falls, not just changes state")

	# Disconnected island FAR from the crater: the loose section is 26 voxels from the shot, well
	# outside the local range previously used to filter components for reclassification.
	var world_island := make_world()
	var wall := _island_wall(world_island)
	world_island.finalize_spatial_index()
	for _frame in 5:
		await physics_frame
	_check(world_island.get_dynamic_bodies().is_empty(), "the wall with an island starts as one static body")
	# Scrape the rock to remove foundation material and ensure classification runs.
	world_island.damage_sphere(wall.voxel_center_world(0), 0.15, 1.0e6)
	for _frame in 30:
		await physics_frame
		world_island._process(1.0 / 60.0)
	var islands := world_island.get_dynamic_bodies()
	_check(not islands.is_empty(), "the section far from the crater detaches into its own body")
	_check(is_instance_valid(wall) and wall.voxel_count() > 0,
		"the base on the rock remains in place")
	var island_heights: Array[float] = []
	for body: VoxelBody3D in islands:
		island_heights.append(_body_height(body))
	for _frame in 90:
		await physics_frame
		world_island._process(1.0 / 60.0)
	var fell := 0
	for index in islands.size():
		var body := islands[index]
		if is_instance_valid(body) and island_heights[index] - _body_height(body) > 0.3:
			fell += 1
	_check(fell > 0, "the distant island actually falls instead of floating")
	var snapshot: Dictionary = world_island._runtime_registry.get_coherence_snapshot()
	print("  distant island: %d bodies, coherence %s" % [islands.size(), snapshot.get("status", "?")])
	_check(String(snapshot.get("status", "")) != "DESYNC",
		"no Shape has desynchronized collision after changing bodies")

	if failures == 0:
		print("VOXEL_UNSUPPORTED_DROP_SELFTEST_OK")
	else:
		printerr("VOXEL_UNSUPPORTED_DROP_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
