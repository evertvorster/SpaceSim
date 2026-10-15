extends SceneTree
## Measure the ambient's scale — phase 0 of [[SpaceSim/Lighting Plan]].
##
##     xvfb-run -a godot-double-mono --path . --script res://tests/probe_ambient.gd
##
## ## The question
##
## Godot's `ambient_light_energy` scale is **an inference, not a measurement**: the vault guessed
## "1.0 ~ 100,000 lux", the property's own hint range is **0 to 16**, and physical starlight wants
## ~2e-9 in those units. Three documents flag it as the one number in the lighting chain with nothing
## behind it. Nothing in the project can be calibrated against the ambient until it is a number.
##
## ## And the suspicion this probe exists to settle
##
## `Environment.ambient_light_color` and `ambient_light_energy` are, per the class reference,
## **"only effective if `ambient_light_sky_contribution` is lower than 1.0 (exclusive)"** — and that
## property **defaults to 1.0**. `SpacesimExposure.configure()` sets source, colour and energy and
## **never sets `ambient_light_sky_contribution`**, so the evidence says the colour-ambient path is
## inert and the scene is lit by the sky's radiance cubemap instead. That matters because
## `exposure.gd`'s own comment records the cubemap route was **tried and rejected** — *"the ambient
## light is far too bright"*, a sky of point sources being exactly what a cubemap cannot represent.
##
## ## What it measures
##
## One white Lambertian quad covering the whole view, no lights, and an `Environment` set explicitly.
## Nothing else is in the scene, so **every pixel is the same number** and the pixel is the surface's
## outgoing radiance.
##
##   * **The anchors come first, and they bypass `source_color`.** A `StandardMaterial3D.albedo_color`
##     is a `source_color` property: the value is sRGB-*decoded* on the way in and re-encoded on the
##     way out, so a 0.5 albedo reads back as 0.5 under *either* encoding — **the round trip hides the
##     one thing the anchor exists to reveal.** (Measured, and it cost this probe a revision.) The
##     anchors are therefore a `ShaderMaterial` writing a known linear `ALBEDO`, which cannot
##     round-trip.
##   * **The colour ambient** across small energies, no sky, with the contribution at 0.0 and at the
##     default 1.0.
##   * **The sky ambient**, from a sky of **known constant radiance** — so the expected value is
##     knowable in advance rather than merely observed. For a uniform sky of radiance `L` the whole
##     hemisphere is `L`, and a white Lambertian reflects `L` back out, so the quad should read `L`.
##   * **The two mixed**, which is the project's configuration.
##   * **The project's own two energies** — daylight and starlight, as `set_ambient_illuminance()`
##     computes them — under LINEAR and under the project's AgX curve.
##
## ## Reading the result
##
## Every claim below is made against the **raw pixel** or against an **anchor**; the "linear" column is
## a conversion, and which conversion is decided by the anchors rather than assumed. **This probe
## proves a mapping, not whether it looks right** — a render is for Evert's eyes.

const VIEW_SIZE := 64
## Radiance of the sky this probe builds. Uniform, so the expected value is arithmetic:
## a white Lambertian under uniform radiance L returns L.
const SKY_RADIANCE := 0.01
## The sky's radiance cubemap is built after the sky is first used, so a sky case must settle. Two
## frames is not enough, and reading too early reports a sky that contributed nothing — which is a
## false finding, not a measurement.
const SKY_SETTLE_FRAMES := 40
## A non-sky case needs one frame to draw and one to read.
const SETTLE_FRAMES := 2

## The energies to sweep. The ends of the property hint (0 to 16), the "1.0 ~ 100,000 lux" inference,
## and the two numbers the game actually computes: daylight 128,000 lux and starlight ~2e-4 lux, both
## over `REFERENCE_LUX`.
const ENERGIES := [0.0, 0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 4.0, 16.0]

var _quad: MeshInstance3D
var _lit: StandardMaterial3D
var _anchor: ShaderMaterial
var _camera: Camera3D
var _world_environment: WorldEnvironment
var _sky: Sky

var _cases: Array[Array] = []
var _index := 0
var _pending := -1
var _settle := 0
var _needed := SETTLE_FRAMES
var _rows: Array[Array] = []
var _encoding := "undetermined"
var _uniform := true


func _initialize() -> void:
	get_root().size = Vector2i(VIEW_SIZE, VIEW_SIZE)
	_build()
	_plan()


