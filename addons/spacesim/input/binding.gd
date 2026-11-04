class_name SpacesimBinding
extends RefCounted
## One way to press one action, written as text so the file stays readable and hand-editable.
##
## `Alt+C`, `W`, `BracketLeft` — a **physical key** with modifiers, which is what the settings file has
## always stored — and `Mouse:Left`, `Mouse:WheelUp` for the mouse's buttons, with the same optional
## modifier prefixes.
##
## **A key binding stores a physical key, not a character**, so `W` stays under the same finger on a
## keyboard whose layout puts A somewhere else. The name is whatever [method OS.get_keycode_string]
## produces and [method OS.find_keycode_from_string] parses back, so the two agree by construction
## rather than by a table we would have to maintain.
##
## ## What is not here yet
##
## A joypad form is **reserved and rejected**: `Joy:<device>/Button:A` and `Joy:<device>/Axis:LEFT_X`
## parse to nothing, so a file written for a pad can never silently bind something else. The grammar
## they will use — including `abs`, `min=`, `max=` and `dead=` for an axis — is in the vault's
## *Input — Actions and Bindings* §3; nothing here needs changing to accept it, because an unrecognised
## text is simply not a binding.

const MODIFIER_ORDER := ["Meta", "Ctrl", "Shift", "Alt"]

## The mouse's buttons, by the names the file uses. **`WheelUp` and `WheelDown` are buttons to Godot**
## (`MOUSE_BUTTON_WHEEL_UP` is 4), which is how a scroll can be bound to an action at all.
const MOUSE_BUTTONS := {
	"Left": MOUSE_BUTTON_LEFT,
	"Right": MOUSE_BUTTON_RIGHT,
	"Middle": MOUSE_BUTTON_MIDDLE,
	"WheelUp": MOUSE_BUTTON_WHEEL_UP,
	"WheelDown": MOUSE_BUTTON_WHEEL_DOWN,
}

const MOUSE_PREFIX := "Mouse:"

## **A modifier's own name is also a valid keycode**, so `Alt` alone parses as the Alt key. Binding a
## modifier as the key is never wanted and is almost always a typo (`Ctrl+Shift` meant as a chord), so
## these are refused as the key part. A modifier still works in its normal position, in front.
const MODIFIER_KEYS := [KEY_ALT, KEY_CTRL, KEY_SHIFT, KEY_META]


## A binding's parts, or an empty dictionary when the text is not one.
##
## Returns `{"device": "keyboard", "keycode": int, "alt": …, …}` or
## `{"device": "mouse", "button": int, "alt": …, …}`.
static func parse(text: String) -> Dictionary:
	# **Empty parts are kept and rejected**, so a stray separator is not silently forgiven: `+W` used
	# to bind `W`, which is a typo becoming a binding.
	var parts := text.split("+", true)
	if parts.is_empty():
		return {}
	for part in parts:
		if part.strip_edges().is_empty():
			return {}

	var source := parts[parts.size() - 1].strip_edges()
	var binding := {}
	if source.begins_with(MOUSE_PREFIX):
		var named := source.substr(MOUSE_PREFIX.length())
		if not MOUSE_BUTTONS.has(named):
			return {}
		binding = {"device": "mouse", "button": int(MOUSE_BUTTONS[named])}
	else:
		var keycode := OS.find_keycode_from_string(source)
		if keycode == KEY_NONE or MODIFIER_KEYS.has(keycode):
			return {}
		binding = {"device": "keyboard", "keycode": keycode}

	binding["alt"] = false
	binding["ctrl"] = false
	binding["shift"] = false
	binding["meta"] = false
	for index in range(parts.size() - 1):
		match parts[index].strip_edges().to_lower():
			"alt":
				binding["alt"] = true
			"ctrl", "control":
				binding["ctrl"] = true
			"shift":
				binding["shift"] = true
			"meta", "super", "cmd":
				binding["meta"] = true
			_:
				return {}
	return binding


static func is_valid(text: String) -> bool:
	return not parse(text).is_empty()


## A binding written the way the store keeps it. The inverse of [method parse], so a round trip is
## identity for anything `parse` accepts.
static func to_text(binding: Dictionary) -> String:
	var parts: Array[String] = []
	for name in MODIFIER_ORDER:
		if bool(binding.get(name.to_lower(), false)):
			parts.append(name)
	if String(binding.get("device", "")) == "mouse":
		for name in MOUSE_BUTTONS:
			if int(MOUSE_BUTTONS[name]) == int(binding.get("button", -1)):
				parts.append(MOUSE_PREFIX + name)
				break
	else:
		parts.append(OS.get_keycode_string(int(binding.get("keycode", KEY_NONE))))
	return "+".join(parts)


## The text for an event — **the inverse of [method matches]**, so a capture can store what it saw.
##
## Empty for anything that is not a key or a mouse button: the two directions of one conversion belong
## together, and a text that cannot come back must not be produced here.
static func from_event(event: InputEvent) -> String:
	if event is InputEventKey:
		var key: InputEventKey = event
		return to_text({
			"device": "keyboard",
			"keycode": key.physical_keycode,
			"alt": key.alt_pressed,
			"ctrl": key.ctrl_pressed,
			"shift": key.shift_pressed,
			"meta": key.meta_pressed,
		})
	if event is InputEventMouseButton:
		var mouse: InputEventMouseButton = event
		return to_text({
			"device": "mouse",
			"button": mouse.button_index,
			"alt": mouse.alt_pressed,
			"ctrl": mouse.ctrl_pressed,
			"shift": mouse.shift_pressed,
			"meta": mouse.meta_pressed,
		})
	return ""


## The key a keyboard binding uses, or `KEY_NONE`. For asking whether it is held down.
static func keycode_of(text: String) -> int:
	var binding := parse(text)
	if binding.is_empty() or String(binding["device"]) != "keyboard":
		return KEY_NONE
	return int(binding["keycode"])


## The button a mouse binding uses, or `-1`.
static func button_of(text: String) -> int:
	var binding := parse(text)
	if binding.is_empty() or String(binding["device"]) != "mouse":
		return -1
	return int(binding["button"])


## Whether this event is this binding. **Modifiers must match exactly**, so `W` does not fire while
## Alt is held — a binding is the whole chord, not a subset of one.
static func matches(event: InputEvent, text: String) -> bool:
	var binding := parse(text)
	if binding.is_empty():
		return false

	if String(binding["device"]) == "keyboard":
		var key := event as InputEventKey
		# `echo` is a held key repeating; an action fires on the press, not sixty times a second.
		if key == null or not key.pressed or key.echo:
			return false
		if key.physical_keycode != int(binding["keycode"]):
			return false
	else:
		var mouse := event as InputEventMouseButton
		if mouse == null or not mouse.pressed:
			return false
		if mouse.button_index != int(binding["button"]):
			return false

	return (
		event.alt_pressed == bool(binding["alt"])
		and event.ctrl_pressed == bool(binding["ctrl"])
		and event.shift_pressed == bool(binding["shift"])
		and event.meta_pressed == bool(binding["meta"])
	)
