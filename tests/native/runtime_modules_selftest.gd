extends SceneTree
## Contracts for the C++ maintenance, support, damage, cable, and import modules.

var _contacts := {
	1: PackedInt64Array([2]),
	2: PackedInt64Array([1, 3]),
	3: PackedInt64Array([2]),
}


func _foundation(body_id: int) -> bool:
	return body_id == 3


func _contact_ids(body_id: int) -> PackedInt64Array:
	return _contacts.get(body_id, PackedInt64Array())


func _direct_foundation(_body_id: int, _excluded: int) -> bool:
	return false


func _fail(label: String, details: Variant = null) -> void:
	printerr("VOXEL_NATIVE_RUNTIME_MODULES_FAIL ", label, " ", details)
	quit(1)


func _init() -> void:
	var registry := VoxelRuntimeRegistry.new()
	registry.upsert_body(10, true, true, true, false, 12, 90, 100)
	registry.upsert_body(20, true, false, false, false, 7, 25, 20)
	var registry_data := VoxelShapeData.new()
	registry.upsert_shape(100, registry_data, 10, 0, 0, -1, true, false, false)
	registry.set_baked_collision_pending(100, true)
	var metrics: Dictionary = registry.get_metrics()
	var pending: Dictionary = registry.get_coherence_snapshot()
	if int(metrics.awake_bodies) != 1 or int(metrics.compound_boxes) != 19 \
			or int(metrics.awake_compound_boxes) != 12 or pending.status != "PENDING":
		_fail("registry", {"metrics": metrics, "coherence": pending})
		return
	registry.upsert_shape(100, registry_data, 10, 0, -1, 0, true, false, false)
	if registry.get_coherence_snapshot().consumer != "voxel_change_signal":
		_fail("registry_desync")
		return
	var budget: Dictionary = registry.plan_budget(1, 2, 8, 64, false)
	if not budget.over_budget or (budget.simplify_ids as PackedInt64Array).size() != 1:
		_fail("budget_plan", budget)
		return

	var graph := VoxelStructuralGraph.new()
	var route: Dictionary = graph.reaches_foundation(
		1, 0, _foundation, _contact_ids, _direct_foundation
	)
	var groups: Array = graph.connected_groups(5, PackedInt32Array([0, 1, 1, 2, 3, 4]))
	if not route.grounded or (route.visited_ids as PackedInt64Array).size() < 2 \
			or groups.size() != 2:
		_fail("structural_graph", {"route": route, "groups": groups})
		return

	var cells := PackedByteArray()
	cells.resize(9)
	cells.fill(1)
	var shape := VoxelShapeData.new()
	shape.set_cells(Vector3i(9, 1, 1), cells)
	var hardnesses := PackedFloat32Array()
	hardnesses.resize(256)
	hardnesses[1] = 1.0
	var planner := VoxelDamagePlanner.new()
	var damage: Dictionary = planner.damage_shape(
		shape, Vector3(4.5, 0.5, 0.5), 1.0, 2.0, hardnesses, 100.0, false, 4
	)
	if int(damage.removed) != 1 or not damage.should_classify:
		_fail("damage_planner", damage)
		return

	var rope := VoxelRopeSolver.new()
	rope.configure(8, 6, 9.8, 3.7, 0.28, 0.0015, 20)
	rope.add_span(Vector3(0, 5, 0), Vector3(6, 5, 0), 2.0, 1.0, 0.75)
	for _step in 150:
		rope.simulate(1.0 / 60.0)
	rope.sleep_all()
	var mesh_data: Dictionary = rope.build_mesh_data(Vector3(0, -10_000, 0))
	if rope.get_span_count() != 1 or rope.get_awake_count() != 0 \
			or (mesh_data.vertices as PackedVector3Array).size() != 18 \
			or rope.get_point(0, 4).y >= 4.0:
		_fail("rope_solver", mesh_data)
		return

	var import_planner := VoxelMapImportPlanner.new()
	var fixture := ProjectSettings.globalize_path("res://tests/fixtures/boundary_map.xml")
	var xml_root: Dictionary = import_planner.parse_xml(fixture)
	var boundary := import_planner.find_boundary_points(xml_root, Transform3D.IDENTITY)
	if xml_root.is_empty() or boundary.size() != 4:
		_fail("map_import_planner", {"root": xml_root, "boundary": boundary})
		return

	var impact_queue := VoxelImpactQueue.new()
	var source := Node.new()
	var target := Node.new()
	root.add_child(source)
	root.add_child(target)
	impact_queue.enqueue(source, target, target, Vector3.ONE, 10.0, 3.0, 4)
	impact_queue.enqueue(source, target, target, Vector3.ONE, 20.0, 4.0, 4)
	var impact: Dictionary = impact_queue.pop_front()
	if impact_queue.size() != 0 or float(impact.impulse) != 20.0 or impact.source != source:
		_fail("impact_queue", impact)
		return

	print("VOXEL_NATIVE_RUNTIME_MODULES_OK")
	quit(0)
