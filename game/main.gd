extends Node3D
## Fly **Sol** and land on planets.
##
## The keys below are the registry's **defaults**; every one except Esc is a rebindable setting, and
## the readout at the bottom of the HUD is generated from whatever is bound rather than from this
## list.
##
##   W / S      throttle (a fraction of the local travel unit)
##   mouse      pitch and yaw
##   A / D      roll
##   Esc        release the mouse    (click to take it back)
##   P          hide/show the bodies
##   [ / ]      the mesh error budget (`lod.error_budget`), which is what sets every body's
##              tessellation — the trim for judging a level's silhouette in flight
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
## **Ten seconds from zero to full**, which over the +-10 range is one unit a second — slow enough to stop
## inside a deck and to watch a surface go past, and astern is reached in the same time.
const THROTTLE_RATE := 1.0

## The mesh error budget, in pixels of silhouette error, as stops to step through rather than a
## continuous number: it is a perceptual trim, so the useful question is "is this better or worse"
## rather than "is 3.7 better than 3.9". **It is a setting and not a debug variable** — the same shape
## the star field's gain established — so it is tuned by flying, and kept in the config until a render
## set justifies freezing it into `SpacesimLod`.
##
## The index is read from the setting every time rather than cached, because a setting cached in a
## variable is the one thing that turns it cold.

var _system: SpacesimSystemScene
var _session: SpacesimSession
var _ship: Node3D
var _camera: Camera3D
## Set by the stop key and consumed by the next physics step.
var _throttle_stop := false
## The camera's exposure. Physics-computed — see SpacesimExposure — so it needs updating as the
## player moves rather than being left to the engine's frame average.
var _exposure: SpacesimExposure
## The frame-wide exposure pass: the metre and the multiply, on the GPU. See `SpacesimExposurePass`.
var _exposure_pass: SpacesimExposurePass
var _surface_bake: SpacesimSurfaceBakePass
var _atmosphere_pass: SpacesimAtmospherePass
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
## **The ship's visibility is a setting now, not session state** (`ship.visible`), and it is *not* cached
## in a variable here — the project's rule, because a cached setting silently stops being hot. Evert,
## 2026-10-16: *"I want the 'ship' in the game to remember its last setting, currently it resets to a
## default."* It used to be a `var` defaulting to true on every run, so the key had to be pressed again
## each time; and it defaulted to true deliberately, because the placeholder hull is lit like a plain box
## and its own pixels move the exposure metre. The default is unchanged — what changed is that pressing
## the key now persists.
var _bodies_visible := true
## Whether the body meshes are being drawn as wireframes — see [method set_wireframe].
var _wireframe := false


