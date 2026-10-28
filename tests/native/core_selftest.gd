extends SceneTree


static func _component_signatures(components: Array) -> Array[String]:
	var result: Array[String] = []
	for component: Dictionary in components:
		result.append("%d:%d:%s:%s" % [
			int(component.voxel_count), int(component.anchor_count),
			str(component.minimum), str(component.maximum),
		])
	result.sort()
	return result


func _init() -> void:
	var shape := VoxelShapeData.new()
	shape.generate_prototype(32)
	var before := shape.get_occupied_count()
	var revision_before_damage := shape.get_content_revision()
	var test: Dictionary = shape.self_test()
	if not test.get("ok", false):
		printerr("VOXEL_NATIVE_SELFTEST_FAIL ", test)
		quit(1)
		return

	var damage: Dictionary = shape.damage_sphere(Vector3(16, 12, 4), 5.0, 1.0)
	var removed := int(damage.get("removed", 0))
	var removed_indices: PackedInt32Array = damage.get("removed_indices", PackedInt32Array())
	var removed_materials: PackedByteArray = damage.get("removed_materials", PackedByteArray())
	if removed <= 0 or shape.get_occupied_count() != before - removed \
		or shape.get_content_revision() <= revision_before_damage \
		or removed_indices.is_empty() or removed_indices.size() > 256 \
		or removed_materials.size() != removed_indices.size():
		printerr("VOXEL_NATIVE_DAMAGE_FAIL ", damage)
		quit(1)
		return

	var components: Array = shape.find_components_6()
	if components.is_empty():
		printerr("VOXEL_NATIVE_CONNECTIVITY_FAIL")
		quit(1)
		return

	var physics_budget := VoxelPhysicsBudget.new()
	var renderer_settings := VoxelRendererSettings.new()
	if physics_budget.max_boxes_per_body != 64 \
		or renderer_settings.clipmap_levels != 4:
		printerr("VOXEL_NATIVE_SETTINGS_FAIL")
		quit(1)
		return

	var palette := VoxelPalette.new()
	palette.set_material(7, {
		"color": Color("44cc88"), "hardness": 2.5, "density": 720.0,
		"roughness": 0.6, "friction": 0.7,
	})
	if palette.get_capacity() != 255 or not is_equal_approx(
		float(palette.get_material(7).hardness), 2.5
	):
		printerr("VOXEL_NATIVE_PALETTE_FAIL")
		quit(1)
		return
	var render_properties := palette.get_render_properties()
	if render_properties.size() != 256 \
			or not is_equal_approx(render_properties[7].r, 0.6) \
			or not is_equal_approx(render_properties[7].g, 0.0):
		printerr("VOXEL_NATIVE_RENDER_PROPERTIES_FAIL ", render_properties[7])
		quit(1)
		return

	var split := VoxelShapeData.new()
	var split_cells := PackedByteArray()
	split_cells.resize(8 * 4 * 4)
	for x in 3:
		split_cells[x] = 1
	for x in range(5, 8):
		split_cells[x] = 2
	if not split.set_cells(Vector3i(8, 4, 4), split_cells):
		printerr("VOXEL_NATIVE_SET_CELLS_FAIL")
		quit(1)
		return
	var classified := split.find_components_6_with_anchors(PackedInt32Array([0]))
	var classified_reference := split.find_components_6_with_anchors_reference(
		PackedInt32Array([0])
	)
	if classified.size() != 2 or not classified[0].anchored or classified[1].anchored \
		or classified_reference.size() != classified.size() \
		or int(classified_reference[0].voxel_count) != int(classified[0].voxel_count) \
		or int(classified_reference[1].voxel_count) != int(classified[1].voxel_count) \
		or int(classified[0].anchor_count) != 1 \
		or int(classified[0].support_cross_section) != 3 \
		or (classified[0].anchor_indices as PackedInt32Array) != PackedInt32Array([0]):
		printerr("VOXEL_NATIVE_ANCHOR_FAIL ", classified)
		quit(1)
		return
	var revision_before_detach := split.get_content_revision()
	var detached: Dictionary = split.detach_component(classified[1].indices)
	if detached.is_empty() or split.get_occupied_count() != 3 \
		or split.get_content_revision() <= revision_before_detach \
		or (detached.data as VoxelShapeData).get_occupied_count() != 3:
		printerr("VOXEL_NATIVE_DETACH_FAIL ", detached)
		quit(1)
		return

	var solid := VoxelShapeData.new()
	var solid_cells := PackedByteArray()
	solid_cells.resize(4 * 4 * 4)
	solid_cells.fill(1)
	solid.set_cells(Vector3i(4, 4, 4), solid_cells)
	var collision: Dictionary = solid.build_collision_boxes(128, 0.1)
	var greedy_faces := solid.build_macro_faces(Vector3i.ZERO, 0.1, 1, 1)
	var mass: Dictionary = solid.calculate_mass_properties(palette.get_densities(), 0.1)
	var inertia := mass.inertia as Vector3
	if collision.box_count != 1 or collision.pitch != 1 or greedy_faces.size() != 36 \
		or not is_equal_approx(float(mass.mass), 115.2) \
		or inertia.x <= 0.0 or inertia.y <= 0.0 or inertia.z <= 0.0:
		printerr("VOXEL_NATIVE_PHYSICS_FAIL collision=", collision, " mass=", mass)
		quit(1)
		return
	if solid.get_cell(3, 2, 1) != 1 or solid.get_cell(4, 0, 0) != 0:
		printerr("VOXEL_NATIVE_INDEXING_FAIL")
		quit(1)
		return

	# A surface crater keeps all of its frontier connected locally, while deleting the only voxel
	# between two blocks must request the exact global component pass.
	var crater := VoxelShapeData.new()
	var crater_cells := PackedByteArray()
	crater_cells.resize(24 * 12 * 12)
	crater_cells.fill(1)
	crater.set_cells(Vector3i(24, 12, 12), crater_cells)
	var crater_damage: Dictionary = crater.damage_sphere(Vector3(12, 11, 6), 3.0, 1.0)
	if crater.damage_may_disconnect_6(crater_damage.dirty_min, crater_damage.dirty_max, 8):
		printerr("VOXEL_NATIVE_LOCAL_CONNECTIVITY_FALSE_POSITIVE")
		quit(1)
		return
	var bridge := VoxelShapeData.new()
	var bridge_cells := PackedByteArray()
	bridge_cells.resize(9)
	bridge_cells.fill(1)
	bridge.set_cells(Vector3i(9, 1, 1), bridge_cells)
	var revision_before_cell := bridge.get_content_revision()
	bridge.set_cell(4, 0, 0, 0)
	if bridge.get_content_revision() <= revision_before_cell \
		or not bridge.damage_may_disconnect_6(Vector3i(4, 0, 0), Vector3i(4, 0, 0), 4) \
		or not bridge.damage_may_disconnect_6_indexed(Vector3i(4, 0, 0), Vector3i(4, 0, 0)):
		printerr("VOXEL_NATIVE_LOCAL_CONNECTIVITY_MISSED_CUT")
		quit(1)
		return

	# The local guard cannot see that both sides reconnect around the rectangle's end. The global
	# index must remove this false positive without running a dense flood fill.
	var detour := VoxelShapeData.new()
	var detour_size := Vector3i(41, 7, 1)
	var detour_cells := PackedByteArray()
	detour_cells.resize(detour_size.x * detour_size.y * detour_size.z)
	for x in detour_size.x:
		detour_cells[x + detour_size.x] = 1
		detour_cells[x + 5 * detour_size.x] = 1
	for y in range(1, 6):
		detour_cells[y * detour_size.x] = 1
		detour_cells[40 + y * detour_size.x] = 1
	detour.set_cells(detour_size, detour_cells)
	detour.set_cell(20, 1, 0, 0)
	if not detour.damage_may_disconnect_6(Vector3i(20, 1, 0), Vector3i(20, 1, 0), 4) \
		or detour.damage_may_disconnect_6_indexed(
			Vector3i(20, 1, 0), Vector3i(20, 1, 0)
		):
		printerr("VOXEL_NATIVE_INDEXED_CONNECTIVITY_DETOUR_FAIL")
		quit(1)
		return

	var checker := VoxelShapeData.new()
	var checker_cells := PackedByteArray()
	checker_cells.resize(16 * 16 * 16)
	for z in 16:
		for y in 16:
			for x in 16:
				if (x + y + z) % 2 == 0:
					checker_cells[x + y * 16 + z * 16 * 16] = 1
	checker.set_cells(Vector3i(16, 16, 16), checker_cells)
	var simplified: Dictionary = checker.build_collision_boxes(128, 0.1)
	if simplified.box_count > 128 or simplified.pitch < 2 or simplified.exact:
		printerr("VOXEL_NATIVE_SIMPLIFICATION_FAIL ", simplified)
		quit(1)
		return

	# Tower regression: the old LOD converted every occupied voxel into a pitch³ cell and then
	# merged those cells, inventing invisible platforms. Three points force pitch 4; their boxes
	# should cover only their local bounds (10 cm in Z), not fill 40 cm of empty space.
	var sparse := VoxelShapeData.new()
	var sparse_dimensions := Vector3i(8, 8, 8)
	var sparse_cells := PackedByteArray()
	sparse_cells.resize(8 * 8 * 8)
	for coordinate in [Vector3i(1, 1, 1), Vector3i(2, 2, 1), Vector3i(5, 1, 1)]:
		sparse_cells[coordinate.x + coordinate.z * 8 + coordinate.y * 64] = 1
	sparse.set_cells(sparse_dimensions, sparse_cells)
	var sparse_collision: Dictionary = sparse.build_collision_boxes(2, 0.1)
	var sparse_tight: bool = int(sparse_collision.pitch) == 4 \
		and int(sparse_collision.box_count) == 2
	for box: Dictionary in sparse_collision.boxes:
		var box_size := box.size as Vector3
		sparse_tight = sparse_tight and minf(box_size.x, minf(box_size.y, box_size.z)) <= 0.101
	if not sparse_tight:
		printerr("VOXEL_NATIVE_TIGHT_COARSE_COLLISION_FAIL ", sparse_collision)
		quit(1)
		return

	# Exactness across 8^3 boundaries: three components cross macrocells on different axes.
	var macro_shape := VoxelShapeData.new()
	var macro_cells := PackedByteArray()
	macro_cells.resize(24 * 24 * 24)
	for x in 24:
		macro_cells[x + 1 * 24 + 1 * 24 * 24] = 1
	for y in 24:
		macro_cells[5 + y * 24 + 10 * 24 * 24] = 1
	for z in 24:
		macro_cells[18 + 18 * 24 + z * 24 * 24] = 1
	macro_shape.set_cells(Vector3i(24, 24, 24), macro_cells)
	var macro_anchors := PackedInt32Array([1 * 24 + 1 * 24 * 24])
	var macro_indexed := macro_shape.find_components_6_with_anchors(macro_anchors)
	var macro_reference := macro_shape.find_components_6_with_anchors_reference(macro_anchors)
	if _component_signatures(macro_indexed) != _component_signatures(macro_reference) \
		or int(macro_shape.get_connectivity_metrics().fallbacks) != 0:
		printerr("VOXEL_NATIVE_MACRO_CONNECTIVITY_MISMATCH indexed=", macro_indexed,
			" reference=", macro_reference)
		quit(1)
		return

	print("VOXEL_NATIVE_SELFTEST_OK occupied=%d removed=%d components=%d macros=%s mass=%.1f" % [
		before, removed, components.size(), shape.get_macro_dimensions(), mass.mass
	])
	quit(0)
