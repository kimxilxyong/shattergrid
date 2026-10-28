extends "res://tests/selftest/selftest.gd"
## Intact authored pieces from the same collapse share a Body; fragments separated by a cut do not.


func _body(world: VoxelWorld3D, center: Vector3, dimensions: Vector3i,
		epoch: int, lineage := 0, family := 9001) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.DYNAMIC
	body.structural = true
	body.set_meta("damage_epoch", epoch)
	body.set_meta("structural_family", family)
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.structural_lineage = lineage
	shape.position = center
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _run() -> void:
	print("structural coalescence by batch")
	var world := make_world(false)
	_body(world, Vector3(-0.2, 2.0, 0.0), Vector3i(4, 1, 1), 42)
	_body(world, Vector3(0.2, 2.0, 0.0), Vector3i(4, 1, 1), 42)
	world._pending_structural_coalesce[42] = true
	world._coalesce_ready_structural_bodies()
	_check(world.get_dynamic_bodies().size() == 1,
		"two authored pieces that still touch use one RigidBody")
	_check(world.get_dynamic_bodies()[0].get_total_voxels() == 8,
		"the merge preserves all material")

	# Two halves of the same volume, with one removed voxel between them, are 10 cm apart.
	# CONTACT_MARGIN would weld them again; lineage restricts merging to numerical tolerance.
	_body(world, Vector3(2.85, 2.0, 0.0), Vector3i(2, 1, 1), 43, 777)
	_body(world, Vector3(3.15, 2.0, 0.0), Vector3i(2, 1, 1), 43, 777)
	world._pending_structural_coalesce[43] = true
	world._coalesce_ready_structural_bodies()
	_check(world.get_dynamic_bodies().size() == 3,
		"two fragments from the same lineage separated by the cut are not welded together again")

	if failures == 0:
		print("VOXEL_STRUCTURAL_COALESCENCE_SELFTEST_OK")
	else:
		printerr("VOXEL_STRUCTURAL_COALESCENCE_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
