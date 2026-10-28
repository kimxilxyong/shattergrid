class_name VoxelShapeGrid
extends RefCounted
## Uniform grid of Shapes, used to ask "which ones intersect this box" without scanning them all.
##
## Refreshing the occupancy volume scanned all 2,312 Shapes in Lee, requesting `world_bounds()` one
## at a time: a measured 10 ms per region, with up to four regions per frame. That scan was the
## entire cost—rasterizing a 4 m box takes 0.05 ms, while a 1 m region with no Shapes cost as much
## as one containing four. The grid is built once, and only moving Shapes (awake bodies) are
## reinserted.

## 8 m: a typical Shape in Lee occupies one or two cells, and a debris piece occupies one.
const CELL_SIZE := 8.0
## Shapes occupying more cells than this are stored separately and checked on every query:
## reinserting one would cost more than the scan we avoid. Lee's largest is 22x9x18 m, or 12 cells.
const MAX_CELLS := 512

var _cells := {}
## Instance ID -> occupied cells, so a Shape can be removed without scanning the grid.
var _placed := {}
var _oversized := {}


static func _cell_of(point: Vector3) -> Vector3i:
	return Vector3i(
		floori(point.x / CELL_SIZE), floori(point.y / CELL_SIZE), floori(point.z / CELL_SIZE)
	)


func insert(shape: VoxelShape3D, bounds: AABB) -> void:
	var key := shape.get_instance_id()
	remove_id(key)
	var low := _cell_of(bounds.position)
	var high := _cell_of(bounds.end)
	var span := high - low + Vector3i.ONE
	if span.x * span.y * span.z > MAX_CELLS:
		_oversized[key] = shape
		return
	var occupied: Array[Vector3i] = []
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var cell := Vector3i(x, y, z)
				if not _cells.has(cell):
					_cells[cell] = []
				(_cells[cell] as Array).append(shape)
				occupied.append(cell)
	_placed[key] = occupied


func remove_id(key: int) -> void:
	_oversized.erase(key)
	if not _placed.has(key):
		return
	for cell: Vector3i in _placed[key]:
		var bucket: Array = _cells.get(cell, [])
		for position in range(bucket.size() - 1, -1, -1):
			# A Variant retains the ID of a freed Object, but casting it raises an error before a
			# typed variable can check for null. Validate the Variant first to clean the cell without
			# touching the dead object.
			var candidate: Variant = bucket[position]
			if not is_instance_valid(candidate):
				bucket.remove_at(position)
				continue
			var shape := candidate as VoxelShape3D
			if shape == null or shape.get_instance_id() == key:
				bucket.remove_at(position)
		if bucket.is_empty():
			_cells.erase(cell)
	_placed.erase(key)


func has_id(key: int) -> bool:
	return _placed.has(key) or _oversized.has(key)


func size() -> int:
	return _placed.size() + _oversized.size()


## Shapes that actually overlap the box, already filtered by `world_bounds()`.
func query(region: AABB) -> Array[VoxelShape3D]:
	var result: Array[VoxelShape3D] = []
	var seen := {}
	var candidates: Array = _oversized.values()
	var low := _cell_of(region.position)
	var high := _cell_of(region.end)
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var bucket: Array = _cells.get(Vector3i(x, y, z), [])
				if not bucket.is_empty():
					candidates.append_array(bucket)
	for candidate: Variant in candidates:
		if not is_instance_valid(candidate):
			continue
		var shape := candidate as VoxelShape3D
		if shape == null:
			continue
		var key := shape.get_instance_id()
		if seen.has(key):
			continue
		seen[key] = true
		if shape.voxel_count() > 0 and shape.world_bounds().intersects(region):
			result.append(shape)
	return result
