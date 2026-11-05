extends RefCounted
## Bindings, and the staged edits behind the settings screen.

const Settings := preload("res://addons/spacesim/settings/settings.gd")
const Edit := preload("res://addons/spacesim/settings/settings_edit.gd")
const Binding := preload("res://addons/spacesim/input/binding.gd")
const Actions := preload("res://addons/spacesim/input/actions.gd")
const Ui := preload("res://tests/ui_fixture.gd")
const Devices := preload("res://addons/spacesim/input/devices.gd")
const AxisProfile := preload("res://addons/spacesim/input/axis_profile.gd")
const AxisBar := preload("res://addons/spacesim/ui/axis_bar.gd")
const Store := preload("res://addons/spacesim/input/bindings_store.gd")
const Controls := preload("res://addons/spacesim/input/controls.gd")
const SettingsPanel := preload("res://addons/spacesim/settings/settings_panel.gd")

const Fixture := preload("res://tests/settings_fixture.gd")

var _fixture := Fixture.new()


func run(h, root: Node) -> void:
	print("  bindings and the settings screen")
	Fixture.clean()
	_test_registry_is_sound(h)
	_test_edits_are_staged_not_applied(h)
	_test_reset_and_discard(h)
	_test_bad_values_are_not_staged(h)
	_test_every_setting_gets_a_control(h, root)
	_test_the_tabs_group_the_registry(h, root)
	_test_the_bindings_tab(h, root)
	_test_the_devices_tab(h, root)
	_test_the_flight_tab(h, root)
	Fixture.clean()
	_fixture.release()


## **A registry row that cannot be what it says it is** would fail silently somewhere far away, so the
## shape is checked here: a dotted key, a validator the code knows, choices that include the row's own
## default.
func _test_registry_is_sound(h) -> void:
	var unknown: Array[String] = []
	var undotted: Array[String] = []
	var bad_choices: Array[String] = []
	for key in Settings.declared_keys():
		var row: Dictionary = Settings.REGISTRY[key]
		if not String(key).contains("."):
			undotted.append(key)
		if row.has("validator") and not Settings.KNOWN_VALIDATORS.has(row["validator"]):
			unknown.append(key)
		# A row offering choices that does not include its own default would open showing nothing, and a
		# row that offers a list but names one we cannot build would fall back to a text box silently.
		var listed: Variant = row.get("choices", null)
		if listed is Array and not listed.has(row["default"]):
			bad_choices.append(key)
		if listed is String and listed != "screens":
			bad_choices.append(key)
	h.check(
		bad_choices.is_empty(),
		"every row that offers choices offers its own default%s" % Fixture.detail(bad_choices)
	)
	h.check(unknown.is_empty(), "every declared validator exists%s" % Fixture.detail(unknown))
	h.check(undotted.is_empty(), "every key is sectioned%s" % Fixture.detail(undotted))


func _test_edits_are_staged_not_applied(h) -> void:
	var settings := _fixture.open()
	var edit = Edit.new(settings)

	h.check(not edit.has_changes(), "nothing to apply to begin with")

	edit.stage("camera.fov", 90.0)
	h.check(edit.has_changes(), "an edit gives something to apply")
	h.check(edit.value("camera.fov") == 90.0, "the screen shows the edited value")
	h.check(
		settings.get_value("camera.fov") != 90.0,
		"and the live setting is untouched until it is applied"
	)

	# Fiddling a control back to where it started leaves nothing to apply.
	edit.stage("camera.fov", 70.0)
	h.check(not edit.has_changes(), "putting an edit back the way it was leaves nothing to apply")

	edit.stage("camera.fov", 90.0)
	var applied := edit.apply()
	h.check(applied == 1, "applying reports what it changed")
	h.check(settings.get_value("camera.fov") == 90.0, "and the live setting now has the value")
	h.check(not edit.has_changes(), "with nothing left to apply")
	h.check(
		FileAccess.get_file_as_string(Fixture.TEST_PATH).contains("fov=90.0"), "and the file has it"
	)


