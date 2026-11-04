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
const AxisProfile := preload("res://addons/spacesim/input/axis_profile.gd")
const AxisBar := preload("res://addons/spacesim/ui/axis_bar.gd")
const Dialog := preload("res://addons/spacesim/ui/dialog.gd")
const Debug := preload("res://addons/spacesim/system/debug.gd")
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
## The Bindings tab's rows, **one per binding**, as `[action id, index in that action's list, LineEdit]`.
var _binding_rows: Array = []
## Empty rows **Add** has opened on an action: rows to detect into, not bindings.
var _extra_rows := {}
var _bindings_vbox: VBoxContainer
## A detection in progress, `{action, index}`, or empty. While it is set `main.gd` forwards events here
## and marks them handled, so nothing pressed in order to bind a control also presses it in the game.
var _detect := {}
var _detected := ""
## Per device, the axis readings at the last look — what makes "the biggest change" a fact.
var _detect_previous := {}
## Set by anything that changes how many rows there are. **The rebuild cannot run inside a button's own
## `pressed` signal** — freeing the button that is emitting is the error the codebase already has a note
## about — so it is done at the next frame, and [method flush_rows] is how a test asks for it now.
var _rows_dirty := false
## The row to put the cursor in after the next rebuild, so **Add is visibly an Add**: the new row takes
## the focus, the scroll container brings it into view, and its empty field says what to do next.
var _focus_row: Array = []

## The devices tab's live readouts: `[device, axis index, Label]` and `[device, button index, Label]`.
var _axis_labels: Array = []
var _button_labels: Array = []

## **The device being set up, by name**, or `""`. While one is set, `main.gd` consumes that device's
## events so it reaches this screen and nothing else — see [method configuring_device].
var _configuring := ""
var _configure_boxes: Array = []

## One entry per axis of every device:
## `[device, axis index, bar, value label, centre field, deadband field, calibrate button, status label]`.
var _axis_rows: Array = []
## Where the device blocks are built, so a hot-plug can rebuild just that.
var _devices_column: VBoxContainer
var _dialog: SpacesimDialog
## The axis being calibrated as `[device, axis index]`, or empty.
var _calibrating: Array = []
var _calibrated_low := 0.0
var _calibrated_high := 0.0
var _apply_button: Button
var _close_button: Button
var _updating := false


func configure(settings: Node, bindings: SpacesimBindingsStore) -> void:
	_settings = settings
	_bindings = bindings
	_edit = EditScript.new(settings)
	_build()
	_edit.changed.connect(
		func() -> void:
			_refresh_reason = "a settings edit"
			_refresh()
	)
	_refresh()

	_dialog = Dialog.new()
	_dialog.visible = false
	_dialog.answered.connect(_on_dialog_answered)
	add_child(_dialog)

	# **A device plugged in while this screen is open should appear**, and one pulled out should go — the
	# tab is where a player looks when a pad is not working.
	Input.joy_connection_changed.connect(_on_joy_connection_changed)


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
		_bindings_vbox = VBoxContainer.new()
		_bindings_vbox.add_theme_constant_override("separation", 4)
		column.add_child(_bindings_vbox)
		_rebuild_binding_rows()

	_apply_button = add_button("Apply", _on_apply)
	_close_button = add_button("Close", _on_close)


## **What the attached gamepads are doing**, live: each device's name and identity, its axes with
## their current deflection, and the buttons held right now.
##
## Read-only on purpose. Binding a pad is the next rung, and the two ways of doing it — typing the text or
## pressing the control — both need this list to exist first, because a player has to see what the
## device is reporting before they can bind it.
func _build_devices(column: VBoxContainer) -> void:
	_devices_column = column
	_axis_rows.clear()
	_button_labels.clear()
	_configure_boxes.clear()
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

		# **One axis per line**: the name, the line the axis moves along, the shaped value, and the two
		# numbers that decide what "moved" means — then the button that measures its travel.
		for index in Devices.AXIS_NAMES.size():
			box.add_child(_axis_row(device, index))

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
	_poll_detection()
	flush_rows()


