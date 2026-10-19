extends SceneTree
## **F3's probe: what the ocean layer costs as a second pass — measured with the exposure pass OFF and the pixels
## absolute.**
##
##     xvfb-run -a godot-double-mono --path . --script res://tests/probe_surface_cost.gd --disable-vsync
##
## `COST_BODY` (default `planet:earth`), `COST_ALT` (default 200 km) and `COST_FRAMES` (default 120 a phase)
## override the body, the altitude and the length of a phase.
##
## ## What is being asked
##
## A body with liquid is drawn **twice**: the ground by `body_surface.gdshader` and the sea by
## `body_ocean.gdshader`, coplanar over the same triangles, each discarding the complement of its own side of the
## sea level. The two are disjoint, so nothing z-fights — but `discard` in **both** layers means the body has no
## depth prepass and no hierarchical-z, and the vertex and raster work is paid twice. Evert, 2026-10-19: *"water
## and land are fundamentally different things"* — a reason for two shaders, not a reason for two passes left
## unexamined. **This probe decides whether the second pass is worth merging into one shader with a branch (which
## would also let the discards go), or whether it is cheap enough to keep.**
##
## ## The rig rules it follows, and they cost a session to learn
##
## 1. **The exposure pass is OFF, and the exposure is a FIXED number.** The adaptive pass makes every frame a
##    different picture from the one before, and it is GPU work of its own — measuring a pass while it runs is
##    measuring the rig. Evert, 2026-10-19: *"It needs to switch off the EV pass, and work on the absolute values
##    of the pixels."* So the pass is disabled **and** the multiplier is pinned. Pinning it to 1.0 was the first
##    attempt and it was still useless: the unexposed frame sits near black (mean luminance 0.006), so sea and land
##    both read as one or two levels and every picture comparison is crushed. The rig now **calibrates once** —
##    measures the frame, sets one multiplier that puts middle grey in range, and holds it — so the pixels are
##    absolute and readable at the same time. The chosen multiplier is printed.
## 2. **The clock is the GPU's, not the frame's.** `RenderingServer.viewport_get_measured_render_time_gpu` is the
##    driver's own timestamp, so it excludes xvfb's present path — which in this rig is most of the frame and is
##    why the first version of this probe reported *hiding* the sea as slower. Frame time is printed beside it for
##    scale only.
## 3. **Pixels are read as absolute values**, once per phase, in a grid across the middle of the frame: that is the
##    other half of "the sea costs something" — a second pass that changes nothing visible would be free to delete.
## 4. **Two phases of each state**, alternating, so the noise floor is measured rather than assumed.

const MAIN_SCENE := "res://game/main.tscn"
## Frames before the stability gate is consulted at all: the scene builds, the base map climbs its ladder and the
## near field settles. Then the gate waits for **quiet** rather than for a count.
const SETTLE_FRAMES := 60
## **Frames of provable stillness before a phase may start.** The first version of this probe waited a fixed 90
## frames, and phase 0 came out at 2.4 ms GPU and twice the brightness of every later phase — because a rung was
## still landing and the exposure had not finished settling. A fixed wait is a guess about the rig; this is a
## measurement of it. Three things must hold: no map bake, a constant primitive count, and a GPU time within a
## few per cent of itself.
const QUIET_FRAMES := 30
## Frames on each side of a pair, and how many pairs. `PAIRS × 2 × PAIR_FRAMES` frames are measured in total, each
## state getting exactly the same number of them, interleaved.
const PAIR_FRAMES := 20
const PAIRS := 6
const DEFAULT_FRAMES := 120
const DEFAULT_ALT := 2.0e5

