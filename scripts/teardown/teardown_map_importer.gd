class_name TeardownMapImporter
extends RefCounted
## Loads a converted Teardown map (`main.xml` + `vox/`) into VoxelWorld3D.
##
## FOR LOCAL RESEARCH ONLY. Map geometry is owned by Tuxedo Labs: this script includes no game data
## and only reads files provided by the user from their own licensed copy. Those local resources are
## kept outside version control.
##
## Format conventions, taken from Teardown-Converter (`write_scene.cpp`):
##
## * `rot="a b c"` son grados Euler compuestos como Rx(a)·Ry(b)·Rz(c) (`QuatEulerRad`).
## * The `pos` of a `<vox>` is not the volume corner: the converter adds half the width in x and y,
##   then rotates the node 90 degrees around X because MagicaVoxel is Z-up and Teardown is Y-up.
##   The volume ends up centered on X and Z and resting on Y; this rotation means the file array's
##   `j` axis points toward world −Z (hence the mirror in `set_cells_from_xyzi`).
## * `<voxbox>` applies neither correction: its `pos` is the corner as-is.
## * `scale` is voxel size × 10, so each voxel measures `scale * 0.1` meters.
## * A `<joint>` axis is its local +Z, as with Godot's `HingeJoint3D`.
## * Physics comes from the palette band; appearance comes from RGBA+MATL: see [TeardownPalette].
##
## The full map with collision automatically uses `TeardownMapCache`. The first run builds and saves
## merged faces. Later runs restore the initial area and stream distant regions. The
## `--rebuild-teardown-cache`, `--no-teardown-cache`, and `--eager-teardown-cache` flags let each path
## be debugged explicitly.

const DEFAULT_RADIUS := 45.0
const TeardownBoundary := preload("res://scripts/teardown/teardown_boundary_3d.gd")
const VoxelBodyScript := preload("res://scripts/voxel/voxel_body_3d.gd")
const VoxelShapeScript := preload("res://scripts/voxel/voxel_shape_3d.gd")

## Maximum number of dense cells allowed to load. The full map has 443 M cells, and the engine
## stores one byte per cell, so an unrestricted import would exhaust RAM before finishing.
const CELL_BUDGET := 500_000_000
## Radius used to find the body to which a cable endpoint is attached. `<location>` elements for a
## `<rope>` land on the insulator, not inside the post, so some clearance is needed.
const ANCHOR_SEARCH := 1.5
## When using the cache, only this area enters Jolt before the player is released. The rest is
## prefetched by proximity under the `VoxelWorld3D` budget; 45 m easily cover the initial fall and
## surrounding area.
const INITIAL_COLLISION_RADIUS := 45.0
## A 10 cm cell in a mobile prop describes its envelope, not one solid liter of steel/wood. The full
## Lee sample gives the same correction across independent categories: small car 33.868 -> 847 kg,
## SUV 61.316 -> 1,533 kg, muscle car 72.799 -> 1,820 kg, wooden crate 1.316 -> 32.9 kg. XML
## `density` still multiplies this base, and static structures are unchanged: their fragments do
## represent real structural volume.
const AUTHORED_DYNAMIC_FILL_SCALE := 0.025
## How often to yield a frame to the engine so the loading screen can redraw. The importer blocks:
## without this, the window freezes for 9 s (35 s the first time) and appears hung. 200 ms yields
## about 45 frames on a warm load; actual cost is measured by `progress_ms`.
const PROGRESS_FRAME_INTERVAL := 200
## Root elements per batch. Lee's large `<group>` has 1,539 children; processing them in one block
## would leave nothing to show for half the loading time.
const PROGRESS_CHUNK := 64

## Segments per cable. With negative `slack`, the line is straight and one segment would suffice,
## but maps with slack need a curve, and eight segments render it without visible kinks.

var _collision := true
var _ropes: VoxelRopes
var _water: VoxelWaterSystem
var _pending_ropes: Array[Dictionary] = []
var _vox_cache := {}
var _palette_cache := {}
var _bodies_bounds: Array[Dictionary] = []
var _pending_joints: Array[Dictionary] = []
var _resolved_joint_records: Array[Dictionary] = []
var _resolved_joint_keys := {}
var _pending_vehicles: Array[Dictionary] = []
var _compiled_cache_context := {}
var _compiled_cache_entries: Array = []
var _compiled_cache_source: Array = []
var _compiled_cache_cursor := 0
var _compiled_cache_hit := false
var _compiled_cache_broken := false
var _compiled_face_blocks := 0
var _last_attached_shape: VoxelShape3D
var _progress := Callable()
var _progress_last := 0
var _progress_frames := 0
var _progress_usec := 0
var _planner := VoxelMapImportPlanner.new()
var _scene_traversal := VoxelMapSceneTraversal.new()
var _scene_committer := VoxelMapSceneCommitter.new()
var _report := {
	"shapes": 0, "voxboxes": 0, "bodies": 0, "joints": 0,
	"authored_dynamic_bodies": 0, "imported_dynamic_bodies": 0, "density_overrides": 0,
	"doors": 0, "latched_doors": 0,
	"vehicles_declared": 0, "vehicles_drivable": 0, "vehicle_wheels": 0,
	"vehicle_lights": 0, "vehicle_visual_bodies": 0,
	"ropes": 0, "rope_anchors": 0, "no_collide": 0,
	"water_surfaces": 0, "water_triangles": 0, "water_area_m2": 0.0,
	"boundary_vertices": 0, "boundary_segments": 0, "boundary_area_m2": 0.0,
	"boundary_width": 0.0, "boundary_depth": 0.0,
	"cells": 0, "voxels": 0, "skipped_far": 0, "skipped_budget": 0, "skipped_joints": 0,
	"decode_ms": 0, "collision_ms": 0, "faces_ms": 0.0,
}


## `xml_path` is absolute (the map is outside res://). `center` and `radius` crop around a point in
## map coordinates, and `offset` shifts the entire map within the world.
static func import_map(
	world: VoxelWorld3D, xml_path: String, center := Vector3.INF, radius := DEFAULT_RADIUS,
	offset := Vector3.ZERO, collision := true
) -> Dictionary:
	var importer := TeardownMapImporter.new()
	importer._collision = collision
	# `_run` yields frames only when a loading screen is listening, so it completes here without
	# suspending and returns the Dictionary. Call through `Callable` because the analyzer requires
	# `await` for any coroutine, which would otherwise need to be propagated to all 37 test harnesses
	# that import maps without a UI.
	var result: Variant = importer._run.call(world, xml_path, center, radius, offset)
	if result is Dictionary:
		return result
	push_error("TeardownMapImporter: import without a loading screen was suspended")
	return {}


