class_name SpacesimBodyRenderer
extends RefCounted
## Builds what a body looks like: its surface material, and its point of light.
##
## Everything the shaders are given comes from **the derivation** — the albedo colour, the body's own
## temperature — so a shader cannot quietly disagree with the model. What is *not* derived yet is named in
## the constants below rather than buried in the shader, because a hidden constant is one nobody can find
## when the picture is wrong.
##
## **Nothing here draws air or cloud.** The air shell, the cloud deck shells and the surface-texture
## mapping are all gone; the next features are built from their plans, not from these materials.
## `SpacesimClouds` stays and is still read: `bond_albedo` needs it, and Earth's calibrated 0.302 against a
## measured 0.306 depends on the deck's fraction and albedo.

const SURFACE_SHADER := preload("res://addons/spacesim/render/body_surface.gdshader")
const OCEAN_SHADER := preload("res://addons/spacesim/render/body_ocean.gdshader")
const STAR_SHADER := preload("res://addons/spacesim/render/body_star.gdshader")
## How far past the environment's `glow_hdr_threshold` (1.0) a star sits. This is the bloom knob: a
## star at 1.0 is a bright dot, and a star is supposed to glare. **Also what a star's point of light is
## emitted at**, so the two cannot disagree.
const STAR_INTENSITY := 24.0

## **Not derived, and deliberately visible here.** Roughness and specularity are per-material
## properties the material table does not carry yet, and relief strength is a look decision. Terrain
## shape from composition is the next thing the derivation can honestly supply.
const SURFACE_ROUGHNESS := 0.9
const SURFACE_SPECULAR := 0.15
## **The ocean's own shading**, and the ocean is its own shader — water and land are fundamentally different
## things (Evert, 2026-10-19). Glossy, so the sun's glint and the bright limb come out of the BRDF for free,
## and the wave rungs keep the glint from being a hard dot.
const OCEAN_ROUGHNESS := 0.14
const OCEAN_SPECULAR := 0.45
## **The depth ramp, in metres.** Shallow water returns light off the bottom, which is what its colour is; past
## `OCEAN_DEEP_METRES` it is the water's own colour and nothing shows through. Evert: *"it has a super-high
## absorption, so realistically we won't see anything below a couple of meters."*
const OCEAN_SHALLOW_METRES := 2.0
const OCEAN_DEEP_METRES := 40.0
## How much of the bottom's colour is left in the shallows, against the water's — a mix, not a tint, because the
## shelf is where both are true.
const OCEAN_SHALLOW_BOTTOM_SHARE := 0.7
## **Waves**: two rungs of the field's generator, a swell of a few hundred metres, and a tilt of a fraction of a
## degree. `OCEAN_WAVE_METRES` is the coarsest wavelength.
const OCEAN_WAVE_OCTAVES := 2
const OCEAN_WAVE_METRES := 400.0
const OCEAN_WAVE_RELIEF := 0.02
const OCEAN_WAVE_NEAR_METRES := 1.0
const OCEAN_WAVE_FAR_METRES := 25.0

## **How much the height gradient tilts the normal.** A real planet's relief is 0.14 % of its radius, so its
## slopes are a fraction of a degree and the shading they cast is invisible at any distance — the geometry is
## honest and the picture is flat. This is the named concession, and it is a *uniform* rather than a constant
## in the shader so the host owns it and it can be tuned.
##
## **5.0, down from 12, because 12 lit the coastlines on the night side.** The exaggeration tilts the normal of
## a sphere that has no relief; past a certain tilt the fiction beats the geometry, and the symptom is a thin
## dotted glow tracing every coast in the dark — the coast being the only steep place, and the *interiors*
## staying correctly black. The shader also clamps the tilt at 19° for the same reason.
const RELIEF_EXAGGERATION := 5.0