func _ready() -> void:
	_print_build()
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
	# **The exposure is applied frame-wide now, by a pass over the finished frame.** The camera's own
	# attributes go to identity, and `SpacesimExposure`'s per-location target is not used for the frame
	# any more — it was the three-disagreeing-estimates problem in miniature, and it is what left the
	# ambient unscaled (measured: exposure ×1/×1000/×80000 give byte-identical pixels).
	#
	# **The attributes stay attached.** Identity is `CameraAttributesPhysical` with the multiplier at 1.0,
	# never `null`: with no attributes the engine skips the factor that implements Godot's lux
	# convention and the scene renders about 95x too bright (`light_storage.cpp:764`).
	_exposure.identity()
	_exposure_pass = SpacesimExposurePass.new()
	# **The surface maps refine on the render thread**, through a pass of this camera's compositor: a bake is a
	# `RenderingDevice` dispatch, and a callback *is* the render thread. After the exposure pass, because it
	# writes no colour and must not sit between the frame and the metre.
	_surface_bake = SpacesimSurfaceBakePass.new()
	# **The air goes before the exposure**, so the metre measures the finished frame: the march writes the air
	# into the colour buffer and the exposure pass reads it. A pass placed after would leave the exposure
	# metering an intermediate frame — the same class of fault as metering the 2D layer.
	_atmosphere_pass = SpacesimAtmospherePass.new()
	var compositor := Compositor.new()
	var effects: Array[CompositorEffect] = [_atmosphere_pass, _exposure_pass, _surface_bake]
	compositor.compositor_effects = effects
	_camera.compositor = compositor
	# The system was built before this camera existed, so the bake pass is handed over now: the maps baked at
	# build are already in place, and refinement begins with the first frame the eye asks for more.
	_system.attach_surface_bake(_surface_bake)
	_apply_settings()
	SpacesimSettings.changed.connect(_on_setting_changed)
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
		# **On each body's own node, not on its meshes.** `update_lod` now decides a mesh's or a point's
		# visibility once a frame, and two writers of one flag is a flicker — so the key sets the
		# parent's, which composes with whatever the tier decided instead of fighting it.
		for body in _system.bodies:
			if body.node != null:
				body.node.visible = _bodies_visible
	elif Bindings.matches(event, String(SpacesimSettings.get_value("bindings.ship_toggle"))):
		# **Write the setting and let `_apply_settings` draw it** — one writer for the hull's visibility,
		# and it is the same path a hand-edited file or a future control would take.
		SpacesimSettings.set_value("ship.visible", not ship_is_visible(), true)
	elif Bindings.matches(event, String(SpacesimSettings.get_value("bindings.cycle_target"))):
		_cycle_target()
	elif Bindings.matches(event, String(SpacesimSettings.get_value("bindings.throttle_stop"))):
		_throttle_stop = true
	elif Bindings.matches(event, String(SpacesimSettings.get_value("bindings.wireframe_toggle"))):
		set_wireframe(not _wireframe)
	elif _view_for(event) != null:
		# **The camera looks along a direction in the SHIP's frame**, so mouse look still steers and the
		# chosen view stays put — which is what makes the same scene comparable from six sides.
		_camera.basis = _view_for(event)
	elif event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


## **The body meshes as unshaded white wireframes, which is a different question from how they look.**
##
## Not `Viewport.DEBUG_DRAW_WIREFRAME`: that draws its lines **with the material's own shading**, so a
## sunlit disc comes out white lines on white and shows nothing. The scene swaps each body's mesh for a
## `PRIMITIVE_LINES` version of the same level (`SpacesimIcosphere.lines_at`) and an unshaded white
## material instead, which is white everywhere by construction.
##
## **Off restores the lit material exactly**, because the body kept its own: `SpacesimSceneBody.mesh_material`
## is set when the body is built and put back by `update_lod`, so the toggle is not a mode the renderer
## reasons about, only a swap.
##
## **The air and the deck are taken out at the same time, or there is nothing to see.** They are the two
## things drawn over the ground, and both hide it. They go off via `layers = 0` rather than `visible`,
## because `update_lod` writes `visible` every frame — the same trap the screenshot rig documents.
##
## It prints what it did, because a debug view that can silently draw nothing reads exactly like a mesh
## that is not there.
func set_wireframe(on: bool) -> void:
	_wireframe = on
	_system.wireframe = on
	var hidden := 0
	for suffix in ["Deck", "Air"]:
		for node in find_children("*%s*" % suffix, "MeshInstance3D", true, false):
			(node as VisualInstance3D).layers = 0 if on else 1
			hidden += 1
	print("wireframe %s: %d deck/air mesh(es) %s" % [
		"on" if on else "off", hidden, "hidden" if on else "restored"
	])