## Like [method import_map], but yields frames to the engine so a loading screen can be shown.
## `progress` receives `(fraction: float, label: String, source: String)`; `source` is sent only
## when it changes and indicates whether collision comes from the compiled cache or must be built.
static func import_map_progressive(
	world: VoxelWorld3D, xml_path: String, progress: Callable, center := Vector3.INF,
	radius := DEFAULT_RADIUS, offset := Vector3.ZERO, collision := true
) -> Dictionary:
	var importer := TeardownMapImporter.new()
	importer._collision = collision
	importer._progress = progress
	return await importer._run(world, xml_path, center, radius, offset)


func _run(
	world: VoxelWorld3D, xml_path: String, center: Vector3, radius: float, offset: Vector3
) -> Dictionary:
	_progress_last = Time.get_ticks_msec()
	await _step(0.02, "Looking for compiled cache…")
	_compiled_cache_context = TeardownMapCache.prepare(
		xml_path, center, radius, offset, _collision
	)
	_report["cache_status"] = _compiled_cache_context.get("status", "disabled")
	_report["cache_load_ms"] = 0
	_report["cache_save_ms"] = 0
	_report["cache_bytes"] = 0
	if bool(_compiled_cache_context.get("enabled", false)):
		var cache_started := Time.get_ticks_msec()
		var payload := TeardownMapCache.load_payload(_compiled_cache_context)
		_report.cache_load_ms = Time.get_ticks_msec() - cache_started
		if not payload.is_empty():
			_compiled_cache_source = payload.entries
			_compiled_cache_hit = true
			_report.cache_status = "hit"
			_report.cache_bytes = FileAccess.get_size(_compiled_cache_context.path)
	await _step(0.12, "Analizando main.xml…", _cache_source_text())
	var root := _planner.parse_xml(xml_path)
	if root.is_empty():
		push_error("TeardownMapImporter: could not open or parse %s" % xml_path)
		return {}
	var folder := xml_path.get_base_dir()
	var spawn := Vector3.ZERO
	for child: Dictionary in root.children:
		if child.tag == "spawnpoint":
			spawn = _planner.parse_vec3(child.attributes.get("pos", ""))
		elif child.tag == "environment":
			# Pass these through unchanged: `<environment>` creates nothing in the voxel world; the
			# scene's WorldEnvironment applies them.
			_report["environment"] = child.attributes
	if center == Vector3.INF:
		# Teardown's spawnpoint is not a useful crop center: Lee's is in the forest at the edge, 103 m
		# from the geometric center, so a 25 m radius would include only grass and trees. The geometry
		# centroid is in the factory, which is the area of interest.
		center = _planner.centroid(root, Transform3D.IDENTITY)
		# Center the crop only in the map plane. Subtracting the vertical centroid also sank half of
		# Lee below the opaque Ground in the test scene, making the atlas appear empty until the first
		# shot or view change revealed a roof.
		center.y = 0.0
	_report["spawnpoint"] = spawn - center + offset
	# Enter from above: landing under gravity avoids spawning inside a building.
	_report["drop_in"] = offset + Vector3.UP * 30.0
	# `boundary` uses X/Z points in the map's frame. It used to be discarded in `_visit`, leaving the
	# geometry recentered but the level without a boundary. Transform it once here; at runtime, Lee's
	# boundary is represented by 31 boxes and an ArrayMesh.
	await _step(0.16, "Tracing map boundary…")
	var boundary_points := _planner.find_boundary_points(
		root, Transform3D(Basis.IDENTITY, offset - center)
	)
	_create_boundary(world, boundary_points)

	# Every `<vox>` not under a `<body>` is static scenery, as in Teardown.
	var context := {
		"world": world, "folder": folder, "center": center, "radius": radius,
		"offset": offset, "body": null, "dynamic": false, "body_attributes": {},
	}
	_report["visited_elements"] = await _traverse_scene(root.children, offset - center, context)
	await _step(0.80, "Configuring vehicles…")
	var vehicle_started := Time.get_ticks_usec()
	_configure_vehicles()
	_report["vehicle_config_ms"] = (Time.get_ticks_usec() - vehicle_started) / 1000.0
	if _water != null:
		_water.finish()
		_report.water_surfaces = _water.get_surface_count_imported()
		_report.water_triangles = _water.get_triangle_count()
		_report.water_area_m2 = snappedf(_water.get_total_area(), 0.01)

	# `register_body` scans a body's Shapes, so call it once per body at the end; calling it per Shape
	# would insert each one twice into the bounding-box tree.
	await _step(0.84, "Registering bodies with physics…")
	var physics_budget := world.ensure_physics_budget()
	var registered := {}
	for entry: Dictionary in _bodies_bounds:
		if not registered.has(entry.body):
			registered[entry.body] = true
			if entry.body.state == VoxelBody3D.State.DYNAMIC:
				# Multiple Shapes under the same `<body>` share a compound. Rebuilding it after each
				# Shape was O(n²); build it once when the Body is complete.
				entry.body.rebuild_dynamic_collision(physics_budget.max_boxes_per_body)
			world.register_body(entry.body)
	_report.imported_dynamic_bodies = 0
	for body: VoxelBody3D in registered:
		if body.state == VoxelBody3D.State.DYNAMIC:
			_report.imported_dynamic_bodies += 1
	await _step(0.88, "Setting up cables and joints…")
	_build_ropes(world)
	_resolve_joints(world)
	if _water != null:
		_water.setup(world)
	# Lee's 632 `<body dynamic="true">` elements start at rest, as in Teardown: asleep, not frozen.
	# Asleep bodies cost Jolt nothing until touched, but remain dynamic—the player can push them,
	# explosions can throw them, and pipe `<joint>`s really hang from the first frame.
	for body: VoxelBody3D in registered:
		if body.state != VoxelBody3D.State.DYNAMIC:
			continue
		var rigid := body.get_physics_body() as RigidBody3D
		if rigid != null:
			# Air resistance. Without it, pipe chains never sleep: dozens of chained constraints keep
			# the solver from fully converging, so they tremble by millimeters forever. Measured in
			# Lee: 65 bodies stayed awake and motionless indefinitely.
			if rigid.has_meta(VoxelDoor3D.BODY_META):
				# A door moves around its axis. Generic damping for chained mechanisms slowed it as if
				# it were rubbing against the frame, even after losing its panel.
				rigid.linear_damp = 0.12
				rigid.angular_damp = 0.28
			else:
				rigid.linear_damp = 0.2
				rigid.angular_damp = 1.0
		body.sleep()
	await _step(0.92, "Building structural index…")
	world.finalize_spatial_index()
	if _compiled_cache_hit \
			and not "--eager-teardown-cache" in OS.get_cmdline_user_args():
		var prime := world.prime_baked_static_collision(offset, INITIAL_COLLISION_RADIUS)
		_report["cache_prime_ms"] = prime.ms
		_report["cache_prime_blocks"] = prime.blocks
		_report["cache_pending_blocks"] = prime.pending_blocks
	await _step(0.96, "Saving collision cache…" if not _compiled_cache_hit \
		else "Loading initial collision…")
	_finish_compiled_cache()
	_vox_cache.clear()
	_report["progress_frames"] = _progress_frames
	_report["progress_ms"] = snappedf(_progress_usec / 1000.0, 0.1)
	await _step(1.0, "Ready")
	return _report


