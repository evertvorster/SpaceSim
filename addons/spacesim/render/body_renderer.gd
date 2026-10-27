class_name SpacesimBodyRenderer
extends RefCounted
## Builds what a body looks like: its surface material, and its point of light.
##
## Everything the shaders are given comes from **the derivation** — the albedo colour, the body's own
## temperature — so a shader cannot quietly disagree with the model. What is *not* derived yet is named in
## the constants below rather than buried in the shader, because a hidden constant is one nobody can find
## when the picture is wrong.
##
## **Nothing here draws air.** The air is one volumetric march over the frame (`SpacesimAtmospherePass`), and a
## material that applied air of its own beside it would apply the same air twice. The cloud deck shells and the
## surface-texture
## mapping are all gone; the next features are built from their plans, not from these materials.
## `SpacesimClouds` stays and is still read: `bond_albedo` needs it, and Earth's calibrated 0.302 against a
## measured 0.306 depends on the deck's fraction and albedo.

const SURFACE_SHADER := preload("res://addons/spacesim/render/body_surface.gdshader")
const OCEAN_SHADER := preload("res://addons/spacesim/render/body_ocean.gdshader")
const DECK_SHADER := preload("res://addons/spacesim/render/body_deck.gdshader")
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
## `OCEAN_DEEP_METRES` it is the water's own colour and nothing shows through.
##
## **It has to span real bathymetry, or the sea has no structure at all.** Evert, 2026-10-19: *"from far out, its
## too smooth."* The ramp was 2 m to 40 m, against a field of 8,919 m on Earth — so `deep_color` arrived at 0.45 %
## of the water column and **every pixel of the ocean was "deep"**: one flat colour from orbit, with a hairline
## fringe at the shore. The sea floor's own structure — basins, ridges, trenches — is the only large-scale
## variation a sea has, and the ramp was hiding all of it.
##
## 5 m and 3,000 m are Earth's own numbers either side of the interesting range: the shelf break is at about
## 130-200 m, the abyssal plains are 4,000-6,000 m, and a ridge crest is 1,000-2,000 m. Filling at 3 km keeps the
## abyss reading as one colour (it is one colour) while the ridges, rises and shelves cross the ramp.
const OCEAN_SHALLOW_METRES := 5.0
const OCEAN_DEEP_METRES := 3000.0
## How much of the bottom's colour is left in the shallows, against the water's — a mix, not a tint, because the
## shelf is where both are true.
const OCEAN_SHALLOW_BOTTOM_SHARE := 0.7
## **Waves**: two rungs of the field's generator, a swell of a few hundred metres, and a tilt of a fraction of a
## degree. `OCEAN_WAVE_METRES` is the coarsest wavelength.
## **Eight octaves, from a 400 m swell down to 3 m of chop**, and there is no separate near/far gate any more.
## Evert, 2026-10-19: *"The sea still renders absolutely smooth all the way down to 10 km. Then, we get a rough
## texture. We need a finer texture, and that needs to start resolving at about the same height that the mottling
## on land starts to resolve."* Two octaves reached 200 m and a `wave_fade` clamped everything to a pixel under
## 25 m — full below 0.8 km, gone above 20.8 km — so the *gate* decided when the sea appeared, not the sampling
## law, and it appeared at the altitude he named. The per-rung footprint fade was always the law (**reuse the law;
## never restate it**), and with the clamp gone a 400 m swell resolves from 166 km; eight octaves carry it down to
## 3 m, which keeps resolving below a kilometre of altitude.
const OCEAN_WAVE_OCTAVES := 8
const OCEAN_WAVE_METRES := 400.0
## **The wave's own steepness, and the reason it is 0.0015 and not 0.02.** A wave's height is a fraction of its
## wavelength — a moderate sea is about a twentieth — so a 400 m swell is ~13 m tall, and 13 m is 0.0015 of the
## 8,919 m field. At 0.02 the swell would have been 178 m: waves as tall as mountains, which is the *"bit scary"*
## the earlier number was trying to avoid.
const OCEAN_WAVE_RELIEF := 0.0015
## **How far the swell is drawn out along the wind**, and this is what makes water look like water rather than
## like ground. Evert, 2026-10-19: the close-up sea *"looks exactly like that mottling on land"* — because it was
## the same isotropic generator sampled the same way, with no direction in it at all. Wind-driven swell and chop
## are stretched downwind, and that anisotropy is the single thing that reads as sea.
## 3.0 is a light breeze's swell; a gale would be nearer 6.
const OCEAN_WAVE_STRETCH := 3.0
## **The sea's own colour structure**, which is the only thing an ocean shows at range: eddies, fronts and slicks.
## Waves are geometry — nothing under 400 m can be seen from 1,000 km — so without this the far sea is one colour,
## which is what Evert reported.
##
## **It starts where the land's ladder starts**: two texels of the map in hand, which the shader derives from
## `map_width`, so the two layers begin to show texture at the same distance and by the same law. Evert,
## 2026-10-19: *"I just wanted to reduce the strength, not the distance at which it started drawing."* The
## strength is `OCEAN_TONE_VARIATION`; the distance is the sampling law and is not a knob.
const OCEAN_TONE_OCTAVES := 3
## A few per cent of the water's colour — enough to read as water moving, not enough to be paint.
const OCEAN_TONE_VARIATION := 0.12