func _process(_delta: float) -> bool:
	if _pending >= 0:
		_settle += 1
		# The frames have to be *drawn* before they mean anything: reading in the iteration a case was
		# applied reports the frame before it, i.e. a configuration this probe never rendered.
		if _settle >= _needed:
			_record(_pending)
			_pending = -1
			_settle = 0
		return false
	if _index >= _cases.size():
		_report()
		return true
	_apply(_cases[_index])
	_pending = _index
	_index += 1
	return false


# --- the scene ------------------------------------------------------------------------------------

func _build() -> void:
	var root := Node3D.new()
	get_root().add_child(root)

	# **A quad larger than the view**, so every pixel read is surface and none is background. Its +Z
	# faces the camera, so the normal is exactly at the view axis.
	var mesh := QuadMesh.new()
	mesh.size = Vector2(4.0, 4.0)
	_quad = MeshInstance3D.new()
	_quad.mesh = mesh
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(_quad)

	# The surface under test: white, fully rough, no specular, so what arrives is diffuse and the
	# outgoing radiance is `albedo * L` for a uniform environment. `albedo_color = Color.WHITE` is
	# exactly representable under `source_color`, so the decode is a no-op here — see the anchors.
	_lit = StandardMaterial3D.new()
	_lit.albedo_color = Color.WHITE
	_lit.roughness = 1.0
	_lit.metallic = 0.0
	_lit.specular = 0.0

	# **The anchors, through a shader rather than a property.** `ALBEDO` in a shader is a linear value
	# with no `source_color` decoding, so what leaves is what the tonemapper and the read-back encoding
	# do to it — and nothing else.
	var shader := Shader.new()
	shader.code = "shader_type spatial;\nrender_mode unshaded;\nuniform float level = 0.5;\nvoid fragment() {\n\tALBEDO = vec3(level);\n}\n"
	_anchor = ShaderMaterial.new()
	_anchor.shader = shader

	# **Orthographic**, so the quad's coverage does not depend on the window size the display autoload
	# may set, and no camera attributes, so the exposure multiplier is 1.0.
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 1.0
	_camera.position = Vector3(0.0, 0.0, 2.0)
	_camera.current = true
	root.add_child(_camera)

	# A sky of a single known radiance. `sky_material` rather than a `ProceduralSkyMaterial`, because a
	# procedural sky's value is not knowable in advance and this probe's whole point is a number that is.
	var sky_shader := Shader.new()
	sky_shader.code = "shader_type sky;\nvoid sky() {\n\tCOLOR = vec3(%f);\n}\n" % SKY_RADIANCE
	var sky_material := ShaderMaterial.new()
	sky_material.shader = sky_shader
	_sky = Sky.new()
	_sky.sky_material = sky_material

	_world_environment = WorldEnvironment.new()
	root.add_child(_world_environment)


