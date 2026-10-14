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
## The solar system comes from `systems/sol.tres`; this script only adds input, the camera's
## render range and a readout. A different system file should not need this script changed.

const PlayerShip := preload("res://game/player_ship.gd")
const Frame := preload("res://addons/spacesim/coordinate/frame.gd")
const Location := preload("res://addons/spacesim/coordinate/location.gd")
const TravelScale := preload("res://addons/spacesim/travel/travel_scale.gd")
const Bindings := preload("res://addons/spacesim/settings/bindings.gd")
const Session := preload("res://addons/spacesim/save/session.gd")

const SYSTEM_PATH := "res://systems/sol.tres"

const MOUSE_SENSITIVITY_FALLBACK := 0.0015
const TURN_RATE := 1.2 ## rad/s from the roll keys
const THROTTLE_RATE := 0.7 ## per second

## Body detail levels for cost attribution: if the frame rate tracks screen coverage it stays
## flat across these, and if it tracks triangle count it moves with them.
const DETAIL_LEVELS := [Vector2i(32, 16), Vector2i(64, 32), Vector2i(128, 64), Vector2i(256, 128)]

var _system: SpacesimSystemScene
var _session: SpacesimSession
var _ship: Node3D
var _camera: Camera3D
## The camera's exposure. Physics-computed — see SpacesimExposure — so it needs updating as the
## player moves rather than being left to the engine's frame average.
var _exposure: SpacesimExposure
var _markers: SpacesimMarkers
var _ui_layer: CanvasLayer
var _player: SpacesimPlayer
var _settings_screen: SpacesimSettingsPanel
var _player_screen: SpacesimPlayerPanel

## The screen that is open, or null. Having one open *is* being paused.
var _screen: SpacesimScreen
var _selected_index := -1
var _look := Vector2.ZERO
var _hud: Label
var _fps: Label
var _skip_next_motion := false
var _detail := 2 ## index into DETAIL_LEVELS
var _triangles := 0
var _bodies_visible := true


func _ready() -> void:
	_system = SpacesimSystemScene.from_file(SYSTEM_PATH)
	if _system == null:
		push_error("cannot load %s" % SYSTEM_PATH)
		return
	_system.build(self)
	_ship = PlayerShip.create()
	PlayerShip.place(_system, _ship)
	_markers = SpacesimMarkers.new()
	_markers.name = "Markers"
	# The HUD is built after this, and the marker overlay needs its rectangles to place labels clear
	# of them — but `refresh` reads them every frame, so the order it is built in does not matter.
	# Which body each one orbits is a fact about the system, so it is handed over once.
	_markers.orbits = _system.orbit_parents()
	add_child(_markers)
	_camera = _ship.get_node("Camera")
	# Exposure is a camera property, and it is ours: the star's light is physical, so the exposure that
	# puts a lit body at middle grey is arithmetic. Settled at once rather than transitioned into, so
	# the first frame is already right.
	_exposure = SpacesimExposure.new()
	_camera.attributes = _exposure.attributes
	_exposure.snap_to(_system.illuminance_at(_ship.global_position))
	_apply_settings()
	SpacesimSettings.changed.connect(_on_setting_changed)
	_set_detail(_detail)
	_build_hud()

	# The session comes up after the system has real frames, because restoring where the player was
	# means putting the ship into one of them.
	_session = Session.for_world(_system.name)
	var brought_up := _session.start(_system)
	if not brought_up["ok"]:
		push_error("cannot open the world's repository: %s" % brought_up["reason"])
	_player = _session.player
	_place_observer_from_session()

	_settings_screen = SpacesimSettingsPanel.new()
	_settings_screen.configure(SpacesimSettings)
	_settings_screen.exit_requested.connect(_on_exit_requested)
	_register_screen(_settings_screen, "Settings")
	_player_screen = SpacesimPlayerPanel.new()
	_player_screen.configure(_player, _session, _system)
	# A load, a switch or a new story all move the player, and the ship is where the player is.
	_player_screen.session_reloaded.connect(_place_observer_from_session)
	_register_screen(_player_screen, "Player")

	_capture_mouse()


