extends "res://tests/selftest/selftest.gd"
## Muzzle flash: it appears at the muzzle, faces along the bore, and respects the cannon's firing rate.

class Gunner:
	extends Node3D
	var camera: Camera3D
	func _init() -> void:
		camera = Camera3D.new()
		add_child(camera)


func _run() -> void:
	print("tank muzzle flash")
	var world := make_world()
	make_box_body(world, Vector3(80, 1, 80), Vector3(0, -0.5, 0))
	var gunner := Gunner.new()
	root.add_child(gunner)
	var tank := VoxelTank3D.spawn(world, Vector3(0, 1.0, 0), gunner)
	_check(tank != null and tank.barrel != null, "the tank imports with a cannon")
	if tank == null or tank.barrel == null:
		quit(1)
		return
	for _frame in 120:
		await physics_frame

	var muzzle := tank.muzzle_transform()
	var turret_center := tank.turret.get_shapes()[0].world_bounds().get_center()
	var barrel_center := tank.barrel.get_shapes()[0].world_bounds().get_center()
	var forward := -muzzle.basis.z
	print("  muzzle: %v  axis: %v" % [muzzle.origin, forward])
	# The muzzle is farther from the turret than the bore's center: if the axis sign is reversed, the
	# flash appears inside the turret and points toward the driver.
	_check(
		muzzle.origin.distance_to(turret_center) > barrel_center.distance_to(turret_center) + 1.0,
		"the muzzle is in front of the cannon, not behind it"
	)
	_check(
		forward.dot((barrel_center - turret_center).normalized()) > 0.9,
		"the muzzle-flash axis follows the bore"
	)
	_check(absf(forward.y) < 0.45, "the idle cannon does not point at the sky or ground")

	var before := int(world.get_metrics().get("active_particles", 0))
	var hull_physics := tank.hull.get_physics_body()
	var rest_pitch := tank.hull_transform().basis.x.y
	_check(tank.fire(), "the cannon fires")
	await process_frame
	var after := int(world.get_metrics().get("active_particles", 0))
	print("  puffs: %d -> %d" % [before, after])
	# A few large effects: fire, ring, smoke, and ground dust. Hundreds of particles would mean
	# someone brought back the little cubes, which look like bugs.
	_check(after > before + 200 and after < before + 500, "the shot fills the muzzle with fire and smoke")

	var kick := 0.0
	for _frame in 30:
		await physics_frame
		kick = maxf(kick, absf(tank.hull_transform().basis.x.y - rest_pitch))
	print("  hull mass: %.0f kg; pitch impulse: %.3f" % [hull_physics.mass, kick])
	# Recoil should be visible without launching the tank: between one and seven degrees of pitch.
	_check(kick > 0.015 and kick < 0.13, "recoil lifts the tank without taking it off the ground")
	_check(not tank.fire(), "the cannon cannot fire again while reloading")

	print("failures: ", failures)
	quit(1 if failures > 0 else 0)
