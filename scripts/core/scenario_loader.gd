class_name ScenarioLoader
extends Node
## Populates the world at startup: tries to load the Teardown map and falls back to the included
## neighborhood if it is unavailable. Also owns the loading screen, since loading is the only slow
## part.
##
## The optional Teardown map is resolved from `SHATTERGRID_MAP`,
## `res://external/teardown_maps/lee/main.xml`, or `--teardown-map=<path>`. Original map data is not
## part of the project. `--no-teardown-map` forces the included scenario.

## No crop: the full map has 2,312 Shapes and 79.3 M voxels; with the brick atlas it fits in 296 MB
## using 37 of the 256 available layers. The first load compiles collision into `user://`; later
## loads restore the initial area and preload the rest by proximity.
## `--teardown-radius=<meters>` remains available for cropping when measurements require it.
const TEARDOWN_MAP_RADIUS := INF
const TEARDOWN_NOTICE := "PROPERTY OF TUXEDO LABS — research only, do not distribute"

## Street along the z axis, with the player entering from the south. At 10 cm per voxel, facades
## are 6.4 m tall; boundaries at x=±7 leave a 7.6 m road for the 3.8 m-wide tank.
##
## Only these three models are repeated: `casa_moderna` is 2.4 m tall and `casa_buhardilla` is
## 3.0 m, both shorter than the tank at 3.31 m. They are flattened Mini Mike's Metro Minis models,
## which made the tank look enormous beside them; repeating a believable house is less distracting
## than lining up a neighborhood of sheds.
const NEIGHBORHOOD := [
	["casa_dos_plantas", Vector3(-7, 0, -4)],
	["casa_barrio", Vector3(-7, 0, 5)],
	["casa_barrio", Vector3(-7, 0, 14)],
	["casa_garaje", Vector3(7, 0, -3)],
	["casa_dos_plantas", Vector3(7, 0, 6)],
]

## Remains alive during startup. The renderer continues using it after map import, so the bootstrap
## reads it and calls `close_loading()` once there is nothing left to cover.
var loading: LoadingScreen

var _world: VoxelWorld3D
var _player: Node3D
var _camera: Camera3D
var _ground: Node3D
var _world_environment: WorldEnvironment
var _sun: DirectionalLight3D
var _hud: GameHud
var _environment := TeardownEnvironment.new()


func setup(
	world: VoxelWorld3D,
	player: Node3D,
	camera: Camera3D,
	ground: Node3D,
	world_environment: WorldEnvironment,
	sun: DirectionalLight3D,
	hud: GameHud
) -> void:
	_world = world
	_player = player
	_camera = camera
	_ground = ground
	_world_environment = world_environment
	_sun = sun
	_hud = hud


## Returns true if the Teardown map was loaded, false if the included neighborhood was built.
func build() -> bool:
	if await _load_teardown_map():
		return true
	for placement: Array in NEIGHBORHOOD:
		_world.create_body_from_asset(
			"res://assets/models/houses/%s.vox" % placement[0],
			Transform3D(Basis.IDENTITY, placement[1])
		)
	return false


## Lighting read from the map's sky is stored during import and passed to the renderer here because
## the renderer is created later. Without a map, nothing changes and the effect keeps its defaults.
func apply_environment_to(renderer: VoxelRenderSystem) -> void:
	if _environment.sun_direction == Vector3.INF:
		return
	renderer.effect.sun_direction = _environment.sun_direction
	renderer.effect.sun_color = _environment.sun_color
	# The shader previously applied 1.05 in its diffuse term; keep it so changing the light source
	# does not also change exposure.
	renderer.effect.sun_energy = _sun.light_energy * 1.05
	renderer.effect.ambient_sky = _environment.ambient_sky
	renderer.effect.ambient_ground = _environment.ambient_ground


## The screen covers all of startup: map import and renderer setup. Until this point the tree was
## paused and the camera disabled so yielded frames would not redraw a partially built world.
func close_loading() -> void:
	if loading == null:
		return
	_camera.current = true
	get_tree().paused = false
	loading.queue_free()
	loading = null