## The screen hotkeys are handled here rather than in _unhandled_input, because Tab is also the
## UI's focus key and the UI system would consume it first. Handled here, Tab always toggles, and
## keyboard focus navigation still works for everything else.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if Bindings.matches(event, String(SpacesimSettings.get_value("bindings.settings_screen"))):
		_toggle(_settings_screen)
		get_viewport().set_input_as_handled()
	elif Bindings.matches(event, String(SpacesimSettings.get_value("bindings.player_screen"))):
		_toggle(_player_screen)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event)
		return
	if _screen != null:
		return
	if event is InputEventMouseMotion:
		_ship_mouse_look(event)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_capture_mouse()


func _handle_key(event: InputEventKey) -> void:
	if _screen != null:
		return

	if Bindings.matches(event, String(SpacesimSettings.get_value("bindings.bodies_toggle"))):
		_bodies_visible = not _bodies_visible
		for body_mesh in _system.meshes():
			body_mesh.visible = _bodies_visible
	elif Bindings.matches(event, String(SpacesimSettings.get_value("bindings.cycle_target"))):
		_cycle_target()
	elif Bindings.matches(event, String(SpacesimSettings.get_value("bindings.detail_down"))):
		_set_detail(_detail - 1)
	elif Bindings.matches(event, String(SpacesimSettings.get_value("bindings.detail_up"))):
		_set_detail(_detail + 1)
	elif event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _ship_mouse_look(event: InputEventMouseMotion) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	# Capturing warps the cursor, and the first motion after that reports the warp as a huge
	# relative delta. Drop it, or the ship spins on every recapture.
	if _skip_next_motion:
		_skip_next_motion = false
		return
	_look += event.relative


## Pausing the game is the scene's business rather than the tree's: only the simulation needs to
## stop, and a screen has to keep running inside it.
func _toggle(screen: SpacesimScreen) -> void:
	if _screen == screen:
		_close_screen()
	else:
		_open_screen(screen)


func _open_screen(screen: SpacesimScreen) -> void:
	if _screen != null:
		_screen.visible = false
		_screen.dismissed()
	_screen = screen
	screen.opened()
	screen.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _close_screen() -> void:
	if _screen == null:
		return
	_screen.visible = false
	_screen.dismissed()
	_screen = null
	_capture_mouse()


## Put a screen in the UI layer, hidden, with its close wired.
func _register_screen(screen: SpacesimScreen, screen_name: String) -> void:
	screen.name = screen_name
	screen.visible = false
	_ui_layer.add_child(screen)
	screen.closed.connect(_close_screen)


func _on_exit_requested() -> void:
	# Unapplied edits are discarded, not applied: the Close button's colour said so. The file is
	# written for anything already applied.
	SpacesimSettings.save()
	get_tree().quit()


## Whether a binding's key is held. Read per frame rather than cached, so rebinding one takes
## effect without anything having to notice.
func _held(binding_key: String) -> bool:
	var code := Bindings.keycode_of(String(SpacesimSettings.get_value(binding_key)))
	return code != KEY_NONE and Input.is_physical_key_pressed(code)


## Change every body's tessellation. The count is measured here rather than per frame, because
## get_faces() allocates.
func _set_detail(index: int) -> void:
	_detail = clampi(index, 0, DETAIL_LEVELS.size() - 1)
	var level: Vector2i = DETAIL_LEVELS[_detail]
	_triangles = 0
	for body_mesh in _system.meshes():
		var sphere: SphereMesh = body_mesh.mesh
		sphere.radial_segments = level.x
		sphere.rings = level.y
		var faces := sphere.get_faces().size()
		_triangles += floori(float(faces) / 3.0)


## Selection is the input half of targeting, and the smallest stand-in for the navigation we
## have not designed yet: cycle the significant bodies and hold the choice.
func _cycle_target() -> void:
	var targets := _system.significant_nodes()
	if targets.is_empty():
		return
	_selected_index = (_selected_index + 1) % targets.size()
	_markers.selected = targets[_selected_index]


