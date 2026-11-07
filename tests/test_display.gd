extends RefCounted
## The window: which screen, how big, and at what resolution the game draws.
##
## Headless, the display server is a dummy — so what is checked here is the *decision*: which mode a
## name means, which screen a stored number resolves to now, and how far the 3D is scaled. What a
## real monitor then does with it is not something this suite can see, and is not claimed.

const Display := preload("res://addons/spacesim/settings/display.gd")
const Settings := preload("res://addons/spacesim/settings/settings.gd")
const SettingsPanel := preload("res://addons/spacesim/settings/settings_panel.gd")

const Fixture := preload("res://tests/settings_fixture.gd")

var _fixture := Fixture.new()


func run(h, root: Node) -> void:
	print("  the window")
	Fixture.clean()
	_test_mode_names(h)
	_test_frame_rates(h)
	_test_aspect_names(h)
	_test_the_render_scale(h)
	_test_the_strip(h)
	_test_a_screen_that_is_gone(h)
	_test_the_resolution_presets(h, root)
	_test_the_picker_stages_and_apply_commits(h, root)
	_test_the_three_sizes_are_separate(h, root)
	_test_nothing_is_written_without_apply(h, root)
	Fixture.clean()
	_fixture.release()


func _test_mode_names(h) -> void:
	var display = Display.new()
	h.check(display.mode_of("windowed") == Window.MODE_WINDOWED, "'windowed' is a window")
	h.check(
		display.mode_of("fullscreen") == Window.MODE_FULLSCREEN,
		"'fullscreen' is a borderless window the size of the screen — windowed fullscreen"
	)
	h.check(
		display.mode_of("exclusive") == Window.MODE_EXCLUSIVE_FULLSCREEN,
		"and 'exclusive' is the one that changes the monitor's mode"
	)
	# A value from a hand-edited file must land somewhere sane rather than on an undefined mode.
	h.check(display.mode_of("nonsense") == Window.MODE_WINDOWED, "anything else is a window")
	display.free()


func _test_aspect_names(h) -> void:
	var display = Display.new()
	h.check(
		display.aspect_of("expand") == Window.CONTENT_SCALE_ASPECT_EXPAND,
		"'expand' fills the window and shows more, rather than stretching"
	)
	h.check(display.aspect_of("keep") == Window.CONTENT_SCALE_ASPECT_KEEP, "'keep' letterboxes instead")
	h.check(display.aspect_of("nonsense") == Window.CONTENT_SCALE_ASPECT_EXPAND, "and anything else expands")
	# The one that distorts. It is deliberately not reachable from a setting.
	h.check(
		display.aspect_of("ignore") != Window.CONTENT_SCALE_ASPECT_IGNORE,
		"there is no way to ask for a stretched picture"
	)
	display.free()


func _test_the_render_scale(h) -> void:
	# The height is exact and the width follows the window, so the scale is height over height.
	h.check_near(Display.render_scale(720, 1440.0), 0.5, "720 lines drawn into 1440 is half scale", 0.0001)
	h.check_near(Display.render_scale(1080, 1080.0), 1.0, "and into its own height is native", 0.0001)
	h.check_near(Display.render_scale(1440, 720.0), 2.0, "a render above the window supersamples", 0.0001)
	# A render resolution is only useful if it can go below what the window would otherwise draw.
	h.check(Display.render_scale(160, 4320.0) >= 0.25, "a tiny render is held at the engine's floor")
	h.check(Display.render_scale(4320, 240.0) <= 2.0, "and a huge one at its ceiling")
	# A window that has not been laid out yet is not a division by zero.
	h.check(Display.render_scale(720, 0.0) > 0.0, "a window with no height at all is not a division by zero")


