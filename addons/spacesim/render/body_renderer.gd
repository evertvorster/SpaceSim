class_name SpacesimBodyRenderer
extends RefCounted
## Builds what a body looks like: its surface material, and its point of light.
##
## Everything the shaders are given comes from **the derivation** — the albedo colour, the body's own
## temperature — so a shader cannot quietly disagree with the model. What is *not* derived yet is named in
## the constants below rather than buried in the shader, because a hidden constant is one nobody can find
## when the picture is wrong.
##
## **Nothing here draws the air's PIXELS.** The air is its own shell (`air_shell.gdshader`, built by
## `air_shell_material()` below): a material that applied the eye's integral beside it would draw the same air
## twice. What a material *does* apply is the air on the LIGHT's path, which is a different quantity —
## `apply_air()` below, and the one place the two meet is the `air` dictionary they are both fed.
## The cloud deck shells and the surface-texture
## mapping are all gone; the next features are built from their plans, not from these materials.
## `SpacesimClouds` stays and is still read: `bond_albedo` needs it, and Earth's calibrated 0.302 against a
## measured 0.306 depends on the deck's fraction and albedo.

const SURFACE_SHADER := preload("res://addons/spacesim/render/body_surface.gdshader")
const DECK_SHADER := preload("res://addons/spacesim/render/body_deck.gdshader")
const STAR_SHADER := preload("res://addons/spacesim/render/body_star.gdshader")
const OCEAN_SHADER := preload("res://addons/spacesim/render/body_ocean.gdshader")
const AIR_SHELL_SHADER := preload("res://addons/spacesim/render/air_shell.gdshader")
## How far past the environment's `glow_hdr_threshold` (1.0) a star sits. This is the bloom knob: a
## star at 1.0 is a bright dot, and a star is supposed to glare. **Also what a star's point of light is
## emitted at**, so the two cannot disagree.
const STAR_INTENSITY := 24.0

## **Not derived, and deliberately visible here.** Roughness and specularity are per-material
## properties the material table does not carry yet, and relief strength is a look decision. Terrain
## shape from composition is the next thing the derivation can honestly supply.
const SURFACE_ROUGHNESS := 0.9
const SURFACE_SPECULAR := 0.15

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

## **How wide the deck's coverage edge is, in field units** — the `smoothstep` around `threshold`. Published
## rather than left to the shader's own default: it was a `hint_range` uniform nobody set, which reads as a
## knob and is a constant. Named here and handed over, so the host owns it like every other look number.
const DECK_SOFTNESS := 0.05

## The wireframe view's one material — see [method wireframe_material].
static var _wireframe: StandardMaterial3D
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
static func material_for(body: SpacesimSceneBody, ramp: ImageTexture) -> Material:
	if body.content != null and body.content.kind == SpacesimSystemBody.Kind.STAR:
		return star_material(body)
	return surface_material(body, ramp)


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
			SpacesimSurfaceDistribution.value_at(quantiles, float(band["from"])),
			SpacesimSurfaceDistribution.value_at(quantiles, float(band["to"])),
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


## **Does this body draw a reference sphere?** — the predicate [[SpaceSim/Levels of Detail|Levels of Detail]] §4
## states as a table, and the question is about *drawing a sphere*, not about having "ground": a gas giant has no
## surface register because its datum is a reference **pressure**, and a star's photosphere is drawn by its own
## shader. Naming the question that is actually being answered is what stopped the last version of this (`d57eb39`
## wrote it as "has a ground", which is false for a star and hid the Sun's disc behind a marker).
static func draws_reference_sphere(content: SpacesimSystemBody) -> bool:
	return content != null and content.surface != null


