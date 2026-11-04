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
const Actions := preload("res://addons/spacesim/input/actions.gd")
const Devices := preload("res://addons/spacesim/input/devices.gd")
const Binding := preload("res://addons/spacesim/input/binding.gd")
const Store := preload("res://addons/spacesim/input/bindings_store.gd")
const EditScript := preload("res://addons/spacesim/settings/settings_edit.gd")
const DisplayScript := preload("res://addons/spacesim/settings/display.gd")

## The tabs the screen draws itself, because what is on them is not settings: the actions' bindings
## (which left the registry) and the attached gamepads.
const BINDINGS_TAB := "bindings"
const DEVICES_TAB := "devices"

## A button of a pad that is up, and one that is held. The resting colour is dim enough that a lit
## button is visible from across the room, which is the point of the tab.
const BUTTON_UP_COLOR := Color(1.0, 1.0, 1.0, 0.35)
const BUTTON_DOWN_COLOR := Color(1.0, 0.9, 0.3)
const BUTTON_COLUMNS := 7

const IDLE_COLOR := Color(1.0, 1.0, 1.0)
const PENDING_COLOR := Color(1.0, 0.72, 0.25)
const INVALID_COLOR := Color(1.0, 0.35, 0.3)

var _settings: Node
var _edit: SpacesimSettingsEdit
var _fields: Dictionary = {} ## key -> the controls that edit it
var _bindings: SpacesimBindingsStore
var _binding_fields: Dictionary = {} ## action id -> the field that shows its bindings

## The devices tab's live readouts: `[device, axis index, Label]` and `[device, button index, Label]`.
var _axis_labels: Array = []
var _button_labels: Array = []

## **The device being set up, by name**, or `""`. While one is set, `main.gd` consumes that device's
## events so it reaches this screen and nothing else — see [method configuring_device].
var _configuring := ""
var _configure_boxes: Array = []
var _apply_button: Button
var _close_button: Button
var _updating := false


func configure(settings: Node, bindings: SpacesimBindingsStore) -> void:
	_settings = settings
	_bindings = bindings
	_edit = EditScript.new(settings)
	_build()
	_edit.changed.connect(_refresh)
	_refresh()


func _build() -> void:
	build_screen("Settings")

	# **The grouping comes from the registry**, one `tab` per row, so a setting is filed by declaring
	# where it goes. Grouping by key prefix here instead would put that knowledge in two places, and a
	# `video.hdr` added later would land in whichever tab the prefix rule happened to name.
	var tabs := TabContainer.new()
	tabs.name = "Tabs"
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(tabs)

	for tab in SettingsScript.TABS:
		var keys := _keys_in(tab)
		var actions := _actions_in(tab)
		var is_devices: bool = tab == DEVICES_TAB
		# A tab nothing was filed into is not built: an empty page is a promise of settings that are
		# somewhere else. The devices tab is the exception — **an empty device list is worth showing**,
		# because "nothing is connected" is the answer to the question the tab asks.
		if keys.is_empty() and actions.is_empty() and not is_devices:
			continue
		var page := ScrollContainer.new()
		page.name = SettingsScript.tab_title(tab)
		page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		tabs.add_child(page)

		var column := VBoxContainer.new()
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_theme_constant_override("separation", 12)
		page.add_child(column)
		if not keys.is_empty():
			var grid := _grid()
			column.add_child(grid)
			for key in keys:
				_add_row(grid, key)
		if is_devices:
			_build_devices(column)
		# **The actions are not settings**, so they get their own grid per category rather than a row
		# among the settings — and this is the only tab that has any.
		for category in Actions.CATEGORIES:
			var ids := _actions_in(tab, category)
			if ids.is_empty():
				continue
			var heading := Label.new()
			heading.text = category
			heading.add_theme_font_size_override("font_size", 16)
			column.add_child(heading)
			var action_grid := _grid()
			column.add_child(action_grid)
			for id in ids:
				_add_binding_row(action_grid, id)

	_apply_button = add_button("Apply", _on_apply)
	_close_button = add_button("Close", _on_close)


