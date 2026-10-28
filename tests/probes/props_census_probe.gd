extends SceneTree
## How many Teardown `<body dynamic="true">` elements survive cropping and what they cost: this
## determines whether all can be active at once or must continue to be frozen.
var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)
	var report: Dictionary = TeardownMapImporter.import_map(
		world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)
	print("imported bodies %d   joints %d (discarded %d)" % [
		report.bodies, report.joints, report.skipped_joints])
	print("XML dynamic=true %d   imported dynamic %d   density overrides %d" % [
		report.authored_dynamic_bodies, report.imported_dynamic_bodies,
		report.density_overrides])
	assert(int(report.authored_dynamic_bodies) == 632,
		"the traversal no longer recognizes Lee's 632 dynamic=true markers")
	var dynamic := 0
	var boxes := 0
	var voxels := 0
	var masses: Array[float] = []
	var mass_records: Array[Dictionary] = []
	var reference_masses := {}
	for body in world.get_dynamic_bodies():
		dynamic += 1
		boxes += body.compound_boxes
		voxels += body.get_total_voxels()
		var rigid := body.get_physics_body() as RigidBody3D
		if rigid != null:
			masses.append(rigid.mass)
			var sources: PackedStringArray = body.get_meta(
				"teardown_sources", PackedStringArray())
			mass_records.append({
				"mass": rigid.mass,
				"voxels": body.get_total_voxels(),
				"sources": sources,
			})
			for source: String in sources:
				if source in ["vox:palette22.vox:shape473", "vox:palette24.vox:shape500",
						"vox:palette25.vox:shape527", "vox:palette197.vox:shape2264",
						"vox:palette126.vox:shape1953"]:
					reference_masses[source] = rigid.mass
	print("dynamic props %d   collision boxes %d   voxels %d" % [dynamic, boxes, voxels])
	assert(dynamic == int(report.imported_dynamic_bodies),
		"the report does not match the registered dynamic Bodies")
	masses.sort()
	var liftable := masses.filter(func(value: float) -> bool: return value <= 2200.0 / 9.8).size()
	var p50 := masses[masses.size() / 2]
	var p90 := masses[int(masses.size() * 0.90)]
	var p99 := masses[int(masses.size() * 0.99)]
	print("masses kg: P50 %.1f  P90 %.1f  P99 %.1f  max %.1f  liftable %d/%d" % [
		p50, p90, p99, masses.back(), liftable, masses.size()])
	assert(p50 < 30.0 and p90 < 300.0 and liftable >= 550,
		"prop masses have reverted to exaggerated solid masses")
	mass_records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.mass) > float(b.mass))
	print("12 heaviest bodies (should be vehicles/machinery, not small props):")
	for index in mini(12, mass_records.size()):
		var record := mass_records[index]
		print("  %.1f kg  vox=%d  %s" % [
			float(record.mass), int(record.voxels), record.sources])
	var expected := {
		"vox:palette22.vox:shape473": 846.7,
		"vox:palette24.vox:shape500": 1532.9,
		"vox:palette25.vox:shape527": 1820.0,
		"vox:palette197.vox:shape2264": 31.8,
		"vox:palette126.vox:shape1953": 32.9,
	}
	for source: String in expected:
		assert(reference_masses.has(source) and absf(
			float(reference_masses[source]) - float(expected[source])
		) < float(expected[source]) * 0.02, "inconsistent mass for %s" % source)
	print("reference masses ", reference_masses)
	print("presupuesto: max_active_boxes %d   target_awake %d" % [
		world.physics_budget.max_active_boxes, world.physics_budget.target_awake_bodies])
	quit()
