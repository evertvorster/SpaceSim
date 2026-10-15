extends SceneTree
## B1 of the lighting plan — does the whole range of lights fit, with identity exposure?
##
##     xvfb-run -a godot-double-mono --path . --script res://tests/probe_range.gd
##
## ## Why this runs before anything is built on it
##
## The plan's §6a replaces Godot's per-path exposure with one frame-wide filter: the scene is rendered
## in **absolute** units (no location term anywhere) and the EV is applied to the finished frame. That
## rests on three claims, and all three are cheap to falsify:
##
##   1. **Identity exposure is affordable.** A white Lambertian reads 8.54 at Mercury and 0.0014 at
##      Neptune in Godot's currency, against a half-float buffer whose maximum is 65,504.
##   2. **Identity exposure is well defined.** "No camera attributes" and "`CameraAttributesPhysical`
##      with `exposure_multiplier = 1.0`" may not be the same number — the engine's factor folds in the
##      aperture and shutter, and only `exposure_multiplier` is readable from GDScript.
##   3. **The buffer's floor is where the night floor has to go.** `RGBA16F`'s smallest subnormal is
##      5.96e-8, i.e. ~0.006 lux in this currency, and the catalogue-summed starlight is 2e-4 lux —
##      thirty times below it. If that is right, "the star field as the ambient" is bounded by the
##      *buffer*, not by the exposure, and a floor has to be chosen deliberately.
##
## ## How claim 3 is tested rather than argued
##
## Set the ambient to a **precisely known value**, set the tonemap exposure to the EV window's ceiling
## (`2^32`), and read the pixel. An ambient of `x` becomes `x * 2^32` after the filter:
##
##   * if `x` survives the buffer, `x >= ~6e-8` reads **white** (`x * 2^32 >= 1`);
##   * if it flushed to zero at the buffer write, it reads **exactly zero**, whatever the exposure.
##
## That is a measurement of the floor's position, not a citation of the specification — and the sweep
## straddles it, so the answer is a boundary rather than a claim.
##
## ## And the half that answers the night-floor question itself
##
## **Planetshine on Luna's night side**, computed from the project's own content: Earth's bond albedo
## from `sol.tres` (which already includes its clouds), the illuminance Sol gives Earth, and Earth's
## solid angle from Luna. If that lands above the buffer's floor by a wide margin while starlight lands
## below it, then requirement 3 does the practical night-side work and requirement 1 is about deep
## space — which changes what the floor is even for.
##
## **What this probe cannot do:** read the buffer directly. An 8-bit sRGB read-back clips at 1.0, so
## the bright end is brought back into the readable window with `tonemap_exposure`, which is a
## *frame-wide multiply after the buffer* — if a value had clipped in the buffer, no exposure would
## recover it, so the two cases are distinguishable. See the anchors.

const CONTENT_PATH := "res://systems/sol.tres"
## Godot's own convention for `light_intensity_lux`: 100,000 lux renders a white surface as 1.0. Every
## figure in the project's currency is a lux divided by this.
const REFERENCE_LUX := 100000.0
## IEEE 754 binary16 — the 3D colour buffer's format (`renderer_scene_render_rd.cpp:1161`).
const HALF_MAX := 65504.0
const HALF_MIN_NORMAL := 6.103515625e-05
const HALF_MIN_SUBNORMAL := 5.960464477539063e-08
## The EV window's ceiling, from `SpacesimExposure.MAX_MULTIPLIER = MIN_MULTIPLIER * 2^32`.
const EV_CEILING := 4294967296.0

const VIEW_SIZE := 64
const SETTLE_FRAMES := 3

var _quad: MeshInstance3D
var _surface: StandardMaterial3D
var _light: DirectionalLight3D
var _camera: Camera3D
var _world_environment: WorldEnvironment
var _environment: Environment

var _cases: Array[Array] = []
var _index := 0
var _pending := -1
var _settle := 0
var _rows: Array[Array] = []
var _encoding := "unknown"


# --- part A: the arithmetic, from the project's own content ---------------------------------------

func _initialize() -> void:
	get_root().size = Vector2i(VIEW_SIZE, VIEW_SIZE)
	_arithmetic()
	_build()
	_plan()


func _body(system: SpacesimSolarSystem, id_fragment: String) -> SpacesimSystemBody:
	for body in system.bodies:
		if String(body.id).ends_with(id_fragment):
			return body
	return null


func _illuminance(luminosity: float, body: SpacesimSystemBody) -> float:
	if body == null or body.orbit == null:
		return 0.0
	return SpacesimStarLight.illuminance(luminosity, body.orbit.semi_major_axis)


