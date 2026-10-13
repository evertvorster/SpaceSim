extends Node
## The window: which monitor, how big it is, and at what resolution the game draws.
##
## ## Three sizes, three different jobs
##
## - **canvas resolution** — the UI's coordinate space. Screens and the HUD are laid out in these
##   units and the whole space is scaled to the window, so this is what sets how large the text
##   reads. Because Godot re-rasterises fonts for the current scale, it stays crisp at any window
##   size — which is the reason this is `canvas_items` and not `viewport` stretch.
## - **render resolution** — what the 3D is drawn at, independent of the window. A space sim is
##   GPU-bound long before it is CPU-bound, so this is the performance knob.
## - **window size** — how big the window is. **Windowed fullscreen is not a mode**: it is this set
##   to the screen's size.
##
## ## Nothing is ever stretched
##
## The aspect is `expand` — never `ignore`, which is the one that distorts. `expand` grows the root
## viewport by one axis to match the window, so the pixel grid stays square and a differently-shaped
## window shows *more* rather than a wider-looking ship. The 3D scale is a single factor for both
## axes, so its buffer has exactly the viewport's aspect, and the camera is a stock [Camera3D] whose
## `keep_aspect` grows the horizontal field of view. So the render resolution's **height is exact and
## its width follows the window** — the extra width has to come from somewhere, and it comes from
## more world rather than from distortion.
##
## Settings are read through [SpacesimSettings] and **never cached** — a display setting is as hot as
## a camera one.
##
## ## This module never writes a setting
##
## A window setting is committed by the settings screen's **Apply** and discarded by **Close**, with
## no third route. Dragging the window resizes it and writes nothing — to make that the size the game
## starts at, pick *This window* from the resolution menu and press Apply. So there is no "it
## remembered on its own" case to reconcile with the staged screen.

const SETTING_MODE := "video.mode"
const SETTING_SCREEN := "video.screen"
const SETTING_ASPECT := "video.aspect"
const SETTING_CANVAS := "video.canvas_resolution"
const SETTING_RENDER := "video.render_resolution"
const SETTING_WINDOW := "video.window_size"

## Godot clamps `scaling_3d_scale` to this, so the arithmetic is held to the same range rather than
## being silently clamped by the engine.
const SCALE_MIN := 0.25
const SCALE_MAX := 2.0

## What the resolution menu offers beyond this machine's own: the shapes people actually have, 16:9
## first and the taller and wider ones after. Godot cannot enumerate the resolutions a monitor
## *supports* — the display server has no such call — so the monitor's own entry is the one it is
## currently in.
const COMMON_RESOLUTIONS := [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(1920, 1200),
	Vector2i(2560, 1440),
	Vector2i(2560, 1600),
	Vector2i(3440, 1440),
	Vector2i(3840, 2160),
]

var _settings: Node

## Set while this is putting the window where the settings say it should be. A change it makes itself
## would otherwise come back round as a change worth reacting to.
var _applying := false


## Read settings from somewhere other than the autoload. The autoload is the only thing that does
## this in the game; a test is the only thing that does it otherwise.
func use(settings: Node) -> void:
	_settings = settings


func _ready() -> void:
	if _settings == null:
		_settings = get_node_or_null("/root/SpacesimSettings")
	if _settings == null:
		push_warning("display: no settings autoload; leaving the window alone")
		return

	var window := get_window()
	if window != null:
		window.size_changed.connect(_on_window_resized)
	_settings.changed.connect(_on_setting_changed)

	apply()


## Put the window where the settings say it should be. Called at startup, which is what makes these
## startup settings rather than preferences that need a restart, and again whenever one changes.
func apply() -> void:
	var window := get_window()
	if window == null:
		return
	_applying = true
	# The screen first: a window is placed *on* a screen, so moving it afterwards is a jump. This is
	# the one thing that has no window equivalent — the list of screens is the display server's.
	DisplayServer.window_set_current_screen(screen_index())
	# **Through the window, not the display server.** `DisplayServer.window_set_size` changes what
	# the display server says the size is and leaves the root [Window] — and so the viewport that is
	# actually drawn — where it was. Setting the window's own property moves both.
	window.mode = mode_of(_settings.get_value(SETTING_MODE))
	# Only windowed has a size of its own. A fullscreen window's size is the screen's.
	if window.mode == Window.MODE_WINDOWED:
		var size: Vector2i = _settings.get_value(SETTING_WINDOW)
		window.size = size
	_apply_scaling()
	_applying = false


