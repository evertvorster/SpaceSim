extends SceneTree
## Render one frame of the game offscreen and save it, so a picture can be looked at without a person.
##
##     xvfb-run -a godot-double-mono --path . --script res://tests/screenshot.gd
##
## The frame number and the output path come from SHOT_FRAMES and SHOT_PATH. It exists because
## headless Godot neither compiles shaders nor draws anything, and "is it visible" is not a
## question a headless test can answer.

var _frames := 0
var _target := 90

## Frames of the timed window, and its total. The window starts after the placement and a settle, so it
## measures the view that was asked for rather than the save's own position or the first frames' setup.
const SETTLE := 10
var _timed := 0
var _elapsed := 0.0


func _initialize() -> void:
	if OS.has_environment("SHOT_FRAMES"):
		_target = int(OS.get_environment("SHOT_FRAMES"))
	var packed: Variant = load("res://game/main.tscn")
	if packed == null:
		print("SHOT: could not load the game scene")
		quit(1)
		return
	var scene: Node = packed.instantiate()
	get_root().add_child(scene)
	# **The hull has to go before the first frame.** It is a few tens of metres from the camera, so it
	# fills the middle of every shot and drags the exposure metre, and a shot is of the world.
	_hide_ship()


func _process(delta: float) -> bool:
	_frames += 1
	if _frames == _target / 2 and OS.has_environment("SHOT_BODY"):
		_place_above(OS.get_environment("SHOT_BODY"), float(OS.get_environment("SHOT_ALT")))
		return false
	if _frames > _target / 2 + SETTLE and _frames <= _target:
		_timed += 1
		_elapsed += delta
	if _frames < _target:
		return false
	if OS.has_environment("SHOT_PROFILE"):
		_report_profile()
		return true
	var path := "/tmp/spacesim_shot.png"
	if OS.has_environment("SHOT_PATH"):
		path = OS.get_environment("SHOT_PATH")
	var image := get_root().get_texture().get_image()
	if image == null:
		print("SHOT: no image")
		return true
	var error := image.save_png(path)
	print("SHOT: frame ", _frames, " -> ", path, "  (", image.get_width(), "x", image.get_height(),
		", error ", error, ")")
	_report_decks()
	return true


## **Hide the player's ship, so a shot is of the world and not of the hull.** It sits a few tens of
## metres from the camera and fills the middle of every frame — which is where whatever is being looked
## at is — and at that range it also drags the exposure metre. `SHOT_SHIP=1` keeps it, for the shots
## that are *about* the ship.
func _hide_ship() -> void:
	if OS.has_environment("SHOT_SHIP"):
		return
	var ship := _find_ship(get_root())
	if ship == null:
		return
	for child in ship.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).visible = false