var _frames := 0
var _phase := 0
var _current_frames: Array[float] = []
var _current_gpu: Array[float] = []
var _current_primitives: Array[int] = []
var _current_pixels: Array[float] = []
var _samples: Array[Dictionary] = []
var _sample_index := 0
var _ocean: MeshInstance3D
var _ocean_mesh: Mesh
var _ocean_land: Material
## The red override, re-asserted every frame: `_poll_patch_builds` writes `material_override` when a patch rebuild
## lands, so a probe that sets it once measures its own override being replaced.
var _red: StandardMaterial3D
var _red_land: MeshInstance3D
var _invisible: StandardMaterial3D
var _hide_land := false
var _land_mesh: MeshInstance3D
var _ocean_fraction := 0.0
var _exposure: Variant
## Chosen once, after the quiet gate, and held for the whole measurement: the frame's own mean set to middle grey.
var _pinned_multiplier := 0.0
var _red_pixels := 0
var _sampled_pixels := 0
var _frames_per_phase := DEFAULT_FRAMES
var _measured := false
var _finished := false
var _quiet := 0
var _quiet_reached := false
var _last_bakes := -1
var _last_primitives := -1
var _last_gpu := 0.0


func _initialize() -> void:
	var packed: Variant = load(MAIN_SCENE)
	if packed == null:
		print("SURFCOST: could not load the game scene")
		quit(1)
		return
	get_root().add_child(packed.instantiate())
	if OS.has_environment("COST_FRAMES"):
		_frames_per_phase = maxi(int(OS.get_environment("COST_FRAMES")), 10)


func _process(delta: float) -> bool:
	_frames += 1
	# **The placement waits for the ship to exist** — the scene is added at `_initialize` and the ship is built a
	# frame or two later, the same trap `tests/screenshot.gd` documents.
	if _frames == 2:
		_place()
	if _frames < SETTLE_FRAMES or _finished:
		_hold_exposure_identity()
		return _finished
	if _ocean == null:
		print("SURFCOST: no ocean layer on this body — nothing to measure")
		_finished = true
		return true
	# **Identity every frame**, because the game's own `_update_view` drives the meter each frame and the probe runs
	# after it. The pass being disabled is not enough: the multiplier also scales the light energy.
	if _red != null or _hide_land:
		_hold_red()
	if _pinned_multiplier <= 0.0:
		_hold_exposure_identity()
	if not _measured:
		_measured = true
		RenderingServer.viewport_set_measure_render_time(get_root().get_viewport_rid(), true)
	# **Nothing is measured until the rig is quiet**, and quiet is defined rather than assumed. Once it has been
	# reached the gate is not consulted again — it is a start condition, not a per-frame one.
	if not _quiet_reached:
		_quiet_reached = _is_quiet()
		if not _quiet_reached:
			return false
		_calibrate_exposure()
		return false
	_measure_frame(delta)
	return _finished


## **Is anything still moving?** No surface bake, the same primitive count as last frame, and a GPU time within
## `QUIET_TOLERANCE` of it. `QUIET_FRAMES` consecutive frames of that, or the probe keeps waiting.
func _is_quiet() -> bool:
	var main: Node = get_root().get_node_or_null("Main")
	var bakes := -1
	if main != null and main.get("_system") != null:
		bakes = main.get("_system").surface_maps().bakes()
	var primitives := int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(get_root().get_viewport_rid())
	var steady := true
	if bakes != _last_bakes:
		steady = false
	if primitives != _last_primitives:
		steady = false
	# **GPU time is deliberately NOT a start condition.** It jitters by a few per cent frame to frame in this rig,
	# and demanding quiet from it made the gate wait ~2,900 frames on the first attempt and then keep reporting
	# "quiet" for the rest of the phase. Constant bakes and a constant primitive count are the signals that
	# something is still arriving; jitter is what the medians are for.
	_last_bakes = bakes
	_last_primitives = primitives
	_last_gpu = gpu
	if not steady:
		_quiet = 0
		return false
	_quiet += 1
	if _quiet >= QUIET_FRAMES:
		print("SURFCOST: quiet after %d frames — %d bakes, %d primitives, %.3f ms GPU" % [
			_frames, bakes, primitives, gpu
		])
		return true
	return false