## One axis, in two lines — **the numbers above the bar they belong to**, and the controls below it:
##
## ```
## LEFT_X                          centre −0.020      travel −0.98 … +0.82
## ──────────●────▭▭▭─────────  +0.32   deadband [0.050]  [Calibrate] [Centred]
## ```
##
## The centre has no field: it is **whatever the axis reads when Centred is pressed**, which is the only
## number a player cannot type accurately and the one thing the axis itself knows. The travel is always
## shown, default included, so a bar is never drawn against numbers the screen is hiding.
func _axis_row(device: int, index: int) -> VBoxContainer:
	var profile: SpacesimAxisProfile = _profile_of(device, index)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)

	# --- the numbers, above the bar
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	box.add_child(header)

	var name_label := Label.new()
	name_label.text = Devices.AXIS_NAMES[index]
	name_label.custom_minimum_size = Vector2(120.0, 0.0)
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.modulate = Color(1.0, 1.0, 1.0, 0.75)
	header.add_child(name_label)

	var centre_label := Label.new()
	centre_label.name = "Centre"
	centre_label.text = "centre %+.3f" % profile.centre
	centre_label.add_theme_font_size_override("font_size", 12)
	centre_label.modulate = Color(1.0, 1.0, 1.0, 0.55)
	header.add_child(centre_label)

	var travel_label := Label.new()
	travel_label.name = "Travel"
	travel_label.text = _travel_text(profile)
	travel_label.add_theme_font_size_override("font_size", 12)
	travel_label.modulate = Color(1.0, 1.0, 1.0, 0.55)
	header.add_child(travel_label)

	var status := Label.new()
	status.name = "Status"
	status.add_theme_font_size_override("font_size", 12)
	status.modulate = INVALID_COLOR
	header.add_child(status)

	# --- the bar, and what acts on it
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)

	var bar := AxisBar.new()
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.set_state(Devices.axis(device, index), profile)
	row.add_child(bar)

	var value_label := Label.new()
	value_label.name = "Value"
	value_label.custom_minimum_size = Vector2(52.0, 0.0)
	value_label.add_theme_font_size_override("font_size", 13)
	row.add_child(value_label)

	var band_caption := Label.new()
	band_caption.text = "deadband"
	band_caption.add_theme_font_size_override("font_size", 12)
	band_caption.modulate = Color(1.0, 1.0, 1.0, 0.55)
	row.add_child(band_caption)

	var deadband_field := _profile_field(profile.deadband, "deadband")
	deadband_field.text_changed.connect(func(_text: String) -> void: _stage_axis(device, index))
	row.add_child(deadband_field)

	var calibrate := Button.new()
	calibrate.name = "Calibrate"
	calibrate.text = "Calibrate"
	calibrate.tooltip_text = "Measure this axis's travel: fully deflect it both ways, then Save."
	calibrate.pressed.connect(func() -> void: _start_calibration(device, index))
	row.add_child(calibrate)

	var centred := Button.new()
	centred.name = "Centred"
	centred.text = "Centred"
	centred.tooltip_text = "Take the value the axis is reading now as where it rests. Leave the stick alone."
	centred.pressed.connect(func() -> void: _centre_on_reading(device, index))
	row.add_child(centred)

	_axis_rows.append([
		device, index, bar, value_label, centre_label, travel_label,
		deadband_field, calibrate, centred, status,
	])
	return box


static func _travel_text(profile: SpacesimAxisProfile) -> String:
	return "travel %+.2f … %+.2f" % [profile.low, profile.high]