## **How dark a cloud's shadow is allowed to get** — the floor on the light it leaves, so `1.0` is no shadow and
## `0.0` is the physical transmittance with nothing given back.
##
## **The engine gives one `AO` value and it drives both the ambient and the direct light**, so "a shadow keeps
## the ambient" cannot be written as two numbers — it is a floor or it is a `light()` override, and the override
## costs the PBR the surface was tuned with. Evert, 2026-10-20: *"when you are in the shadow of a cloud, there is
## usually still plenty of ambient light."* The physical reason is multiple scattering: a cloud's base is a
## bright diffuse source overhead, and nothing here models it — the ambient is a *constant*, not a sky probe.
##
## **0.45**: a shadow removes a little over half the light, which reads as shade rather than as night, and the
## contrast against full sun is still unmistakable. A look number, and one that wants a flight rather than a
## calculation. When the lighting plan gives the ambient an actual sky, this floor goes and the ambient is
## simply lit by what is above it.
const DECK_SHADOW_FLOOR := 0.45

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

## **The ladder's DEPTH — how many rungs exist, not how many run.** The shader derives the count from the pixel:
##
##     rungs = clamp(ceil(log2(first_feature / (2 * footprint))), 0, detail_max_rungs)
##
## where `first_feature` is the field's octave `first_detail_octave` — the first one the map did not carry. So a
## distant body runs none, a ground filling the frame runs as many as it can resolve, and this constant is only the
## ceiling on that. **Which fixes the fault it replaced**: `DETAIL_OCTAVES = 8` was a *count*, so the finest
## rung was `feature / 2^8` whatever the pixel — 271 m on Earth at a 2,304-wide map, against the 13 m a pixel covers
## at 10 km altitude. Detail stopped arriving and no amount of approach brought it back.
##
## **The depth is 18 because of a count, not a taste.** The ladder starts at two texels of the map in hand, and a
## rung halves the feature: the rungs a view needs are `log2(feature / footprint)`. Measured on the two maps the
## game actually uses, at the 720p centre pixel:
##
## | map | feature | 2,000 km up | 100 km | 10 km | 1 km |
## |---|---|---|---|---|---|
## | 512 (the 720p default's ceiling) | 156 km | 6 | 11 | 14 | **17** |
## | 2,304 (a 4K render, half of it) | 34.7 km | 4 | 9 | 12 | 15 |
##
## So the finest a 1 km descent asks for is 17, and the ceiling sits one above it. **A deeper ceiling costs nothing**
## — the count that runs is the pixel's, so a distant body evaluates one rung whatever this number is — which is
## exactly why it can afford to be generous.
const DETAIL_MAX_RUNGS := 18
## Colour variation is deliberately small: the bands' mean is what the temperature and the light budget are
## fitted to, and a large swing would move the drawn average away from it.
const DETAIL_VARIATION := 0.18
## **The banded detail ladder's loudness, in the field's own units.** This is the number that decides whether a tile
## is a textured piece of ground or a smooth square: the ladder is normalised to `detail_strength` and its first rung
## carries half of it, so 0.15 is 7.5 % of the field's ±1 at the largest rung — tens of metres of relief at the map's
## two-texel scale, which is what a hillside has.
const SURFACE_DETAIL_STRENGTH := 0.15
## **The relief's exaggeration**, in the sloped sense: the shader computes a real slope (metres of height per
## metre of ground) and this scales it. It is the one look number in the relief, and 1.0 is a surface that shades
## exactly as steep as it is.
const DETAIL_RELIEF := 1.0
## **The amplitude falloff of the octaves below the map**, and the one place the ladder deviates from the field's
## own spectrum. Evert, 2026-10-19: *"the landscape looks too smooth now. We need a little graininess coming up when
## we are close, but only a tiny amount."*
##
## The field falls at `gain` 0.5 per octave, which is `2^-1` — a self-affine surface whose slope is the same at
## every scale. Real terrain is closer to `2^-0.8 = 0.574`: its *slope* grows as you look closer, which is why a
## 30 m hill is tens of centimetres tall rather than millimetres. At a 1 km altitude the ladder reaches octave 20,
## where 0.5 gives **8.7 mm** of relief and 0.574 gives **about 10 cm** — both tiny, but only one of them is there
## at all.
##
## **The map keeps the field's own 0.5.** That spectrum is what the far view was calibrated on and what makes the
## continents read at 20,000 km; this number only governs the octaves the bake never carried, so the change is
## continuous in amplitude at the seam and differs only in the tail's slope. **0.574 is `2^-0.8`** and is the
## physical value, not a taste — and it is deliberately *not* larger: the tail is grain, not hills.
const DETAIL_TAIL_GAIN := 0.574

