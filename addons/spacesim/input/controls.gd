class_name SpacesimControls
extends RefCounted
## **The degrees of freedom, and what drives each one.**
##
## A degree of freedom is not an action. Roll, pitch, yaw, throttle and the two strafes are *dimensions*
## with one signed value each, fed by sources of three different kinds — a key or button held, an axis
## deflected, or a wheel notch — and the three are not interchangeable:
##
## | kind | from | into |
## |---|---|---|
## | **bang** | a key or mouse button held | `±1` while down |
## | **relative** | a joystick axis | a fraction of the full rate |
## | **angle** | mouse movement | an angle, already in radians |
## | **impulse** | a wheel notch | a fixed step, once per notch |
##
## **`value(dof)` is this frame's contribution, in the DOF's own output unit** — radians for a rotation, a
## fraction of `TOP_THROTTLE` for throttle. It is a *delta*, not a level: the throttle level stays in
## `FlightController` where it has always lived, and this adds to it. That keeps the ship's state in one
## place and makes a menu pause cost nothing.
##
## ## Why this exists at all
##
## An axis is signed; a pair of digital actions is not. Binding a stick to `throttle_up` gave `−1` pulled
## back (reads as inverted) and refused to let the same axis also drive `throttle_down` (one source claimed
## twice). Both were the model, not the binding code — see the vault's *Flight Control*.

const Binding := preload("res://addons/spacesim/input/binding.gd")
const Devices := preload("res://addons/spacesim/input/devices.gd")
const Store := preload("res://addons/spacesim/input/bindings_store.gd")

## The DOFs, in the order the tab shows them.
const DOFS := ["roll", "pitch", "yaw", "throttle", "strafe_x", "strafe_y"]

## Per DOF: what it is called, its output unit, and the full rate its sources scale to.
##
## `rate` is in output units per second at full deflection — rad/s for a rotation — so a held key and a
## deflected stick are the same number. **`in_ship` false means the DOF is defined and drawn but the ship
## cannot move that way yet**, and the tab says so rather than showing a control that does nothing.
const REGISTRY := {
	"roll": {"label": "Roll", "unit": "rad", "rate": 1.2, "in_ship": true},
	"pitch": {"label": "Pitch", "unit": "rad", "rate": 0.8, "in_ship": true},
	"yaw": {"label": "Yaw", "unit": "rad", "rate": 0.8, "in_ship": true},
	"throttle": {"label": "Throttle", "unit": "throttle", "rate": 1.0, "in_ship": true},
	"strafe_x": {"label": "Strafe left/right", "unit": "m/s", "rate": 1.0, "in_ship": false},
	"strafe_y": {"label": "Strafe up/down", "unit": "m/s", "rate": 1.0, "in_ship": false},
}

## How much one wheel notch moves an impulse-fed DOF, in its output unit.
const NOTCH_STEP := 0.1

## Which pointer axis drives a DOF, and with what sign. **Pitch takes −y**, because pushing the mouse
## forward has nosed the ship down since the first flight test and it must not change now.
const POINTER_AXIS := {
	"roll": "x", "yaw": "x", "pitch": "-y", "throttle": "y",
	"strafe_x": "x", "strafe_y": "-y",
}

## The lines a DOF stores, in the order the tab shows them.
## What a DOF's lines are before the player has touched them: the blank shape with the shipped
## assignments laid over it. The tab draws from this, so a fresh screen shows what the ship is flying.
static func defaults_for(dof: String) -> Dictionary:
	var row := BLANK.duplicate()
	var assigned: Dictionary = DEFAULTS.get(dof, {})
	for key in assigned:
		row[key] = assigned[key]
	return row


## The shape of a DOF's lines, all empty, before anything is assigned.
const BLANK := {
	"keyboard_decrease": "", "keyboard_increase": "",
	"joystick": "", "joystick_invert": false,
	"mouse_movement": "off", "mouse_invert": false,
	"mouse_decrease": "", "mouse_increase": "",
}

## **What the ship flew with before this layer existed**, so wiring it in changes nothing: the brackets
## rolled, minus and shifted-equal wound the throttle, and the mouse turned. Everything else starts
## unassigned, and the tab is how it becomes anything else.
const DEFAULTS := {
	"roll": {"keyboard_decrease": "BracketLeft", "keyboard_increase": "BracketRight"},
	"pitch": {"mouse_movement": "glide"},
	"yaw": {"mouse_movement": "glide"},
	"throttle": {"keyboard_decrease": "Minus", "keyboard_increase": "Shift+Equal"},
}

const KEYS := [
	"keyboard_decrease", "keyboard_increase",
	"joystick", "joystick_invert",
	"mouse_movement", "mouse_invert",
	"mouse_decrease", "mouse_increase",
]

var store: SpacesimBindingsStore

## Radians of rotation per pixel of mouse movement, before the DOF's own invert. Set by the caller from
## the player's `mouse.sensitivity`, so the pointer feels the same as it always has.
var pointer_sensitivity := 0.0015



## Bang sources that are down, as `"<dof>|<slot>|<text>"`.
var _down := {}
## Wheel notches accumulated since the last step, per DOF.
var _notches := {}
## The pointer's movement since the last step, in pixels.
var _pointer := Vector2.ZERO
## The value each DOF produced this frame.
var _value := {}


## One DOF's lines: the store's over the defaults, so a missing key is never a missing line.
func _row(dof: String) -> Dictionary:
	var row := defaults_for(dof)
	var stored: Dictionary = store.control(dof)
	for key in stored:
		row[key] = stored[key]
	return row