func _test_reset_and_discard(h) -> void:
	var settings := _fixture.open()
	var edit = Edit.new(settings)

	settings.set_value("camera.fov", 95.0)
	settings.save(true)
	edit.reset_to_default("camera.fov")
	h.check(edit.value("camera.fov") == Settings.default_of("camera.fov"), "a reset stages the default")
	h.check(settings.get_value("camera.fov") == 95.0, "not applied until it is applied")
	edit.apply()
	h.check(
		settings.get_value("camera.fov") == Settings.default_of("camera.fov"),
		"and applying takes it back to the default"
	)
	h.check(
		not FileAccess.get_file_as_string(Fixture.TEST_PATH).contains("fov"),
		"which also removes it from the file"
	)

	edit.stage("camera.fov", 100.0)
	edit.discard()
	h.check(not edit.has_changes(), "closing discards what was staged")
	h.check(settings.get_value("camera.fov") != 100.0, "and the live setting never saw it")


## **A registry type the panel has no editor for leaves the row with no control at all**, and
## `_refresh` then indexes the first one — so a new setting type has to arrive with an editor, and this
## is what says so. A color did, the first time one was added.
func _test_every_setting_gets_a_control(h, root: Node) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var panel := SettingsPanel.new()
	panel.configure(_fixture.open(), _fixture.bindings())
	layer.add_child(panel)

	var fields: Dictionary = panel.get("_fields")
	var bare: Array[String] = []
	for key in Edit.editable_keys():
		var editors: Array = fields.get(key, [])
		if editors.is_empty():
			bare.append(String(key))
	h.check(bare.is_empty(), "every declared setting gets a control%s" % Fixture.detail(bare))

	layer.free()


## **Every setting is on a tab, and the tabs are the ones the registry names.** The failure this
## guards is a setting silently not appearing: a row with no `tab` files itself under `rest`, which is
## the point of `rest` existing, but a row naming a tab nobody builds would land nowhere.
func _test_the_tabs_group_the_registry(h, root: Node) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var panel := SettingsPanel.new()
	panel.configure(_fixture.open(), _fixture.bindings())
	layer.add_child(panel)

	var found := panel.find_children("*", "TabContainer", true, false)
	h.check(found.size() == 1, "the screen has one tab container (%d)" % found.size())
	if found.is_empty():
		layer.free()
		return
	var tabs: TabContainer = found[0]
	var titles: Array = []
	for index in tabs.get_tab_count():
		titles.append(tabs.get_tab_title(index))
	h.check(
		titles == ["Display", "HUD", "Flight", "Bindings", "Devices", "Troubleshooting"],
		"the tabs are Display, HUD, Flight, Bindings, Devices and Troubleshooting (%s)" % str(titles)
	)

	# What each tab holds, read off the screen: the display tab is the window, the bindings are the
	# keys, the troubleshooting tab is what you reach for when the picture is wrong, and the HUD tab is
	# what the player looks through: the camera and the markers. **Nothing is left in `rest`, so `rest`
	# is not built** — a tab with nothing filed into it is a promise of settings that are elsewhere.
	var pages := {}
	for index in tabs.get_tab_count():
		var names: Array = []
		for key in Edit.editable_keys():
			if _rows_label(tabs, index, String(key)):
				names.append(String(key))
		pages[titles[index]] = names

	var display: Array = pages["Display"]
	var bindings: Array = pages["Bindings"]
	var trouble: Array = pages["Troubleshooting"]
	var hud: Array = pages["HUD"]

	h.check(display.size() == 6, "Display holds the six window settings (%d)" % display.size())
	h.check(
		display.all(func(key: String) -> bool: return key.begins_with("video.")),
		"and they are the video ones (%s)" % str(display)
	)
	h.check(
		bindings.size() == 1,
		"Bindings holds only the mouse's sensitivity: the sixteen keys left for their own store (%d)"
			% bindings.size()
	)
	h.check(
		trouble.has("render.mode") and trouble.has("lod.error_budget") and trouble.has("sky.star_gain"),
		"Troubleshooting holds the drawing switches, the LOD knobs and the sky's calibration (%d)"
			% trouble.size()
	)
	h.check(
		trouble.size() == 15,
		"and nothing else has been filed there by accident (%d)" % trouble.size()
	)
	h.check(
		hud.size() == 13,
		"HUD holds the camera, the three HUD switches and the markers (%d)" % hud.size()
	)
	var stray := 0
	for key in hud:
		if not (
			String(key).begins_with("camera.")
			or String(key).begins_with("markers.")
			or String(key).begins_with("hud.")
		):
			stray += 1
	h.check(stray == 0, "and nothing else (%d stray)" % stray)
	h.check(not pages.has("Rest"), "with every setting filed, no empty Rest tab is built")

	var total := display.size() + bindings.size() + trouble.size() + hud.size()
	h.check(
		total == Edit.editable_keys().size(),
		"and every setting is on exactly one tab (%d of %d)" % [total, Edit.editable_keys().size()]
	)
	h.check(
		Edit.editable_keys().size() == 35,
		"there are thirty-five settings, the sixteen bindings having left (%d)"
			% Edit.editable_keys().size()
	)

	layer.free()