## Traverses the scene in batches to yield frames. Each batch wraps its children in a synthetic
## `<group>` with the same attributes, so the engine calculates exactly the same transform as in a
## single pass. The only difference is that the group is visited multiple times, and those extra
## visits are subtracted from the count.
func _traverse_scene(roots: Array, translation: Vector3, context: Dictionary) -> int:
	var base := Transform3D(Basis.IDENTITY, translation)
	if not _progress.is_valid():
		return _scene_traversal.traverse(roots, base, context, _commit_element)
	var total := 0
	for element: Dictionary in roots:
		total += (element.get("children", []) as Array).size()
	total = maxi(total, 1)
	var done := 0
	var visited := 0
	for element: Dictionary in roots:
		var children: Array = element.get("children", [])
		if children.size() <= PROGRESS_CHUNK:
			visited += _scene_traversal.traverse([element], base, context, _commit_element)
			done += children.size()
			await _step(0.20 + 0.60 * done / float(total), _traverse_label(done, total))
			continue
		var cursor := 0
		while cursor < children.size():
			var slice := children.slice(cursor, cursor + PROGRESS_CHUNK)
			# −1: the synthetic group counts as a visit in each batch, but it is the same element.
			visited += _scene_traversal.traverse([{
				"tag": element.tag, "attributes": element.attributes, "children": slice,
			}], base, context, _commit_element) - 1
			cursor += PROGRESS_CHUNK
			done += slice.size()
			await _step(0.20 + 0.60 * done / float(total), _traverse_label(done, total))
		visited += 1
	return visited


func _traverse_label(done: int, total: int) -> String:
	return "Building scene…  %d/%d blocks" % [done, total]


func _cache_source_text() -> String:
	if not bool(_compiled_cache_context.get("enabled", false)):
		return "Cache disabled (--no-teardown-cache or partial import)"
	if _compiled_cache_hit:
		return "Collision from cache · %.1f MB in %d ms" % [
			_report.cache_bytes / 1048576.0, _report.cache_load_ms,
		]
	return "No cache: compiling the entire map (once only)"


## Yields to the engine just long enough to redraw, and only if a screen is being shown. `await`
## does not suspend when no `progress` callback is set, so calls without a screen remain
## synchronous and return the Dictionary directly.
func _step(fraction: float, label: String, source := "") -> void:
	if not _progress.is_valid():
		return
	_progress.call(fraction, label, source)
	var now := Time.get_ticks_msec()
	if now - _progress_last < PROGRESS_FRAME_INTERVAL and fraction < 1.0:
		return
	var started := Time.get_ticks_usec()
	await Engine.get_main_loop().process_frame
	_progress_usec += Time.get_ticks_usec() - started
	_progress_frames += 1
	_progress_last = Time.get_ticks_msec()


func _create_boundary(world: VoxelWorld3D, points: PackedVector3Array) -> void:
	if points.size() < 3:
		return
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	var twice_area := 0.0
	for index in points.size():
		var point := Vector2(points[index].x, points[index].z)
		var next := Vector2(
			points[(index + 1) % points.size()].x,
			points[(index + 1) % points.size()].z
		)
		minimum = minimum.min(point)
		maximum = maximum.max(point)
		twice_area += point.x * next.y - next.x * point.y
	var actor := world.get_parent().get_node_or_null("Player") as Node3D \
		if world.get_parent() != null else null
	var boundary := TeardownBoundary.new()
	boundary.name = "TeardownBoundary"
	world.add_child(boundary)
	if not boundary.setup(points, actor, _collision):
		boundary.queue_free()
		return
	_report.boundary_vertices = points.size()
	_report.boundary_segments = boundary.get_collision_segment_count()
	_report.boundary_area_m2 = snappedf(absf(twice_area) * 0.5, 0.01)
	_report.boundary_width = snappedf(maximum.x - minimum.x, 0.01)
	_report.boundary_depth = snappedf(maximum.y - minimum.y, 0.01)


func _commit_element(
	element: Dictionary, transform: Transform3D, context: Dictionary
) -> Dictionary:
	var tag: String = element.tag
	var attributes: Dictionary = element.attributes
	var child_context := context

	match tag:
		"vehicle":
			var tags := String(attributes.get("tags", ""))
			var record := {
				"attributes": attributes.duplicate(),
				"transform": transform,
				# Teardown's vehicle element faces -Z; VehicleBody3D uses MODEL_FRONT (+Z).
				"physics_transform": transform * Transform3D(
					Basis(Quaternion(Vector3.UP, PI)), Vector3.ZERO
				),
				"seat_transform": Transform3D.IDENTITY,
				"body": null,
				"visual_body": null,
				"wheels": [],
				"lights": [],
				"drivable": not _has_tag(tags, "nodrive"),
			}
			_pending_vehicles.append(record)
			_report.vehicles_declared += 1
			child_context = context.duplicate()
			child_context.vehicle = record
		"wheel":
			var vehicle: Dictionary = context.get("vehicle", {})
			if not vehicle.is_empty():
				var wheel := {
					"attributes": attributes.duplicate(), "transform": transform, "shapes": [],
				}
				(vehicle.wheels as Array).append(wheel)
				_report.vehicle_wheels += 1
				child_context = context.duplicate()
				child_context.vehicle_wheel = wheel
		"vox", "voxbox":
			# The `<joint>` is nested under `<vox>`, so its children need to see the Body just created:
			# in static scenery, each Shape gets a new Body that is not cached.
			var made: VoxelBody3D = _add_vox(attributes, transform, context) if tag == "vox" \
				else _add_voxbox(attributes, transform, context)
			if made != null:
				child_context = context.duplicate()
				child_context.body = made
		"body":
			# `dynamic="true"` makes a door, barrel, or wheel a Jolt RigidBody3D; the rest of the
			# scenery belongs to the world's static body.
			child_context = context.duplicate()
			# The Body is created in `_attach`, with the first Shape that survives radius cropping:
			# the full map has 632 `<body>` elements and almost all are outside the crop.
			child_context.body = null
			child_context.dynamic = attributes.get("dynamic", "false") == "true"
			child_context.body_attributes = attributes
			if child_context.dynamic:
				_report.authored_dynamic_bodies += 1
		"joint":
			# Teardown stores only one endpoint; resolve the other Body on load by overlap. Defer this
			# until all bodies are placed, then search by AABB.
			_pending_joints.append({
				"attributes": attributes, "transform": transform, "body": context.body,
			})
			return {"visit_children": false}
		"rope":
			_add_rope(element, transform)
			return {"visit_children": false}
		"water":
			_add_water(element, transform, context)
			return {"visit_children": false}
		"light":
			var light_vehicle: Dictionary = context.get("vehicle", {})
			if not light_vehicle.is_empty():
				(light_vehicle.lights as Array).append({
					"attributes": attributes.duplicate(), "transform": transform,
				})
				_report.vehicle_lights += 1
			return {"visit_children": false}
		"location":
			var location_vehicle: Dictionary = context.get("vehicle", {})
			if not location_vehicle.is_empty() \
					and _has_tag(String(attributes.get("tags", "")), "player"):
				location_vehicle.seat_transform = transform
			return {"visit_children": false}
		# Triggers, Lua scripts, and screens have no equivalent; their child geometry is still
		# traversed when appropriate.
		"trigger", "screen", "boundary", "environment", \
		"postprocessing", "spawnpoint", "vertex":
			return {"visit_children": false}

	return {"context": child_context, "visit_children": true}


