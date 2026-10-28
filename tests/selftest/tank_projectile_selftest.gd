extends "res://tests/selftest/selftest.gd"
## Tank cannon projectile: drops as expected, does not pass through objects at high speed, and
## detonates BEHIND the armor instead of on its surface.

class Gunner:
	extends Node3D
	var camera: Camera3D
	func _init() -> void:
		camera = Camera3D.new()
		add_child(camera)


func _run() -> void:
	print("cannon projectile")
	await _test_ballistics()
	await _test_penetration()
	await _test_tank_fires()
	quit(1 if failures > 0 else 0)


## Free fall: with nothing to hit, the projectile follows a parabola. Compare it with ½·g·t²,
## the analytical reference; drag can only reduce the distance, never increase it.
func _test_ballistics() -> void:
	var world := make_world()
	var start := Vector3(0.0, 50.0, 0.0)
	var muzzle := Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP), start)
	var shell := Projectile.spawn(world, muzzle)
	_check(shell != null, "the 'ap' ammunition entry exists and can be instantiated")
	if shell == null:
		world.queue_free()
		return
	_check_is_voxel_dart(shell)
	var elapsed := 0.0
	var step := 1.0 / Engine.physics_ticks_per_second
	for _frame in 30:
		await physics_frame
		elapsed += step
	_check(is_instance_valid(shell), "it does not detonate in midair")
	if not is_instance_valid(shell):
		world.queue_free()
		return
	var drop := start.y - shell.global_position.y
	var free_fall := 0.5 * Projectile.GRAVITY * elapsed * elapsed
	var travel := shell.global_position.x - start.x
	print("  t=%.3f s  travel=%.1f m  drop=%.3f m (free %.3f m)" % [
		elapsed, travel, drop, free_fall
	])
	_check(drop > free_fall * 0.85 and drop <= free_fall * 1.01, "the drop follows a parabola")
	# With quadratic drag, velocity follows v0/(1+k·v0·t): always below the vacuum trajectory,
	# never above it or slowed to a stop.
	var vacuum: float = float(Projectile.AMMO.ap.speed) * elapsed
	_check(travel < vacuum and travel > vacuum * 0.9, "drag slows it without stopping it")
	world.queue_free()
	await process_frame


## The bullet uses the actual `.vox` model, not a box or a table in code: verify that the asset
## loads, appears fully in the MultiMesh, and is oriented like a dart—with a one-voxel tip at the
## nose and wide fins at the tail. In headless mode, the silent video driver does not return the
## MultiMesh transforms, so measure the silhouette in the model and the draw count in the instances.
func _check_is_voxel_dart(shell: Projectile) -> void:
	var asset := Projectile.model()
	_check(not asset.is_empty(), "the projectile .vox model loads")
	if asset.is_empty():
		return
	var data: VoxelShapeData = asset.shapes[0].data
	var dimensions := data.get_dimensions()
	var occupied := data.get_live_indices().size()
	var drawn := 0
	for child in shell.get_children():
		if child is MultiMeshInstance3D:
			drawn += (child as MultiMeshInstance3D).multimesh.instance_count
	var unit := float(Projectile.AMMO.ap.caliber) / float(Projectile.MODEL_BODY_VOXELS)
	print("  dart: %s voxels at %.3f m, %d occupied, %d drawn" % [
		dimensions, unit, occupied, drawn
	])
	_check(occupied > 100, "the dart is made of voxels, not a loose box")
	_check(drawn == occupied, "the entire model is drawn, including steel and tracer")
	# The long axis is the direction of travel: a dart is much longer than it is wide.
	_check(dimensions.z > dimensions.x * 3, "the model is a dart, not a brick")
	_check(_slice_count(data, 0) == 1, "the sharp tip points forward (-Z), in the direction of travel")
	_check(
		_slice_count(data, dimensions.z - 1) > 1,
		"the base is wider than the tip: it holds the fins and tracer"
	)
	# The barrel matches the ammunition caliber: five 24 mm voxels equal the real 120 mm caliber.
	_check(
		is_equal_approx(unit * Projectile.MODEL_BODY_VOXELS, float(Projectile.AMMO.ap.caliber)),
		"the barrel thickness matches the caliber"
	)


## Occupied voxels in the model's z slice.
func _slice_count(data: VoxelShapeData, z: int) -> int:
	var dimensions := data.get_dimensions()
	var count := 0
	for y in dimensions.y:
		for x in dimensions.x:
			if data.get_cell(x, y, z) != 0:
				count += 1
	return count


## Penetration: a 40 cm wall at 30 m. At 420 m/s, the projectile travels 7 m per physics step, so
## without swept tracing it would pass through without registering a hit.
func _test_penetration() -> void:
	var world := make_world()
	var wall_x := 30.0
	var thickness := 0.4
	make_box_body(world, Vector3(thickness, 8.0, 8.0), Vector3(wall_x, 50.0, 0.0))
	var blasts: Array[Dictionary] = []
	world.explosion_started.connect(
		func(center: Vector3, radius: float, _energy: float) -> void:
			blasts.append({"center": center, "radius": radius})
	)
	var face := wall_x - thickness * 0.5
	var muzzle := Transform3D(
		Basis.looking_at(Vector3.RIGHT, Vector3.UP), Vector3(0.0, 50.0, 0.0)
	)
	var shell := Projectile.spawn(world, muzzle)
	for _frame in 20:
		await physics_frame
		if not blasts.is_empty():
			break
	_check(not blasts.is_empty(), "the wall stops the projectile; it does not pass through without detonating")
	_check(not is_instance_valid(shell), "the projectile is removed after detonation")
	if blasts.is_empty():
		world.queue_free()
		return
	var center: Vector3 = blasts[0].center
	var depth := center.x - face
	print("  wall face x=%.2f  charge x=%.2f  (%.2f m inside)" % [face, center.x, depth])
	# What distinguishes an AP round from a grenade: the charge detonates beyond the plate, not against it.
	_check(depth > 0.5, "the charge detonates behind the armor, not on its surface")
	_check(depth <= float(Projectile.AMMO.ap.penetration) + 0.01, "it does not exceed its spec penetration")
	# The parabolic drop cannot significantly deflect the wall impact: at 30 m it is only centimeters.
	_check(absf(center.z) < 0.5 and absf(center.y - 50.0) < 1.0, "it impacts where it is aimed")
	world.queue_free()
	await process_frame


## Integration: the tank cannon fires a real projectile and does not shoot itself, even though
## the muzzle starts inside the turret's envelope.
func _test_tank_fires() -> void:
	var world := make_world()
	make_box_body(world, Vector3(80, 1, 80), Vector3(0, -0.5, 0))
	var gunner := Gunner.new()
	root.add_child(gunner)
	var tank := VoxelTank3D.spawn(world, Vector3(0, 1.0, 0), gunner)
	_check(tank != null, "the tank imports successfully")
	if tank == null:
		world.queue_free()
		return
	for _frame in 90:
		await physics_frame
	var blasts := 0
	world.explosion_started.connect(
		func(_center: Vector3, _radius: float, _energy: float) -> void: blasts += 1
	)
	_check(tank.fire(), "the cannon fires")
	await physics_frame
	var shells := 0
	for child in world.get_children():
		if child is Projectile:
			shells += 1
	_check(shells == 1, "firing adds one projectile to the world")
	# Two frames at 420 m/s cover 14 m: if the ray hit the tank itself, it would already have detonated.
	await physics_frame
	_check(blasts == 0, "the projectile does not detonate on the tank that fired it")
	world.queue_free()
	gunner.queue_free()
	await process_frame
