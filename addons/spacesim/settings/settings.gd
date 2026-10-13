extends Node
## Engine settings: declared defaults in code, one machine-written file for what differs.
##
## This is the shape Godot recommends, and the shape Godot itself uses: `project.godot` carries
## only values that differ from the engine defaults, and `override.cfg` layers a sparse
## per-install file over it. `ConfigFile.get_value(section, key, default)` is built around the
## same idea — the default argument exists because the key is expected to be absent.
##
## One file, in `$XDG_CONFIG_HOME/spacesim/settings.cfg`, machine read and written. It is INI so a
## human *can* read it, but nothing depends on that (and comments would not survive a write).
##
## ## Hot by construction
##
## Read through [method get_value] and listen to [signal changed]. **Never cache a setting in a
## variable at startup** — that is the one thing that turns a hot setting cold, and retrofitting
## it later means hunting down every cached copy.
##
## Registered as the `SpacesimSettings` autoload. Tests use their own instance with their own
## path, so the suite never touches the real file.

## A setting is either the player's business or the world's. World settings come from the world's
## own file, travel with the world as content, and are never written to the player's config.
enum Scope { PLAYER, WORLD }

const BindingsScript := preload("res://addons/spacesim/settings/bindings.gd")

## The named checks [method _passes_validator] knows. A row naming anything else is a mistake in
## the registry, not a silently skipped check.
const KNOWN_VALIDATORS := ["key_binding"]

