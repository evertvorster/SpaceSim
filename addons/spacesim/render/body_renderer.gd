class_name SpacesimBodyRenderer
extends RefCounted
## Builds what a body looks like: its surface material, and its air when it has one.
##
## Everything the shaders are given comes from **the derivation** — the albedo colour, the scattering
## coefficient and scale height — so a shader cannot quietly disagree with the model. What is *not*
## derived yet is named in the constants below rather than buried in the shader, because a hidden
## constant is one nobody can find when the picture is wrong.
##
## **Nothing draws a cloud deck.** The shell that did was removed in `ffbc802`: it stood at
## `radius * 1.012` — 76 km up at Earth, seven times a real cloud top — which made it the outermost
## silhouette of every body, and it is what read as "an atmosphere" from space while the actual air
## was invisible. `SpacesimClouds` stays and is still read: `bond_albedo` needs it, and Earth's
## calibrated 0.302 against a measured 0.306 depends on the deck's fraction and albedo.

const SURFACE_SHADER := preload("res://addons/spacesim/render/body_surface.gdshader")
const STAR_SHADER := preload("res://addons/spacesim/render/body_star.gdshader")
const ATMOSPHERE_SHADER := preload("res://addons/spacesim/render/body_atmosphere.gdshader")
const DECK_SHADER := preload("res://addons/spacesim/render/body_deck.gdshader")

## The width of a cloud's edge, in field units. **Not the coverage** — the coverage is the threshold,
## which is the map's own percentile — so this only decides whether a boundary is a stipple or a smear.
const DECK_SOFTNESS := 0.05

## **The deck before the air.** Both shells are centred on the body, so distance sorting cannot separate
## them; the deck has to occlude first and the air add over it. The atmosphere's own material is what
## this is relative to, and it is left at the default.
const DECK_RENDER_PRIORITY := -1

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
static var _white: ImageTexture


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


## The **cloud deck's** material: a baked coverage map, thresholded into cloud, lit through the air
## above it.
##
## **The deck is drawn in its palette colour, and NOT scaled to its albedo — measured, 2026-10-16.**
##
## The two numbers are different quantities and both are right. `bond_albedo` is the fraction of
## incident *energy* reflected **integrated over every direction and phase**, which is what the
## temperature depends on. What you see from a spacecraft is the *directional* reflectance at one
## geometry, and for a thick water cloud at low phase that is **0.8-0.9 — near white**. Drawing the
## average instead is what made the clouds grey, and the arithmetic is worth recording:
##
##     illuminance at 1 au = 3.828e26 / (4 pi d^2) * 94 lm/W = 127,900 lux
##     a Lambertian of albedo A renders at A * 127,900 / 100,000 = A * 1.279
##     measured at the cloud tops, straight down from 1,000 km: 0.4872
##     implied reflectance 0.4872 / 1.279 = 0.381, and / 0.87 of air = 0.44  ->  the albedo, as drawn
##
## `7020cba` fixed the opposite fault — the deck was drawn at its palette colour while `bond_albedo`
## said 0.45, and the note called it *"twice as reflective"*. That was right about the **disc average**
## and wrong about the **peak**, and the two facts hold at once: `SpacesimClouds.color` is the "how it
## looks" field and `SpacesimClouds.albedo` is the "what it reflects" field, and scaling one to the
## other is what conflated them.
##
## **What this does not have yet is the phase dependence.** A real cloud is near-white at low phase and
## much darker toward crescent, and *that* is why its Bond average is 0.45 while its peak is 0.85. A
## Lambertian cannot be both, so the drawn deck is now right where you look at it and the disc average
## is the thing to check next — against Earth's measured 0.302 — rather than a number to defend here.
##
## `cover` may be **null**, and that is a real case rather than a failure: a body the model calls
## `FEATURELESS` has no map because there is no noise to bake, and its honest picture is a uniform shroud
## at full coverage. `uniform_white()` is what it gets.
static func deck_material(
	body: SpacesimSceneBody, cover: Texture2D, threshold: float, ramp_mean: float = 1.0
) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = DECK_SHADER
	material.set_shader_parameter("cover", cover if cover != null else uniform_white())
	material.set_shader_parameter("threshold", threshold)
	material.set_shader_parameter("softness", DECK_SOFTNESS)
	var clouds: SpacesimClouds = body.content.clouds if body.content != null else null
	if clouds != null:
		# sRGB-decoded, because Godot's spatial shaders take a linear albedo. It carries the *hue*.
		var linear := clouds.color.srgb_to_linear()
		material.set_shader_parameter("cloud_color", Vector3(linear.r, linear.g, linear.b))
	else:
		material.set_shader_parameter("cloud_color", Vector3.ONE)
	# **The deck is drawn before the air that is in front of it.** Both shells are centred on the body, so
	# a distance sort cannot separate them and the order is ours to state: the deck occludes, then the air
	# adds over it. Without this the air's own glow would be covered by a cloud it should be lighting.
	material.render_priority = DECK_RENDER_PRIORITY
	return material


