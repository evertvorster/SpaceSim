class_name SpacesimSettingsPanel
extends SpacesimScreen
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
const DisplayScript := preload("res://addons/spacesim/settings/display.gd")

const IDLE_COLOR := Color(1.0, 1.0, 1.0)
const PENDING_COLOR := Color(1.0, 0.72, 0.25)
const INVALID_COLOR := Color(1.0, 0.35, 0.3)

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
	build_screen("Settings")

	var grid := GridContainer.new()
	grid.name = "Settings"
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	content.add_child(grid)

	for key in EditScript.editable_keys():
		_add_row(grid, key)

	_apply_button = add_button("Apply", func() -> void: _edit.apply())
	_close_button = add_button("Close", _on_close)
	add_button("Exit Game", func() -> void: exit_requested.emit())


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

	# A row that declares choices is offered rather than typed into. That is the whole difference
	# between picking your monitor and guessing at a number for it.
	var choices := _choices(row)
	if not choices.is_empty():
		editors.append(_choice_field(key, default, choices))
		return editors

	match typeof(default):
		TYPE_FLOAT, TYPE_INT:
			editors.append(_number_field(key, default, row, 0))
		TYPE_VECTOR2, TYPE_VECTOR2I:
			var pair := HBoxContainer.new()
			pair.add_theme_constant_override("separation", 6)
			pair.add_child(_number_field(key, default, row, 0))
			pair.add_child(_number_field(key, default, row, 1))
			# A resolution is a pair of numbers nobody remembers, so the pair is offered one.
			if typeof(default) == TYPE_VECTOR2I:
				pair.add_child(_resolution_menu(key))
			editors.append(pair)
		TYPE_STRING:
			editors.append(_text_field(key))
	return editors


## The display autoload, or null.
##
## Through the main loop rather than `get_tree()`: these rows are built when the panel is configured,
## which can be before it has been added to the tree — and `get_tree()` is an error, not a null, in
## that state.
func _display() -> Node:
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return null
	return (loop as SceneTree).root.get_node_or_null("SpacesimDisplay")


## The list a row offers, or an empty one when it offers none. `"screens"` is a reserved name for
## the one list that cannot be written down here, because it is the machine's, not ours.
func _choices(row: Dictionary) -> Array:
	var declared: Variant = row.get("choices", null)
	if declared == null:
		return []
	if declared is Array:
		return declared
	if String(declared) != "screens":
		return []
	var display := _display()
	if display == null:
		return []
	return display.screen_names()


## A menu of resolutions beside a resolution row. **The list is built when the menu opens**, not when
## the row is: this window's size and the monitors' resolutions both move underneath it, and a list
## made at startup would already be wrong.
func _resolution_menu(key: String) -> MenuButton:
	var button := MenuButton.new()
	button.text = "Presets"
	button.tooltip_text = "Common resolutions, this window's size, and the resolution each monitor is in."
	var menu := button.get_popup()
	menu.about_to_popup.connect(func() -> void: _fill_resolution_menu(menu))
	menu.index_pressed.connect(
		func(index: int) -> void: _stage_resolution(key, menu.get_item_metadata(index))
	)
	return button


func _fill_resolution_menu(menu: PopupMenu) -> void:
	menu.clear()
	var display := _display()
	if display == null:
		return
	var separated := false
	for preset in display.resolution_presets():
		var label: String = preset["label"]
		var size: Vector2i = preset["size"]
		var text := "%d x %d" % [size.x, size.y]
		if label.is_empty():
			if not separated:
				# Everything from here on is a plain resolution, with nothing to say about where it
				# came from.
				menu.add_separator()
				separated = true
		else:
			text = "%s   %s" % [label, text]
		menu.add_item(text)
		menu.set_item_metadata(menu.item_count - 1, size)


## Picking one fills the two fields, which is a staged edit like any other: Apply commits it and
## Close throws it away. A preset the registry would refuse is not staged, so it cannot look as
## though it worked.
func _stage_resolution(key: String, size: Variant) -> void:
	if typeof(size) == TYPE_VECTOR2I:
		_edit.stage(key, size)