## **Keep the red on.** `_poll_patch_builds` rewrites `material_override` for any body whose patch rebuild lands, so
## an override set once is silently replaced — the same class of fault as a probe that toggles `visible` against a
## per-frame writer.
func _hold_red() -> void:
	if _red == null:
		return
	if _red_land != null:
		_red_land.material_override = _red
	elif _ocean != null and _ocean.mesh != null:
		_ocean.material_override = _red
	# **`COST_HIDE_LAND=1` makes the land invisible** so whatever is underneath it can be seen. A layer that draws
	# nothing looks exactly like a layer that is behind something else, and only one of those is a bug.
	if _hide_land and _land_mesh != null:
		_land_mesh.material_override = _invisible


## **Calibrate the exposure once, then hold it.** The pass is off either way; the multiplier is what turns a
## near-black frame into one whose pixels can be compared.
func _calibrate_exposure() -> void:
	if _exposure == null:
		return
	# Let the frame with identity exposure land, then scale its own mean to middle grey.
	var mean := _mean(_sample_pixels())
	var multiplier := 0.18 / maxf(mean, 1.0e-6)
	_pinned_multiplier = multiplier
	_exposure.identity()
	_exposure.attributes.exposure_multiplier = multiplier
	print("SURFCOST: exposure pinned at %.1f (the frame's own mean was %.4f, so mid-grey is 0.18)" % [
		multiplier, mean
	])


## **The exposure pass off, and the camera's exposure at identity** — the two halves of "absolute values".
func _hold_exposure_identity() -> void:
	var camera := _find_camera(get_root())
	if camera != null and camera.compositor != null:
		for effect in camera.compositor.compositor_effects:
			if effect is SpacesimExposurePass:
				(effect as CompositorEffect).enabled = false
	if _exposure == null:
		var main: Node = get_root().get_node_or_null("Main")
		if main != null:
			_exposure = main.get("_exposure")
	if _exposure != null:
		_exposure.identity()