## The screen to open on, which is **not** simply the stored number: a stored number outlives the
## monitor it named — a laptop undocked, a docking station removed — so a screen that is no longer
## there falls back to the primary one rather than opening a window on a monitor that does not exist.
func screen_index() -> int:
	var wanted: int = int(_settings.get_value(SETTING_SCREEN))
	return clampi(wanted, 0, maxi(0, DisplayServer.get_screen_count() - 1))


## The root viewport's scaling: the UI's coordinate space, and how far the 3D is scaled up.
func _apply_scaling() -> void:
	var window := get_window()
	if window == null:
		return
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = aspect_of(_settings.get_value(SETTING_ASPECT))
	var canvas: Vector2i = _settings.get_value(SETTING_CANVAS)
	window.content_scale_size = canvas
	_apply_render_resolution()


## The 3D is drawn at the render resolution and scaled up to the window. Only the height can be
## honoured exactly — see the class comment.
func _apply_render_resolution() -> void:
	var window := get_window()
	if window == null:
		return
	var target: Vector2i = _settings.get_value(SETTING_RENDER)
	# The drawn height in *pixels* — not `get_visible_rect()`, which is in canvas units, and not the
	# canvas resolution, which is the UI's scale rather than the 3D's.
	window.scaling_3d_scale = render_scale(target.y, float(window.size.y))


## How far the 3D is scaled for a render height drawn into a viewport that tall. Pure, so what it
## does at the ends of the range can be checked without a window.
static func render_scale(render_height: int, drawn_height: float) -> float:
	return clampf(float(render_height) / maxf(drawn_height, 1.0), SCALE_MIN, SCALE_MAX)


## A window of a different shape draws the 3D into a different buffer, so the scale is worked out
## again. **Nothing is written**: a resize is not an edit, and the size the game starts at is the one
## Apply committed.
func _on_window_resized() -> void:
	if _applying:
		return
	_apply_render_resolution()


func _on_setting_changed(key: String, _value: Variant) -> void:
	if _applying:
		return
	if key.begins_with("video."):
		apply()


# --- reading a setting ---------------------------------------------------------------------------

func mode_of(name: Variant) -> Window.Mode:
	match String(name):
		"fullscreen":
			# Godot's FULLSCREEN is a borderless window covering the screen — which is what
			# "windowed fullscreen" means — rather than a mode switch of the monitor.
			return Window.MODE_FULLSCREEN
		"exclusive":
			# The real thing: the monitor changes mode, and alt-tabbing is slower for it.
			return Window.MODE_EXCLUSIVE_FULLSCREEN
	return Window.MODE_WINDOWED


func aspect_of(name: Variant) -> Window.ContentScaleAspect:
	return (
		Window.CONTENT_SCALE_ASPECT_KEEP
		if String(name) == "keep"
		else Window.CONTENT_SCALE_ASPECT_EXPAND
	)


## The monitors, as `"1: 2560 x 1440 (primary)"`. For the settings screen to offer, because a list of
## screens is the one thing here that cannot be declared in the registry — it is the machine's.
##
## Not `static`: `DisplayServer` is a singleton rather than a class of statics, and a static function
## cannot reach it.
func screen_names() -> Array:
	var names: Array = []
	var primary := DisplayServer.get_primary_screen()
	for index in DisplayServer.get_screen_count():
		var size := DisplayServer.screen_get_size(index)
		names.append(
			"%d: %d x %d%s" % [index, size.x, size.y, "  (primary)" if index == primary else ""]
		)
	return names


## Every resolution the menu beside a resolution row should offer, in the order to show them:
## `{"label": String, "size": Vector2i}`. An empty label is a plain resolution with nothing to say
## about where it came from, and is where the menu draws its separator.
##
## Built when the menu opens rather than when the row is, because both the window and the monitors
## move underneath it.
func resolution_presets() -> Array:
	var presets: Array = []
	var window := get_window()
	if window != null:
		presets.append({"label": "This window", "size": window.size})
	var primary := DisplayServer.get_primary_screen()
	for index in DisplayServer.get_screen_count():
		presets.append(
			{
				"label": "Screen %d%s" % [index, "  (primary)" if index == primary else ""],
				"size": DisplayServer.screen_get_size(index),
			}
		)
	for size in COMMON_RESOLUTIONS:
		presets.append({"label": "", "size": size})
	return presets
