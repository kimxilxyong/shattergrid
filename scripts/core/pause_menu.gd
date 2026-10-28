extends CanvasLayer
## Global pause menu. Always processes so it can receive the same action before and during a pause.

@onready var _overlay: Control = $Overlay
@onready var _resume_button: Button = $Overlay/Layout/MenuCard/Content/ResumeButton

var _mouse_mode_before_pause := Input.MOUSE_MODE_CAPTURED


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_overlay.visible = false
	_resume_button.pressed.connect(resume_game)
	$Overlay/Layout/MenuCard/Content/RestartButton.pressed.connect(_restart_game)
	$Overlay/Layout/MenuCard/Content/QuitButton.pressed.connect(_quit_game)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and not event.is_echo():
		get_viewport().set_input_as_handled()
		if get_tree().paused:
			resume_game()
		else:
			pause_game()


func pause_game() -> void:
	if get_tree().paused:
		return
	_mouse_mode_before_pause = Input.mouse_mode
	_overlay.visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_resume_button.grab_focus()


func resume_game() -> void:
	if not get_tree().paused:
		return
	_overlay.visible = false
	get_tree().paused = false
	Input.mouse_mode = _mouse_mode_before_pause


func _restart_game() -> void:
	_overlay.visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().reload_current_scene()


func _quit_game() -> void:
	get_tree().paused = false
	get_tree().quit()


func _exit_tree() -> void:
	if get_tree() != null:
		get_tree().paused = false
