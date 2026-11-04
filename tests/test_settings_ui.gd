extends RefCounted
## Bindings, and the staged edits behind the settings screen.

const Settings := preload("res://addons/spacesim/settings/settings.gd")
const Edit := preload("res://addons/spacesim/settings/settings_edit.gd")
const Binding := preload("res://addons/spacesim/input/binding.gd")
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
	panel.configure(_fixture.open())
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
	panel.configure(_fixture.open())
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
		titles == ["Display", "HUD", "Bindings", "Troubleshooting"],
		"the tabs are Display, HUD, Bindings and Troubleshooting, in that order (%s)"
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


func _test_bad_values_are_not_staged(h) -> void:
	var settings := _fixture.open()
	var edit = Edit.new(settings)
	h.check(not edit.stage("camera.fov", 10000.0), "an out-of-range edit is not staged")
	h.check(not edit.has_changes(), "so there is nothing to apply")