## Every setting the engine knows, with the single declaration of its default.
##
## Keys are `section.key`, which is how they appear in the file. PLAYER-scope keys are what the
## player's file may carry; WORLD-scope keys are resolved from the world's file instead. `min` and
## `max` are optional guards for the values that would otherwise be able to break something — a
## wrong camera far plane is a black screen.
const REGISTRY := {
	# --- the window and the display. Three sizes, and they are three different things: the canvas
	# resolution is the UI's coordinate space (and so how large the HUD reads), the render resolution
	# is what the 3D is drawn at, and the window size is how big the window is. "Windowed
	# fullscreen" is not a fourth thing — it is the window size set to the screen's.
	#
	# The aspect is `expand`, so a window of another shape shows more rather than stretching. `keep`
	# is offered for anyone who would rather have bars and an exact canvas.
	"video.mode": {
		"default": "windowed",
		"scope": Scope.PLAYER,
		"choices": ["windowed", "fullscreen", "exclusive"],
	},
	"video.aspect": {"default": "expand", "scope": Scope.PLAYER, "choices": ["expand", "keep"]},
	# The list of screens is the machine's, not ours, so the row names a builder rather than a list.
	"video.screen": {"default": 0, "scope": Scope.PLAYER, "min": 0, "choices": "screens"},
	"video.canvas_resolution": {
		"default": Vector2i(1280, 720),
		"scope": Scope.PLAYER,
		"min": Vector2i(320, 240),
		"max": Vector2i(7680, 4320),
	},
	"video.render_resolution": {
		"default": Vector2i(1280, 720),
		"scope": Scope.PLAYER,
		"min": Vector2i(160, 120),
		"max": Vector2i(7680, 4320),
	},
	"video.window_size": {
		"default": Vector2i(1280, 720),
		"scope": Scope.PLAYER,
		"min": Vector2i(320, 240),
		"max": Vector2i(16384, 16384),
	},
	"mouse.sensitivity": {"default": 0.0015, "scope": Scope.PLAYER, "min": 0.0001, "max": 0.05},
	# Scales the air's density. A look knob rather than a preference, and a *setting* rather than a
	# constant because tuning a picture you cannot see must not require a rebuild.
	"air.density": {"default": 1.0, "scope": Scope.PLAYER, "min": 0.0, "max": 100.0},
	"camera.fov": {"default": 70.0, "scope": Scope.PLAYER, "min": 20.0, "max": 140.0},
	"camera.range_space": {"default": Vector2(100.0, 1.0e11), "scope": Scope.PLAYER, "min": Vector2(0.001, 1.0)},
	"camera.range_orbital": {"default": Vector2(5.0, 1.0e8), "scope": Scope.PLAYER, "min": Vector2(0.001, 1.0)},
	"camera.range_atmosphere": {
		"default": Vector2(0.5, 1.0e7), "scope": Scope.PLAYER, "min": Vector2(0.001, 1.0)
	},
	"camera.range_surface": {
		"default": Vector2(0.1, 2.0e5), "scope": Scope.PLAYER, "min": Vector2(0.001, 1.0)
	},
	"camera.range_interior": {
		"default": Vector2(0.05, 1.0e3), "scope": Scope.PLAYER, "min": Vector2(0.001, 0.01)
	},
	"markers.pool_size": {"default": 12, "scope": Scope.PLAYER, "min": 1, "max": 64},
	"markers.font_size": {"default": 20, "scope": Scope.PLAYER, "min": 8, "max": 72},
	"markers.margin": {"default": 100.0, "scope": Scope.PLAYER, "min": 0.0, "max": 400.0},
	"frames.system_band": {"default": Vector2(1.0e4, 1.0e11), "scope": Scope.WORLD},
	"frames.atmosphere_band": {"default": Vector2(2.0e3, 4.0e5), "scope": Scope.WORLD},
	"frames.surface_band": {"default": Vector2(1.0e2, 5.0e3), "scope": Scope.WORLD},
	"frames.atmosphere_altitude": {"default": 100000.0, "scope": Scope.WORLD, "min": 0.0},
	"frames.surface_altitude": {"default": 2000.0, "scope": Scope.WORLD, "min": 0.0},
	"frames.pad_size": {"default": 4000.0, "scope": Scope.WORLD, "min": 1.0},
	"bindings.settings_screen": {"default": "Alt+C", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.player_screen": {"default": "Tab", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.throttle_up": {"default": "W", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.throttle_down": {"default": "S", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.roll_left": {"default": "A", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.roll_right": {"default": "D", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.cycle_target": {"default": "T", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.bodies_toggle": {"default": "P", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.detail_down": {"default": "BracketLeft", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.detail_up": {"default": "BracketRight", "scope": Scope.PLAYER, "validator": "key_binding"},
}

## Emitted after a value changes, with the value that now stands.
signal changed(key: String, value: Variant)

var _file := ConfigFile.new()
var _world_values: Dictionary = {}
var _path := ""
var _dirty := false


func _ready() -> void:
	open()


func _exit_tree() -> void:
	save()


## Open the player's file. An empty path means the XDG location.
func open(path := "") -> void:
	_path = path if not path.is_empty() else SpacesimXdg.settings_path()
	_file = ConfigFile.new()
	if not FileAccess.file_exists(_path):
		return
	var error := _file.load(_path)
	if error != OK:
		# A corrupt or unreadable file must not stop the game: fall back to defaults.
		push_warning("settings: cannot read '%s' (%s); using defaults" % [_path, error_string(error)])
		_file = ConfigFile.new()


func path() -> String:
	return _path


static func declared_keys() -> Array:
	return REGISTRY.keys()


static func scope_of(key: String) -> Variant:
	var row: Dictionary = REGISTRY.get(key, {})
	return row.get("scope", null)


static func default_of(key: String) -> Variant:
	var row: Dictionary = REGISTRY.get(key, {})
	return row.get("default", null)


## The value that stands. Defaults unless the world or the player has said otherwise.
func get_value(key: String) -> Variant:
	var row: Dictionary = REGISTRY.get(key, {})
	if row.is_empty():
		push_warning("settings: '%s' is not a declared setting" % key)
		return null

	var fallback: Variant = row["default"]
	if int(row["scope"]) == Scope.WORLD:
		if _world_values.has(key):
			return _sanitise(row, _world_values[key])
		return fallback

	var parts := _split(key)
	if not _file.has_section_key(parts[0], parts[1]):
		return fallback
	# Sanitised on read as well as on write: the file is the player's to edit, and a value of
	# the wrong type or out of range must fall back rather than poison everything downstream.
	return _sanitise(row, _file.get_value(parts[0], parts[1], fallback))


## Set a player setting. A value equal to its default is erased rather than written, so the file
## only ever holds what the player actually changed.
func set_value(key: String, value: Variant, save_now := false) -> bool:
	var row: Dictionary = REGISTRY.get(key, {})
	if row.is_empty():
		push_warning("settings: '%s' is not a declared setting" % key)
		return false
	if int(row["scope"]) != Scope.PLAYER:
		push_warning("settings: '%s' is not player-settable" % key)
		return false

	var coerced: Variant = _coerce(value, row["default"])
	if not is_acceptable(key, value):
		push_warning("settings: %s = %s is out of range or unusable; ignored" % [key, value])
		return false

	var parts := _split(key)
	if _same(coerced, row["default"]):
		# Godot logs an error for erasing from a section that was never there, so check first —
		# and a setting left at its default is the common case, not the exception.
		if _file.has_section_key(parts[0], parts[1]):
			_file.erase_section_key(parts[0], parts[1])
	else:
		_file.set_value(parts[0], parts[1], coerced)
	_dirty = true
	if save_now:
		save()
	changed.emit(key, get_value(key))
	return true


func reset_value(key: String, save_now := false) -> bool:
	return set_value(key, default_of(key), save_now)


## Adopt values from the world's own file. World settings travel with the world as content, so
## they are never written here.
func set_world_values(values: Dictionary) -> void:
	for key in values:
		var row: Dictionary = REGISTRY.get(key, {})
		if row.is_empty():
			push_warning("settings: world sets undeclared '%s'; ignored" % key)
			continue
		if int(row["scope"]) != Scope.WORLD:
			push_warning("settings: world may not set '%s'" % key)
			continue
		var coerced: Variant = _coerce(values[key], row["default"])
		if not _acceptable_row(row, values[key]):
			push_warning("settings: world value for %s is unusable; ignored" % key)
			continue
		_world_values[key] = coerced
		changed.emit(key, get_value(key))


## Write the file, if there is anything to write. Never called by get_value: reading a setting
## must not touch the disk.
func save(force := false) -> bool:
	if not _dirty and not force:
		return true
	var directory := _path.get_base_dir()
	if not SpacesimXdg.ensure_directory(directory):
		push_warning("settings: cannot create '%s'" % directory)
		return false
	var error := _file.save(_path)
	if error != OK:
		push_warning("settings: cannot write '%s' (%s)" % [_path, error_string(error)])
		return false
	_dirty = false
	return true


## `section.key` split into its two parts.
static func _split(key: String) -> PackedStringArray:
	return key.split(".", false, 1)


static func _same(a: Variant, b: Variant) -> bool:
	return typeof(a) == typeof(b) and a == b


## Bounds are optional, and a Vector2's are compared component by component so a range key can
## at least be kept positive. Relational guards (a near plane must stay below a far plane) are not
## expressible here; whichever code consumes the value has to hold that end.
static func _within(row: Dictionary, value: Variant) -> bool:
	var low: Variant = row.get("min", null)
	var high: Variant = row.get("max", null)
	if low == null and high == null:
		return true

	if typeof(value) == TYPE_VECTOR2:
		if typeof(low) == TYPE_VECTOR2 and (value.x < low.x or value.y < low.y):
			return false
		if typeof(high) == TYPE_VECTOR2 and (value.x > high.x or value.y > high.y):
			return false
		return true

	if typeof(value) == TYPE_VECTOR2I:
		if typeof(low) == TYPE_VECTOR2I and (value.x < low.x or value.y < low.y):
			return false
		if typeof(high) == TYPE_VECTOR2I and (value.x > high.x or value.y > high.y):
			return false
		return true

	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		if (typeof(low) == TYPE_FLOAT or typeof(low) == TYPE_INT) and float(value) < float(low):
			return false
		if (typeof(high) == TYPE_FLOAT or typeof(high) == TYPE_INT) and float(value) > float(high):
			return false
	return true

## Whether the store would accept this value for this key. The settings screen asks before it
## stages an edit, so a control cannot put the store into a state the store would refuse.
static func is_acceptable(key: String, value: Variant) -> bool:
	var row: Dictionary = REGISTRY.get(key, {})
	if row.is_empty():
		return false
	return _acceptable_row(row, value)


static func _acceptable_row(row: Dictionary, value: Variant) -> bool:
	var coerced: Variant = _coerce(value, row["default"])
	if typeof(coerced) != typeof(row["default"]):
		return false
	if not _within(row, coerced):
		return false
	return _passes_validator(row, coerced)


## Named checks the bounds cannot express — and the extension point for the relational ones that
## min/max cannot either, such as a near plane having to stay below a far plane.
static func _passes_validator(row: Dictionary, value: Variant) -> bool:
	match String(row.get("validator", "")):
		"key_binding":
			return typeof(value) == TYPE_STRING and BindingsScript.is_valid(value)
	return true


## A value from a file or the world, made safe: coerced when it is merely a whole number stored
## as an int, and the declared default when it is the wrong type, out of range, or unusable.
static func _sanitise(row: Dictionary, value: Variant) -> Variant:
	if not _acceptable_row(row, value):
		return row["default"]
	return _coerce(value, row["default"])


## INI hands back an int where a float was stored (`70` for `70.0`), which the type check would
## otherwise reject.
static func _coerce(value: Variant, fallback: Variant) -> Variant:
	if typeof(fallback) == TYPE_FLOAT and typeof(value) == TYPE_INT:
		return float(value)
	if typeof(fallback) == TYPE_INT and typeof(value) == TYPE_FLOAT:
		if is_equal_approx(value, roundf(value)):
			return int(value)
	# A `Vector2i` is written and read back as one, so this is for a hand-edited file that spelled
	# it `Vector2(1280, 720)` — which is what somebody will type.
	if typeof(fallback) == TYPE_VECTOR2I and typeof(value) == TYPE_VECTOR2:
		return Vector2i(value)
	return value