## The surface material: **a height field, a colour ramp and a sea.**
##
## Everything it is given is derived: the ramp from `SpacesimSurfaceModel.bands()` and the *measured* quantiles, and
## the field's own plan — the shader evaluates `surface_height` itself, so there is no map to publish, no ladder to
## keep in step and no sea level to hand over with the heights it belongs to.
static func surface_material(
	body: SpacesimSceneBody, ramp: ImageTexture
) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SURFACE_SHADER
	material.set_shader_parameter("colour_ramp", ramp)
	material.set_shader_parameter("planet_radius", body.radius)
	var plan := SpacesimSurfaceField.plan(body.id, body.radius)
	# **The field's own numbers, and now the WHOLE plan** — the shader evaluates the field itself, so every number the
	# bake compiles has to reach it or the two are different fields. Only the fields `surface_height` reads are here;
	# a number in the struct that nothing reads would be a number nothing draws.
	material.set_shader_parameter("field_seed", plan.seed)
	material.set_shader_parameter("field_amplitude", plan.amplitude)
	material.set_shader_parameter("field_continent_frequency", plan.continent_frequency)
	material.set_shader_parameter("field_continent_octaves", plan.continent_octaves)
	material.set_shader_parameter("field_continent_share", plan.continent_share)
	material.set_shader_parameter("field_continent_bounding", plan.continent_bounding)
	material.set_shader_parameter("field_ridge_frequency", plan.ridge_frequency)
	material.set_shader_parameter("field_ridge_octaves", plan.ridge_octaves)
	material.set_shader_parameter("field_ridge_strength", plan.ridge_strength)
	material.set_shader_parameter("field_warp_frequency", plan.warp_frequency)
	material.set_shader_parameter("field_warp_octaves", plan.warp_octaves)
	material.set_shader_parameter("field_warp_strength", plan.warp_strength)
	material.set_shader_parameter("field_warp_bounding", plan.warp_bounding)
	material.set_shader_parameter("field_region_frequency", plan.region_frequency)
	material.set_shader_parameter("field_region_octaves", plan.region_octaves)
	material.set_shader_parameter("field_region_share", plan.region_share)
	material.set_shader_parameter("field_region_bounding", plan.region_bounding)
	material.set_shader_parameter("field_plate_bias_share", plan.plate_bias_share)
	material.set_shader_parameter("field_belt_width", plan.belt_width)
	material.set_shader_parameter("field_plate_phase", plan.plate_phase)
	material.set_shader_parameter("field_mottle_plain_gain", plan.mottle_plain_gain)
	material.set_shader_parameter("field_gain", plan.gain)
	material.set_shader_parameter("field_lacunarity", plan.lacunarity)
	material.set_shader_parameter("land_roughness", SURFACE_ROUGHNESS)
	material.set_shader_parameter("land_specular", SURFACE_SPECULAR)
	material.set_shader_parameter("base_color", body.color)
	# **The debug tint starts off, published rather than left to the shader's default**: `get_shader_parameter` returns
	# null for a parameter nobody wrote, so a material that missed its publish would report "no tint" as missing and read
	# as an unset knob. `SpacesimSystemScene._publish_surface_flags` writes it when the setting moves.
	material.set_shader_parameter("tint_amount", 0.0)
	# **No deck above to begin with**: `deck_tau = 0` makes the shadow path a uniform branch, which is the
	# honest state of every body without a cloud layer. `apply_deck_shadow()` is the one writer.
	material.set_shader_parameter("deck_tau", 0.0)
	material.set_shader_parameter("deck_height", 0.0)
	material.set_shader_parameter("deck_threshold", 1.0)
	# **Floor 1.0 means no shadow**, which is what a material with no deck above it should say — the gate is
	# `deck_tau > 0`, and this makes the arithmetic agree with it rather than relying on the gate alone.
	material.set_shader_parameter("deck_shadow_floor", 1.0)
	# **`flat` is the platform's own mode and not a second material**: the fragment short-circuits to the derived albedo
	# before it reads a texture, so `flat` costs no map and no ladder. Published beside the tint for the same reason.
	# **A body with no surface content gets the interior sphere and nothing else.** The mesh still exists — the
	# decks are drawn on copies of it — so this is not about geometry: it is the field, which a gas giant has no use
	# for and which had been painting terrain (and, since the vertex translation, *displacing* it) on a ball that
	# is really the top of an atmosphere.
	var has_surface := body.content != null and body.content.surface != null
	material.set_shader_parameter("has_surface", 1.0 if has_surface else 0.0)
	material.set_shader_parameter("flat_mode", 0.0)
	return material