## **A ceiling on how far the detail may tilt a normal.** A bump's dark side drawn as absolute black is the
## missing sky as much as the relief — with no air above it, nothing lifts a shadow — so the fiction may lean
## only so far before it becomes a hole.
##
## (There was a second decay here, `RELIEF_GAIN`, that quartered each rung's relief amplitude. It existed to stop
## an inflated ladder shading like a bed of black pits, and it went with that ladder: the field's own spectrum
## already halves the amplitude per octave, so the slope of a fine octave is half the coarse one's for free.)
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

## **How far the deck's detail ladder may push the field either side of the map's own value.** Measured when
## this was last built (`tests/probe_deck_detail.gd`, 2026-10-18): coverage 60.5 % → 57.3 %, mean thickness
## 0.3419 → 0.3396 — small enough that the percentile threshold and the fitted ramp gain stay honest, which
## is the property that matters, because both are measured off the *map's* distribution.
const DECK_DETAIL_STRENGTH := 0.2

## **How wide the deck's coverage edge is, in field units** — the `smoothstep` around `threshold`. Published
## rather than left to the shader's own default: it was a `hint_range` uniform nobody set, which reads as a
## knob and is a constant. Named here and handed over, so the host owns it like every other look number.
const DECK_SOFTNESS := 0.05

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


## A one-texel map at the neutral height, so a body with no bake yet draws its colour ramp rather than black.
## **The shader's samplers default to black**, which for a height field means "the datum everywhere" — that
## happens to be harmless, and a flat 0.5 makes the intent explicit rather than relying on it.
##
## **One image, and it takes no argument.** It used to take the height and cache the first caller's value for
## the whole process — every caller passed 0.5, so the parameter was a promise the function did not keep.
const FLAT_HEIGHT := 0.5

static func flat_height() -> ImageTexture:
	if _flat == null:
		var image := Image.create_empty(1, 1, false, Image.FORMAT_RH)
		image.set_pixel(0, 0, Color(FLAT_HEIGHT, 0.0, 0.0, 1.0))
		_flat = ImageTexture.create_from_image(image)
	return _flat


## **Does this body draw a reference sphere?** — the predicate [[SpaceSim/Levels of Detail|Levels of Detail]] §4
## states as a table, and the question is about *drawing a sphere*, not about having "ground": a gas giant has no
## surface register because its datum is a reference **pressure**, and a star's photosphere is drawn by its own
## shader. Naming the question that is actually being answered is what stopped the last version of this (`d57eb39`
## wrote it as "has a ground", which is false for a star and hid the Sun's disc behind a marker).
static func draws_reference_sphere(content: SpacesimSystemBody) -> bool:
	return content != null and content.surface != null


