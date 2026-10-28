extends SceneTree


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	root.add_child(world)
	var palette := VoxelPalette.new()
	var cells := PackedByteArray()
	cells.resize(8)
	cells.fill(1)
	for index in 256:
		var data := VoxelShapeData.new()
		data.set_cells(Vector3i(2, 2, 2), cells)
		var shape := VoxelShape3D.new()
		shape.data = data
		shape.palette = palette
		shape.anchored = false
		shape.position = Vector3((index % 16) * 0.35, 5.0 + (index / 16) * 0.35, 0)
		var body := VoxelBody3D.new()
		world.add_child(body)
		body.add_voxel_shape(shape)
		body.make_dynamic(world.physics_budget.max_boxes_per_body)
		world.register_body(body)
	# While the previous StaticBody is still leaving the PhysicsServer, the handoff protects each
	# body from retirement. The budget is applied after that tick, as it is during gameplay.
	for _frame in 3:
		await process_frame
		await physics_frame
	world._update_metrics()
	world._enforce_physics_budget(false)
	await process_frame
	world._update_metrics()
	var metrics := world.get_metrics()
	var passed := int(metrics.awake_bodies) <= world.physics_budget.target_awake_bodies \
		and int(metrics.awake_compound_boxes) <= world.physics_budget.max_active_boxes
	for body: VoxelBody3D in get_nodes_in_group(VoxelBody3D.GROUP):
		passed = passed and body.compound_boxes <= world.physics_budget.max_boxes_per_body
	print("VOXEL_PHYSICS_BUDGET_RESULT ", JSON.stringify({
		"bodies": get_nodes_in_group(VoxelBody3D.GROUP).size(),
		"awake_bodies": metrics.awake_bodies,
		"awake_compound_boxes": metrics.awake_compound_boxes,
		"total_compound_boxes": metrics.compound_boxes,
		"pass": passed,
	}))
	quit(0 if passed else 1)