## Whether a band entry came from a liquid material — the derivation's own answer, read off the phase it carries.
static func band_is_liquid(band: Dictionary) -> bool:
	return int(band.get("phase", -1)) == SpacesimSurfaceModel.Phase.LIQUID


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
## a single publisher does**: a threshold from one bake against a gain from another is a deck whose average
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
	# **The width with the map**, because the reconstruction needs the map's own texel — and a refinement moves both.
	deck.set_shader_parameter("cover_width", width)
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
	material: Material, texture: Texture2D, width: int, threshold: float, tau: float, height: float,
	base: float = 0.0
) -> void:
	var surface := material as ShaderMaterial
	if surface == null or tau <= 0.0 or height <= 0.0:
		return
	if texture != null and surface.get_shader_parameter("deck_cover") != texture:
		surface.set_shader_parameter("deck_cover", texture)
	# **The width comes with the map**, so the shadow reconstructs the coverage exactly as the deck does: two different
	# reconstructions of one field are two slightly different clouds, and the shadow must be the image of the cloud.
	surface.set_shader_parameter("deck_cover_width", width)
	surface.set_shader_parameter("deck_threshold", threshold)
	surface.set_shader_parameter("deck_tau", tau)
	surface.set_shader_parameter("deck_height", height)
	surface.set_shader_parameter("deck_base", base)
	surface.set_shader_parameter("deck_shadow_floor", DECK_SHADOW_FLOOR)