## Everything this scene takes from settings, applied now. Called at startup and again on any
## change, so nothing here is read once at startup and then forgotten.
func _apply_settings() -> void:
	_camera.fov = SpacesimSettings.get_value("camera.fov")
	_markers.rebuild_pool(int(SpacesimSettings.get_value("markers.pool_size")))
	_markers.font_size = int(SpacesimSettings.get_value("markers.font_size"))
	_markers.margin = float(SpacesimSettings.get_value("markers.margin"))
	_markers.selected_color = SpacesimSettings.get_value("markers.selected_color")


func _on_setting_changed(key: String, _value: Variant) -> void:
	match key:
		"camera.fov", "markers.pool_size", "markers.font_size", "markers.margin", "markers.selected_color":
			_apply_settings()


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
	if _screen != null:
		return

	var throttle: float = _ship.throttle
	if _held("bindings.throttle_up"):
		throttle += THROTTLE_RATE * delta
	if _held("bindings.throttle_down"):
		throttle -= THROTTLE_RATE * delta

	var roll := 0.0
	if _held("bindings.roll_left"):
		roll -= TURN_RATE * delta
	if _held("bindings.roll_right"):
		roll += TURN_RATE * delta

	# Read per frame rather than held, so it is hot without anything having to react to a change.
	var sensitivity: float = SpacesimSettings.get_value("mouse.sensitivity")
	var input := {
		"throttle": clampf(throttle, 0.0, 1.0),
		"pitch": -_look.y * sensitivity,
		"yaw": _look.x * sensitivity,
		"roll": roll,
	}
	_look = Vector2.ZERO

	_ship.step(delta, input)
	_system.frame_tree.evaluate()
	_sync_player_location()
	_system.aim_sun_at(_ship.global_position)
	# The sky follows the **camera**, not the ship: it is the eye that scattering is seen from, and
	# nothing about it depends on which body the player is attached to.
	_system.update_atmospheres(_camera.global_position)
	_system.update_sky(_camera)
	# Exposed for **what the eye is looking at**, not for the light falling on a surface where the player
	# happens to be — see SpacesimSystemScene.view_luminance_at. A luminance, because adaptation follows
	# the scene; an irradiance is a property of where you are and cannot tell the Sun from empty sky.
	var tan_y := tan(deg_to_rad(_camera.fov * 0.5))
	var view_size := _camera.get_viewport().get_visible_rect().size
	var tan_half := Vector2(tan_y, tan_y)
	if view_size.y > 0.0:
		tan_half.x = tan_y * view_size.x / view_size.y
	var luminance := _system.view_luminance_at(
		_ship.global_position, -_camera.global_transform.basis.z, tan_half
	)
	# The dark-adapted value is a **ceiling, not a floor**: nothing can adapt you better than darkness,
	# and a bright object can only stop you down from there. That is also what keeps the sky's brightness
	# from depending on how far away the star is, which it must not — your eye adapts to what it is
	# looking at, not to the distance to a lamp.
	var target := SpacesimExposure.DARK_ADAPTED_MULTIPLIER
	if luminance > 0.0:
		target = minf(target, SpacesimExposure.target_multiplier_for_luminance(luminance))
	_exposure.update_to(target, delta)
	_update_markers(_camera)
	_update_camera(_camera)
	_update_hud()


## The player is *inside* the ship while flying, so their location follows it. They are separate
## entities — containment is frame membership, which is what makes "which ship am I in" readable
## from the player's own location. Nothing can be entered yet, so the two currently coincide.
func _sync_player_location() -> void:
	var frame := _ship.get_parent() as Frame
	if frame != null:
		_session.player.location = Location.new(frame.frame_id, _ship.position)


## Put the ship where the session says the player is. Said out loud when the system no longer has the
## frame a save named, because the ship has then been placed somewhere the save did not choose.
func _place_observer_from_session() -> void:
	if not _player.location.is_set():
		return
	if not _system.place_observer(_player.location):
		push_warning("the saved location's frame is gone; placed at the nearest frame that remains")


