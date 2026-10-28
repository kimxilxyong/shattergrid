class_name VoxelShape3D
extends Node3D
## A cropped dense voxel volume owned by a VoxelBody3D.

signal voxels_changed(world_aabb: AABB, dirty_min: Vector3i, dirty_max: Vector3i)
signal surface_animation_changed(shape: VoxelShape3D)

var data: VoxelShapeData
var palette: VoxelPalette
var anchor_indices := PackedInt32Array()
var anchored := true
var voxel_size := 0.1
## Multiplier authored by `<vox density="…">`/`<voxbox density="…">`. The palette retains the
## material's physical density, while this value preserves the relative ballast specified by the
## level. The internal void fraction is stored separately in `physical_fill_scale`.
var density_scale := 1.0
## Internal physical volume fraction. Teardown props are 10 cm voxel art: a sheet-metal cell
## represents millimeters of material, not a solid cube. This is separate from the XML
## `density_scale` to preserve authored intent and is inherited by detached fragments.
var physical_fill_scale := 1.0
## Shape identity before the first cut. Distinguishes two fragments from the same volume (which
## require exact contact to reconnect) from separate authored pieces, whose transforms allow the
## 12 cm import margin.
var structural_lineage := 0
## A static structure needs no mass until it falls. As a fragment, its voxels still describe a
## visual envelope of masonry, beams, and gaps rather than solid cubic meters. It is denser than a
## sheet-metal prop (`0.025`), but an order of magnitude lighter than the volumetric integration
## that made Lee's power tower weigh 105 tonnes.
const STRUCTURAL_DYNAMIC_FILL_SCALE := 0.10
var renderer_slot := -1
## Optional surface effect. Kept in a separate component so the Shape remains a volume rather than
## a container for vehicle-specific or animated-material rules.
var surface_animation: VoxelSurfaceAnimation:
	get:
		return _surface_animation
	set(value):
		if _surface_animation == value:
			return
		_surface_animation = value
		surface_animation_changed.emit(self)
var _surface_animation: VoxelSurfaceAnimation
var last_damage_native_ms := 0.0
var last_damage_notify_ms := 0.0
## Most recent revision whose mutation passed through this wrapper and emitted `voxels_changed`.
var last_notified_revision := 0
## Per-Shape state that used to live on the owning VoxelBody3D. A fragment can change bodies several
## times (detach, absorption, retirement), and that state did not travel with it: the new owner
## returned 0 and the old collision stayed in Jolt forever. It lives here because it describes the
## Shape, not the body currently holding it.
var collision_revision := 0
## Cached count of voxels with hardness >= the foundation threshold, valid only for
## `foundation_revision`.
var foundation_count := 0
var foundation_revision := -1
var _foundation_threshold := -1.0
static var _damage_planner := VoxelDamagePlanner.new()


static func from_asset(entry: Dictionary, source_palette: VoxelPalette) -> VoxelShape3D:
	var shape := VoxelShape3D.new()
	shape.data = entry.data
	shape.palette = source_palette
	shape.anchor_indices = entry.get("anchors", PackedInt32Array())
	shape.anchored = bool(entry.get("anchored", true))
	shape.transform = entry.get("transform", Transform3D.IDENTITY)
	shape.sync_revision_baseline()
	return shape


func voxel_count() -> int:
	return data.get_occupied_count() if data != null else 0


func content_revision() -> int:
	return int(data.get_content_revision()) if data != null else 0


func sync_revision_baseline() -> void:
	last_notified_revision = content_revision()


func recover_unnotified_mutation() -> void:
	if data == null or last_notified_revision == content_revision():
		return
	last_notified_revision = content_revision()
	voxels_changed.emit(
		world_bounds(), Vector3i.ZERO, data.get_dimensions() - Vector3i.ONE
	)


func local_bounds() -> AABB:
	if data == null:
		return AABB()
	var size := Vector3(data.get_dimensions()) * voxel_size
	return AABB(-size * 0.5, size)


func world_bounds() -> AABB:
	var bounds := local_bounds()
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for corner_index in 8:
		var corner := bounds.position + Vector3(
			bounds.size.x if corner_index & 1 else 0.0,
			bounds.size.y if corner_index & 2 else 0.0,
			bounds.size.z if corner_index & 4 else 0.0
		)
		var world_corner := global_transform * corner
		minimum = minimum.min(world_corner)
		maximum = maximum.max(world_corner)
	return AABB(minimum, maximum - minimum)


func world_to_voxel(world_position: Vector3) -> Vector3:
	return to_local(world_position) / voxel_size + Vector3(data.get_dimensions()) * 0.5


func voxel_center_world(index: int) -> Vector3:
	var dimensions := data.get_dimensions()
	var z := index / (dimensions.x * dimensions.y)
	var rest := index - z * dimensions.x * dimensions.y
	var y := rest / dimensions.x
	var x := rest - y * dimensions.x
	var local := (Vector3(x + 0.5, y + 0.5, z + 0.5) - Vector3(dimensions) * 0.5) \
		* voxel_size
	return global_transform * local


