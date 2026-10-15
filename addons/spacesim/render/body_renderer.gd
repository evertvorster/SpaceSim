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
	material.set_shader_parameter("mie_anisotropy", SpacesimAtmosphereModel.MIE_ANISOTROPY)
	# Relative to the star's light, so the sky keeps its proportion to the surface it is seen against.
	material.set_shader_parameter(
		"sun_intensity",
		SpacesimAtmosphereModel.SKY_INTENSITY * illuminance / SpacesimAtmosphereModel.REFERENCE_LUX
	)
	return material


## The quad every point of light is drawn on: **one resource, shared, scaled by the node** — the same
## arrangement the icosphere uses, and for the same reason.
static func point_quad() -> QuadMesh:
	if _point_quad == null:
		_point_quad = QuadMesh.new()
		_point_quad.size = Vector2.ONE
	return _point_quad


## The material a **point of light** is drawn with: unshaded, additive, and always facing the eye.
##
## A body too small to be a disc is not geometry, it is its own light — so it is a camera-facing quad
## whose colour is the body's mean radiance and whose size is the disc it would have had. `albedo_color`
## can exceed 1: Godot passes an overbright albedo straight through, which is what lets a splat be
## brighter than white and still be tone-mapped with everything else. Nothing here is exposure-corrected,
## because a splat **reports radiance** and the environment decides what is seen.
##
## **It is in the 3D pass and not in the overlay, deliberately.** A `CanvasLayer` is composited *after*
## the tonemap, so a splat drawn there would ignore the exposure entirely and could not be a body's
## radiance at all — which is why the navigation overlay, for all that it already projects screen
## positions, is the wrong home for this.
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
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# Without this the billboard throws the node's scale away, and the scale is what sizes the splat.
	material.billboard_keep_scale = true
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
