extends SceneTree
## Measure the actual clearance between the two authored pieces of Lee's power tower.

var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	_run.call_deferred()


static func _shape_near(world: VoxelWorld3D, probe: Vector3, radius: float) -> VoxelShape3D:
	for body in world.get_children():
		if not body is VoxelBody3D:
			continue
		for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
			var bounds := shape.world_bounds()
			if probe.distance_to(probe.clamp(bounds.position, bounds.end)) < radius:
				return shape
	return null


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, false)
	var mast := _shape_near(world, Vector3(-3.9, 14.7, 70.9), 2.0)
	var head := _shape_near(world, Vector3(-3.9, 25.5, 70.9), 1.0)
	assert(mast != null and head != null and mast != head)
	var mast_bounds := mast.world_bounds()
	var head_bounds := head.world_bounds()
	var closest_mast := head_bounds.get_center().clamp(mast_bounds.position, mast_bounds.end)
	var closest_head := closest_mast.clamp(head_bounds.position, head_bounds.end)
	var contacts := {}
	for margin in [0.09, 0.12, 0.125, 0.13, 0.15, 0.19]:
		contacts[str(margin)] = world._shapes_touch_with_margin(mast, head, margin)
	print("VOXEL_TOWER_CONTACT_PROBE ", JSON.stringify({
		"mast": mast_bounds,
		"head": head_bounds,
		"aabb_gap_m": closest_mast.distance_to(closest_head),
		"contacts": contacts,
	}))
	for step in 3:
		var affected := world.damage_sphere(
			Vector3(-3.92, 3.0 + float(step) * 0.8, 70.95), 3.2, 400.0
		)
		var created: Array[Dictionary] = []
		for record: Dictionary in affected:
			for body: VoxelBody3D in record.new_bodies:
				var touching_head := false
				for fragment_shape in body.get_shapes():
					touching_head = touching_head or world._shapes_touch_with_margin(
						fragment_shape, head, VoxelWorld3D.CONTACT_MARGIN
					)
				created.append({
					"name": body.name,
					"voxels": body.get_total_voxels(),
					"family": body.get_meta("structural_family", -1),
					"epoch": body.get_meta("damage_epoch", -1),
					"touching_head": touching_head,
				})
		print("VOXEL_TOWER_DAMAGE_STEP ", step, " ", JSON.stringify({
			"created": created,
			"head_owner": world._body_of(head).name if is_instance_valid(head) else "freed",
			"head_state": world._body_of(head).state if is_instance_valid(head) else -1,
			"metrics": world.get_metrics(),
		}))
	for _frame in 12:
		await physics_frame
		await process_frame
	var head_owner := world._body_of(head)
	print("VOXEL_TOWER_COALESCE_PROBE ", JSON.stringify({
		"head_owner": head_owner.name,
		"head_voxels": head_owner.get_total_voxels(),
		"head_state": head_owner.state,
		"coalesces": world.structural_coalesces,
		"handoffs": int(world.get_metrics().pending_collision_handoffs),
	}))
	quit(0)