## **What the decks were actually drawn with.** A map that never refined looks exactly like a map that
## refined and is being sampled wrongly, and neither is visible in the file name — so the width, the
## threshold and the veil are printed, from the materials the frame was rendered with.
func _report_decks() -> void:
	var decks := 0
	for node in get_root().find_children("*Deck", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if not mesh.visible:
			continue
		var material := mesh.material_override as ShaderMaterial
		if material == null:
			continue
		var cover := material.get_shader_parameter("cover") as Texture2D
		decks += 1
		print("SHOT deck %-18s %sx%s  threshold=%.3f  veil=%.3f" % [
			mesh.name,
			"-" if cover == null else str(cover.get_width()),
			"-" if cover == null else str(cover.get_height()),
			float(material.get_shader_parameter("threshold")),
			float(material.get_shader_parameter("veil")),
		])
	print("SHOT: %d deck(s) in the tree" % decks)


## The frame cost of a view, as numbers. `SHOT_PROFILE=1` reports this **instead of** saving a picture
## — the same placement and the same aim, so the two modes measure the same view.
##
## **Why not read the frame rate off the picture**, which the HUD already draws: `Engine.get_frames_per_second`
## is a smoothed average that includes startup, and a *rate* alone cannot tell a geometry cost from an
## overdraw one. The monitors below can — draw calls and primitives say how much was submitted, and
## `TIME_PROCESS` says how much of that was the main thread's own work rather than the GPU's.
##
## `TIME_PROCESS` is in **seconds**; the video memory in **bytes**.
func _report_profile() -> void:
	var mean_ms := 1000.0 * _elapsed / float(maxi(_timed, 1))
	print("PROFILE: %s" % _view_name())
	print("PROFILE:   %-34s %.2f ms/frame over %d frames  (%.1f fps)" % [
		"mean frame", mean_ms, _timed, 1000.0 / maxf(mean_ms, 0.001)
	])
	print("PROFILE:   %-34s %.2f ms" % ["TIME_PROCESS",
		1000.0 * Performance.get_monitor(Performance.TIME_PROCESS)])
	print("PROFILE:   %-34s %.2f ms" % ["TIME_PHYSICS_PROCESS",
		1000.0 * Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)])
	print("PROFILE:   %-34s %d" % ["RENDER_TOTAL_DRAW_CALLS_IN_FRAME",
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))])
	print("PROFILE:   %-34s %d" % ["RENDER_TOTAL_PRIMITIVES_IN_FRAME",
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))])
	print("PROFILE:   %-34s %d" % ["RENDER_TOTAL_OBJECTS_IN_FRAME",
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))])
	print("PROFILE:   %-34s %.1f MB" % ["RENDER_VIDEO_MEM_USED",
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])


## What was asked for, so a run of these can be told apart in a log without cross-referencing.
func _view_name() -> String:
	var body := OS.get_environment("SHOT_BODY") if OS.has_environment("SHOT_BODY") else "(the save's own place)"
	var altitude := OS.get_environment("SHOT_ALT") if OS.has_environment("SHOT_ALT") else "-"
	var aim := "default"
	if OS.has_environment("SHOT_PITCH"):
		aim = "pitch=%s" % OS.get_environment("SHOT_PITCH")
	elif OS.has_environment("SHOT_AIM"):
		aim = OS.get_environment("SHOT_AIM")
	return "%s  alt=%s  aim=%s" % [body, altitude, aim]


