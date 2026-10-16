class_name SpacesimBodyRenderer
extends RefCounted
## Builds what a body looks like: its surface material, and its air when it has one.
##
## Everything the shaders are given comes from **the derivation** — the albedo colour, the scattering
## coefficient and scale height — so a shader cannot quietly disagree with the model. What is *not*
## derived yet is named in the constants below rather than buried in the shader, because a hidden
## constant is one nobody can find when the picture is wrong.
##
## **The cloud deck is drawn again, and the altitude is what changed.** The shell that was removed in
## `ffbc802` stood at `radius * 1.012` — a *fraction of the body*, which is 76 km up at Earth against a
## real cloud top of 10-12, and that is what made it the outermost silhouette of every world. The
## deck now sits at the **condensation level**, a real height derived from the air's own `T(h)` profile
## (see `SpacesimAtmosphereModel.condensation_levels`), so it tracks the air rather than the planet's
## size. `SpacesimClouds` keeps carrying `fraction` and `albedo` for `bond_albedo` — Earth's calibrated
## 0.302 against a measured 0.306 still depends on them.

const SURFACE_SHADER := preload("res://addons/spacesim/render/body_surface.gdshader")
const STAR_SHADER := preload("res://addons/spacesim/render/body_star.gdshader")
const ATMOSPHERE_SHADER := preload("res://addons/spacesim/render/body_atmosphere.gdshader")
const DECK_SHADER := preload("res://addons/spacesim/render/body_deck.gdshader")

## How far past the environment's `glow_hdr_threshold` (1.0) a star sits. This is the bloom knob: a
## star at 1.0 is a bright dot, and a star is supposed to glare. **Also what a star's point of light is
## emitted at**, so the two cannot disagree.
const STAR_INTENSITY := 24.0

## **Not derived, and deliberately visible here.** Roughness and specularity are per-material
## properties the material table does not carry yet, and relief strength is a look decision. Terrain
## shape from composition is the next thing the derivation can honestly supply.
const SURFACE_ROUGHNESS := 0.9
const SURFACE_SPECULAR := 0.15
## Multiplies a *true* gradient over the unit sphere, so it is small: at noise_scale 6 the gradient is
## around 6, and 0.05 of that tips the normal by roughly 17 degrees where the field is steepest.
const RELIEF := 0.05

## How far into the two-stop colour gradient the blend sits, and how soft the edge is.
const DETAIL_MIX := 0.5
const DETAIL_SOFTNESS := 0.18

## **How much of the noise texture the sphere is mapped over, and it is not the surface's 1.0.**
##
## At 1.0 the sphere uses a *quarter* of the texture — 16 of its 64 texels across a whole planet — which
## gives a handful of blobs. A deck wants structure, so it maps the *whole* texture over the sphere and
## gets roughly four times the features. `seamless` is what makes the wrap invisible, which is the flag's
## own purpose; the surface keeps 1.0 because its *relief* is a gradient of this same field, and a wrapped
## gradient would show the repeat as terrain.
const CLOUD_NOISE_SCALE := 4.0

## How wide the cloud deck's edge is, in field units. A cloud boundary has width, and the same number
## drives the deck's colour and its alpha, so a soft edge is also a thin one.
const CLOUD_SOFTNESS := 0.06
## How many directions the coverage threshold is measured over, and how coarsely the field's range is
## found. Both are local to building a deck, and the count is what the percentile's accuracy costs.
const CLOUD_PERCENTILE_SAMPLES := 2048
## The coverage measurement's own density, and a spin that separates its sample from the threshold's.
const CLOUD_COVERAGE_SAMPLES := 997
const CLOUD_SPAN_STRIDE := 2

## Features **inside the noise texture**, not wraps of it. The sphere is mapped into a quarter of the
## texture, so detail comes from how much noise the texture holds — raising the sampling scale instead
## walks out of the texture and repeats the whole pattern as a visible grid.
const SURFACE_NOISE_SCALE := 1.0