## Whether the page on this tab shows a row labelled with this key.
static func _rows_label(tabs: TabContainer, index: int, key: String) -> bool:
	var page: Control = tabs.get_child(index)
	if page == null:
		return false
	for child in page.find_children("*", "Label", true, false):
		if (child as Label).text == key:
			return true
	return false


## **The actions are not settings**, so what this tab proves is different: every action appears, a row is
## a binding, Add opens one, Remove deletes one, and a detection is confirmed before it lands.
func _test_the_bindings_tab(h, root: Node) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var store := _fixture.bindings()
	var panel := SettingsPanel.new()
	panel.configure(_fixture.open(), store)
	layer.add_child(panel)

	var missing: Array[String] = []
	for id in Actions.ids():
		if not Ui.shows(panel, Actions.label_of(id)):
			missing.append(String(id))
	h.check(missing.is_empty(), "every action is on the bindings tab%s" % Fixture.detail(missing))

	# **The rows live on the Bindings page and nowhere else.** Every tab used to get a bindings vbox, so
	# `_bindings_vbox` pointed at the last tab's and every rebuild drew there — invisible to a player on
	# the Bindings tab, which looked exactly like the buttons doing nothing.
	var bindings_vbox: VBoxContainer = panel.get("_bindings_vbox")
	h.check(bindings_vbox != null, "the screen has somewhere to put the rows")
	if bindings_vbox != null:
		h.check(bindings_vbox.is_inside_tree(), "and it is in the tree")
		# vbox → the tab's column → the tab's scroll page → the TabContainer
		var page: Node = bindings_vbox.get_parent().get_parent()
		h.check(
			page != null and page.get_parent() is TabContainer and String(page.name) == "Bindings",
			"on the Bindings page, not another tab (%s)" % (page.name if page != null else "none")
		)

	var field: LineEdit = _row_field(panel, "bodies_toggle", 0)
	h.check(field != null and field.text == "P", "showing the binding that stands")

	# --- a typo is coloured and goes nowhere
	field.text = "Nonsense"
	field.text_changed.emit("Nonsense")
	h.check(field.modulate == panel.INVALID_COLOR, "a binding that does not parse is coloured")
	h.check(not store.has_changes(), "and is not staged")

	# --- a real edit stages, and Apply writes it
	field.text = "W"
	field.text_changed.emit("W")
	h.check(field.modulate == panel.IDLE_COLOR, "a valid one is not coloured")
	h.check(store.has_changes(), "and is staged")
	panel._apply_button.pressed.emit()
	h.check(_fixture.bindings().of("bodies_toggle") == ["W"], "applying writes the file")

	# --- **Add opens a row; Remove on the last one clears the binding rather than the row**
	# The panel rebuilds its rows from `_process`; a test asks for it directly.
	var before := _rows_named(panel, "bodies_toggle").size()
	var add: Button = _row_button(panel, "bodies_toggle", 0, "Add")
	h.check(add != null, "the first row can add another")
	add.pressed.emit()
	panel.flush_rows()
	h.check(
		_rows_named(panel, "bodies_toggle").size() == before + 1,
		"which opens one more row for the same action (%d)" % _rows_named(panel, "bodies_toggle").size()
	)
	var extra_field: LineEdit = _row_field(panel, "bodies_toggle", before)
	h.check(extra_field != null and extra_field.text.is_empty(), "an empty row to detect into")
	panel._apply_button.pressed.emit()
	h.check(_fixture.bindings().of("bodies_toggle") == ["W"], "and applying stores nothing for it")

	var remove: Button = _row_button(panel, "bodies_toggle", 0, "Remove")
	h.check(remove != null, "and remove a binding")
	remove.pressed.emit()
	panel.flush_rows()
	# **Staged, not written**: the file is untouched until Apply.
	h.check(store.of("bodies_toggle").is_empty(), "which clears what that row held")
	h.check(not _rows_named(panel, "bodies_toggle").is_empty(), "leaving the row, not deleting it")

	# --- **A discarded edit is not left on screen.** The file is right either way; the fields must agree.
	field = _row_field(panel, "bodies_toggle", 0)
	field.text = "G"
	field.text_changed.emit("G")
	h.check(store.has_changes(), "an edit is staged")
	panel.dismissed()
	panel.opened()
	panel.flush_rows()
	field = _row_field(panel, "bodies_toggle", 0)
	h.check(
		not store.has_changes() and field.text == Store.SEPARATOR.join(PackedStringArray(
			_fixture.bindings().of("bodies_toggle")
		)),
		"closing discards it, and opening again shows what stands (%s)" % field.text
	)

	# --- **Detect: listen, catch, confirm**
	panel._apply_button.pressed.emit()
	var press := InputEventKey.new()
	press.physical_keycode = KEY_Y
	press.pressed = true
	panel._start_detect("cycle_target", 0)
	h.check(panel.is_detecting(), "Detect starts listening")
	panel.feed_capture(press)
	h.check(not panel._detected.is_empty(), "a pressed key is caught (%s)" % panel._detected)
	h.check(panel._dialog.visible, "and shown before it is committed")
	h.check(not store.has_changes(), "with nothing staged yet")
	# **The mouse has a square of its own**: a click inside it is a binding, and clicks anywhere else stay
	# the dialog's, which is what lets the Bind button be pressed at all.
	var square := panel._dialog.content.get_node_or_null("Capture")
	h.check(square != null, "the detection dialog draws somewhere to click")
	if square != null:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_MIDDLE
		click.pressed = true
		square.gui_input.emit(click)
		panel.flush_capture()
		h.check(
			panel._detected == "Mouse:Middle",
			"and a click inside it is the binding that was caught (%s)" % panel._detected
		)
		# put the key back for the conflict test below
		panel.feed_capture(press)
	var caught: String = panel._detected
	panel._dialog.answered.emit("Bind")
	h.check(not panel.is_detecting(), "confirming ends the detection")
	h.check(store.of("cycle_target") == [caught], "and stages the control that was caught")

	# **A control already bound elsewhere is a warning, not an override**
	panel._start_detect("bodies_toggle", 0)
	panel.feed_capture(press)
	h.check(
		panel._dialog.title_label.text == "Already bound",
		"a conflict says so (%s)" % panel._dialog.title_label.text
	)
	var answers: Array = []
	for button in panel._dialog.actions.get_children():
		answers.append(String(button.text))
	h.check(
		answers.has("Bind to both") and answers.has("Detect again"),
		"offering the choices (%s)" % str(answers)
	)
	var take := ""
	for answer in answers:
		if String(answer).begins_with("Take it from"):
			take = String(answer)
	h.check(not take.is_empty(), "including taking it from where it was")
	panel._dialog.answered.emit(take)
	h.check(
		store.of("cycle_target").is_empty() and store.of("bodies_toggle") == [caught],
		"which moves the binding rather than copying it"
	)

	layer.free()