## Put the eye low over the body, aimed straight down, so the disc **fills the frame** — the case where a second
## fragment pass over the whole body is most expensive, and the case the flight was in when it looked fine.
func _place() -> void:
	var body_name := "planet:earth"
	if OS.has_environment("COST_BODY"):
		body_name = OS.get_environment("COST_BODY")
	var altitude := DEFAULT_ALT
	if OS.has_environment("COST_ALT"):
		altitude = float(OS.get_environment("COST_ALT"))

	var main: Node = get_root().get_node_or_null("Main")
	if main == null:
		print("SURFCOST: no Main node")
		return
	var system: Variant = main.get("_system")
	var ship: Node3D = _find_ship(get_root())
	if system == null or ship == null:
		print("SURFCOST: no system or no ship")
		return
	var target: Node3D = null
	var radius := 6.371e6
	var star: Node3D = null
	for body in system.bodies:
		if String(body.id) == body_name:
			target = body.node
			radius = float(body.radius)
			_ocean = body.ocean
			_ocean_land = body.mesh_material
			_ocean_fraction = float(body.surface_ocean_fraction)
			if _ocean != null:
				_ocean_mesh = _ocean.mesh
		elif body.content != null and body.content.kind == 2: # SpacesimSystemBody.Kind.STAR
			star = body.node
	if target == null:
		print("SURFCOST: no body called ", body_name)
		return

	# **The sun behind the eye and the planet in front of it** (Evert, 2026-10-19): stand off on the star-facing
	# side and look at the *disc*, which is a full phase, fully lit, and the brightest view there is. The first
	# versions of this probe stood 200 km up looking straight down, which is dark enough that a frame reads as
	# near-black and no picture comparison can be made in it.
	#
	# `COST_STANDOFF` sets the distance in body radii; 3 puts a disc ~39 degrees across in the frame.
	var standoff := 3.0
	if OS.has_environment("COST_STANDOFF"):
		standoff = maxf(float(OS.get_environment("COST_STANDOFF")), 1.2)
	var to_star := Vector3.RIGHT
	if star != null:
		to_star = (star.global_position - target.global_position).normalized()
	ship.global_position = target.global_position + to_star * radius * standoff

	var camera: Camera3D = _find_camera(get_root())
	if camera == null:
		print("SURFCOST: no camera")
		return
	# **Aim the SHIP, not the camera.** The camera is a child of the ship (`player_ship.gd` adds it at a fixed
	# offset), so a global transform set on the camera is recomposed from the ship's on the next tick and the view
	# goes back to wherever the ship points. The first version of this probe did exactly that and photographed
	# empty space: the frame was near-black, and painting the land red changed nothing at all because the planet
	# was not in it.
	var forward := (target.global_position - ship.global_position).normalized()
	var up := to_star
	ship.look_at(target.global_position, up)
	for child in ship.get_children():
		if child is Camera3D:
			(child as Camera3D).global_transform = Transform3D(
				Basis.looking_at(forward, up), child.global_position
			)
	_hide_ship(ship)
	# **Say where the aim landed, and check it.** A rig that can point at nothing and still report numbers is a rig
	# that lies; the patch walk's lesson, one instrument over.
	var screen := camera.unproject_position(target.global_position)
	var viewport_size := Vector2(get_root().size)
	var in_frame := screen.x >= 0.0 and screen.y >= 0.0 \
		and screen.x <= viewport_size.x and screen.y <= viewport_size.y
	print("SURFCOST: aim — body centre lands at %s in a %s viewport: %s" % [
		str(screen), str(viewport_size), "IN FRAME" if in_frame else "**OFF SCREEN — the picture test is void**"
	])
	# **`COST_RED=1` paints the sea solid red and asks a different question: is the layer drawing at all?** A cost
	# of zero for a pass that contributes no pixels is a fact about the layer, not about the pass.
	# **`COST_RED=sea` or `COST_RED=land` paints that layer solid red** and asks a different question: which of the
	# two is drawing? Painting the LAND is the decisive one, because it needs no writes to the ocean's mesh and so
	# cannot fight the scene's own `_poll_patch_builds`: red everywhere means the sea is behind it or absent, and red
	# only on the continents means the sea is drawing where the land is not.
	if OS.has_environment("COST_HIDE_LAND"):
		_hide_land = true
		_invisible = StandardMaterial3D.new()
		_invisible.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_invisible.albedo_color = Color(0.0, 0.0, 0.0, 0.0)
		_invisible.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		for body in system.bodies:
			if String(body.id) == body_name:
				_land_mesh = body.mesh
		print("SURFCOST: the land is invisible — whatever shows is underneath it")
	if OS.has_environment("COST_RED"):
		_red = StandardMaterial3D.new()
		_red.albedo_color = Color(1.0, 0.0, 0.0)
		_red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var which := String(OS.get_environment("COST_RED"))
		if which == "land":
			for body in system.bodies:
				if String(body.id) == body_name:
					_red_land = body.mesh
			print("SURFCOST: the LAND is painted RED — red everywhere means the sea draws nothing")
		elif _ocean != null:
			print("SURFCOST: the sea is painted RED — no red means the sea draws nothing")
		_hold_red()
	# The parameters that decide whether the sea's fragments survive, printed once: the shader can be right and
	# still be handed a threshold that discards everything.
	if _ocean_land != null:
		var land := _ocean_land as ShaderMaterial
		var sea_mat: ShaderMaterial = null
		if _ocean.material_override is ShaderMaterial:
			sea_mat = _ocean.material_override
		elif _ocean.material_override == null:
			sea_mat = _ocean.get_surface_override_material(0) as ShaderMaterial
		print("SURFCOST: land  has_ocean=%s sea_level=%s map=%s" % [
			str(land.get_shader_parameter("has_ocean")) if land != null else "?",
			str(land.get_shader_parameter("sea_level")) if land != null else "?",
			"present" if land != null and land.get_shader_parameter("height_map") != null else "MISSING",
		])
		print("SURFCOST: land  width=%s tile_count=%s" % [
			str(land.get_shader_parameter("map_width")) if land != null else "?",
			str(land.get_shader_parameter("tile_count")) if land != null else "?",
		])
		print("SURFCOST: sea   sea_level=%s map=%s width=%s tile_count=%s" % [
			str(sea_mat.get_shader_parameter("sea_level")) if sea_mat != null else "NO MATERIAL",
			"present" if sea_mat != null and sea_mat.get_shader_parameter("height_map") != null else "MISSING",
			str(sea_mat.get_shader_parameter("map_width")) if sea_mat != null else "?",
			str(sea_mat.get_shader_parameter("tile_count")) if sea_mat != null else "?",
		])
		print("SURFCOST: sea node override=%s surface_override=%s" % [
			str(_ocean.material_override), str(_ocean.get_surface_override_material(0))
		])
	print("SURFCOST: ocean fraction %.3f, ocean node %s, mesh %s" % [
		float(main.get("_system").bodies[0].surface_ocean_fraction) if false else _ocean_fraction,
		str(_ocean != null), str(_ocean.mesh != null) if _ocean != null else "none"
	])
	print("SURFCOST: %.0f km over %s, sea layer %s, exposure pass OFF, exposure pinned to identity" % [
		altitude / 1000.0, body_name, "present" if _ocean != null else "absent"
	])