## lux/sr into the engine's units, which is what turns a radiance into something a shader can be handed.
##
## **It is the same number as `sky_stars.gdshader`'s `UNIT_LUX_PER_SR`** — 100000 / pi — and that is not
## a coincidence to be maintained by discipline: the point of light a body becomes and the star field
## behind it are the same kind of quantity, and two currencies for one quantity is how they come to
## disagree. `tests/test_render.gd` checks the shader still carries this value, so a change in either
## place fails rather than drifting.
const UNIT_LUX_PER_SR := 100000.0 / PI

## Triangles in the quad a point of light is drawn on. Counted in the HUD's total, because the HUD is
## an instrument for "is anything actually being applied" and an instrument that ignores part of what is
## drawn can only ever under-report.
const POINT_TRIANGLES := 2

static var _noise: NoiseTexture3D
static var _point_quad: QuadMesh


## One 3D noise field, shared by every body and every layer. Each body gets its own **offset**, so
## sharing the field costs nothing visually and only one texture is ever built.
##
## The frequency is what supplies the detail: the sphere samples only a quarter of the texture, so a
## gentle noise reads as two smooth blobs and a busy one reads as terrain. 0.01 was far too gentle.
static func noise_field() -> NoiseTexture3D:
	if _noise == null:
		var generator := FastNoiseLite.new()
		generator.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		generator.frequency = 0.09
		generator.fractal_octaves = 5
		var texture := NoiseTexture3D.new()
		texture.noise = generator
		texture.seamless = true
		texture.normalize = true
		_noise = texture
	return _noise


## The air's own numbers, on a material that has to deal with it.
##
## **Both shaders get the air from here.** The shell integrates it as scattering; the surface attenuates
## its light by it. One place handing out the same numbers is what keeps the sky and the ground under it
## from disagreeing about how thick the air is — and a second copy is exactly how they would.
##
## Nothing is set when the body has no air, so the material keeps the degenerate defaults and the column
## comes back empty.
static func set_air_parameters(
	material: ShaderMaterial,
	body: SpacesimSceneBody,
	materials: SpacesimMaterialTable,
	shell_top: float,
	temperature: float,
	illuminance: float
) -> void:
	if material == null or body.content == null or body.content.atmosphere == null or shell_top <= 0.0:
		return
	var air := body.content.atmosphere
	material.set_shader_parameter("planet_radius", body.radius)
	material.set_shader_parameter("atmosphere_radius", body.radius + shell_top)
	material.set_shader_parameter(
		"rayleigh_coefficient", SpacesimAtmosphereModel.rayleigh_coefficient(air, materials, temperature)
	)
	material.set_shader_parameter(
		"rayleigh_scale_height",
		SpacesimAtmosphereModel.scale_height(
			air, materials, temperature, SpacesimAtmosphereModel.surface_gravity(body.content)
		)
	)
	material.set_shader_parameter("mie_coefficient", SpacesimAtmosphereModel.MIE_COEFFICIENT)
	material.set_shader_parameter("mie_scale_height", SpacesimAtmosphereModel.MIE_SCALE_HEIGHT)
	# **Absorption joins the extinction and never the emission** — the shaders are handed it separately so
	# the split cannot be lost. Zero until the material table carries visible cross-sections, which is a
	# named gap rather than a value: see `SpacesimSpecies.absorption`.
	material.set_shader_parameter(
		"absorption_coefficient", SpacesimAtmosphereModel.absorption_coefficient(air, materials, temperature)
	)
	# **The sky's own light on the ground.** Every number is the model's, so the shader holds none of the
	# derivation — and the shell's material ignores these, which is what keeps one call serving both.
	material.set_shader_parameter("sky_illuminance", Vector3.ONE * illuminance)
	material.set_shader_parameter("sky_diffuse_max", SpacesimAtmosphereModel.SKY_DIFFUSE_MAX)
	material.set_shader_parameter("sky_down_fraction", SpacesimAtmosphereModel.SKY_DOWN_FRACTION)
	material.set_shader_parameter("sky_min_cos_zenith", SpacesimAtmosphereModel.SKY_MIN_COS_ZENITH)
	material.set_shader_parameter("sky_shadow_softness", SpacesimAtmosphereModel.SKY_SHADOW_SOFTNESS)
	material.set_shader_parameter("reference_lux", SpacesimAtmosphereModel.REFERENCE_LUX)