## **The ladder: how many rungs, how much it moves the colour, and how much it tilts the normal.**
##
## The octave count is a *cost* decision before it is a look decision: a rung costs one FastNoiseLite octave on
## every pixel the ground covers, and the deck measured **six** at ~5 ms a frame at 1080p on this machine. Eight
## is chosen here because the rungs fade by what a pixel can resolve, so at a distance two or three run and
## only a ground filling the screen pays for all eight — which is the number to watch in flight.
const DETAIL_OCTAVES := 8
## Colour variation is deliberately small: the bands' mean is what the temperature and the light budget are
## fitted to, and a large swing would move the drawn average away from it.
const DETAIL_VARIATION := 0.18
## **The relief's exaggeration**, in the sloped sense: the shader computes a real slope (metres of height per
## metre of ground) and this scales it. It is the one look number in the relief, and 1.0 is a surface that shades
## exactly as steep as it is.
const DETAIL_RELIEF := 1.0
## **And water's, which is a fiftieth of the land's** — waves are metres tall and a pixel 400 m across holds the
## average of a hundred of them, which is flat. Evert, 2026-10-19: *"the ocean needs to be practically smooth
## until we walk around next to it... waves as tall as mountains is a bit scary."* Gated as well, on the pixel
## being metres wide: see `body_surface.gdshader`'s `wave_near`/`wave_far`.
const WAVE_RELIEF := 0.02
## Where a wave stops existing, in metres of ground per pixel. A 2 m swell is unresolved long before a pixel
## covers a kilometre, so this is a statement about the wave rather than about the distance.
const WAVE_NEAR_METRES := 1.0
const WAVE_FAR_METRES := 25.0
## **How fast the relief decays per rung, against the colour's own gain.** Evert, 2026-10-19: *"small features
## should have small shadows."* At the field's gain the slope is the same on every octave, so the finest visible
## bump shades as hard as a mountain and the ground becomes a bed of black pits. A quarter per rung halves the
## slope each time, so the coarse shapes carry the shading.
const RELIEF_GAIN := 0.25
## **A ceiling on how far the detail may tilt a normal.** A bump's dark side drawn as absolute black is the
## missing sky as much as the relief — with no air above it, nothing lifts a shadow — so the fiction may lean
## only so far before it becomes a hole.
const RELIEF_MAX_TILT := 0.6

## Texels in the colour ramp. **256 along the height axis** is finer than any band edge needs (a band edge
## interpolates the measured quantiles, so it is not quantised by this), and it is one row: the ramp is a
## lookup table, not a texture.
const RAMP_WIDTH := 256
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

## The wireframe view's one material — see [method wireframe_material].
static var _wireframe: StandardMaterial3D
## The one-texel neutral height map every un-baked material starts with.
static var _flat: ImageTexture
static var _point_quad: QuadMesh
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
## **The wireframe view's material: white, and unshaded.**
##
## The point of the view is to see where the triangles are, so nothing about it may depend on the light —
## a lit wireframe on a sunlit disc is white lines on white. `SHADING_MODE_UNSHADED` is the whole of it,
## plus `disable_receive_shadows` so the lines do not fade under the terminator either.
##
## Shared and cached: one material for every body, because a wireframe has no per-body anything.
static func wireframe_material() -> StandardMaterial3D:
	if _wireframe == null:
		_wireframe = StandardMaterial3D.new()
		_wireframe.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_wireframe.albedo_color = Color(1.0, 1.0, 1.0)
		_wireframe.disable_receive_shadows = true
		# A line has no faces to cull, but an inside-out shell would z-fight its own far side; drawing depth
		# opaque and leaving it at that keeps the view readable from inside an atmosphere.
		_wireframe.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	return _wireframe


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
static func material_for(body: SpacesimSceneBody, ramp: ImageTexture, has_ocean: bool) -> Material:
	if body.content != null and body.content.kind == SpacesimSystemBody.Kind.STAR:
		return star_material(body)
	return surface_material(body, ramp, has_ocean)


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


## **The colour ramp: the derived bands, indexed by field value.**
##
## The bands are authored as *area fractions* and the shader needs a *colour for a height*, so the bridge is
## the baked field's own distribution: each band edge's percentile is turned into a field value through the
## measured quantiles, and the ramp is filled between them. **This is the derivation-to-picture link**, and it
## is one place: the bands' colours are already normalised to their own albedos, so nothing here decides a
## colour, only where it starts.
##
## `fallback` is what a body with **no bands at all** is filled with — a gas giant, whose visible surface is its
## deck, keeps the derived colour it was already drawn in rather than going grey.
static func surface_ramp(
	bands: Array, quantiles: PackedFloat32Array, fallback: Color
) -> ImageTexture:
	return ImageTexture.create_from_image(ramp_image(bands, quantiles, fallback))


## The ramp as an **`Image`** — the part worth testing, since a texture needs a renderer and the arithmetic
## does not.
static func ramp_image(
	bands: Array, quantiles: PackedFloat32Array, fallback: Color
) -> Image:
	var image := Image.create_empty(RAMP_WIDTH, 1, false, Image.FORMAT_RGBA8)
	var edges: Array = []
	for band in bands:
		edges.append([
			SpacesimSurfaceMaps.value_at(quantiles, float(band["from"])),
			SpacesimSurfaceMaps.value_at(quantiles, float(band["to"])),
			band["color"],
		])
	for index in RAMP_WIDTH:
		var value := lerpf(-1.0, 1.0, float(index) / float(RAMP_WIDTH - 1))
		image.set_pixel(index, 0, _band_colour(edges, value, fallback))
	return image


