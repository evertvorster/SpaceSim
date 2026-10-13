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


## `FogVolumeShape` is **not exposed to GDScript at all** in this build — not as a member of FogVolume,
## not as a global enum, and not in ClassDB's constant list. Its value comes from the property hint on
## `FogVolume.shape` instead, which reads "Ellipsoid (Local),Cone (Local),Cylinder (Local),Box (Local),
## World (Global)" — so ellipsoid is 0, and the default of 3 is box, which is what a FogVolume should
## default to. Named here rather than left as a bare 0.
##
## *(Local)* matters: the volume is measured in its parent's space, so a shell parented to a body moves
## with that body and needs no per-frame repositioning.
const AIR_SHAPE_ELLIPSOID := 0

## The air's density profile, as a 3D texture rather than `height_falloff`.
##
## **`height_falloff` does not work here.** It is documented as falling off in *world* space, and it
## measured uniform in practice — Evert: "keeps the same thickness all the way up to where the
## atmosphere ends". A planet's surface is a sphere, so height above it is a radius, not a Y. A density
## texture is sampled in the volume's own local space, so the profile is a function of radius and world
## space cannot enter into it.
const AIR_TEXTURE_SIZE := 32

## Where the density has fallen to 1/e, as a fraction of the way from the surface to the top. A sixth
## puts the air's visible thinning in the lower part of the shell and leaves the upper part nearly
## clear — "almost gone when you transition into space".
##
## The derived scale height is `kT/(m-bar g)` and needs the temperature stage, which is not built; when
## it is, it replaces this fraction rather than sitting beside it.
const AIR_SCALE_FRACTION := 1.0 / 6.0

## The air's density at one atmosphere, as a fraction of Godot's fog units, lives in
## [code]SpacesimAtmosphereModel.DENSITY_AT_ONE_BAR[/code] — it is a property of the air rather than of
## the drawing, and it is scaled live by the `air.density` setting.

## How far above the surface the air reaches, in metres: the altitude at which the observer crosses
## into space. This is the *outer* bound of the fog shell, taken from the framing the scene already
## uses for that transition rather than guessed at separately — so the air ends exactly where the air
## is declared to end.


## The air's density with height: 1.0 at the surface, falling exponentially toward nothing at the top.
##
## Evert: *"most of the density at the surface of the planet and thinning out logarithmically until it
## should be almost gone when you transition into space."* Exponential in height is what a scale height
## is, so this is the shape the derived `kT/(m-bar g)` will slot into.
##
## Below the surface it is 1.0 — there is no reason to thin the air *inside* a planet, and the planet
## occludes it in any case.
static func air_profile(distance_from_centre: float, surface_radius: float, scale_height: float) -> float:
	if distance_from_centre <= surface_radius:
		return 1.0
	return exp(-(distance_from_centre - surface_radius) / maxf(scale_height, 1.0))


## The profile above, baked into a 3D texture for the shell to sample.
##
## The coordinate is the **radius from the volume's own centre**, so the air thins upward from the
## surface in every direction at once, and world space never enters into it.
static func air_density_texture(surface_radius: float, outer_radius: float) -> Texture3D:
	var size := AIR_TEXTURE_SIZE
	var scale_height := (outer_radius - surface_radius) * AIR_SCALE_FRACTION
	var slices: Array[Image] = []
	for z in size:
		var slice := Image.create(size, size, false, Image.FORMAT_R8)
		for y in size:
			for x in size:
				var offset := Vector3(
					(float(x) + 0.5) / float(size) - 0.5,
					(float(y) + 0.5) / float(size) - 0.5,
					(float(z) + 0.5) / float(size) - 0.5
				)
				var distance := offset.length() * 2.0 * outer_radius
				slice.set_pixel(x, y, Color(air_profile(distance, surface_radius, scale_height), 0.0, 0.0))
		slices.append(slice)
	var texture := ImageTexture3D.new()
	texture.create(Image.FORMAT_R8, size, size, size, false, slices)
	return texture


## The air as a **hollow shell of fog**: an ellipsoid whose outer bound is where the atmosphere ends
## and whose inner bound is below the surface, so the planet itself occludes the middle and what is
## left is the shell.
static func atmosphere_volume(
	body: SpacesimSceneBody, top_altitude: float, materials: SpacesimMaterialTable
) -> FogVolume:
	var air := body.content.atmosphere if body.content != null else null
	if air == null or top_altitude <= 0.0:
		return null
	var outer := body.radius + top_altitude
	var material := FogMaterial.new()
	material.albedo = SpacesimAtmosphereModel.color(body.content, materials)
	material.density = SpacesimAtmosphereModel.density(body.content)
	material.density_texture = air_density_texture(body.radius, outer)
	# Left at zero deliberately: the falloff lives in the density texture, because this one measures
	# height in world space and a sphere's height is a radius.
	material.height_falloff = 0.0
	var volume := FogVolume.new()
	volume.name = "%sAir" % body.name
	volume.shape = AIR_SHAPE_ELLIPSOID
	volume.size = Vector3(outer, outer, outer) * 2.0
	volume.material = material
	# Shown only when the observer is inside this body's air — see SpacesimSystemScene.air_body().
	volume.visible = false
	return volume


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
