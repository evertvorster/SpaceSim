extends SceneTree
## Does the exposure pass change the game's frame? — the end-to-end check for Track B3.
##
##     xvfb-run -a godot-double-mono --path . --script res://tests/probe_frame_exposure.gd
##
## ## Why this exists on top of `probe_compositor.gd`
##
## That probe proved the *mechanism* — a GDScript `CompositorEffect` fires, reaches the colour texture, and
## writing it changes the frame — but it ran on a scene of its own with a shader of its own. This one runs
## **the game**, with the game's camera, and asks whether `SpacesimExposurePass` is attached, running, and
## changing what is drawn.
##
## **The A/B is inside one run**, using the effect's inherited `enabled` flag, so nothing about the tree
## changes between the two halves — a comparison across two runs would also have to rule out the
## screenshot rig's own ~2.24% noise floor, which this does not need to.
##
## **What it cannot say:** whether the result *looks* right. The metre's target, the weighting and the
## adaptation rate are all judgements about a picture, and this is a mean brightness. **That is what the
## flight test is for.**
##
## Note that the suite cannot do any of this: `tests/run.sh` runs Godot `--headless`, where there is no
## `RenderingDevice` and no rendering at all.

const MAIN_SCENE := "res://game/main.tscn"
const SETTLE_FRAMES := 40
const SAMPLE_FRAMES := 20


func _initialize() -> void:
	var packed: Variant = load(MAIN_SCENE)
	if packed == null:
		print("FRAME EXPOSURE: could not load the game scene")
		quit(1)
		return
	get_root().add_child(packed.instantiate())


var _frames := 0
var _phase := 0
var _sum := 0.0
var _samples := 0
var _on := 0.0
var _off := 0.0
var _status := ""
var _attached := false


func _read() -> float:
	var image := get_root().get_texture().get_image()
	var size := image.get_size()
	# A block at the centre of the frame rather than one pixel: the scene's middle is sky or a body
	# depending on where the ship is, and an average over a patch is the honest "is this frame brighter".
	var total := 0.0
	var count := 0
	for y in range(size.y * 2 / 5, size.y * 3 / 5, 8):
		for x in range(size.x * 2 / 5, size.x * 3 / 5, 8):
			total += image.get_pixel(x, y).get_luminance()
			count += 1
	return total / maxf(count, 1)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < SETTLE_FRAMES:
		return false

	var main: Node = get_root().get_node_or_null("Main")
	if main == null:
		print("FRAME EXPOSURE: no Main node")
		return true
	var pass_effect: CompositorEffect = main.get("_exposure_pass")
	_attached = pass_effect != null
	if pass_effect == null:
		_report()
		return true

	match _phase:
		0:
			# --- the game as it runs ---------------------------------------------------------------
			pass_effect.enabled = true
			# `call` rather than a direct call: the variable is typed `CompositorEffect`, and the method is
			# the pass's own.
			_status = str(pass_effect.call("status"))
			_phase = 1
			_frames = 0
		1:
			_sum += _read()
			_samples += 1
			if _samples >= SAMPLE_FRAMES:
				_on = _sum / _samples
				_sum = 0.0
				_samples = 0
				pass_effect.enabled = false
				_phase = 2
				_frames = 0
		2:
			# Let the disabled state settle before sampling it: the metre's own value is frozen, but the
			# frame still has to be drawn without the multiply.
			if _frames < SETTLE_FRAMES:
				return false
			_sum += _read()
			_samples += 1
			if _samples >= SAMPLE_FRAMES:
				_off = _sum / _samples
				_report()
				return true
	return false


func _report() -> void:
	print("FRAME EXPOSURE — is the pass attached to the game, and does it change the frame?")
	print("FRAME EXPOSURE:")
	print("FRAME EXPOSURE: a pass is attached to the camera   %s" % _attached)
	print("FRAME EXPOSURE: the effect's own status            %s" % _status)
	print("FRAME EXPOSURE:")
	print("FRAME EXPOSURE: mean centre luminance, pass ON     %.5f" % _on)
	print("FRAME EXPOSURE: mean centre luminance, pass OFF    %.5f" % _off)
	var ratio := _on / maxf(_off, 1e-9)
	print("FRAME EXPOSURE: ratio                              %.4f" % ratio)
	print("FRAME EXPOSURE:")
	if not _attached:
		print("FRAME EXPOSURE: **the pass is NOT attached** — `main.gd` did not build one, or the member")
		print("FRAME EXPOSURE: name changed. The exposure is per-path again and Track B3 is not wired.")
	elif absf(_on - _off) < 0.002:
		print("FRAME EXPOSURE: attached but the frame did not move. Either the pass is not dispatching in")
		print("FRAME EXPOSURE: the game's render path, or its multiplier is 1.0 — check its status line.")
	else:
		print("FRAME EXPOSURE: **the pass is attached and it changes the frame** (x%.3f)." % ratio)
		print("FRAME EXPOSURE: OFF is the unexposed absolute frame, which is what identity exposure means;")
		print("FRAME EXPOSURE: ON is the metre's. Whether the metre's value is the RIGHT one is a")
		print("FRAME EXPOSURE: judgement about a picture, and that is Evert's flight test.")