## **The octave of the field's own fbm that is two texels of a `width`-wide map** — where the ladder starts.
##
## `surface_height`'s octave `j` has `base_frequency * 2^j` on the unit sphere, so its feature is
## `1 / (base_frequency * 2^j)` radians; two texels of the map span `2 * (TAU / width)` = `4 pi / width`. Setting
## the two equal gives `j = log2(width / (4 pi * base_frequency))`.
##
## **The `4 pi` matters, and getting it wrong cost a band of nothing.** Written as `width / (2 * base_frequency)`
## it was off by `log2(2 pi)` — 2.65 octaves — so at a 960-wide map the ladder started at octave 8 when the map
## had stopped at 4, and octaves 5, 6 and 7 (160 km, 80 km, 40 km features) were drawn by neither the bake nor the
## shader. That is the "leaves a band of nothing between them" failure the `apply_surface_maps` comment warns
## about, and it read as the ground being too smooth. `tests/test_render.gd` now asserts the seam.
##
## Returns -1 for a body that should have no ladder at all.
static func first_detail_octave(base_frequency: float, width: int) -> int:
	if base_frequency <= 0.0 or width <= 0:
		return -1
	return int(round(log(float(width) / (4.0 * PI * base_frequency)) / log(2.0)))





## **How deep the detail ladder may go on this body**: none at all where there is no sphere to put it on.
##
## A gas giant used to be handed the full eight-rung ladder for a surface that is not its visible face — noise
## evaluated on every pixel of a body whose visible face is a deck. That is work with no need, and it is the §1.7
## pattern: the answer to "how much detail?" being given to something that never asked the question.
static func max_rungs_for(content: SpacesimSystemBody) -> int:
	return DETAIL_MAX_RUNGS if draws_reference_sphere(content) else 0


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
	material.set_shader_parameter("height_map", flat_height())
	material.set_shader_parameter("planet_radius", body.radius)
	material.set_shader_parameter(
		"field_amplitude", SpacesimSurfaceField.plan(body.id, body.radius).amplitude
	)
	material.set_shader_parameter("relief_exaggeration", RELIEF_EXAGGERATION)
	material.set_shader_parameter("map_width", SpacesimSurfaceMaps.BUILD_WIDTH)
	# **The ladder's numbers, from the same plan the bake uses** — one writer, so the detail cannot be a
	# different field from the map it extends. **The ladder is the field's own octaves**, so what it needs is not a
	# feature size but the field's own base frequency, its seed, and which octave the map stopped at:
	# `first_octave = log2(width / (4 pi * base_frequency))`, the octave whose feature is two texels of the brick
	# in hand — **the 4 pi is load-bearing**: as `width / (2 * base_frequency)` it was 2.65 octaves out and left
	# a band of nothing between the map and the ladder. `first_detail_octave` carries the reasoning.
	var plan := SpacesimSurfaceField.plan(body.id, body.radius)
	material.set_shader_parameter("detail_seed", plan.seed)
	material.set_shader_parameter("detail_base_frequency", plan.continent_frequency)
	material.set_shader_parameter("detail_first_octave", first_detail_octave(
		plan.continent_frequency, SpacesimSurfaceMaps.BUILD_WIDTH
	))
	material.set_shader_parameter("detail_bounding", plan.continent_bounding)
	material.set_shader_parameter("detail_gain", plan.gain)
	material.set_shader_parameter("detail_tail_gain", DETAIL_TAIL_GAIN)
	material.set_shader_parameter("detail_lacunarity", plan.lacunarity)
	material.set_shader_parameter("detail_max_rungs", max_rungs_for(body.content))
	material.set_shader_parameter("detail_variation", DETAIL_VARIATION)
	material.set_shader_parameter("detail_strength", SURFACE_DETAIL_STRENGTH)
	# **The field's own numbers for the crest continuation**, off the same plan the bake compiles.
	material.set_shader_parameter("field_plate_phase", plan.plate_phase)
	material.set_shader_parameter("field_belt_width", plan.belt_width)
	material.set_shader_parameter("field_ridge_frequency", plan.ridge_frequency)
	material.set_shader_parameter("field_ridge_octaves", plan.ridge_octaves)
	material.set_shader_parameter("field_ridge_strength", plan.ridge_strength)
	material.set_shader_parameter("field_gain", plan.gain)
	material.set_shader_parameter("field_lacunarity", plan.lacunarity)
	material.set_shader_parameter("field_warp_frequency", plan.warp_frequency)
	material.set_shader_parameter("field_warp_octaves", plan.warp_octaves)
	material.set_shader_parameter("field_warp_strength", plan.warp_strength)
	material.set_shader_parameter("field_warp_bounding", plan.warp_bounding)
	material.set_shader_parameter("detail_relief", DETAIL_RELIEF)
	material.set_shader_parameter("relief_max_tilt", RELIEF_MAX_TILT)
	material.set_shader_parameter("has_ocean", 1.0 if has_ocean else 0.0)
	material.set_shader_parameter("land_roughness", SURFACE_ROUGHNESS)
	material.set_shader_parameter("land_specular", SURFACE_SPECULAR)
	# **No deck above to begin with**: `deck_tau = 0` makes the shadow path a uniform branch, which is the
	# honest state of every body without a cloud layer. `apply_deck_shadow()` is the one writer.
	material.set_shader_parameter("deck_tau", 0.0)
	material.set_shader_parameter("deck_height", 0.0)
	material.set_shader_parameter("deck_threshold", 1.0)
	# **Floor 1.0 means no shadow**, which is what a material with no deck above it should say — the gate is
	# `deck_tau > 0`, and this makes the arithmetic agree with it rather than relying on the gate alone.
	material.set_shader_parameter("deck_shadow_floor", 1.0)
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
	material.set_shader_parameter("height_map", flat_height())
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
	material.set_shader_parameter("wave_stretch", OCEAN_WAVE_STRETCH)
	material.set_shader_parameter("tone_seed", plan.seed + 5501)
	material.set_shader_parameter("tone_gain", plan.gain)
	material.set_shader_parameter("tone_lacunarity", plan.lacunarity)
	material.set_shader_parameter("tone_octaves", OCEAN_TONE_OCTAVES)
	material.set_shader_parameter("tone_variation", OCEAN_TONE_VARIATION)
	# **The sea is shadowed by the same deck as the land**, from the same uniforms — see `deck_shadow.gdshaderinc`.
	material.set_shader_parameter("deck_tau", 0.0)
	material.set_shader_parameter("deck_height", 0.0)
	material.set_shader_parameter("deck_threshold", 1.0)
	# **Floor 1.0 means no shadow**, which is what a material with no deck above it should say — the gate is
	# `deck_tau > 0`, and this makes the arithmetic agree with it rather than relying on the gate alone.
	material.set_shader_parameter("deck_shadow_floor", 1.0)
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
	material: Material, texture: Texture2D, width: int, base_frequency: float = 0.0
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
		# duplicate what the new map shows or leave a band of nothing between them. The ladder is the field's own
		# octaves, so what moves is *which octave* is the first one the map did not carry.
		#
		# **`base_frequency` arrives as an argument, not read back off the material.** Reading it back was a crash
		# in flight: the ocean material has no `detail_base_frequency` (it has no ladder), so the read returned
		# `null` and `float(null)` is *"Invalid call. Nonexistent 'float' constructor"* — once per ocean per map
		# landing, and invisible to the suite because a headless run has no surface maps at all. A caller that
		# passes 0.0 gets -1, which the shader's gate already treats as "no ladder".
		surface.set_shader_parameter("detail_first_octave", first_detail_octave(base_frequency, width))


