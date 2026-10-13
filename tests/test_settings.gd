extends RefCounted
## Settings: declared defaults in code, one sparse file for what differs.

const Settings := preload("res://addons/spacesim/settings/settings.gd")
const Xdg := preload("res://addons/spacesim/settings/xdg.gd")

const Fixture := preload("res://tests/settings_fixture.gd")

var _fixture := Fixture.new()


func run(h, root: Node) -> void:
	print("  settings")
	Fixture.clean()
	_test_declared_keys_round_trip(h)
	_test_sparse_and_self_cleaning(h)
	_test_validation(h)
	_test_unreadable_values_fall_back(h)
	_test_coercion(h)
	_test_unknown_keys_survive(h)
	_test_world_scope_never_reaches_the_file(h)
	_test_xdg_fallbacks(h)
	Fixture.clean()
	_fixture.release()


func _test_declared_keys_round_trip(h) -> void:
	# A declared key that cannot be set and read back is the bug class that made settings
	# silently never persist in the vegastrike config work. Every key is checked, not a sample.
	var settings := _fixture.open()
	var failures: Array[String] = []
	for key in Settings.declared_keys():
		if int(Settings.scope_of(key)) != Settings.Scope.PLAYER:
			continue
		var changed_value: Variant = _something_else(key)
		if not settings.set_value(key, changed_value):
			failures.append("%s: rejected" % key)
			continue
		if settings.get_value(key) != changed_value:
			failures.append("%s: read back as %s" % [key, settings.get_value(key)])
	h.check(failures.is_empty(), "every player-settable key round-trips%s" % Fixture.detail(failures))
	settings.save(true)

	# And again from a fresh instance, so it is the file doing the work.
	var reloaded := _fixture.open()
	var persisted: Array[String] = []
	for key in Settings.declared_keys():
		if int(Settings.scope_of(key)) != Settings.Scope.PLAYER:
			continue
		if reloaded.get_value(key) != _something_else(key):
			persisted.append(key)
	h.check(persisted.is_empty(), "and survives a reload%s" % Fixture.detail(persisted))


func _test_sparse_and_self_cleaning(h) -> void:
	Fixture.clean()
	var settings := _fixture.open()
	settings.set_value("camera.fov", 90.0)
	settings.save(true)

	var text := FileAccess.get_file_as_string(Fixture.TEST_PATH)
	h.check(text.contains("fov=90.0"), "a changed value is written")
	h.check(not text.contains("pool_size"), "and values left at their default are not")
	h.check(text.contains("[camera]"), "under the section its key names")

	settings.set_value("camera.fov", Settings.default_of("camera.fov"))
	settings.save(true)
	text = FileAccess.get_file_as_string(Fixture.TEST_PATH)
	h.check(not text.contains("fov"), "returning a value to its default removes it again")


func _test_validation(h) -> void:
	var settings := _fixture.open()
	h.check(not settings.set_value("camera.fov", 10000.0), "a value out of range is refused")
	h.check(
		settings.get_value("camera.fov") == Settings.default_of("camera.fov"),
		"and the value that stood is unchanged"
	)
	h.check(not settings.set_value("nobody.declared_this", 1.0), "an undeclared key is refused")
	h.check(not settings.set_value("frames.pad_size", 10.0), "a world setting is not player-settable")


func _test_coercion(h) -> void:
	# INI hands back an int for a float that happens to be whole.
	var settings := _fixture.open()
	settings.set_value("camera.fov", 75)
	h.check(settings.get_value("camera.fov") == 75.0, "an int given for a float reads back as a float")


func _test_unknown_keys_survive(h) -> void:
	Fixture.clean()
	var settings := _fixture.open()
	settings.set_value("camera.fov", 90.0)
	settings.save(true)

	# Something newer wrote a key this build does not know about.
	var text := FileAccess.get_file_as_string(Fixture.TEST_PATH)
	text = text.replace("[camera]", "[camera]\nfuture_setting=42")
	var file := FileAccess.open(Fixture.TEST_PATH, FileAccess.WRITE)
	file.store_string(text)
	file.close()

	var reloaded := _fixture.open()
	reloaded.set_value("markers.pool_size", 20)
	reloaded.save(true)
	h.check(
		FileAccess.get_file_as_string(Fixture.TEST_PATH).contains("future_setting=42"),
		"a key this build does not know about is preserved, not dropped"
	)