## **What the attached gamepads are doing**, live: each device's name and identity, its axes with
## their current deflection, and the buttons held right now.
##
## Read-only on purpose. Binding a pad is the next rung, and the two ways of doing it — typing the text or
## pressing the control — both need this list to exist first, because a player has to see what the
## device is reporting before they can bind it.
func _build_devices(column: VBoxContainer) -> void:
	_axis_labels.clear()
	_button_labels.clear()
	var pads := Devices.connected()
	if pads.is_empty():
		var none := Label.new()
		none.text = "No joystick or gamepad is connected."
		none.modulate = Color(1.0, 1.0, 1.0, 0.7)
		column.add_child(none)
		return

	var summary := Label.new()
	summary.text = "%d device%s" % [pads.size(), "" if pads.size() == 1 else "s"]
	summary.modulate = Color(1.0, 1.0, 1.0, 0.7)
	column.add_child(summary)

	for device in pads:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 4)
		column.add_child(box)

		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", 12)
		box.add_child(header)

		var title := Label.new()
		title.text = Devices.name_of(device)
		title.add_theme_font_size_override("font_size", 16)
		header.add_child(title)

		# **One device at a time**: what is being set up is a single target, and two devices both routed
		# away from the menus would be a way to bind the wrong pad.
		var configure := CheckBox.new()
		configure.text = "Configure"
		configure.tooltip_text = (
			"While this is on, this device does not press anything in the game or its menus — "
			+ "it only reaches this screen."
		)
		configure.button_pressed = _configuring == Devices.name_of(device)
		configure.toggled.connect(
			func(on: bool) -> void: _set_configuring(Devices.name_of(device) if on else "")
		)
		header.add_child(configure)
		_configure_boxes.append([device, configure])

		# **Whether the engine knows the device is the one fact that changes what its numbers mean**: a
		# known pad reports named controls in −1…1, an unknown one reports raw indices.
		var detail := Label.new()
		var raw := Devices.raw_name_of(device)
		detail.text = "guid %s   ·   %s" % [
			Devices.guid_of(device),
			"mapped" if Devices.is_known(device) else "NO MAPPING — raw indices",
		]
		if not raw.is_empty() and raw != Devices.name_of(device):
			detail.text += "   ·   os calls it '%s'" % raw
		detail.modulate = Color(1.0, 1.0, 1.0, 0.55)
		box.add_child(detail)

		# **One axis per line**, name then value: a row of six numbers across the panel is a table to
		# decode, and what a player is doing here is watching one stick move.
		var axes_grid := _grid()
		axes_grid.columns = 2
		for index in Devices.AXIS_NAMES.size():
			var name_label := Label.new()
			name_label.text = Devices.AXIS_NAMES[index]
			name_label.add_theme_font_size_override("font_size", 13)
			name_label.modulate = Color(1.0, 1.0, 1.0, 0.6)
			axes_grid.add_child(name_label)
			var value_label := Label.new()
			value_label.name = "Axis%d" % index
			value_label.add_theme_font_size_override("font_size", 13)
			value_label.custom_minimum_size = Vector2(56.0, 0.0)
			axes_grid.add_child(value_label)
			_axis_labels.append([device, index, value_label])
		box.add_child(axes_grid)

		# **Every button, laid out**, rather than only the one held: the point of the tab is to see what
		# the device *has*, and a button you cannot find is one you cannot bind. Lit when it is down.
		var button_grid := GridContainer.new()
		button_grid.columns = BUTTON_COLUMNS
		button_grid.add_theme_constant_override("h_separation", 10)
		button_grid.add_theme_constant_override("v_separation", 2)
		box.add_child(button_grid)
		for index in Devices.BUTTON_NAMES.size():
			var button_label := Label.new()
			button_label.name = "Button%d" % index
			button_label.text = Devices.BUTTON_NAMES[index]
			button_label.add_theme_font_size_override("font_size", 12)
			button_label.custom_minimum_size = Vector2(84.0, 0.0)
			button_grid.add_child(button_label)
			_button_labels.append([device, index, button_label])

	_refresh_devices()


## **Which device is being set up**, by name, or `""` for none. `main.gd` asks this for every joypad
## event: while a device is named here, its events are consumed before the GUI sees them, so it cannot
## steer a menu or fire a game action while the player is binding it.
func configuring_device() -> String:
	return _configuring


## Set it, and keep the checkboxes in step. **One at a time**: turning one on turns the rest off.
func _set_configuring(device_name: String) -> void:
	_configuring = device_name
	for entry in _configure_boxes:
		var box: CheckBox = entry[1]
		box.set_pressed_no_signal(device_name != "" and Devices.name_of(int(entry[0])) == device_name)


## The live half: called every frame while a screen is up, and it is six axis reads and twenty button
## reads per device — nothing.
func _refresh_devices() -> void:
	for entry in _axis_labels:
		var label: Label = entry[2]
		var value: float = Devices.axis(int(entry[0]), int(entry[1]))
		label.text = "%+.2f" % value
		label.modulate = (
			Color(1.0, 0.9, 0.3) if absf(value) > Devices.SHOWN_AS_MOVED else Color(1.0, 1.0, 1.0, 0.45)
		)
	for entry in _button_labels:
		var label: Label = entry[2]
		var down := Input.is_joy_button_pressed(int(entry[0]), int(entry[1]))
		label.modulate = BUTTON_DOWN_COLOR if down else BUTTON_UP_COLOR


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_devices()


## A grid of rows, three columns, as every table on this screen is.
static func _grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.name = "Settings"
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	return grid


## The actions shown on a tab, in registry order, optionally within one category. **Only the bindings
## tab has any**, and that is decided by `Settings.tab_of` on the *settings* side: an action belongs
## wherever its category is shown, which today is the one tab called `bindings`.
static func _actions_in(tab: String, category := "") -> Array:
	if tab != BINDINGS_TAB:
		return []
	var found: Array = []
	for id in Actions.ids():
		if not category.is_empty() and Actions.category_of(id) != category:
			continue
		found.append(id)
	return found


