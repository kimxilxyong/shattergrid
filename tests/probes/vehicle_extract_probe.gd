extends SceneTree
## Verify that `TeardownMapImporter.load_named_shape` extracts the three test vehicles (small car,
## SUV, muscle car) from the real map's shared .vox file, with actual voxels and without invoking
## the full import pipeline.
var VOX_DIR := VoxelProjectPaths.teardown_vox_dir()


func _init() -> void:
	for triple in [
		["small car", "palette22.vox", "shape473"],
		["suv", "palette24.vox", "shape500"],
		["muscle car", "palette25.vox", "shape527"],
	]:
		var shape := TeardownMapImporter.load_named_shape(VOX_DIR + triple[1], triple[2])
		if shape == null:
			printerr("FAIL  %s (%s): not found" % [triple[0], triple[2]])
			continue
		var bounds := shape.local_bounds()
		print("ok     %-14s %-10s voxels=%d  size=%.2f x %.2f x %.2f m" % [
			triple[0], triple[2], shape.voxel_count(),
			bounds.size.x, bounds.size.y, bounds.size.z])
	quit(0)