## **Take what the axis reads now as its rest.** The one number a player cannot type accurately, and the
## one the device knows exactly — so it is measured rather than entered.
func _centre_on_reading(device: int, index: int) -> void:
	var profile: SpacesimAxisProfile = _profile_of(device, index).duplicate_profile()
	var reading: float = Devices.axis(device, index)
	var previous := profile.centre
	profile.centre = reading
	var entry := _axis_entry(device, index)
	if not _bindings.stage_axis_profile(Devices.name_of(device), String(Devices.AXIS_NAMES[index]), profile):
		if not entry.is_empty():
			_set_axis_status(entry, "a centre outside the travel")
		profile.centre = previous
		return
	if not entry.is_empty():
		_set_axis_status(entry, "")
	_refresh()


## A text field for one number of a profile, sized for three decimals and a sign.
func _profile_field(value: float, named: String) -> LineEdit:
	var field := LineEdit.new()
	field.name = named
	field.text = "%.3f" % value
	field.custom_minimum_size = Vector2(62.0, 0.0)
	field.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	field.tooltip_text = "The half-width around the centre that reads as nothing."
	return field


func _profile_of(device: int, index: int) -> SpacesimAxisProfile:
	return _bindings.axis_profile(
		Devices.name_of(device), String(Devices.AXIS_NAMES[index])
	)


## Stage what the two fields say. **A profile that cannot make sense is coloured and not staged** — a
## centre outside the travel, or a band that leaves no room to reach full deflection.
func _stage_axis(device: int, index: int) -> void:
	var entry := _axis_entry(device, index)
	if entry.is_empty():
		return
	var band_text: String = (entry[6] as LineEdit).text.strip_edges()
	if not band_text.is_valid_float():
		_set_axis_status(entry, "a number, please")
		return
	var profile: SpacesimAxisProfile = _profile_of(device, index).duplicate_profile()
	profile.deadband = band_text.to_float()
	if not _bindings.stage_axis_profile(
		Devices.name_of(device), String(Devices.AXIS_NAMES[index]), profile
	):
		_set_axis_status(entry, "that does not fit the axis")
		return
	_set_axis_status(entry, "")
	(entry[2] as AxisBar).set_state(Devices.axis(device, index), profile)


## **A complaint, not a report**: the travel is always on screen now, so anything written here is
## something that went wrong — and only the field it went wrong in is coloured.
func _set_axis_status(entry: Array, text: String) -> void:
	(entry[9] as Label).text = text
	(entry[6] as LineEdit).modulate = INVALID_COLOR if not text.is_empty() else IDLE_COLOR


func _axis_entry(device: int, index: int) -> Array:
	for entry in _axis_rows:
		if int(entry[0]) == device and int(entry[1]) == index:
			return entry
	return []


## **Calibrate this axis**: listen to it while the player deflects it both ways, and take the two
## extremes as its travel.
##
## The device is routed away from the menus for the duration — waving a stick to calibrate it would
## otherwise also walk the tab bar — and the dialog's hint line carries the running extremes, which is
## what makes it visible that something is being measured.
func _start_calibration(device: int, index: int) -> void:
	_calibrating = [device, index]
	_calibrated_low = INF
	_calibrated_high = -INF
	_set_configuring(Devices.name_of(device))
	_dialog.ask(
		"Calibrate %s" % Devices.AXIS_NAMES[index],
		(
			"Fully deflect the axis both ways, then press Save.\n\n"
			+ "The device is taken away from the game and its menus while this is open."
		),
		["Save", "Cancel"]
	)
	_dialog.hint.text = "waiting for the axis to move"