## The air's material, or null when the body has none.
##
## `shell_top` is how far above the surface the shell reaches — **derived** from the air's own scale
## height and floored by the framing's altitude (`SpacesimSceneBody.sky_top`), not an authored
## altitude. It used to be called `atmosphere_altitude`, which named the floor it is not.
##
## **Every number here comes from `SpacesimAtmosphereModel`**, so the shader cannot disagree with the
## model: the coefficient and the scale height are the derivation's, and the Mie terms are named
## constants there rather than buried in the shader. `temperature` is the reference state the
## coefficient is evaluated at and `illuminance` scales the whole sky — see the model for both.
static func atmosphere_material(
	body: SpacesimSceneBody,
	materials: SpacesimMaterialTable,
	shell_top: float,
	temperature: float,
	illuminance: float
) -> ShaderMaterial:
	var air := body.content.atmosphere if body.content != null else null
	if air == null or shell_top <= 0.0:
		return null
	var material := ShaderMaterial.new()
	material.shader = ATMOSPHERE_SHADER
	set_air_parameters(material, body, materials, shell_top, temperature, illuminance)
	material.set_shader_parameter("mie_anisotropy", SpacesimAtmosphereModel.MIE_ANISOTROPY)
	# Relative to the star's light, so the sky keeps its proportion to the surface it is seen against.
	material.set_shader_parameter(
		"sun_intensity", SpacesimAtmosphereModel.sky_scale(illuminance)
	)
	return material


## The quad every point of light is drawn on: **one resource, shared, scaled by the node** — the same
## arrangement the icosphere uses, and for the same reason.
static func point_quad() -> QuadMesh:
	if _point_quad == null:
		_point_quad = QuadMesh.new()
		_point_quad.size = Vector2.ONE
	return _point_quad


## The material a **point of light** is drawn with: unshaded and additive.
##
## A body too small to be a disc is not geometry, it is its own light — so it is a quad whose colour is the
## body's mean radiance and whose size is the disc it would have had. `albedo_color` can exceed 1: Godot
## passes an overbright albedo straight through, which is what lets a splat be brighter than white and
## still be tone-mapped with everything else. Nothing here is exposure-corrected *by Godot* — the splat
## reports radiance and the environment decides what is seen — which is why `_place_point` applies the
## exposure itself; see there for why that has to be done by hand.
##
## **It is in the 3D pass and not in the overlay, deliberately.** A `CanvasLayer` is composited *after*
## the tonemap, so a splat drawn there would ignore the exposure entirely and could not be a body's
## radiance at all — which is why the navigation overlay, for all that it already projects screen
## positions, is the wrong home for this.
##
## **The quad is NOT billboarded by the material, and that is the point.** Godot's `BILLBOARD_ENABLED`
## works by rewriting `MODELVIEW_MATRIX` in the vertex shader —
## `MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2],
## MODEL_MATRIX[3])` — which multiplies **world-space axes** against a **camera-relative translation**.
## That is exactly the transform chain the double-precision emulation exists to manage, and the project
## has already been bitten twice by things that sidestep it: *"No triplanar or `world_vertex_coords`:
## neither gets the double-precision vertex transform emulation, and both jitter at planet scale."* The
## symptom would be a quad that lands somewhere other than where the body is, **depending on where the
## camera is** — so it would blink as you fly rather than being wrong always, and a bright splat's glow
## would go with it, because the glow is made of that quad's pixels. Evert, 2026-10-15: *"There are very
## bright blown-out flashes..."* was a different fault, but this one is *"single points of light... about
## 10% of the time they would just wink out of existence"*, and it does not happen with the camera still.
##
## So the orientation is set from GDScript in `_place_point`, by copying the camera's basis onto the node —
## which is what a billboard is, done where the emulation can see it, and which also needs no
## `billboard_keep_scale` because the scale is the node's own.
##
## **Depth is tested and not written.** Tested, so a splat behind a planet is hidden — per pixel, by the
## depth buffer, which does that job better than a ray test against body centres could. Not written,
## because one additive splat must not occlude another.
static func point_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.disable_receive_shadows = true
	material.albedo_color = Color(0.0, 0.0, 0.0, 1.0)
	return material