## Teardown surface `<vertex pos="x z">` points lie on its local XZ plane. Preserve the node's `rot`
## (Lee uses -90° around Y) and convert it to the same VoxelWorld-local frame as the rest of the map.
## `VoxelWaterSystem` groups the geometry into a single draw call.
func _add_water(element: Dictionary, transform: Transform3D, context: Dictionary) -> void:
	var attributes: Dictionary = element.attributes
	if attributes.get("type", "polygon") != "polygon":
		return
	var points := PackedVector3Array()
	for child: Dictionary in element.children:
		if child.tag != "vertex":
			continue
		var values := String(child.attributes.get("pos", "")).split(" ", false)
		if values.size() < 2:
			continue
		points.append(transform * Vector3(float(values[0]), 0.0, float(values[1])))
	if points.size() < 3 or not _water_intersects_crop(
		points, context.offset, float(context.radius)
	):
		return
	if _water == null:
		_water = VoxelWaterSystem.new()
		_water.name = "TeardownWater"
		context.world.add_child(_water)
	var color := VoxelWaterSystem.DEFAULT_COLOR
	if attributes.has("color"):
		var color_values := _planner.parse_float_values(attributes.color, 3)
		color = Color(color_values[0], color_values[1], color_values[2], 1.0)
	var depth := maxf(0.0, float(attributes.get("depth", 0.0)))
	var visibility := maxf(
		0.2, float(attributes.get("visibility", VoxelWaterSystem.DEFAULT_VISIBILITY))
	)
	var ripples := clampf(float(attributes.get("ripple", 0.35)), 0.0, 1.0)
	var foam := clampf(float(attributes.get("foam", 1.0)), 0.0, 1.0)
	_water.add_polygon(points, color, visibility, ripples, depth, foam)


static func _water_intersects_crop(
	points: PackedVector3Array, crop_center: Vector3, radius: float
) -> bool:
	if is_inf(radius):
		return true
	if radius <= 0.0 or points.is_empty():
		return false
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	for point in points:
		minimum = minimum.min(Vector2(point.x, point.z))
		maximum = maximum.max(Vector2(point.x, point.z))
	var center_2d := Vector2(crop_center.x, crop_center.z)
	var closest := center_2d.clamp(minimum, maximum)
	return closest.distance_squared_to(center_2d) <= radius * radius


func _add_vox(attributes: Dictionary, transform: Transform3D, context: Dictionary) -> VoxelBody3D:
	var file_name: String = String(attributes.get("file", "")).get_file()
	var object: String = attributes.get("object", "")
	if file_name.is_empty() or object.is_empty():
		return null
	var models := _load_vox(context.folder.path_join("vox").path_join(file_name))
	var model: Dictionary = models.get(object, {})
	if model.is_empty():
		return null
	var source_size: Vector3i = model.size
	var voxel_size := 0.1 * float(attributes.get("scale", "1"))
	# Volume in the element's frame: X and Y are the file's x and z columns, and the file's y axis
	# points toward −Z. Undo the converter's `axis_offset` here to place the volume center at the
	# origin expected by VoxelShape3D.
	var center_offset := Vector3(
		voxel_size * 0.5 * (source_size.x & 1),
		voxel_size * 0.5 * source_size.z,
		-voxel_size * 0.5 * (source_size.y & 1)
	)
	var dimensions := Vector3i(source_size.x, source_size.z, source_size.y)
	if not _accept(transform.origin, dimensions, context):
		return null
	var data := VoxelShapeData.new()
	var decode_started := Time.get_ticks_msec()
	var decoded := data.set_cells_from_xyzi(source_size, model.xyzi)
	_report.decode_ms += Time.get_ticks_msec() - decode_started
	if not decoded or data.get_occupied_count() == 0:
		return null
	var descriptor := "vox:%s:%s" % [file_name, object]
	var baked := _take_compiled_collision(descriptor)
	var body := _attach(data, transform * Transform3D(Basis.IDENTITY, center_offset), voxel_size,
		_palette_for(context.folder.path_join("vox").path_join(file_name)), context,
		_collides(attributes), baked.get("faces", []), bool(baked.get("valid", false)),
		float(attributes.get("density", "1")))
	if body != null:
		_annotate_source(body, _last_attached_shape, descriptor, attributes, context)
	_record_compiled_collision(descriptor, body, _last_attached_shape)
	_report.shapes += 1
	return body