func damage_sphere(
	world_center: Vector3, radius: float, energy: float, foundation_threshold := -1.0
) -> Dictionary:
	if data == null or palette == null:
		return {}
	var native_started := Time.get_ticks_usec()
	var result: Dictionary = _damage_planner.damage_shape(
		data, world_to_voxel(world_center), radius / voxel_size, energy,
		palette.get_hardnesses(), foundation_threshold, anchored, 16
	)
	last_damage_native_ms = (Time.get_ticks_usec() - native_started) / 1000.0
	var notify_started := Time.get_ticks_usec()
	if int(result.get("removed", 0)) > 0:
		# Keep the foundation count O(1) by subtracting what the planner just removed. Otherwise the
		# entire dense volume would need to be rescanned for every shot.
		if foundation_revision >= 0 and is_equal_approx(_foundation_threshold, foundation_threshold):
			foundation_count = maxi(
				0, foundation_count - int(result.get("removed_foundation", 0))
			)
			foundation_revision = content_revision()
		last_notified_revision = content_revision()
		voxels_changed.emit(
			world_bounds(), result.dirty_min as Vector3i, result.dirty_max as Vector3i
		)
	last_damage_notify_ms = (Time.get_ticks_usec() - notify_started) / 1000.0
	return result


## A foundation retains at least one voxel with hardness >= threshold. Recount natively only when
## the cached revision is stale, keeping a normal shot O(1).
func foundation_voxel_count(threshold: float) -> int:
	if data == null or palette == null:
		return 0
	var revision := content_revision()
	if foundation_revision != revision or not is_equal_approx(_foundation_threshold, threshold):
		foundation_count = data.count_hardness_at_least(palette.get_hardnesses(), threshold)
		foundation_revision = revision
		_foundation_threshold = threshold
	return foundation_count


func classified_components(external_anchors := PackedInt32Array()) -> Array:
	if data == null:
		return []
	return data.find_components_6_with_anchors(
		anchor_indices if anchored else external_anchors
	)


func classified_components_by_hardness(threshold: float) -> Array:
	if data == null or palette == null:
		return []
	return data.find_components_6_with_hardness_anchors(
		palette.get_hardnesses(), threshold
	)


func detach_component(indices: PackedInt32Array) -> VoxelShape3D:
	if data == null:
		return null
	var source_dimensions := data.get_dimensions()
	var detached: Dictionary = data.detach_component(indices)
	return _shape_from_detached(detached, source_dimensions)


func detach_component_preserving(
	indices: PackedInt32Array, retained_indices: PackedInt32Array
) -> VoxelShape3D:
	if data == null:
		return null
	var source_dimensions := data.get_dimensions()
	var detached: Dictionary = data.detach_component_except(indices, retained_indices)
	return _shape_from_detached(detached, source_dimensions)


func _shape_from_detached(detached: Dictionary, source_dimensions: Vector3i) -> VoxelShape3D:
	if detached.is_empty():
		return null
	var child_data: VoxelShapeData = detached.data
	var low: Vector3i = detached.offset
	var center_offset := (
		Vector3(low) + Vector3(child_data.get_dimensions()) * 0.5
		- Vector3(source_dimensions) * 0.5
	) * voxel_size
	var child := VoxelShape3D.new()
	child.data = child_data
	child.palette = palette
	child.anchored = false
	child.voxel_size = voxel_size
	child.density_scale = density_scale
	child.physical_fill_scale = physical_fill_scale
	child.structural_lineage = structural_lineage
	child.transform = global_transform * Transform3D(Basis.IDENTITY, center_offset)
	child.sync_revision_baseline()
	last_notified_revision = content_revision()
	voxels_changed.emit(world_bounds(), detached.dirty_min, detached.dirty_max)
	return child


func build_collision_boxes(max_boxes: int) -> Dictionary:
	return data.build_collision_boxes(max_boxes, voxel_size) if data != null else {"boxes": []}


func mass_properties() -> Dictionary:
	if data == null or palette == null:
		return {"mass": 0.0}
	var properties: Dictionary = data.calculate_mass_properties(
		palette.get_densities(), voxel_size
	)
	var scale := maxf(density_scale, 0.001) * maxf(physical_fill_scale, 0.001)
	properties["mass"] = float(properties.get("mass", 0.0)) * scale
	properties["inertia"] = (properties.get("inertia", Vector3.ZERO) as Vector3) * scale
	return properties


## Idempotent: an authored prop already using 0.025 is not scaled again, and a structural fragment
## does not lose mass on each remove/reactivate transition.
func calibrate_for_dynamic_structure() -> void:
	physical_fill_scale = minf(physical_fill_scale, STRUCTURAL_DYNAMIC_FILL_SCALE)
