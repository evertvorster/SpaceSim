extends RefCounted
## The action registry and the binding text format: what a player can do, and how a way of doing it is
## written down. No runtime, no store, no consumers — this suite is about the two declarations.

const Actions := preload("res://addons/spacesim/input/actions.gd")
const Binding := preload("res://addons/spacesim/input/binding.gd")
const Store := preload("res://addons/spacesim/input/bindings_store.gd")
const InputMapScript := preload("res://addons/spacesim/input/input_map.gd")
const Profile := preload("res://addons/spacesim/input/axis_profile.gd")
const Devices := preload("res://addons/spacesim/input/devices.gd")

const TEST_DIR := "/tmp/spacesim-input-test"


func run(h, _root: Node) -> void:
	print("  input")
	_test_the_registry(h)
	_test_binding_text(h)
	_test_binding_matching(h)
	_test_what_is_not_a_binding(h)
	_test_the_store(h)
	_test_the_legacy_import(h)
	_test_the_runtime(h)
	_test_the_axis_profile(h)
	_test_joypad_matching(h)


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
	h.check(Actions.ids().size() == 20, "there are twenty actions (%d)" % Actions.ids().size())

	# **Every category has something in it**, or the Bindings tab shows a heading over nothing.
	var empty: Array = []
	for category in Actions.CATEGORIES:
		if Actions.in_category(category).is_empty():
			empty.append(category)
	h.check(empty.is_empty(), "and no category is empty%s" % _detail(empty))

	# **The four held actions are the only four that are read every frame**; everything else is an
	# edge. If that ever changes, what `_physics_process` reads changes with it.
	var rates := Actions.in_category("Flight").filter(
		func(id: String) -> bool: return Actions.kind_of(id) == "rate"
	)
	var levels := Actions.ids().filter(
		func(id: String) -> bool: return Actions.kind_of(id) == "level"
	)
	h.check(
		rates.size() == 8,
		"eight rates: throttle up/down, roll and the four turning actions a stick needs (%d)"
			% rates.size()
	)
	h.check(levels.is_empty(), "and no levels yet: a level is what a stick sets directly%s"
		% _detail(levels))


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

	# **A joypad form names a control Godot knows**, so an unknown name is not a binding — and the names
	# come from `SpacesimDevices`, the only place the engine's own vocabulary exists.
	var pad := Binding.parse("Joy:PS4 Controller/Button:A")
	h.check(
		String(pad.get("device", "")) == "joypad" and String(pad.get("pad", "")) == "PS4 Controller",
		"a pad button parses to its device and button (%s)" % str(pad)
	)
	h.check(
		Binding.to_text(pad) == "Joy:PS4 Controller/Button:A",
		"and round-trips even though the device name has a space (%s)" % Binding.to_text(pad)
	)
	h.check(
		int(Binding.parse("Joy:PS4 Controller/Axis:LEFT_X").get("axis", -1)) == 0,
		"an axis parses to its index, by Godot's own name"
	)
	h.check(
		Binding.parse("Joy:PS4 Controller/Button:Nonsense").is_empty(),
		"a button name Godot does not have is not a binding"
	)
	h.check(
		Binding.parse("Joy:PS4 Controller/Axis:SIDEWAYS").is_empty(),
		"and neither is an axis that does not exist"
	)
	h.check(Binding.parse("Joy:/Button:A").is_empty(), "nor a binding with no device")

	h.check(Devices.axis_index("LEFT_X") == 0 and Devices.axis_index("nope") == -1, "axis names resolve")
	h.check(Devices.button_index("A") == 0 and Devices.button_index("nope") == -1, "button names resolve")




