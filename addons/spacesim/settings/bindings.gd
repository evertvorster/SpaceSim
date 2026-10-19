class_name SpacesimBindings
extends RefCounted
## Input bindings, stored as text: `Alt+C`, `W`, `BracketLeft`.
##
## Text rather than a raw keycode so the file stays readable and hand-editable. The key name is
## whatever [method OS.get_keycode_string] produces and [method OS.find_keycode_from_string] parses
## it back, so the two agree by construction; modifiers are written as prefixes.
##
## Matching uses the **physical** key, so WASD stays under the same fingers on a keyboard whose
## layout puts A somewhere else. That is why a binding stores a key rather than a character.

const MODIFIER_ORDER := ["Meta", "Ctrl", "Shift", "Alt"]


## A binding's parts, or an empty dictionary when the text is not a binding.
static func parse(text: String) -> Dictionary:
	var parts := text.split("+", false)
	if parts.is_empty():
		return {}
	var keycode := OS.find_keycode_from_string(parts[parts.size() - 1].strip_edges())
	if keycode == KEY_NONE:
		return {}

	var binding := {"keycode": keycode, "alt": false, "ctrl": false, "shift": false, "meta": false}
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


## The key a binding uses, or KEY_NONE. For asking whether it is held down.
static func keycode_of(text: String) -> int:
	var binding := parse(text)
	if binding.is_empty():
		return KEY_NONE
	return int(binding["keycode"])


## Whether a key event is this binding. Modifiers must match exactly, so `W` does not fire while
## Alt is held.
static func matches(event: InputEventKey, text: String) -> bool:
	if not event.pressed or event.echo:
		return false
	var binding := parse(text)
	if binding.is_empty():
		return false
	if event.physical_keycode != int(binding["keycode"]):
		return false
	return (
		event.alt_pressed == bool(binding["alt"])
		and event.ctrl_pressed == bool(binding["ctrl"])
		and event.shift_pressed == bool(binding["shift"])
		and event.meta_pressed == bool(binding["meta"])
	)


## A binding written the way the settings file stores it.
static func from_event(event: InputEventKey) -> String:
	return format(
		{
			"keycode": event.physical_keycode,
			"alt": event.alt_pressed,
			"ctrl": event.ctrl_pressed,
			"shift": event.shift_pressed,
			"meta": event.meta_pressed,
		}
	)


static func format(binding: Dictionary) -> String:
	var parts: Array[String] = []
	for name in MODIFIER_ORDER:
		if bool(binding.get(name.to_lower(), false)):
			parts.append(name)
	parts.append(OS.get_keycode_string(int(binding.get("keycode", KEY_NONE))))
	return "+".join(parts)
