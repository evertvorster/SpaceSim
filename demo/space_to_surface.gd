extends Node3D
## Fly around the playground system and land on planets.
##
##   W / S      throttle (a fraction of the local travel unit)
##   mouse      pitch and yaw
##   A / D      roll
##   Esc        release the mouse    (click to take it back)
##   P          hide/show the bodies
##   [ / ]      body tessellation, for attributing frame cost
##
## The world comes from `worlds/playground.json`; this script only adds input, the camera's
## render range and a readout. A different world file should not need this script changed.

const PlayerShip := preload("res://demo/player_ship.gd")
const Frame := preload("res://addons/spacesim/coordinate/frame.gd")
const TravelScale := preload("res://addons/spacesim/travel/travel_scale.gd")

const WORLD_PATH := "res://worlds/playground.json"

const MOUSE_SENSITIVITY := 0.0015
const TURN_RATE := 1.2 ## rad/s from the roll keys
const THROTTLE_RATE := 0.7 ## per second

## Body detail levels for cost attribution: if the frame rate tracks screen coverage it stays
## flat across these, and if it tracks triangle count it moves with them.
const DETAIL_LEVELS := [Vector2i(32, 16), Vector2i(64, 32), Vector2i(128, 64), Vector2i(256, 128)]

var _world: SpacesimWorld
var _ship: Node3D
var _look := Vector2.ZERO
var _hud: Label
var _fps: Label
var _skip_next_motion := false
var _detail := 2 ## index into DETAIL_LEVELS
var _triangles := 0
var _bodies_visible := true


func _ready() -> void:
	_world = SpacesimWorld.from_file(WORLD_PATH)
	if _world == null:
		push_error("cannot load %s" % WORLD_PATH)
		return
	_world.build(self)
	_ship = PlayerShip.create()
	PlayerShip.place(_world, _ship)
	_set_detail(_detail)
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
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			KEY_P:
				_bodies_visible = not _bodies_visible
				for body_mesh in _world.meshes():
					body_mesh.visible = _bodies_visible
			KEY_BRACKETLEFT:
				_set_detail(_detail - 1)
			KEY_BRACKETRIGHT:
				_set_detail(_detail + 1)


## Change every body's tessellation. The count is measured here rather than per frame, because
## get_faces() allocates.
func _set_detail(index: int) -> void:
	_detail = clampi(index, 0, DETAIL_LEVELS.size() - 1)
	var level: Vector2i = DETAIL_LEVELS[_detail]
	_triangles = 0
	for body_mesh in _world.meshes():
		var sphere: SphereMesh = body_mesh.mesh
		sphere.radial_segments = level.x
		sphere.rings = level.y
		var faces := sphere.get_faces().size()
		_triangles += floori(float(faces) / 3.0)


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
	var throttle: float = _ship.throttle
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

	_ship.step(delta, input)
	_world.frame_tree.evaluate()
	_world.aim_sun_at(_ship.global_position)
	_update_camera()
	_update_hud()


## Render range tracks the scale you are operating at. Only the ratio costs depth precision, and
## reverse-Z (Godot 4.3+) absorbs a lot — but this is a "measure it for artefacts" item, not a
## settled number.
func _update_camera() -> void:
	var camera: Camera3D = _ship.get_node("Camera")
	var frame = _world.frame_tree.active_frame
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


## The limit is shown alongside the speed, not instead of it: a limit the player cannot see
## reads as a bug.
func _update_hud() -> void:
	var frame = _world.frame_tree.active_frame
	var length: float = _ship.travel_length
	var fraction := 0.0
	if length > 0.0:
		fraction = _ship.speed * TravelScale.TRAVERSE_SECONDS / length
	var contact := "on the surface" if _ship.landed else "free flight"
	var bodies := "visible" if _bodies_visible else "hidden"

	_hud.text = "\n".join(
		PackedStringArray(
			[
				"world       %s" % _world.name,
				"frame       %s" % frame.name,
				"altitude    %s" % _distance(_ship.altitude()),
				"speed       %s   (%.0f%% of local)" % [_speed(_ship.speed), fraction * 100.0],
				"nearest     %s at %s" % [_ship.nearest_name, _distance(_ship.nearest_distance)],
				"local unit  %s" % _distance(length),
				"state       %s" % contact,
				"",
				"bodies      %s, %d triangles" % [bodies, _triangles],
				"",
				"W/S throttle    mouse look    A/D roll    Esc release mouse, click to take it back",
				"P bodies on/off    [ ] body detail",
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