func _on_dialog_answered(action: String) -> void:
	if not _detect.is_empty():
		_handle_detect_answer(action)
		return
	if _calibrating.is_empty():
		return
	var device := int(_calibrating[0])
	var index := int(_calibrating[1])
	var entry := _axis_entry(device, index)
	_calibrating = []
	_set_configuring("")

	if action != "Save":
		return
	if _calibrated_high - _calibrated_low < AxisProfile.MIN_CALIBRATED_TRAVEL:
		# **Refused rather than stored**: `±0.0` would make a healthy control dead, and the usual cause is
		# that the axis never spoke.
		if not entry.is_empty():
			_set_axis_status(entry, "the axis did not move")
		return

	var profile: SpacesimAxisProfile = _profile_of(device, index)
	profile = profile.with_travel(_calibrated_low, _calibrated_high)
	if not _bindings.stage_axis_profile(Devices.name_of(device), String(Devices.AXIS_NAMES[index]), profile):
		if not entry.is_empty():
			_set_axis_status(entry, "calibrated travel does not fit the band")
		return
	if not entry.is_empty():
		_set_axis_status(entry, "travel %.2f … %.2f" % [_calibrated_low, _calibrated_high])
	_refresh()


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


## The set of devices changed. **Rebuild only the device blocks**, and forget what was being configured:
## the device that was being set up may be the one that just left, and a name that no longer exists would
## leave the game deaf to nothing.
func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	if _devices_column == null or not is_instance_valid(_devices_column):
		return
	_calibrating = []
	_set_configuring("")
	for child in _devices_column.get_children():
		_devices_column.remove_child(child)
		child.free()
	_build_devices(_devices_column)


## The live half: called every frame while a screen is up, and it is six axis reads and twenty button
## reads per device — nothing.
func _refresh_devices() -> void:
	for entry in _axis_rows:
		var device := int(entry[0])
		var index := int(entry[1])
		var raw: float = Devices.axis(device, index)
		var profile: SpacesimAxisProfile = _profile_of(device, index)
		var shaped: float = profile.shape(raw)
		# **Raw, with the profile**: the bar draws in travel units, so the dot and the box agree.
		(entry[2] as AxisBar).set_state(raw, profile)
		var value_label: Label = entry[3]
		value_label.text = "%+.2f" % shaped
		value_label.modulate = (
			Color(1.0, 0.9, 0.3) if absf(shaped) > 0.0 else Color(1.0, 1.0, 1.0, 0.45)
		)
		(entry[4] as Label).text = "centre %+.3f" % profile.centre
		(entry[5] as Label).text = _travel_text(profile)
		# A calibration in flight takes the raw extremes, not the shaped ones.
		if not _calibrating.is_empty() and int(_calibrating[0]) == device and int(_calibrating[1]) == index:
			_calibrated_low = minf(_calibrated_low, raw)
			_calibrated_high = maxf(_calibrated_high, raw)
			if _dialog != null:
				_dialog.hint.text = "so far   %.2f … %.2f" % [_calibrated_low, _calibrated_high]
	for entry in _button_labels:
		var label: Label = entry[2]
		var down := Input.is_joy_button_pressed(int(entry[0]), int(entry[1]))
		label.modulate = BUTTON_DOWN_COLOR if down else BUTTON_UP_COLOR


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_devices()
	_poll_detection()
	flush_capture()
	# **Rows are rebuilt here, not in a button's own signal**: freeing the control that is emitting is the
	# error this codebase already has a note about.
	flush_rows()


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


## **A row per binding.** The first row of an action carries its label; the rest repeat it dimmed, so a
## column reads as one action's list of bindings.
##
## **Add** opens another row, **Remove** deletes that binding — and on the last row it clears the binding
## instead of the row, because an action always needs somewhere to be bound. An empty row is not a binding:
## Apply writes nothing for one.
func _rebuild_binding_rows() -> void:
	if _bindings_vbox == null:
		return
	for child in _bindings_vbox.get_children():
		_bindings_vbox.remove_child(child)
		child.free()
	_binding_rows.clear()

	Debug.say("bindings[%d]: rebuilt -> %d rows" % [get_instance_id(), _binding_rows.size()])
	for category in Actions.CATEGORIES:
		var ids := Actions.in_category(category)
		if ids.is_empty():
			continue
		var heading := Label.new()
		heading.text = category
		heading.add_theme_font_size_override("font_size", 16)
		_bindings_vbox.add_child(heading)
		var grid := _grid()
		_bindings_vbox.add_child(grid)
		for id in ids:
			var texts := _row_texts(String(id))
			var rows: int = maxi(texts.size(), 1 + int(_extra_rows.get(String(id), 0)))
			for index in rows:
				_add_binding_row(
					grid, String(id), index,
					"" if index >= texts.size() else String(texts[index]),
					index == 0
				)


