extends SceneTree
## **Is the cloud deck drawn from both sides of its shell?** — the reproduction Evert should not have had to fly.
##
##     SHOT_ALT=3200 xvfb-run -a godot-double-mono --path . --script res://tests/probe_deck_sides.gd
##     SHOT_ALT=2900 xvfb-run -a godot-double-mono --path . --script res://tests/probe_deck_sides.gd
##
## Earth's deck has its base at ~1,436 m and its top at **~3,040 m**, so the two altitudes in the two runs
## chosen here sit either side of the shell: 3,200 m is outside it looking down at the tops, 2,900 m is
## *inside* it, under the ceiling. Evert, 2026-10-20: *"at exactly 3km altitude for this planet, with the
## clouds still below us, they disappear when I descend."*
##
## **The ship is held at the altitude every frame, not placed once.** The first attempt at this used the
## screenshot rig's one-shot placement and the ship flew 15,000 km away between frames — the flight
## controller owns its position, so a rig that writes it once measures where the ship went, not what was
## asked for. Holding it makes the altitude an input rather than a hope.
##
## It writes one PNG per run and prints the deck's own numbers, because "the clouds are missing" is a
## question with two halves — is the mesh drawn, and does the texture draw on it — and only the material's
## parameters plus the picture can tell them apart.

const SETTLE := 20
const AIM_PITCH := -10.0 ## degrees above the local horizontal; negative looks down at the deck

var _frames := 0
var _altitude := 0.0
var _ship: Node3D
var _camera: Camera3D
var _body: Node3D


func _initialize() -> void:
	_altitude = float(OS.get_environment("SHOT_ALT")) if OS.has_environment("SHOT_ALT") else 3000.0
	var packed: Variant = load("res://game/main.tscn")
	if packed == null:
		print("SIDES: could not load the game scene")
		quit(1)
		return
	get_root().add_child((packed as PackedScene).instantiate())


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_ship = _find_ship(get_root())
		_camera = _find_camera(get_root())
		_body = get_root().find_child("Earth", true, false) as Node3D
		if _ship == null or _camera == null or _body == null:
			print("SIDES: could not find the ship, the camera or Earth")
			return true
		# **The flight controller owns the ship's position**, so stop it asking for anything: the rig's job is
		# to watch from a fixed altitude, not to fly.
		if _ship.has_method("apply_input"):
			_ship.call("apply_input", {"throttle": 0.0})
	# **Held every frame**, after the game has had its turn.
	if _ship != null and _frames > 2:
		var up := (_ship.global_position - _body.global_position).normalized()
		_ship.global_position = _body.global_position + up * (6.371e6 + _altitude)
		if _frames == SETTLE:
			_aim_level(up)
	if _frames < SETTLE + 20:
		return false
	var path := "/tmp/deck_%d.png" % int(_altitude)
	var image := get_root().get_texture().get_image()
	if image == null:
		print("SIDES: no image")
		return true
	image.save_png(path)
	var offset: Vector3 = _find_ship(get_root()).global_position - _body.global_position
	print("SIDES: altitude %.0f m (asked %.0f), frame %s, -> %s"
		% [offset.length() - 6.371e6, _altitude, _frame_name(), path])
	_report_decks()
	return true


## **Level, with the local vertical as up** — assigned as a `Basis` because `look_at` fails silently when its
## target lands on the origin, and a shot that quietly looks the wrong way reads as a broken shader.
func _aim_level(up: Vector3) -> void:
	var forward := up.cross(Vector3.UP).cross(up).normalized()
	if forward.length() < 0.5:
		forward = up.cross(Vector3.RIGHT).normalized()
	var pitch := deg_to_rad(AIM_PITCH)
	var aimed := (up * sin(pitch) + forward * cos(pitch)).normalized()
	var right := aimed.cross(up).normalized()
	var true_up := right.cross(aimed).normalized()
	_camera.global_transform = Transform3D(Basis(right, true_up, -aimed), _camera.global_position)
	print("SIDES: aimed %.0f degrees above the local horizontal" % AIM_PITCH)


func _frame_name() -> String:
	var game := get_root().get_child(0)
	if game != null and "frame_name" in game:
		return str(game.get("frame_name"))
	return "?"


## Every number the deck's shader is actually given. **`eye` is the one that says which side of the shell the
## frame was taken from**: below 1.0 is inside it. The deck draws one sphere at its top radius, so that is the
## only boundary this report can speak about.
func _report_decks() -> void:
	var decks := 0
	for node in get_root().find_children("*Deck*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var material := mesh.material_override as ShaderMaterial
		if material == null:
			continue
		var cover := material.get_shader_parameter("cover") as Texture2D
		var raw_eye: Variant = material.get_shader_parameter("eye_local")
		var eye: Variant = raw_eye if raw_eye is Vector3 else null
		# **Every number read through a `Variant`, because a parameter that was never set returns null**
		# — `float(null)` is an error that aborts the whole report, and a report that dies is worse than none.
		var threshold: Variant = material.get_shader_parameter("threshold")
		var veil: Variant = material.get_shader_parameter("veil")
		var gain: Variant = material.get_shader_parameter("ramp_gain")
		var tau: Variant = material.get_shader_parameter("tau_full")
		decks += 1
		print("SIDES deck %-16s visible=%s mesh=%s map=%s threshold=%s veil=%s gain=%s tau_full=%s eye=%s"
			% [mesh.name, mesh.visible, mesh.mesh != null,
				"-" if cover == null else str(cover.get_width()),
				threshold, veil, gain, tau,
				"-" if eye == null else "%.6f" % eye.length()])
	print("SIDES: %d deck(s)" % decks)


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