func _add_voxbox(attributes: Dictionary, transform: Transform3D, context: Dictionary) -> VoxelBody3D:
	var size := Vector3i(_planner.parse_vec3(attributes.get("size", "50 30 20")))
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		return null
	if not _accept(transform.origin, size, context):
		return null
	# A `<voxbox>` is a solid, single-material box and does not go through MagicaVoxel, so it needs
	# neither a 90-degree rotation nor centering: its `pos` is the corner and its axes are Godot's.
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	cells.fill(1)
	var data := VoxelShapeData.new()
	if not data.set_cells(size, cells):
		return null
	var palette := VoxelPalette.new()
	var material: String = attributes.get("material", "none")
	var traits: Dictionary = TeardownPalette.MATERIALS.get(
		material, TeardownPalette.MATERIALS["none"]
	)
	# A `<voxbox>` stores its material in XML, not in the palette band, so build its mask manually:
	# the whole block uses index 1, with the same metadata as a converted palette so
	# `TeardownPalette.mask_for` does not need to distinguish it.
	var mask := PackedByteArray()
	mask.resize(256)
	mask.fill(1)
	mask[1] = 0 if material in TeardownPalette.WALK_THROUGH else 1
	palette.set_meta("collide_mask", mask)
	var color := _planner.parse_vec3(attributes.get("color", "1 1 1"))
	# The converter writes the voxbox's visual material in Teardown G-buffer order: reflectivity,
	# smoothness, metallic, and emission. Reflections are not traced yet, but preserve
	# roughness/metallic/emission in the palette consumed by the DDA pass.
	var pbr := _planner.parse_float_values(attributes.get("pbr", "0 0 0 0"), 4)
	palette.set_material(1, {
		"color": Color(color.x, color.y, color.z),
		"opacity": float(traits.get("opacity", 1.0)),
		"roughness": 1.0 - clampf(pbr[1], 0.0, 1.0),
		"metallic": clampf(pbr[2], 0.0, 1.0),
		"emission": clampf(pbr[3], 0.0, 32.0),
		"hardness": traits.hardness,
		"density": traits.density,
		"friction": 0.9,
		"restitution": 0.02,
	})
	_report.voxboxes += 1
	var descriptor := "voxbox:%s:%s:%s:%s" % [
		attributes.get("size", ""), attributes.get("material", ""),
		attributes.get("color", ""), attributes.get("pbr", ""),
	]
	var baked := _take_compiled_collision(descriptor)
	var body := _attach(
		data, transform * Transform3D(Basis.IDENTITY, Vector3(size) * 0.05), 0.1,
		palette, context, _collides(attributes), baked.get("faces", []),
		bool(baked.get("valid", false)), float(attributes.get("density", "1"))
	)
	if body != null:
		_annotate_source(body, _last_attached_shape, descriptor, attributes, context)
	_record_compiled_collision(descriptor, body, _last_attached_shape)
	return body


func _annotate_source(
	body: VoxelBody3D, shape: VoxelShape3D, descriptor: String, attributes: Dictionary,
	context: Dictionary
) -> void:
	if shape == null:
		return
	shape.set_meta("teardown_source", descriptor)
	shape.set_meta("teardown_attributes", attributes.duplicate())
	if not body.has_meta("teardown_sources"):
		body.set_meta("teardown_sources", PackedStringArray())
	var sources := body.get_meta("teardown_sources") as PackedStringArray
	sources.append(descriptor)
	body.set_meta("teardown_sources", sources)
	var body_attributes: Dictionary = context.get("body_attributes", {})
	if not body.has_meta("teardown_body_attributes") and not body_attributes.is_empty():
		body.set_meta("teardown_body_attributes", body_attributes.duplicate())


## `collide="false"` in Teardown XML marks pass-through geometry. Any other value, including an
## omitted attribute, enables collision.
static func _collides(attributes: Dictionary) -> bool:
	return String(attributes.get("collide", "true")) != "false"


## A `<rope>` consists of two anchors and some slack, not voxels. It is intentionally rendered as a
## free line: a cable is neither destructible nor collidable, and adding it to the atlas would waste
## macro-cells on a nearly empty diagonal—the factory cables span 30 m diagonally.
func _add_rope(element: Dictionary, transform: Transform3D) -> void:
	var anchors := PackedVector3Array()
	for child: Dictionary in element.children:
		if child.tag == "location":
			anchors.append(transform * _planner.parse_vec3(child.attributes.get("pos", "")))
	if anchors.size() < 2:
		return
	# `slack` is the extra length in meters. Lee's 79 cables use -0.15, meaning they are taut.
	var slack := float(element.attributes.get("slack", "0"))
	var strength := float(element.attributes.get(
		"strength", str(VoxelRopes.DEFAULT_STRENGTH)))
	var max_stretch := float(element.attributes.get(
		"maxstretch", str(VoxelRopes.DEFAULT_MAX_STRETCH)))
	# Create spans at the end, not here: the Body attached to each endpoint must be known, and the
	# XML's `Ropes` group appears before some of the geometry holding the cables.
	_pending_ropes.append({
		"anchors": anchors, "slack": slack,
		"strength": strength, "max_stretch": max_stretch,
	})
	_report.ropes += 1


## Find the Body with actual voxels beneath an anchor. In Lee, `<rope>` elements live in their own
## group with world coordinates and do not specify what they attach to, so resolve attachments by
## geometry; this also works with any map.
func _body_near(position: Vector3, radius: float) -> VoxelBody3D:
	var best: VoxelBody3D = null
	var best_distance := INF
	for entry: Dictionary in _bodies_bounds:
		var body: VoxelBody3D = entry.body
		if body == best or not is_instance_valid(body):
			continue
		var bounds: AABB = entry.bounds
		if not bounds.grow(radius).has_point(position):
			continue
		var distance := bounds.get_center().distance_to(position)
		if distance >= best_distance \
				or not VoxelDoor3D._body_has_material_near(body, position, radius):
			continue
		best_distance = distance
		best = body
	return best


func _build_ropes(world: VoxelWorld3D) -> void:
	if _pending_ropes.is_empty():
		return
	_ropes = VoxelRopes.new()
	_ropes.name = "TeardownRopes"
	for pending: Dictionary in _pending_ropes:
		var anchors: PackedVector3Array = pending.anchors
		var slack: float = pending.slack
		var strength := float(pending.strength)
		var max_stretch := float(pending.max_stretch)
		for index in anchors.size() - 1:
			# Only the endpoints are attached to a body; intermediate nodes in a multi-span `<rope>`
			# are points along the cable itself.
			var body_a := _body_near(anchors[index], ANCHOR_SEARCH) if index == 0 else null
			var body_b := _body_near(anchors[index + 1], ANCHOR_SEARCH) \
				if index == anchors.size() - 2 else null
			if body_a != null or body_b != null:
				_report.rope_anchors += 1
			_ropes.add_span(
				anchors[index], anchors[index + 1], slack, body_a, body_b,
				strength, max_stretch
			)
	world.add_child(_ropes)
	_ropes.setup(world)
	_ropes.settle()


