extends RefCounted
## The action registry and the binding text format: what a player can do, and how a way of doing it is
## written down. No runtime, no store, no consumers — this suite is about the two declarations.

const Actions := preload("res://addons/spacesim/input/actions.gd")
const Binding := preload("res://addons/spacesim/input/binding.gd")


func run(h, _root: Node) -> void:
	print("  input")
	_test_the_registry(h)
	_test_binding_text(h)
	_test_binding_matching(h)
	_test_what_is_not_a_binding(h)


## **Every action declares the three things the screen and the runtime need**, and its defaults are
## real bindings — a registry whose own defaults do not parse is a registry nobody has tried.
func _test_the_registry(h) -> void:
	var missing: Array = []
	var bad_kind: Array = []
	var no_category: Array = []
	var bad_default: Array = []
	for id in Actions.ids():
		var row := Actions.row(id)
		if not (row.has("label") and row.has("kind") and row.has("category") and row.has("defaults")):
			missing.append(id)
			continue
		if not Actions.KINDS.has(Actions.kind_of(id)):
			bad_kind.append("%s=%s" % [id, Actions.kind_of(id)])
		if not Actions.CATEGORIES.has(Actions.category_of(id)):
			no_category.append("%s=%s" % [id, Actions.category_of(id)])
		for text in Actions.defaults_of(id):
			if not Binding.is_valid(String(text)):
				bad_default.append("%s=%s" % [id, text])

	h.check(missing.is_empty(), "every action declares label, kind, category and defaults%s"
		% _detail(missing))
	h.check(bad_kind.is_empty(), "every kind is one of trigger, rate, level%s" % _detail(bad_kind))
	h.check(no_category.is_empty(), "every action is in a category the screen shows%s"
		% _detail(no_category))
	h.check(bad_default.is_empty(), "and every default binding parses%s" % _detail(bad_default))
	h.check(Actions.ids().size() == 16, "there are sixteen actions (%d)" % Actions.ids().size())

	# **Every category has something in it**, or the Bindings tab shows a heading over nothing.
	var empty: Array = []
	for category in Actions.CATEGORIES:
		if Actions.in_category(category).is_empty():
			empty.append(category)
	h.check(empty.is_empty(), "and no category is empty%s" % _detail(empty))

	# The four held actions are the only levels and rates; everything else is an edge. If that ever
	# changes, the per-frame path changes with it.
	var levels := Actions.in_category("Flight").filter(
		func(id: String) -> bool: return Actions.kind_of(id) == "level"
	)
	var rates := Actions.in_category("Flight").filter(
		func(id: String) -> bool: return Actions.kind_of(id) == "rate"
	)
	h.check(levels.size() == 2, "two levels: throttle up and down (%d)" % levels.size())
	h.check(rates.size() == 2, "two rates: roll left and right (%d)" % rates.size())


## **The text format round-trips**, which is what makes the file hand-editable: a value read from
## `bindings.cfg`, turned into parts and written back, is the same text it started as.
func _test_binding_text(h) -> void:
	var texts := ["W", "Alt+C", "Shift+Equal", "BracketLeft", "Tab", "1", "Space", "Escape"]
	var broken: Array = []
	for text in texts:
		if Binding.to_text(Binding.parse(text)) != text:
			broken.append("%s→%s" % [text, Binding.to_text(Binding.parse(text))])
	h.check(broken.is_empty(), "key bindings round-trip through parse and to_text%s" % _detail(broken))

	# Modifier order is fixed, so a chord written in any order stores one way.
	h.check(
		Binding.to_text(Binding.parse("Alt+Shift+W")) == "Shift+Alt+W",
		"and the modifiers are written in one order (%s)"
			% Binding.to_text(Binding.parse("Alt+Shift+W"))
	)
	# **The physical key, not the character.** `W` is stored as the key in the W position whatever
	# the layout calls it, which is why the text keeps the name rather than a character.
	var key := Binding.parse("W")
	h.check(
		String(key.get("device", "")) == "keyboard"
		and int(key.get("keycode", KEY_NONE)) == OS.find_keycode_from_string("W"),
		"a key parses to the keycode of its name (%s)" % str(key)
	)

	# The mouse's buttons, including the wheel — which is a button to Godot and so is bindable.
	var mouse := ["Mouse:Left", "Mouse:Right", "Mouse:Middle", "Mouse:WheelUp", "Mouse:WheelDown"]
	var broken_mouse: Array = []
	for text in mouse:
		if Binding.to_text(Binding.parse(text)) != text:
			broken_mouse.append(text)
	h.check(broken_mouse.is_empty(), "mouse buttons round-trip too%s" % _detail(broken_mouse))
	h.check(
		Binding.button_of("Mouse:WheelUp") == MOUSE_BUTTON_WHEEL_UP,
		"and the wheel is a button, not an axis"
	)
	h.check(
		Binding.to_text(Binding.parse("Shift+Mouse:Left")) == "Shift+Mouse:Left",
		"a mouse button takes modifiers like a key"
	)
	h.check(Binding.keycode_of("Mouse:Left") == KEY_NONE, "a mouse binding has no keycode")