## **Paired alternation, not four long phases.** A software rasteriser's numbers drift monotonically — the first
## attempt at this measured 2.4, 1.4, 1.1, 0.9 ms across four phases of alternating state, which is a ramp, not a
## difference. Alternating every `PAIR_FRAMES` and comparing each drawn sample with the hidden one *next to it*
## cancels any slow drift, because both halves of a pair are equally far along the ramp.
func _measure_frame(delta: float) -> void:
	var part := _sample_index % 2 # 0 = sea drawn, 1 = sea hidden
	_ocean.mesh = _ocean_mesh if part == 0 else null
	_current_frames.append(delta)
	_current_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(get_root().get_viewport_rid()))
	_current_primitives.append(int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)))
	_current_pixels.append(_mean(_sample_pixels()))
	if _current_frames.size() < PAIR_FRAMES:
		return
	_samples.append({
		"part": part,
		"gpu": _median(_current_gpu),
		"frame": _median(_current_frames),
		"primitives": _median_int(_current_primitives),
		"pixel": _mean(_current_pixels),
	})
	_current_frames = []
	_current_gpu = []
	_current_primitives = []
	_current_pixels = []
	_sample_index += 1
	if _sample_index < PAIRS * 2:
		return
	_ocean.mesh = _ocean_mesh
	# **A probe that reports pixels must show the frame it read.** One PNG at the end, so the numbers can be
	# checked against the picture they claim to describe.
	var shot: Image = get_root().get_texture().get_image()
	if shot != null:
		shot.save_png("/tmp/surf_cost.png")
		print("SURFCOST: the frame it measured is at /tmp/surf_cost.png")
	var cam := _find_camera(get_root())
	if cam != null and cam.compositor != null:
		for effect in cam.compositor.compositor_effects:
			print("SURFCOST: compositor effect %s enabled=%s" % [effect.get_class(), str(effect.enabled)])
	var main2: Node = get_root().get_node_or_null("Main")
	if main2 != null and main2.get("_system") != null:
		var maps = main2.get("_system").surface_maps()
		print("SURFCOST: surface map bakes %d, entry width for Earth %d" % [
			maps.bakes(), maps.map("planet:earth").width if maps.map("planet:earth") != null else -1
		])
	_report_all()
	_finished = true


## **The absolute values of the pixels** — a grid across the middle of the frame, read back once a phase with
## nothing adapting underneath it. Luminance, so one number can be compared with another; and with the exposure
## pass off and the multiplier pinned, it is a property of the scene rather than of the rig.
func _sample_pixels() -> Array[float]:
	var values: Array[float] = []
	var image: Image = get_root().get_texture().get_image()
	if image == null:
		return values
	# **Strided across the whole frame, not a grid in the middle**: a view that happens to sit over one continent
	# makes a 4x4 grid read "the sea draws nothing", which is a statement about the view rather than about the sea.
	# 64 times fewer pixels than a full pass keeps a GDScript loop out of the measurement.
	var width := image.get_width()
	var height := image.get_height()
	var step := 8
	for row in range(0, height, step):
		for column in range(0, width, step):
			var pixel := image.get_pixel(column, row)
			values.append(pixel.get_luminance())
			if pixel.r > 0.30 and pixel.g < 0.15 and pixel.b < 0.15:
				_red_pixels += 1
			_sampled_pixels += 1
	return values