## The material a body is drawn with.
##
## **A star is a source and everything else is a reflector**, so the choice is by kind rather than by
## anything a shader could work out for itself.
static func material_for(body: SpacesimSceneBody) -> Material:
	if body.content != null and body.content.kind == SpacesimSystemBody.Kind.STAR:
		return star_material(body)
	return surface_material(body)


## The colour a **point of light** is drawn with: the body's own radiance, tinted by the body's own
## colour.
##
## **A star is a source and everything else is a reflector** — the same by-kind distinction
## `material_for` makes, and it has to be made here too, because the two are different quantities. A
## planet's point is the light it reflects, `SpacesimSystemScene.body_luminance`, which is a scalar; a
## star's is what its own surface emits, `star_color * STAR_INTENSITY`, which is what `body_star.gdshader`
## puts in `ALBEDO`. Running the reflector formula on a star gives **zero** — a star has no albedo — which
## is how a Sun with a sub-pixel disc would vanish from its own sky.
##
## **`radiance` is a scalar and the tint is normalised to unit luminance**, so tinting cannot change how
## bright a splat is: the same quantity the exposure weighs stays the quantity that lands on the screen.
##
## **The planet's value is sRGB-ENCODED on the way out, and that is not belt-and-braces.** Godot's default
## spatial material declares `uniform vec4 albedo : source_color` (`scene/resources/material.cpp`), so
## `albedo_color` is **decoded from sRGB** as it is written — which for a *linear* radiance is `level^2.2`,
## dimmer by `level^1.2` and non-linear, silently. The star field does not have this problem: it writes
## `COLOR` in a **sky** shader, which is linear and untouched, so a splat without this encode is in a
## different currency from the sky it is seen against. `linear_to_srgb()` is the exact inverse of what
## Godot decodes, so what arrives in the shader is the radiance — see the round trip in
## `tests/test_lod.gd`. **The clean alternative is a `ShaderMaterial` with a plain uniform, which asks
## Godot to convert nothing; this is the one-liner that gets the same number without reimplementing the
## billboard.**
##
## **The star's branch is deliberately NOT encoded**, because it goes into the same `source_color` property
## the star's own disc does — the two must be converted *alike* for the handoff to stay free, whatever
## that conversion is. That path converts twice (the disc's shader also declares `star_color`
## `source_color`, and `SpacesimStarModel.color` already linearises), which is a real defect belonging to
## the star's own colour and the lighting plan. It does not show here: both the disc and the splat clip at
## 24x whatever the conversion does, which is also the only reason their handoff looks free.
static func point_colour(body: SpacesimSceneBody, radiance: float) -> Color:
	if body.content != null and body.content.kind == SpacesimSystemBody.Kind.STAR:
		return star_color_of(body) * STAR_INTENSITY
	return _at_unit_luminance(body.color, radiance / UNIT_LUX_PER_SR).linear_to_srgb()


## A colour scaled so that its luminance is `level`, whatever its hue.
static func _at_unit_luminance(colour: Color, level: float) -> Color:
	var grey := colour.get_luminance()
	if grey <= 0.0:
		return Color(level, level, level, 1.0)
	return Color(level * colour.r / grey, level * colour.g / grey, level * colour.b / grey, 1.0)


## A star's own colour, from its temperature — **derived once**, because the surface shader and a point
## of light both need it and two derivations would be two colours.
static func star_color_of(body: SpacesimSceneBody) -> Color:
	if body.content == null:
		return Color.WHITE
	var luminosity := SpacesimStarModel.luminosity(body.content)
	return SpacesimStarModel.color(
		SpacesimStarModel.effective_temperature(luminosity, body.content.radius)
	)


## A star's own surface: unshaded, and coloured from its temperature.
##
## **Unshaded because it is a source.** Drawn with the ordinary surface material it was lit by *its own*
## light — which travels from the star toward the observer, so its near face was back-lit and came out
## black, which is exactly what it looked like. Emissive well past the glow threshold, because a star is
## supposed to glare.
static func star_material(body: SpacesimSceneBody) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = STAR_SHADER
	material.set_shader_parameter("star_color", star_color_of(body))
	material.set_shader_parameter("intensity", STAR_INTENSITY)
	return material


