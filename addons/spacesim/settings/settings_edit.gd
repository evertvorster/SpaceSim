class_name SpacesimSettingsEdit
extends RefCounted
## Staged changes for the settings screen.
##
## Nothing reaches the live settings until [method apply]. That is what makes Apply a real button
## rather than a decoration: the controls edit a staging area, Apply commits and writes the file,
## and Close throws the staging away. The screen shows which of the two you are about to do by
## changing the buttons' colour.

const SettingsScript := preload("res://addons/spacesim/settings/settings.gd")

signal changed

var _settings: Node
var _staged: Dictionary = {}


func _init(settings: Node) -> void:
	_settings = settings


## The keys this screen is allowed to edit, in registry order.
static func editable_keys() -> Array:
	var keys: Array = []
	for key in SettingsScript.declared_keys():
		if int(SettingsScript.scope_of(key)) == SettingsScript.Scope.PLAYER:
			keys.append(key)
	return keys


## The value the screen should show: staged if it has been edited, otherwise what stands.
func value(key: String) -> Variant:
	if _staged.has(key):
		return _staged[key]
	return _settings.get_value(key)


func is_staged(key: String) -> bool:
	return _staged.has(key)


func has_changes() -> bool:
	return not _staged.is_empty()


func staged_keys() -> Array:
	return _staged.keys()


## Record an edit. Staging a value that is already in force un-stages it, so fiddling a control
## back to where it started leaves nothing to apply.
func stage(key: String, value: Variant) -> bool:
	if int(SettingsScript.scope_of(key)) != SettingsScript.Scope.PLAYER:
		return false
	if not SettingsScript.is_acceptable(key, value):
		return false
	if value == _settings.get_value(key):
		_staged.erase(key)
	else:
		_staged[key] = value
	changed.emit()
	return true


## Put a setting back to the engine's default — staged, not applied, like any other edit.
func reset_to_default(key: String) -> bool:
	return stage(key, SettingsScript.default_of(key))


## Throw the staged edits away.
func discard() -> void:
	if _staged.is_empty():
		return
	_staged.clear()
	changed.emit()


## Commit everything staged. Returns how many settings changed.
func apply() -> int:
	var applied := 0
	for key in _staged.keys():
		if _settings.set_value(key, _staged[key]):
			applied += 1
	_staged.clear()
	_settings.save()
	changed.emit()
	return applied
