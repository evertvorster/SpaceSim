extends Node3D
## Fly from space to a planet's surface.
##
##   W / S      throttle (a fraction of the local travel unit)
##   mouse      pitch and yaw
##   A / D      roll
##   Esc        release the mouse
##
## The world is built in code by [code]scale_world.gd[/code] so the headless test can fly
## the identical world; this script only adds input, the camera's render range and a
## readout.

const ScaleWorld := preload("res://demo/scale_world.gd")
const Frame := preload("res://addons/spacesim/coordinate/frame.gd")
const TravelScale := preload("res://addons/spacesim/travel/travel_scale.gd")

const MOUSE_SENSITIVITY := 0.0015
const TURN_RATE := 1.2 ## rad/s from the roll keys
const THROTTLE_RATE := 0.7 ## per second

var _world := {}
var _look := Vector2.ZERO
var _hud: Label
var _fps: Label
var _skip_next_motion := false


func _ready() -> void:
	_world = ScaleWorld.new().build(self)
	_build_hud()
	_capture_mouse()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
		# Capturing warps the cursor, and the first motion after that reports the warp as a
		# huge relative delta. Drop it, or the ship spins on every recapture.
		if _skip_next_motion:
			_skip_next_motion = false
			return
		_look += event.relative
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_capture_mouse()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


## Click to take the mouse back after Esc released it.
func _capture_mouse() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return
	_look = Vector2.ZERO
	_skip_next_motion = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _process(_delta: float) -> void:
	var frames := Engine.get_frames_per_second()
	if frames <= 0:
		_fps.text = "-- fps"
		return
	_fps.text = "%d fps    %.1f ms" % [frames, 1000.0 / float(frames)]


func _physics_process(delta: float) -> void:
	var ship = _world["ship"]

	var throttle: float = ship.throttle
	if Input.is_key_pressed(KEY_W):
		throttle += THROTTLE_RATE * delta
	if Input.is_key_pressed(KEY_S):
		throttle -= THROTTLE_RATE * delta

	var roll := 0.0
	if Input.is_key_pressed(KEY_A):
		roll -= TURN_RATE * delta
	if Input.is_key_pressed(KEY_D):
		roll += TURN_RATE * delta

	var input := {
		"throttle": clampf(throttle, 0.0, 1.0),
		"pitch": -_look.y * MOUSE_SENSITIVITY,
		"yaw": _look.x * MOUSE_SENSITIVITY,
		"roll": roll,
	}
	_look = Vector2.ZERO

	ship.step(delta, input)
	_world["frame_tree"].evaluate()
	_update_camera()
	_update_hud()


## Render range tracks the scale you are operating at. Only the ratio costs depth
## precision, and reverse-Z (Godot 4.3+) absorbs a lot — but this is a "measure it for
## artefacts" item, not a settled number.
func _update_camera() -> void:
	var camera: Camera3D = _world["ship"].get_node("Camera")
	var frame = _world["frame_tree"].active_frame
	var range_for_frame := _camera_range(frame.kind)
	camera.near = range_for_frame.x
	camera.far = range_for_frame.y


func _camera_range(kind: int) -> Vector2:
	match kind:
		Frame.Kind.SPACE:
			return Vector2(100.0, 1.0e11)
		Frame.Kind.ORBITAL:
			return Vector2(5.0, 1.0e8)
		Frame.Kind.ATMOSPHERE:
			return Vector2(0.5, 1.0e7)
		Frame.Kind.SURFACE:
			return Vector2(0.1, 2.0e5)
		_:
			return Vector2(0.05, 1.0e3)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	var label := Label.new()
	label.name = "Readout"
	label.position = Vector2(24.0, 18.0)
	label.add_theme_font_size_override("font_size", 17)
	layer.add_child(label)
	_hud = label

	# Top right, so a frame-rate change while tuning something else is visible at a glance.
	var fps := Label.new()
	fps.name = "FrameRate"
	fps.anchor_left = 1.0
	fps.anchor_right = 1.0
	fps.offset_left = -220.0
	fps.offset_right = -24.0
	fps.offset_top = 18.0
	fps.offset_bottom = 46.0
	fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fps.add_theme_font_size_override("font_size", 17)
	layer.add_child(fps)
	_fps = fps


## The limit is shown alongside the speed, not instead of it: a limit the player cannot
## see reads as a bug.
func _update_hud() -> void:
	var ship = _world["ship"]
	var frame = _world["frame_tree"].active_frame
	var length: float = ship.travel_length
	var fraction := 0.0
	if length > 0.0:
		fraction = ship.speed * TravelScale.TRAVERSE_SECONDS / length

	_hud.text = "\n".join(
		PackedStringArray(
			[
				"frame       %s" % frame.name,
				"altitude    %s" % _distance(ship.altitude()),
				"speed       %s   (%.0f%% of local)" % [_speed(ship.speed), fraction * 100.0],
				"nearest     %s at %s" % [ship.nearest_name, _distance(ship.nearest_distance)],
				"local unit  %s" % _distance(length),
				"",
				"W/S throttle    mouse look    A/D roll    Esc release mouse, click to take it back",
			]
		)
	)


static func _distance(metres: float) -> String:
	if is_inf(metres) or is_nan(metres):
		return "--"
	var magnitude := absf(metres)
	if magnitude >= 1.0e9:
		return "%.3f Gm" % (metres / 1.0e9)
	if magnitude >= 1.0e6:
		return "%.3f Mm" % (metres / 1.0e6)
	if magnitude >= 1.0e3:
		return "%.3f km" % (metres / 1.0e3)
	return "%.2f m" % metres


static func _speed(metres_per_second: float) -> String:
	var magnitude := absf(metres_per_second)
	if magnitude >= 1.0e6:
		return "%.3f Mm/s" % (metres_per_second / 1.0e6)
	if magnitude >= 1.0e3:
		return "%.3f km/s" % (metres_per_second / 1.0e3)
	return "%.2f m/s" % metres_per_second
