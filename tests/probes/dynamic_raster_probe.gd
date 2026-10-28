extends SceneTree
## Cost of refreshing the occupancy volume based on the size of the dirty region.
##
## `_update_dynamic_shapes` merges everything that moved this frame into one AABB, then
## `_refresh_world_cell_region` rerasterizes ALL Shapes touching that box, including static ones.
## This probe measures the cost without a GPU: it reproduces the raster loop without the texture
## upload, which is exactly what `last_region_raster_ms` measures.
var MAP := VoxelProjectPaths.teardown_map_path()
const BASE_CELL_SIZE := 0.2


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)
	var shapes: Array[VoxelShape3D] = []
	var mapa := AABB()
	for body in world.get_children():
		if not (body is VoxelBody3D):
			continue
		for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
			if shape.data == null or shape.voxel_count() == 0:
				continue
			shapes.append(shape)
			mapa = shape.world_bounds() if mapa.size == Vector3.ZERO else mapa.merge(shape.world_bounds())
	print("%d shapes, mapa %s\n" % [shapes.size(), mapa])

	# Bounds scan only, without rasterization: the fixed cost of checking 2,247 Shapes.
	var t := Time.get_ticks_usec()
	var tocan := 0
	for s in shapes:
		if s.world_bounds().intersects(mapa):
			tocan += 1
	print("bounds scan of %d Shapes: %.2f ms\n" % [
		shapes.size(), (Time.get_ticks_usec() - t) / 1000.0])

	# With the grid: same measurement, querying instead of scanning.
	var grid := VoxelShapeGrid.new()
	var construccion := Time.get_ticks_usec()
	for s2 in shapes:
		grid.insert(s2, s2.world_bounds())
	print("grid built with %d Shapes in %.0f ms\n" % [
		grid.size(), (Time.get_ticks_usec() - construccion) / 1000.0])

	# Centro en una zona construida: el spawn.
	var centro := Vector3(-64.4, 3.0, -81.0)
	print("%-6s %-8s %-9s %-7s %11s %11s" % [
		"side", "level", "cells", "Shapes", "scan", "grid"])
	for lado in [1.0, 4.0, 16.0, 64.0, 256.0]:
		for level in 4:
			var cell_size := BASE_CELL_SIZE * float(1 << level)
			var region := AABB(centro - Vector3.ONE * lado * 0.5, Vector3.ONE * lado)
			var logical_size := Vector3i(Vector3.ONE * ceilf(lado / cell_size / 2.0) * 2.0)
			var logical_low := Vector3i((region.position / cell_size).floor())
			var packed_size := logical_size / 2
			if packed_size.x <= 0:
				continue
			var buffer := PackedByteArray()
			buffer.resize(packed_size.x * packed_size.y * packed_size.z)
			var world_region := AABB(Vector3(logical_low) * cell_size, Vector3(logical_size) * cell_size)
			var n := 0
			var inicio := Time.get_ticks_usec()
			for s in shapes:
				if not s.world_bounds().intersects(world_region):
					continue
				n += 1
				buffer = s.data.rasterize_occupancy_region(
					s.global_transform, s.voxel_size, logical_low, logical_size,
					cell_size, packed_size, buffer
				)
			var barrido := (Time.get_ticks_usec() - inicio) / 1000.0
			buffer.fill(0)
			inicio = Time.get_ticks_usec()
			for s in grid.query(world_region):
				buffer = s.data.rasterize_occupancy_region(
					s.global_transform, s.voxel_size, logical_low, logical_size,
					cell_size, packed_size, buffer
				)
			print("%-6.0f %-8d %-9s %-7d %8.2f ms  %8.2f ms" % [
				lado, level, str(logical_size.x), n, barrido,
				(Time.get_ticks_usec() - inicio) / 1000.0])
		print()
	quit()