func _test_the_store(h) -> void:
	_clean()
	var path := TEST_DIR.path_join("bindings.cfg")

	var store := Store.new()
	store.open(path)
	h.check(store.of("throttle_up") == ["Shift+Equal"], "with no file, an action is its registry default")
	h.check(not store.has_changes(), "and nothing is staged")
	h.check(not FileAccess.file_exists(path), "opening writes nothing")

	h.check(store.stage("throttle_up", ["W"]), "a valid binding stages")
	h.check(store.of("throttle_up") == ["W"], "and is what the action now reads")
	h.check(store.has_changes(), "which counts as a change")
	h.check(not FileAccess.file_exists(path), "and is still not written")
	store.discard()
	h.check(not store.has_changes(), "discarding clears it")
	h.check(store.of("throttle_up") == ["Shift+Equal"], "and restores what stood")

	# A typo is refused at the store, not discovered at the next keypress.
	h.check(not store.stage("throttle_up", ["Nonsense"]), "an unparseable binding is refused")
	h.check(not store.stage("no_such_action", ["W"]), "and so is an action that does not exist")

	# **An empty list unbinds**, which is different from an absent key — that is what lets a player
	# clear an action rather than only change it.
	store.stage("cycle_target", [])
	h.check(store.of("cycle_target").is_empty(), "an empty list unbinds the action")

	store.stage("roll_left", ["BracketLeft", "Q"])
	h.check(store.of("roll_left") == ["BracketLeft", "Q"], "and an action can have several bindings")

	var written := store.apply()
	h.check(written == Actions.ids().size(), "applying writes every action (%d)" % written)
	h.check(FileAccess.file_exists(path), "and creates the file")
	h.check(not store.has_changes(), "with nothing left staged")

	var reread := Store.new()
	reread.open(path)
	h.check(reread.of("roll_left") == ["BracketLeft", "Q"], "a second open reads the two bindings back")
	h.check(reread.of("cycle_target").is_empty(), "including an action that was unbound")
	h.check(reread.of("throttle_up") == ["Shift+Equal"], "and the ones that were never touched")

	# A device's own section overrides the default table, and survives an apply untouched.
	var file := ConfigFile.new()
	file.load(path)
	file.set_value("bindings.PS4 Controller", "throttle_up", "W")
	file.save(path)
	var with_pad := Store.new()
	with_pad.open(path)
	h.check(with_pad.of("throttle_up") == ["Shift+Equal"], "the default table still stands")
	h.check(
		with_pad.of("throttle_up", "PS4 Controller") == ["W"],
		"and a device's section overrides it for that device"
	)
	with_pad.stage("roll_right", ["E"])
	with_pad.apply()
	var after := ConfigFile.new()
	after.load(path)
	h.check(
		after.has_section_key("bindings.PS4 Controller", "throttle_up"),
		"applying carries a device section across untouched"
	)
	_clean()


## **The one-time import from `settings.cfg`**, where an action's binding was a settings key of the same
## name under a `bindings.` prefix. It writes nothing: the imported values live in memory until Apply.
func _test_the_legacy_import(h) -> void:
	_clean()
	var settings_path := TEST_DIR.path_join("settings.cfg")
	var bindings_path := TEST_DIR.path_join("bindings.cfg")

	var legacy := ConfigFile.new()
	legacy.set_value("bindings", "throttle_up", "W")
	legacy.set_value("bindings", "roll_left", "Nonsense")
	legacy.set_value("video", "mode", "windowed")
	SpacesimXdg.ensure_directory(TEST_DIR)
	legacy.save(settings_path)

	var store := Store.new()
	store.open(bindings_path, settings_path)
	h.check(store.of("throttle_up") == ["W"], "a legacy binding is imported")
	h.check(
		store.of("roll_left") == Actions.defaults_of("roll_left"),
		"an unparseable one leaves the registry's default in place"
	)
	h.check(
		store.problems.size() == 1 and String(store.problems[0]).begins_with("roll_left"),
		"and is reported rather than swallowed (%s)" % str(store.problems)
	)
	h.check(store.of("cycle_target") == Actions.defaults_of("cycle_target"),
		"an action the legacy file never had keeps its default")
	h.check(not FileAccess.file_exists(bindings_path), "and the import writes nothing")

	store.apply()
	h.check(FileAccess.file_exists(bindings_path), "the first Apply creates the file")
	var reread := Store.new()
	reread.open(bindings_path, settings_path)
	h.check(reread.of("throttle_up") == ["W"], "with the imported value in it")
	h.check(reread.problems.is_empty(), "and no problem re-reported, because nothing is re-imported")
	_clean()