## **Where the star is, and how wide it looks, in the body's frame** — the two numbers a surface's own light
## occlusion is made of, published per frame because both follow the body's distance to the star.
##
## `star_angle` is `asin(R_star / d)` from `SpacesimLod.angular_radius` — the same call `SpacesimStarLight`
## makes for `light_angular_distance`, so the penumbra a surface is shaded with and the softness the engine's
## own shadow would use cannot disagree. Its width also decides what a pixel can resolve: a penumbra narrower
## than one pixel is filtered to the step it averages to (`star_transmission.gdshaderinc`).
static func face_surface_star(
	material: Material, sun_model: Vector3, star_angle: float, eye_local: Vector3, pixel_angle: float
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
	# **The pixel's own angular size**, which the surface converts into a footprint per fragment — `p / cos tilt`
	# rather than a derivative of the mesh, so the detail ladder does not move when the patching does. A deck declares
	# no such uniform and ignores it.
	surface.set_shader_parameter("pixel_angle", pixel_angle)


## **The air's own share of the star's light, at a material's altitude** — published once, at scene build,
## because it is derived from what the body is made of and where the layer sits, and neither changes while
## the game runs. Six uniform writes, and unlike the star's direction they never need repeating.
##
## **`air` is the same dictionary the shells are fed**, so the ground and the sky over it cannot come to
## disagree about how thick the air is — which is the whole reason the derivation has one home.
##
## **The view half is deliberately absent.** `air_shell.gdshader` owns the transmittance along the eye ray; a
## material that applied it too would count the same air twice. One integral, one place each.
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


## **The air's shell: one band of one body's atmosphere.**
##
## The static half of the shell's state — the optics and the band's two radii — goes in here, beside every
## other material this renderer builds. The per-frame half (the eye, the star, the rotation) is published by
## the scene, because it changes every frame and this does not.
##
## **`u_band_inner` is the surface the band stands on**, so it is `planet_radius` for the one band a body has
## today; a deck's base is where it moves to when the stack is split.
static func air_shell_material(
	air: Dictionary, planet_radius: float, band_outer: float, band_inner: float
) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = AIR_SHELL_SHADER
	material.set_shader_parameter("u_rayleigh", air.get("rayleigh", Vector3.ZERO))
	material.set_shader_parameter("u_rayleigh_h", float(air.get("rayleigh_scale_height", 1.0)))
	material.set_shader_parameter("u_absorption", air.get("absorption", Vector3.ZERO))
	material.set_shader_parameter("u_mie", float(air.get("mie", 0.0)))
	material.set_shader_parameter("u_mie_h", float(air.get("mie_scale_height", 1.0)))
	material.set_shader_parameter("u_mie_g", float(air.get("mie_anisotropy", 0.758)))
	material.set_shader_parameter("u_sun_intensity", float(air.get("sun_intensity", 0.0)))
	material.set_shader_parameter("u_planet_radius", planet_radius)
	# **Where the air starts**, which is the datum for a body with a surface and NOT for a gas giant. A giant's
	# deck bases sit below its datum (a pressure, not a floor), so the datum sphere is *inside* the clouds: a band
	# from it upward stops in mid-atmosphere and draws a hard circle at a sphere nothing can be seen on.
	# Evert, 2026-11-02, flying Saturn: *"there is something exactly on the sphere"* — this is that.
	material.set_shader_parameter("u_band_inner", band_inner)
	material.set_shader_parameter("u_band_outer", band_outer)
	return material


## **The sea's material, from the liquid's own `SpacesimSpecies`.**
##
## Nothing Earth-specific is written here: the colour, roughness and specular are the same `band_color()` and
## `band_shading()` every surface band takes, so water is glossy and methane is whatever its own material says.
## Evert, 2026-11-01: *"material and reflectivity needs to be proper for earth and different planets."*
##
## The datum is not a parameter: the sea's surface is the sphere the ground is *displaced from*, so the ocean's node
## wears the ground's own mesh at ratio 1.0 and `sea_level` (the field value) is all the shader needs to know where
## the waterline falls.
static func ocean_material(liquid: SpacesimSpecies) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = OCEAN_SHADER
	# **The sea is UNDER the cloud, so it must be drawn before every deck.** Evert, 2026-11-03, over a solid deck:
	# *"There is the reflection off of the ocean showing through the clouds… the sunlight should have been attenuated
	# and scattered twice."* It was not, because `render_priority` was left at 0 while the decks run 0 to −N: on Earth
	# the sea and the single deck **tied**, and a tie falls to the distance sort — which cannot separate two meshes at
	# the body's own origin. The sea's glint then composited straight over the deck.
	#
	# **Below every deck** (they are `-seed_layer`, so 0 and down), and still after the opaque ground, which is what
	# makes water draw over land. The double attenuation Evert describes then falls out for free: the deck's shadow
	# already takes the light on the way down (`deck_shadow.gdshaderinc`), and the deck's own alpha now takes it on
	# the way back up, because the sea is behind it.
	#
	# **`RENDER_PRIORITY_MIN` is −128**, and a priority outside that range is *refused outright*
	# (`material.cpp:71`: "Condition p_priority < RENDER_PRIORITY_MIN is true") — the material then keeps 0, which is
	# exactly the tie this line exists to break. Measured 2026-11-03: `-1000` printed that error twice per body and
	# changed no pixel. Eight is below any deck this engine can have (one per condensed species) and leaves the rest
	# of the range alone.
	const OCEAN_RENDER_PRIORITY := -8
	material.render_priority = OCEAN_RENDER_PRIORITY
	material.set_shader_parameter("ocean_color", SpacesimSurfaceModel.band_color(liquid))
	var shading := SpacesimSurfaceModel.band_shading(liquid)
	material.set_shader_parameter("ocean_roughness", shading.x)
	material.set_shader_parameter("ocean_specular", shading.y)
	return material


## **The colour the sea reflects**, from the body's own air: the Rayleigh coefficients are the sky's hue by
## derivation (1/lambda^4), so a redder sky reflects red for the same reason the sky is blue. Normalised to unit
## brightness, because the shader scales it — a reflectance, not a radiance.
static func sky_reflection_tint(air: Dictionary) -> Color:
	var rayleigh: Vector3 = air.get("rayleigh", Vector3.ZERO)
	if rayleigh.length() <= 0.0:
		return Color(0.20, 0.42, 0.90)
	return Color(rayleigh.x, rayleigh.y, rayleigh.z).srgb_to_linear() / maxf(rayleigh.length(), 1.0e-9)


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