## One entry per row: [label, sky ("none"/"constant"/"project"), contribution, energy, tonemap,
## white, anchor level (-1 for the lit surface), exposure multiplier].
func _plan() -> void:
	# --- anchors: what does the read-back encoding do to a known LINEAR value? --------------------
	# 0.5 linear reads 0.5 if the buffer is linear and ~0.735 if it is sRGB-encoded. 0.25 is a second
	# point, so the answer is a pair rather than a single coincidence.
	for level in [0.5, 0.25]:
		_cases.append(["ANCHOR linear %.2f, unshaded shader" % level, "none", 0.0, 0.0,
			Environment.TONE_MAPPER_LINEAR, 1.0, level, 1.0])
	# Does the LINEAR tonemapper divide by `tonemap_white`? The project sets it to 6.0, and AgX is known
	# to ignore `tonemap_white` — so this asks the same of LINEAR.
	_cases.append(["ANCHOR linear 0.5, tonemap_white 6.0", "none", 0.0, 0.0,
		Environment.TONE_MAPPER_LINEAR, 6.0, 0.5, 1.0])

	# --- the colour ambient, no sky at all --------------------------------------------------------
	for energy in ENERGIES:
		_cases.append(["colour ambient, no sky, contrib 0.0, energy %s" % _fmt(energy),
			"none", 0.0, energy, Environment.TONE_MAPPER_LINEAR, 1.0, -1.0, 1.0])
	# ... the same with the DEFAULT contribution. **Measured to be identical to 0.0**, and the source
	# says why: `use_ambient_cubemap` needs `AMBIENT_SOURCE_BG + BG_SKY` or `AMBIENT_SOURCE_SKY`
	# (`render_scene_data_rd.cpp:192`), so under the project's `AMBIENT_SOURCE_COLOR` the mix at
	# `scene_forward_clustered.glsl:1756` never runs and the contribution cannot matter.
	for energy in [0.05, 0.1]:
		_cases.append(["colour ambient, no sky, contrib 1.0, energy %s" % _fmt(energy),
			"none", 1.0, energy, Environment.TONE_MAPPER_LINEAR, 1.0, -1.0, 1.0])

	# --- IS THE AMBIENT DARK-ADAPTED? -------------------------------------------------------------
	# The shader sets `ambient_light = ambient_light_color_energy.rgb` with no exposure factor, while
	# the *sky* cubemap branch is multiplied by `IBL_exposure_normalization`. If that holds, the camera's
	# exposure cannot lift the ambient, and an ambient authored in lux needs a different currency. This
	# is the case that decides whether the game's 2e-9 is a bug or merely dark.
	for multiplier in [1.0, 1000.0, 800000.0]:
		_cases.append(["colour ambient, energy 0.01, exposure x%s" % _fmt(multiplier),
			"none", 0.0, 0.01, Environment.TONE_MAPPER_LINEAR, 1.0, -1.0, multiplier])

	# --- the sky routes, and why they are NOT a controlled measurement here ------------------------
	# Kept as an observation rather than deleted, because the observation is the finding: a sky of a
	# KNOWN constant radiance does not put a knowable number on the surface. The value goes through
	# `IBL_exposure_normalization = current_exposure / MAX(0.001, sky_baked_exposure)`
	# (`render_scene_data_rd.cpp:247`) and through the reflection cubemap, neither of which is exposed to
	# GDScript — so "radiance L in, L out" is not a prediction this rig can check. Every sky row below
	# saturated. **What it would need instead: the game's own screenshot rig on a real night side.**
	for contribution in [0.0, 1.0]:
		_cases.append(["SKY(obs) constant radiance, contrib %.1f, energy 0" % contribution,
			"constant", contribution, 0.0, Environment.TONE_MAPPER_LINEAR, 1.0, -1.0, 1.0])
	for contribution in [0.0, 0.5, 1.0]:
		_cases.append(["SKY(obs) constant radiance, contrib %.1f, energy 0.5" % contribution,
			"constant", contribution, 0.5, Environment.TONE_MAPPER_LINEAR, 1.0, -1.0, 1.0])
	for energy in [0.0, 0.5, 16.0]:
		_cases.append(["SKY(obs) constant radiance, contrib 1.0 (DEFAULT), energy %s" % _fmt(energy),
			"constant", 1.0, energy, Environment.TONE_MAPPER_LINEAR, 1.0, -1.0, 1.0])

	# --- the project's own environment and its own two energies ------------------------------------
	# NO SKY in these rows. The game's sky is the star-field cubemap; its contribution is the
	# unmeasured half, per the note above.
	for energy in [1.28, 2.0e-9]:
		for tonemap in [Environment.TONE_MAPPER_LINEAR, Environment.TONE_MAPPER_AGX]:
			_cases.append(["PROJECT settings, NO SKY, contrib 1.0, energy %s" % _fmt(energy),
				"project", 1.0, energy, tonemap, 6.0, -1.0, 1.0])


## A format GDScript actually has: there is no `%e` and no `%g`, both runtime errors.
func _fmt(value: float) -> String:
	if value == 0.0 or (absf(value) >= 0.01 and absf(value) < 1000.0):
		return "%.2f" % value
	return "%s" % String.num_scientific(value)


func _apply(case: Array) -> void:
	var sky_kind: String = case[1]
	var contribution: float = case[2]
	var energy: float = case[3]
	var tonemap: int = case[4]
	var white: float = case[5]
	var anchor_level: float = case[6]
	var exposure: float = case[7]

	_needed = SETTLE_FRAMES if sky_kind == "none" else SKY_SETTLE_FRAMES

	# The exposure, which is the question in the dark-adaptation rows: `CameraAttributesPhysical` is
	# what the project uses, with `auto_exposure_enabled = false` and the multiplier computed.
	if exposure == 1.0:
		_camera.attributes = null
	else:
		var attributes := CameraAttributesPhysical.new()
		attributes.auto_exposure_enabled = false
		attributes.exposure_multiplier = exposure
		_camera.attributes = attributes

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	if sky_kind == "constant":
		env.background_mode = Environment.BG_SKY
		env.sky = _sky
	if sky_kind == "project":
		# Exactly the game's environment, then the two things this case is about.
		SpacesimExposure.configure(env)
		SpacesimExposure.set_ambient_illuminance(env, energy * SpacesimExposure.REFERENCE_LUX)
	env.tonemap_mode = tonemap
	env.tonemap_white = white
	env.tonemap_agx_white = white
	if anchor_level < 0.0:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color.WHITE
		env.ambient_light_energy = energy
		# **The property under suspicion.** Never set by the project, so this is where it is pinned.
		env.ambient_light_sky_contribution = contribution
	else:
		# The anchors are unshaded and do not read the ambient at all, so it is switched off to keep
		# the scene honest about what it is measuring.
		env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED

	_world_environment.environment = env
	if anchor_level >= 0.0:
		_anchor.set_shader_parameter("level", anchor_level)
		_quad.material_override = _anchor
	else:
		_quad.material_override = _lit