## The camera-local basis for a view key, or `null` when the event is not one of them.
##
## The ship looks along `-Z`, `+Y` is up and `+X` is right, so a rotation about `Y` swings the view
## horizontally and one about `X` swings it vertically.
func _view_for(event: InputEventKey) -> Variant:
	if Bindings.matches(event, String(SpacesimSettings.get_value("bindings.view_forward"))):
		return Basis.IDENTITY
	if Bindings.matches(event, String(SpacesimSettings.get_value("bindings.view_back"))):
		return Basis(Vector3.UP, PI)
	if Bindings.matches(event, String(SpacesimSettings.get_value("bindings.view_left"))):
		return Basis(Vector3.UP, PI * 0.5)
	if Bindings.matches(event, String(SpacesimSettings.get_value("bindings.view_right"))):
		return Basis(Vector3.UP, -PI * 0.5)
	if Bindings.matches(event, String(SpacesimSettings.get_value("bindings.view_up"))):
		return Basis(Vector3.RIGHT, PI * 0.5)
	if Bindings.matches(event, String(SpacesimSettings.get_value("bindings.view_down"))):
		return Basis(Vector3.RIGHT, -PI * 0.5)
	return null


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
	# **The scene owns a local `RenderingDevice`** (the surface maps bake on it), and one left alive to be
	# destroyed at teardown segfaults the process on exit — after everything else has shut down cleanly, which
	# is what makes it look unrelated.
	if _system != null:
		_system.close()
	get_tree().quit()


## Whether a binding's key is held. Read per frame rather than cached, so rebinding one takes
## effect without anything having to notice.
func _held(binding_key: String) -> bool:
	var code := Bindings.keycode_of(String(SpacesimSettings.get_value(binding_key)))
	return code != KEY_NONE and Input.is_physical_key_pressed(code)


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
## Whether the player's hull is drawn. **One place to ask**, so the HUD, the near plane and the material
## cannot disagree about it — and it reads the settings rather than a variable, which is what makes the
## value hot and what makes it survive a restart.
func ship_is_visible() -> bool:
	return bool(SpacesimSettings.get_value("ship.visible"))


func _apply_settings() -> void:
	_camera.fov = SpacesimSettings.get_value("camera.fov")
	# **The one writer of the hull's visibility.** Read from the setting rather than a variable, so the file
	# stays hot by construction.
	var hull := _ship.get_node_or_null("Hull") if _ship != null else null
	if hull != null:
		(hull as MeshInstance3D).visible = ship_is_visible()
	# The camera sits behind the hull, on the ship's own basis. Only the distance is settable; the height
	# above the hull is part of what the ship is.
	var offset := PlayerShip.CAMERA_OFFSET
	offset.z = float(SpacesimSettings.get_value("camera.ship_distance"))
	_camera.position = offset
	# The exposure's ceiling, hot like everything else here: `exposure.range_stops` is in stops above
	# the light-adapted floor, and 32.0 is the whole window with no cap on the derived value.
	_exposure_pass.max_multiplier = SpacesimExposure.max_multiplier_for_stops(
		float(SpacesimSettings.get_value("exposure.range_stops"))
	)
	_markers.rebuild_pool(int(SpacesimSettings.get_value("markers.pool_size")))
	_markers.font_size = int(SpacesimSettings.get_value("markers.font_size"))
	_markers.margin = float(SpacesimSettings.get_value("markers.margin"))
	_markers.selected_color = SpacesimSettings.get_value("markers.selected_color")


func _on_setting_changed(key: String, _value: Variant) -> void:
	match key:
		"camera.fov", "camera.ship_distance", "ship.visible", "markers.pool_size", "markers.font_size", "markers.margin", "markers.selected_color", "exposure.range_stops":
			_apply_settings()


## Click to take the mouse back after Esc released it.
func _capture_mouse() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return
	_look = Vector2.ZERO
	_skip_next_motion = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _process(delta: float) -> void:
	var frames := Engine.get_frames_per_second()
	if frames <= 0:
		_fps.text = "-- fps"
	else:
		_fps.text = "%d fps    %.1f ms" % [frames, 1000.0 / float(frames)]
	# A screen is open, so the world is frozen and there is nothing to redraw it against.
	if _screen == null:
		_update_view(delta)