## **The flight tab: every degree of freedom, with the lines its kind of source needs.**
func _test_the_flight_tab(h, root: Node) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var store := _fixture.bindings()
	var panel := SettingsPanel.new()
	panel.configure(_fixture.open(), store)
	layer.add_child(panel)

	var missing: Array[String] = []
	for dof in Controls.DOFS:
		if not Ui.shows(panel, String(Controls.REGISTRY[dof]["label"])):
			missing.append(String(dof))
	h.check(missing.is_empty(), "every degree of freedom is on the tab%s" % Fixture.detail(missing))

	# **The strafes say the ship cannot move that way**, rather than offering a control that does nothing.
	h.check(
		Ui.shows(panel, "the ship cannot move this way yet"),
		"and the ones the ship cannot do say so"
	)

	# The shipped assignments are what the screen shows: brackets for roll, minus and shifted-equal for
	# throttle, the pointer for pitch and yaw.
	var roll := _flight_control(panel, "roll", "keyboard_decrease")
	h.check(roll != null and (roll as LineEdit).text == "BracketLeft", "roll's decrease slot shows the bracket")
	var throttle := _flight_control(panel, "throttle", "keyboard_increase")
	h.check(
		throttle != null and (throttle as LineEdit).text == "Shift+Equal",
		"and throttle's increase slot shows the shifted equal"
	)
	var yaw := _flight_control(panel, "yaw", "mouse_movement")
	h.check(
		yaw != null and String((yaw as OptionButton).get_item_metadata((yaw as OptionButton).selected))
			== "glide",
		"and yaw's pointer is gliding"
	)

	# **Typing a line stages it, and a typo colours it and stages nothing.**
	var field: LineEdit = _flight_control(panel, "roll", "keyboard_decrease")
	field.text = "Z"
	field.text_changed.emit("Z")
	h.check(store.has_changes(), "editing a line stages it (%s)" % str(store.control("roll")))
	field.text = "Nonsense"
	field.text_changed.emit("Nonsense")
	h.check(field.modulate == panel.INVALID_COLOR, "and a line that does not parse is coloured")

	# **Invert is per continuous line**, which is the whole point of it being on that row.
	field.text = "BracketLeft"
	field.text_changed.emit("BracketLeft")
	var invert: CheckBox = _flight_control(panel, "roll", "joystick_invert")
	h.check(invert != null, "the joystick line has an invert")
	invert.button_pressed = true
	invert.toggled.emit(true)
	h.check(
		bool(store.control("roll").get("joystick_invert", false)),
		"and toggling it stages the line"
	)

	layer.free()