## **Whether this body's ground is drawn as geometry.** One writer for both layers, because the land and the sea share
## a mesh: a sea left on the sphere under displaced land is a cliff along every coast.
##
## Read through `get_value` by the caller and handed here, so the switch stays hot — a setting cached at startup is a
## cold setting, and this one exists to be flipped while flying.
static func apply_displacement(material: Material, displaced: bool) -> void:
	var surface := material as ShaderMaterial
	if surface == null:
		return
	surface.set_shader_parameter("displace", 1.0 if displaced else 0.0)
	# **The exaggeration is the fiction's, and it goes with the fiction.** `relief_exaggeration` exists because a
	# smooth sphere needs a lie to read as 3D — 5.0 times the true gradient. With the vertices carrying the relief the
	# geometry *is* the shape, so shading it at 5x counts the mountain twice and reads as crumpled paper. It is
	# derived rather than tuned: the honest value with geometry is 1.0, the surface shading as steep as it is.
	#
	# `detail_relief` stays as it is — the ladder's sub-triangle bumps are still a fiction, and the geometry cannot
	# carry anything finer than the map's own texel.
	surface.set_shader_parameter(
		"relief_exaggeration",
		1.0 if displaced else RELIEF_EXAGGERATION
	)


## **The cloud deck's material** — the far regime's cloud, from the derivation and the layer's own numbers.
##
## A deck is the body's own patch mesh at `radius + height + thickness`, so **the node is the geometry and
## this is everything else**: the field's seed, the slab's two radii in the one ratio the shader needs, the
## layer's optical depth, and its colour.
##
## **The thickness is simulated, not built.** Evert, 2026-10-20: *"We can simulate the thickness by using a
## similar thing to the land textures. At any real distance from the observer this would be sufficient."* So
## the deck's geometry is one sphere at its TOP radius, which is 1.0 in model space; the base is a shading
## fact, not a surface. The shader samples the base's own crossing of the eye ray from underneath, which is
## genuine parallax of thickness rather than a fudge.
##
## `seed_layer` is the content layer's index, which is what `SpacesimCloudField.seed_for()` keys the weather
## by — so a body's decks are different clouds rather than the same one at two heights.
static func deck_material(
	body: SpacesimSceneBody,
	level: SpacesimAtmosphereModel.Condensation,
	palette: Color,
	seed_layer: int
) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = DECK_SHADER
	# **The slab's proportions, and the reason a negative altitude is fine.** A gas giant's deck base is
	# *below* its datum, because its datum is a pressure and not a floor, so `radius + height` can be smaller
	# than `radius` and there is nothing to clamp: the base is inside the planet's own reference sphere, which
	# no giant draws.
	#
	# The base's *radius* is no longer published: the deck draws one sphere at its TOP and samples the map there
	# at every altitude (2026-10-21), so nothing in the shader knows where the base is.
	material.set_shader_parameter("cover", white_texel())
	material.set_shader_parameter("veil", 1.0)
	# **The sphere the air and the occlusion are measured against.** A deck never needed it before — the node
	# is the body's own unit sphere scaled — but its light now comes from `star_transmission.gdshaderinc`,
	# which needs the body's radius to place the cloud's own horizon and to integrate the air above it.
	material.set_shader_parameter("planet_radius", body.radius)
	# **Linear, because the shader's uniform is a plain `vec3` and asks Godot to convert nothing.** The
	# authored colour is a palette value; what the deck reflects is `ramp_gain`'s business, one level up.
	material.set_shader_parameter("cloud_color", palette.srgb_to_linear())
	material.set_shader_parameter("detail_seed", SpacesimCloudField.seed_for(body.id, seed_layer))
	material.set_shader_parameter("detail_strength", DECK_DETAIL_STRENGTH)
	material.set_shader_parameter("softness", DECK_SOFTNESS)
	# **Every deck is centred on the same body, so a distance sort cannot separate the stack** — the order has
	# to be stated. The deepest composites first (lower priority is drawn earlier), leaving the highest deck
	# over the top of it, which is what a belt *is*: a thin bright deck over a browner one.
	material.render_priority = -seed_layer
	return material