func _physics_process(delta: float) -> void:
	if _screen != null:
		return

	# **The stop key is edge-triggered**, so it puts the throttle at zero now rather than winding it down.
	var throttle: float = 0.0 if _throttle_stop else _ship.throttle
	_throttle_stop = false
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
		# The controller clamps to its own range; one place for the limit.
		"throttle": throttle,
		"pitch": -_look.y * sensitivity,
		"yaw": _look.x * sensitivity,
		"roll": roll,
	}
	_look = Vector2.ZERO

	_ship.step(delta, input)
	_system.frame_tree.evaluate()
	_sync_player_location()


## Everything that is **drawn** rather than simulated, and it runs once per drawn frame.
##
## **Presentation belongs here and not in `_physics_process`**, and two reasons point the same way.
## The physics tick is pinned to `physics/common/physics_ticks_per_second` (60), so anything derived
## there is quantised to it — the camera among them, and nothing interpolates it because
## `physics/common/physics_interpolation` is off. And when a frame runs long Godot takes up to
## `max_physics_steps_per_frame` (8) physics steps before drawing one frame, so every call below used
## to run **up to eight times for a single frame** — the work multiplying exactly when there was the
## least time for it. See vault `SpaceSim/Engine Review 2026-10-15 — Actions.md`.
##
## Nothing here feeds the simulation, which is what makes the split safe: the ship has already been
## stepped and the frame tree already evaluated by the time this runs.
##
## **Every transform read here is the INTERPOLATED one**, because `physics/common/physics_interpolation`
## is on and this is not the physics frame. `get_global_transform()` is only accurate to the most
## recent physics tick, so deriving the sky, the LOD or the markers from it would describe a different
## frame than the one being drawn — a lag no interpolation could undo. Godot's own note on
## `get_global_transform_interpolated` names this exact case: "frame-based operations that take place
## in `_process` … examples include `Camera3D`s focusing on a node".
##
## `Camera3D`'s *methods* already do this for us — `unproject_position` reads `get_camera_transform()`,
## which returns the interpolated transform outside the physics frame — so only the direct
## `global_transform` reads need saying out loud.
## How often the readout is rebuilt, in seconds. **Everything on it either moves at human speed** — the
## date, the frame, names, the selected target — **or jitters faster than anyone can read** — altitude
## and speed to a centimetre. It was rebuilt every drawn frame, which is a 13-line string with a format
## per field and a `PackedStringArray` to join it, sixty times a second, for a display. Measured at
## 0.12% of a frame it is not a cost problem; it is a *shape* problem, and this is the shape.
const HUD_INTERVAL := 0.1
var _hud_since := 0.0

## **Nothing here may touch the `RenderingDevice`.** It belongs to the render thread and its RID allocator
## is not thread safe — reading it from `_process` demonstrated that with thousands of `Element limit
## reached` errors. The exposure metre's numbers are read *inside* the pass, on the render thread, and the
## readback that reported them (and printed every jump) was an instrument from a landing investigation; it
## is gone, with its state, rather than left running in the game.



## **Which code is running, said once at startup.**
##
## A session outlives commits: a three-minute flight spans a fix, and the console it leaves behind then
## names line numbers that no longer exist in the tree — which is unfalsifiable from outside and cost a
## round of it already. One `git rev-parse` costs nothing and makes every pasted console self-describing,
## including whether the tree had uncommitted changes when it started.
func _print_build() -> void:
	var git := SpacesimGit.new(ProjectSettings.globalize_path("res://"))
	var result := git.run(["rev-parse", "--short", "HEAD"])
	var head := git.text(result).strip_edges() if result["ok"] else ""
	if head.is_empty():
		print("SpaceSim: build unknown — no git metadata in the project directory")
		return
	print("SpaceSim: build %s%s" % [head, "" if git.is_clean() else ", with uncommitted changes"])


