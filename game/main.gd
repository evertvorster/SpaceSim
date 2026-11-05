extends Node3D
## Fly **Sol** and land on planets.
##
## **The controls are the action registry's, not this file's.** Every key but Esc is an action declared in
## `SpacesimActions` with its bindings in `SpacesimBindingsStore`, and the bottom line of the HUD is
## generated from whatever is bound — so a list written here would be a second copy that drifts. It did:
## the version of this paragraph before 2026-10-25 had throttle on `W`/`S`, roll on `A`/`D`, and the error
## budget on the brackets, all three of which had moved. Read the registry, or the HUD.
##
## **Escape is a binding like any other** — the personal-data screen — and the mouse is captured while
## flying because mouse look reads relative motion. One key gives the pointer back, and it is **held**:
## `Insert` by default, in the Bindings tab with everything else.
##
## The solar system comes from `systems/sol.tres`; this script only adds input, the camera's
## render range and a readout. A different system file should not need this script changed.

const PlayerShip := preload("res://game/player_ship.gd")
const Frame := preload("res://addons/spacesim/coordinate/frame.gd")
const Location := preload("res://addons/spacesim/coordinate/location.gd")
const TravelScale := preload("res://addons/spacesim/travel/travel_scale.gd")
const Actions := preload("res://addons/spacesim/input/actions.gd")
const Devices := preload("res://addons/spacesim/input/devices.gd")
const BindingsStore := preload("res://addons/spacesim/input/bindings_store.gd")
const InputMapScript := preload("res://addons/spacesim/input/input_map.gd")
const ControlsScript := preload("res://addons/spacesim/input/controls.gd")
const Session := preload("res://addons/spacesim/save/session.gd")

const SYSTEM_PATH := "res://systems/sol.tres"

const MOUSE_SENSITIVITY_FALLBACK := 0.0015

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
## The camera's exposure attributes, held only so they can be put at **identity**: the frame-wide pass
## applies the multiplier, so anything here would be applied twice. See `SpacesimExposure`.
var _exposure: SpacesimExposure
## The frame-wide exposure pass: the metre and the multiply, on the GPU. See `SpacesimExposurePass`.
var _exposure_pass: SpacesimExposurePass
## **The fog, which is the atmosphere pass's one remaining live behaviour.** Evert, 2026-11-03: *"Can we re-enable
## fog? We disabled it for reasons when doing the layered atmosphere shaders."* The pass came back into the
## compositor for this alone: its air march is still unreachable (`MARCHES_DECK`), the shells own the air, and what
## is left in it is the medium at the eye — the cloud map read at the camera and ramped from the deck's base to its
## top. Re-enabled rather than re-implemented, because that code has been flown.
var _atmosphere_pass: SpacesimAtmospherePass
var _markers: SpacesimMarkers
var _ui_layer: CanvasLayer
var _player: SpacesimPlayer
var _settings_screen: SpacesimSettingsPanel
var _player_screen: SpacesimPlayerPanel
var _saved_games_screen: SpacesimSavedGamesPanel

## The player's bindings and what they are doing. Built after the session, because the store's first open
## is where an old `settings.cfg`'s keys are imported.
var _bindings: SpacesimBindingsStore
var _input_map: SpacesimInput
## **The degrees of freedom** — roll, pitch, yaw, throttle — which are dimensions with sources, not actions
## with a press. See the vault's *Flight Control*.
var _controls: SpacesimControls

## The screen that is open, or null. Having one open *is* being paused.
var _screen: SpacesimScreen