## The cloud deck's own material: one shell of noise, drawn where the noise says there is cloud.
##
## **`fraction` is turned into a threshold by measuring the field, not by assuming its distribution.**
## A threshold admits the fraction of the field *above* it, which is the authored fraction only if the
## distribution is known — and the first deck assumed it, which is why the vault carries "the achieved
## coverage was never measured, only assumed" as a trap. `cloud_threshold` measures it.
##
## **The deck's drawn reflectance is its palette colour, not `clouds.albedo`** — the same split the
## surface has, and named for the same reason: `bond_albedo` uses the albedo for the temperature, the
## exposure's body term and the point of light, while the picture is a colour. Making the drawn
## reflectance the measurement is a step of its own (see the cloud plan), not something to half-do here.
static func deck_material(body: SpacesimSceneBody) -> ShaderMaterial:
	var clouds := body.content.clouds
	var material := ShaderMaterial.new()
	material.shader = DECK_SHADER
	var colour: Color = clouds.color
	material.set_shader_parameter("cloud_color", colour)
	# The edge, darkened rather than hand-picked, so a deck keeps its identity while gaining structure.
	material.set_shader_parameter("edge_color", colour.darkened(0.3))
	material.set_shader_parameter(
		"threshold", cloud_threshold(offset_for(body.id), clouds.fraction, CLOUD_NOISE_SCALE)
	)
	material.set_shader_parameter("softness", CLOUD_SOFTNESS)
	material.set_shader_parameter("opacity", clouds.opacity)
	# **The surface's own field, scale and offset.** The deck's shadow is sampled from this same noise, so
	# the two have to agree about where a cloud is — and the scale is 1.0 because the sphere is mapped into
	# a quarter of the texture; raising it walks out of the texture and repeats it as a grid.
	material.set_shader_parameter("noise_scale", CLOUD_NOISE_SCALE)
	material.set_shader_parameter("noise_offset", offset_for(body.id))
	material.set_shader_parameter("noise_field", noise_field())
	return material


## **The coverage threshold, as a PERCENTILE of the field rather than `1 - cover`.**
##
## **What is measured is the noise GENERATOR, on the grid Godot builds the texture from.**
## `NoiseTexture3D` has **no `get_image()`** in 4.7.2 — the method does not exist, and a probe paid for
## that — while `Noise::_get_image` evaluates the noise at **integer texel coordinates** and normalises
## by the min/max over that grid. Those are the two things reproduced here. Two approximations are
## named rather than hidden: the project's texture is `seamless`, whose skirt blends the outer 16 texels,
## and it is quantised to 8 bits. Neither moves the percentile of a smooth field by more than a
## fraction of a percent, and `cloud_coverage` is the instrument that measures whether that is true.
static func cloud_threshold(
	offset: Vector3, fraction: float, scale := SURFACE_NOISE_SCALE
) -> float:
	if fraction <= 0.0:
		return 1.0
	if fraction >= 1.0:
		return 0.0
	var samples := _sphere_samples(offset, CLOUD_PERCENTILE_SAMPLES, 0.0, scale)
	if samples.is_empty():
		return 0.0
	samples.sort()
	# The percentile that leaves `fraction` of the field above it.
	var index := clampi(int((1.0 - fraction) * float(samples.size())), 0, samples.size() - 1)
	return samples[index]


## **How much of the sphere is above a threshold** — the measurement the vault names as missing
## (*"the achieved coverage was never measured, only assumed"*), and the instrument that checks
## `cloud_threshold`.
##
## It samples at a **different density and with a different spin** than the threshold does, so the two
## agreeing is a measurement rather than a restatement of the same list — and a threshold built as
## `1 - cover`, or from the wrong distribution, fails it.
static func cloud_coverage(
	offset: Vector3, threshold: float, scale := SURFACE_NOISE_SCALE
) -> float:
	var samples := _sphere_samples(offset, CLOUD_COVERAGE_SAMPLES, 0.5, scale)
	if samples.is_empty():
		return 0.0
	var above := 0
	for value in samples:
		if value >= threshold:
			above += 1
	return float(above) / float(samples.size())


