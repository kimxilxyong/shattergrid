extends SceneTree
## The inertia of a multi-Shape Body must include orientation and distance from the center of mass.
## Summing only intrinsic inertia made a tower or long pipe rotate like a compact cube.


func _init() -> void:
	_run.call_deferred()


static func _cube(position: Vector3) -> VoxelShape3D:
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(8)
	cells.fill(1)
	shape.data.set_cells(Vector3i(2, 2, 2), cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.GRAY, "density": 1000.0, "hardness": 1.0,
	})
	shape.position = position
	shape.anchored = false
	return shape


func _run() -> void:
	var authored := _cube(Vector3.ZERO)
	root.add_child(authored)
	var full_mass := float(authored.mass_properties().mass)
	authored.density_scale = 0.25
	var light_properties := authored.mass_properties()
	var density_ok := is_equal_approx(float(light_properties.mass), full_mass * 0.25)
	var all_indices := PackedInt32Array([0, 1, 2, 3])
	var detached := authored.detach_component(all_indices)
	density_ok = density_ok and detached != null \
		and is_equal_approx(detached.density_scale, authored.density_scale)
	authored.queue_free()
	if detached != null:
		detached.queue_free()

	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.DYNAMIC
	root.add_child(body)
	body.add_voxel_shape(_cube(Vector3(-1.0, 0.0, 0.0)), false, false)
	body.add_voxel_shape(_cube(Vector3(1.0, 0.0, 0.0)), false, false)
	body.rebuild_dynamic_collision(16)
	var rigid := body.get_physics_body() as RigidBody3D
	var inertia := rigid.inertia
	var ok := absf(rigid.center_of_mass.x) < 0.0001 \
		and inertia.y > inertia.x * 20.0 and inertia.z > inertia.x * 20.0 \
		and rigid is VoxelImpactRigidBody3D \
		and rigid.contact_monitor and rigid.max_contacts_reported == 8 and density_ok
	if ok:
		print("VOXEL_COMPOSITE_MASS_SELFTEST_OK center=", rigid.center_of_mass,
			" inertia=", inertia)
	else:
		printerr("VOXEL_COMPOSITE_MASS_SELFTEST_FAIL center=", rigid.center_of_mass,
			" inertia=", inertia, " contact_monitor=", rigid.contact_monitor)
	quit(0 if ok else 1)