## Where closing the open screen goes, when it was opened *from* another screen. Null means the world.
var _back_to: SpacesimScreen
var _selected_index := -1
var _hud: Label
var _hints: Label
var _fps: Label
var _skip_next_motion := false
## Whether the body nodes are drawn at all — the debug key that hides them.
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
	# **`--debug` before anything can print.** The command line is read here because `_ready` is the first
	# place the game owns before a frame, and `SpacesimDebug.enabled` is what every diagnostic print checks.
	SpacesimDebug.enabled = (
		OS.get_cmdline_user_args().has("--debug") or OS.get_cmdline_args().has("--debug")
	)
	_exposure.identity()
	_exposure_pass = SpacesimExposurePass.new()
	# **The surface maps refine on the render thread**, through a pass of this camera's compositor: a bake is a
	# `RenderingDevice` dispatch, and a callback *is* the render thread. After the exposure pass, because it
	# writes no colour and must not sit between the frame and the metre.
	#
	# **The air is not a pass here any more.** It is `air_shell.gdshader` on each body's own geometry, so the
	# rasteriser's depth is what clips it and the exposure still meters the finished frame. `SpacesimAtmospherePass`
	# is left in the tree, unregistered: `march_deck`/`deck_span` are the deck-as-a-boundary machinery the second
	# shell will want, and deleting a 45 KB effect is its own commit rather than a footnote on this one.
	# **The fog composites before the exposure**, so the metre weighs the finished frame — the same ordering the air
	# march needed when it lived here, and still right for a veil over the view.
	_atmosphere_pass = SpacesimAtmospherePass.new()
	var compositor := Compositor.new()
	var effects: Array[CompositorEffect] = [_atmosphere_pass, _exposure_pass]
	compositor.compositor_effects = effects
	_camera.compositor = compositor
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

	# **The bindings are their own store**, beside the settings file; `open()` is where the sixteen old
	# `bindings.*` settings keys are imported, in memory, on the first run after this change.
	_bindings = BindingsStore.new()
	_bindings.open()
	_input_map = InputMapScript.new(_bindings)
	_controls = ControlsScript.new(_bindings)

	_settings_screen = SpacesimSettingsPanel.new()
	_settings_screen.configure(SpacesimSettings, _bindings)
	_register_screen(_settings_screen, "Settings")
	_player_screen = SpacesimPlayerPanel.new()
	_player_screen.configure(_player, _session, _system)
	# **Exit Game lives here, not on the settings screen.** Settings is where a value is edited and
	# throwing the edits away is Close's job; leaving the game is about the player, and the screen
	# that shows them is where it belongs.
	_player_screen.exit_requested.connect(_on_exit_requested)
	_register_screen(_player_screen, "Player")

	# The browser of what has been played, behind a button on the personal-data screen rather than a
	# key of its own. It is the one screen that can move the player, so it is the one that reports it.
	_saved_games_screen = SpacesimSavedGamesPanel.new()
	_saved_games_screen.configure(_player, _session, _system)
	# Opening it from the player screen closes that one on the way through: one screen open is what
	# being paused means, and `_open_screen` is where that rule lives.
	_player_screen.saved_games_requested.connect(
		_open_from.bind(_saved_games_screen, _player_screen)
	)
	# The settings screen has a key of its own, so this is a second way in rather than the only one:
	# entered here, it closes back here; entered by Alt+C, it closes to the world.
	_player_screen.settings_requested.connect(_open_from.bind(_settings_screen, _player_screen))
	_saved_games_screen.session_reloaded.connect(_place_observer_from_session)
	_register_screen(_saved_games_screen, "SavedGames")

	_capture_mouse()


## The screen hotkeys are handled here rather than in _unhandled_input, because Tab is also the
## UI's focus key and the UI system would consume it first. Handled here, Tab always toggles, and
## keyboard focus navigation still works for everything else.
func _input(event: InputEvent) -> void:
	# **A device being set up presses nothing.** While the settings screen names a device, its events are
	# consumed here — which is before `Control._gui_input`, so they cannot move a menu either. The screen
	# reads that device by polling, so what it is being set up with still arrives.
	if _is_being_configured(event):
		get_viewport().set_input_as_handled()
		return

	# **A binding being detected presses nothing** — but only for keys and pad buttons. A mouse click is
	# **not** intercepted here: the screen has a square of its own for that, and taking every click would
	# catch the one that presses the dialog's own buttons.
	if _settings_screen.is_detecting() and (
		event is InputEventKey or event is InputEventJoypadButton
	):
		_settings_screen.feed_capture(event)
		get_viewport().set_input_as_handled()
		return

	# **Every key and button event is fed, released ones too**: a release is what clears a held source,
	# and a screen that swallows it is why `release_all()` exists.
	if event is InputEventKey or event is InputEventMouseButton or event is InputEventJoypadButton:
		_input_map.feed(event)
		_controls.feed(event)

	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if _triggered(event, "settings_screen"):
		_toggle(_settings_screen)
		get_viewport().set_input_as_handled()
	elif _triggered(event, "player_screen"):
		_toggle(_player_screen)
		get_viewport().set_input_as_handled()