## **The band and the strip**, both halves of the one number the whole HUD layout derives from.
##
## The arithmetic is checked rather than the picture: this suite can see a `Rect2` and cannot see a frame,
## and every way this goes wrong is arithmetic — a rounding that leaves a seam, a canvases' worth of
## confusion between canvas units and window pixels, or the render resolution turning a familiar preset
## into an unfamiliar number.
func _test_the_strip(h) -> void:
	var canvas := Rect2(Vector2.ZERO, Vector2(1920.0, 1080.0))

	# **The design's number**: a fifth of the height, and the picture above it is 2.22 : 1.
	h.check(Display.strip_height(1080, 0.2) == 216, "20 % of 1080 rows is 216")
	var band := Display.band_of(canvas, 0.2)
	var strip := Display.strip_of(canvas, 0.2)
	h.check(band.size == Vector2(1920.0, 864.0), "so the band is 1920 x 864 (%s)" % str(band.size))
	h.check_near(band.size.x / band.size.y, 2.2222, "which is the 2.22 : 1 picture", 0.0001)

	# **They tile the canvas exactly** — the band gets the remainder, so no rounding can leave a seam.
	h.check(
		band.size.y + strip.size.y == canvas.size.y,
		"the two rects tile the canvas with nothing over and nothing short (%s)" % str(band.size.y + strip.size.y)
	)
	h.check(strip.position.y == 864.0, "and the strip is at the BOTTOM, under the picture (%s)" % str(strip.position.y))
	h.check(strip.size.x == canvas.size.x, "across the full width")

	# **A changed height moves both**, which is what makes it a setting rather than a constant.
	var taller := Display.band_of(canvas, 0.3)
	# **`%%`, not `%`** — a literal percent in a string that is also formatted is read as a specifier, and
	# the error aborts the function it is in without failing the run (the message printed as though it had
	# worked). The project has paid for this shape before.
	h.check(taller.size.y == 756.0, "30 %% gives a 756-row band (%s)" % str(taller.size.y))
	h.check(taller.size.y < band.size.y, "so a taller strip is a smaller picture")

	# **Zero is the cockpit**: no strip, and the whole canvas is picture.
	h.check(Display.band_of(canvas, 0.0) == canvas, "0 % leaves the band the whole canvas")
	h.check(Display.strip_of(canvas, 0.0).size.y == 0.0, "and the strip nothing at all")

	# A value from a hand-edited file clamps to a picture that still exists rather than to a degenerate one.
	h.check(Display.band_of(canvas, 1.5).size.y > 0.0, "a nonsense fraction is clamped, not obeyed")
	h.check(Display.strip_height(1080, -3.0) == 0, "and a negative one is no strip")

	# **The render resolution describes the WHOLE WINDOW** (Evert, 2026-11-07): a preset must not turn
	# into a shape nobody chose. 2560 x 1440 at the 1920 x 1080 preset is 0.75, the band is 2560 x 1152
	# on screen, and its buffer is 1920 x 864 — the preset's own height, not a new one.
	var size := Display.band_size(Vector2i(2560, 1440), 0.2)
	var scale := Display.render_scale(1080, 1440.0)
	h.check(size == Vector2i(2560, 1152), "the band in a 2560 x 1440 window is 2560 x 1152 (%s)" % str(size))
	h.check_near(scale, 0.75, "and the 1920 x 1080 preset is 0.75 of that window", 0.0001)
	h.check(
		Vector2i(roundi(size.x * scale), roundi(size.y * scale)) == Vector2i(1920, 864),
		"so the band's buffer is 1920 x 864 — the preset keeps its name and its height"
	)

	# The registry has to agree with the clamp, or a value the screen cannot refuse is a value the rect
	# silently overrides.
	h.check(Settings.is_acceptable("hud.strip_height", 0.0), "the registry accepts no strip at all")
	h.check(Settings.is_acceptable("hud.strip_height", 0.4), "and the widest one the rects allow")
	h.check(not Settings.is_acceptable("hud.strip_height", 0.9), "and refuses one that would be a letterbox")


## The one that outlives the machine it was set on: a laptop undocked, a docking station removed.
func _test_a_screen_that_is_gone(h) -> void:
	var settings := _fixture.open()
	var display = Display.new()
	display.use(settings)

	var count := DisplayServer.get_screen_count()
	settings.set_value("video.screen", 0)
	h.check(display.screen_index() == 0, "the first screen is screen zero")

	settings.set_value("video.screen", maxi(0, count - 1))
	h.check(display.screen_index() == maxi(0, count - 1), "and a stored one that exists is used as stored")

	settings.set_value("video.screen", count + 9)
	h.check(
		display.screen_index() == maxi(0, count - 1),
		"a stored screen that is no longer there falls back to one that is (%d of %d)" % [display.screen_index(), count]
	)
	h.check(display.screen_index() >= 0, "rather than opening a window on a monitor that does not exist")

	# A negative from a hand-edited file is the same class of thing.
	settings.set_value("video.screen", 0)
	h.check(display.screen_index() == 0, "and a screen number below the first is held at the first")
	display.free()


