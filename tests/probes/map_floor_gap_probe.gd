extends SceneTree
## Failures remaining after fixing winding: probe noise or a second bug?
##
## For each walkable surface the ray misses, inspect the ConcavePolygonShape3D block that should
## cover it and check for triangles above that column. Three possible outcomes:
##  - a triangle exists at the correct height -> the probe failed (something blocked the ray).
##  - triangles exist in the block but not in that column -> faces are missing: a second bug.
##  - the block does not exist -> it was not rebuilt: a different bug.

var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)
	for _frame in 4:
		await physics_frame

	var space := root.world_3d.direct_space_state
	var veredictos := {}
	var muestras := {"aligned": 0, "rotated": 0}
	var fallos := {"aligned": 0, "rotated": 0}
	var ejemplos: Array[String] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for body in world.get_children():
		if not (body is VoxelBody3D) or body.get_physics_body() is RigidBody3D \
				or not (body as VoxelBody3D).collision_enabled:
			continue
		for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
			if shape.data == null:
				continue
			var cells := shape.data.get_dimensions()
			var origin := -Vector3(cells) * shape.voxel_size * 0.5
			var to_world := (body as Node3D).global_transform * shape.transform
			var encontrados := 0
			for _try in 220:
				if encontrados >= 6:
					break
				var x := rng.randi_range(0, cells.x - 1)
				var z := rng.randi_range(0, cells.z - 1)
				var y := rng.randi_range(0, cells.y - 2)
				var index := shape.data.get_cell(x, y, z)
				if index == 0 or shape.data.get_cell(x, y + 1, z) != 0:
					continue
				encontrados += 1
				# A voxel's +Y is only "up" if the Shape is not rotated in the XML.
				var clase := "aligned" if to_world.basis.y.normalized().dot(Vector3.UP) > 0.999 \
					else "rotated"
				muestras[clase] = int(muestras[clase]) + 1
				var material := TeardownPalette.material_name(index)
				if material == "foliage":
					continue
				var local := origin + Vector3(
					float(x) + 0.5, float(y) + 1.0, float(z) + 0.5
				) * shape.voxel_size
				var top := to_world * local
				var query := PhysicsRayQueryParameters3D.create(
					top + Vector3.UP * 0.4, top - Vector3.UP * 0.25
				)
				if not space.intersect_ray(query).is_empty():
					continue
				fallos[clase] = int(fallos[clase]) + 1
				var veredicto := _diagnosticar(body as VoxelBody3D, shape, Vector3i(x, y, z), local)
				veredictos[veredicto] = int(veredictos.get(veredicto, 0)) + 1
				if ejemplos.size() < 12 and veredicto != "probe: triangle at the expected location":
					ejemplos.append("  %-46s %s vox=%s dims=%s block=%d material=%s"
						% [veredicto, body.name, Vector3i(x, y, z), cells,
						VoxelBody3D.collision_block_for(shape), material])

	for clase in muestras:
		var total: int = muestras[clase]
		if total > 0:
			print("  Shapes %-10s %d/%d fail (%.1f %%)"
				% [clase, fallos[clase], total, 100.0 * float(fallos[clase]) / float(total)])
	print("\nverdict for remaining failures (excluding foliage)")
	for veredicto in veredictos:
		print("  %-46s %d" % [veredicto, veredictos[veredicto]])
	print("\nexamples")
	for linea in ejemplos:
		print(linea)
	quit()


func _diagnosticar(
	body: VoxelBody3D, shape: VoxelShape3D, voxel: Vector3i, local: Vector3
) -> String:
	var block := VoxelBody3D.collision_block_for(shape)
	var key := "%d:%d:%d:%d" % [shape.get_instance_id(),
		(voxel.x / 8) / block, (voxel.y / 8) / block, (voxel.z / 8) / block]
	var collision: CollisionShape3D = body._macro_collisions.get(key)
	if collision == null:
		return "no collision block"
	var faces: PackedVector3Array = (collision.shape as ConcavePolygonShape3D).get_faces()
	if faces.is_empty():
		return "empty block"
	var media := shape.voxel_size * 0.5
	var en_columna := 0
	var a_su_altura := 0
	for i in range(0, faces.size(), 3):
		var low := faces[i]
		var high := faces[i]
		for j in range(1, 3):
			low = low.min(faces[i + j])
			high = high.max(faces[i + j])
		if local.x < low.x - 0.001 or local.x > high.x + 0.001 \
				or local.z < low.z - 0.001 or local.z > high.z + 0.001:
			continue
		en_columna += 1
		if absf(low.y - local.y) < media and absf(high.y - local.y) < media:
			a_su_altura += 1
	if a_su_altura > 0:
		return "probe: triangle at the expected location"
	if en_columna > 0:
		return "missing faces: geometry exists in the column, but not at this height"
	return "missing faces: no geometry in this column"
