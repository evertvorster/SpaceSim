class_name SpacesimSettingsPanel
extends Control
## The settings screen: staged edits, Apply to commit, Close to discard.
##
## Modelled on the vegastrike config screen. A control edits a staging area rather than the live
## settings, any setting can be put back to its engine default, and while there is something
## waiting to be applied **both Apply and Close change colour** — Close throws the staging away,
## so the colour is the warning, not the decoration.
##
## Rows come from the registry, so a newly declared setting appears here without this file
## changing. Editing a *binding* is text for now; capturing a key press is the next step.

const SettingsScript := preload("res://addons/spacesim/settings/settings.gd")
const EditScript := preload("res://addons/spacesim/settings/settings_edit.gd")

const IDLE_COLOR := Color(1.0, 1.0, 1.0)
const PENDING_COLOR := Color(1.0, 0.72, 0.25)
const INVALID_COLOR := Color(1.0, 0.35, 0.3)

signal closed
signal exit_requested

var _settings: Node
var _edit: SpacesimSettingsEdit
var _fields: Dictionary = {} ## key -> the controls that edit it
var _apply_button: Button
var _close_button: Button
var _updating := false


func configure(settings: Node) -> void:
	_settings = settings
	_edit = EditScript.new(settings)
	_build()
	_edit.changed.connect(_refresh)
	_refresh()


func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.65)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -430.0
	panel.offset_top = -320.0
	panel.offset_right = 430.0
	panel.offset_bottom = 320.0
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 16)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 22)
	column.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(grid)

	for key in EditScript.editable_keys():
		_add_row(grid, key)

	column.add_child(_build_buttons())


func _add_row(grid: GridContainer, key: String) -> void:
	var label := Label.new()
	label.text = key
	label.custom_minimum_size = Vector2(300.0, 0.0)
	grid.add_child(label)

	var editors := _build_editors(key)
	for editor in editors:
		grid.add_child(editor)

	var reset := Button.new()
	reset.name = "Reset"
	reset.text = "Reset"
	reset.tooltip_text = "Back to the engine's default. Nothing is committed until you apply."
	reset.pressed.connect(func() -> void: _edit.reset_to_default(key))
	grid.add_child(reset)

	_fields[key] = editors


func _build_editors(key: String) -> Array[Control]:
	var default: Variant = SettingsScript.default_of(key)
	var row: Dictionary = SettingsScript.REGISTRY.get(key, {})
	var editors: Array[Control] = []

	match typeof(default):
		TYPE_FLOAT, TYPE_INT:
			editors.append(_number_field(key, default, row, 0))
		TYPE_VECTOR2:
			var pair := HBoxContainer.new()
			pair.add_theme_constant_override("separation", 6)
			pair.add_child(_number_field(key, default, row, 0))
			pair.add_child(_number_field(key, default, row, 1))
			editors.append(pair)
		TYPE_STRING:
			editors.append(_text_field(key))
	return editors


func _number_field(key: String, default: Variant, row: Dictionary, component: int) -> SpinBox:
	var field := SpinBox.new()
	field.custom_minimum_size = Vector2(150.0, 0.0)
	field.step = 1.0 if typeof(default) == TYPE_INT else _step_for(_component_of(default, component))

	var low: Variant = _bound(row, component, "min")
	var high: Variant = _bound(row, component, "max")
	field.min_value = float(low) if low != null else -1.0e12
	field.max_value = float(high) if high != null else 1.0e12
	field.allow_greater = false
	field.allow_lesser = false
	field.value = _component_of(_edit.value(key), component)
	field.value_changed.connect(func(new_value: float) -> void: _stage_number(key, component, new_value))
	return field


func _text_field(key: String) -> LineEdit:
	var field := LineEdit.new()
	field.custom_minimum_size = Vector2(300.0, 0.0)
	field.text = String(_edit.value(key))
	field.text_changed.connect(func(new_text: String) -> void: _stage_text(key, field, new_text))
	return field


func _stage_number(key: String, component: int, new_value: float) -> void:
	if _updating:
		return
	var current: Variant = _edit.value(key)
	if typeof(current) == TYPE_VECTOR2:
		var updated: Vector2 = current
		if component == 0:
			updated.x = new_value
		else:
			updated.y = new_value
		_edit.stage(key, updated)
	elif typeof(SettingsScript.default_of(key)) == TYPE_INT:
		_edit.stage(key, int(roundf(new_value)))
	else:
		_edit.stage(key, new_value)


## A binding that does not parse is shown as invalid rather than staged, so Apply cannot be the
## place you find out.
func _stage_text(key: String, field: LineEdit, new_text: String) -> void:
	if _updating:
		return
	var acceptable := SettingsScript.is_acceptable(key, new_text)
	field.modulate = IDLE_COLOR if acceptable else INVALID_COLOR
	if acceptable:
		_edit.stage(key, new_text)


func _build_buttons() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)

	_apply_button = Button.new()
	_apply_button.name = "Apply"
	_apply_button.text = "Apply"
	_apply_button.pressed.connect(func() -> void: _edit.apply())
	row.add_child(_apply_button)

	_close_button = Button.new()
	_close_button.name = "Close"
	_close_button.text = "Close"
	_close_button.tooltip_text = "Discards anything you have not applied."
	_close_button.pressed.connect(_on_close)
	row.add_child(_close_button)

	var exit_button := Button.new()
	exit_button.name = "ExitGame"
	exit_button.text = "Exit Game"
	exit_button.pressed.connect(func() -> void: exit_requested.emit())
	row.add_child(exit_button)

	return row


func _on_close() -> void:
	_edit.discard()
	closed.emit()


## Pull every control back to what the staging area holds — which is how a Reset shows up, and how
## a discarded edit disappears.
func _refresh() -> void:
	_updating = true
	for key in _fields.keys():
		var editors: Array = _fields[key]
		var value: Variant = _edit.value(key)
		if editors[0] is HBoxContainer:
			var pair: HBoxContainer = editors[0]
			for index in pair.get_child_count():
				var field = pair.get_child(index)
				if field is SpinBox:
					field.value = _component_of(value, index)
		elif editors[0] is SpinBox:
			editors[0].value = float(value)
		elif editors[0] is LineEdit:
			editors[0].text = String(value)
			editors[0].modulate = IDLE_COLOR
	_updating = false

	var pending := _edit.has_changes()
	_apply_button.modulate = PENDING_COLOR if pending else IDLE_COLOR
	_close_button.modulate = PENDING_COLOR if pending else IDLE_COLOR


static func _component_of(value: Variant, index: int) -> float:
	if typeof(value) == TYPE_VECTOR2:
		return value.x if index == 0 else value.y
	return float(value)


static func _bound(row: Dictionary, component: int, name: String) -> Variant:
	if not row.has(name):
		return null
	var bound: Variant = row[name]
	if typeof(bound) == TYPE_VECTOR2:
		return bound.x if component == 0 else bound.y
	if typeof(bound) == TYPE_FLOAT or typeof(bound) == TYPE_INT:
		return float(bound)
	return null


## Three significant digits of the value's own magnitude, so a slow-stepping sensitivity and a
## hundred-million-kilometre far plane both get a usable arrow-key step.
static func _step_for(value: float) -> float:
	var magnitude := absf(value)
	if magnitude < 1.0e-12:
		return 0.0001
	return pow(10.0, floor(log(magnitude) / log(10.0)) - 3.0)