func _load_teardown_map() -> bool:
	var path := VoxelProjectPaths.teardown_map_path()
	var radius := TEARDOWN_MAP_RADIUS
	var collision := true
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--teardown-map="):
			path = argument.trim_prefix("--teardown-map=")
		elif argument.begins_with("--teardown-radius="):
			radius = float(argument.trim_prefix("--teardown-radius="))
		elif argument == "--no-teardown-map":
			return false
		elif argument == "--teardown-no-collision":
			collision = false
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	var started := Time.get_ticks_msec()
	# Import blocks the main thread for seconds. The loading screen draws during frames yielded
	# between importer stages; pause the tree so nothing simulates with a partial map, and disable
	# the camera so those frames do not redraw a partially built world.
	loading = LoadingScreen.new()
	add_child(loading)
	get_tree().paused = true
	_camera.current = false
	await get_tree().process_frame
	# The importer accounts for one third of startup; the bootstrap distributes the remaining
	# renderer work.
	loading.set_range(0.0, 0.30)
	var report := await TeardownMapImporter.import_map_progressive(
		_world, path, loading.report, Vector3.INF, radius, Vector3.ZERO, collision
	)
	if report.is_empty():
		return false
	# The test floor obstructs a real map: its mesh is a 400 m square in the same gray, and its
	# collision is an infinite plane at y=0. Lee's terrain varies around that height, so the floor
	# showed through as flat slabs with straight edges. The plane itself is useful as bedrock: remove
	# its mesh and lower it beneath the map's lowest point. Teardown does not add an indestructible
	# voxel—its floor is `rock`, already indestructible here—but it also prevents falling into the
	# void, and an infinite plane is Jolt's cheapest safety net.
	_ground.get_node("Mesh").queue_free()
	_ground.position.y = _lowest_voxel_y() - 5.0
	_environment.apply(
		_world_environment, _sun, _world, report.get("environment", {}), path.get_base_dir(),
		TEARDOWN_NOTICE
	)
	print("[%s] map imported in %d ms: %s"
		% [TEARDOWN_NOTICE, Time.get_ticks_msec() - started, JSON.stringify(report)])
	# Spawn by falling: the crop center often lands inside a building, and gravity prevents getting
	# stuck in the geometry.
	_player.global_position = report.get("drop_in", Vector3.UP * 30.0)
	_player.reset_physics_interpolation()
	var boundary := _world.get_node_or_null("TeardownBoundary")
	if boundary != null and boundary.has_method("set_tracked_actor"):
		boundary.set_tracked_actor(_player)
	# The entry point is 30 m above the center to avoid spawning inside a building. Looking
	# horizontally from that height shows only the sky and ground, making it seem as if the atlas
	# activated on the first shot when mouse movement had actually aimed down at the map.
	_camera.rotation.x = deg_to_rad(-35.0)
	_hud.show_watermark(TEARDOWN_NOTICE)
	if "--teardown-vehicles" in OS.get_cmdline_user_args():
		_spawn_test_vehicles(path.get_base_dir())
	return true


## Focused physics test: extracts three vehicles from the map's shared `.vox` file—a small car, SUV,
## and muscle car—and drops them in front of the entry point as actual dynamic bodies.
## Enabled only with `--teardown-vehicles`; normal startup is unchanged. Like the rest of the map,
## it reads the file from its original location outside the repository and does not copy or save
## vehicle data.
func _spawn_test_vehicles(map_folder: String) -> void:
	var vox_dir := map_folder.path_join("vox")
	# {label: [file, object]}. Each Teardown vehicle has its own `.vox` file; they do not share files
	# even though the object name (`shapeNNN`) uses a map-wide counter.
	var vehicles := {
		"small car": ["palette22.vox", "shape473", 1.5],
		"suv": ["palette24.vox", "shape500", 2.0],
		"muscle car": ["palette25.vox", "shape527", 2.0],
	}
	var drop: Vector3 = _player.global_position + _player.global_transform.basis.z * -4.0
	var offset := 0
	for label: String in vehicles:
		var entry: Array = vehicles[label]
		var vox_path := vox_dir.path_join(entry[0])
		var shape := TeardownMapImporter.load_named_shape(vox_path, entry[1], float(entry[2]))
		if shape == null:
			push_warning("--teardown-vehicles: could not find %s (%s) in %s"
				% [label, entry[1], vox_path])
			continue
		var body := VoxelBody3D.new()
		body.name = "TestVehicle_%s" % entry[1]
		body.state = VoxelBody3D.State.DYNAMIC
		_world.add_child(body)
		body.add_voxel_shape(shape)
		body.global_position = drop + Vector3(float(offset) * 3.5, 3.0, 0.0)
		_world.register_body(body)
		body.wake_for_interaction()
		offset += 1
	print("[%s] --teardown-vehicles: spawned %d test vehicles beside the entry point"
		% [TEARDOWN_NOTICE, offset])


## Lowest point in the imported map, used to place the bedrock below it.
func _lowest_voxel_y() -> float:
	var lowest := INF
	for body in _world.get_children():
		if not (body is VoxelBody3D):
			continue
		for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
			lowest = minf(lowest, shape.world_bounds().position.y)
	return 0.0 if is_inf(lowest) else lowest