# --- reading --------------------------------------------------------------------------------------

func _record(index: int) -> void:
	var image := get_root().get_texture().get_image()
	var size := image.get_size()
	var centre := image.get_pixel(size.x / 2, size.y / 2)
	# A second sample: the surface is uniform, so any difference is the probe lying about its own rig.
	var corner := image.get_pixel(size.x / 4, size.y / 4)
	if not is_equal_approx(centre.r, corner.r):
		_uniform = false
	_rows.append([_cases[index], centre, corner])


func _report() -> void:
	_classify()
	print("AMBIENT PROBE — phase 0 of the lighting plan")
	print("AMBIENT PROBE: renderer          %s" % RenderingServer.get_video_adapter_name())
	print("AMBIENT PROBE: physical units    %s" % ProjectSettings.get_setting(
		"rendering/lights_and_shadows/use_physical_light_units", false))
	print("AMBIENT PROBE: use_hdr_2d        %s" % get_root().use_hdr_2d)
	print("AMBIENT PROBE: no light in any case; no camera attributes, so exposure is 1.0")
	print("AMBIENT PROBE: quad 4x4, orthographic size 1.0 — every pixel is the surface")
	print("AMBIENT PROBE: uniform across the buffer: %s" % _uniform)
	print("AMBIENT PROBE: sky cases settled %d frames (radiance cubemap), others %d"
		% [SKY_SETTLE_FRAMES, SETTLE_FRAMES])
	print("AMBIENT PROBE: sky radiance %.4f — the sky rows do NOT check this; see their label" % SKY_RADIANCE)
	print("AMBIENT PROBE: encoding          %s" % _encoding)
	print("AMBIENT PROBE: read-back is 8-bit, so the smallest readable non-zero is byte 1: linear %s"
		% String.num_scientific(_linear(1.0 / 255.0)))
	print("AMBIENT PROBE: below that, an ambient is indistinguishable from none — see the starlight row")
	print("AMBIENT PROBE:")
	print("AMBIENT PROBE: %-50s %6s %8s %9s %9s %10s" % ["case", "sky", "contrib", "energy", "pixel r", "linear r"])
	for row in _rows:
		var case: Array = row[0]
		print("AMBIENT PROBE: %-50s %6s %8.2f %9s %9.5f %10.6f" % [
			case[0], case[1], case[2], _fmt(case[3]), row[1].r, _linear(row[1].r),
		])
	print("AMBIENT PROBE:")
	print("AMBIENT PROBE: the linear column is a CONVERSION, valid only if the encoding above was")
	print("AMBIENT PROBE: decided by the anchors. Compare it against the arithmetic, never against the eye.")


## Decide the encoding from the anchor pair — the whole reason the anchors are shaders.
func _linear(value: float) -> float:
	match _encoding:
		"linear":
			return value
		"sRGB-encoded":
			# The piecewise inverse, honouring the linear segment near black.
			#
			# **NOT `pow(v, 2.4)`.** That was this file's first version, and it manufactured a compressive
		# tone curve out of nothing: every ambient row came out 0.4x to 0.96x of its energy and the
		# ratio climbed with the value. The measurement was fine; the conversion was the lie. Check a
		# conversion against a known pair before reading anything through it.
			if value > 0.04045:
				return pow((value + 0.055) / 1.055, 2.4)
			return value / 12.92
	return value


func _classify() -> void:
	for row in _rows:
		var case: Array = row[0]
		if not String(case[0]).begins_with("ANCHOR linear 0.50"):
			continue
		var pixel: float = row[1].r
		if absf(pixel - 0.5) < 0.02 and _encoding == "undetermined":
			_encoding = "linear"
		elif absf(pixel - 0.5) > 0.2 and absf(pixel - 0.735) < 0.03:
			_encoding = "sRGB-encoded"