## One row: label, the binding as text, and what can be done to it.
func _add_binding_row(
	grid: GridContainer, action: String, index: int, text: String, first: bool
) -> void:
	var label := Label.new()
	label.text = Actions.label_of(action) if first else ""
	label.custom_minimum_size = Vector2(300.0, 0.0)
	label.modulate = Color(1.0, 1.0, 1.0, 0.7) if first else Color(1.0, 1.0, 1.0, 0.3)
	grid.add_child(label)

	var field := LineEdit.new()
	field.name = "Binding%d" % index
	field.text = text
	field.placeholder_text = "press Detect, or type a binding"
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.tooltip_text = (
		"One binding — type it, or press Detect and use the control you want.\n"
		+ "W, Alt+C, Mouse:Left, Joy:<device>/Button:A, Joy:<device>/Axis:LEFT_X"
	)
	field.text_changed.connect(func(_t: String) -> void: _stage_rows(action))
	grid.add_child(field)
	_binding_rows.append([action, index, field])

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	grid.add_child(buttons)

	var detect := Button.new()
	detect.name = "Detect"
	detect.text = "Detect"
	detect.tooltip_text = "Listen for the control to bind: a key, a button, or a gamepad axis."
	detect.pressed.connect(func() -> void: _start_detect(action, index))
	buttons.add_child(detect)

	if first:
		var add := Button.new()
		add.name = "Add"
		add.text = "Add"
		add.tooltip_text = "Another binding for this action."
		add.pressed.connect(func() -> void: _add_binding(action))
		buttons.add_child(add)

	var remove := Button.new()
	remove.name = "Remove"
	remove.text = "Remove"
	remove.pressed.connect(func() -> void: _remove_binding(action, index))
	buttons.add_child(remove)


## What an action currently holds: staged if edited, else the store's, else the registry's.
func _row_texts(action: String) -> Array:
	return _bindings.of(action)


## One row's binding, or `""` for a row that is waiting to be detected into.
## One row's field control, by action and index.
func _row_field(action: String, index: int) -> LineEdit:
	for entry in _binding_rows:
		if String(entry[0]) == action and int(entry[1]) == index:
			return entry[2]
	return null


func _binding_text_of(action: String, index: int) -> String:
	var texts := _row_texts(action)
	return "" if index >= texts.size() else String(texts[index])


## Stage every row of one action from its fields. **A half-typed binding is coloured and stages nothing**,
## so a typo cannot reach the file.
func _stage_rows(action: String) -> void:
	if _updating:
		return
	var texts: Array = []
	var fields: Array = []
	for entry in _binding_rows:
		if String(entry[0]) != action:
			continue
		var field: LineEdit = entry[2]
		fields.append(field)
		var text := field.text.strip_edges()
		if not text.is_empty():
			texts.append(text)

	for text in texts:
		if not Binding.is_valid(String(text)):
			for field in fields:
				field.modulate = INVALID_COLOR
			return
	for field in fields:
		field.modulate = IDLE_COLOR
	if not _bindings.stage(action, texts):
		for field in fields:
			field.modulate = INVALID_COLOR