func _arithmetic() -> void:
	var loaded: Variant = load(CONTENT_PATH)
	if loaded == null or not (loaded is SpacesimSolarSystem):
		print("RANGE: no content at '%s'" % CONTENT_PATH)
		return
	var system: SpacesimSolarSystem = loaded

	var star := _body(system, ":sol")
	if star == null:
		print("RANGE: no star in the content")
		return
	var luminosity := SpacesimStarModel.luminosity(star)
	var table := SpacesimMaterialTable.engine_table()

	print("RANGE — part A, arithmetic from the project's own content")
	print("RANGE: Sol's luminosity        %s W" % String.num_scientific(luminosity))
	print("RANGE: Godot's currency        %s lux renders a white surface as 1.0" % _fmt(REFERENCE_LUX))
	print("RANGE: the buffer's limits     max %s, min normal %s, min subnormal %s"
		% [_fmt(HALF_MAX), String.num_scientific(HALF_MIN_NORMAL),
			String.num_scientific(HALF_MIN_SUBNORMAL)])
	print("RANGE: in this currency those are  max %s, floor %s lux"
		% [_fmt(HALF_MAX), String.num_scientific(HALF_MIN_SUBNORMAL * REFERENCE_LUX)])
	print("RANGE:")
	print("RANGE: %-12s %18s %14s %12s %8s" % ["body", "distance (m)", "illuminance", "buffer", "sRGB px"])
	for name in [":mercury", ":earth", ":neptune"]:
		var body := _body(system, name)
		var lux := _illuminance(luminosity, body)
		var buffer := lux / REFERENCE_LUX
		print("RANGE: %-12s %18s %14s %12s %8.1f" % [
			name.trim_prefix(":"), _fmt(body.orbit.semi_major_axis), _fmt(lux), _fmt(buffer),
			_srgb(buffer) * 255.0,
		])

	# --- the star field, which is the ambient the project actually computes ------------------------
	var sky := SpacesimStarSky.new()
	var starfield := 0.0
	if sky.create():
		starfield = sky.illuminance(6.5) ## the registry's default `sky.star_depth`
		print("RANGE:")
		print("RANGE: star field (depth 6.5)  %s lux -> buffer %s -> sRGB px %.4f"
			% [String.num_scientific(starfield), String.num_scientific(starfield / REFERENCE_LUX),
				_srgb(starfield / REFERENCE_LUX) * 255.0])
		print("RANGE:   against the buffer floor %s: %s"
			% [String.num_scientific(HALF_MIN_SUBNORMAL),
				"ABOVE it (survives)" if starfield / REFERENCE_LUX >= HALF_MIN_SUBNORMAL
				else "BELOW it — flushes to zero"])

	# --- planetshine on Luna's night side ---------------------------------------------------------
	var earth := _body(system, ":earth")
	var luna := _body(system, ":luna")
	if earth == null or luna == null or luna.orbit == null:
		print("RANGE:")
		print("RANGE: no Luna in the content; planetshine not computed")
		return
	var earth_albedo := SpacesimSurfaceModel.bond_albedo(earth, table)
	var earth_lux := _illuminance(luminosity, earth)
	# **Full Earth**, i.e. the best case, which is exactly when Luna's near side is in lunar night:
	# a phase angle of zero.
	var earth_luminance := SpacesimLuminance.disc_luminance(earth_lux, earth_albedo, 0.0)
	# Earth's solid angle from Luna. The exact spherical cap at a distance, not the small-angle
	# approximation, because the point is to trust this number.
	var d := luna.orbit.semi_major_axis
	var sin_theta := earth.radius / d
	var earth_omega := 2.0 * PI * (1.0 - sqrt(maxf(0.0, 1.0 - sin_theta * sin_theta)))
	# Irradiance on a surface facing it: `L * omega` for a disc of uniform radiance, cos = 1.
	var earthshine := earth_luminance * earth_omega

	print("RANGE:")
	print("RANGE: — planetshine on Luna's night side (full Earth, the best case) —")
	print("RANGE: Earth's bond albedo      %f (from sol.tres, includes the cloud deck)" % earth_albedo)
	print("RANGE: Earth's illuminance      %s lux" % _fmt(earth_lux))
	print("RANGE: Earth's luminance        %s lux/sr" % _fmt(earth_luminance))
	print("RANGE: Earth as seen from Luna  %s rad across, %s sr"
		% [_fmt(asin(clampf(sin_theta, -1.0, 1.0))), _fmt(earth_omega)])
	print("RANGE: earthshine on the surface %s lux  -> buffer %s"
		% [_fmt(earthshine), String.num_scientific(earthshine / REFERENCE_LUX)])
	print("RANGE: starlight for comparison  %s lux  -> buffer %s"
		% [String.num_scientific(starfield), String.num_scientific(starfield / REFERENCE_LUX)])
	print("RANGE: earthshine / starlight    %sx" % _fmt(earthshine / maxf(starfield, 1e-30)))
	print("RANGE: earthshine vs the floor   %sx above it"
		% _fmt((earthshine / REFERENCE_LUX) / HALF_MIN_SUBNORMAL))