## Whether this event comes from the device the settings screen is configuring.
##
## `Viewport.push_input` runs `_input` before `Control._gui_input`, and marking the event handled there
## stops every later phase — so this one call keeps a pad out of the menus as well as out of the game.
func _is_being_configured(event: InputEvent) -> bool:
	var device := -1
	if event is InputEventJoypadButton:
		device = (event as InputEventJoypadButton).device
	elif event is InputEventJoypadMotion:
		device = (event as InputEventJoypadMotion).device
	if device < 0:
		return false
	var configuring: String = _settings_screen.configuring_device()
	return not configuring.is_empty() and Devices.name_of(device) == configuring


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event)
		return
	if _screen != null:
		return
	if event is InputEventMouseMotion:
		_ship_mouse_look(event)


func _handle_key(event: InputEventKey) -> void:
	if _screen != null:
		return

	if _triggered(event, "bodies_toggle"):
		_bodies_visible = not _bodies_visible
		# **On each body's own node, not on its meshes.** `update_lod` now decides a mesh's or a point's
		# visibility once a frame, and two writers of one flag is a flicker — so the key sets the
		# parent's, which composes with whatever the tier decided instead of fighting it.
		for body in _system.bodies:
			if body.node != null:
				body.node.visible = _bodies_visible
	elif _triggered(event, "cycle_target"):
		_cycle_target()
	elif _triggered(event, "throttle_stop"):
		_throttle_stop = true
	elif _triggered(event, "wireframe_toggle"):
		set_wireframe(not _wireframe)
	elif _view_for(event) != null:
		# **The camera looks along a direction in the SHIP's frame**, so mouse look still steers and the
		# chosen view stays put — which is what makes the same scene comparable from six sides.
		_camera.basis = _view_for(event)


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
	# **The toggle is a mode, and the mode is the setting**, so the key, the settings screen and the HUD cannot disagree
	# about what is being drawn. `rendered` is left alone: the key toggles between the two modes that draw something.
	SpacesimSettings.set_value("render.mode", "wireframe" if on else "flat")
	var hidden := 0
	for suffix in ["Deck", "Air"]:
		for node in find_children("*%s*" % suffix, "MeshInstance3D", true, false):
			(node as VisualInstance3D).layers = 0 if on else 1
			hidden += 1
	SpacesimDebug.say("wireframe %s: %d deck/air mesh(es) %s" % [
		"on" if on else "off", hidden, "hidden" if on else "restored"
	])


## The camera-local basis for a view key, or `null` when the event is not one of them.
##
## The ship looks along `-Z`, `+Y` is up and `+X` is right, so a rotation about `Y` swings the view
## horizontally and one about `X` swings it vertically.
func _view_for(event: InputEventKey) -> Variant:
	if _triggered(event, "view_forward"):
		return Basis.IDENTITY
	if _triggered(event, "view_back"):
		return Basis(Vector3.UP, PI)
	if _triggered(event, "view_left"):
		return Basis(Vector3.UP, PI * 0.5)
	if _triggered(event, "view_right"):
		return Basis(Vector3.UP, -PI * 0.5)
	if _triggered(event, "view_up"):
		return Basis(Vector3.RIGHT, PI * 0.5)
	if _triggered(event, "view_down"):
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
	_controls.feed_motion(event.relative)


## Pausing the game is the scene's business rather than the tree's: only the simulation needs to
## stop, and a screen has to keep running inside it.
func _toggle(screen: SpacesimScreen) -> void:
	if _screen == screen:
		_close_screen()
	else:
		_open_screen(screen)


func _open_screen(screen: SpacesimScreen) -> void:
	# **The game stops watching while a menu is open**, so nothing may be left held when it resumes.
	_input_map.release_all()
	if _screen != null:
		_screen.visible = false
		_screen.dismissed()
	_screen = screen
	_back_to = null
	screen.opened()
	screen.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


## Open a screen that belongs to another one, so its Close goes back there instead of dropping the
## player into the world. The browser and the configuration screen are reached this way from the
## personal-data screen; a screen opened by its own hotkey has no way back and closes to the world.
func _open_from(screen: SpacesimScreen, back: SpacesimScreen) -> void:
	_open_screen(screen)
	_back_to = back