## The band a field value falls in, or the nearest one past either end — a sea below the lowest band and a
## peak above the highest are still the sea and that peak.
static func _band_colour(edges: Array, value: float, fallback: Color) -> Color:
	if edges.is_empty():
		return fallback
	for edge in edges:
		if value <= float(edge[1]):
			return edge[2]
	return edges[edges.size() - 1][2]


## A one-texel map at a neutral height, so a body with no bake yet draws its colour ramp rather than black.
## **The shader's samplers default to black**, which for a height field means "the datum everywhere" — that
## happens to be harmless, and a flat 0.5 makes the intent explicit rather than relying on it.
static func flat_height(value: float) -> ImageTexture:
	if _flat == null:
		var image := Image.create_empty(1, 1, false, Image.FORMAT_RH)
		image.set_pixel(0, 0, Color(value, 0.0, 0.0, 1.0))
		_flat = ImageTexture.create_from_image(image)
	return _flat


## The surface material: **a height field, a colour ramp and a sea.**
##
## Everything it is given is derived: the ramp from `SpacesimSurfaceModel.bands()` and the measured quantiles,
## the amplitude from `SpacesimSurfaceField.plan()`, the radius from the body. **The maps and the sea level
## arrive later**, when the first bake lands — `apply_surface_maps()` is the one place that sets them, so the
## shader cannot be told one body's maps and another's sea.
static func surface_material(
	body: SpacesimSceneBody, ramp: ImageTexture, has_ocean: bool
) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SURFACE_SHADER
	material.set_shader_parameter("colour_ramp", ramp)
	material.set_shader_parameter("height_map", flat_height(0.5))
	material.set_shader_parameter("planet_radius", body.radius)
	material.set_shader_parameter(
		"field_amplitude", SpacesimSurfaceField.plan(body.id, body.radius).amplitude
	)
	material.set_shader_parameter("relief_exaggeration", RELIEF_EXAGGERATION)
	material.set_shader_parameter("map_width", SpacesimSurfaceMaps.BUILD_WIDTH)
	# **The ladder's numbers, from the same plan the bake uses** — one writer, so the detail cannot be a
	# different field from the map it extends. `detail_feature` starts at two texels of the map in hand.
	var plan := SpacesimSurfaceField.plan(body.id, body.radius)
	material.set_shader_parameter("detail_seed", plan.seed)
	material.set_shader_parameter("detail_gain", plan.gain)
	material.set_shader_parameter("detail_lacunarity", plan.lacunarity)
	material.set_shader_parameter(
		"detail_feature", 2.0 * TAU / float(SpacesimSurfaceMaps.BUILD_WIDTH)
	)
	material.set_shader_parameter("detail_octaves", DETAIL_OCTAVES)
	material.set_shader_parameter("detail_variation", DETAIL_VARIATION)
	material.set_shader_parameter("detail_relief", DETAIL_RELIEF)
	material.set_shader_parameter("relief_gain", RELIEF_GAIN)
	material.set_shader_parameter("relief_max_tilt", RELIEF_MAX_TILT)
	material.set_shader_parameter("has_ocean", 1.0 if has_ocean else 0.0)
	material.set_shader_parameter("land_roughness", SURFACE_ROUGHNESS)
	material.set_shader_parameter("land_specular", SURFACE_SPECULAR)
	return material