## Rebuild the rows now if something asked for it. Called every frame by [method _process], and by a test
## that cannot wait for the frame — **a row control cannot free itself from inside its own signal**, so the
## rebuild never runs there.
func flush_rows() -> void:
	if not _rows_dirty:
		return
	Debug.say("bindings[%d]: flushing rows (extras %s)" % [get_instance_id(), str(_extra_rows)])
	_rows_dirty = false
	_rebuild_binding_rows()
	if not _focus_row.is_empty():
		var field := _row_field(String(_focus_row[0]), int(_focus_row[1]))
		_focus_row = []
		if field != null:
			field.grab_focus()


func _add_binding(action: String) -> void:
	# **The flag first**: if staging throws, the row must still be rebuilt.
	_rows_dirty = true
	Debug.say("bindings[%d]: Add on %s, rows before %d" % [
		get_instance_id(), action, _binding_rows.size()
	])
	_stage_rows(action)
	Debug.say("bindings[%d]: staged after Add: %s" % [get_instance_id(), str(_bindings.of(action))])
	var opened := int(_extra_rows.get(action, 0)) + 1
	_extra_rows[action] = opened
	_focus_row = [action, _row_texts(action).size() + opened - 1]
	_rows_dirty = true


func _remove_binding(action: String, index: int) -> void:
	_stage_rows(action)
	var texts := _row_texts(action)
	var extras := int(_extra_rows.get(action, 0))
	if index >= texts.size() and extras > 0:
		# A row this screen opened and nothing was detected into: close it, store nothing.
		_extra_rows[action] = extras - 1
		_rows_dirty = true
		return
	if index < texts.size():
		texts.remove_at(index)
		_extra_rows[action] = 0
		_bindings.stage(action, texts)
	_rows_dirty = true


## **Listen for the control to bind.** Nothing is committed until it is confirmed, so a stick nudged while
## the dialog is open costs one more Detect rather than a lost binding.
func _start_detect(action: String, index: int) -> void:
	_detect = {"action": action, "index": index}
	_detected = ""
	_detect_previous.clear()
	for device in Devices.connected():
		_detect_previous[int(device)] = _axis_readings(int(device))
	_ask_detect(
		"Detect a binding for %s" % Actions.label_of(action),
		(
			"Press a key or a gamepad button, move one axis of a gamepad, or click inside the square "
			+ "below.\n\nThe device is taken away from the game and its menus while this is open."
		),
		["Cancel"]
	)


## Ask, and **put the mouse's square back**: the dialog rebuilds its content on every ask, so the region
## that takes a click has to be added after each one.
func _ask_detect(title: String, message: String, buttons: Array) -> void:
	_dialog.ask(title, message, buttons)
	_dialog.hint.text = "listening…"

	# **Only inside this square is a click a binding.** Everywhere else the mouse belongs to the dialog —
	# otherwise the click that presses *Bind* is caught as the control being bound, and there is no way to
	# press the button at all.
	var square := Panel.new()
	square.name = "Capture"
	square.custom_minimum_size = Vector2(280.0, 88.0)
	square.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	square.mouse_filter = Control.MOUSE_FILTER_STOP
	square.gui_input.connect(_on_capture_input)
	_dialog.content.add_child(square)

	var caption := Label.new()
	caption.text = "click here to bind a mouse button"
	caption.modulate = Color(1.0, 1.0, 1.0, 0.6)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	square.add_child(caption)


## A click inside the square is **deferred to the next frame**: catching it rebuilds the dialog, and the
## square cannot be freed while it is the control emitting its own `gui_input` — the same trap as a button
## that frees its own row.
var _pending_capture: InputEvent = null


## A click inside the square. **Mouse events are not intercepted anywhere else** — `main.gd` forwards only
## keys and pad buttons while detecting — so the dialog's own buttons still work.
func _on_capture_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_pending_capture = event


## Take the pending click now. Called every frame, and by a test that cannot wait for one.
func flush_capture() -> void:
	if _pending_capture == null:
		return
	var event := _pending_capture
	_pending_capture = null
	feed_capture(event)