func _close_screen() -> void:
	if _screen == null:
		return
	_screen.visible = false
	_screen.dismissed()
	_screen = null
	var back := _back_to
	_back_to = null
	# Back the way the player came, not out into the world — one Close, one step.
	if back != null:
		_open_screen(back)
	else:
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
## Whether this event is an action's edge. **One line, so the call sites read as actions** rather than as
## a chain of settings lookups.
func _triggered(event: InputEvent, action: String) -> bool:
	return _input_map.triggered(event, action, _controls.holds())


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
	# **The camera sits in the ship's frame and there is no hull** — see `PlayerShip.CAMERA_OFFSET` for why the box that
	# used to be here went. The offset is a constant, so nothing about the viewpoint is a setting.
	_camera.position = PlayerShip.CAMERA_OFFSET
	# The exposure's ceiling, hot like everything else here: `exposure.range_stops` is in stops above
	# the light-adapted floor, and 32.0 is the whole window with no cap on the derived value.
	_exposure_pass.max_multiplier = SpacesimExposure.max_multiplier_for_stops(
		float(SpacesimSettings.get_value("exposure.range_stops"))
	)
	_exposure_pass.adaptation_rate = float(
		SpacesimSettings.get_value("exposure.adaptation_rate")
	)
	_atmosphere_pass.fog_gain = float(SpacesimSettings.get_value("fog.gain"))
	_markers.rebuild_pool(int(SpacesimSettings.get_value("markers.pool_size")))
	_markers.font_size = int(SpacesimSettings.get_value("markers.font_size"))
	_markers.margin = float(SpacesimSettings.get_value("markers.margin"))
	_markers.selected_color = SpacesimSettings.get_value("markers.selected_color")


func _on_setting_changed(key: String, _value: Variant) -> void:
	match key:
		"camera.fov", "markers.pool_size", "markers.font_size", "markers.margin", "markers.selected_color", "exposure.range_stops", "exposure.adaptation_rate", "fog.gain":
			_apply_settings()
		# The HUD's switches are visibility, so they are read by the readout's own refresh — which is
		# once every `HUD_INTERVAL`, and would otherwise leave a toggle looking broken for a moment.
		"hud.readout", "hud.fps", "hud.key_hints":
			_apply_hud_visibility()


## **The mouse belongs to the ship while flying and to a screen while one is open**, which is the whole of
## the rule: no key releases it and no click takes it back. A capture warps the cursor, so the first motion
## after one is dropped rather than read as a spin.
func _capture_mouse() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return
	_skip_next_motion = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


## **Hold the free-mouse key to get the pointer back; releasing it flies again.** Captured, because mouse
## look reads relative motion and a free pointer hits the screen's edges and sits over the view; held rather
## than toggled, because a toggle leaves the ship in a state nobody asked for.
func _freed_by_key() -> bool:
	return _screen == null and _input_map.held("mouse_release")


func _process(delta: float) -> void:
	var frames := Engine.get_frames_per_second()
	if frames <= 0:
		_fps.text = "-- fps"
	else:
		_fps.text = "%d fps    %.1f ms" % [frames, 1000.0 / float(frames)]
	if _freed_by_key():
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif _screen == null and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_capture_mouse()

	# A screen is open, so the world is frozen and there is nothing to redraw it against.
	if _screen == null:
		_update_view(delta)


func _physics_process(delta: float) -> void:
	if _screen != null:
		return

	# **The degrees of freedom produce this frame's contribution each**, in radians for a rotation and a
	# fraction of the throttle for throttle. The mouse, a stick and a key differ only in how they arrive.
	_controls.pointer_sensitivity = float(SpacesimSettings.get_value("mouse.sensitivity"))
	_controls.step(delta)

	# **The stop key is edge-triggered**, so it puts the throttle at zero now rather than winding it down.
	var throttle: float = 0.0 if _throttle_stop else _ship.throttle
	_throttle_stop = false
	throttle += _controls.value("throttle")

	var pitch := _controls.value("pitch")
	var yaw := _controls.value("yaw")
	var roll := _controls.value("roll")

	var input := {
		# The controller clamps to its own range; one place for the limit.
		"throttle": throttle,
		"pitch": pitch,
		"yaw": yaw,
		"roll": roll,
	}

	_ship.step(delta, input)
	_system.frame_tree.evaluate()
	_sync_player_location()


## How often the readout is rebuilt, in seconds. **Everything on it either moves at human speed** — the
## date, the frame, names, the selected target — **or jitters faster than anyone can read** — altitude
## and speed to a centimetre. It was rebuilt every drawn frame, which is a 13-line string with a format
## per field and a `PackedStringArray` to join it, sixty times a second, for a display. Measured at
## 0.12% of a frame it is not a cost problem; it is a *shape* problem, and this is the shape.
const HUD_INTERVAL := 0.1
var _hud_since := 0.0

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


