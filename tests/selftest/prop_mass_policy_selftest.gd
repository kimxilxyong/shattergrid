extends "res://tests/selftest/selftest.gd"

const FIXTURE := "res://tests/fixtures/mass_policy_map.xml"


func _run() -> void:
	print("mass policy: hollow props versus solid structure")
	var world := make_world(false)
	TeardownMapImporter.import_map(world, ProjectSettings.globalize_path(FIXTURE),
		Vector3.ZERO, 100.0, Vector3.ZERO, true)
	var by_tag := {}
	for body: VoxelBody3D in world.get_dynamic_bodies():
		var attributes := body.get_meta("teardown_body_attributes", {}) as Dictionary
		by_tag[String(attributes.get("tags", ""))] = body
	_check(by_tag.size() == 3, "all three authored props remain dynamic")
	var crate := by_tag.get("mass_crate") as VoxelBody3D
	var tank := by_tag.get("mass_tank") as VoxelBody3D
	var overridden := by_tag.get("mass_override") as VoxelBody3D
	if crate != null and tank != null and overridden != null:
		var crate_mass := (crate.get_physics_body() as RigidBody3D).mass
		var tank_mass := (tank.get_physics_body() as RigidBody3D).mass
		var override_mass := (overridden.get_physics_body() as RigidBody3D).mass
		print("  masses: crate=%.3f kg tank=%.3f kg density=.25=%.3f kg" % [
			crate_mass, tank_mass, override_mass])
		_check(is_equal_approx(crate_mass, 17.5),
			"a visually 1 m³ box does not weigh 700 kg: it represents 17.5 kg of planks")
		_check(is_equal_approx(tank_mass, 48.75),
			"a visually metallic tank does not use 10 cm of solid steel")
		_check(is_equal_approx(override_mass, 4.375),
			"authored density still scales the effective mass")
		var shape := overridden.get_shapes()[0] as VoxelShape3D
		_check(is_equal_approx(shape.density_scale, 0.25) \
			and is_equal_approx(shape.physical_fill_scale, 0.025),
			"XML authoring and effective volume remain separate states")
		var detached := shape.detach_component(shape.data.get_live_indices())
		_check(detached != null and is_equal_approx(
			(detached as VoxelShape3D).physical_fill_scale, shape.physical_fill_scale
		), "a prop fragment inherits its mass scale")
		if detached != null:
			detached.free()
	var static_mass := -1.0
	var static_body: VoxelBody3D
	var static_shape: VoxelShape3D
	for child: Node in world.get_children():
		if not child is VoxelBody3D:
			continue
		var body := child as VoxelBody3D
		if body.state != VoxelBody3D.State.STATIC:
			continue
		for shape: VoxelShape3D in body.get_shapes():
			if shape.has_meta("teardown_source"):
				static_mass = float(shape.mass_properties().mass)
				static_body = body
				static_shape = shape
	_check(is_equal_approx(static_mass, 700.0),
		"the supported structure retains canonical volumetric density")
	if static_body != null and static_shape != null:
		static_body.make_dynamic(world.physics_budget.max_boxes_per_body)
		var falling_mass := (static_body.get_physics_body() as RigidBody3D).mass
		print("  structure while falling: %.3f kg (was %.3f kg)" % [falling_mass, static_mass])
		_check(is_equal_approx(static_shape.physical_fill_scale, 0.10) \
			and is_equal_approx(falling_mass, 70.0),
			"a structural fragment uses 10% physical fill when becoming dynamic")
		_check(static_body.continuous_collision \
			and (static_body.get_physics_body() as RigidBody3D).continuous_cd,
			"long structural fragments enable CCD against thin supports")
	if failures == 0:
		print("VOXEL_PROP_MASS_POLICY_SELFTEST_OK")
	else:
		printerr("VOXEL_PROP_MASS_POLICY_SELFTEST_FAIL count=", failures)
	world.queue_free()
	await process_frame
	quit(1 if failures > 0 else 0)
