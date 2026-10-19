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

## A setting is **the player's business**: the file is theirs, and it never travels with the world.
## Content that *should* travel — the frame bands, the shell altitudes — is authored on the resource
## instead, in `SpacesimFraming`, which is the one source for it.
##
## The `scope` field still declares whose a setting is. **It has one value today, deliberately**: a
## second scope is then a declaration rather than a refactor, and a reader can see that the single
## value is a decision and not something left over.
enum Scope { PLAYER }

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
	"camera.fov": {"default": 70.0, "scope": Scope.PLAYER, "min": 20.0, "max": 140.0},
	# --- how far behind the ship its own camera sits, in metres. **The ship's placeholder hull is only
	# visible when the near plane is inside it**, and the near plane follows the frame kind (deep space is
	# 100 m), so this is the knob that decides whether you can see the ship you are flying at all. Read at
	# the point of use in `main.gd`.
	"camera.ship_distance": {"default": 32.0, "scope": Scope.PLAYER, "min": 10.0, "max": 2000.0},
	# --- whether the player's own hull is drawn. **It was session state and it reset every run**, so the
	# key had to be pressed again each time; Evert, 2026-10-16: *"I want the 'ship' in the game to remember
	# its last setting."* A boolean row, which is the first one here — the bounds and the coercion leave an
	# unknown type alone, so nothing else had to change to take it. Read at the point of use in `main.gd`,
	# never cached in a variable, so the file stays hot.
	"ship.visible": {"default": true, "scope": Scope.PLAYER},
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
	# --- levels of detail. The geometric error a body's mesh is allowed to show at its **silhouette**,
	# in pixels on screen. One number decides the whole engine's mesh budget: a body's tessellation
	# follows from this and its screen size, and body to body it is the difference between 20 triangles
	# and 20,000. Read by `SpacesimSystemScene.update_lod`.
	#
	# Small is finer. It is a **trim**, the same shape as the star field's gain: it is meant to be tuned
	# by eye while flying and then frozen to a constant once a render set justifies the number, at which
	# point it stops being a setting and the value moves into `SpacesimLod`.
	"lod.error_budget": {"default": 4.0, "scope": Scope.PLAYER, "min": 0.25, "max": 32.0},
	# --- the exposure's ceiling. The metre drives the frame toward middle grey, and a frame of nothing
	# but stars has almost no mean luminance to answer with, so it drives toward the *top* of the
	# window — which is what this caps. In STOPS above the light-adapted floor, so 32 is the whole
	# range a dark-adapted eye has and 0 allows no boost at all. Read every frame by `main.gd` and
	# handed to `SpacesimExposurePass`; the arithmetic is `SpacesimExposure.max_multiplier_for_stops`.
	"exposure.range_stops": {"default": 32.0, "scope": Scope.PLAYER, "min": 0.0, "max": 40.0},
	"markers.pool_size": {"default": 12, "scope": Scope.PLAYER, "min": 1, "max": 64},
	# --- the sky. How deep the star field is drawn, as a magnitude. The catalogue holds the whole sky
	# and this only decides how much of it is shown, so sweeping it is a uniform write rather than a
	# rebuild, and going deeper can only ADD stars. The catalogue is a COMPLETE sky to magnitude 8 and
	# a diminishing fraction beyond (0.99 at 8, 0.69 at 9), so this belongs in 6.5 to 8.0; the
	# naked-eye limit is 6.5 and 9.5 is a soft ceiling. See `sky/PROVENANCE.md` for the measurements.
	"sky.star_depth": {"default": 6.5, "scope": Scope.PLAYER, "min": 3.0, "max": 9.5},
	# --- the star field's brightness, **in DECADES** (the multiplier is 10^this). A hand tuner, because
	# settling the absolute level by argument proved slower than settling it by eye. Placed in decades
	# so a linear slider can cross orders of magnitude; 0 is the derived brightness, and the range runs
	# from a thousandth of it to ten thousand times it.
	#
	# **It is a calibration knob and not a fudge factor to leave in.** If the value that looks right is
	# far from 0, the distance is a fact about the model worth chasing -- the two candidates are the
	# exposure resting multiplier, and whether the Sun's *illuminance* should ever be used to expose
	# for a sky at all, since an irradiance is not a scene luminance.
	"sky.star_gain": {"default": 0.0, "scope": Scope.PLAYER, "min": -6.0, "max": 8.0},
	# Sized to the HUD's own 17, so the markers read as part of the screen rather than as something
	# laid over it.
	"markers.font_size": {"default": 17, "scope": Scope.PLAYER, "min": 8, "max": 72},
	# Breathing room at the viewport edge. It was 100 when a pointer was clamped there and its own
	# width decided the clearance; labels are placed inside the bounds now, so it is only a margin.
	"markers.margin": {"default": 24.0, "scope": Scope.PLAYER, "min": 0.0, "max": 400.0},
	# The selected target's own colour, against the one colour everything else is drawn in. A colour
	# rather than a flag so the target can be made to stand out against whatever it is seen against.
	"markers.selected_color": {"default": Color(1.0, 0.9, 0.3), "scope": Scope.PLAYER},
	"bindings.settings_screen": {"default": "Alt+C", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.player_screen": {"default": "Tab", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.throttle_up": {"default": "W", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.throttle_down": {"default": "S", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.roll_left": {"default": "A", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.roll_right": {"default": "D", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.cycle_target": {"default": "T", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.bodies_toggle": {"default": "P", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.ship_toggle": {"default": "O", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.detail_down": {"default": "BracketLeft", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.detail_up": {"default": "BracketRight", "scope": Scope.PLAYER, "validator": "key_binding"},
	"bindings.wireframe_toggle": {"default": "L", "scope": Scope.PLAYER, "validator": "key_binding"},
}

## Emitted after a value changes, with the value that now stands.
signal changed(key: String, value: Variant)

var _file := ConfigFile.new()
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


## The value that stands: the default, unless the player's file says otherwise.
func get_value(key: String) -> Variant:
	var row: Dictionary = REGISTRY.get(key, {})
	if row.is_empty():
		push_warning("settings: '%s' is not a declared setting" % key)
		return null

	var fallback: Variant = row["default"]
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