## **The fog: a medium at the eye, and the only thing the atmosphere pass still draws.**
##
## Evert, 2026-10-21, on what it is for: *"We are approximating based on the refined texture, and scaling based on
## distance between the top and the bottom of the cloud layer."* Two numbers, neither invented — the deck's own map
## read **at the camera** for how cloudy this patch is, and the camera's altitude through the layer's own thickness
## for how much of it is in front of you. Full at the base, nothing at the top, so the ramp's ends are geometry.
##
## **Why it belongs over the whole view and not inside the air shell**: the fog is what the camera is *sitting in*,
## not a segment on a ray. The shell marches per pixel and is clipped by depth; a veil at the eye is not, and that
## distinction is the one that made returning early on empty depth wrong on 2026-11-01 — it removed the fog from
## every pixel of sky, which is most of the frame when you are inside a band.
##
## **`blend = 1`**: the pass's composite weight is its only remaining dial, and the march it used to scale is dead
## code. Zero means "do not draw", which is what every early return below hands it.
func _update_fog(observer: Vector3) -> void:
	if _atmosphere_pass == null or _camera == null:
		return
	if _atmosphere_pass.fog_gain <= 0.0 or not bool(SpacesimSettings.get_value("render.atmosphere_volume")):
		_clear_fog()
		return
	var air := _system.air_for_eye(observer)
	if air.is_empty():
		_clear_fog()
		return
	var deck: Dictionary = air.get("deck", {})
	if deck.is_empty():
		_clear_fog()
		return
	# **Above the deck's top there is no fog, and the pass should not be dispatched to discover that.** The ramp is
	# full at the base and zero at the top, so a camera above it draws nothing; the pass still built a uniform set and
	# ran a full-frame dispatch every frame to composite an identity. Measured 2026-11-03 in flight: `blend=1.0
	# deck_weight=0.00`.
	var top_radius := float(deck.get("top_radius", 0.0))
	if top_radius <= 0.0 or observer.distance_to(air["centre"]) >= top_radius:
		_clear_fog()
		return
	_atmosphere_pass.prepare(
		_camera, air["centre"], float(air["planet_radius"]), float(air["atmosphere_radius"]),
		air["sun_direction"], air["air"], 1.0, deck
	)


