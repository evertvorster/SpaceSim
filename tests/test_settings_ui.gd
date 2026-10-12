extends RefCounted
## Bindings, and the staged edits behind the settings screen.

const Settings := preload("res://addons/spacesim/settings/settings.gd")
const Edit := preload("res://addons/spacesim/settings/settings_edit.gd")
const Bindings := preload("res://addons/spacesim/settings/bindings.gd")

const TEST_PATH := "user://test-settings-ui.cfg"

var _instances: Array[Node] = []


func run(h, root: Node) -> void:
	print("  bindings and the settings screen")
	_clean()
	_test_binding_text(h)
	_test_binding_matching(h)
	_test_registry_is_sound(h)
	_test_edits_are_staged_not_applied(h)
	_test_reset_and_discard(h)
	_test_bad_values_are_not_staged(h)
	_clean()
	_release()


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
	h.check(unknown.is_empty(), "every declared validator exists%s" % _detail(unknown))
	h.check(bad_defaults.is_empty(), "every binding default is a valid binding%s" % _detail(bad_defaults))
	h.check(undotted.is_empty(), "every key is sectioned%s" % _detail(undotted))
	h.check(
		Settings.is_acceptable("bindings.throttle_up", "Alt+W"),
		"a valid binding is acceptable"
	)
	h.check(
		not Settings.is_acceptable("bindings.throttle_up", "Nonsense"),
		"and an unparseable one is not"
	)


func _test_edits_are_staged_not_applied(h) -> void:
	var settings := _open()
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
		FileAccess.get_file_as_string(TEST_PATH).contains("fov=90.0"), "and the file has it"
	)


func _test_reset_and_discard(h) -> void:
	var settings := _open()
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
		not FileAccess.get_file_as_string(TEST_PATH).contains("fov"),
		"which also removes it from the file"
	)

	edit.stage("camera.fov", 100.0)
	edit.discard()
	h.check(not edit.has_changes(), "closing discards what was staged")
	h.check(settings.get_value("camera.fov") != 100.0, "and the live setting never saw it")


func _test_bad_values_are_not_staged(h) -> void:
	var settings := _open()
	var edit = Edit.new(settings)
	h.check(not edit.stage("camera.fov", 10000.0), "an out-of-range edit is not staged")
	h.check(not edit.stage("frames.pad_size", 1.0), "a world setting is not staged")
	h.check(not edit.stage("bindings.throttle_up", "Nonsense"), "an unparseable binding is not staged")
	h.check(not edit.has_changes(), "so there is nothing to apply")


func _open() -> Node:
	var settings := Settings.new()
	settings.open(TEST_PATH)
	_instances.append(settings)
	return settings


func _release() -> void:
	for instance in _instances:
		instance.free()
	_instances.clear()


func _detail(problems: Array[String]) -> String:
	return "" if problems.is_empty() else ": " + ", ".join(problems)


func _clean() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
