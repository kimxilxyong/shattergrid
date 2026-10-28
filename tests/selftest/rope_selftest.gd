extends "res://tests/selftest/selftest.gd"
## Cables must behave like cables: sag under their own weight, maintain their length, and above all,
## sleep when idle. Simulating 79 cables is expensive when none of them are moving.


func _run() -> void:
	print("cables")
	var ropes := VoxelRopes.new()
	root.add_child(ropes)
	# Taut, like the cables in Lee, and another with two meters of slack to show the catenary.
	ropes.add_span(Vector3(0, 5, 0), Vector3(6, 5, 0), -0.15)
	ropes.add_span(Vector3(0, 5, 40), Vector3(6, 5, 40), 2.0)
	# A long cable whose bounds sphere reaches the explosion even though the actual segment is 20 m
	# above it. This guards against the old radius that woke distant tower cables.
	ropes.add_span(Vector3(-20, 25, 0), Vector3(20, 25, 0), -0.15)
	ropes.settle()
	_check(ropes.span_count() == 3, "all three spans are added")

	var middle := VoxelRopes.SEGMENTS / 2
	var taut_sag := 5.0 - ropes.point(0, middle).y
	var slack_sag := 5.0 - ropes.point(1, middle).y
	print("  center sag: taut %.3f m, slack %.3f m" % [taut_sag, slack_sag])
	# A taut cable sags slightly, not not at all: with negative `slack`, the chain cannot span the
	# gap, so it remains stretched and under tension, as a real cable would.
	_check(taut_sag < 0.2 and taut_sag < slack_sag * 0.1, "the taut cable stays nearly straight")
	_check(slack_sag > 1.0, "the slack cable sags under its own weight")

	# The endpoints are anchors and never move.
	_check(ropes.point(0, 0).is_equal_approx(Vector3(0, 5, 0))
		and ropes.point(0, VoxelRopes.SEGMENTS).is_equal_approx(Vector3(6, 5, 0)),
		"the anchors remain pinned")

	# The distance constraint must preserve cable length; without it, the cable stretches indefinitely.
	var longest := 0.0
	for step in VoxelRopes.SEGMENTS:
		longest = maxf(longest, ropes.point(1, step).distance_to(ropes.point(1, step + 1)))
	var rest := (6.0 + 2.0) / float(VoxelRopes.SEGMENTS)
	print("  longest span %.3f m  (rest length %.3f m)" % [longest, rest])
	_check(longest < rest * 1.25, "the segments do not stretch")

	for _frame in 40:
		await physics_frame
	_check(ropes.awake_count() == 0, "stationary cables sleep and stop consuming resources")

	# A nearby explosion wakes the adjacent span but not the one 40 m away.
	ropes.on_impact(Vector3(3, 5, 0), 2.0)
	_check(ropes.awake_count() == 1, "a nearby explosion wakes only the adjacent cable")
	var before := ropes.point(0, middle)
	for _frame in 6:
		await physics_frame
	_check(not ropes.point(0, middle).is_equal_approx(before), "and the cable actually moves")

	for _frame in 240:
		await physics_frame
	_check(ropes.awake_count() == 0, "and sleeps again when it settles")
	_check(VoxelRopes.elastic_tension_for_extension(VoxelRopes.TENSION_SLACK) == 0.0 \
			and VoxelRopes.elastic_tension_for_extension(
				VoxelRopes.TENSION_SLACK + 0.001
			) < 25.0,
		"tension ramps up smoothly without making the anchor chatter")

	# Once an endpoint breaks, it no longer uses the strong damping of a constrained span. In one
	# second it should accelerate nearly under gravity, not reach a sheet of paper's terminal speed.
	ropes.add_span(Vector3(0, 12, 80), Vector3(4, 12, 80), 0.4)
	ropes.release_anchor(ropes._spans[3], "b")
	var loose_before := ropes.point(3, VoxelRopes.SEGMENTS).y
	for _frame in 60:
		await physics_frame
	var loose_drop := loose_before - ropes.point(3, VoxelRopes.SEGMENTS).y
	print("  loose endpoint fell %.2f m in one second" % loose_drop)
	_check(loose_drop > 3.0, "a broken cable falls under gravity, not like a piece of paper")

	var surfaces := (ropes.mesh as ArrayMesh).get_surface_count()
	var vertices := 0
	if surfaces > 0:
		vertices = ((ropes.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as
			PackedVector3Array).size()
	print("  mesh: %d surface(s), %d vertices" % [surfaces, vertices])
	_check(vertices == 4 * 2 * (VoxelRopes.SEGMENTS + 1),
		"the ribbon has two vertices per point, and the shader sets its width")

	if failures == 0:
		print("VOXEL_ROPE_SELFTEST_OK")
	else:
		printerr("VOXEL_ROPE_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