## The runtime: edges, held state, and the hint text.
func _test_the_runtime(h) -> void:
	_clean()
	var store := Store.new()
	store.open(TEST_DIR.path_join("bindings.cfg"))
	var runtime = InputMapScript.new(store)

	# --- an edge fires once, on the press
	var press := _key_event("Equal", true, false, false, false)
	h.check(runtime.triggered(press, "throttle_up"), "a chord matches its action")
	h.check(not runtime.triggered(press, "throttle_down"), "and not another one")
	var release := _key_event("Equal", true, false, false, false)
	release.pressed = false
	h.check(not runtime.triggered(release, "throttle_up"), "a release is not a trigger")

	# --- held state is tracked from what it has been fed
	h.check(not runtime.held("throttle_up"), "nothing is held to begin with")
	runtime.feed(press)
	h.check(runtime.held("throttle_up"), "a press holds the action")
	h.check(not runtime.held("throttle_down"), "and only that action")
	runtime.feed(release)
	h.check(not runtime.held("throttle_up"), "a release lets it go")

	# Two bindings on one action are independent sources: letting one go does not release the other.
	store.stage("roll_left", ["BracketLeft", "Q"])
	runtime.feed(_key_event("BracketLeft"))
	runtime.feed(_key_event("Q"))
	h.check(runtime.held("roll_left"), "either of two bindings holds the action")
	runtime.feed(_released(_key_event("Q")))
	h.check(runtime.held("roll_left"), "and releasing one leaves the other held")
	runtime.feed(_released(_key_event("BracketLeft")))
	h.check(not runtime.held("roll_left"), "releasing both lets it go")

	# **A screen that swallows a release must not leave a key held for ever.**
	runtime.feed(_key_event("BracketLeft"))
	h.check(runtime.held("roll_left"), "held again")
	runtime.release_all()
	h.check(not runtime.held("roll_left"), "and release_all forgets everything")

	# --- the floor is a button, and it can be fed like a key
	var floor_binding := InputEventMouseButton.new()
	floor_binding.button_index = MOUSE_BUTTON_LEFT
	floor_binding.pressed = true
	store.stage("cycle_target", ["Mouse:Left"])
	h.check(runtime.triggered(floor_binding, "cycle_target"), "a mouse button triggers an action")
	runtime.feed(floor_binding)
	h.check(runtime.held("cycle_target"), "and holds it like a key")

	# --- the hint text, which the HUD prints
	h.check(runtime.hint("throttle_up") == "Shift+Equal", "the hint is the action's binding text")
	h.check(runtime.hint("no_such_action").is_empty(), "and empty for an action that does not exist")
	store.stage("bodies_toggle", ["Mouse:Middle", "P"])
	h.check(runtime.hint("bodies_toggle") == "P", "a keyboard binding is preferred for a hint")
	store.stage("bodies_toggle", ["Mouse:Middle"])
	h.check(
		runtime.hint("bodies_toggle") == "Mouse:Middle",
		"and the first binding is used when there is no keyboard one"
	)
	_clean()


## **Shaping an axis**: the ends of its travel, where it rests, and what the middle is worth.
func _test_the_axis_profile(h) -> void:
	var profile := Profile.new()
	h.check(
		is_equal_approx(profile.shape(-1.0), -1.0) and is_equal_approx(profile.shape(1.0), 1.0),
		"with no changes, the ends of the travel are −1 and +1"
	)
	h.check(
		is_equal_approx(profile.shape(0.0), 0.0),
		"and the middle is zero, because the deadband swallows it"
	)

	# **The rescale is the part worth checking**: just outside the band the value is small but not a step,
	# and full deflection is still full deflection.
	h.check(
		profile.shape(0.15) == 0.0 and profile.shape(0.1501) < 0.01,
		"an axis in the deadband reads zero (%f)" % profile.shape(0.1501)
	)
	h.check(
		is_equal_approx(profile.shape(1.0), 1.0),
		"and full deflection is still 1, not 1 − deadband (%f)" % profile.shape(1.0)
	)
	h.check(
		is_equal_approx(Profile.new().shape(0.575), 0.5),
		"the band is rescaled into the rest of the travel (%f)" % Profile.new().shape(0.575)
	)

	# A band of zero leaves the axis linear.
	var sharp := Profile.new()
	sharp.deadband = 0.0
	h.check(is_equal_approx(sharp.shape(0.25), 0.25), "with no band the axis is linear (%f)" % sharp.shape(0.25))

	# **An asymmetric axis maps onto −1 … +1 exactly**: its own ends are the ends, and its own centre is the
	# centre, even though they are not a midpoint's worth apart.
	var worn := Profile.new()
	worn.low = -0.95
	worn.high = 0.88
	worn.centre = 0.03
	worn.deadband = 0.0
	h.check(
		is_equal_approx(worn.shape(-0.95), -1.0) and is_equal_approx(worn.shape(0.88), 1.0),
		"a worn, asymmetric stick reaches both ends (%f, %f)" % [worn.shape(-0.95), worn.shape(0.88)]
	)
	h.check(
		is_equal_approx(worn.shape(0.03), 0.0),
		"and rests where it was told it rests (%f)" % worn.shape(0.03)
	)

	# The text form round-trips, and a bad number falls back to that field alone.
	var text := worn.to_text()
	var back := Profile.from_text(text)
	h.check(back.to_text() == text, "the profile round-trips through its text (%s)" % text)
	var half := Profile.from_text("-0.5, nonsense, 0.0, 0.15")
	h.check(
		is_equal_approx(half.low, -0.5) and is_equal_approx(half.high, 1.0),
		"one unreadable number keeps the default for that field alone (%s)" % half.to_text()
	)

	# What cannot make sense is refused.
	var bad := Profile.new()
	bad.low = 0.5
	bad.high = -0.5
	h.check(not bad.is_sane(), "travel that runs backwards is refused")
	# **The centre may sit at an end** — a trigger rests at the bottom of its travel — but not outside it.
	var at_end := Profile.default_for("TRIGGER_LEFT")
	h.check(
		is_equal_approx(at_end.centre, 0.0) and is_equal_approx(at_end.low, 0.0) and at_end.is_sane(),
		"a trigger's default is 0 … +1 and its rest is legal at the bottom (%s)" % at_end.to_text()
	)
	var outside := Profile.default_for("TRIGGER_LEFT")
	outside.centre = -0.5
	h.check(not outside.is_sane(), "a centre outside the travel is refused")
	var band := Profile.new()
	band.deadband = 1.0
	h.check(not band.is_sane(), "and a band of one, where nothing could be deflected")

	# A calibration keeps the typed centre and band, and takes only the travel.
	var calibrated: Profile = Profile.new()
	calibrated.centre = 0.2
	calibrated.deadband = 0.1
	calibrated = calibrated.with_travel(-0.92, 0.97)
	h.check(
		is_equal_approx(calibrated.low, -0.92) and is_equal_approx(calibrated.high, 0.97)
		and is_equal_approx(calibrated.centre, 0.2) and is_equal_approx(calibrated.deadband, 0.1),
		"and a calibration replaces the travel without touching what was typed"
	)