## Put the ship where a test wants it: on the side of the start body that faces the star, at a chosen
## altitude. Without this the shot shows whatever the last save was, which is usually night.
##
## `SHOT_AIM=level` pitches the camera along the **horizon** instead of down at the body. It matters
## because the default aim is always a radial, so no shot taken with it can contain a horizon, a limb
## or a sky — and "is there a sky" is exactly the question an atmosphere has to answer. `SHOT_AIM` is
## otherwise unset, which keeps every existing shot looking at the body.
func _place_above(body_name: String, altitude: float) -> void:
	var ship := _find_ship(get_root())
	var body_name_real := body_name if body_name != "star" else "Sol"
	var body := get_root().find_child(body_name_real, true, false) as Node3D
	if ship == null or body == null:
		print("SHOT: could not find the ship or ", body_name)
		return
	var to_star := -body.global_position.normalized()
	ship.global_position = body.global_position + to_star * (6.371e6 + altitude)
	# Point the camera at the body, so the shot shows it rather than empty space.
	var camera := _find_camera(get_root())
	if camera == null:
		return
	# `SHOT_PITCH` aims at a given elevation above the body's own horizon: 0 is level, 90 is straight
	# up, -90 is straight down. The general case, and what a sky gradient has to be measured with —
	# `level` and `up` are the two ends of it.
	if OS.has_environment("SHOT_PITCH"):
		var up := (ship.global_position - body.global_position).normalized()
		var tangent := up.cross(Vector3.UP)
		if tangent.length() < 0.5:
			tangent = up.cross(Vector3.RIGHT)
		tangent = tangent.normalized()
		var pitch := deg_to_rad(float(OS.get_environment("SHOT_PITCH")))
		var forward := (up * sin(pitch) + tangent * cos(pitch)).normalized()
		# Keep the horizon level in frame: the camera's up is the local vertical, minus whatever the
		# view direction already accounts for.
		var cam_up := up - forward * up.dot(forward)
		if cam_up.length() < 0.01:
			cam_up = tangent
		_aim(camera, forward, cam_up.normalized())
		_report_aim(body, camera, "pitch=%d" % int(round(rad_to_deg(pitch))))
		return
	# `up` looks straight up the body's own vertical — the zenith, which is where the sky was black.
	if OS.get_environment("SHOT_AIM") == "up":
		var up := (ship.global_position - body.global_position).normalized()
		var side := up.cross(Vector3.UP)
		if side.length() < 0.5:
			side = up.cross(Vector3.RIGHT)
		_aim(camera, up, side.normalized())
		_report_aim(body, camera, "up")
		return
	if OS.get_environment("SHOT_AIM") == "level":
		# **Level, relative to the body's own up**, which is the placement geometry rather than the
		# camera's: the camera is a child of the ship and gets reparented by the frame tree, so anything
		# derived from where it happens to be is a moving target.
		#
		# The basis is built and assigned directly, **not with `look_at`**. `look_at` fails silently-ish
		# (an error to the log, the old orientation kept) when the target lands on the origin, and an
		# earlier version of this could produce exactly that — which meant every "level" shot was really
		# aimed straight down and read as a broken shader. A basis that is constructed cannot do that.
		var up := (ship.global_position - body.global_position).normalized()
		var along := up.cross(Vector3.UP)
		if along.length() < 0.5:
			along = up.cross(Vector3.RIGHT)
		_aim(camera, along.normalized(), up)
		_report_aim(body, camera, "level")
		return
	# The up vector must not be parallel to the look direction, or look_at is degenerate and the
	# camera ends up pointing nowhere — which reads as "the planet is not rendered".
	var aim := body.global_position + to_star * (6.371e6 * 0.4)
	var look := (aim - camera.global_position).normalized()
	var up := Vector3.UP
	if absf(look.dot(up)) > 0.99:
		up = Vector3.RIGHT
	camera.look_at(aim, up)
	_report_aim(body, camera, "radial")


## Point the camera **without `look_at`**, which fails when the target lands on the origin — it logs an
## error, keeps the old orientation, and the shot then reads as a broken shader rather than a broken
## rig. A constructed basis cannot do that.
##
## `forward` and `up` must be perpendicular, in world axes. Godot's convention: -Z forward, +Y up.
func _aim(camera: Camera3D, forward: Vector3, up: Vector3) -> void:
	var right := forward.cross(up).normalized()
	var true_up := right.cross(forward).normalized()
	camera.global_transform = Transform3D(Basis(right, true_up, -forward), camera.global_position)


## Say where the camera ended up pointing, in **degrees above the local horizontal**.
##
## Worth printing because the aim is set once, on one frame, and the ship is reparented by the frame
## tree afterwards — so "did the camera stay where I put it" is not something a picture answers, and a
## shot that quietly looks the wrong way reads as a broken shader rather than a broken rig. It has
## already caught one: `look_at` failing left every "level" shot aimed straight down.
##
## `up` is the body's own vertical taken from the *ship*, not from the camera.
func _report_aim(body: Node3D, camera: Camera3D, mode: String) -> void:
	var up := (body.global_position - camera.global_position).normalized()
	var forward := -camera.global_transform.basis.z
	var elevation := rad_to_deg(asin(clampf(forward.dot(-up), -1.0, 1.0)))
	print("SHOT: aim=%s elevation=%.1f deg" % [mode, elevation])


func _find_camera(node: Node) -> Camera3D:
	for child in node.get_children():
		if child is Camera3D:
			return child
		var found := _find_camera(child)
		if found != null:
			return found
	return null


func _find_ship(node: Node) -> Node3D:
	for child in node.get_children():
		if child is Camera3D:
			return node
		var found := _find_ship(child)
		if found != null:
			return found
	return null
