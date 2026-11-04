extends RefCounted
## Bindings, and the staged edits behind the settings screen.

const Settings := preload("res://addons/spacesim/settings/settings.gd")
const Edit := preload("res://addons/spacesim/settings/settings_edit.gd")
const Bindings := preload("res://addons/spacesim/settings/bindings.gd")
const SettingsPanel := preload("res://addons/spacesim/settings/settings_panel.gd")

const Fixture := preload("res://tests/settings_fixture.gd")

var _fixture := Fixture.new()


func run(h, root: Node) -> void:
	print("  bindings and the settings screen")
	Fixture.clean()
	_test_binding_text(h)
	_test_binding_matching(h)
	_test_registry_is_sound(h)
	_test_edits_are_staged_not_applied(h)
	_test_reset_and_discard(h)
	_test_bad_values_are_not_staged(h)
	_test_every_setting_gets_a_control(h, root)
	_test_the_tabs_group_the_registry(h, root)
	Fixture.clean()
	_fixture.release()


func _test_binding_text(h) -> void:
	h.check(Bindings.is_valid("W"), "a plain key is a binding")
	h.check(Bindings.is_valid("Alt+C"), "so is a modified one")
	h.check(Bindings.is_valid("BracketLeft"), "and a key named for its position")
	h.check(not Bindings.is_valid("Nonsense"), "a word that is not a key is not")
	h.check(not Bindings.is_valid(""), "and neither is nothing")

	# Formatting normalises the modifier order, so two spellings of one binding agree.
	h.check(
		Bindings.format(Bindings.parse("Alt+Shift+BracketLeft")) == "Shift+Alt+BracketLeft",
		"a binding survives a round trip, order normalised"
	)
	h.check(Bindings.keycode_of("W") == KEY_W, "and yields the key it names")


func _test_binding_matching(h) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_C
	event.alt_pressed = true
	event.pressed = true
	h.check(Bindings.matches(event, "Alt+C"), "the event matches its own binding")
	h.check(not Bindings.matches(event, "C"), "but not the bare key: modifiers must match exactly")
	h.check(not Bindings.matches(event, "Ctrl+C"), "nor a different modifier")

	event.pressed = false
	h.check(not Bindings.matches(event, "Alt+C"), "a release is not a press")
	event.pressed = true
	event.echo = true
	h.check(not Bindings.matches(event, "Alt+C"), "nor is a key repeat")
	event.echo = false
	h.check(Bindings.from_event(event) == "Alt+C", "and an event reads back as its binding")


func _test_registry_is_sound(h) -> void:
	# A row naming a validator that does not exist would silently skip its check, so the names are
	# checked against the list the code knows.
	var unknown: Array[String] = []
	var bad_defaults: Array[String] = []
	var undotted: Array[String] = []
	for key in Settings.declared_keys():
		var row: Dictionary = Settings.REGISTRY[key]
		if not String(key).contains("."):
			undotted.append(key)
		if row.has("validator") and not Settings.KNOWN_VALIDATORS.has(row["validator"]):
			unknown.append(key)
		if row.get("validator", "") == "key_binding" and not Bindings.is_valid(String(row["default"])):
			bad_defaults.append(key)
	# A row offering choices that does not include its own default would open showing nothing, and a
	# row that offers a list but names one we cannot build would fall back to a text box silently.
	var bad_choices: Array[String] = []
	for key in Settings.declared_keys():
		var row: Dictionary = Settings.REGISTRY[key]
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
	h.check(bad_defaults.is_empty(), "every binding default is a valid binding%s" % Fixture.detail(bad_defaults))
	h.check(undotted.is_empty(), "every key is sectioned%s" % Fixture.detail(undotted))
	h.check(
		Settings.is_acceptable("bindings.throttle_up", "Alt+W"),
		"a valid binding is acceptable"
	)
	h.check(
		not Settings.is_acceptable("bindings.throttle_up", "Nonsense"),
		"and an unparseable one is not"
	)


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
		titles == ["Bindings", "Display", "Graphics", "Rest"],
		"the tabs are Bindings, Display, Graphics and Rest, in that order (%s)" % str(titles)
	)

	# What each tab holds, read off the screen: the display tab is the window, the graphics tab is
	# what is drawn, and the bindings are the keys.
	var on_display: Array = []
	var on_graphics: Array = []
	var on_rest: Array = []
	var on_bindings: Array = []
	for index in tabs.get_tab_count():
		var names: Array = []
		for key in Edit.editable_keys():
			if not _rows_label(tabs, index, String(key)):
				continue
			names.append(String(key))
		match titles[index]:
			"Bindings":
				on_bindings = names
			"Display":
				on_display = names
			"Graphics":
				on_graphics = names
			"Rest":
				on_rest = names

	h.check(on_display.size() == 6, "Display holds the six window settings (%d)" % on_display.size())
	h.check(
		on_display.all(func(key: String) -> bool: return key.begins_with("video.")),
		"and they are the video ones (%s)" % str(on_display)
	)
	h.check(on_graphics.size() == 6, "Graphics holds the six drawing switches (%d)" % on_graphics.size())
	h.check(
		on_graphics.all(func(key: String) -> bool: return key.begins_with("render.")),
		"and they are the render ones (%s)" % str(on_graphics)
	)
	h.check(
		on_bindings.size() == 17,
		"Bindings holds the sixteen keys and the mouse (%d)" % on_bindings.size()
	)
	# What nobody has filed yet is on `rest`, and the total below proves nothing fell between tabs.
	h.check(
		on_rest.size() > 0 and on_rest.has("camera.fov") and not on_rest.has("video.mode"),
		"Rest holds the settings that have no tab yet, and no copy of a filed one (%d)"
			% on_rest.size()
	)

	var total := on_display.size() + on_graphics.size() + on_bindings.size() + on_rest.size()
	h.check(
		total == Edit.editable_keys().size(),
		"and every setting is on exactly one tab (%d of %d)" % [total, Edit.editable_keys().size()]
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
	h.check(not edit.stage("bindings.throttle_up", "Nonsense"), "an unparseable binding is not staged")
	h.check(not edit.has_changes(), "so there is nothing to apply")
