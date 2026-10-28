extends SceneTree
## How real bodies behave: how many stay awake when untouched, whether a structure falls after one
## shot or needs a second, and what happens to cables as it falls.
var MAP := VoxelProjectPaths.teardown_map_path()

var _world: VoxelWorld3D


func _init() -> void:
	_run.call_deferred()


func _awake_report(label: String) -> void:
	_world._update_metrics()
	var awake: Array[String] = []
	for body in _world.get_dynamic_bodies():
		if is_instance_valid(body) and body.is_awake():
			var shapes := body.get_shapes()
			var where := shapes[0].world_bounds().get_center() if not shapes.is_empty() \
				else Vector3.ZERO
			awake.append("%s@%.0f,%.0f,%.0f" % [body.name, where.x, where.y, where.z])
	print("  %s: despiertos=%d  %s" % [label, awake.size(), ", ".join(awake.slice(0, 6))])


func _wait(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _state_of(shape: VoxelShape3D) -> int:
	var body := _world._body_of(shape)
	return -1 if body == null else body.state


func _run() -> void:
	_world = VoxelWorld3D.new()
	_world.show_diagnostics = false
	_world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(_world)
	TeardownMapImporter.import_map(_world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)

	print("\n=== idle, no input ===")
	for step in 5:
		await _wait(30)
		_awake_report("t=%.1fs" % (float(step + 1) * 0.5))

	var ropes := _world.get_node_or_null("TeardownRopes") as VoxelRopes
	print("\n=== cables ===")
	print("  spans=%d  endpoints with bodies=%d of %d" % [
		ropes.span_count(), ropes.bound_ends(), ropes.span_count() * 2])
	for index in ropes.span_count():
		for side in ["a", "b"]:
			if not ropes.has_body(index, side):
				print("    loose endpoint %s on span %d at %v" % [
					side, index, ropes.point(index, 0 if side == "a" else 8)])

	# The tower, firing EXACTLY where it has voxels, with the cannon's radius and energy.
	print("\n=== power tower: cannon fire at its supports ===")
	var mast: VoxelShape3D = null
	var head: VoxelShape3D = null
	for body in _world.get_children():
		if not body is VoxelBody3D:
			continue
		for shape in (body as VoxelBody3D).get_shapes():
			var bounds := shape.world_bounds()
			if Vector3(-3.9, 14.7, 70.9).distance_to(
					Vector3(-3.9, 14.7, 70.9).clamp(bounds.position, bounds.end)) < 1.0:
				mast = shape
			if Vector3(-3.9, 25.5, 70.9).distance_to(
					Vector3(-3.9, 25.5, 70.9).clamp(bounds.position, bounds.end)) < 0.5:
				head = shape
	var head_y := head.world_bounds().get_center().y
	var legs := _occupied_band(mast, 0.0, 1.2)
	print("  legs found in the lower band: %d points" % legs.size())
	for shot in mini(24, legs.size()):
		_world.damage_sphere(legs[shot], 1.1, 1.1)
		await _wait(4)
		if shot % 4 == 3 or _state_of(mast) == VoxelBody3D.State.DYNAMIC:
			print("  shot %d -> state=%d  voxels=%d" % [
				shot + 1, _state_of(mast), mast.voxel_count()])
		if _state_of(mast) == VoxelBody3D.State.DYNAMIC:
			break
	if _state_of(mast) != VoxelBody3D.State.DYNAMIC:
		print("  still standing with %d voxels. DISTANT shot:" % mast.voxel_count())
		_world.damage_sphere(Vector3(-3.92, 3.0, 62.0), 1.1, 1.1)
		await _wait(10)
		print("  after distant shot -> state=%d" % _state_of(mast))
	var mast_body := _world._body_of(mast)
	for step in 6:
		await _wait(15)
		print("    t=+%.2fs  awake=%s  boxes=%d  head y=%.2f" % [
			float(step + 1) * 0.25, mast_body.is_awake(), mast_body.compound_boxes,
			head.world_bounds().get_center().y])
	print("  head fell %.2f m  (head state=%d)" % [
		head_y - head.world_bounds().get_center().y, _state_of(head)])
	# Now remove the entire base for real, as with a bomb.
	for step in 3:
		_world.damage_sphere(Vector3(-3.92, 3.0 + float(step) * 0.8, 70.95), 3.2, 400.0)
	await _wait(90)
	print("  after destroying the entire base, head fell %.2f m" % [
		head_y - head.world_bounds().get_center().y])
	_awake_report("after tower")

	# A pipe post: the same experiment.
	print("\n=== pipe post ===")
	var post: VoxelShape3D = null
	for body in _world.get_children():
		if not body is VoxelBody3D:
			continue
		for shape in (body as VoxelBody3D).get_shapes():
			var bounds := shape.world_bounds()
			if Vector3(4.22, 6.4, -27.0).distance_to(
					Vector3(4.22, 6.4, -27.0).clamp(bounds.position, bounds.end)) < 0.2:
				post = shape
	var post_y := post.world_bounds().get_center().y
	print("  initial state=%d  voxels=%d" % [_state_of(post), post.voxel_count()])
	for shot in 6:
		_world.damage_sphere(Vector3(4.22, 5.0 + float(shot) * 0.3, -27.0), 1.1, 1.1)
		await _wait(6)
	await _wait(60)
	print("  after 6 shots at the post base: state=%d  fell %.2f m" % [
		_state_of(post), post_y - post.world_bounds().get_center().y])
	print("  rope endpoints with dead bodies: %d" % _orphans(ropes))
	quit(0)


## World-space centers of live voxels within a height band above the Shape's base.
func _occupied_band(shape: VoxelShape3D, low: float, high: float) -> Array[Vector3]:
	var found: Array[Vector3] = []
	var dimensions := shape.data.get_dimensions()
	var base := shape.world_bounds().position.y
	for y in dimensions.y:
		for z in range(0, dimensions.z, 2):
			for x in range(0, dimensions.x, 2):
				if shape.data.get_cell(x, y, z) == 0:
					continue
				var index := x + dimensions.x * (y + dimensions.y * z)
				var world := shape.voxel_center_world(index)
				if world.y - base >= low and world.y - base <= high:
					found.append(world)
	found.shuffle()
	return found


func _orphans(ropes: VoxelRopes) -> int:
	var orphan := 0
	for index in ropes.span_count():
		orphan += ropes.orphan_ends(index)
	return orphan