func _test_world_scope_never_reaches_the_file(h) -> void:
	Fixture.clean()
	var settings := _fixture.open()
	settings.set_world_values({"frames.pad_size": 8000.0})
	h.check(settings.get_value("frames.pad_size") == 8000.0, "the world's value takes effect")
	settings.set_value("camera.fov", 90.0)
	settings.save(true)
	var text := FileAccess.get_file_as_string(Fixture.TEST_PATH)
	h.check(not text.contains("pad_size"), "a world value is never written to the player's file")


func _test_xdg_fallbacks(h) -> void:
	# The specification: unset, empty, or not absolute means the fallback.
	var saved := OS.get_environment("XDG_CONFIG_HOME")
	var home := OS.get_environment("HOME")

	OS.set_environment("XDG_CONFIG_HOME", "")
	h.check(
		Xdg.config_home() == home.path_join(".config"), "unset falls back to ~/.config"
	)

	OS.set_environment("XDG_CONFIG_HOME", "relative/path")
	h.check(Xdg.config_home() == home.path_join(".config"), "a relative value is ignored, not used")

	OS.set_environment("XDG_CONFIG_HOME", "/tmp/spacesim-xdg-test")
	h.check(Xdg.config_home() == "/tmp/spacesim-xdg-test", "an absolute value is used")
	h.check(
		Xdg.settings_path() == "/tmp/spacesim-xdg-test/spacesim/settings.cfg",
		"and the settings path is built from it"
	)

	OS.set_environment("XDG_CONFIG_HOME", saved)


## The file is the player's to edit, so reading must be as careful as writing.
func _test_unreadable_values_fall_back(h) -> void:
	Fixture.clean()
	var settings := _fixture.open()
	settings.set_value("camera.fov", 90.0)
	settings.save(true)

	var file := FileAccess.open(Fixture.TEST_PATH, FileAccess.WRITE)
	file.store_string("[camera]\nfov=\"not a number\"\nrange_space=42\nrange_surface=Vector2(0, 0)\n")
	file.close()

	var reloaded := _fixture.open()
	h.check(
		reloaded.get_value("camera.fov") == Settings.default_of("camera.fov"),
		"a value of the wrong type falls back to the default"
	)
	h.check(
		reloaded.get_value("camera.range_space") == Settings.default_of("camera.range_space"),
		"a wrong type on a Vector2 key does too"
	)
	h.check(
		reloaded.get_value("camera.range_surface") == Settings.default_of("camera.range_surface"),
		"and a Vector2 below its bounds does too, rather than giving a black screen"
	)


## A value of the same type that differs from the default **and is inside whatever range the
## registry declares** — otherwise the round-trip test trips the validation it is next to.
func _something_else(key: String) -> Variant:
	var default: Variant = Settings.default_of(key)
	var row: Dictionary = Settings.REGISTRY.get(key, {})
	match typeof(default):
		TYPE_FLOAT:
			var wanted := float(default) + 1.0
			if row.has("max"):
				wanted = minf(wanted, float(row["max"]))
			return wanted
		TYPE_INT:
			var wanted_int := int(default) + 1
			if row.has("max"):
				wanted_int = mini(wanted_int, int(row["max"]))
			return wanted_int
		TYPE_VECTOR2:
			return default + Vector2(1.0, 1.0)
		TYPE_VECTOR2I:
			return default + Vector2i(1, 1)
		TYPE_COLOR:
			# Any other colour: the store only checks the type.
			return Color(0.1, 0.2, 0.3, 1.0)
		TYPE_STRING:
			# A row that offers choices can only be given one of them, or it would not be acceptable.
			var listed: Variant = row.get("choices", null)
			if listed is Array:
				for choice in listed:
					if String(choice) != String(default):
						return String(choice)
			# A different valid binding, so the round-trip test does not accidentally stage the
			# default and trip over the self-cleaning.
			return "Alt+U" if String(default) == "Alt+V" else "Alt+V"
	return default