## **The air, as one volumetric march over the frame**, when the setting asks for it, or nothing at all.
##
## The gate is the setting, read through `get_value` so it stays hot, and the pass is told `blend = 0` when the
## air should not be drawn — a frame with it off is left exactly as it was drawn.
##
## **The tier test is `update_lod`'s own**, not a second opinion about size. The pass dispatches over the whole
## frame, so an atmosphere too small to be a disc costs a full-screen compute pass to draw nothing — measured
## as 340 -> 240 fps in empty space. `SpacesimLod` owns the arithmetic and the threshold, and borrowing both is
## what keeps "too small to draw" one rule in the project. **A distance gate was tried and is wrong in the
## other direction**: four atmosphere-radii made the air vanish until the body covered a quarter of the screen,
## which reads as the LOD being skipped.
func _update_atmosphere_volume(observer: Vector3) -> void:
	if _atmosphere_pass == null or _camera == null:
		return
	if not bool(SpacesimSettings.get_value("render.atmosphere_volume")):
		_atmosphere_pass.prepare(_camera, Vector3.ZERO, 0.0, 0.0, Vector3.UP, {}, 0.0)
		return
	var air := _system.air_for_eye(observer)
	if air.is_empty():
		_atmosphere_pass.prepare(_camera, Vector3.ZERO, 0.0, 0.0, Vector3.UP, {}, 0.0)
		return
	var distance := observer.distance_to(air["centre"])
	var pixel := SpacesimLod.pixel_angle(_camera.fov, float(_camera.get_viewport().size.y))
	var screen := SpacesimLod.screen_radius_pixels(
		SpacesimLod.angular_radius(float(air["atmosphere_radius"]), distance), pixel
	)
	if screen < SpacesimLod.POINT_TIER_SCREEN_RADIUS:
		_atmosphere_pass.prepare(_camera, Vector3.ZERO, 0.0, 0.0, Vector3.UP, {}, 0.0)
		return
	_atmosphere_pass.prepare(
		_camera, air["centre"], float(air["planet_radius"]), float(air["atmosphere_radius"]),
		air["sun_direction"], air["air"], 1.0, air.get("deck", {})
	)


func _update_view(delta: float) -> void:
	var eye: Transform3D = _camera.get_global_transform_interpolated()
	var observer: Vector3 = _ship.get_global_transform_interpolated().origin
	_system.aim_sun_at(observer)
	# **The air is one march over the whole frame** (`SpacesimAtmospherePass`), told which body to march — or
	# nothing — below. The decks are not built: their mechanism is `Cloud Volumes` §6a's decision, and a deck
	# drawn before this pass gets its air in front for free, because this pass attenuates what is already in
	# the colour buffer.
	_system.update_sky(_camera)
	# **The tessellation follows from where the camera is**, so it is decided here, once a frame, next to
	# the other things that depend on the eye rather than on the world.
	_system.update_lod(_camera, delta)
	# **The exposure is no longer decided here.** It is the metre's, on the GPU, applied to the finished
	# frame — see `SpacesimExposurePass` and the lighting plan's §6a. What this function owes the pass is
	# the frame's own delta, because `_render_callback` has no clock of its own.
	_exposure_pass.frame_delta = delta
	_update_atmosphere_volume(observer)
	_update_markers(_camera)
	_update_camera(_camera)
	_hud_since += delta
	if _hud_since >= HUD_INTERVAL:
		_hud_since = 0.0
		_update_hud()



## The player is *inside* the ship while flying, so their location follows it. They are separate
## entities — containment is frame membership, which is what makes "which ship am I in" readable
## from the player's own location. Nothing can be entered yet, so the two currently coincide.
func _sync_player_location() -> void:
	var frame := _ship.get_parent() as Frame
	if frame == null:
		return
	# **Mutated, not replaced.** This runs every physics tick and a `Location` is a `RefCounted`, so one
	# allocation per tick was garbage for nothing. The player's location is a single piece of state that
	# changes in place, and nothing keeps an older one — the only readers use it inside their own call.
	var location: Location = _session.player.location
	if location == null:
		location = Location.new()
		_session.player.location = location
	location.frame_id = frame.frame_id
	location.position = _ship.position


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
	var near: float = range_for_frame.x
	# **A drawn ship sets the near plane, because its hull is only ~23 m in front of the camera.** The
	# frame's own near plane is a depth-precision knob and deep space's is 100 m, which clips the whole
	# hull away — so showing the ship anywhere means bringing the plane inside it. The cost is paid only
	# while the ship is shown, which is why the toggle is the thing that pays it.
	if ship_is_visible():
		near = minf(near, float(SpacesimSettings.get_value("camera.ship_distance")) * 0.5)
	camera.near = near
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


