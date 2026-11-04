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
		titles == ["Display", "HUD", "Bindings", "Devices", "Troubleshooting"],
		"the tabs are Display, HUD, Bindings, Devices and Troubleshooting, in that order (%s)"
			% str(titles)
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


## **The actions are not settings**, so what this tab has to prove is different: every action appears,
## the field shows what stands, an edit stages, a typo is coloured and staged nowhere, Apply writes the
## file, and Reset puts the default back.
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

	var fields: Dictionary = panel.get("_binding_fields")
	h.check(fields.size() == Actions.ids().size(), "with one field each (%d)" % fields.size())

	var throttle: LineEdit = fields.get("throttle_up")
	h.check(throttle != null and throttle.text == "Shift+Equal", "showing the binding that stands")

	# --- a typo is coloured and goes nowhere
	throttle.text = "Nonsense"
	throttle.text_changed.emit("Nonsense")
	h.check(throttle.modulate == panel.INVALID_COLOR, "a binding that does not parse is coloured")
	h.check(not store.has_changes(), "and is not staged")

	# --- a real edit stages, and Apply writes it
	throttle.text = "W"
	throttle.text_changed.emit("W")
	h.check(throttle.modulate == panel.IDLE_COLOR, "a valid one is not coloured")
	h.check(store.has_changes(), "and is staged")
	h.check(not panel._apply_button.disabled, "so Apply is available")
	panel._apply_button.pressed.emit()
	h.check(not store.has_changes(), "applying clears the staging")
	var reread := _fixture.bindings()
	h.check(reread.of("throttle_up") == ["W"], "and the file has the new binding")

	# --- several bindings in one field, which is what the comma is for
	throttle.text = "W, Mouse:Left"
	throttle.text_changed.emit("W, Mouse:Left")
	panel._apply_button.pressed.emit()
	var two := _fixture.bindings()
	h.check(two.of("throttle_up") == ["W", "Mouse:Left"], "and a field can hold more than one")

	# --- Reset is staged, and says the default
	var reset := _button_named(panel, "Reset", "throttle_up")
	h.check(reset != null, "the row has a Reset")
	if reset != null:
		reset.pressed.emit()
	h.check(store.of("throttle_up") == Actions.defaults_of("throttle_up"), "which restores the default")
	h.check(store.has_changes(), "as a staged edit, not a silent write")

	layer.free()


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
		buttons.size() == pads.size() * Devices.BUTTON_NAMES.size(),
		"and every button laid out, per device (%d for %d device(s))"
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