## The field, normalised the way the texture normalises it, over directions on the sphere.
##
## `spin` shifts the spiral's phase, which is how a caller gets an independent sample of the same
## distribution. Directions are Fibonacci-spread so the sample is the sphere's own rather than a
## pole-heavy one, and each is mapped through **the shader's own mapping** — `direction * 0.25 + 0.5`
## plus the body's offset — so what is measured is the field the deck actually samples.
static func _sphere_samples(
	offset: Vector3, count: int, spin: float, scale: float
) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	var texture := noise_field()
	var generator := texture.noise as FastNoiseLite
	if generator == null:
		return samples
	var size := texture.get_width()
	var span := _grid_span(generator, size)
	if span.y <= span.x:
		return samples
	for i in count:
		var t := (float(i) + spin) / float(count)
		var y := 1.0 - 2.0 * t
		var ring := sqrt(maxf(1.0 - y * y, 0.0))
		var turn := PI * (1.0 + sqrt(5.0)) * (float(i) + spin)
		var mapped := Vector3(cos(turn) * ring, y, sin(turn) * ring) \
			* (0.25 * scale) + Vector3(0.5, 0.5, 0.5) + offset
		var texel := Vector3i(
			int(floorf(mapped.x * float(size))) % size,
			int(floorf(mapped.y * float(size))) % size,
			int(floorf(mapped.z * float(size))) % size
		)
		var raw := generator.get_noise_3d(float(texel.x), float(texel.y), float(texel.z))
		samples.append((raw - span.x) / (span.y - span.x))
	return samples


## The range the texture normalises with: the generator on its own **integer texel grid**, which is what
## `Noise::_get_image` walks. Sampled on a stride, since the extremes of a smooth field are found by
## sampling it rather than by testing all 262,144 texels.
static func _grid_span(generator: FastNoiseLite, size: int) -> Vector2:
	var lowest := INF
	var highest := -INF
	for z in range(0, size, CLOUD_SPAN_STRIDE):
		for y in range(0, size, CLOUD_SPAN_STRIDE):
			for x in range(0, size, CLOUD_SPAN_STRIDE):
				var value := generator.get_noise_3d(float(x), float(y), float(z))
				lowest = minf(lowest, value)
				highest = maxf(highest, value)
	return Vector2(lowest, highest)


## The surface material: the body's derived colour, split into a two-stop height gradient.
##
## The two stops are the colour darkened and lightened rather than two hand-picked colours, so a world
## keeps its identity while gaining structure. That is the honest version of Planet 3D's
## `heightGradient`: real stops per material are what the coverage fractions will fill in later.
static func surface_material(body: SpacesimSceneBody) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SURFACE_SHADER
	material.set_shader_parameter("base_color", body.color.darkened(0.35))
	material.set_shader_parameter("detail_color", body.color.lightened(0.25))
	material.set_shader_parameter("detail_mix", DETAIL_MIX)
	material.set_shader_parameter("detail_softness", DETAIL_SOFTNESS)
	material.set_shader_parameter("noise_scale", SURFACE_NOISE_SCALE)
	material.set_shader_parameter("relief", RELIEF)
	material.set_shader_parameter("roughness_value", SURFACE_ROUGHNESS)
	material.set_shader_parameter("specular_value", SURFACE_SPECULAR)
	material.set_shader_parameter("noise_offset", offset_for(body.id))
	material.set_shader_parameter("noise_field", noise_field())
	return material


## A stable offset into the noise field, derived from the body's id — so the same body always wears the
## same surface, and two bodies never wear the same one.
##
## **Small.** The sphere is mapped into a quarter of the texture, so an offset of more than about 0.2
## walks the sample out of it and back into the tiling the mapping exists to avoid. The first version
## returned values up to 10, which did exactly that.
static func offset_for(id: String) -> Vector3:
	var seed := int(hash(id))
	return Vector3(
		float(seed & 0xff) / 255.0, float((seed >> 8) & 0xff) / 255.0, float((seed >> 16) & 0xff) / 255.0
	) * 0.15