## Whether a detection is in progress: `main.gd` forwards events here and marks them handled while it is.
func is_detecting() -> bool:
	return not _detect.is_empty()


## The event half: keys, mouse buttons and pad buttons all arrive as events.
func feed_capture(event: InputEvent) -> void:
	if _detect.is_empty() or not event.is_pressed():
		return
	if event is InputEventKey and (event as InputEventKey).echo:
		return
	var text := Binding.from_event(event)
	if not text.is_empty():
		_on_detected(text)


## The axis half: **the biggest change since the last look, outside that axis's own deadband**, and only
## while no button is pressed — a player pressing to bind means a button, and a stick nudged by the same
## hand should not steal it.
func _poll_detection() -> void:
	if _detect.is_empty() or _dialog == null or not _dialog.visible:
		return
	if _any_button_down():
		return
	for device in Devices.connected():
		var index := int(device)
		var previous: Dictionary = _detect_previous.get(index, {})
		if previous.is_empty():
			_detect_previous[index] = _axis_readings(index)
			continue
		var moved: Array = Devices.most_moved(
			index, previous, Callable(self, "_detect_profile").bind(index)
		)
		_detect_previous[index] = _axis_readings(index)
		if int(moved[0]) >= 0:
			_on_detected(
				"%s%s/Axis:%s" % [
					Binding.JOYPAD_PREFIX, Devices.name_of(index), Devices.AXIS_NAMES[int(moved[0])]
				]
			)
			return


func _detect_profile(axis: String, device: int) -> SpacesimAxisProfile:
	return _bindings.axis_profile(Devices.name_of(device), axis)


static func _axis_readings(device: int) -> Dictionary:
	var readings := {}
	for index in Devices.AXIS_NAMES.size():
		readings[Devices.AXIS_NAMES[index]] = Devices.axis(device, index)
	return readings


static func _any_button_down() -> bool:
	for device in Devices.connected():
		if not Devices.pressed(int(device)).is_empty():
			return true
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)


## A control was caught. **Say what it is and ask**, because confirming is the difference between detecting
## a binding and losing one to a stray nudge — and a control already bound elsewhere is a warning, never a
## silent override.
func _on_detected(text: String) -> void:
	if _detect.is_empty():
		return
	_detected = text
	var action := String(_detect["action"])
	var conflicts := _conflicts_with(text, action)
	if conflicts.is_empty():
		_ask_detect(
			"Detected",
			"%s\n\nBind it to %s?" % [text, Actions.label_of(action)],
			["Bind", "Detect again", "Cancel"]
		)
		return

	var names := PackedStringArray()
	for entry in conflicts:
		names.append(Actions.label_of(String(entry[0])))
	_ask_detect(
		"Already bound",
		(
			"%s is already bound to %s.\n\n"
			+ "Bind it to both, take it away from %s, or leave things as they are."
		) % [text, ", ".join(names), ", ".join(names)],
		["Bind to both", "Take it from %s" % ", ".join(names), "Detect again", "Cancel"]
	)


## Every action, other than the one being bound, that already holds this exact binding.
func _conflicts_with(text: String, except_action: String) -> Array:
	var found: Array = []
	for id in Actions.ids():
		if String(id) == except_action:
			continue
		for other in _bindings.of(String(id)):
			if String(other) == text:
				found.append([String(id), text])
	return found


## Commit the detection into its row, having been told what to do about a conflict.
func _apply_detected(remove_from: bool) -> void:
	Debug.say("bindings: apply_detected(%s) detect=%s detected='%s'" % [remove_from, str(_detect), _detected])
	if _detect.is_empty() or _detected.is_empty():
		Debug.say("bindings: nothing to apply, bail")
		return
	var action := String(_detect["action"])
	var index := int(_detect["index"])

	if remove_from:
		for entry in _conflicts_with(_detected, action):
			var victim := String(entry[0])
			var kept: Array = []
			for other in _bindings.of(victim):
				if String(other) != _detected:
					kept.append(String(other))
			_bindings.stage(victim, kept)

	var texts := _row_texts(action).duplicate()
	while texts.size() <= index:
		texts.append("")
	texts[index] = _detected
	var staged := _bindings.stage(action, texts)
	Debug.say("bindings: staged %s -> %s (%s)" % [action, str(texts), staged])
	_extra_rows[action] = 0
	_finish_detect()