## A pad's button matches its binding — checked against the pad that is attached, or not exercised at all,
## because a test cannot conjure hardware and should not pretend to.
func _test_joypad_matching(h) -> void:
	var pads := Devices.connected()
	if pads.is_empty():
		h.check(true, "(no gamepad attached: pad matching is not exercised)")
		return
	var device := int(pads[0])
	var named := Devices.name_of(device)
	var event := InputEventJoypadButton.new()
	event.device = device
	event.button_index = JOY_BUTTON_A
	event.pressed = true
	h.check(Binding.matches(event, "Joy:%s/Button:A" % named), "a pad button matches its own binding")
	h.check(
		not Binding.matches(event, "Joy:Some Other Pad/Button:A"),
		"and not one that names another device"
	)
	event.pressed = false
	h.check(not Binding.matches(event, "Joy:%s/Button:A" % named), "a release is not a press")

	# **Detecting an axis is watching for the biggest change**, outside its deadband — there is no event to
	# catch, so the reading itself has to be the evidence.
	var profile := Profile.default_for("LEFT_X")
	var previous := {
		"LEFT_X": 0.0, "LEFT_Y": 0.0, "RIGHT_X": 0.0, "RIGHT_Y": 0.0,
		"TRIGGER_LEFT": 0.0, "TRIGGER_RIGHT": 0.0,
	}
	# Whatever the stick is doing now, it is not what it was a moment ago unless it moved by that much.
	var moved: Array = Devices.most_moved(device, previous, func(_named: String) -> Profile: return profile)
	h.check(moved.size() == 2, "most_moved answers an axis and a size (%s)" % str(moved))
	h.check(
		int(moved[0]) == -1 or absf(float(moved[1])) >= Devices.MOVED_ENOUGH,
		"and only reports an axis that moved by more than the delta threshold (%s)" % str(moved)
	)
	# A reading that has not changed reports nothing, whatever the stick is held at.
	var still := {}
	for index in Devices.AXIS_NAMES.size():
		still[Devices.AXIS_NAMES[index]] = Devices.axis(device, index)
	var quiet: Array = Devices.most_moved(device, still, func(_named: String) -> Profile: return profile)
	h.check(int(quiet[0]) == -1, "an unchanged axis is not a movement (%s)" % str(quiet))

	# **An axis is a position, not an event**: nothing matches it, and `value()` is where it is read.
	var motion := InputEventJoypadMotion.new()
	motion.device = device
	motion.axis = JOY_AXIS_LEFT_X
	motion.axis_value = 0.8
	h.check(
		not Binding.matches(motion, "Joy:%s/Axis:LEFT_X" % named),
		"an axis never matches an event"
	)


static func _released(event: InputEventKey) -> InputEventKey:
	event.pressed = false
	return event


static func _clean() -> void:
	OS.execute("rm", PackedStringArray(["-rf", TEST_DIR]))


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
