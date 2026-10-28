extends "res://tests/selftest/selftest.gd"

var LEE_MAP := VoxelProjectPaths.teardown_map_path()


static func _record(position: Vector3, type := "ball", size := "0.16") -> Dictionary:
	return {
		"attributes": {"type": type, "size": size},
		"transform": Transform3D(Basis.IDENTITY, position),
	}


func _run() -> void:
	print("Teardown doors: hinges, panel, and grabbing")
	var records: Array[Dictionary] = [
		_record(Vector3(-0.6, 0.4, -0.1)),
		_record(Vector3(-0.6, 2.1, -0.1)),
		_record(Vector3(0.6, 1.2, -0.1), "ball", "0.2"),
	]
	var roles := TeardownMapImporter.classify_door_joint_records(
		records, AABB(Vector3(-0.65, 0.0, -0.1), Vector3(1.3, 2.2, 0.2))
	)
	_check(not roles.is_empty() and (roles.hinges as Array).size() == 2,
		"two vertical joints are classified as a hinge axis")
	_check(not (roles.get("latch", {}) as Dictionary).is_empty(),
		"the joint on the opposite edge is classified as a latch")
	var non_door: Array[Dictionary] = [
		_record(Vector3(0.0, 0.1, 0.0)), _record(Vector3(0.0, 0.3, 0.0)),
	]
	_check(TeardownMapImporter.classify_door_joint_records(
		non_door, AABB(Vector3.ZERO, Vector3(8.0, 0.5, 0.5))
	).is_empty(), "a horizontal mechanism is not accidentally converted into a door")

	if FileAccess.file_exists(LEE_MAP):
		var world := VoxelWorld3D.new()
		world.show_diagnostics = false
		root.add_child(world)
		# This is a real authored Lee door with two hinge joints and the third latch joint. A tight
		# crop keeps the regression cheap and avoids loading or rendering the complete map.
		var crop_center := (
			Vector3.INF if "--default-crop" in OS.get_cmdline_user_args()
			else Vector3(28.7, 0.0, -36.3)
		)
		var crop_radius := 25.0 if crop_center == Vector3.INF else 4.5
		var report := TeardownMapImporter.import_map(
			world, LEE_MAP, crop_center, crop_radius, Vector3.ZERO, true
		)
		var doors: Array[VoxelDoor3D] = []
		for child in world.get_children():
			if child is VoxelDoor3D:
				doors.append(child)
		_check(int(report.get("doors", 0)) > 0 and not doors.is_empty(),
			"the importer recognizes doors in the real map")
		var closed: VoxelDoor3D
		for door: VoxelDoor3D in doors:
			if door.is_latched():
				closed = door
				break
		_check(closed != null, "the map's third joint remains a closed latch")
		if closed != null:
			var imported_rigid := closed.get_rigid_body()
			print("  closed door: mass=", imported_rigid.mass,
				" inercia=", imported_rigid.inertia,
				" bisagras=", closed.hinge_records.size(),
				" attrs=", (closed.hinge_records[0] as Dictionary).get("attributes", {}) \
					if not closed.hinge_records.is_empty() else {})
			_check(imported_rigid.mass >= VoxelDoor3D.MIN_DOOR_MASS - 0.01 \
				and imported_rigid.mass <= VoxelDoor3D.MAX_DOOR_MASS + 0.01,
				"the hollow door leaf is not imported as a solid block weighing several tons")
			var all_hinges_are_free_pins := true
			for record: Dictionary in closed.hinge_records:
				all_hinges_are_free_pins = all_hinges_are_free_pins \
					and record.get("joint") is PinJoint3D
			_check(all_hinges_are_free_pins,
				"both hinge-axis points use freely rotating joints")
			var constraint_hold_keys: Array[String] = []
			for record: Dictionary in closed.hinge_records:
				constraint_hold_keys.append(String(record.get("physics_hold_key", "")))
			if not closed.latch_record.is_empty():
				constraint_hold_keys.append(String(closed.latch_record.get("physics_hold_key", "")))
			closed.begin_grab()
			_check(closed.is_latched(), "right-click does not unlatch an intact door")
			_check(closed.voxel_body.is_awake(), "grabbing wakes the Body without replacing its joints")
			# Absorption changes logical ownership without changing the door. The Door, joints, and
			# holds must follow the successor before the empty Body leaves the World.
			var old_owner := closed.voxel_body
			var heir := VoxelBody3D.new()
			heir.state = VoxelBody3D.State.DYNAMIC
			world.add_child(heir)
			for shape: VoxelShape3D in old_owner.get_shapes().duplicate():
				old_owner.release_voxel_shape(shape)
				heir.add_voxel_shape(shape, true, false)
			heir.rebuild_dynamic_collision()
			world.register_body(heir)
			world.body_split.emit(old_owner, [heir] as Array[VoxelBody3D])
			_check(closed.voxel_body == heir and closed.get_rigid_body() == heir.get_physics_body() \
				and heir.get_physics_body().get_meta(VoxelDoor3D.BODY_META, null) == closed,
				"the door and its interaction transfer ownership during split/merge")
			world.unregister_body(old_owner)
			old_owner.queue_free()
			var latch_point := (closed.latch_record.transform as Transform3D).origin
			world.damage_sphere(latch_point, 0.55, 100.0)
			_check(not closed.is_latched(), "destroying the latch voxels releases the door")
			var hinge_points: Array[Vector3] = []
			for record: Dictionary in closed.hinge_records:
				hinge_points.append((record.transform as Transform3D).origin)
			# Previously broken in-game state: the panel is gone, but both hinges are still live.
			# Pulling the opposite edge with exactly the player's force limit must rotate around the
			# hinge, not translate or behave like a welded wall.
			if hinge_points.size() >= 2:
				await physics_frame
				await physics_frame
				var rigid := closed.get_rigid_body()
				var opening_records: Array[String] = []
				var opening_joint_manager := world.get_node_or_null("TeardownJoints") as VoxelJoints
				for record: Dictionary in opening_joint_manager._records:
					if VoxelDoor3D._record_joint_is_live(record) and (record.get("owner_body") \
							== closed.voxel_body or record.get("other_body") == closed.voxel_body):
						var live_joint := record.get("joint") as Joint3D
						opening_records.append("%s@%s" % [
							live_joint.get_class() if live_joint != null else "null",
							VoxelDoor3D._record_position(record),
						])
				print("  live joints while opening: ", opening_records)
				var hinge_axis: Vector3 = (hinge_points.back() - hinge_points.front()).normalized()
				var hinge_center: Vector3 = (hinge_points.back() + hinge_points.front()) * 0.5
				var local_pull_point := rigid.to_local(latch_point)
				var initial_pull_point := rigid.to_global(local_pull_point)
				var initial_radial: Vector3 = initial_pull_point - hinge_center
				initial_radial -= hinge_axis * initial_radial.dot(hinge_axis)
				var player_force_limit := minf(2200.0, maxf(rigid.mass, 0.001) * 38.0)
				for _pull_frame in 75:
					var pull_point := rigid.to_global(local_pull_point)
					var radial: Vector3 = pull_point - hinge_center
					radial -= hinge_axis * radial.dot(hinge_axis)
					var tangent: Vector3 = hinge_axis.cross(radial).normalized()
					rigid.apply_force(
						tangent * player_force_limit, pull_point - rigid.global_position
					)
					rigid.sleeping = false
					await physics_frame
				var final_pull_point := rigid.to_global(local_pull_point)
				var final_radial: Vector3 = final_pull_point - hinge_center
				final_radial -= hinge_axis * final_radial.dot(hinge_axis)
				var opened_angle := absf(atan2(
					hinge_axis.dot(initial_radial.cross(final_radial)),
					initial_radial.dot(final_radial)
				))
				print("  hinged opening: degrees=", rad_to_deg(opened_angle),
					" mass=", rigid.mass, " w=", rigid.angular_velocity,
					" hinges=", closed.live_hinge_count())
				_check(opened_angle > deg_to_rad(12.0) and closed.live_hinge_count() >= 1,
					"without a latch, the player's grip rotates the leaf around its hinges")
				_check(closed._frame_collision_exceptions.is_empty(),
					"collision against the frame is restored when it leaves the recess")
			for point: Vector3 in hinge_points:
				world.damage_sphere(point, 0.55, 100.0)
			_check(closed.live_hinge_count() == 0,
				"destroying both hinge supports fully detaches the leaf")
			var transform_before_fall := closed.get_rigid_body().global_transform
			closed.end_grab()
			for _frame in 45:
				await physics_frame
			var transform_after_fall := closed.get_rigid_body().global_transform
			var live_attached_records := 0
			var joint_manager := world.get_node_or_null("TeardownJoints") as VoxelJoints
			for record: Dictionary in joint_manager._records:
				if VoxelDoor3D._record_joint_is_live(record) and (record.get("owner_body") \
						== closed.voxel_body or record.get("other_body") == closed.voxel_body):
					live_attached_records += 1
			print("  free door: before=", transform_before_fall.origin,
				" after=", transform_after_fall.origin, " awake=", closed.voxel_body.is_awake(),
				" mass=", closed.get_rigid_body().mass, " v=", closed.get_rigid_body().linear_velocity,
				" w=", closed.get_rigid_body().angular_velocity, " joints extra=", live_attached_records,
				" freeze=", closed.get_rigid_body().freeze, " boxes=", closed.voxel_body.compound_boxes)
			var moved_or_rotated := transform_before_fall.origin.distance_to(
				transform_after_fall.origin
			) > 0.025 or absf(transform_before_fall.basis.y.dot(
				transform_after_fall.basis.y
			)) < 0.995
			_check(moved_or_rotated,
				"without a latch or hinges, Jolt simulates the leaf and it stops behaving like a wall")
			var all_constraint_holds_released := true
			for hold_key: String in constraint_hold_keys:
				all_constraint_holds_released = all_constraint_holds_released \
					and not closed.voxel_body.has_physics_hold(hold_key)
			_check(all_constraint_holds_released,
				"breaking the door atomically releases the holds for all its joints")
		world.queue_free()
	else:
		print("  SKIP Lee map unavailable; synthetic classification was run")

	print("")
	if failures == 0:
		print("VOXEL_DOOR_SELFTEST_OK")
	else:
		printerr("VOXEL_DOOR_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