## **Publish a baked map, and everything measured off it, together.**
##
## The threshold is the percentile the layer's coverage implies, `ramp_gain` is fitted to the map's own
## measured mean, and `veil` is 1 for a mapped deck. **All four arrive in one call for the same reason
## `apply_surface_maps` does**: a threshold from one bake against a gain from another is a deck whose average
## reflectance is not the calibrated albedo, and nothing would catch it.
##
## `width == 0` is the *no map* case — a body the model calls `FEATURELESS`, whose honest picture is a
## uniform veil at its coverage rather than an absent deck. That is the recipe's own rule (§3a), and it is
## why the white texel and `threshold = 0` are the material's starting state.
## **`tau_full` is the deck's OPACITY, not its lighting** — the one number that decides whether the deck is drawn
## at all. `column_tau = tau_full * thickness / mu`, `transmit = 1/(1 + column_tau)` and
## `alpha = covered * veil * (1 - transmit)`, so an unset `tau_full` is `alpha = 0` and a completely invisible
## deck. It lives here, in the one place a deck's numbers are published, because the function that used to set it
## (`apply_deck_light`) was deleted as light plumbing on 2026-10-21 and took the deck with it. **A deletion that
## claims "nothing reads this" must grep each uniform for readers, not each function.**
static func apply_cloud_map(
	material: Material, texture: Texture2D, width: int, threshold: float, ramp_gain: float,
	veil: float, tau_full: float
) -> void:
	var deck := material as ShaderMaterial
	if deck == null:
		return
	if texture != null and deck.get_shader_parameter("cover") != texture:
		deck.set_shader_parameter("cover", texture)
	if width > 0:
		# **The ladder starts at two texels of the map in hand**, so it can never duplicate what the map shows
		# and it moves as the map refines. A texel spans `TAU / width` in longitude.
		deck.set_shader_parameter("detail_feature", TAU * 2.0 / float(width))
	deck.set_shader_parameter("threshold", threshold)
	deck.set_shader_parameter("ramp_gain", ramp_gain)
	deck.set_shader_parameter("veil", veil)
	deck.set_shader_parameter("tau_full", tau_full)