## **A black outline, because the readout has to survive a blown-out frame.** The exposure's own flash is the
## case that matters: while the frame is white, an unoutlined label is white on white and the one instrument
## that would say what the metre is doing is the thing that disappears. The marker labels already do this
## (`SpacesimMarkers`); the HUD did not.
const HUD_OUTLINE := Color(0.0, 0.0, 0.0, 0.9)
const HUD_OUTLINE_SIZE := 6


func _outline(label: Label, font_size: int) -> void:
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_outline_color", HUD_OUTLINE)
	label.add_theme_constant_override("outline_size", HUD_OUTLINE_SIZE)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)
	_ui_layer = layer

	var label := Label.new()
	label.name = "Readout"
	label.position = Vector2(24.0, 18.0)
	_outline(label, 17)
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
	_outline(fps, 17)
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
				"date        %s" % SpacesimWorldTime.format(_session.world_time),
				"settings    %s" % SpacesimSettings.path(),
				"frame       %s" % frame.name,
				"altitude    %s" % SpacesimMarkers.format_distance(_ship.altitude()),
				"speed       %s   (%.0f%% of local)" % [_speed(_ship.speed), fraction * 100.0],
				"nearest     %s at %s" % [_ship.nearest_name, SpacesimMarkers.format_distance(_ship.nearest_distance)],
				"local unit  %s" % SpacesimMarkers.format_distance(length),
				"state       %s" % contact,
				"target      %s" % target,
				"",
				"bodies      %s, %d triangles" % [bodies, _system.triangles()],
				(
					"ship        %s at %s"
					% [
						"visible" if ship_is_visible() else "hidden",
						SpacesimMarkers.format_distance(
							float(SpacesimSettings.get_value("camera.ship_distance"))
						),
					]
				),
				"",
				(
					"%s/%s throttle    %s stop    mouse look    %s/%s roll    Esc release mouse"
					% [
						_binding("bindings.throttle_up"),
						_binding("bindings.throttle_down"),
						_binding("bindings.throttle_stop"),
						_binding("bindings.roll_left"),
						_binding("bindings.roll_right"),
					]
				),
				(
					"view: %s fwd  %s back  %s left  %s right  %s up  %s down"
					% [
						_binding("bindings.view_forward"),
						_binding("bindings.view_back"),
						_binding("bindings.view_left"),
						_binding("bindings.view_right"),
						_binding("bindings.view_up"),
						_binding("bindings.view_down"),
					]
				),
				(
					"%s personal data    %s settings    %s cycle target    %s bodies on/off    %s ship on/off"
					% [
						_binding("bindings.player_screen"),
						_binding("bindings.settings_screen"),
						_binding("bindings.cycle_target"),
						_binding("bindings.bodies_toggle"),
						_binding("bindings.ship_toggle"),
					]
				),
			]
		)
	)


## The key a binding currently names, for the readout.
##
## **The hints used to be hardcoded text beside a rebindable setting**, which meant changing a binding
## left the HUD telling the player to press a key that no longer did anything. Reading them from the
## registry is what keeps the two in step.
static func _binding(key: String) -> String:
	return String(SpacesimSettings.get_value(key))


static func _speed(metres_per_second: float) -> String:
	var magnitude := absf(metres_per_second)
	if magnitude >= 1.0e6:
		return "%.3f Mm/s" % (metres_per_second / 1.0e6)
	if magnitude >= 1.0e3:
		return "%.3f km/s" % (metres_per_second / 1.0e3)
	return "%.2f m/s" % metres_per_second