func _finish_detect() -> void:
	_detect = {}
	_detected = ""
	_detect_previous.clear()
	if _dialog != null:
		_dialog.visible = false
	_rows_dirty = true
	_refresh_reason = "detect finished"
	_refresh()


## The detection's answers: **confirm, re-detect, both, or take it away** — and Cancel keeps everything as
## it was.
func _handle_detect_answer(answer: String) -> void:
	Debug.say("bindings: dialog answer '%s'" % answer)
	if answer.begins_with("Cancel"):
		_finish_detect()
	elif answer.begins_with("Detect again"):
		_start_detect(String(_detect["action"]), int(_detect["index"]))
	elif answer.begins_with("Take it from"):
		_apply_detected(true)
	else:
		_apply_detected(false)


## Apply is **two** edits now, and it only goes idle when both have committed. A file that cannot be
## written leaves the button amber, which is the one signal the player has.
func _on_apply() -> void:
	_refresh_reason = "Apply pressed"
	_edit.apply()
	if _bindings.apply() < 0:
		push_warning("settings: the bindings could not be written")
	_refresh()


func _on_close() -> void:
	closed.emit()


## Called just before the screen is shown. **Rebuilt from what stands**, because the bindings are a file
## that can change while this screen is not looking at it — a hand edit, or a changed `bindings.cfg`.
func opened() -> void:
	_refresh_reason = "opened"
	Debug.say("bindings[%d]: opened" % get_instance_id())
	_rows_dirty = true
	_refresh()


## Leaving without applying throws the staged edits away — which is what the amber Close button
## warns about. It holds whichever route the screen is left by, not only the Close button.
func dismissed() -> void:
	_refresh_reason = "dismissed"
	Debug.say("bindings[%d]: dismissed" % get_instance_id())
	_edit.discard()
	if _bindings != null:
		_bindings.discard()
	# **The fields come back to what stands**, or a discarded edit would still be on screen the next time
	# the screen is opened — the file is right and the screen would lie about it.
	_refresh()
	# **A screen that is closed is not configuring anything.** The flag is read live by `main.gd`, so
	# leaving it set would keep a device deaf to the game with nothing on screen to explain why.
	_set_configuring("")


## Pull every control back to what the staging area holds — which is how a Reset shows up, and how
## a discarded edit disappears.
## Why the refresh ran, for the debug line. Set by whatever is about to refresh.
var _refresh_reason := "?"


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

	for entry in _binding_rows:
		var field: LineEdit = entry[2]
		if not field.has_focus():
			field.text = _binding_text_of(String(entry[0]), int(entry[1]))
			field.modulate = IDLE_COLOR

	# The axis fields come back to what stands, which is how a discarded edit disappears — but **not
	# while one of them is being typed into**, or the text would be rewritten under the cursor.
	for entry in _axis_rows:
		var profile: SpacesimAxisProfile = _profile_of(int(entry[0]), int(entry[1]))
		var field: LineEdit = entry[6]
		if not field.has_focus():
			field.text = "%.3f" % profile.deadband
			field.modulate = IDLE_COLOR
		(entry[4] as Label).text = "centre %+.3f" % profile.centre
		(entry[5] as Label).text = _travel_text(profile)

	var pending := _edit.has_changes() or _bindings.has_changes()
	Debug.say("bindings[%d]: refresh(%s) has_changes=%s rows=%d" % [
		get_instance_id(), _refresh_reason, pending, _binding_rows.size()
	])
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