# --- part B: the render ---------------------------------------------------------------------------

func _build() -> void:
	var root := Node3D.new()
	get_root().add_child(root)

	var mesh := QuadMesh.new()
	mesh.size = Vector2(4.0, 4.0)
	_quad = MeshInstance3D.new()
	_quad.mesh = mesh
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(_quad)

	# White, fully rough, no specular: a Lambertian, so what it reflects is `albedo * E / pi` and the
	# project's own convention can be checked against it directly.
	_surface = StandardMaterial3D.new()
	_surface.albedo_color = Color.WHITE
	_surface.roughness = 1.0
	_surface.metallic = 0.0
	_surface.specular = 0.0
	_quad.material_override = _surface

	# A stock `DirectionalLight3D` at its default basis shines along -Z, onto the quad's +Z face.
	_light = DirectionalLight3D.new()
	_light.shadow_enabled = false
	root.add_child(_light)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 1.0
	_camera.position = Vector3(0.0, 0.0, 2.0)
	_camera.current = true
	root.add_child(_camera)

	_environment = Environment.new()
	_environment.background_mode = Environment.BG_COLOR
	_environment.background_color = Color.BLACK
	_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_environment.tonemap_white = 1.0
	_environment.glow_enabled = false
	_world_environment = WorldEnvironment.new()
	_world_environment.environment = _environment
	root.add_child(_world_environment)


## One entry per row: [label, light lux, ambient energy, tonemap exposure, attributes mode, kind].
## `attributes` is "none", "physical" (defaults) or "identity" (`exposure_multiplier = 1.0`).
func _plan() -> void:
	# --- THE LUX SWEEP: what does X lux actually render as? ----------------------------------------
	# **Not anchors of 100,000 and 50,000 lux.** Both of those clip at 1.0 and therefore measure
	# nothing — the first version of this probe had exactly that bug, and two clipped anchors cannot
	# pin a constant. Well below white, the convention is *measured* over a range instead of assumed.
	for lux in [1000.0, 5000.0, 10000.0, 25000.0, 50000.0]:
		_cases.append(["lux sweep: %s lux, attributes=identity" % _fmt(lux), lux, 0.0, 1.0, "identity", "lux"])
	# ... and the same level with NO attributes at all, and with defaults, which are the other two
	# things "identity exposure" could mean. **At 10,000 lux the no-attributes case clips**, so this is
	# at 1,000 lux where all three are readable and the ratio between them is a number.
	for mode in ["none", "physical", "identity"]:
		_cases.append(["identity? 1,000 lux, attributes=%s" % mode, 1000.0, 0.0, 1.0, mode, "lux"])

	# --- the three light levels, each at an exposure that lands it in the readable window ----------
	# `tonemap_exposure` is a frame-wide multiply AFTER the buffer, so a value that had clipped in the
	# buffer could not be recovered by any exposure — the scaling is what makes the bright end testable.
	for name in ["mercury", "earth", "neptune"]:
		_cases.append(["%s, exposure x%s" % [name, _fmt(_level_exposure(name))], -1.0, 0.0,
			_level_exposure(name), "identity", "level:" + name])

	# --- THE FLOOR SWEEP: the claim the night-floor decision rests on ------------------------------
	# A known ambient, the EV window's ceiling, and a read-back. White means the value survived the
	# buffer and the exposure lifted it; exactly zero means it flushed at the buffer write. The sweep
	# straddles the floor, so the answer is a boundary rather than a citation.
	for energy in [0.0, 1.0e-9, 1.0e-8, 3.0e-8, 6.0e-8, 1.0e-7, 1.0e-6]:
		_cases.append(["floor sweep: ambient %s, exposure 2^32" % String.num_scientific(energy),
			-REFERENCE_LUX, energy, EV_CEILING, "identity", "floor"])


## The exposure that puts each level near mid-grey, so every one of the three is readable in an 8-bit
## read-back. Mercury needs the most stopping down: it is 6.7x Earth and about 6,000x Neptune.
func _level_exposure(name: String) -> float:
	match name:
		"mercury":
			return 1.0 / 256.0
		"earth":
			return 1.0 / 64.0
	return 1.0 ## Neptune is dark enough to read at unity