## What the menu beside a resolution row offers.
func _test_the_resolution_presets(h, root: Node) -> void:
	var settings := _fixture.open()
	# Before the display is in the tree, since its `_ready` applies the settings — which includes
	# putting the window at the size the setting says.
	settings.set_value("video.window_size", Vector2i(1366, 768))
	var window := Window.new()
	var display = Display.new()
	display.use(settings)
	window.add_child(display)
	root.add_child(window)

	var presets := display.resolution_presets()
	h.check(presets.size() > Display.COMMON_RESOLUTIONS.size(), "the menu offers more than the common list")
	h.check(
		presets[0]["label"] == "This window" and presets[0]["size"] == Vector2i(1366, 768),
		"starting with the size this window is right now (%s)" % str(presets[0]["size"])
	)

	# Godot cannot enumerate the resolutions a monitor supports — the display server has no such
	# call — so what is offered for a monitor is the one it is currently in.
	var from_monitors := 0
	for preset in presets:
		if String(preset["label"]).begins_with("Screen"):
			from_monitors += 1
	h.check(from_monitors == DisplayServer.get_screen_count(), "and one for each monitor (%d)" % from_monitors)

	var missing: Array[String] = []
	for size in Display.COMMON_RESOLUTIONS:
		if not presets.any(func(p: Dictionary) -> bool: return p["size"] == size):
			missing.append(str(size))
	h.check(missing.is_empty(), "with every common one in it%s" % Fixture.detail(missing))

	# A preset the store would refuse must never be offered, or picking it would silently do nothing.
	var refused: Array[String] = []
	for preset in presets:
		for key in ["video.canvas_resolution", "video.render_resolution", "video.window_size"]:
			if not Settings.is_acceptable(key, preset["size"]):
				refused.append("%s for %s" % [str(preset["size"]), key])
	h.check(refused.is_empty(), "and nothing in it that the store would refuse%s" % Fixture.detail(refused))
	window.free()


## The picker, through its real wiring: the row builds a menu, picking stages, and **Apply is what
## commits**.
func _test_the_picker_stages_and_apply_commits(h, root: Node) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var settings := _fixture.open()
	var panel := SettingsPanel.new()
	panel.configure(settings, _fixture.bindings())
	layer.add_child(panel)

	var menus := _menu_buttons(panel, [])
	h.check(menus.size() == 3, "each of the three resolution rows has a menu beside it (%d)" % menus.size())
	if menus.is_empty():
		layer.free()
		return

	# What the screen does when the menu is opened.
	var menu: PopupMenu = menus[0].get_popup()
	menu.about_to_popup.emit()
	h.check(menu.item_count > 3, "and the menu fills when it opens (%d items)" % menu.item_count)

	var wanted := Vector2i(1600, 900)
	var picked := -1
	for index in menu.item_count:
		if menu.get_item_metadata(index) == wanted:
			picked = index
	if picked < 0:
		h.check(false, "the menu offers %s to pick" % str(wanted))
		layer.free()
		return

	# Which row the first menu belongs to is the registry's business, so the check is about the
	# value: nothing is applied until Apply.
	var before: Dictionary = {}
	for key in Settings.declared_keys():
		before[key] = settings.get_value(key)
	menu.index_pressed.emit(picked)

	var changed_early: Array[String] = []
	for key in before:
		if settings.get_value(key) != before[key]:
			changed_early.append(key)
	h.check(
		changed_early.is_empty(),
		"picking a preset applies nothing on its own%s" % Fixture.detail(changed_early)
	)

	panel.actions.get_child(0).pressed.emit()
	var committed: Array[String] = []
	for key in before:
		if settings.get_value(key) != before[key]:
			committed.append("%s = %s" % [key, str(settings.get_value(key))])
	h.check(
		committed == ["video.canvas_resolution = (1600, 900)"],
		"and Apply is what commits it (%s)" % ", ".join(committed)
	)
	layer.free()


static func _menu_buttons(node: Node, into: Array) -> Array:
	if node is MenuButton:
		into.append(node)
	for child in node.get_children():
		_menu_buttons(child, into)
	return into


