extends Node3D
## Scene bootstrap: creates the components in order and connects them. The scenario, HUD, tank,
## environment, and diagnostic tools each have their own controller; this class only decides what
## is created first.
##
## The order matters: scenario first—it is the only slow part and sets the player's entry
## position—then the renderer, which needs the populated world to build the atlas and BVH, and HUD
## last, once there is something to report.

@onready var _voxel_world: VoxelWorld3D = $VoxelWorld
@onready var _hud: GameHud = $HUD

var _scenario: ScenarioLoader
var _voxel_renderer: VoxelRenderSystem
var _diagnostics: MainDiagnostics
var _tank: VoxelTank3D


func _ready() -> void:
	if "--debug-colliders" in OS.get_cmdline_user_args():
		var collider_debug := ColliderDebug3D.new()
		collider_debug.name = "ColliderDebug"
		add_child(collider_debug)
		collider_debug.setup($Player/Camera3D, [($Player as CollisionObject3D).get_rid()])
	# Without this, `trace_sun_shadow` always returns 1.0 and no shadows appear. As in Teardown, trace
	# the sun ray against a mipmapped bit volume of the world rather than a shadow map. Filling that
	# volume voxel by voxel in GDScript took 201 s for the full map; in C++ with macrocells, rasterizing
	# it takes 2.9 s (`tests/clipmap_raster_selftest.gd`). Across all four levels, using the bytes as
	# initial texture data, it takes about 2.6 s in the real scene and costs 134 MB at load time.
	_voxel_world.renderer_settings.sun_shadows_enabled = \
		not "--no-voxel-sun-shadows" in OS.get_cmdline_user_args()
	_scenario = ScenarioLoader.new()
	_scenario.name = "ScenarioLoader"
	add_child(_scenario)
	_scenario.setup(
		_voxel_world, $Player, $Player/Camera3D, $Ground, $WorldEnvironment, $Sun, _hud
	)
	await _scenario.build()
	_tank = VoxelTank3D.spawn(
		_voxel_world,
		($Player as Node3D).global_position + Vector3(0, 0.2, -14),
		$Player as Node3D
	)
	_voxel_renderer = VoxelRenderSystem.new()
	_voxel_renderer.name = "VoxelRenderSystem"
	add_child(_voxel_renderer)
	var renderer_started := false
	if _scenario.loading != null:
		_scenario.loading.set_range(0.30, 1.0)
		renderer_started = await _voxel_renderer.setup_progressive(
			_voxel_world, $Player/Camera3D, _scenario.loading.report
		)
	else:
		renderer_started = _voxel_renderer.setup(_voxel_world, $Player/Camera3D)
	if not renderer_started:
		push_error("Could not start the dedicated DDA renderer")
	_scenario.close_loading()
	_scenario.apply_environment_to(_voxel_renderer)
	# The HUD also uses these metrics outside benchmarks.
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_hud.setup(_voxel_world, _voxel_renderer, $Player, $Player/Camera3D)
	_diagnostics = MainDiagnostics.new()
	_diagnostics.name = "MainDiagnostics"
	add_child(_diagnostics)
	_diagnostics.setup(_voxel_world, _voxel_renderer, $Player, _hud)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		get_tree().reload_current_scene()