## Consumes an artifact entry in the same deterministic order as XML traversal. The map signature
## already covers XML, `.vox`, native binary, and implementation; the descriptor is an additional
## safeguard against a truncated or corrupt cache.
func _take_compiled_collision(descriptor: String) -> Dictionary:
	if not _compiled_cache_hit or _compiled_cache_broken:
		return {"valid": false, "faces": []}
	if _compiled_cache_cursor >= _compiled_cache_source.size():
		_break_compiled_cache("missing entries for %s" % descriptor)
		return {"valid": false, "faces": []}
	var entry: Dictionary = _compiled_cache_source[_compiled_cache_cursor]
	_compiled_cache_cursor += 1
	if String(entry.get("descriptor", "")) != descriptor \
			or not entry.get("faces", null) is Array:
		_break_compiled_cache("unexpected descriptor at %d" % (_compiled_cache_cursor - 1))
		return {"valid": false, "faces": []}
	var records := entry.faces as Array
	_compiled_face_blocks += records.size()
	return {"valid": true, "faces": records}


func _record_compiled_collision(
	descriptor: String, body: VoxelBody3D, shape: VoxelShape3D
) -> void:
	if not bool(_compiled_cache_context.get("enabled", false)) or _compiled_cache_hit \
			or _compiled_cache_broken or body == null or shape == null:
		return
	var records := body.export_baked_static_collision(shape)
	_compiled_face_blocks += records.size()
	_compiled_cache_entries.append({"descriptor": descriptor, "faces": records})


func _break_compiled_cache(reason: String) -> void:
	if _compiled_cache_broken:
		return
	_compiled_cache_broken = true
	_compiled_cache_hit = false
	_report.cache_status = "invalid"
	push_warning("TeardownMapImporter: invalid compiled cache (%s); it will be rebuilt on next launch" % reason)
	TeardownMapCache.invalidate(_compiled_cache_context.get("path", ""))


func _finish_compiled_cache() -> void:
	if not bool(_compiled_cache_context.get("enabled", false)):
		return
	if _compiled_cache_hit:
		if _compiled_cache_cursor != _compiled_cache_source.size():
			_break_compiled_cache("%d extra entries" % (
				_compiled_cache_source.size() - _compiled_cache_cursor
			))
		else:
			_report["cache_face_blocks"] = _compiled_face_blocks
		return
	if _compiled_cache_broken:
		return
	var save_started := Time.get_ticks_msec()
	var saved := TeardownMapCache.save_payload(
		_compiled_cache_context, _compiled_cache_entries, _compiled_face_blocks
	)
	_report.cache_save_ms = Time.get_ticks_msec() - save_started
	_report.cache_face_blocks = _compiled_face_blocks
	if bool(saved.get("ok", false)):
		_report.cache_status = "built"
		_report.cache_bytes = int(saved.get("bytes", 0))
	else:
		_report.cache_status = "save_failed"
		push_warning("TeardownMapImporter: could not save compiled cache (%s)" % saved.get("error", ERR_CANT_CREATE))



func _accept(origin: Vector3, dimensions: Vector3i, context: Dictionary) -> bool:
	if origin.distance_to(context.offset) > context.radius:
		_report.skipped_far += 1
		return false
	var cells := dimensions.x * dimensions.y * dimensions.z
	if _report.cells + cells > CELL_BUDGET:
		_report.skipped_budget += 1
		return false
	_report.cells += cells
	return true


func _attach(
	data: VoxelShapeData, transform: Transform3D, voxel_size: float,
	palette: VoxelPalette, context: Dictionary, collides := true,
	baked_faces: Array = [], use_baked_collision := false, density_scale := 1.0
) -> VoxelBody3D:
	var committed: Dictionary = _scene_committer.attach(
		VoxelBodyScript, VoxelShapeScript, data, transform, voxel_size, palette, context,
		collides, baked_faces, use_baked_collision, density_scale, _collision,
		"--eager-teardown-cache" in OS.get_cmdline_user_args(), AUTHORED_DYNAMIC_FILL_SCALE,
		int(_report.bodies), int(_report.vehicle_visual_bodies)
	)
	if not bool(committed.get("ok", false)):
		_last_attached_shape = null
		return null
	var body := committed.body as VoxelBody3D
	_last_attached_shape = committed.shape as VoxelShape3D
	_report.bodies += int(committed.bodies_created)
	_report.vehicle_visual_bodies += int(committed.visual_bodies_created)
	_report.no_collide += int(committed.no_collide)
	_report.density_overrides += int(bool(committed.density_override))
	_report.collision_ms += float(committed.collision_ms)
	_report.faces_ms += float(committed.faces_ms)
	_report.voxels += int(committed.voxels)
	_bodies_bounds.append({"body": body, "bounds": committed.bounds})
	return body


## Converts only `<vehicle>` elements with wheels and without the `nodrive` tag. Boats, tracked
## excavators, and decorative pieces retain their normal dynamic Bodies; they do not get partial
## controls or an invented suspension.
func _configure_vehicles() -> void:
	for descriptor: Dictionary in _pending_vehicles:
		var body := descriptor.get("body") as VoxelBody3D
		var wheels: Array = descriptor.get("wheels", [])
		if not bool(descriptor.get("drivable", true)) or wheels.size() < 2 \
				or body == null or not is_instance_valid(body):
			continue
		var vehicle := body.configure_vehicle(descriptor)
		if vehicle == null:
			continue
		body.set_meta("teardown_vehicle", vehicle)
		var visual_body := descriptor.get("visual_body") as VoxelBody3D
		if visual_body != null:
			body.set_meta("teardown_vehicle_visual_body", visual_body)
		_report.vehicles_drivable += 1


static func _has_tag(tags: String, wanted: String) -> bool:
	for token in tags.replace(",", " ").split(" ", false):
		if token == wanted or token.begins_with(wanted + "="):
			return true
	return false


