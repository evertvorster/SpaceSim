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

const SETTING_MODE := "video.mode"
const SETTING_SCREEN := "video.screen"
const SETTING_ASPECT := "video.aspect"
const SETTING_CANVAS := "video.canvas_resolution"
const SETTING_RENDER := "video.render_resolution"
const SETTING_WINDOW := "video.window_size"

## A window being dragged emits a resize event per frame. The size is written back once the resizing
## stops, so a drag is one write rather than a hundred.
const SETTLE_SECONDS := 0.5

## Godot clamps `scaling_3d_scale` to this, so the arithmetic is held to the same range rather than
## being silently clamped by the engine.
const SCALE_MIN := 0.25
const SCALE_MAX := 2.0

var _settings: Node
var _settle: Timer

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

	_settle = Timer.new()
	_settle.one_shot = true
	_settle.wait_time = SETTLE_SECONDS
	_settle.timeout.connect(_remember_window_size)
	add_child(_settle)

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


## A resize re-fits the 3D and, once the player has stopped, is what the window remembers being.
func _on_window_resized() -> void:
	var window := get_window()
	if _applying or window == null or window.mode != Window.MODE_WINDOWED:
		return
	_apply_render_resolution()
	_settle.start()


func _remember_window_size() -> void:
	var window := get_window()
	if window == null or window.mode != Window.MODE_WINDOWED:
		return
	# Not a write when nothing moved: applying the settings can resize the window, and writing that
	# back would be this reacting to itself.
	if window.size == _settings.get_value(SETTING_WINDOW):
		return
	_settings.set_value(SETTING_WINDOW, window.size)


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