## **The ocean's material**, built from the same derivation as the land's: the deep colour is the *liquid* band's
## own, and the shallow colour is the lowest land band — what the bottom is made of — mixed with the water's,
## because a shelf is the one place both are true.
##
## **A body with no liquid band gets no ocean material at all**, which is how the phase test reaches the
## renderer: `bands()` has no liquid entry for Mars, Venus, Mercury, Luna, Io, Europa or Triton, so no sea is
## built there rather than a sea with zero coverage.
static func ocean_material(body: SpacesimSceneBody, bands: Array) -> ShaderMaterial:
	var deep := SpacesimSurfaceModel.UNPINNED_COLOR
	var bottom := SpacesimSurfaceModel.UNPINNED_COLOR
	for band in bands:
		var colour: Color = band["color"]
		if band_is_liquid(band):
			deep = colour
		elif bottom == SpacesimSurfaceModel.UNPINNED_COLOR:
			bottom = colour
	if deep == SpacesimSurfaceModel.UNPINNED_COLOR:
		return null
	var material := ShaderMaterial.new()
	material.shader = OCEAN_SHADER
	material.set_shader_parameter(
		"shallow_color", bottom.lerp(deep, OCEAN_SHALLOW_BOTTOM_SHARE)
	)
	material.set_shader_parameter("deep_color", deep)
	material.set_shader_parameter("shallow_metres", OCEAN_SHALLOW_METRES)
	material.set_shader_parameter("deep_metres", OCEAN_DEEP_METRES)
	material.set_shader_parameter("roughness_value", OCEAN_ROUGHNESS)
	material.set_shader_parameter("specular_value", OCEAN_SPECULAR)
	material.set_shader_parameter("height_map", flat_height(0.5))
	material.set_shader_parameter("planet_radius", body.radius)
	var plan := SpacesimSurfaceField.plan(body.id, body.radius)
	material.set_shader_parameter("field_amplitude", plan.amplitude)
	material.set_shader_parameter("map_width", SpacesimSurfaceMaps.BUILD_WIDTH)
	material.set_shader_parameter("wave_seed", plan.seed + 7331)
	material.set_shader_parameter("wave_gain", plan.gain)
	material.set_shader_parameter("wave_lacunarity", plan.lacunarity)
	material.set_shader_parameter(
		"wave_feature", OCEAN_WAVE_METRES / maxf(body.radius, 1.0)
	)
	material.set_shader_parameter("wave_octaves", OCEAN_WAVE_OCTAVES)
	material.set_shader_parameter("wave_relief", OCEAN_WAVE_RELIEF)
	material.set_shader_parameter("wave_near", OCEAN_WAVE_NEAR_METRES)
	material.set_shader_parameter("wave_far", OCEAN_WAVE_FAR_METRES)
	return material


## Whether a band entry came from a liquid material — the derivation's own answer, read off the phase it carries.
static func band_is_liquid(band: Dictionary) -> bool:
	return int(band.get("phase", -1)) == SpacesimSurfaceModel.Phase.LIQUID


## **Publish a bake.** The texture and the sea level are set together and from one entry, because a sea level
## from one body and a map from another is a coastline in the wrong place that nothing would catch.
##
## **Only the refining map is published**, and the build bake is not: the shader thresholds and colours from
## whatever resolution it is handed, and the build map's job is the *measurement* (the quantiles the sea level
## and the band edges come from), which happens on the host.
## **A test that would have caught the old shape**: the material must have no `coarse_map` parameter, because a
## second texture in the shader is a second resolution to keep in step with the picture. **The same reasoning
## deleted the window** — the shader now samples exactly one height map, at whatever width the ladder has reached.
## **Publish the near field**: the tile array and the rectangles that index it.
##
## The array itself and the rectangles are handed over together, because a rectangle names a layer and a layer
## without its array is an index into nothing. **Padded to the table's size** rather than truncated to the live
## count: a fixed-size uniform array is written whole, and `tile_count` is what the shader loops over.
static func apply_surface_tiles(
	material: Material, array: Texture2DArrayRD,
	rects: PackedVector4Array, layers: PackedInt32Array
) -> void:
	var surface := material as ShaderMaterial
	if surface == null:
		return
	# **A rectangle without its array is an index into nothing**, so no array means no tiles are claimed — the
	# shader samples the whole-body map alone until the first tile has actually landed.
	var live := rects.size() if array != null else 0
	if array != null and surface.get_shader_parameter("tile_map") != array:
		surface.set_shader_parameter("tile_map", array)
	var size := SpacesimSurfaceTiles.MAX_TILES
	var padded_rects := PackedVector4Array()
	var padded_layers := PackedInt32Array()
	padded_rects.resize(size)
	padded_layers.resize(size)
	for index in size:
		if index < live:
			padded_rects[index] = rects[index]
			padded_layers[index] = layers[index]
		else:
			padded_rects[index] = Vector4.ZERO
			padded_layers[index] = 0
	surface.set_shader_parameter("tile_rect", padded_rects)
	surface.set_shader_parameter("tile_layer", padded_layers)
	surface.set_shader_parameter("tile_count", mini(live, size))


static func apply_surface_maps(
	material: Material, texture: Texture2D, width: int
) -> void:
	if material == null or texture == null:
		return
	var surface := material as ShaderMaterial
	if surface == null:
		return
	# **Identity, not a width**: two refined maps can share a width across a recede and re-approach, and a
	# repoint is a dictionary write against a texture that is already correct.
	if surface.get_shader_parameter("height_map") != texture:
		surface.set_shader_parameter("height_map", texture)
		surface.set_shader_parameter("map_width", width)
		# **The ladder starts where the map stops**, so a refinement moves it — otherwise the detail would either
		# duplicate what the new map shows or leave a band of nothing between them.
		surface.set_shader_parameter("detail_feature", 2.0 * TAU / float(maxi(width, 1)))
