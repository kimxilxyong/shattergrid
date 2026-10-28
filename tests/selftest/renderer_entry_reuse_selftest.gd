extends SceneTree
## Visual-budget regression: a freed entry can be reused without losing transparent-pass metadata.
## No RenderingDevice is required; this validates CPU-side topology and records.



var failures := 0


## `assert` is removed from release builds: a test using only assertions would always pass. Count
## failures and return them through the exit code.
func _check(condition: bool, message := "") -> void:
	if not condition:
		failures += 1
		printerr("  FAIL ", message)

func _entry(dimensions: Vector3i, has_glass: bool) -> Dictionary:
	return {
		"transform": Transform3D.IDENTITY,
		"dimensions": dimensions,
		"voxel_size": 0.1,
		"atlas_origin": Vector3i.ZERO,
		"macro_origin": Vector3i.ZERO,
		"macro_dimensions": Vector3i.ONE,
		"brick_table_base": 0,
		"palette_row": 0,
		"has_glass": has_glass,
	}


func _initialize() -> void:
	var renderer := VoxelRenderSystem.new()
	renderer._free_entry_indices = PackedInt32Array([3, 7])
	renderer._entry_glass_capable = {3: false, 7: true}
	_check(renderer._find_free_entry_offset(false) == 1,
		"an opaque entry can reuse any free slot")
	renderer._free_entry_indices = PackedInt32Array([7, 3])
	_check(renderer._find_free_entry_offset(true) == 0,
		"a glass entry cannot use a slot missing from the transparent BVH")

	var placeholder := VoxelRenderSystem._placeholder_entry(1)
	var fragment := _entry(Vector3i(9, 5, 3), true)
	fragment.atlas_origin = Vector3i(4, 6, 8)
	fragment.brick_table_base = 123
	var glass_entry := DedicatedVoxelDDAEffect._glass_entry_after_update(
		placeholder, fragment, true
	)
	_check(glass_entry.dimensions == fragment.dimensions \
		and glass_entry.atlas_origin == fragment.atlas_origin \
		and int(glass_entry.brick_table_base) == 123,
		"enabling the reservation copies all metadata to the transparent BVH")
	renderer.free()
	print("VOXEL_RENDERER_ENTRY_REUSE_SELFTEST_OK")
	quit(1 if failures > 0 else 0)
