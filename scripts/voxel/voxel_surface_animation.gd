class_name VoxelSurfaceAnimation
extends RefCounted
## Per-Shape visual parameters for materials that simulate movement across a surface.
##
## Distances and offsets are in voxel cells. This component knows nothing about vehicles or the
## renderer: producers advance the offsets, and the renderer watches `revision` to upload them.

var material_index := 0
var cell_bounds := AABB()
## Pattern pitch in cells. The shader distributes an integer number of links around the perimeter
## so the loop closes without a broken seam; this is the nominal pitch.
var link_pitch := 4.0
## Profile corner chamfer in cells. The shader uses it to identify the ring's outer layer, the only
## layer that can be emptied without opening a hole into the interior.
var profile_chamfer := 0.0
var offsets := Vector2.ZERO
var revision := 0


static func create(
	material: int, bounds: AABB, pitch := 4.0, chamfer := 0.0
) -> VoxelSurfaceAnimation:
	var animation := VoxelSurfaceAnimation.new()
	animation.material_index = clampi(material, 0, 255)
	animation.cell_bounds = bounds
	animation.link_pitch = maxf(pitch, 1.0)
	animation.profile_chamfer = maxf(chamfer, 0.0)
	animation.revision = 1
	return animation


## Pattern loop length: the profile perimeter in the volume's long/height plane. It is an octagon
## with ends chamfered at 45 degrees. This must match the shader's calculation exactly; wrapping the
## offset by another value introduces a phase jump on every loop.
func perimeter_cells() -> float:
	var extent := Vector2(cell_bounds.size.x, cell_bounds.size.y) * 0.5 - Vector2.ONE * 0.5
	var chamfer := minf(profile_chamfer, minf(extent.x, extent.y))
	return 2.0 * (2.0 * (extent.x - chamfer) + 2.0 * (extent.y - chamfer)) + 4.0 * chamfer * sqrt(2.0)


func advance(left_cells: float, right_cells: float) -> void:
	var loop := maxf(perimeter_cells(), 1.0)
	set_offsets(
		fposmod(offsets.x + left_cells, loop), fposmod(offsets.y + right_cells, loop)
	)


func set_offsets(left: float, right: float) -> void:
	var next := Vector2(left, right)
	if offsets.is_equal_approx(next):
		return
	offsets = next
	revision += 1


func gpu_parameters() -> Dictionary:
	return {
		"animation": Vector4(offsets.x, offsets.y, float(material_index), 1.0),
		"bounds_min": cell_bounds.position,
		"bounds_max": cell_bounds.end,
		"link_pitch": link_pitch,
		"profile_chamfer": profile_chamfer,
	}