## **Where the eye is in the deck's own frame** — the one number that decides whether a fragment is a cloud top,
## a cloud base, or cloud seen from the inside.
##
## `eye_offset` is the body-to-eye vector **divided by the top radius on the host, in double precision**: the
## model space of a deck node is a unit sphere, so nothing astronomical ever reaches a `float`.
##
## **The star is not passed**, and that is deliberate: the deck is lit by the engine's own light, and the
## underside's brightness is a diffuse share of the top's rather than a beam transmittance — see the shader's
## `UNDERSIDE_SHARE`. A direction uniform that nothing reads is worse than none.
static func face_deck(material: Material, eye_offset: Vector3) -> void:
	var deck := material as ShaderMaterial
	if deck == null:
		return
	deck.set_shader_parameter("eye_local", eye_offset)


## **The light a cloud base transmits, from the air's own numbers** — `Cloud Decks Plan` §D6.
##
## Everything here is derived. `beta * H` is the slab's optical depth for each species, and it is the closed form
## of the sky's own single-scatter loop: `int p(theta)*beta*exp(-h/H) dh = p(theta)*beta*H`. Because `beta` is a
## vec3, **the colour is the Rayleigh ratio** and there is no blue constant to choose.
##
## `tau_full` is the layer's own vertical optical depth, so the shader multiplies it by the thickness it samples
## and needs to know nothing about the extinction law.
##
## **And the interior's light is a Lambertian surface of the cloud's own reflectance**: `E/pi` times the
## reflectance the top is drawn at. That is the diffusion limit and it uses no new constant — a thick base is as
## bright as the cloud's albedo would make it, which is what "the multiply-scattered light" means without a
## multiple-scattering model this project does not have.
static func apply_deck_shadow(
	material: Material, texture: Texture2D, threshold: float, tau: float, height: float,
	detail_seed: int, detail_feature: float
) -> void:
	var surface := material as ShaderMaterial
	if surface == null or tau <= 0.0 or height <= 0.0:
		return
	if texture != null and surface.get_shader_parameter("deck_cover") != texture:
		surface.set_shader_parameter("deck_cover", texture)
	surface.set_shader_parameter("deck_threshold", threshold)
	surface.set_shader_parameter("deck_tau", tau)
	surface.set_shader_parameter("deck_height", height)
	# **The deck's own ladder, so the shadow is the image of the field the cloud draws** — not of the map
	# alone, which is what made it blotchy where the cloud was whispy. The seed and the first feature must be
	# the deck's exactly, or the shadow would be a different cloud from the one casting it.
	surface.set_shader_parameter("deck_detail_seed", detail_seed)
	surface.set_shader_parameter("deck_detail_feature", detail_feature)
	surface.set_shader_parameter("deck_detail_strength", DECK_DETAIL_STRENGTH)
	surface.set_shader_parameter("deck_shadow_floor", DECK_SHADOW_FLOOR)


