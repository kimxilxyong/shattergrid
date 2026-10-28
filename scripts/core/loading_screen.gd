class_name LoadingScreen
extends CanvasLayer
## Map loading screen. It is built by the script from eight nodes, so it does not also need to be
## maintained in `main.tscn`.
##
## The importer is a single blocking call, so this screen is visible only if something yields
## frames to the engine. [TeardownMapImporter] does this with `await` between stages; the cost of
## those frames is measured and reported as `progress_ms`, making any future overhead visible.

var _title: Label
var _detail: Label
var _source: Label
var _bar: ProgressBar
var _started := Time.get_ticks_msec()
var _low := 0.0
var _high := 1.0


func _init() -> void:
	layer = 200
	# The tree is paused during import; this layer must keep running so it can redraw.
	process_mode = Node.PROCESS_MODE_ALWAYS
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.035, 0.055, 1.0)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	var layout := CenterContainer.new()
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(layout)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(560, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.055, 0.085, 0.96)
	style.set_content_margin_all(34.0)
	style.set_border_width_all(1)
	style.border_color = Color(0.28, 0.72, 0.92, 0.32)
	style.set_corner_radius_all(18)
	card.add_theme_stylebox_override("panel", style)
	layout.add_child(card)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	card.add_child(content)

	content.add_child(_label("SHATTERGRID  /  LOADING MAP", 14, Color(0.38, 0.86, 1, 1)))
	_title = _label("Preparing…", 30, Color(0.94, 0.98, 1, 1))
	content.add_child(_title)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(0, 10)
	_bar.max_value = 1.0
	_bar.step = 0.0
	_bar.show_percentage = false
	content.add_child(_bar)

	_detail = _label("", 15, Color(0.65, 0.72, 0.8, 1))
	content.add_child(_detail)
	_source = _label("", 15, Color(0.55, 0.85, 0.6, 1))
	content.add_child(_source)


## Each stage reports its own 0..1 progress; the range maps it to the global progress bar.
func set_range(low: float, high: float) -> void:
	_low = low
	_high = high


## Passed to each stage as a `Callable`. `source` is sent only when it changes; the line indicates
## whether the map is loaded from the compiled cache or built from scratch.
func report(fraction: float, label: String, source := "") -> void:
	var overall := _low + (_high - _low) * clampf(fraction, 0.0, 1.0)
	_title.text = label
	_bar.value = overall
	_detail.text = "%d %%  ·  %.1f s" % [
		roundi(overall * 100.0), (Time.get_ticks_msec() - _started) / 1000.0,
	]
	if not source.is_empty():
		_source.text = source


static func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label