## **The ramp's gain** — the number that makes the deck's *average* drawn reflectance the albedo the
## light budget uses, whatever the field's distribution turns out to be.
##
## `blend_mix` composites `ALBEDO * ALPHA`, and the shader's alpha rises with thickness, so what reaches
## the eye from a texel is `cloud_color * gain * thickness`. The average over the covered area is
## therefore `palette_luminance * gain * mean(thickness)`, and setting
## `gain = albedo / (palette_luminance * mean)` makes that the albedo **exactly**, for any mean.
##
## That exactness is the point: the field's *shape* cannot break the light budget, it can only change how
## the whiteness is distributed. Thick tops get as near white as the average permits, thin edges fade
## out, and the mean is the calibrated number either way.
##
## **The clamp is a real ceiling and not paranoia.** A low-contrast field has a small mean thickness,
## which asks for a gain above 1 — a cloud reflecting more than white. It cannot, so the gain stops and
## the achieved average falls short of the budget. That shortfall is the honest signal that the field
## wants more contrast, and `tests/test_cloud_deck.gd` measures it rather than hiding it.
static func deck_ramp_gain(body: SpacesimSceneBody, ramp_mean: float) -> float:
	var clouds: SpacesimClouds = body.content.clouds if body.content != null else null
	if clouds == null:
		return 1.0
	var palette := maxf(clouds.color.srgb_to_linear().get_luminance(), 1.0e-4)
	var mean := clampf(ramp_mean, 1.0e-4, 1.0)
	return clampf((clouds.albedo / palette) / mean, 0.0, 1.0)


## **One white texel, shared.** A featureless body's field is uniform, so its map is uniform — and a
## 1x1 texture with `threshold = 0` draws exactly that without a branch in the shader or a special case
## in the scene.
static func uniform_white() -> ImageTexture:
	if _white == null:
		var image := Image.create_empty(1, 1, false, Image.FORMAT_L8)
		image.fill(Color.WHITE)
		_white = ImageTexture.create_from_image(image)
	return _white


## The surface material: the body's derived colour, **with its mapping disabled**.
##
## **The two-stop gradient and the relief are off deliberately, 2026-10-16.** Evert: *"we can comment out
## the surface mapping we put on the planet, and just use the bare sphere."* The mapped surface is being
## rebuilt, so what is drawn for now is a plain Lambertian sphere in its derived colour — which is also the
## cleaner thing to measure an albedo against, and it removes the two candidates that could turn a lit
## sphere black: a bump normal built from the field's gradient, and a colour blended between two stops.
##
## **Everything else the material carries is unchanged.** The air block still dims the ground and still
## lights it from the sky, so the ground is still a surface under air and not a sticker on the sphere.
## `tests/test_render.gd` still checks the wiring of every one of those, which is why this is a change of
## two parameters rather than a different material.
static func surface_material(body: SpacesimSceneBody) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SURFACE_SHADER
	# **Both stops the same colour, and no relief.** A flat Lambertian at the derived albedo; turning the
	# mapping back on is these three lines.
	material.set_shader_parameter("base_color", body.color)
	material.set_shader_parameter("detail_color", body.color)
	material.set_shader_parameter("detail_mix", DETAIL_MIX)
	material.set_shader_parameter("detail_softness", DETAIL_SOFTNESS)
	material.set_shader_parameter("noise_scale", SURFACE_NOISE_SCALE)
	material.set_shader_parameter("relief", 0.0)
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