## The ambient group is the frame's business: other bodies matter while you are out in space, and
## stop mattering once you are busy landing on one of them.
func _update_markers(camera: Camera3D) -> void:
	var frame: Frame = _system.frame_tree.active_frame
	var in_space: bool = frame.kind == Frame.Kind.SPACE or frame.kind == Frame.Kind.ORBITAL
	var context: Array[Node3D] = []
	if in_space:
		context = _system.significant_nodes()
	_markers.context_targets = context
	_markers.refresh(camera)


## Render range tracks the scale you are operating at. Only the ratio costs depth precision, and
## reverse-Z (Godot 4.3+) absorbs a lot — but this is a "measure it for artefacts" item, not a
## settled number.
func _update_camera(camera: Camera3D) -> void:
	var frame: Frame = _system.frame_tree.active_frame
	var range_for_frame: Vector2 = SpacesimSettings.get_value(_range_key(frame.kind))
	camera.near = range_for_frame.x
	var far: float = range_for_frame.y
	# **Never let the far plane be smaller than what must be drawn.** For space that is the system: the
	# space range is a player quality knob whose 1e11 m default is *less than one au*, so every body
	# beyond 0.67 au — the star included — was clipped and simply not drawn. Inside a body's air it is
	# the sky **and everything in it**: the grazing ray reaches ~1,600 km and the star is 1.5e11 m, so a
	# terrain-tight plane clips the sky itself as well as the sun and the other bodies. See
	# `SpacesimSystemScene.sky_reach` for why the sky is that far away.
	if frame.kind == Frame.Kind.SPACE or _system.air_body(frame) != null:
		far = maxf(far, maxf(_system.sky_reach(frame), _system.view_distance()))
	camera.far = far


func _range_key(kind: int) -> String:
	match kind:
		Frame.Kind.ORBITAL:
			return "camera.range_orbital"
		Frame.Kind.ATMOSPHERE:
			return "camera.range_atmosphere"
		Frame.Kind.SURFACE:
			return "camera.range_surface"
		Frame.Kind.INTERIOR:
			return "camera.range_interior"
		_:
			return "camera.range_space"


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)
	_ui_layer = layer

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
	var frame: Frame = _system.frame_tree.active_frame
	var length: float = _ship.travel_length
	var fraction := 0.0
	if length > 0.0:
		fraction = _ship.speed * TravelScale.TRAVERSE_SECONDS / length
	var contact := "on the surface" if _ship.landed else "free flight"
	var bodies := "visible" if _bodies_visible else "hidden"
	var target := "none"
	if _markers.selected != null:
		target = _markers.selected.name

	_hud.text = "\n".join(
		PackedStringArray(
			[
				"system      %s" % _system.name,
				"player      %s   in %s" % [_player.display_name(), _session.repo.current_history()],
				"date        %s" % _system.format_time(_session.world_time),
				"settings    %s" % SpacesimSettings.path(),
				"frame       %s" % frame.name,
				"altitude    %s" % SpacesimMarkers.format_distance(_ship.altitude()),
				"speed       %s   (%.0f%% of local)" % [_speed(_ship.speed), fraction * 100.0],
				"nearest     %s at %s" % [_ship.nearest_name, SpacesimMarkers.format_distance(_ship.nearest_distance)],
				"local unit  %s" % SpacesimMarkers.format_distance(length),
				"state       %s" % contact,
				"target      %s" % target,
				"",
				"bodies      %s, %d triangles" % [bodies, _triangles],
				"",
				"W/S throttle    mouse look    A/D roll    Esc release mouse, click to take it back",
				"Tab personal data    Alt+C settings    T cycle target    P bodies on/off    [ ] body detail",
			]
		)
	)


static func _speed(metres_per_second: float) -> String:
	var magnitude := absf(metres_per_second)
	if magnitude >= 1.0e6:
		return "%.3f Mm/s" % (metres_per_second / 1.0e6)
	if magnitude >= 1.0e3:
		return "%.3f km/s" % (metres_per_second / 1.0e3)
	return "%.2f m/s" % metres_per_second
