class_name SpacesimInput
extends RefCounted
## What an action's bindings are doing right now.
##
## **The runtime, and the only place that knows an event is a press of an action.** It replaces the
## three shapes the game used to call directly — `Bindings.matches(event, get_value("bindings.x"))`,
## a poll of `Input.is_physical_key_pressed`, and the raw text for the HUD's hints — with one object
## that reads the store and answers in actions rather than settings keys.
##
## ## Held state is tracked, not polled
##
## `held()` reads what [method feed] has seen rather than asking `Input` whether a key is down. That is
## what makes it testable (a test cannot press a key) and it is what a stick will need anyway, where
## "down" is a threshold on a value. **[method release_all] exists because a screen can take events
## while the game is not looking**: without it a key pressed and released behind a menu could leave an
## action held for ever.
##
## ## A value, not just a press
##
## **`value(action)` is what a stick needs and a key already had**: a key contributes `+1` while it is down,
## a mouse or pad button the same, and an axis contributes its **shaped** deflection — through that axis's
## profile, so the deadband and the travel are respected. The contributions **sum and clamp to −1 … +1**,
## which is why one axis can drive both directions of a paired action: a stick bound to `roll_right` reads
## `−1` when it is pushed left, and the consumer multiplies rather than gating on "is it held".
##
## `held()` stays what it was — *is a bang source down right now* — because a level accumulated in the
## flight controller is not a key, and asking `held()` about an axis would conflate the two.
##
## ## No integration, yet
##
## There is no `step(dt)` in this slice on purpose. The one level in the game — the ship's throttle —
## is integrated and clamped in `FlightController`, where the rest of the flight model lives, and the
## two throttle actions are `rate`s that say "+1 while held". A stick that sets a level directly is
## the pad work, and `step` arrives with it.

const Actions := preload("res://addons/spacesim/input/actions.gd")
const AxisProfile := preload("res://addons/spacesim/input/axis_profile.gd")
const Binding := preload("res://addons/spacesim/input/binding.gd")
const Devices := preload("res://addons/spacesim/input/devices.gd")
const Store := preload("res://addons/spacesim/input/bindings_store.gd")

var store: SpacesimBindingsStore

## The sources that are down, as `"<action>|<binding text>"` — a source is an action's *binding*, not
## the action, so two bindings on one action can be pressed independently and releasing one does not
## unpress the other.
var _down := {}


func _init(p_store: SpacesimBindingsStore) -> void:
	store = p_store


## Take one event. Returns whether it belonged to any action, so a caller can consume it.
##
## **Called for every event, pressed or released**, before anything is matched: a release is what
## clears a held source.
func feed(event: InputEvent) -> bool:
	var used := false
	for action in Actions.ids():
		for text in store.of(action):
			if not _is_source(event, String(text)):
				continue
			used = true
			var key := _key(action, String(text))
			if event.is_pressed():
				_down[key] = true
			else:
				_down.erase(key)
	return used


## Whether this event is this action's, as a press. **Edges only**: a release is not a press, and a key
## repeating while held is not another press.
func triggered(event: InputEvent, action: String) -> bool:
	if not event.is_pressed():
		return false
	for text in store.of(action):
		if Binding.matches(event, String(text)):
			return true
	return false


## **The action's value right now**, −1 … +1: bang sources at ±1 while down, axis sources shaped by their
## profile, summed and clamped.
func value(action: String) -> float:
	var total := 0.0
	for text in store.of(action):
		var binding := Binding.parse(String(text))
		if binding.is_empty():
			continue
		match String(binding["device"]):
			"keyboard", "mouse":
				if _down.has(_key(action, String(text))):
					total += 1.0
			"joypad":
				var device := Devices.device_index(String(binding["pad"]))
				if device < 0:
					continue
				if binding.has("button"):
					if Input.is_joy_button_pressed(device, int(binding["button"])):
						total += 1.0
				else:
					var axis_name := String(Devices.AXIS_NAMES[int(binding["axis"])])
					var profile: SpacesimAxisProfile = store.axis_profile(
						String(binding["pad"]), axis_name
					)
					total += profile.shape(Devices.axis(device, int(binding["axis"])))
	return clampf(total, -1.0, 1.0)


## Whether any of the action's **bang** sources is down right now. An axis is not a bang source: it is a
## position, and [method value] is where it belongs.
func held(action: String) -> bool:
	for text in store.of(action):
		if _down.has(_key(action, String(text))):
			return true
	return false


## Forget every held source. The screen pause uses it: **the game stops watching while a menu is open**,
## and a key pressed and released behind one would otherwise still read as held.
func release_all() -> void:
	_down.clear()


## The text to print for an action, for the HUD's hints.
##
## **The first keyboard binding if there is one, else the first binding**: a hint is read at a keyboard,
## so a pad-only action should still print the first thing a player could press.
func hint(action: String) -> String:
	var bindings := store.of(action)
	for text in bindings:
		if Binding.keycode_of(String(text)) != KEY_NONE:
			return String(text)
	return "" if bindings.is_empty() else String(bindings[0])


## Whether an event is this binding's *source*, pressed or released — the identity half of a match,
## without the chord. A release still has to clear the right source even if the modifier has already
## been let go.
func _is_source(event: InputEvent, text: String) -> bool:
	var binding := Binding.parse(text)
	if binding.is_empty():
		return false
	if String(binding["device"]) == "joypad":
		var pad := event as InputEventJoypadButton
		if pad == null or not binding.has("button"):
			return false
		return (
			pad.button_index == int(binding["button"])
			and Devices.name_of(pad.device) == String(binding["pad"])
		)
	if String(binding["device"]) == "keyboard":
		var key := event as InputEventKey
		return key != null and key.physical_keycode == int(binding["keycode"])
	var mouse := event as InputEventMouseButton
	return mouse != null and mouse.button_index == int(binding["button"])


static func _key(action: String, text: String) -> String:
	return "%s|%s" % [action, text]
