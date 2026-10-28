class_name ColliderDebug3D
extends MeshInstance3D
## Draw the collision mesh in front of the crosshair in green. If a ground artifact appears as a
## wireframe, collision geometry is present and rendering is at fault; if it appears clean, the
## reverse is true.
##
## `debug_collisions_hint` is unsuitable here: the static scene has one CollisionShape3D per
## macrocell—nearly a million across the full map—and asking Godot to wireframe them all stalls
## startup. Draw only those around the player, querying Jolt to find them.

## View distance: also the distance at which the box is placed in front of the camera and its
## half-width, so it covers from the player's feet to twice that distance in the viewed direction.
## The real triangle mesh is drawn, with hundreds of vertices per shape, so keep the range short.
const REACH := 4.0

## Tope de vertices, para que un sitio muy poblado no congele el frame.
const MAX_VERTICES := 300_000

var _camera: Camera3D
var _exclude: Array[RID] = []
var _origin := Vector3.INF


func setup(camera: Camera3D, exclude: Array[RID]) -> void:
	_camera = camera
	_exclude = exclude


func _process(_delta: float) -> void:
	if _camera == null:
		return
	# Place the volume in front of the camera, not centered on the player: what is behind is not
	# visible, and spending work there would reduce the range in the direction being viewed.
	var center := _camera.global_position - _camera.global_basis.z * REACH
	# Rebuild after movement or rotation, both of which move the center: rebuilding the mesh every
	# frame costs much more than the query.
	if _origin.distance_to(center) < 1.0:
		return
	_origin = center
	var query := PhysicsShapeQueryParameters3D.new()
	var region := BoxShape3D.new()
	region.size = Vector3.ONE * REACH * 2.0
	query.shape = region
	query.transform = Transform3D(Basis.IDENTITY, center)
	query.exclude = _exclude
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.1, 1.0, 0.35)
	var vertices := PackedVector3Array()
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query, 4096):
		var collider := hit.collider as CollisionObject3D
		if collider == null:
			continue
		var node := collider.shape_owner_get_owner(collider.shape_find_owner(int(hit.shape)))
		var collision := node as CollisionShape3D
		if collision == null or collision.shape == null:
			continue
		# The static scene uses a triangle mesh per macrocell, not boxes, so filtering for BoxShape3D
		# left the viewer empty. Draw the actual outline rather than its bounding box: a box around an
		# irregular mesh does not show where the surface is, which is exactly what must be compared
		# with the rendered result.
		var outline: ArrayMesh = collision.shape.get_debug_mesh()
		if outline.get_surface_count() == 0:
			continue
		var transform := collision.global_transform
		for point: Vector3 in outline.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array:
			vertices.append(transform * point)
		if vertices.size() >= MAX_VERTICES:
			break
	if vertices.is_empty():
		mesh = null
		return
	var immediate := ImmediateMesh.new()
	immediate.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for point in vertices:
		immediate.surface_add_vertex(point)
	immediate.surface_end()
	mesh = immediate
