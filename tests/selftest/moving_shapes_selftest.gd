extends "res://tests/selftest/selftest.gd"
## A body that becomes dynamic AFTER registration—such as a tower losing support or a pipe
## section breaking loose—must enter the list of Shapes tracked by the renderer every frame.
##
## If it was not tracked, the body actually fell but its transform was never uploaded to the GPU:
## an upright ghost remained in its old location, passable and indestructible, while the real voxels
## were already on the ground. Its shadow did move, which was the clue.


func _run() -> void:
	print("Shapes tracked by the renderer")
	var world := make_world()
	world.renderer_settings = VoxelRendererSettings.new()
	world.renderer_settings.sun_shadows_enabled = false
	root.add_child(world)

	# Away from the origin, where the map's posts and tower were located.
	var tower := VoxelBody3D.new()
	world.add_child(tower)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(4, 20, 4)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 0.4, "density": 400.0})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, Vector3(-3.9, 14.7, 70.9))
	tower.add_voxel_shape(shape)
	world.register_body(tower)
	await physics_frame
	var camera := Camera3D.new()
	root.add_child(camera)
	var render := VoxelRenderSystem.new()
	root.add_child(render)
	var renderer_ready := RenderingServer.get_rendering_device() != null
	if renderer_ready:
		renderer_ready = render.setup(world, camera)
		_check(renderer_ready, "the real renderer accepts the Shape")
	else:
		render.world = world
		print("  omite pose GPU: --headless no crea RenderingDevice")
	await process_frame

	_check(render.movable_shapes().is_empty(), "a static Shape is not tracked")

	var before := shape.global_transform.origin
	tower.make_dynamic()
	await physics_frame
	_check(render.movable_shapes().has(shape), "it is tracked once it becomes dynamic")

	for _frame in 30:
		await physics_frame
		await process_frame
	# Sample once more before comparing the three stages of the pose.
	if renderer_ready:
		render._process(0.0)
	var fell := before.y - shape.global_transform.origin.y
	print("  cayo %.2f m" % fell)
	_check(fell > 0.5, "it actually moves, so the renderer must track it")
	if renderer_ready:
		var pose := render.get_shape_pose_snapshot(shape)
		print("  error pose scene=%.4f m effect=%.4f m" % [
			float(pose.get("scene_error_m", INF)), float(pose.get("effect_error_m", INF)),
		])
		_check(bool(pose.get("valid", false)) and float(pose.scene_error_m) < 0.02,
			"the tracked pose matches Jolt's interpolated transform")
		_check(float(pose.get("effect_error_m", INF)) < 0.001,
			"the compositor entry receives that same pose instead of keeping the upright post")
		# The mirror changes synchronously; the POST_OPAQUE callback consumes this batch when
		# rendering the next frame. Measure it separately because the body may advance another tick
		# while waiting.
		await process_frame
		var delivered := render.get_shape_pose_snapshot(shape)
		_check(int(delivered.get("pending_gpu_updates", -1)) == 0,
			"the render callback consumes the update before declaring coherence")
		# Force the awake -> sleeping transition. The grace frame must seal the canonical pose rather
		# than leave an earlier interpolated sample as the final one.
		var rigid := tower.get_physics_body() as RigidBody3D
		rigid.freeze = true
		rigid.sleeping = true
		tower.runtime_state_changed.emit(tower)
		for _frame in 3:
			await physics_frame
			await process_frame
		render._process(0.0)
		var settled := render.get_shape_pose_snapshot(shape)
		print("  resting: sleeping=%s canonical_error=%.4f m tracked=%s" % [
			rigid.sleeping, float(settled.get("canonical_error_m", INF)),
			str(world.get_transform_tracked_body_ids()),
		])
		_check(float(settled.get("canonical_error_m", INF)) < 0.02,
			"sleeping seals the final canonical pose instead of an old interpolation")
		_check(int(settled.get("pending_gpu_updates", -1)) == 0,
			"the final pose is also flushed to Vulkan")

	if failures == 0:
		print("VOXEL_MOVING_SHAPES_SELFTEST_OK")
	else:
		printerr("VOXEL_MOVING_SHAPES_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
