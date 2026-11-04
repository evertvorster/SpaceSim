class_name SpacesimBindingsStore
extends RefCounted
## The player's bindings, in their own file beside `settings.cfg`.
##
## **A store of its own, not settings rows**, because the settings registry declares its keys statically
## and the suite asserts every declared setting has a control — a bindings table cannot be declared, and
## a pad plugged in tomorrow has no row to add.
##
## ## The file
##
## ```ini
## [bindings]
## throttle_up = "Shift+Equal"
## roll_left = "BracketLeft, A"
##
## [bindings.PS4 Controller]
## throttle_up = "Joy:PS4 Controller/Button:A"
## ```
##
## `[bindings]` is the default table; `[bindings.<device name>]` overrides it for one device, keyed by
## the device's **name** — two pads with the same name share their bindings, which is the accepted
## trade. Per-device sections are read here but nothing writes them until the pad work lands.
##
## **An empty value means unbound**, which is a different thing from an absent key (which means "use
## the registry's default"). That is what lets a player clear an action rather than only change it.
##
## ## Staged, like the settings screen
##
## Edits accumulate in memory; `apply()` writes them and `discard()` throws them away. The screen's
## Apply and Close colours are driven by [method has_changes], and **nothing is ever written by any
## other route** — no auto-save, no write-back.

const Actions := preload("res://addons/spacesim/input/actions.gd")
const AxisProfile := preload("res://addons/spacesim/input/axis_profile.gd")
const Binding := preload("res://addons/spacesim/input/binding.gd")

const DEFAULT_SECTION := "bindings"
const DEVICE_PREFIX := "bindings."
## **The axis profiles, one section per device**, keyed by the axis's name:
##
## ```ini
## [axes.PS4 Controller]
## LEFT_X = "-1.000, 1.000, 0.000, 0.150"
## ```
##
## They live here because they are staged and written by the same edits as the bindings, not because they
## are bindings: a profile belongs to the device's axis.
const AXES_PREFIX := "axes."
## What separates two bindings on one action in the file. A comma cannot appear in a binding, so the
## split is unambiguous.
const SEPARATOR := ","

var _file := ConfigFile.new()
var _path := ""
## action id → Array of texts, for the actions the player has edited and not yet applied.
var _staged := {}
## `"<device>|<axis>"` → `SpacesimAxisProfile`, for the axis profiles the player has edited.
var _staged_axes := {}

## Anything the one-time import could not read, as `["<action>: <text>", …]`. Shown by the screen
## rather than swallowed: a binding that silently reverted to its default is the fault nobody reports.
var problems: Array = []


## Open the store. **An empty path means the XDG location**; an empty `legacy_path` means the XDG
## settings file, which is where the sixteen old `bindings.*` keys live.
func open(path := "", legacy_path := "") -> void:
	_path = path if not path.is_empty() else SpacesimXdg.bindings_path()
	_file = ConfigFile.new()
	_staged.clear()
	_staged_axes.clear()
	problems.clear()

	if FileAccess.file_exists(_path):
		var error := _file.load(_path)
		if error != OK:
			push_warning("bindings: cannot read '%s' (%s); using the registry's defaults"
				% [_path, error_string(error)])
			_file = ConfigFile.new()
		return

	_import_legacy(legacy_path if not legacy_path.is_empty() else SpacesimXdg.settings_path())


func path() -> String:
	return _path


## **The one-time import from `settings.cfg`**, where an action's binding was a settings key with the
## same name and a `bindings.` prefix.
##
## It **writes nothing**: the imported values live in memory until the player presses Apply, so the
## import is idempotent and a first run cannot overwrite anything. `[bindings]` is written whole on the
## first apply, which is also the moment the file starts existing.
func _import_legacy(settings_path: String) -> void:
	if not FileAccess.file_exists(settings_path):
		return
	var legacy := ConfigFile.new()
	if legacy.load(settings_path) != OK:
		return
	# The old file stores them as `[bindings] throttle_up = "Shift+Equal"`: `SpacesimSettings` splits a
	# `bindings.throttle_up` key into that section and that key.
	for id in Actions.ids():
		if not legacy.has_section_key("bindings", id):
			continue
		var text := String(legacy.get_value("bindings", id, ""))
		if Binding.is_valid(text):
			_file.set_value(DEFAULT_SECTION, id, text)
		else:
			problems.append("%s: %s" % [id, text])


## Every action's bindings, defaults filled in, for one device (`""` for the default table).
func table(device := "") -> Dictionary:
	var found := {}
	for id in Actions.ids():
		found[id] = of(id, device)
	return found


## One action's bindings: **staged** if it has been edited, else what the file says, else the
## registry's.
func of(action: String, device := "") -> Array:
	if _staged.has(action):
		return (_staged[action] as Array).duplicate()
	return _stored(action, device)