## Matching is exact on the whole chord, and it reads the **physical** key.
func _test_binding_matching(h) -> void:
	var plain := _key_event("W")
	h.check(Binding.matches(plain, "W"), "W matches W")
	h.check(not Binding.matches(plain, "Alt+W"), "but not Alt+W, which is a different binding")
	h.check(not Binding.matches(plain, "Q"), "and not Q")

	var alt := _key_event("W", false, true, false, false)
	h.check(Binding.matches(alt, "Alt+W"), "Alt+W matches with Alt held")
	h.check(not Binding.matches(alt, "W"), "and plain W does not fire while Alt is held")

	var released := _key_event("W")
	released.pressed = false
	h.check(not Binding.matches(released, "W"), "a release is not a press")

	var echo := _key_event("W")
	echo.echo = true
	h.check(not Binding.matches(echo, "W"), "and neither is a key repeating while held")

	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	h.check(Binding.matches(click, "Mouse:Left"), "a click matches Mouse:Left")
	h.check(not Binding.matches(click, "Mouse:Right"), "and not Mouse:Right")
	h.check(not Binding.matches(plain, "Mouse:Left"), "a key event never matches a mouse binding")
	h.check(not Binding.matches(click, "W"), "and a click never matches a key binding")


## Anything else is **not a binding**, and says so instead of binding something surprising.
func _test_what_is_not_a_binding(h) -> void:
	var nonsense := [
		"", "Nonsense", "Alt+", "+W", "W++Alt", "Ctrl+Shift", "Mouse:", "Mouse:Side",
		# A modifier's name is a valid keycode, so these would otherwise bind a modifier as the key.
		"Alt", "Ctrl", "Shift", "Meta",
	]
	var accepted: Array = []
	for text in nonsense:
		if Binding.is_valid(text):
			accepted.append(text)
	h.check(accepted.is_empty(), "nonsense is not a binding%s" % _detail(accepted))

	# **The joypad forms are reserved and rejected.** A file written for a pad must not silently bind
	# something else on a keyboard, and the grammar is fixed before the device arrives.
	var joypad := [
		"Joy:PS4 Controller/Button:A",
		"Joy:PS4 Controller/Axis:LEFT_X",
		"Joy:/Button:A",
	]
	var taken: Array = []
	for text in joypad:
		if Binding.is_valid(text):
			taken.append(text)
	h.check(taken.is_empty(), "a joypad binding is refused until pads land%s" % _detail(taken))


## A key event, by the name the binding text uses. A fresh instance each call, so a caller can mutate
## its `pressed` or `echo` without affecting another check.
static func _key_event(
	key_name: String, shift := false, alt := false, ctrl := false, meta := false
) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = OS.find_keycode_from_string(key_name)
	event.pressed = true
	event.shift_pressed = shift
	event.alt_pressed = alt
	event.ctrl_pressed = ctrl
	event.meta_pressed = meta
	return event


static func _detail(items: Array) -> String:
	return "" if items.is_empty() else " (%s)" % str(items)
