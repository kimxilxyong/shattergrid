extends SceneTree
## Verify that each imported joint is attached to actual material, not just an overlapping AABB.

var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	if not FileAccess.file_exists(MAP):
		print("JOINT_CENSUS_PROBE_SKIPPED missing_map")
		quit(0)
		return
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, INF, Vector3.ZERO, false)
	var joints := world.get_node_or_null("TeardownJoints") as VoxelJoints
	assert(joints != null)
	var missing_owner := 0
	var missing_other := 0
	var duplicates := 0
	var missing_details: Array[Dictionary] = []
	var seen := {}
	var types := {}
	for record: Dictionary in joints._records:
		var point := VoxelDoor3D._record_position(record)
		var radius := VoxelDoor3D._record_size(record)
		if not VoxelDoor3D._body_has_material_near(record.owner_body, point, radius):
			missing_owner += 1
		if not VoxelDoor3D._body_has_material_near(record.other_body, point, radius):
			missing_other += 1
			missing_details.append({
				"point": point, "radius": radius,
				"owner": (record.owner_body as VoxelBody3D).name,
				"other": (record.other_body as VoxelBody3D).name,
				"attributes": record.attributes,
			})
		var attributes: Dictionary = record.attributes
		var kind := String(attributes.get("type", "ball"))
		types[kind] = int(types.get(kind, 0)) + 1
		var a := (record.owner_body as VoxelBody3D).get_instance_id()
		var b := (record.other_body as VoxelBody3D).get_instance_id()
		var key := "%d:%d:%s:%d:%d:%d" % [
			mini(a, b), maxi(a, b), kind,
			roundi(point.x * 100.0), roundi(point.y * 100.0), roundi(point.z * 100.0),
		]
		if seen.has(key):
			duplicates += 1
		seen[key] = true
	print("JOINT_CENSUS_PROBE ", JSON.stringify({
		"joints": joints.count(),
		"types": types,
		"missing_owner_material": missing_owner,
		"missing_other_material": missing_other,
		"duplicates_1cm": duplicates,
		"missing_details": missing_details,
	}))
	quit(0 if missing_owner == 0 and missing_other == 0 and duplicates == 0 else 1)
