extends RefCounted
## The window: which screen, how big, and at what resolution the game draws.
##
## Headless, the display server is a dummy — so what is checked here is the *decision*: which mode a
## name means, which screen a stored number resolves to now, and how far the 3D is scaled. What a
## real monitor then does with it is not something this suite can see, and is not claimed.

const Display := preload("res://addons/spacesim/settings/display.gd")
const Settings := preload("res://addons/spacesim/settings/settings.gd")

const Fixture := preload("res://tests/settings_fixture.gd")

var _fixture := Fixture.new()


func run(h, root: Node) -> void:
	print("  the window")
	Fixture.clean()
	_test_mode_names(h)
	_test_aspect_names(h)
	_test_the_render_scale(h)
	_test_a_screen_that_is_gone(h)
	_test_the_three_sizes_are_separate(h, root)
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
