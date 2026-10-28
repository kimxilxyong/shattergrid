extends SceneTree
## Minimal contracts for the C++ services extracted from the five GDScript hot paths.

class FakeBody:
	extends Node
	var state := VoxelBody3D.State.DYNAMIC
	var shapes: Array = []

	func get_shapes() -> Array:
		return shapes

	func get_physics_body() -> PhysicsBody3D:
		return null


class FakeShape:
	extends Node3D
	var bounds := AABB(Vector3.ZERO, Vector3.ONE)

	func world_bounds() -> AABB:
		return bounds

	func voxel_count() -> int:
		return 1


var _visited := 0


func _visitor(_element: Dictionary, _transform: Transform3D, context: Dictionary) -> Dictionary:
	_visited += 1
	return {"context": context, "visit_children": true}


func _fail(label: String, details: Variant = null) -> void:
	printerr("VOXEL_NATIVE_MIGRATION_MODULES_FAIL ", label, " ", details)
	quit(1)


func _init() -> void:
	var shadow := VoxelShadowUpdatePlanner.new()
	var body := FakeBody.new()
	var shape := FakeShape.new()
	body.shapes.append(shape)
	root.add_child(body)
	body.add_child(shape)
	shadow.reset([shape], [shape.bounds], [true])
	var moved := AABB(Vector3(1.0, 0.0, 0.0), Vector3.ONE)
	var update: Dictionary = shadow.plan(
		[shape], {shape.get_instance_id(): moved}, 1, 12, 0.01, 0.2, 15, 8.0
	)
	if update.dirty.size() != 1 or update.grid_updates.size() != 1:
		_fail("shadow_move", update)
		return
	var quiet: Dictionary = shadow.plan(
		[shape], {shape.get_instance_id(): moved}, 2, 12, 0.01, 0.2, 15, 8.0
	)
	if not quiet.dirty.is_empty():
		_fail("shadow_deadband", quiet)
		return
	var coalesced := shadow.coalesce([
		AABB(Vector3.ZERO, Vector3.ONE),
		AABB(Vector3(1.0, 0.0, 0.0), Vector3.ONE),
		AABB(Vector3(20.0, 0.0, 0.0), Vector3.ONE),
	], 8.0)
	if coalesced.size() != 2:
		_fail("shadow_coalesce", coalesced)
		return

	var decoder := VoxelAssetDecoder.new()
	var decoded: Dictionary = decoder.decode(
		"res://assets/models/houses/casa_dos_plantas.vox", 2, 2, 0.1
	)
	if not decoded.ok or decoded.shapes.is_empty() \
			or not decoded.shapes[0].data is VoxelShapeData:
		_fail("asset_decoder", decoded)
		return

	var traversal := VoxelMapSceneTraversal.new()
	var planner := VoxelMapImportPlanner.new()
	var fixture := ProjectSettings.globalize_path("res://tests/fixtures/mass_policy_map.xml")
	var scene: Dictionary = planner.parse_xml(fixture)
	var visited := traversal.traverse(
		scene.children, Transform3D.IDENTITY, {}, _visitor
	)
	if visited != _visited or visited < 7:
		_fail("scene_traversal", {"returned": visited, "callbacks": _visited})
		return

	var damping := VoxelMassProperties.damping_for_inertia(Vector3(120.0, 4.0, 120.0))
	if damping.y < 2.0:
		_fail("mass_properties", damping)
		return

	print("VOXEL_NATIVE_MIGRATION_MODULES_OK visited=", visited,
		" decoded_shapes=", decoded.shapes.size())
	quit(0)
