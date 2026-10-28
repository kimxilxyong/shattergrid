extends "res://tests/selftest/selftest.gd"
## Road wheels rotate as the tank advances and move with the suspension, without changing the
## resting height after their geometry is detached from the hull.

class Gunner:
	extends Node3D
	var camera: Camera3D

	func _init() -> void:
		camera = Camera3D.new()
		add_child(camera)


func _run() -> void:
	print("tank road wheels")
	var world := make_world()

	make_box_body(world, Vector3(60, 1, 60), Vector3(0, -0.5, 0))

	var gunner := Gunner.new()
	root.add_child(gunner)
	var tank := VoxelTank3D.spawn(world, Vector3(0, 1.0, 0), gunner)
	_check(tank != null, "the tank is imported")
	if tank == null:
		quit(1)
		return

	for _frame in 150:
		await physics_frame
	var bottom := tank.hull.get_shapes()[0].world_bounds().position.y
	print("  hull resting height: %.3f m" % bottom)
	# Reference measured with the running gear baked into the hull, before separating its visuals.
	_check(absf(bottom - 0.154) < 0.06, "the tank rests at the same height as before")

	var visuals: Array = tank.vehicle._wheel_visuals
	_check(visuals.size() == 14, "all fourteen authored road wheels are wheel visuals")
	if visuals.is_empty():
		quit(1)
		return
	var probe := visuals[0].shape as VoxelShape3D
	var rest_basis := probe.global_basis
	var rest_height := probe.global_position.y - bottom

	# The disc is drawn on the hull between 0.20 and 1.10 m above the track: if the spring leaves it
	# elsewhere, the road wheels hang below the track and the tank looks broken.
	print("  settled road-wheel height: %.3f m above the hull" % rest_height)
	_check(absf(rest_height - 0.65) < 0.08, "the settled road wheel stays where the art placed it")
	var start := tank.hull_transform().origin
	tank.vehicle.set_control_override(true, 1.0, 0.0, false)
	var spin := 0.0
	var travel := 0.0
	for _frame in 300:
		await physics_frame
		var now := probe.global_basis
		spin = maxf(spin, maxf(
			rest_basis.x.angle_to(now.x),
			maxf(rest_basis.y.angle_to(now.y), rest_basis.z.angle_to(now.z))
		))
		travel = maxf(travel, absf(
			probe.global_position.y - tank.hull.get_shapes()[0].world_bounds().position.y
			- rest_height
		))
	tank.vehicle.set_control_override(false)
	print("  tank travel: %.2f m" % start.distance_to(tank.hull_transform().origin))
	print("  maximum road-wheel rotation: %.1f degrees; travel: %.3f m" % [
		rad_to_deg(spin), travel
	])
	_check(spin > 0.5, "the road wheels rotate while moving")
	_check(travel > 0.01, "the road wheels move relative to the hull with the suspension")

	print("failures: ", failures)
	quit(1 if failures > 0 else 0)