## Load a named object from a shared map `.vox`, isolated from the `<body>` that wrapped it in the
## XML. This is intended for loading loose props (vehicles, furniture) without using the full
## `import_map` context/budget flow. The path remains outside the repository and points to the
## original map: nothing is copied or redistributed; the file is read on demand.
static func load_named_shape(
	vox_path: String, object_name: String, density_scale := 1.0
) -> VoxelShape3D:
	var importer := TeardownMapImporter.new()
	var models := importer._load_vox(vox_path)
	var model: Dictionary = models.get(object_name, {})
	if model.is_empty():
		return null
	var source_size: Vector3i = model.size
	var data := VoxelShapeData.new()
	if not data.set_cells_from_xyzi(source_size, model.xyzi) or data.get_occupied_count() == 0:
		return null
	var shape := VoxelShape3D.new()
	shape.data = data
	shape.palette = importer._palette_for(vox_path)
	shape.anchored = false
	shape.voxel_size = 0.1
	shape.density_scale = maxf(density_scale, 0.001)
	shape.physical_fill_scale = AUTHORED_DYNAMIC_FILL_SCALE
	# Use the same axis rotation as `_add_vox`: X/Z of the decoded volume are the file's x/y columns,
	# and its Y axis points toward -Z. Undo it here to place the volume center at the origin expected
	# by VoxelShape3D.
	shape.transform = Transform3D(Basis.IDENTITY, Vector3(
		0.05 * float(source_size.x & 1), 0.05 * float(source_size.z), -0.05 * float(source_size.y & 1)
	))
	return shape


func _resolve_joints(world: VoxelWorld3D) -> void:
	for pending: Dictionary in _pending_joints:
		var transform: Transform3D = pending.transform
		var owner_body: VoxelBody3D = pending.body
		if owner_body == null:
			# Its Shape was outside the radius, so the joint has nothing to attach to.
			_report.skipped_joints += 1
			continue
		var joint_size := maxf(
			VoxelDoor3D.DEFAULT_JOINT_SIZE,
			float(pending.attributes.get("size", VoxelDoor3D.DEFAULT_JOINT_SIZE))
		)
		var other := _body_at(transform.origin, owner_body, joint_size)
		if other == null or (owner_body.state != VoxelBody3D.State.DYNAMIC
			and other.state != VoxelBody3D.State.DYNAMIC):
			_report.skipped_joints += 1
			continue
		var joint_key := _joint_key(owner_body, other, transform.origin, pending.attributes)
		if _resolved_joint_keys.has(joint_key):
			_report.skipped_joints += 1
			continue
		var joint := _make_joint(pending.attributes)
		if joint == null:
			_report.skipped_joints += 1
			continue
		world.add_child(joint)
		var frame := transform.orthonormalized()
		if joint is SliderJoint3D:
			frame.basis = _slider_basis(frame.basis)
		joint.global_transform = frame
		# Order matters: Godot rebuilds the constraint when assigning the nodes and uses the frame
		# from the node's transform at that moment.
		joint.node_a = joint.get_path_to(owner_body.get_physics_body())
		joint.node_b = joint.get_path_to(other.get_physics_body())
		if joint is Generic6DOFJoint3D:
			_configure_ball_joint(
				joint as Generic6DOFJoint3D, pending.attributes, owner_body, other
			)
		_resolved_joint_keys[joint_key] = true
		_resolved_joint_records.append({
			"joint": joint,
			"attributes": pending.attributes,
			"transform": frame,
			"owner_body": owner_body,
			"other_body": other,
			"broken": false,
		})
		_report.joints += 1
	# This manager exclusively owns the live -> broken transition. Doors use the same records, but
	# never release a Joint/hold outside it.
	var joints := VoxelJoints.new()
	joints.name = "TeardownJoints"
	world.add_child(joints)
	joints.add_records(_resolved_joint_records)
	# Connect doors to `voxel_impact` first so they request the break from the manager and emit their
	# signals in the same transition; the general callback then sees the record already broken.
	_create_doors(world)
	joints.setup(world)


## Detects authored Teardown doors from their actual joint topology. This deliberately does not
## turn every nearby prop into a door: a candidate must be door-sized and either have an explicit
## hinge or two ball joints that define a vertical hinge axis. A remaining connection at the
## opposite edge is the latch and stays locked until its voxels are destroyed.
func _create_doors(world: VoxelWorld3D) -> void:
	var by_body := {}
	for record: Dictionary in _resolved_joint_records:
		# XML does not guarantee that the dynamic endpoint is `owner_body`; it depends on spatial
		# traversal order. Checking only one side meant some door panels never received VoxelDoor3D.
		for side_name in ["owner_body", "other_body"]:
			var candidate := record.get(side_name) as VoxelBody3D
			if candidate == null or candidate.state != VoxelBody3D.State.DYNAMIC:
				continue
			if not by_body.has(candidate):
				var empty_records: Array[Dictionary] = []
				by_body[candidate] = empty_records
			var body_records: Array[Dictionary] = by_body[candidate]
			if not body_records.has(record):
				body_records.append(record)
	for key in by_body:
		var body := key as VoxelBody3D
		var body_bounds := _bounds_for_body(body)
		var records: Array[Dictionary] = by_body[body]
		var roles := _planner.classify_door_joint_records(records, body_bounds)
		if roles.is_empty():
			continue
		var door := VoxelDoor3D.new()
		door.name = "TeardownDoor%d" % int(_report.doors)
		world.add_child(door)
		var hinges: Array[Dictionary] = []
		hinges.assign(roles.hinges)
		var latch: Dictionary = roles.get("latch", {})
		_replace_door_ball_hinges(world, hinges)
		door.configure(world, body, hinges, latch, body_bounds)
		_report.doors += 1
		_report.latched_doors += 0 if latch.is_empty() else 1


## A door's two authored ball joints are neither springs nor welds: they are two free points that
## define an axis through their vertical separation. Generic6DOF is useful for other mechanisms that
## use `rotstrength`, but Jolt can solve two linear 6DOFs as a redundant system and leave the panel
## almost locked. PinJoint3D expresses the intended behavior and avoids six unnecessary angular
## constraints. Keep both records separate so one hinge can break without breaking the other.
func _replace_door_ball_hinges(world: VoxelWorld3D, hinges: Array[Dictionary]) -> void:
	for record: Dictionary in hinges:
		var old_joint := record.get("joint") as Joint3D
		if not old_joint is Generic6DOFJoint3D or not is_instance_valid(old_joint):
			continue
		var owner := record.get("owner_body") as VoxelBody3D
		var other := record.get("other_body") as VoxelBody3D
		if owner == null or other == null:
			continue
		var body_a := owner.get_physics_body()
		var body_b := other.get_physics_body()
		if body_a == null or body_b == null:
			continue
		var pin := PinJoint3D.new()
		pin.name = "TeardownDoorHinge"
		world.add_child(pin)
		pin.global_transform = (record.get("transform", Transform3D.IDENTITY) as Transform3D) \
			.orthonormalized()
		pin.node_a = pin.get_path_to(body_a)
		pin.node_b = pin.get_path_to(body_b)
		record["joint"] = pin
		old_joint.queue_free()