func _apply(case: Array) -> void:
	var light_lux: float = case[1]
	var ambient: float = case[2]
	var exposure: float = case[3]
	var mode: String = case[4]
	var kind: String = case[5]

	match mode:
		"none":
			_camera.attributes = null
		"physical":
			_camera.attributes = CameraAttributesPhysical.new()
		"identity":
			var attributes := CameraAttributesPhysical.new()
			attributes.auto_exposure_enabled = false
			attributes.exposure_multiplier = 1.0
			_camera.attributes = attributes

	# A negative light lux means "the case supplies its own"; those levels come from part A, so the
	# amplifier is read from it rather than repeated here.
	if light_lux == -1.0:
		light_lux = _level_lux(kind)
	_light.light_intensity_lux = maxf(light_lux, 0.0)
	# A negative light lux also switches the light off for the floor sweep, where the light must not
	# contribute at all.
	_light.visible = light_lux > 0.0

	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_environment.ambient_light_color = Color.WHITE
	_environment.ambient_light_energy = ambient
	_environment.tonemap_exposure = exposure
	_world_environment.environment = _environment


## The illuminance part A computed for a body, so the render and the arithmetic cannot drift.
func _level_lux(kind: String) -> float:
	var loaded: Variant = load(CONTENT_PATH)
	if loaded == null or not (loaded is SpacesimSolarSystem):
		return 0.0
	var system: SpacesimSolarSystem = loaded
	var star := _body(system, ":sol")
	var body := _body(system, ":" + kind.trim_prefix("level:"))
	return _illuminance(SpacesimStarModel.luminosity(star), body)


func _process(_delta: float) -> bool:
	if _pending >= 0:
		_settle += 1
		if _settle >= SETTLE_FRAMES:
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


func _record(index: int) -> void:
	var image := get_root().get_texture().get_image()
	var size := image.get_size()
	var pixel := image.get_pixel(size.x / 2, size.y / 2)
	if _cases[index][5] == "lux" and absf(float(_cases[index][1]) - 10000.0) < 0.01 \
			and _cases[index][4] == "identity":
		# The encoding is decided by a *linear* value we know the engine wrote: `tonemap_exposure`
		# 1.0 and a measured lux must round-trip through the same curve the report inverts.
		_encoding = "sRGB-encoded" if pixel.r > 0.05 else "unexpected (%.4f -> %.4f)" % [pixel.r, pixel.r]
	_rows.append([_cases[index], pixel.r, _linear(pixel.r)])


# --- output ---------------------------------------------------------------------------------------

func _fmt(value: float) -> String:
	if value == 0.0:
		return "0"
	# **`%g` and `%e` are not GDScript format codes** — they are runtime errors, and the string comes
	# out literal. This file used `%.4g` in its first version and printed half its own output as
	# format specifiers. `String.num` and `String.num_scientific` are the two that exist.
	var magnitude := absf(value)
	if magnitude >= 1.0e-3 and magnitude < 1.0e7:
		var text := String.num(value, 4)
		if text.contains("."):
			text = text.rstrip("0").rstrip(".")
		return text
	return String.num_scientific(value)


## sRGB encode, so an expected buffer value can be stated as a pixel.
func _srgb(value: float) -> float:
	if value <= 0.0:
		return 0.0
	if value <= 0.0031308:
		return value * 12.92
	return 1.055 * pow(value, 1.0 / 2.4) - 0.055


## The piecewise inverse — **not `pow(v, 2.4)`**, which manufactures a tone curve that is not there.
func _linear(value: float) -> float:
	if value > 0.04045:
		return pow((value + 0.055) / 1.055, 2.4)
	return value / 12.92


func _report() -> void:
	print("RANGE:")
	print("RANGE — part B, rendered. Read-back is 8-bit sRGB (%s), tonemap LINEAR, no glow." % _encoding)
	print("RANGE: %-52s %10s %12s %14s" % ["case", "pixel", "linear", "implied lux/unit"])
	for row in _rows:
		var case: Array = row[0]
		# The constant the whole arithmetic depends on, *measured*: how many lux of light on a white
		# Lambertian make one buffer unit. Only printed where the light is the only thing lit.
		var implied := ""
		if case[5] == "lux" and float(case[1]) > 0.0 and row[2] > 0.0:
			implied = _fmt(float(case[1]) / row[2])
		elif case[5].begins_with("level:"):
			implied = _fmt(_level_lux(String(case[5])) / (row[2] / float(case[3])))
		print("RANGE: %-52s %10.5f %12s %14s" % [case[0], row[1], _fmt(row[2]), implied])
	print("RANGE:")
	print("RANGE: how to read the floor sweep — white means the ambient value SURVIVED the buffer")
	print("RANGE: and the EV ceiling lifted it; exactly zero means it flushed at the buffer write.")
	print("RANGE: The boundary between the two is the floor the night side has to sit above.")
	print("RANGE: ")
	print("RANGE: the lux/unit column is the project's currency measured rather than assumed: if it is")
	print("RANGE: flat across the sweep, `REFERENCE_LUX` is the right number and the arithmetic in part A")
	print("RANGE: can be trusted at every distance.")