func _init(p_store: SpacesimBindingsStore) -> void:
	store = p_store
	for dof in DOFS:
		_value[dof] = 0.0


## **Take one event**: a key or mouse button down/up, or a wheel notch. Called for every event before
## anything is matched, because a release is what clears a held source.
func feed(event: InputEvent) -> void:
	for dof in DOFS:
		var row := _row(dof)
		for slot in ["decrease", "increase"]:
			for text in _texts(row, slot):
				if not _is_source(event, text):
					continue
				var key := _key(dof, slot, text)
				if not event.is_pressed():
					_down.erase(key)
					continue
				# **A notch is a step, not a hold.** Counting it as a held source as well made one notch
				# move the DOF twice: once per frame for as long as it stayed "down", and once as a step.
				if _is_wheel(text):
					_notches[dof] = float(_notches.get(dof, 0.0)) + _sign(slot)
				else:
					_down[key] = true


## The pointer's movement since the last call, in pixels.
func feed_motion(relative: Vector2) -> void:
	_pointer += relative


## Work out every DOF's contribution for this frame. Call once, before reading [method value].
func step(delta: float) -> void:
	for dof in DOFS:
		var row := _row(dof)
		var rate := float(REGISTRY[dof]["rate"])
		# **`_bang` carries the slot's sign already**, so the two slots add rather than subtract.
		var drive := _bang(dof, "increase") + _bang(dof, "decrease")
		drive += _axis(dof, row)
		var out := drive * rate * delta

		# **The pointer is an angle already**, so it is added rather than scaled by dt: a pixel of movement
		# is the same amount of turn however fast the frame came round. **Several DOFs may read it**, one
		# axis each — that is what mouse-look is, yaw from x and pitch from y.
		out += _pointer_angle(dof, row)

		out += float(_notches.get(dof, 0.0)) * NOTCH_STEP
		_value[dof] = out
	_notches.clear()
	_pointer = Vector2.ZERO


## This frame's contribution for one DOF, in its output unit.
func value(dof: String) -> float:
	return float(_value.get(dof, 0.0))


## Every DOF's value, for a caller that wants them in one go.
func values() -> Dictionary:
	return _value.duplicate()


# --- the sources -----------------------------------------------------------------------------------

## `+1` if this slot is held, `0` otherwise — and the slot says the sign, which is the whole reason a
## discrete source does not need an invert toggle.
func _bang(dof: String, slot: String) -> float:
	var row := _row(dof)
	for text in _texts(row, slot):
		if _down.has(_key(dof, slot, String(text))):
			return _sign(slot)
	return 0.0


## The joystick axis, shaped by **that axis's own profile** so the deadband and the calibrated travel are
## respected, then inverted if the player says this stick is mounted the other way round.
func _axis(dof: String, row: Dictionary) -> float:
	var text := String(row.get("joystick", ""))
	if text.is_empty():
		return 0.0
	var binding := Binding.parse(text)
	if binding.is_empty() or not binding.has("axis"):
		return 0.0
	var pad := String(binding["pad"])
	var device := Devices.device_index(pad)
	if device < 0:
		return 0.0
	var axis_name := String(Devices.AXIS_NAMES[int(binding["axis"])])
	var shaped: float = store.axis_profile(pad, axis_name).shape(
		Devices.axis(device, int(binding["axis"]))
	)
	return -shaped if bool(row.get("joystick_invert", false)) else shaped


## The pointer, **as an angle**: a pixel of movement is the same amount of turn however long the frame was.
func _pointer_angle(dof: String, row: Dictionary) -> float:
	if String(row.get("mouse_movement", "off")) == "off":
		return 0.0
	var direction := String(POINTER_AXIS.get(dof, "x"))
	var pixels := _pointer.x if direction.trim_prefix("-") == "x" else _pointer.y
	var angle := pixels * pointer_sensitivity
	if direction.begins_with("-"):
		angle = -angle
	if bool(row.get("mouse_invert", false)):
		angle = -angle
	return angle


static func _texts(row: Dictionary, slot: String) -> Array:
	var found: Array = []
	for key in ["keyboard", "mouse"]:
		var value := String(row.get("%s_%s" % [key, slot], ""))
		if not value.is_empty():
			found.append(value)
	return found


static func _is_wheel(text: String) -> bool:
	return text.contains("Wheel")


static func _sign(slot: String) -> float:
	return 1.0 if slot == "increase" else -1.0


static func _key(dof: String, slot: String, text: String) -> String:
	return "%s|%s|%s" % [dof, slot, text]


## Whether this event is this binding's **source**, pressed or released — the identity half, without the
## chord, because a release still has to clear the right source after the modifier was let go.
static func _is_source(event: InputEvent, text: String) -> bool:
	var binding := Binding.parse(text)
	if binding.is_empty():
		return false
	match String(binding["device"]):
		"keyboard":
			var key := event as InputEventKey
			return key != null and key.physical_keycode == int(binding["keycode"])
		"mouse":
			var mouse := event as InputEventMouseButton
			return mouse != null and mouse.button_index == int(binding["button"])
		"joypad":
			var pad := event as InputEventJoypadButton
			return (
				pad != null and binding.has("button")
				and pad.button_index == int(binding["button"])
				and Devices.name_of(pad.device) == String(binding["pad"])
			)
	return false


func _find_pointer_owner() -> String:
	for dof in DOFS:
		if String(_row(dof).get("mouse_movement", "off")) != "off":
			return dof
	return ""