## One flight control, by DOF and line name.
static func _flight_control(panel: Node, dof: String, name: String) -> Control:
	for entry in panel.get("_flight_controls"):
		if String(entry[0]) == dof and String(entry[1]) == name:
			return entry[2]
	return null


## One row's field, by action and index.
static func _row_field(panel: Node, action: String, index: int) -> LineEdit:
	for entry in panel.get("_binding_rows"):
		if String(entry[0]) == action and int(entry[1]) == index:
			return entry[2]
	return null


## Every row belonging to one action.
static func _rows_named(panel: Node, action: String) -> Array:
	var found: Array = []
	for entry in panel.get("_binding_rows"):
		if String(entry[0]) == action:
			found.append(entry)
	return found


## The button with this label on one row.
static func _row_button(panel: Node, action: String, index: int, text: String) -> Button:
	var field := _row_field(panel, action, index)
	if field == null:
		return null
	# **A `GridContainer` has no row nodes**: the button cell is simply the child after the field's own,
	# so `field.get_parent()` and a search through it would find the FIRST row's buttons.
	var cell := field.get_parent().get_child(field.get_index() + 1)
	if cell is HBoxContainer:
		for button in cell.get_children():
			if button is Button and String(button.text) == text:
				return button
	return null


## **The devices tab shows what the machine has**, whatever that is — so the count is checked against the
## engine rather than against a number this test would have to guess. Headless detects a gamepad when one
## is attached, which is why this is a real check and not a skipped one.
func _test_the_devices_tab(h, root: Node) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var store := _fixture.bindings()
	var panel := SettingsPanel.new()
	panel.configure(_fixture.open(), store)
	layer.add_child(panel)

	var tabs: TabContainer = panel.find_children("*", "TabContainer", true, false)[0]
	var at := -1
	for index in tabs.get_tab_count():
		if tabs.get_tab_title(index) == "Devices":
			at = index
	h.check(at >= 0, "the screen has a Devices tab")
	if at < 0:
		layer.free()
		return

	var pads := Devices.connected()
	h.check(
		Ui.shows(panel, "No joystick or gamepad") == pads.is_empty(),
		"it says so when nothing is connected, and does not when something is (%d)" % pads.size()
	)

	# Every axis of every device gets its own line, whether or not a pad is attached.
	var rows: Array = panel.get("_axis_rows")
	h.check(
		rows.size() == pads.size() * Devices.AXIS_NAMES.size(),
		"and one line per axis, per device (%d for %d device(s))" % [rows.size(), pads.size()]
	)
	var buttons: Array = panel.get("_button_labels")
	h.check(
		buttons.size() == pads.size() * Devices.MAX_BUTTONS,
		"and every button the engine accepts is laid out, per device (%d for %d device(s))"
			% [buttons.size(), pads.size()]
	)

	# **The readout follows the device**, and it is the *shaped* value: the bar, the number and the
	# profile's centre and band all come from the same place.
	if not pads.is_empty():
		panel._refresh_devices()
		var device := int(pads[0])
		var raw: float = Devices.axis(device, 0)
		var profile: SpacesimAxisProfile = panel._profile_of(device, 0)
		var value_label: Label = rows[0][3]
		h.check(
			value_label.text == "%+.2f" % profile.shape(raw),
			"and each line shows the shaped value of that axis (%s)" % value_label.text
		)
		var bar: AxisBar = rows[0][2]
		h.check(
			is_equal_approx(bar.profile.centre, profile.centre)
			and is_equal_approx(bar.profile.deadband, profile.deadband)
			and is_equal_approx(bar.value, raw),
			"with the bar drawing the profile's deadband and the axis's raw reading"
		)

		# **The numbers live above the bar**: the centre and the travel are shown, never typed; only the
		# deadband has a field.
		var centre_label: Label = rows[0][4]
		var travel_label: Label = rows[0][5]
		var band: LineEdit = rows[0][6]
		h.check(
			centre_label.text.contains("%.3f" % profile.centre)
			and travel_label.text.contains("%.2f" % profile.low)
			and travel_label.text.contains("%.2f" % profile.high),
			"the centre and the travel are shown above the bar (%s · %s)"
				% [centre_label.text, travel_label.text]
		)
		h.check(band.text == "%.3f" % profile.deadband, "and the deadband is a field (%s)" % band.text)
		band.text = "0.250"
		band.text_changed.emit("0.250")
		h.check(store.has_changes(), "typing a deadband stages it")
		h.check(
			is_equal_approx(
				store.axis_profile(Devices.name_of(device), Devices.AXIS_NAMES[0]).deadband, 0.25
			),
			"and it is that axis's profile that changed"
		)

		# **Centred takes the reading**, which is the one number a player cannot type accurately — and then
		# the dot is in the middle of the deadband box, because both are drawn in travel units.
		(rows[0][8] as Button).pressed.emit()
		panel._refresh_devices()
		var box_centre: float = bar.profile.centre
		h.check(
			is_equal_approx(bar.value, box_centre),
			"and the bar puts the dot at the centre of the band (%f vs %f)" % [bar.value, box_centre]
		)
		h.check(
			is_equal_approx(
				store.axis_profile(Devices.name_of(device), Devices.AXIS_NAMES[0]).centre,
				Devices.axis(device, 0)
			),
			"Centred stores what the axis is reading now"
		)
		# **A profile that cannot make sense is refused**, and says so: a centre outside the travel, and a
		# band of 1.0 where nothing could ever be deflected.
		var status: Label = rows[0][9]
		band.text = "1.000"
		band.text_changed.emit("1.000")
		h.check(not status.text.is_empty(), "and so is a band that would swallow everything")
		band.text = "0.900"
		band.text_changed.emit("0.900")
		h.check(
			status.text.is_empty(),
			"while a silly but legal band is allowed, because the bar is the feedback (%s)" % status.text
		)

		# Apply writes the profile, and a second open reads it back.
		band.text = "0.200"
		band.text_changed.emit("0.200")
		panel._apply_button.pressed.emit()
		var saved: SpacesimAxisProfile = _fixture.bindings().axis_profile(
			Devices.name_of(device), Devices.AXIS_NAMES[0]
		)
		h.check(
			is_equal_approx(saved.deadband, 0.2),
			"and Apply writes it to the store (%s)" % saved.to_text()
		)

	# --- **Configure routes one device away from everything else**, and one at a time
	if not pads.is_empty():
		var boxes: Array = panel.get("_configure_boxes")
		h.check(boxes.size() == pads.size(), "each device has a Configure box (%d)" % boxes.size())
		h.check(panel.configuring_device().is_empty(), "and none is on to begin with")
		var first: CheckBox = boxes[0][1]
		first.button_pressed = true
		first.toggled.emit(true)
		h.check(
			panel.configuring_device() == Devices.name_of(int(pads[0])),
			"turning one on names that device (%s)" % panel.configuring_device()
		)
		if boxes.size() >= 2:
			var second: CheckBox = boxes[1][1]
			second.button_pressed = true
			second.toggled.emit(true)
			h.check(
				panel.configuring_device() == Devices.name_of(int(pads[1])),
				"and turning another on moves it over (%s)" % panel.configuring_device()
			)
			h.check(not first.button_pressed, "leaving exactly one on")
		# **A closed screen configures nothing**: main reads this live, so a stale name would leave a
		# device deaf to the game with nothing on screen to explain it.
		panel.dismissed()
		h.check(panel.configuring_device().is_empty(), "and closing the screen clears it")

	layer.free()



## The Reset on one action's row.
static func _button_named(panel: Node, text: String, action: String) -> Button:
	var field: LineEdit = panel.get("_binding_fields").get(action)
	if field == null or field.get_parent() == null:
		return null
	for child in field.get_parent().get_children():
		if child is Button and child.text == text:
			return child
	return null


func _test_bad_values_are_not_staged(h) -> void:
	var settings := _fixture.open()
	var edit = Edit.new(settings)
	h.check(not edit.stage("camera.fov", 10000.0), "an out-of-range edit is not staged")
	h.check(not edit.has_changes(), "so there is nothing to apply")