## **Tell the pass to draw nothing**, which is `blend = 0`: it returns before it builds a pipeline or a uniform set,
## so a frame at a body with no deck, or with the fog switched off, costs nothing at all.
func _clear_fog() -> void:
	_atmosphere_pass.prepare(_camera, Vector3.ZERO, 0.0, 0.0, Vector3.UP, {}, 0.0)


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
##
## **Nothing here may touch the `RenderingDevice`.** It belongs to the render thread and its RID allocator
## is not thread safe — reading it from `_process` demonstrated that with thousands of `Element limit
## reached` errors.
func _update_view(delta: float) -> void:
	var eye: Transform3D = _camera.get_global_transform_interpolated()
	var observer: Vector3 = _ship.get_global_transform_interpolated().origin
	_system.aim_sun_at(observer)
	# **The air rides on the bodies themselves** (`air_shell.gdshader`, one shell per band), so nothing about it is
	# published from here: the scene hands each shell its eye, its star and the frame's rotation in `update_lod`.
	# The sky is a star field again, and `update_sky` says why.
	_system.update_sky(_camera)
	# **The tessellation follows from where the camera is**, so it is decided here, once a frame, next to
	# the other things that depend on the eye rather than on the world.
	# **The testing platform's mode, set before the walk** because `wireframe` is an input to it: the gate compares it, so
	# a mode change must open the walk like any other change in what is needed. `flat` and `rendered` are the same mesh
	# and the same material — one uniform short-circuits the fragment's texture reads — so only `wireframe` changes the
	# geometry and only `flat` changes the shading.
	var mode := String(SpacesimSettings.get_value("render.mode"))
	_system.wireframe = mode == "wireframe"
	_system.flat_shaded = mode == "flat"
	# **The ship's origin, not the camera's** — the camera's offset swings on a 32 m arm as the ship rotates, and at low
	# altitude that re-cut the mesh every frame. The level is a property of where the observer is.
	_system.update_lod(_camera, observer)
	# **The exposure is no longer decided here.** It is the metre's, on the GPU, applied to the finished
	# frame — see `SpacesimExposurePass` and the lighting plan's §6a. What this function owes the pass is
	# the frame's own delta, because `_render_callback` has no clock of its own.
	_exposure_pass.frame_delta = delta
	_update_fog(observer)
	# **EV compensation, on or off.** On is the metre's — a compute pass over the rendered pixels, so the exposure and
	# the frame cannot disagree. Off disables the pass, so the frame is drawn at Godot's own reference: no multiplier,
	# and a difference in the picture is a difference in the geometry rather than in the exposure.
	_exposure_pass.enabled = bool(SpacesimSettings.get_value("render.ev_compensation"))
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
	# **The frame kind alone sets the near plane.** It used to be pulled inside the ship's hull while the hull was
	# drawn, which is what made a placeholder box appear as a plate on the ground on approach; there is no hull now, so
	# the plane is a depth-precision knob and nothing else.
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

	# **Two labels in a column, not one block**, because the readout and the key hints are switched off
	# separately: `hud.readout` and `hud.key_hints`. One label could only be hidden whole.
	var column := VBoxContainer.new()
	column.name = "Readouts"
	column.position = Vector2(24.0, 18.0)
	column.add_theme_constant_override("separation", 18)
	layer.add_child(column)

	var label := Label.new()
	label.name = "Information"
	_outline(label, 17)
	column.add_child(label)
	_hud = label

	var hints := Label.new()
	hints.name = "KeyHints"
	_outline(hints, 17)
	column.add_child(hints)
	_hints = hints

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
				"mode        %s%s%s" % [
					String(SpacesimSettings.get_value("render.mode")),
					", depth tint" if bool(SpacesimSettings.get_value("render.depth_tint")) else "",
					", EV compensated" if bool(SpacesimSettings.get_value("render.ev_compensation")) else ", EV off",
				],
				"speed       %s   (%.0f%% of local)" % [_speed(_ship.speed), fraction * 100.0],
				"nearest     %s at %s" % [_ship.nearest_name, SpacesimMarkers.format_distance(_ship.nearest_distance)],
				"local unit  %s" % SpacesimMarkers.format_distance(length),
				"state       %s" % contact,
				"target      %s" % target,
				"",
				"bodies      %s, %d triangles, %d chunks, depth %d"
					% [bodies, _system.triangles(), _system.chunks(), _system.deepest_level()],
			]
		)
	)

	_hints.text = "\n".join(
		PackedStringArray(
			[
				(
					"%s/%s throttle    %s stop    mouse look    %s/%s roll"
					% [
						_hint("throttle_up"),
						_hint("throttle_down"),
						_hint("throttle_stop"),
						_hint("roll_left"),
						_hint("roll_right"),
					]
				),
				(
					"view: %s fwd  %s back  %s left  %s right  %s up  %s down"
					% [
						_hint("view_forward"),
						_hint("view_back"),
						_hint("view_left"),
						_hint("view_right"),
						_hint("view_up"),
						_hint("view_down"),
					]
				),
				(
					"%s personal data    %s settings    %s cycle target    %s bodies on/off"
					% [
						_hint("player_screen"),
						_hint("settings_screen"),
						_hint("cycle_target"),
						_hint("bodies_toggle"),
					]
				),
			]
		)
	)
	_apply_hud_visibility()


## **Each of the HUD's three parts is switched on its own** — see the registry's `hud.*` rows. Read
## here rather than cached, so a change on the settings screen is on screen before the player looks
## back; `_on_setting_changed` calls this for the same reason when a screen is open over the game.
func _apply_hud_visibility() -> void:
	_hud.visible = bool(SpacesimSettings.get_value("hud.readout"))
	_hints.visible = bool(SpacesimSettings.get_value("hud.key_hints"))
	_fps.visible = bool(SpacesimSettings.get_value("hud.fps"))


## The key an action currently names, for the readout.
##
## **The hints used to be hardcoded text beside a rebindable setting**, which meant changing a binding
## left the HUD telling the player to press a key that no longer did anything. Reading them from the
## bindings is what keeps the two in step — and `hint()` prefers a keyboard binding, because the hints
## are read at a keyboard.
func _hint(action: String) -> String:
	return _input_map.hint(action)


static func _speed(metres_per_second: float) -> String:
	var magnitude := absf(metres_per_second)
	if magnitude >= 1.0e6:
		return "%.3f Mm/s" % (metres_per_second / 1.0e6)
	if magnitude >= 1.0e3:
		return "%.3f km/s" % (metres_per_second / 1.0e3)
	return "%.2f m/s" % metres_per_second