## Paired differences: for each pair, `drawn - hidden`, then the median of those. The median of paired differences
## is robust to both drift and the occasional outlier, which a mean of phases is not.
func _report_all() -> void:
	print("SURFCOST: %d pairs, %d frames a side, GPU time from the driver's own timestamps" % [
		PAIRS, PAIR_FRAMES
	])
	var deltas: Array[float] = []
	var frame_deltas: Array[float] = []
	var pixel_deltas: Array[float] = []
	for index in range(0, _samples.size(), 2):
		var drawn: Dictionary = _samples[index]
		var hidden: Dictionary = _samples[index + 1]
		var delta := float(drawn["gpu"]) - float(hidden["gpu"])
		deltas.append(delta)
		frame_deltas.append(float(drawn["frame"]) - float(hidden["frame"]))
		pixel_deltas.append(float(drawn["pixel"]) - float(hidden["pixel"]))
		print("SURFCOST:   pair %d   gpu %6.3f - %6.3f = %+6.3f ms   prims %d/%d   pixel %.4f/%.4f" % [
			index / 2, float(drawn["gpu"]), float(hidden["gpu"]), delta,
			int(drawn["primitives"]), int(hidden["primitives"]),
			float(drawn["pixel"]), float(hidden["pixel"])
		])
	var spread := 0.0
	for value in deltas:
		spread = maxf(spread, absf(value - _median(deltas)))
	print("SURFCOST: **the second pass**")
	print("SURFCOST:   GPU time     median paired delta **%+.3f ms** (spread %.3f ms), frame delta %+.2f ms" % [
		_median(deltas), spread, 1000.0 * _median(frame_deltas)
	])
	print("SURFCOST:   picture      median pixel delta %+.5f — the sea is %s the frame" % [
		_median(pixel_deltas),
		"part of" if absf(_median(pixel_deltas)) > 0.0005 else "invisible in"
	])
	print("SURFCOST:   primitives   one draw call and ~3,000 triangles more (see the pairs above)")
	if absf(_median(deltas)) <= spread:
		print("SURFCOST: **the effect is inside its own spread** — this rig cannot resolve it; the primitive count "
			+ "is the only fact here")
	print("SURFCOST: red pixels seen: %d of %d sampled (%.1f %%) — with `COST_RED` set, that is the painted layer's share of the frame" % [
		_red_pixels, _sampled_pixels,
		100.0 * float(_red_pixels) / maxf(float(_sampled_pixels), 1.0)
	])
	print("SURFCOST: exposure held at %.1f for the whole run — absolute pixels, nothing adapting" % [
		_pinned_multiplier
	])


func _median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _median_int(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


## The node that owns the camera — the ship, as `tests/screenshot.gd` finds it.
func _find_ship(root: Node) -> Node3D:
	var camera := _find_camera(root)
	if camera == null:
		return null
	var node: Node = camera
	while node != null:
		if node is Node3D and node.name.to_lower().contains("ship"):
			return node as Node3D
		node = node.get_parent()
	return null


func _find_camera(root: Node) -> Camera3D:
	for child in root.get_children():
		var found := _find_camera_in(child)
		if found != null:
			return found
	return null


func _find_camera_in(node: Node) -> Camera3D:
	if node is Camera3D:
		return node as Camera3D
	for child in node.get_children():
		var found := _find_camera_in(child)
		if found != null:
			return found
	return null


## Hide the hull, which sits metres from the camera and would otherwise be most of the frame.
func _hide_ship(ship: Node3D) -> void:
	var stack: Array[Node] = [ship]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			(node as MeshInstance3D).visible = false
		for child in node.get_children():
			stack.append(child)
