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


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == _target / 2 and OS.has_environment("SHOT_BODY"):
		_place_above(OS.get_environment("SHOT_BODY"), float(OS.get_environment("SHOT_ALT")))
		return false
	if _frames < _target:
		return false
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
	return true


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
	if OS.get_environment("SHOT_AIM") == "level":
		# Along the horizon: perpendicular to the local vertical, with the vertical kept as "up" so
		# the horizon sits level in the frame rather than rolled.
		var radial := (ship.global_position - body.global_position).normalized()
		var along := radial.cross(Vector3.UP)
		if along.length() < 0.01:
			along = radial.cross(Vector3.RIGHT)
		camera.look_at(camera.global_position + along.normalized(), radial)
		return
	# The up vector must not be parallel to the look direction, or look_at is degenerate and the
	# camera ends up pointing nowhere — which reads as "the planet is not rendered".
	var aim := body.global_position + to_star * (6.371e6 * 0.4)
	var look := (aim - camera.global_position).normalized()
	var up := Vector3.UP
	if absf(look.dot(up)) > 0.99:
		up = Vector3.RIGHT
	camera.look_at(aim, up)


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
