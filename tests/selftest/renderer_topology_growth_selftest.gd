extends SceneTree
## Regression test for debris that had collision but no image: the BVH must support more leaves than
## its initial capacity and rebuild the transparent subset when its size changes.



var failures := 0


## `assert` is removed in release builds: a test that relies only on assertions would always pass.
## Failures are counted and reflected in the exit code.
func _check(condition: bool, message := "") -> void:
	if not condition:
		failures += 1
		printerr("  FAIL ", message)

func _initialize() -> void:
	var initial: Array[Dictionary] = []
	for index in 8:
		initial.append(VoxelRenderSystem._placeholder_entry(index))
	var grown: Array[Dictionary] = []
	for index in 520:
		grown.append(VoxelRenderSystem._placeholder_entry(index))
	_check(DedicatedVoxelDDAEffect._topology_must_rebuild(
		false, initial.size(), grown.size(), false
	),
		"changing the leaf count must rebuild topology even if the palette is unchanged")
	var built := DedicatedVoxelBVH.build_entries(grown)
	_check(not built.is_empty() and int(built.node_count) == grown.size() * 2 - 1,
		"the expanded BVH must contain all its leaves")
	var animation := VoxelSurfaceAnimation.create(
		122, AABB(Vector3(0, 0, 0), Vector3(78, 13, 38)), 4.0, 4.0
	)
	# The loop wraps around the profile's octagonal perimeter, not the link spacing or the rectangle:
	# the shader calculates the same value, and any mismatch shifts the phase on every loop.
	var perimeter := animation.perimeter_cells()
	_check(is_equal_approx(perimeter, 168.627417),
		"the chamfered-profile perimeter matches the one derived by the shader")
	animation.advance(perimeter + 1.25, 2.5)
	_check(is_equal_approx(animation.offsets.x, 1.25),
		"the offset wraps around the profile perimeter")
	var animated_entry := VoxelRenderSystem._placeholder_entry(0)
	animated_entry.surface_animation = animation.gpu_parameters()
	var packed := DedicatedVoxelBVH.pack_entry(animated_entry)
	_check(packed.size() == 240, "the Shape ABI reserves 240 bytes with surface animation")
	var floats := packed.to_float32_array()
	_check(is_equal_approx(floats[48], 1.25) and is_equal_approx(floats[49], 2.5)
		and roundi(floats[50]) == 122 and is_equal_approx(floats[51], 1.0),
		"offsets, material, and activation retain their ABI positions")
	_check(Vector3(floats[52], floats[53], floats[54]) == Vector3.ZERO
		and is_equal_approx(floats[55], 4.0)
		and Vector3(floats[56], floats[57], floats[58]) == Vector3(78, 13, 38)
		and is_equal_approx(floats[59], 4.0),
		"bounds, link spacing, and profile chamfer reach the shader intact")
	_check(VoxelRenderSystem._grow_macro_atlas(Vector3i(32, 32, 256)) \
		== Vector3i(32, 32, 512))
	print("VOXEL_RENDERER_TOPOLOGY_GROWTH_SELFTEST_OK")
	quit(1 if failures > 0 else 0)