func _bounds_for_body(body: VoxelBody3D) -> AABB:
	var result := AABB()
	var found := false
	for entry: Dictionary in _bodies_bounds:
		if entry.body != body:
			continue
		if found:
			result = result.merge(entry.bounds)
		else:
			result = entry.bounds
			found = true
	return result


static func classify_door_joint_records(records: Array[Dictionary], body_bounds: AABB) -> Dictionary:
	return VoxelMapImportPlanner.new().classify_door_joint_records(records, body_bounds)


func _make_joint(attributes: Dictionary) -> Joint3D:
	var limits := _planner.parse_vec3(attributes.get("limits", "0 0 0"))
	match attributes.get("type", "ball"):
		"hinge":
			var hinge := HingeJoint3D.new()
			hinge.name = "TeardownHinge"
			if limits.x != limits.y:
				hinge.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
				hinge.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, deg_to_rad(limits.x))
				hinge.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(limits.y))
			return hinge
		"prismatic":
			var slider := SliderJoint3D.new()
			slider.name = "TeardownSlider"
			slider.set_param(SliderJoint3D.PARAM_LINEAR_LIMIT_LOWER, limits.x)
			slider.set_param(SliderJoint3D.PARAM_LINEAR_LIMIT_UPPER, limits.y)
			return slider
		"ball", "":
			var ball := Generic6DOFJoint3D.new()
			ball.name = "TeardownBall"
			# Coincident point, but free rotation except for the authored spring. PinJoint3D cannot
			# represent `rotstrength`/`rotspring`, and Jolt ignores its bias and damping parameters, so
			# chains accumulated torsion without any angular resistance.
			for axis in 3:
				_set_6dof_linear_locked(ball, axis)
				_set_6dof_angular_free(ball, axis)
			return ball
	return null


func _body_at(position: Vector3, exclude: VoxelBody3D, radius := 0.2) -> VoxelBody3D:
	var best: VoxelBody3D = null
	var best_distance := INF
	for entry: Dictionary in _bodies_bounds:
		var body: VoxelBody3D = entry.body
		if body == exclude or not is_instance_valid(body):
			continue
		var bounds: AABB = entry.bounds
		if not bounds.grow(radius).has_point(position) \
				or not VoxelDoor3D._body_has_material_near(body, position, radius):
			continue
		var distance := bounds.get_center().distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best = body
	return best


static func _joint_key(
	a: VoxelBody3D, b: VoxelBody3D, position: Vector3, attributes: Dictionary
) -> String:
	var low := mini(a.get_instance_id(), b.get_instance_id())
	var high := maxi(a.get_instance_id(), b.get_instance_id())
	var millimeters := Vector3i(
		roundi(position.x * 1000.0), roundi(position.y * 1000.0),
		roundi(position.z * 1000.0)
	)
	return "%d:%d:%s:%s" % [low, high, String(attributes.get("type", "ball")), millimeters]


static func _set_6dof_linear_locked(joint: Generic6DOFJoint3D, axis: int) -> void:
	match axis:
		0:
			joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
			joint.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
			joint.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)
		1:
			joint.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
			joint.set_param_y(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
			joint.set_param_y(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)
		2:
			joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
			joint.set_param_z(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, 0.0)
			joint.set_param_z(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.0)


static func _set_6dof_angular_free(joint: Generic6DOFJoint3D, axis: int) -> void:
	match axis:
		0: joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, false)
		1: joint.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, false)
		2: joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT, false)


static func _configure_ball_joint(
	joint: Generic6DOFJoint3D, attributes: Dictionary,
	owner_body: VoxelBody3D, other_body: VoxelBody3D
) -> void:
	var strength := maxf(0.0, float(attributes.get("rotstrength", 0.0)))
	if strength <= 0.0:
		return
	var inertia_a := _body_mean_inertia(owner_body)
	var inertia_b := _body_mean_inertia(other_body)
	var effective_inertia := inertia_b if inertia_a < 0.0 else inertia_a
	if inertia_a >= 0.0 and inertia_b >= 0.0:
		effective_inertia = inertia_a * inertia_b / maxf(0.0001, inertia_a + inertia_b)
	effective_inertia = maxf(0.0001, effective_inertia)
	# Preserve the authored scale without pretending to use Teardown units: interpret strength as
	# natural frequency² and rotspring as the damping ratio. This makes k = I·ω² and c = 2ζIω adapt
	# to the body's actual inertia instead of applying the same constant to a cup and a tower.
	var omega := TAU * sqrt(strength)
	var stiffness := effective_inertia * omega * omega
	var damping := 2.0 * clampf(float(attributes.get("rotspring", 0.0)), 0.0, 2.0) \
		* effective_inertia * omega
	for axis in 3:
		match axis:
			0:
				joint.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, true)
				joint.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_STIFFNESS, stiffness)
				joint.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_DAMPING, damping)
			1:
				joint.set_flag_y(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, true)
				joint.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_STIFFNESS, stiffness)
				joint.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_DAMPING, damping)
			2:
				joint.set_flag_z(Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_SPRING, true)
				joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_STIFFNESS, stiffness)
				joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_SPRING_DAMPING, damping)


static func _body_mean_inertia(body: VoxelBody3D) -> float:
	var physics := body.get_physics_body()
	if not physics is RigidBody3D:
		return -1.0
	var inertia := (physics as RigidBody3D).inertia
	return maxf(0.0001, (inertia.x + inertia.y + inertia.z) / 3.0)


## A Godot `SliderJoint3D` slides along its local X, but a Teardown joint's axis is +Z. Rotate the
## node to correct this, not the geometry.
static func _slider_basis(basis: Basis) -> Basis:
	return basis * Basis(Quaternion(Vector3.UP, deg_to_rad(-90.0)))


func _palette_for(path: String) -> VoxelPalette:
	if not _palette_cache.has(path):
		_load_vox(path)
	return _palette_cache.get(path)


## Returns `{object_name: {size, xyzi}}`. Names come from the nTRN `_name` fields, which are what
## each XML `<vox>` element's `object` attribute refers to.
func _load_vox(path: String) -> Dictionary:
	if _vox_cache.has(path):
		return _vox_cache[path]
	var parsed: Dictionary = _planner.parse_named_vox(path)
	var result: Dictionary = parsed.get("models", {})
	_vox_cache[path] = result
	if not bool(parsed.get("ok", false)):
		push_warning("TeardownMapImporter: missing %s" % path)
		_palette_cache[path] = VoxelPalette.new()
		return result
	_palette_cache[path] = TeardownPalette.build(
		parsed.colors, parsed.material_attributes, parsed.imap
	)
	return result
