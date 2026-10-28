extends "res://tests/selftest/selftest.gd"
## Connections between bodies: joints that survive a body's `PhysicsBody` changing, and cables
## attached to a body that pull on it and break when overstretched.
##
## Both bugs looked the same in the map: destroying a post's base made the post fall and detach from
## the pipe even though the connection was intact; destroying a post with cables left the cables
## hanging in midair, unaware that the post had fallen.


func _slab(world: VoxelWorld3D, origin: Vector3, dimensions: Vector3i,
		dynamic := false) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.DYNAMIC if dynamic else VoxelBody3D.State.STATIC
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 0.4, "density": 400.0})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, origin)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _run() -> void:
	print("connections between bodies")
	var world := make_world()

	# A static post and a dynamic pipe joined by a joint halfway up.
	var post := _slab(world, Vector3(0.0, 2.0, 0.0), Vector3i(4, 40, 4))
	var pipe := _slab(world, Vector3(1.0, 3.5, 0.0), Vector3i(30, 4, 4), true)
	var junction := Transform3D(Basis.IDENTITY, Vector3(0.3, 3.5, 0.0))
	var joint := PinJoint3D.new()
	world.add_child(joint)
	joint.global_transform = junction
	joint.node_a = joint.get_path_to(post.get_physics_body())
	joint.node_b = joint.get_path_to(pipe.get_physics_body())
	var record := {
		"joint": joint, "attributes": {"size": "0.3"}, "transform": junction,
		"owner_body": post, "other_body": pipe, "broken": false,
	}
	var joints := VoxelJoints.new()
	world.add_child(joints)
	joints.setup(world)
	joints.add_records([record] as Array[Dictionary])
	await physics_frame
	_check(joints.live_count() == 1, "the joint is registered as live")

	# Blow away the post's base: it becomes dynamic and gets a new `PhysicsBody`. The connection is intact.
	var old_physics := post.get_physics_body()
	post.make_dynamic()
	await physics_frame
	_check(post.get_physics_body() != old_physics, "the fallen post gets a new rigid body")
	_check(joints.live_count() == 1, "the connection to the pipe remains intact")
	_check(joint.node_a != NodePath() and joint.get_node_or_null(joint.node_a)
			== post.get_physics_body(), "reattached to the new body, not the old one")
	var post_rigid := post.get_physics_body() as RigidBody3D
	var center := post_rigid.to_global(post_rigid.center_of_mass)
	post_rigid.linear_velocity = Vector3.ZERO
	post_rigid.angular_velocity = Vector3(0.0, 0.0, 2.0)
	_check(VoxelRopes._velocity_at(post, center + Vector3.UP * 2.0).x < -3.9,
		"the cable damper accounts for angular velocity at the end of the post")
	post_rigid.angular_velocity = Vector3.ZERO
	_check(VoxelBody3D.structural_damping_for_inertia(Vector3(120.0, 4.0, 120.0)).y >= 2.0,
		"an elongated body receives post-style angular damping")
	(post.get_physics_body() as RigidBody3D).sleeping = true
	(pipe.get_physics_body() as RigidBody3D).sleeping = true
	_check(joints.wake_connected(post) == 2 \
			and not (post.get_physics_body() as RigidBody3D).sleeping \
			and not (pipe.get_physics_body() as RigidBody3D).sleeping,
		"waking the tractor also activates the attached trailer body")

	# A cable between the post and a distant anchor.
	var far := _slab(world, Vector3(12.0, 6.0, 0.0), Vector3i(6, 6, 6))
	var ropes := VoxelRopes.new()
	world.add_child(ropes)
	ropes.setup(world)
	var top := Vector3(0.0, 4.0, 0.0)
	ropes.add_span(top, Vector3(12.0, 6.0, 0.0), -0.15, post, far)
	ropes.settle()
	_check(ropes.attached_count() == 1, "the cable knows which bodies it is attached to")
	_check(ropes.anchor_pinned(0, "a") and ropes.anchor_pinned(0, "b"),
		"and is pinned at both ends")
	_check(post.physics_hold_count() == 2 and far.physics_hold_count() == 1,
		"the joint and cable accumulate retentions without interfering with each other")

	# The post falls. The cable endpoint must move with it instead of staying in midair.
	post.wake_for_interaction()
	for _frame in 20:
		await physics_frame
	var anchor := ropes.point(0, 0)
	print("  endpoint dropped %.2f m with the post" % (top.y - anchor.y))
	_check(top.y - anchor.y > 0.1, "the endpoint follows the body it is pinned to")

	# It detaches completely from the pipe, leaving only the cable to hold it. A cable does not stop
	# the fall; it turns it into a pendulum and keeps the body within the cable's maximum extension.
	joints.break_record(record)
	_check(post.physics_hold_count() == 1,
		"breaking the joint preserves the hold from the still-live rope")
	var far_point := Vector3(12.0, 6.0, 0.0)
	var rest := top.distance_to(far_point)
	var worst := 0.0
	var peak_angular_speed := 0.0
	for _frame in 180:
		await physics_frame
		worst = maxf(worst, ropes.point(0, 0).distance_to(far_point))
		peak_angular_speed = maxf(
			peak_angular_speed, (post.get_physics_body() as RigidBody3D).angular_velocity.length()
		)
	print("  hanging from cable: maximum separation %.2f m over %.2f at rest" % [worst, rest])
	_check(worst <= ropes.maximum_separation(0) + 0.05,
		"the cable pulls on the post and keeps it within its maximum stretch")
	_check(ropes.anchor_pinned(0, "a"), "it remains pinned while the cable holds")
	_check(peak_angular_speed < 20.0 \
			and (post.get_physics_body() as RigidBody3D).angular_velocity.length() < 4.0,
		"the cable-held post falls without gaining unstable angular motion")

	# A pull stronger than the cable can withstand must break it.
	var rigid := post.get_physics_body() as RigidBody3D
	rigid.apply_central_impulse(Vector3(-1.0, 0.0, 0.0) * rigid.mass * 40.0)
	for _frame in 120:
		await physics_frame
	var still_pinned := ropes.anchor_pinned(0, "a") and ropes.anchor_pinned(0, "b")
	print("  pinned at both ends after pulling: %s" % still_pinned)
	_check(not still_pinned, "it breaks when stretched beyond its maximum")
	_check(post.physics_hold_count() == 0,
		"the broken endpoint releases its physics hold")
	world.unregister_body(far)
	_check(not ropes.anchor_pinned(0, "a") and not ropes.anchor_pinned(0, "b") \
		and ropes.attached_count() == 0 and far.physics_hold_count() == 0,
		"unregistering the last endpoint removes its reference and hold")

	if failures == 0:
		print("VOXEL_CABLE_LINK_SELFTEST_OK")
	else:
		printerr("VOXEL_CABLE_LINK_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