## What stands without the staging, which is what [method has_changes] has to compare against.
func _stored(action: String, device := "") -> Array:
	if not device.is_empty():
		var override := _section_values(DEVICE_PREFIX + device)
		if override.has(action):
			return override[action]
	var values := _section_values(DEFAULT_SECTION)
	if values.has(action):
		return values[action]
	return Actions.defaults_of(action).duplicate()


## Stage an action's bindings. **Every text must parse and the action must exist**, so a typo is
## refused here rather than written and discovered at the next keypress. An empty array unbinds it.
func stage(action: String, texts: Array) -> bool:
	if not Actions.has(action):
		return false
	for text in texts:
		if not Binding.is_valid(String(text)):
			return false
	_staged[action] = _clean(texts)
	return true


## A staged reset: back to what the registry declares.
func reset(action: String) -> void:
	if Actions.has(action):
		_staged[action] = Actions.defaults_of(action).duplicate()


func has_changes() -> bool:
	for id in _staged:
		if _clean(_staged[id]) != _clean(_stored(id)):
			return true
	for key in _staged_axes:
		var staged: SpacesimAxisProfile = _staged_axes[key]
		if staged.to_text() != _stored_axis_profile(key).to_text():
			return true
	return false


func discard() -> void:
	_staged.clear()
	_staged_axes.clear()


## **One axis's profile**: staged if edited, else the device's section, else the defaults.
func axis_profile(device: String, axis: String) -> SpacesimAxisProfile:
	var key := _axis_key(device, axis)
	if _staged_axes.has(key):
		return (_staged_axes[key] as SpacesimAxisProfile).duplicate_profile()
	return _stored_axis_profile(key)


## Stage a profile. **A profile that cannot make sense is refused**, so a centre outside the travel or a
## band wide enough to swallow the whole axis never reaches the file.
func stage_axis_profile(device: String, axis: String, profile: SpacesimAxisProfile) -> bool:
	if not profile.is_sane():
		return false
	_staged_axes[_axis_key(device, axis)] = profile.duplicate_profile()
	return true


func _stored_axis_profile(key: String) -> SpacesimAxisProfile:
	var split := key.split("|", true, 1)
	if split.size() != 2:
		return AxisProfile.new()
	var section := AXES_PREFIX + String(split[0])
	if not _file.has_section_key(section, String(split[1])):
		# **Uncalibrated is not "no idea"**: a trigger's default travel is 0 … +1, so a fresh profile is
		# the one the axis actually has rather than a symmetric guess.
		return AxisProfile.default_for(String(split[1]))
	return AxisProfile.from_text(String(_file.get_value(section, String(split[1]), "")))


static func _axis_key(device: String, axis: String) -> String:
	return "%s|%s" % [device, axis]


## Write the whole table and clear the staging. Returns the number of actions written, or -1 when the
## file could not be written.
func apply() -> int:
	var written := table()
	var fresh := ConfigFile.new()
	for id in Actions.ids():
		fresh.set_value(DEFAULT_SECTION, id, _join(written[id]))

	# A device's binding overrides and every axis profile are carried across untouched — nothing here
	# writes one — so a section this screen does not know about survives an Apply.
	for section in _file.get_sections():
		if not (section.begins_with(DEVICE_PREFIX) or section.begins_with(AXES_PREFIX)):
			continue
		for key in _file.get_section_keys(section):
			fresh.set_value(section, key, _file.get_value(section, key))

	# The staged axis profiles go over the top of that.
	for key in _staged_axes:
		var parts := String(key).split("|", true, 1)
		if parts.size() != 2:
			continue
		fresh.set_value(
			AXES_PREFIX + String(parts[0]),
			String(parts[1]),
			(_staged_axes[key] as SpacesimAxisProfile).to_text()
		)

	if not SpacesimXdg.ensure_directory(_path.get_base_dir()):
		push_warning("bindings: cannot create '%s'" % _path.get_base_dir())
		return -1
	var error := fresh.save(_path)
	if error != OK:
		push_warning("bindings: cannot write '%s' (%s)" % [_path, error_string(error)])
		return -1

	_file = fresh
	_staged.clear()
	_staged_axes.clear()
	return Actions.ids().size()


## One section's values, each parsed into an Array of texts.
func _section_values(section: String) -> Dictionary:
	var values := {}
	if not _file.has_section(section):
		return values
	for key in _file.get_section_keys(section):
		values[key] = _texts(String(_file.get_value(section, key, "")))
	return values


## A stored value — one string, bindings separated by commas — as a list of texts.
static func _texts(stored: String) -> Array:
	return _clean(stored.split(SEPARATOR, false))


## A list of texts with the blanks gone, so `""` and `[]` both mean unbound.
static func _clean(texts: Array) -> Array:
	var found: Array = []
	for text in texts:
		var stripped := String(text).strip_edges()
		if not stripped.is_empty():
			found.append(stripped)
	return found


static func _join(texts: Array) -> String:
	var parts := PackedStringArray()
	for text in _clean(texts):
		parts.append(String(text))
	return SEPARATOR.join(parts)
