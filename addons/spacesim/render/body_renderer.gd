class_name SpacesimBodyRenderer
extends RefCounted
## Builds what a body looks like: its surface material, and its cloud deck when it has one.
##
## Everything the shaders are given comes from **the derivation** — the albedo colour, the cloud
## fraction and colour — so a shader cannot quietly disagree with the model. What is *not* derived yet
## is named in the constants below rather than buried in the shader, because a hidden constant is one
## nobody can find when the picture is wrong.

const SURFACE_SHADER := preload("res://addons/spacesim/render/body_surface.gdshader")
const CLOUDS_SHADER := preload("res://addons/spacesim/render/body_clouds.gdshader")
const STAR_SHADER := preload("res://addons/spacesim/render/body_star.gdshader")

## How far past the environment's `glow_hdr_threshold` (1.0) a star sits. This is the bloom knob: a
## star at 1.0 is a bright dot, and a star is supposed to glare.
const STAR_INTENSITY := 24.0

## How far above the surface the cloud shell sits. Near enough to read as a deck *on* the body, far
## enough that the two spheres do not z-fight.
const CLOUD_SHELL := 1.012

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
const CLOUD_NOISE_SCALE := 1.6

## The deck samples the field somewhere else, so clouds do not sit in exactly the pattern the terrain
## underneath is wearing. Small on purpose — see `offset_for`.
const CLOUD_OFFSET := Vector3(0.07, 0.03, 0.11)

static var _noise: NoiseTexture3D


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


## The material a body is drawn with.
##
## **A star is a source and everything else is a reflector**, so the choice is by kind rather than by
## anything a shader could work out for itself.
static func material_for(body: SpacesimSceneBody) -> Material:
	if body.content != null and body.content.kind == SpacesimSystemBody.Kind.STAR:
		return star_material(body)
	return surface_material(body)


## A star's own surface: unshaded, and coloured from its temperature.
##
## Unshaded because it is a source — drawn with the ordinary surface material it was lit by *its own*
## light, which travels from the star toward the observer, so its near face was back-lit and rendered
## black. Which is exactly what it looked like.
static func star_material(body: SpacesimSceneBody) -> ShaderMaterial:
	var content := body.content
	var luminosity := SpacesimStarModel.luminosity(content)
	var temperature := SpacesimStarModel.effective_temperature(luminosity, content.radius)
	var material := ShaderMaterial.new()
	material.shader = STAR_SHADER
	material.set_shader_parameter("star_color", SpacesimStarModel.color(temperature))
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


## The cloud deck's material, or null when the body has no deck.
##
## The authored fraction **is** the coverage: it sets the noise threshold, so a body content calls 60%
## covered comes out 60% covered, rather than the fraction being a number the shader politely ignores.
static func cloud_material(body: SpacesimSceneBody) -> ShaderMaterial:
	var clouds: SpacesimClouds = body.content.clouds if body.content != null else null
	if clouds == null or clouds.fraction <= 0.0 or clouds.opacity <= 0.0:
		return null
	var material := ShaderMaterial.new()
	material.shader = CLOUDS_SHADER
	material.set_shader_parameter("cloud_color", clouds.color)
	material.set_shader_parameter("coverage", clampf(clouds.fraction, 0.0, 1.0))
	material.set_shader_parameter("opacity", clampf(clouds.opacity, 0.0, 1.0))
	material.set_shader_parameter("noise_scale", CLOUD_NOISE_SCALE)
	material.set_shader_parameter("noise_offset", offset_for(body.id) + CLOUD_OFFSET)
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
