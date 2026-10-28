extends "res://tests/selftest/selftest.gd"
## Map props start asleep, not frozen. Asleep means Jolt does not simulate them until something
## touches them; frozen meant inert static objects that did not react to anything. That difference
## makes the world feel alive: boxes can be pushed, pipes hang from their joints, and canisters fly
## when an explosion goes off nearby.


func _make_body(world: VoxelWorld3D, origin: Vector3, dynamic: bool) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.DYNAMIC if dynamic else VoxelBody3D.State.STATIC
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(6, 6, 6)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 5.0, "density": 400.0})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, origin)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _height(body: VoxelBody3D) -> float:
	return body.get_shapes()[0].world_bounds().get_center().y


func _run() -> void:
	print("live props")
	var world := make_world()

	var floor_body := _make_body(world, Vector3(0, 0, 0), false)
	floor_body.name = "Suelo"
	var crate := _make_body(world, Vector3(0, 1.2, 0), true)
	crate.sleep()
	for _frame in 10:
		await physics_frame
	_check(not crate.is_awake(), "the imported prop starts asleep and costs no simulation time")
	var resting := _height(crate)

	# The key is contact. A frozen body did nothing; Jolt wakes a sleeping body on contact.
	var hammer := _make_body(world, Vector3(0, 5.0, 0), true)
	hammer.name = "Martillo"
	for _frame in 90:
		await physics_frame
	_check(crate.is_awake() or absf(_height(crate) - resting) > 0.02,
		"a body landing on it wakes and moves it")
	print("  prop height: resting %.3f  after impact %.3f" % [resting, _height(crate)])

	# A nearby explosion must also push it even if it removes no voxels.
	var other := _make_body(world, Vector3(20, 1.2, 0), true)
	other.sleep()
	for _frame in 10:
		await physics_frame
	var before := other.get_shapes()[0].world_bounds().get_center()
	world.damage_sphere(Vector3(18.0, 1.2, 0), 1.0, 3.0)
	for _frame in 60:
		await physics_frame
	var moved := before.distance_to(other.get_shapes()[0].world_bounds().get_center())
	print("  displaced by the shockwave: %.3f m" % moved)
	_check(moved > 0.05, "a nearby explosion pushes the sleeping prop")

	# A long volume can overlap the broad candidate sphere while all its mass remains outside the
	# blast. Waking it without applying force caused the phantom burst of posts/cables in Lee.
	var distant_pole := VoxelBody3D.new()
	distant_pole.state = VoxelBody3D.State.DYNAMIC
	world.add_child(distant_pole)
	var pole_shape := VoxelShape3D.new()
	pole_shape.data = VoxelShapeData.new()
	var pole_cells := PackedByteArray()
	pole_cells.resize(2 * 100 * 2)
	pole_cells.fill(1)
	pole_shape.data.set_cells(Vector3i(2, 100, 2), pole_cells)
	pole_shape.palette = VoxelPalette.new()
	pole_shape.palette.set_material(1, {
		"color": Color.GRAY, "hardness": 100.0, "density": 400.0,
	})
	pole_shape.transform = Transform3D(Basis.IDENTITY, Vector3(30.0, 7.0, 0.0))
	distant_pole.add_voxel_shape(pole_shape)
	world.register_body(distant_pole)
	distant_pole.sleep()
	for _frame in 4:
		await physics_frame
	world.damage_sphere(Vector3(30.0, 0.0, 0.0), 1.0, 3.0)
	for _frame in 3:
		await physics_frame
	_check(not distant_pole.is_awake(),
		"a long AABB outside the impulse radius does not create a ghost awake Body")

	# The budget must not degrade collision for sleeping props: that turned every map box into a
	# 40 cm block on the first tick.
	world.physics_budget.max_active_boxes = 1
	var boxes_before := crate.compound_boxes
	crate.sleep()
	for _frame in 4:
		await physics_frame
	world._enforce_physics_budget(false)
	_check(crate.compound_boxes == boxes_before,
		"a sleeping prop keeps its detailed collision (%d boxes)" % boxes_before)

	if failures == 0:
		print("VOXEL_LIVE_PROPS_SELFTEST_OK")
	else:
		printerr("VOXEL_LIVE_PROPS_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