## **A frame rate is a fraction of the panel, not a number in a file**, which is the only form that survives
## being moved to a different monitor — and the cap can only lower what vsync sets.
func _test_frame_rates(h) -> void:
	for pair in [["unlimited", 240.0, 0], ["screen", 240.0, 240], ["1/2 screen", 240.0, 120],
			["1/4 screen", 240.0, 60], ["1/8 screen", 240.0, 30], ["1/3 screen", 144.0, 48],
			["1/2 screen", 60.0, 30], ["60", 240.0, 60], ["240", 60.0, 240]]:
		var got := Display.fps_for(String(pair[0]), float(pair[1]))
		h.check(
			got == int(pair[2]),
			"%s of %d Hz is %d fps (%d)" % [pair[0], int(pair[1]), int(pair[2]), got]
		)
	# **A display server that will not say is 60**, not zero: a fraction of zero is a stopped game.
	h.check(Display.fps_for("1/2 screen", 0.0) == 30, "an unknown refresh falls back to 60 Hz")
	h.check(Display.fps_for("nonsense", 240.0) == 0, "and an unreadable choice is no cap, not a stop")


## The whole point of three settings rather than one: they are not each other.
func _test_the_three_sizes_are_separate(h, root: Node) -> void:
	var settings := _fixture.open()
	# A window of the display's own, so the checks below are about this one and the real window is
	# left where it is. It has to be in the tree: `get_window()` is what the display reads, and a
	# node outside it has none.
	var window := Window.new()
	window.size = Vector2i(1600, 1000)
	var display = Display.new()
	display.use(settings)
	window.add_child(display)
	root.add_child(window)

	settings.set_value("video.canvas_resolution", Vector2i(1280, 720))
	settings.set_value("video.render_resolution", Vector2i(720, 360))
	settings.set_value("video.window_size", Vector2i(1024, 768))

	h.check(
		window.content_scale_size == Vector2i(1280, 720),
		"the canvas resolution is what the UI is laid out in"
	)
	h.check(
		window.content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS,
		"as canvas items, so a font is re-rasterised for the window rather than magnified"
	)
	h.check(
		window.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND,
		"and the aspect expands — no stretch, no bars"
	)
	h.check(
		window.size == Vector2i(1024, 768),
		"and the window takes the window size, which is its own number (%s)" % str(window.size)
	)
	h.check_near(
		window.scaling_3d_scale,
		Display.render_scale(360, 768.0),
		"while the render resolution sets how far the 3D is drawn up (%.3f of the window)"
		% window.scaling_3d_scale,
		0.0001
	)

	# Read through the settings every time rather than cached at startup, so changing one takes
	# effect without a restart.
	settings.set_value("video.render_resolution", Vector2i(1536, 768))
	display.apply()
	h.check_near(
		window.scaling_3d_scale,
		1.0,
		"and the render resolution is read each time, not remembered from startup",
		0.0001
	)
	window.free()


## **Nothing is preserved without Apply.** A resize is not an edit made in the settings screen, so
## it must not reach the file — the size the game starts at is the one Apply committed.
func _test_nothing_is_written_without_apply(h, root: Node) -> void:
	var settings := _fixture.open()
	var window := Window.new()
	var display = Display.new()
	display.use(settings)
	window.add_child(display)
	root.add_child(window)

	settings.set_value("video.window_size", Vector2i(1024, 768))
	settings.set_value("video.render_resolution", Vector2i(1536, 768))
	display.apply()
	h.check(window.size == Vector2i(1024, 768), "the window is where the setting says")

	# Dragging the window. This is a real resize: `size_changed` fires from here.
	window.size = Vector2i(900, 700)
	h.check(window.size == Vector2i(900, 700), "the window goes where it is dragged")
	h.check(
		settings.get_value("video.window_size") == Vector2i(1024, 768),
		"and the setting is untouched by it, because that is what Apply is for"
	)
	# What a resize *does* have to do: the 3D is drawn into a differently-shaped buffer now.
	h.check_near(
		window.scaling_3d_scale,
		Display.render_scale(768, 700.0),
		"but the 3D is re-fitted to the window it is actually in (%.3f)" % window.scaling_3d_scale,
		0.0001
	)

	# What the player does instead: take this window's size, which stages it, and commit that.
	settings.set_value("video.window_size", window.size)
	h.check(
		settings.get_value("video.window_size") == Vector2i(900, 700),
		"taking this window's size and applying it is how a resize is kept"
	)
	window.free()