## **Where the star is, and how wide it looks, in the body's frame** — the two numbers a surface's own light
## occlusion is made of, published per frame because both follow the body's distance to the star.
##
## `star_angle` is `asin(R_star / d)` from `SpacesimLod.angular_radius` — the same call `SpacesimStarLight`
## makes for `light_angular_distance`, so the penumbra a surface is shaded with and the softness the engine's
## own shadow would use cannot disagree. Its width also decides what a pixel can resolve: a penumbra narrower
## than one pixel is filtered to the step it averages to (`star_transmission.gdshaderinc`).
static func face_surface_star(
	material: Material, sun_model: Vector3, star_angle: float, eye_local: Vector3
) -> void:
	var surface := material as ShaderMaterial
	if surface == null:
		return
	surface.set_shader_parameter("body_sun", sun_model)
	surface.set_shader_parameter("star_angle", star_angle)
	# **The eye, in body radii, because the upward ray needs a position and not a direction** — the camera is a
	# few radii away, so the viewing angle varies across a disc, unlike the star's. It is the third number a
	# surface's light needs and the one `deck_specular_share` uses.
	surface.set_shader_parameter("body_eye_local", eye_local)


## **The air's own share of the star's light, at a material's altitude** — published once, at scene build,
## because it is derived from what the body is made of and where the layer sits, and neither changes while
## the game runs. Six uniform writes, and unlike the star's direction they never need repeating.
##
## **`air` is the same dictionary `SpacesimAtmospherePass` is fed**, so the ground and the sky over it cannot
## come to disagree about how thick the air is — which is the whole reason the derivation has one home.
##
## **The view half is deliberately absent.** The pass owns the transmittance along the eye ray; a material
## that applied it too would count the same air twice. One integral, one place each.
static func apply_air(material: Material, air: Dictionary, altitude: float) -> void:
	var surface := material as ShaderMaterial
	if surface == null:
		return
	surface.set_shader_parameter("air_rayleigh", air.get("rayleigh", Vector3.ZERO))
	surface.set_shader_parameter("air_rayleigh_height", float(air.get("rayleigh_scale_height", 0.0)))
	surface.set_shader_parameter("air_absorption", air.get("absorption", Vector3.ZERO))
	surface.set_shader_parameter("air_mie", float(air.get("mie", 0.0)))
	surface.set_shader_parameter("air_mie_height", float(air.get("mie_scale_height", 0.0)))
	surface.set_shader_parameter("air_altitude", altitude)


## **The reflectance a deck is drawn at**, so that its *average* is the calibrated albedo while its thick tops
## are as near white as the budget allows.
##
##     gain = albedo / (palette_luminance · mean)
##
## because what reaches the eye from a texel is `ALBEDO · ALPHA`, whose mean is `ramp_gain · mean(thickness)`.
## **The clamp at 1.0 is a real ceiling and not paranoia**: a low-contrast field asks for a gain above 1, which
## would be a cloud reflecting more than white. It cannot, so the gain stops and the achieved average falls
## short — and that shortfall is worth reporting rather than hiding, so `Gain` carries it.
class Gain:
	extends RefCounted

	var value := 1.0
	## How much of the calibrated albedo this deck actually reaches, 0..1. **1.0 means the budget was met**;
	## below it, the field wanted more contrast than a single reflectance can give it.
	var achieved := 1.0


static func cloud_gain(albedo: float, palette: Color, mean: float) -> Gain:
	var gain := Gain.new()
	var luminance := palette.get_luminance()
	if albedo <= 0.0 or luminance <= 0.0 or mean <= 0.0:
		gain.value = 0.0
		gain.achieved = 0.0
		return gain
	var wanted := albedo / (luminance * mean)
	gain.value = clampf(wanted, 0.0, 1.0)
	gain.achieved = gain.value / wanted
	return gain


## **A one-texel white map**, for a deck the model places but the field has nothing to bake for: a
## `FEATURELESS` body's uniform shroud, with `threshold = 0` so the whole disc is cloud.
##
## Its own texture rather than [method flat_height]'s, because that one is the neutral height and this has to
## be white — a deck's `cover` is a field, not a height.
static var _white: ImageTexture
static func white_texel() -> ImageTexture:
	if _white == null:
		var image := Image.create_empty(1, 1, false, Image.FORMAT_L8)
		image.set_pixel(0, 0, Color(1.0, 1.0, 1.0, 1.0))
		_white = ImageTexture.create_from_image(image)
	return _white
