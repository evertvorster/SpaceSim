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


## The surface material: **a flat Lambertian at the body's derived albedo.**
##
## There is no mapping, and none is switched off: the noise field, the two-stop gradient and the relief
## normal are deleted from the shader rather than disabled in it. They were the documented cause of a
## black surface — a bump normal built from a field's gradient, and a colour blended between two stops —
## so their absence is a property of this function rather than a default anybody can turn back on.
##
## The surface mapping is a feature to be designed, with its own document, on a surface that subdivides.
static func surface_material(body: SpacesimSceneBody) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SURFACE_SHADER
	material.set_shader_parameter("base_color", body.color)
	material.set_shader_parameter("roughness_value", SURFACE_ROUGHNESS)
	material.set_shader_parameter("specular_value", SURFACE_SPECULAR)
	# **The debug tint starts off, published rather than left to the shader's default**: `get_shader_parameter` returns
	# null for a parameter nobody wrote, so a material that missed its publish would report "no tint" as missing and read
	# as an unset knob. `SpacesimSystemScene._publish_depth_tint` writes it when the setting moves.
	material.set_shader_parameter("tint_amount", 0.0)
	return material