## A list to choose from. What a choice *is* depends on the setting: an enum's value is its word, a
## screen's is its number — the position in the list is the screen index.
func _choice_field(key: String, default: Variant, choices: Array) -> OptionButton:
	var field := OptionButton.new()
	field.custom_minimum_size = Vector2(300.0, 0.0)
	for index in choices.size():
		field.add_item(String(choices[index]), index)
	field.selected = _choice_index(_edit.value(key), default, choices)
	field.item_selected.connect(
		func(index: int) -> void: _stage_choice(key, default, choices, index)
	)
	return field


## A stored screen that has since gone still has to land on something to show, so the index is
## clamped rather than left to point past the end of the list.
static func _choice_index(value: Variant, default: Variant, choices: Array) -> int:
	if typeof(default) == TYPE_INT:
		return clampi(int(value), 0, maxi(0, choices.size() - 1))
	return maxi(0, choices.find(String(value)))


func _stage_choice(key: String, default: Variant, choices: Array, index: int) -> void:
	if _updating:
		return
	var chosen: Variant = index if typeof(default) == TYPE_INT else String(choices[index])
	_edit.stage(key, chosen)


func _number_field(key: String, default: Variant, row: Dictionary, component: int) -> SpinBox:
	var field := SpinBox.new()
	field.custom_minimum_size = Vector2(150.0, 0.0)
	# A resolution is whole numbers: an arrow key that offers 1279.7 is not a resolution.
	field.step = (
		1.0
		if typeof(default) == TYPE_INT or typeof(default) == TYPE_VECTOR2I
		else _step_for(_component_of(default, component))
	)

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
	var default: Variant = SettingsScript.default_of(key)
	var current: Variant = _edit.value(key)
	if typeof(default) == TYPE_VECTOR2I:
		var rounded: Vector2i = Vector2i(current)
		if component == 0:
			rounded.x = int(roundf(new_value))
		else:
			rounded.y = int(roundf(new_value))
		_edit.stage(key, rounded)
	elif typeof(current) == TYPE_VECTOR2:
		var updated: Vector2 = current
		if component == 0:
			updated.x = new_value
		else:
			updated.y = new_value
		_edit.stage(key, updated)
	elif typeof(default) == TYPE_INT:
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


func _on_close() -> void:
	closed.emit()


## Leaving without applying throws the staged edits away — which is what the amber Close button
## warns about. It holds whichever route the screen is left by, not only the Close button.
func dismissed() -> void:
	_edit.discard()


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
		elif editors[0] is OptionButton:
			var row: Dictionary = SettingsScript.REGISTRY.get(key, {})
			editors[0].selected = _choice_index(value, SettingsScript.default_of(key), _choices(row))
		elif editors[0] is LineEdit:
			editors[0].text = String(value)
			editors[0].modulate = IDLE_COLOR
	_updating = false

	var pending := _edit.has_changes()
	_apply_button.modulate = PENDING_COLOR if pending else IDLE_COLOR
	_close_button.modulate = PENDING_COLOR if pending else IDLE_COLOR


static func _component_of(value: Variant, index: int) -> float:
	match typeof(value):
		TYPE_VECTOR2:
			return value.x if index == 0 else value.y
		TYPE_VECTOR2I:
			return float(value.x) if index == 0 else float(value.y)
	return float(value)


static func _bound(row: Dictionary, component: int, name: String) -> Variant:
	if not row.has(name):
		return null
	var bound: Variant = row[name]
	match typeof(bound):
		TYPE_VECTOR2:
			return bound.x if component == 0 else bound.y
		TYPE_VECTOR2I:
			return float(bound.x) if component == 0 else float(bound.y)
		TYPE_FLOAT, TYPE_INT:
			return float(bound)
	return null


## Three significant digits of the value's own magnitude, so a slow-stepping sensitivity and a
## hundred-million-kilometre far plane both get a usable arrow-key step.
static func _step_for(value: float) -> float:
	var magnitude := absf(value)
	if magnitude < 1.0e-12:
		return 0.0001
	return pow(10.0, floor(log(magnitude) / log(10.0)) - 3.0)