## The editable keys filed under one tab, in registry order.
static func _keys_in(tab: String) -> Array:
	var keys: Array = []
	for key in EditScript.editable_keys():
		if SettingsScript.tab_of(key) == tab:
			keys.append(key)
	return keys


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
		TYPE_COLOR:
			editors.append(_color_field(key))
		TYPE_STRING:
			editors.append(_text_field(key))
		# **A boolean has two states and no third, so a checkbox is the one control that cannot be got
		# wrong** — and it is what a saved boolean needs to exist as a real setting rather than as session
		# state. The suite requires every declared setting to have a control, so this branch is the price
		# of declaring one.
		TYPE_BOOL:
			editors.append(_bool_field(key))
	return editors


## A checkbox, staged like every other control: the box moves at once and the value commits on Apply.
func _bool_field(key: String) -> CheckBox:
	var field := CheckBox.new()
	field.button_pressed = bool(_edit.value(key))
	field.toggled.connect(func(pressed: bool) -> void:
		if _updating:
			return
		_edit.stage(key, pressed)
	)
	return field


## Godot's own colour button: a swatch that opens the picker. **A colour is a thing you look at**, so
## typing one as text would be a spelling test, and picking one against the background it will be seen
## on is the whole point of making it a setting.
func _color_field(key: String) -> ColorPickerButton:
	var field := ColorPickerButton.new()
	field.custom_minimum_size = Vector2(120.0, 26.0)
	field.color = _edit.value(key)
	field.color_changed.connect(func(new_color: Color) -> void: _stage_color(key, new_color))
	return field


func _stage_color(key: String, new_color: Color) -> void:
	if _updating:
		return
	_edit.stage(key, new_color)


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


## **One row per action**: its label, its bindings as text, and a Reset.
##
## Text editing, not capture — pressing the key you want is the follow-up, and it needs the dialog the
## design note describes. What this row already gets right is the staging: an edit that does not parse is
## **coloured and not staged**, so a typo cannot reach the file.
func _add_binding_row(grid: GridContainer, action: String) -> void:
	var label := Label.new()
	label.text = Actions.label_of(action)
	label.custom_minimum_size = Vector2(300.0, 0.0)
	grid.add_child(label)

	var field := LineEdit.new()
	field.name = "Bindings"
	field.text = _bindings_text(action)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.tooltip_text = "One or more bindings, separated by commas: W, Alt+C, Mouse:Left"
	field.text_changed.connect(func(text: String) -> void: _stage_bindings(action, text))
	grid.add_child(field)
	_binding_fields[action] = field

	var reset := Button.new()
	reset.name = "Reset"
	reset.text = "Reset"
	reset.tooltip_text = "Back to the engine's default. Nothing is committed until you apply."
	reset.pressed.connect(
		func() -> void:
			_bindings.reset(action)
			_refresh()
	)
	grid.add_child(reset)


## Stage what was typed, or colour it and stage nothing. **The field is the whole chord list**, so a
## half-typed binding fails here rather than becoming a key that fires nothing.
func _stage_bindings(action: String, text: String) -> void:
	if _updating:
		return
	var parts: Array = []
	for part in text.split(Store.SEPARATOR, false):
		if not part.strip_edges().is_empty():
			parts.append(part.strip_edges())
	for part in parts:
		if not Binding.is_valid(String(part)):
			_binding_fields[action].modulate = INVALID_COLOR
			return
	_binding_fields[action].modulate = IDLE_COLOR
	if not _bindings.stage(action, parts):
		_binding_fields[action].modulate = INVALID_COLOR


func _bindings_text(action: String) -> String:
	return Store.SEPARATOR.join(PackedStringArray(_bindings.of(action)))


## Apply is **two** edits now, and it only goes idle when both have committed. A file that cannot be
## written leaves the button amber, which is the one signal the player has.
func _on_apply() -> void:
	_edit.apply()
	if _bindings.apply() < 0:
		push_warning("settings: the bindings could not be written")
	_refresh()


func _on_close() -> void:
	closed.emit()


## Leaving without applying throws the staged edits away — which is what the amber Close button
## warns about. It holds whichever route the screen is left by, not only the Close button.
func dismissed() -> void:
	_edit.discard()
	if _bindings != null:
		_bindings.discard()
	# **A screen that is closed is not configuring anything.** The flag is read live by `main.gd`, so
	# leaving it set would keep a device deaf to the game with nothing on screen to explain why.
	_set_configuring("")


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
		elif editors[0] is ColorPickerButton:
			editors[0].color = value
		elif editors[0] is LineEdit:
			editors[0].text = String(value)
			editors[0].modulate = IDLE_COLOR
		elif editors[0] is CheckBox:
			editors[0].button_pressed = bool(value)
	_updating = false

	for action in _binding_fields:
		var field: LineEdit = _binding_fields[action]
		field.text = _bindings_text(action)
		field.modulate = IDLE_COLOR

	var pending := _edit.has_changes() or _bindings.has_changes()
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
