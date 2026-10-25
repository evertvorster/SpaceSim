class_name SpacesimXdg
extends RefCounted
## XDG Base Directory paths.
##
## Godot's `user://` is a single writable directory, under the *data* home and nested through
## `godot/app_userdata`, so it cannot separate configuration from data and it is not `~/.config`.
## These resolve the paths properly instead, which also puts the world and save repositories
## somewhere predictable.
##
## Per the specification a variable that is unset, empty, or **not an absolute path** is ignored —
## the last of those is the rule nobody implements until it bites.

const APP_DIR := "spacesim"


static func config_home() -> String:
	return _base("XDG_CONFIG_HOME", ".config")


static func data_home() -> String:
	return _base("XDG_DATA_HOME", ".local/share")


## Where this application's settings live.
static func config_dir() -> String:
	return config_home().path_join(APP_DIR)


## Where this application's data (worlds, save branches) lives.
static func data_dir() -> String:
	return data_home().path_join(APP_DIR)


static func settings_path() -> String:
	return config_dir().path_join("settings.cfg")


static func ensure_directory(path: String) -> bool:
	if DirAccess.dir_exists_absolute(path):
		return true
	return DirAccess.make_dir_recursive_absolute(path) == OK


static func _base(variable: String, fallback_relative: String) -> String:
	var value := OS.get_environment(variable)
	if not value.is_empty() and value.is_absolute_path():
		return value
	var home := OS.get_environment("HOME")
	if home.is_empty():
		# Nowhere to put it: fall back to Godot's user directory so the game still runs.
		return OS.get_user_data_dir()
	return home.path_join(fallback_relative)
