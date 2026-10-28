extends Node3D
## Visual stress test equivalent to the small map: the renderer starts with one Shape and receives
## 520 more in a burst, exceeding the original 256 reserved entries.

const FRAGMENT_COUNT := 520

var _world: VoxelWorld3D
var _body: VoxelBody3D
var _renderer: VoxelRenderSystem
var _palette: VoxelPalette
var _frames_after_spawn := -1


func _ready() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(0, 8, 18)
	add_child(camera)
	camera.look_at(Vector3.ZERO)
	_world = VoxelWorld3D.new()
	_world.show_diagnostics = false
	_world.renderer_settings = VoxelRendererSettings.new()
	_world.renderer_settings.sun_shadows_enabled = false
	add_child(_world)
	_body = VoxelBody3D.new()
	_body.structural = false
	_world.add_child(_body)
	_palette = VoxelPalette.new()
	var seed := _new_shape(0)
	_body.add_voxel_shape(seed, false, false)
	_world.register_body(_body)
	_renderer = VoxelRenderSystem.new()
	add_child(_renderer)
	if not _renderer.setup(_world, camera):
		push_error("Could not start the renderer for the capacity test")
		get_tree().quit(90)
		return
	_spawn_fragments.call_deferred()


func _new_shape(index: int) -> VoxelShape3D:
	var cells := PackedByteArray()
	cells.resize(8)
	cells.fill(1)
	var data := VoxelShapeData.new()
	data.set_cells(Vector3i(2, 2, 2), cells)
	var shape := VoxelShape3D.new()
	shape.name = "StressFragment%d" % index
	shape.data = data
	shape.palette = _palette
	shape.anchored = true
	shape.position = Vector3((index % 26) * 0.25, (index / 26) * 0.25, 0)
	return shape


func _spawn_fragments() -> void:
	for index in FRAGMENT_COUNT:
		var shape := _new_shape(index + 1)
		_body.add_voxel_shape(shape, false, false)
		_world.register_shape(shape)
		_renderer.register_shape(shape)
	_frames_after_spawn = 0


func _process(_delta: float) -> void:
	if _frames_after_spawn < 0:
		return
	_frames_after_spawn += 1
	if _frames_after_spawn < 12:
		return
	var audit := _renderer.get_coherence_snapshot()
	var passed := (audit.missing_slots as Array).is_empty() \
		and (audit.missing_entries as Array).is_empty() \
		and (audit.invalid_entries as Array).is_empty() \
		and int(audit.live_shapes) == FRAGMENT_COUNT + 1 \
		and _renderer.entry_capacity_rebuilds == 1
	print("VOXEL_RENDERER_FRAGMENT_CAPACITY_RESULT ", JSON.stringify({
		"audit": audit,
		"pass": passed,
	}))
	get_tree().quit(0 if passed else 91)
