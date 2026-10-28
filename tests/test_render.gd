extends RefCounted
## That the shader layers are wired to the derivation.
##
## **Not that they look right, and not even that they compile.** Headless Godot does not compile
## shaders at all: `load()` hands back a valid `Shader` with a syntax error sitting inside it, and
## `--import` says nothing — verified by breaking one deliberately. Compilation is checked by
## `tests/shader_check.sh`, which needs a window (`xvfb-run` counts).
##
## What is checkable here is the **wiring**, and that is worth checking on its own: every value a
## shader is handed must have come from the derivation, and a constant that should be derived must not
## be hiding in the shader.

const SOL_PATH := "res://systems/sol.tres"


func run(h, root: Node) -> void:
	print("  render layers")
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "Sol loads")
	if sol == null:
		return

	var scene := SpacesimSystemScene.from_content(sol)
	h.check(scene != null, "a scene wraps it")
	if scene == null:
		return
	scene.build(root)

	var earth := scene.body_by_id("planet:earth")
	var luna := scene.body_by_id("moon:luna")

	_test_surface_is_derived(h, earth, luna)
	_test_the_ladder_is_only_where_there_is_a_sphere(h, scene)
	_test_the_star_is_a_source(h, scene)
	_test_the_background_is_the_real_sky(h, scene)
	_test_the_phase_term_is_a_disc_average(h)
	_test_shader_defaults_are_the_hosts(h)
	_test_the_star_occludes_itself(h, scene, root)
	_test_the_sky_is_derived(h, scene, sol, earth, luna)
	_test_the_air_heights_are_derived(h, scene, sol)
	_test_the_condensation_levels(h, scene, sol)
	_test_the_temperature_profile(h, scene, sol)
	_test_the_greenhouse(h, scene)
	_test_the_air_is_drawn_only_where_its_ring_resolves(h, scene)
	_test_the_air_takes_its_share_of_the_starlight(h, scene)
	_test_hiding_a_body_hides_everything_it_draws(h, scene)

	scene.container.free()


## **F6: the detail ladder exists only where there is a sphere to put it on.**
##
## The predicate is [[SpaceSim/Levels of Detail|Levels of Detail]] §4's table — *does this body draw a reference
## sphere?* — and the content already encodes it: a gas giant's datum is a reference **pressure**, so it carries no
## `surface` register, and a star's photosphere is its disc, drawn by the star's own shader. Both used to be handed
## the full eight-rung ladder, which meant noise evaluated on every pixel of a body whose visible face is a deck.
##
## **The depth is the other half.** It is a ceiling now, not a count: the shader derives the rungs from the pixel
## (`ceil(log2(feature/footprint))`, clamped), so this number decides how deep the ladder *can* go, and a ground
## filling the frame is the only thing that reaches it. Eighteen rungs reach ~2 m on the 720p default's 512-wide
## map, where a 1 km descent asks for 17; the constant it replaced, eight rungs, stopped at 271 m whatever the
## altitude.
func _test_the_ladder_is_only_where_there_is_a_sphere(h, scene: SpacesimSystemScene) -> void:
	var earth := scene.body_by_id("planet:earth")
	var jupiter := scene.body_by_id("planet:jupiter")
	var sol := scene.body_by_id("star:sol")
	h.check(SpacesimBodyRenderer.draws_reference_sphere(earth.content),
		"Earth draws a reference sphere")
	h.check(SpacesimBodyRenderer.max_rungs_for(earth.content) == SpacesimBodyRenderer.DETAIL_MAX_RUNGS,
		"so its ladder is as deep as the ceiling allows (%d)" % SpacesimBodyRenderer.DETAIL_MAX_RUNGS)
	h.check(not SpacesimBodyRenderer.draws_reference_sphere(jupiter.content),
		"a gas giant does not — its datum is a reference pressure, not a surface")
	h.check(SpacesimBodyRenderer.max_rungs_for(jupiter.content) == 0,
		"so it gets no detail ladder at all")
	h.check(not SpacesimBodyRenderer.draws_reference_sphere(sol.content),
		"and a star does not either: its photosphere is its disc, drawn by its own shader")
	h.check(SpacesimBodyRenderer.max_rungs_for(sol.content) == 0, "so the surface ladder is zero for it")
	# **And the material the game actually builds carries it**, rather than the predicate being true in isolation.
	var jupiter_material := SpacesimBodyRenderer.material_for(
		jupiter, SpacesimBodyRenderer.surface_ramp([], SpacesimSurfaceMaps.linear_quantiles(), jupiter.color)
	) as ShaderMaterial
	h.check(int(jupiter_material.get_shader_parameter("detail_max_rungs")) == 0,
		"and the material Jupiter is drawn with asks for none")
	var earth_material := SpacesimBodyRenderer.material_for(
		earth, SpacesimBodyRenderer.surface_ramp([], SpacesimSurfaceMaps.linear_quantiles(), earth.color)
	) as ShaderMaterial
	h.check(int(earth_material.get_shader_parameter("detail_max_rungs")) == SpacesimBodyRenderer.DETAIL_MAX_RUNGS,
		"while Earth's asks for the full depth (%d)" % SpacesimBodyRenderer.DETAIL_MAX_RUNGS)

	# **The ladder's seam: the octave it starts at must be the first one the map did not carry.** One texel of a
	# `width`-wide map is `TAU / width` radians, and the field's octave `j` is `1 / (base * 2^j)`, so the start has
	# to land near two texels — within half an octave of it, because an octave is an integer.
	#
	# Written as `width / (2 * base)` the start was 2.65 octaves too deep, and the octaves in the gap were drawn by
	# neither the bake nor the shader, which read as ground that was too smooth. So the assertion is the seam, not
	# the formula that computes it.
	for width in [256, 512, 960, 2048, 4096]:
		var octave := SpacesimBodyRenderer.first_detail_octave(2.5, width)
		var feature := 1.0 / (2.5 * pow(2.0, float(octave)))
		var texels := feature / (TAU / float(width))
		h.check(texels >= 1.4 and texels <= 2.9,
			"at %d wide the ladder starts %.2f texels out" % [width, texels])

	# **A material with no ladder must not crash the map landing.** The ocean has no `detail_base_frequency` and
	# no ladder, and reading the parameter back off the material to derive the octave returned `null` — which in
	# GDScript is *"Invalid call. Nonexistent 'float' constructor"*, once per ocean per map, in flight only. The
	# headless suite never saw it because a headless run has no surface maps at all, so this calls the function
	# the way a landing does, with a material that has no ladder parameters.
	var bare := ShaderMaterial.new()
	SpacesimBodyRenderer.apply_surface_maps(
		bare, ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RF)), 512
	)
	h.check(int(bare.get_shader_parameter("detail_first_octave")) == -1,
		"and a material with no ladder is told to draw none, not made to throw")


## **The background is the real sky, and it must not become the light.**
##
## Both halves matter. The sky replaced a flat look-value colour that the exposure multiplier turned
## bright blue at outer-system distances (measured 0.655, 0.733, 0.890 at Saturn), and it is drawn
## from the real catalogue rather than generated — which is the whole point of a calibration fixture.
##
## The ambient half is the one that would fail silently: Godot's default ambient source IS the
## background, so wiring a sky quietly changes how every body is lit. Here that is deliberate
## (Evert, 2026-10-14: *"The sky should be the ambient light source"*), which is why it is asserted
## rather than left to whoever notices the night side looking different.
func _test_the_background_is_the_real_sky(h, scene: SpacesimSystemScene) -> void:
	var environment := scene.environment
	h.check(environment != null, "the scene built an environment")
	if environment == null:
		return
	h.check(environment.background_mode == Environment.BG_SKY,
		"the background is a sky, not a flat colour")
	h.check(environment.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR,
		"and the ambient is the star field's own light, summed from the catalogue — the sky is still the "
			+ "source, it is no longer asked to travel through a radiance cubemap to say so")

	var sky := scene.star_sky
	h.check(sky != null, "with a star sky behind it")
	if sky == null:
		return
	h.check(sky.catalogue != null and sky.catalogue.count > 100000,
		"loaded from the real catalogue (%d stars)" % (sky.catalogue.count if sky.catalogue else 0))
	var material := sky.material
	h.check(material != null and material.shader != null, "with a material")
	if material == null or material.shader == null:
		return
	var code := material.shader.code
	h.check(code.contains("shader_type sky"),
		"of the sky kind, so EYEDIR is a world direction and no mesh has to be centred on the camera")
	# The shader is an INPUT: it reports radiance, and the exposure decides what is seen. If it ever
	# grows a tone curve of its own it has become display referred, which is what made every earlier
	# star field unable to respond to a varying EV.
	#
	# Checked as `aces(` and not as `aces`: the first version of this matched the bare word, which is
	# inside "Spacesim" and "surfaces", so it failed for a reason that had nothing to do with tone
	# curves. A substring scan over source is blunt enough that it needs to be aimed.
	h.check(not code.contains("aces(") and not code.contains("0.4545"),
		"and returns linear HDR: no tone curve in the shader, or the exposure cannot reach it")
	h.check(code.contains("UNIT_LUX_PER_SR"),
		"converted into the engine's units, which is a unit conversion and not a gain")

	# **The pixel's size is measured in the shader, not sent from the host.** Godot draws a sky as a
	# fullscreen triangle whose vertices ARE the NDC corners, so NDC is affine in the fragment
	# coordinate and the screen-space derivative is exactly one pixel, at whatever resolution the 3D
	# is drawn at. The host alternative is `Viewport.get_visible_rect()`, which is the CANVAS rect —
	# right only while the render resolution's height equals the canvas's, and wrong by its SQUARE at
	# every other. A wrong solid angle is a wrong star brightness and a wrong half-pixel is a star in
	# the wrong pixel, and neither announces itself. Both halves are checked, because either one alone
	# would look perfectly reasonable in a diff.
	# **The shader's per-cell loop bound must cover the worst cell in the catalogue, or the stars in the
	# densest cell are silently dropped.** The build tool prints the number it wrote to ("stars a cell:
	# median .., 99th .., worst ..") and this reads it back from the asset — the same kind of
	# cross-language constant as `cell_of`, which the tool already guards, and worth a check for the same
	# reason: a grid change moves the worst cell and nothing else would notice.
	var bound := 0
	var declaration := RegEx.new()
	declaration.compile("MAX_PER_CELL\\s*=\\s*([0-9]+)")
	var found := declaration.search(code)
	if found != null:
		bound = int(found.get_string(1))
	h.check(bound > 0, "the shader declares a per-cell loop bound (%d)" % bound)
	var cell_image: Image = sky.catalogue.cells_texture.get_image()
	var worst_cell := 0
	var empty_cells := 0
	for i in sky.catalogue.cell_count:
		var held := int(cell_image.get_pixel(i % cell_image.get_width(), i / cell_image.get_width()).g)
		worst_cell = maxi(worst_cell, held)
		if held == 0:
			empty_cells += 1
	h.check(bound >= worst_cell,
		"and it covers the catalogue's worst cell, so the bound drops no star (bound %d, worst %d, "
			% [bound, worst_cell]
			+ "%d cells empty of %d)" % [empty_cells, sky.catalogue.cell_count])

	h.check(code.contains("dFdx") and code.contains("dFdy"),
		"and MEASURES its own pixel size, so the star's solid angle cannot be a square law in disguise")
	h.check(not code.contains("u_inv_viewport"),
		"with no viewport size handed in for the shader and the host to disagree about")

	# The depth tunable must reach the shader, since sweeping it is how the sky gets iterated on.
	sky.set_limit_magnitude(7.25)
	h.check_near(material.get_shader_parameter("u_limit_mag"), 7.25,
		"and the depth tunable is a uniform, so it costs a write rather than a rebuild", 1e-6)

	# The whole naked-eye sky is 2e-4 lux, which is the measured figure the calibration was checked
	# against -- so this is the calibration asserted, not a shape assertion.
	# GDScript's `%` has no `%e` (a runtime error, not a formatting surprise), so the number is scaled
	# into units and printed with `%f`, which is the documented workaround.
	var naked_eye := sky.illuminance(6.5)
	h.check(naked_eye > 1.5e-4 and naked_eye < 2.7e-4,
		"and the naked-eye sky it holds comes to %.3f e-4 lux against a measured 2.0e-4"
			% (naked_eye * 1e4))


## **The phase term is a disc average, not a clamped cosine.**
##
## Three points of the Lambert phase function are fixed rather than fitted, and the fourth is the
## regression: the clamped cosine it replaced returned **exactly zero** for every body past the half
## moon, so a crescent filling the frame contributed nothing anywhere its brightness was asked for. The
## exposure's own sum over the view is gone — `SpacesimExposurePass` meters the frame — and
## `SpacesimLuminance.disc_luminance`, which colours the point of light, is what still asks.
func _test_the_phase_term_is_a_disc_average(h) -> void:
	h.check_near(SpacesimSurfaceModel.lambert_phase(0.0), 1.0,
		"a fully lit disc reflects all of it", 1.0e-6)
	h.check_near(SpacesimSurfaceModel.lambert_phase(PI * 0.5), 1.0 / PI,
		"a half moon is 1/pi of a full one", 1.0e-6)
	h.check_near(SpacesimSurfaceModel.lambert_phase(PI), 0.0, "and a new one none", 1.0e-6)
	var crescent := SpacesimSurfaceModel.lambert_phase(deg_to_rad(122.0))
	h.check(crescent > 0.09 and crescent < 0.11,
		"while a crescent is a tenth of the disc and not zero (%.3f at 122 degrees)" % crescent)

## A star emits; it does not reflect. Drawn with the ordinary surface material it was lit by its own
## light — which travels from the star toward the observer, so its near face was back-lit and came out
## black — and it could not bloom, because nothing about it was above the glow threshold.
func _test_the_star_is_a_source(h, scene: SpacesimSystemScene) -> void:
	var sun := scene.body_by_id("star:sol")
	var material: ShaderMaterial = sun.mesh.material_override
	h.check(material != null and material.shader != null, "the star has a material of its own")
	if material == null:
		return
	h.check(material.shader.code.contains("unshaded"), "which is unshaded, so its own light cannot darken it")
	h.check(float(material.get_shader_parameter("intensity")) > 1.0,
		"and emissive well past the glow threshold, so it blooms")
	var color: Color = material.get_shader_parameter("star_color")
	h.check(color.r >= color.g and color.g >= color.b,
		"with the Sun's colour: warm white (%.3f, %.3f, %.3f)" % [color.r, color.g, color.b])


func _test_surface_is_derived(h, earth: SpacesimSceneBody, luna: SpacesimSceneBody) -> void:
	var material: ShaderMaterial = earth.mesh.material_override
	h.check(material != null and material.shader != null, "the surface carries a shader material")
	if material == null:
		return

	# **A height field and a colour ramp**, and every number off the derivation. **One material serves both the
	# `flat` and the `rendered` mode**, so `base_color` is not gone — it is the flat mode's knob, and the shader
	# short-circuits every texture read to it. So the check is that the knob holds the *derived* albedo: a flat
	# mode that fell back to a constant grey would be the old Lambertian back by the side door.
	h.check(material.get_shader_parameter("base_color") == earth.color,
		"the flat mode's colour is the body's derived albedo, not a constant")
	h.check(material.get_shader_parameter("planet_radius") == earth.radius,
		"the shader is told the body's radius, which is what turns a texel into a slope")
	var plan := SpacesimSurfaceField.plan(earth.content.id, earth.radius)
	h.check_near(float(material.get_shader_parameter("field_amplitude")), plan.amplitude,
		"and the relief amplitude the plan derives (%.0f m)" % plan.amplitude, 1.0)
	h.check(material.get_shader_parameter("height_map") != null,
		"with a neutral height until a bake lands")
	# **One map, not two.** The surface shader draws from the refining map only: a second, fixed-resolution
	# texture in it is a second resolution to keep in step with the picture, and the version that had one drew
	# a planet at 39 km texels from low orbit.
	h.check(material.get_shader_parameter("coarse_map") == null,
		"and no second, fixed-resolution map for the colour to fall back to")

	# **The ramp is the derivation's picture**: its bottom is Earth's sea band and its top is its land, in
	# the order `bands()` put them.
	var ramp: ImageTexture = material.get_shader_parameter("colour_ramp")
	h.check(ramp != null, "and a colour ramp built from the derived bands")
	if ramp != null:
		var image := ramp.get_image()
		var sea := image.get_pixel(0, 0)
		var land := image.get_pixel(image.get_width() - 1, 0)
		h.check(sea.b > sea.r, "whose bottom is water: blue-dominant (%.3f, %.3f)" % [sea.r, sea.b])
		h.check(land.g > land.b, "and whose top is vegetation: green above blue (%.3f, %.3f)" % [land.g, land.b])
		# **The luminance is the material's albedo**, which is the correction the bands carry — the authored
		# palette is 2.3-3.4x brighter than the reflectance it claims.
		h.check(sea.get_luminance() < 0.12,
			"with the sea at its own darker reflectance (%.3f)" % sea.get_luminance())

	# **There is ONE surface layer, and it draws the whole sphere.** The sea's layer is gone (2026-10-28): a liquid is
	# a level, and the layer that drew it was a second material over the same triangles, which the plateau could afford
	# only because both were unit spheres. So the cull that made the two halves complementary has to be gone with it —
	# left in, Earth's 71 % of water would be a hole showing the far side, and nothing headless would report it.
	# **Checked against the source**, because a `discard` is a shader fact no material can show.
	var surface_source := FileAccess.get_file_as_string(
		"res://addons/spacesim/render/body_surface.gdshader"
	)
	h.check(not surface_source.contains("discard"),
		"with no sea layer, the ground is drawn everywhere — there is no cull left in it")
	h.check(not surface_source.contains("has_ocean"),
		"and no switch that could turn the cull back on")

	# **An airless body gets its own ramp rather than a shared one** — one band, one colour, end to end.
	var luna_material: ShaderMaterial = luna.mesh.material_override
	var luna_ramp: ImageTexture = luna_material.get_shader_parameter("colour_ramp")
	h.check(luna_ramp != null and luna_ramp != ramp, "an airless body has a ramp of its own")
	if luna_ramp != null:
		var image := luna_ramp.get_image()
		var first := image.get_pixel(0, 0)
		var last := image.get_pixel(image.get_width() - 1, 0)
		h.check(first.is_equal_approx(last),
			"and being one material, it is one colour from the bottom to the top")
	# **And there is no per-body sweep of the cull, because there is no cull**: an airless body's lowest ground is
	# drawn like its highest, by the same line that draws Earth's sea bed.


## The sky: that the shader's inputs are the derivation's, and that the derivation agrees with
## measured air.
##
## **The coefficients are checked against a published Earth value**, the same way the albedos are
## checked against measured Bond albedos. It is a consistency check, not a fit: if a cross-section in
## the material table is wrong, this goes red by naming the number.
func _test_the_sky_is_derived(
	h,
	scene: SpacesimSystemScene,
	sol: SpacesimSolarSystem,
	earth: SpacesimSceneBody,
	luna: SpacesimSceneBody
) -> void:
	var materials := SpacesimMaterialTable.engine_table()

	# **The air's height is derived, and nothing draws it.** The shell that used to be built at this radius
	# is gone; what survives is the arithmetic, because the camera's far plane reads it and it is a fact
	# about the body rather than about a renderer.
	h.check(luna.sky_top == 0.0, "Luna has no air — content gives it none, so it has no height")
	h.check(earth.sky_top > 0.0, "Earth has one")
	if earth.sky_top <= 0.0:
		return
	# Earth's ten scale heights come to ~84 km, *under* the frame's 100 km floor, so the floor wins --
	# which is the rule that stops the air being shorter than the atmosphere the game puts you in.
	h.check(SpacesimAtmosphereModel.shell_reach(
		earth.content.atmosphere, materials, 288.15,
		SpacesimAtmosphereModel.surface_gravity(earth.content)) < sol.framing.atmosphere_altitude,
		"Earth's derived reach is under the frame's floor, so the floor is what is used (%.0f km)"
			% (earth.sky_top / 1000.0))
	h.check_near(earth.sky_top, sol.framing.atmosphere_altitude,
		"and the derived height IS the frame's floor", 1.0)

	# **The single-scattering albedo, and the visible absorption behind it.** `w = scattering /
	# (scattering + absorption)` decides whether a thick air reflects like a mirror or dims like a filter,
	# and it is the whole basis of the two-stream limit (`k = sqrt(3(1-w)(1-wg))`, zero when `w` is one).
	# **Earth's air is the only one carrying a measured absorber today — ozone** — and the check on it is
	# the effect rather than the value: a 300 DU ozone column absorbs about 2.6% of 550 nm light, which is
	# a published figure, so landing on it is what says the cross-section and the column are both right.
	var absorption := SpacesimAtmosphereModel.absorption_coefficient(
		earth.content.atmosphere, materials, 288.15
	)
	var albedo := SpacesimAtmosphereModel.single_scatter_albedo(
		earth.content.atmosphere, materials, 288.15
	)
	var air_height := SpacesimAtmosphereModel.scale_height(
		earth.content.atmosphere, materials, 288.15,
		SpacesimAtmosphereModel.surface_gravity(earth.content)
	)
	h.check(absorption.length_squared() > 0.0,
		"Earth's air absorbs visible light, because the ozone species carries measured cross-sections")
	h.check_near(absorption.y * air_height, 0.026,
		"and a 300 DU ozone column comes to %.2f%% absorbed at 550 nm"
			% (absorption.y * air_height * 100.0), 0.004)
	h.check(absorption.y > absorption.x and absorption.x > absorption.z,
		"with the Chappuis band's own shape: strongest in green, then red, and barely anything in blue")
	for channel in 3:
		h.check(albedo[channel] < 1.0,
			"so the air is no longer a conservative scatterer in channel %d (w = %.5f)"
				% [channel, albedo[channel]])
	h.check(albedo.y < albedo.x and albedo.x < albedo.z,
		"and the albedo follows it — green loses most of what it removes, blue almost nothing")

	# The mix, at a temperature we can check by hand. Earth's air is 78% nitrogen, 21% oxygen.
	var reference := SpacesimAtmosphereModel.rayleigh_coefficient(
		earth.content.atmosphere, materials, 288.15
	)
	# A coefficient is per **channel**, so a Vector3's components are red, green and blue.
	var red := reference.x
	var green := reference.y
	var blue := reference.z
	# GDScript's `%` has no `%e`, so the numbers are scaled into micro-units and printed as floats.
	h.check(blue > green and green > red,
		"blue scatters most — which is the whole reason the sky is blue (%.2f, %.2f, %.2f) e-06"
			% [red * 1.0e6, green * 1.0e6, blue * 1.0e6])
	# 5.5e-6 and 13.0e-6 are glsl-atmosphere's Earth-like values for red and green.
	h.check(absf(red / 5.5e-6 - 1.0) < 0.25,
		"and the red channel lands on the published value (%.2f against 5.50 e-06)" % (red * 1.0e6))
	h.check(absf(green / 13.0e-6 - 1.0) < 0.25,
		"as does green (%.2f against 13.00 e-06)" % (green * 1.0e6))
	h.check(reference.length_squared() > 0.0, "and the air scatters at all")

	# Scale height: kT/(m-bar g), against the model doc's ~8.5 km for Earth.
	var gravity := SpacesimAtmosphereModel.surface_gravity(earth.content)
	h.check_near(gravity, 9.81, "Earth's surface gravity from its authored mass", 0.05)
	var height := SpacesimAtmosphereModel.scale_height(
		earth.content.atmosphere, materials, 288.15, gravity
	)
	h.check(absf(height / 8500.0 - 1.0) < 0.1,
		"and a scale height of %.0f m against the model's 8.5 km" % height)

	# The temperature the coefficients are actually evaluated at, and the greenhouse-sized gap in it.
	var luminosity := SpacesimStarModel.luminosity(scene.star().content)
	var sun := scene.star()
	var earth_teq := SpacesimAtmosphereModel.equilibrium_temperature(
		earth.content, materials, luminosity, earth.position.distance_to(sun.position)
	)
	h.check(absf(earth_teq - 255.0) < 10.0,
		"Earth's equilibrium temperature is %.0f K against the published 255 K" % earth_teq)
	var venus := scene.body_by_id("planet:venus")
	var venus_teq := SpacesimAtmosphereModel.equilibrium_temperature(
		venus.content, materials, luminosity, venus.position.distance_to(sun.position)
	)
	h.check(absf(venus_teq - 229.0) < 10.0,
		"and Venus's is %.0f K against 232 K — the greenhouse is what is missing, not the geometry"
			% venus_teq)

	# **The far plane has to reach the sky, and the sky is further than it looks.** The air is a thin
	# skin — 100 km over a 6,371 km planet — so the distance out to it is ~100 km straight up and
	# ~1,130 km at the horizon, `camera.range_surface` defaulted to 200 km, and the sky was drawn above
	# 29 degrees of elevation with a black ring below. **And the longest ray is not the horizontal one**:
	# the ray that grazes the planet's limb and then climbs out reaches a horizon distance further.
	var surface_frame := scene.frame_tree.frame_by_id("planet:earth/surface")
	var reach := scene.sky_reach(surface_frame)
	h.check(absf(reach - 1.603e6) < 2.0e3,
		"the sky reaches %.0f km from Earth's surface, grazing the limb on the way" % (reach / 1000.0))
	h.check(scene.sky_reach(scene.frame_tree.frame_by_id("planet:earth/atmosphere")) == reach,
		"and the same from inside its atmosphere frame")
	h.check(scene.sky_reach(scene.system_frame) == 0.0, "while in space there is no sky to reach")
	h.check(scene.air_body(surface_frame) == earth, "and the surface frame is inside Earth's air")
	h.check(scene.air_body(scene.system_frame) == null, "as the system frame is not")

	# **A named gap, not a silent one**, and the list below is the statement of it: water vapour and ammonia
	# are the two species the authored atmospheres use that carry no Rayleigh cross-section in
	# `materials.tres`, so 0.7 % of Jupiter's air and 0.1 % of Saturn's contributes to neither the sky nor
	# the air column.
	#
	# **Hydrogen was the third until 2026-10-16**, when it was given a cross-section; the gap then grew in a
	# different direction as the giants were given their real mixes, which brought ammonia and water vapour
	# in. **Named rather than invented**: a cross-section is a measured quantity, so the honest state is "the
	# giants' rain is missing", not a guessed number. Two sentences used to sit in this block, one before
	# hydrogen landed and one after, contradicting each other with the stale one first.
	var uncovered: Array[String] = []
	for body in scene.bodies:
		if body.content == null or body.content.atmosphere == null:
			continue
		if SpacesimAtmosphereModel.coverage(body.content.atmosphere, materials) < 1.0:
			uncovered.append(body.name)
	h.check(uncovered == ["Earth", "Jupiter", "Saturn"],
		"and the air short of a cross-section is water vapour and ammonia: %s" % [uncovered])


## The four giants have no surface to stand on, but they do have air -- and the air is most of what
## you see. **Their "surface" is the 1-bar level, which is a convention and not a boundary:** there is
## no liquid to land on, because hydrogen is supercritical above 33 K at 13 bar and every giant's 1-bar
## level is far above that. The radius is already the 1-bar radius, so the shell sits above it.
func _test_the_air_heights_are_derived(
	h, scene: SpacesimSystemScene, sol: SpacesimSolarSystem
) -> void:
	var materials := SpacesimMaterialTable.engine_table()
	var top := sol.framing.atmosphere_altitude
	# Ten scale heights of the *measured* 1-bar temperature. Equilibrium temperature would be ~101 K
	# for Jupiter against a measured 165, because a giant radiates more than it receives -- so the
	# temperature is pinned in content and this is the check that the pin is read.
	# Every air body, against the values the code produces today. They are derived from authored
	# content, so they should be stable -- and if a cross-section or a temperature changes, this is
	# what should go red and say so.
	# **Jupiter did, 2026-10-16: 227 km -> 218 km.** Its real mix arrived (ammonia and water vapour,
	# 17 and 18 g/mol in a hydrogen atmosphere), which raised the mean molar mass from 2.314 to 2.430 and
	# shortened the scale height. The pinned 165 K pulls the other way and does not win.
	for entry in [
		{"id": "planet:venus", "reach": 159.0, "covered": 1.0},
		{"id": "planet:earth", "reach": 100.0, "covered": 0.99},
		{"id": "planet:mars", "covered": 1.0, "reach": 114.0}, {"id": "moon:triton", "covered": 1.0, "reach": 158.0},
		{"id": "moon:titan", "covered": 1.0, "reach": 215.0}, {"id": "planet:neptune", "covered": 1.0, "reach": 207.0},
		{"id": "planet:jupiter", "covered": 0.993, "reach": 218.0}, {"id": "planet:uranus", "covered": 1.0, "reach": 275.0},
		{"id": "planet:saturn", "covered": 0.999, "reach": 501.0},
	]:
		var body := scene.body_by_id(String(entry["id"]))
		h.check(body != null and body.sky_top > 0.0, "%s has air, so it has a height" % entry["id"])
		if body == null or body.sky_top <= 0.0:
			continue
		h.check(absf(body.sky_top - float(entry["reach"]) * 1000.0) < 6000.0,
			"reaching %.0f km, ten scale heights of its reference temperature (floor %.0f km)"
				% [body.sky_top / 1000.0, top / 1000.0])
		# Every species but Earth's water vapour: **hydrogen was the gap for the giants**, and it is
		# why Titan stopped being listed as short too.
		var covered := SpacesimAtmosphereModel.coverage(body.content.atmosphere, materials)
		h.check(absf(covered - float(entry["covered"])) < 1.0e-3,
			"%s: %.3f of its air has a cross-section" % [entry["id"], covered])
	# Hydrogen is the reason those are covered at all, and it is checked against helium: the two
	# formulations agree to four digits for helium, where a dispersion relation exists.
	var hydrogen := materials.by_name("hydrogen")
	var helium := materials.by_name("helium")
	h.check(absf(hydrogen.rayleigh.y / helium.rayleigh.y - 13.1) < 0.3,
		"hydrogen scatters %.1fx helium, matching the refractivity ratio squared"
			% (hydrogen.rayleigh.y / helium.rayleigh.y))
	# An airless body stays airless: no air block, so no height either.
	var mercury := scene.body_by_id("planet:mercury")
	h.check(mercury.sky_top == 0.0, "Mercury still has no air at all")


## **Stage A of the temperature work: the profile, not the temperature.**
##
## Nothing here changes the surface temperature -- the greenhouse is what does that. What is checked is
## that the *shape* of the air comes out right from composition and gravity alone, which is a real test
## rather than a fitted number: Earth's dry adiabatic lapse rate is a textbook 9.8 K/km and the model
## derives it from the mix's heat capacity, and Earth's cloud base lands where cloud bases are.
func _test_the_temperature_profile(h, scene: SpacesimSystemScene, sol: SpacesimSolarSystem) -> void:
	var materials := SpacesimMaterialTable.engine_table()
	var star := scene.star()
	var luminosity := SpacesimStarModel.luminosity(star.content)

	for entry in [
		{"id": "planet:earth", "lapse": 9.8, "capacity": 1005.0},
		{"id": "planet:venus", "lapse": 10.5, "capacity": 848.0},
		{"id": "planet:mars", "lapse": 4.4, "capacity": 848.0},
	]:
		var body := scene.body_by_id(String(entry["id"]))
		var air := body.content.atmosphere
		var capacity := SpacesimAtmosphereModel.heat_capacity(air, materials)
		h.check(absf(capacity / float(entry["capacity"]) - 1.0) < 0.06,
			"%s: c_p of the mix is %.0f J/(kg K), mass-weighted" % [entry["id"], capacity])
		var lapse := SpacesimAtmosphereModel.lapse_rate(
			air, materials, SpacesimAtmosphereModel.surface_gravity(body.content)
		)
		h.check(absf(lapse * 1000.0 - float(entry["lapse"])) < 0.6,
			"and g/c_p gives %.2f K/km against the textbook %.1f" % [lapse * 1000.0, entry["lapse"]])

	# **The profile's shape, and the one number that proves it is not arbitrary.** A dry adiabat is
	# right where it matters most: the height at which water in Earth's air reaches its condensation
	# temperature should be a real cloud base, 1-2 km. (The *tropopause* is 4 km low, because the
	# adiabat is dry -- named in the model and in the plan, and it is what moist convection fixes.)
	var earth := scene.body_by_id("planet:earth")
	var materials_earth := SpacesimMaterialTable.engine_table()
	# **The tropopause is the SKIN temperature of the effective (equilibrium) temperature**, not of the
	# surface: `tropopause_temperature()` takes the equilibrium, and passing it the greenhouse-adjusted
	# surface instead put the ceiling 28 K too warm. It is the pairing `condensation_levels` uses, so this
	# is now the same convention in both places rather than two.
	var equilibrium := SpacesimAtmosphereModel.equilibrium_temperature(
		earth.content, materials_earth,
		SpacesimStarModel.luminosity(star.content), earth.position.distance_to(star.position))
	var temperature := SpacesimAtmosphereModel.surface_temperature(
		earth.content.atmosphere, materials_earth,
		SpacesimAtmosphereModel.surface_gravity(earth.content), equilibrium)
	var tropopause := SpacesimAtmosphereModel.tropopause_temperature(equilibrium)
	var lapse := SpacesimAtmosphereModel.lapse_rate(
		earth.content.atmosphere, materials_earth,
		SpacesimAtmosphereModel.surface_gravity(earth.content))
	h.check(absf(tropopause / equilibrium - 0.8409) < 1.0e-4,
		"the tropopause is the grey skin temperature, %.1f K for an effective %.1f"
			% [tropopause, equilibrium])
	# **The profile's shape, and the check that the greenhouse landed.** Before the greenhouse this
	# surface was 256.5 K — below freezing — so water "condensed" 1.7 km *below ground*. It is now
	# above freezing and the base is where cloud bases are. **The base comes from the derivation rather
	# than being worked out here**: it was `(T - T_cond) / lapse` inline until
	# `SpacesimAtmosphereModel.condensation_levels` existed, and that is the one home for it now.
	var water := materials_earth.by_name("water_vapour")
	var base := 0.0
	for level in SpacesimAtmosphereModel.condensation_levels(
			earth.content.atmosphere, materials_earth,
			SpacesimAtmosphereModel.surface_gravity(earth.content), equilibrium, earth.content):
		if level.species == "water_vapour":
			base = level.height / 1000.0
	# **The number to compare against is the condensation temperature at Earth's own water VAPOUR
	# PRESSURE, not the 1-atm reference** — 276 K, not 373 K. `condensation_temperature` is defined as the
	# 1-atm vapour-pressure reference (water's boiling point), so comparing the surface to it would be
	# asserting that Earth's surface is hot enough to boil. What the check means is that the surface is
	# warmer than where water condenses, which is what puts the cloud base above the ground.
	var water_fraction: float = earth.content.atmosphere.species.get("water_vapour", 0.0)
	var dew_point := SpacesimAtmosphereModel.condensation_temperature_at(
		water, water_fraction, earth.content.atmosphere.surface_pressure
	)
	h.check(temperature > dew_point,
		"the surface is %.1f K, above water's %.1f K condensation point at its own partial pressure"
			% [temperature, dew_point])
	h.check(base > 0.5 and base < 3.0,
		"so water condenses %.1f km up -- a real cloud base, where there was none before" % base)
	var surface := temperature
	h.check(SpacesimAtmosphereModel.temperature_at(50.0e3, surface, lapse, tropopause)
			== tropopause,
		"above the tropopause the profile is flat, not still falling")
	h.check(SpacesimAtmosphereModel.temperature_at(0.0, surface, lapse, tropopause) == surface,
		"and at the surface it is the surface temperature")


## **Stage B: the greenhouse, and the measured surface temperatures it reproduces.**
##
## This is §3.6's hardest test. Each of the three absorbers is fixed against one measured surface
## temperature, and the point of the table below is that the *other* two bodies come out right with
## nothing tuned for them — Mars and Triton are untouched checks, and Triton is transparent to a
## rounding error, which is what an airless body should be.
func _test_the_greenhouse(h, scene: SpacesimSystemScene) -> void:
	var materials := SpacesimMaterialTable.engine_table()
	var star := scene.star()
	var luminosity := SpacesimStarModel.luminosity(star.content)

	for entry in [
		{"id": "planet:earth", "tau": 0.857, "surface": 288.0, "measured": 288.0},
		{"id": "planet:venus", "tau": 141.6, "surface": 737.0, "measured": 737.0},
		{"id": "moon:titan", "tau": 0.693, "surface": 94.0, "measured": 94.0},
		{"id": "planet:mars", "tau": 0.022, "surface": 212.9, "measured": 210.0},
		# Triton is the airless-shaped check: the profile is there, the greenhouse is zero.
		{"id": "moon:triton", "tau": 0.0, "surface": 41.5, "measured": 38.0},
	]:
		var body := scene.body_by_id(String(entry["id"]))
		var air := body.content.atmosphere
		var gravity := SpacesimAtmosphereModel.surface_gravity(body.content)
		# **At the mean orbital distance**, because the measured figure being compared against is a
		# mean. The model itself is given the body's *actual* position by the scene, so the derived
		# temperature moves with the orbit — which is a season, and it is checked a little lower down.
		# **A moon's orbit is relative to its planet**, so its own semi-major axis says nothing about how
		# far it is from the star — Titan's would have put it 2,889 K. The mean distance is the parent's
		# orbit; only a body orbiting the star uses its own.
		var mean := body.content.orbit.semi_major_axis
		var parent := scene.body_by_id(body.content.parent_id)
		if parent != null and parent.kind != "star":
			mean = parent.content.orbit.semi_major_axis
		if mean <= 0.0:
			mean = body.position.distance_to(star.position)
		var equilibrium := SpacesimAtmosphereModel.equilibrium_temperature(
			body.content, materials, luminosity, mean)
		var depth := SpacesimAtmosphereModel.greenhouse_optical_depth(air, materials, gravity)
		h.check(absf(depth - float(entry["tau"])) < 0.5,
			"%s: the column's infrared optical depth is %.3f" % [entry["id"], depth])
		var surface := SpacesimAtmosphereModel.surface_temperature(air, materials, gravity, equilibrium)
		h.check(absf(surface - float(entry["measured"])) < 4.0,
			"its surface comes out %.1f K against a measured %.0f, from %.1f K of insolation alone"
				% [surface, entry["measured"], equilibrium])

	# **A season, and it is free.** The insolation is a function of `t`, so a body on an eccentric orbit
	# is warmer nearer its star — Earth by a couple of kelvin, Mars by about twelve. Nothing models this;
	# it falls out of evaluating the orbit at the current time, which is what §4 asks for.
	var earth := scene.body_by_id("planet:earth")
	var earth_mean := SpacesimAtmosphereModel.equilibrium_temperature(
		earth.content, materials, luminosity, earth.content.orbit.semi_major_axis)
	var near := SpacesimAtmosphereModel.equilibrium_temperature(
		earth.content, materials, luminosity, earth.content.orbit.semi_major_axis * (1.0 - 0.0167))
	var far := SpacesimAtmosphereModel.equilibrium_temperature(
		earth.content, materials, luminosity, earth.content.orbit.semi_major_axis * (1.0 + 0.0167))
	h.check(far < near and near - far > 3.0,
		"Earth swings %.1f K between perihelion and aphelion" % (near - far))
	# And the planet's own temperature follows the orbit rather than the mean.
	var here := SpacesimAtmosphereModel.equilibrium_temperature(
		earth.content, materials, luminosity, earth.position.distance_to(star.position))
	h.check(absf(here - earth_mean) > 0.5,
		"and at the epoch it sits at %.1f K, %.1f K from its own mean" % [here, here - earth_mean])

	# **The physical checks that are not targets.** Nitrogen, oxygen, argon, helium and hydrogen are
	# transparent in the infrared, and that is why Earth is warmed by 1% water vapour rather than by the
	# nitrogen that is 78% of its air. The ordering of the absorbers is a real result too: water vapour
	# far stronger per kilogram than methane, methane than CO2.
	for transparent in ["nitrogen", "oxygen", "argon", "helium", "hydrogen"]:
		var material := materials.by_name(transparent)
		h.check(material.greenhouse.size() == 1 and material.greenhouse[0] == 0.0,
			"%s is transparent in the infrared" % transparent)
	var water := materials.by_name("water_vapour").greenhouse[0]
	var methane := materials.by_name("methane").greenhouse[0]
	var carbon := materials.by_name("carbon_dioxide").greenhouse[0]
	h.check(water > 50.0 * methane and methane > carbon,
		"and the absorbers are ordered as physics says: H2O %.5f, CH4 %.5f, CO2 %.5f"
			% [water, methane, carbon])
	h.check(absf(carbon - 0.0001397) < 1.0e-7 and absf(methane - 0.0001961) < 1.0e-7,
		"both within the range of published broadband infrared absorptivities")


## **The cloud decks are derived, and this is the measurement that says the derivation works.**
##
## The parameter is the height at which a species in the mix reaches its own `condensation_temperature`
## in the `T(h)` profile — nothing new is authored for it. What is checked is the *effect*: the two bodies
## whose real decks are known from outside the model are **Earth** (cumulus bases at 1–2 km, ~0.9 bar)
## and **Venus** (45–70 km). A third case is checked for its shape rather than its value — an ice giant's
## methane, which a well-mixed profile cannot put a level on at all.
##
## **The pressure is NOT checked against the literature, and `pressure_at` says why**: the sources publish
## a pressure level, turning a height into one is a single-exponential approximation, and it holds for a
## couple of scale heights and no further. Earth's 0.84 bar against a real ~0.9 is inside that; Venus's
## 3.5 against a real ~0.7–1 is not, and the check below says so rather than pretending otherwise.
func _test_the_condensation_levels(h, scene: SpacesimSystemScene, sol: SpacesimSolarSystem) -> void:
	var materials := SpacesimMaterialTable.engine_table()
	var star_body := scene.star()
	var luminosity := SpacesimStarModel.luminosity(star_body.content)

	# --- Earth: the cloud base, against a real one -----------------------------------------------------
	var earth := scene.body_by_id("planet:earth")
	var earth_levels := SpacesimAtmosphereModel.condensation_levels(
		earth.content.atmosphere, materials,
		SpacesimAtmosphereModel.surface_gravity(earth.content),
		SpacesimAtmosphereModel.equilibrium_temperature(
			earth.content, materials, luminosity,
			earth.position.distance_to(star_body.position)
		)
	)
	var base: SpacesimAtmosphereModel.Condensation = null
	var never := 0
	for level in earth_levels:
		if level.species == "water_vapour":
			base = level
		elif level.regime == SpacesimAtmosphereModel.Condensation.Regime.NONE:
			never += 1
	h.check(base != null, "Earth's water finds a level")
	if base == null:
		return
	h.check(base.regime == SpacesimAtmosphereModel.Condensation.Regime.LEVEL,
		"and it is a deck rather than a fog")
	h.check(base.height > 1000.0 and base.height < 2000.0,
		"at %.0f m, against real cumulus bases of 1-2 km" % base.height)
	# The real base is near 0.9 bar, so this is the pressure check the approximation does survive.
	h.check(base.pressure / 1.0e5 > 0.78 and base.pressure / 1.0e5 < 0.95,
		"and at %.2f bar against ~0.9 — a level inside a scale height, which is where the estimate holds"
			% (base.pressure / 1.0e5))
	h.check(never > 0,
		"while species that only reach their condensation point above the tropopause get no deck "
			+ "at all (%d of them)" % never)

	# --- Venus: the right level from the wrong molecule ------------------------------------------------
	var venus := scene.body_by_id("planet:venus")
	var venus_levels := SpacesimAtmosphereModel.condensation_levels(
		venus.content.atmosphere, materials,
		SpacesimAtmosphereModel.surface_gravity(venus.content),
		SpacesimAtmosphereModel.equilibrium_temperature(
			venus.content, materials, luminosity,
			venus.position.distance_to(star_body.position)
		)
	)
	var deck: SpacesimAtmosphereModel.Condensation = null
	for level in venus_levels:
		if level.regime == SpacesimAtmosphereModel.Condensation.Regime.LEVEL:
			deck = level
	h.check(deck != null, "Venus finds one too")
	if deck != null:
		# Venus's clouds are H2SO4 and its condensable here is CO2 — but the LEVEL is set by the
		# temperature profile, so the wrong molecule does not stop it landing in the right place. That
		# property is the whole reason a generator can use this.
		h.check(deck.height > 45000.0 and deck.height < 70000.0,
			"(%.0f km, inside the real deck's 45-70 km, and from CO2 rather than H2SO4)"
				% (deck.height / 1000.0))

	# --- An ice giant: a fog, not a deck ---------------------------------------------------------------
	# Uranus's methane is BELOW its condensation point all the way up the troposphere (49-57 K against
	# methane's 90.7 K), so a well-mixed model has nowhere to put a level. That is a real limitation and
	# not a bug: its 1.2 bar methane deck exists because methane is UNDERSATURATED there, and saturation
	# is not modelled.
	var uranus := scene.body_by_id("planet:uranus")
	var uranus_levels := SpacesimAtmosphereModel.condensation_levels(
		uranus.content.atmosphere, materials,
		SpacesimAtmosphereModel.surface_gravity(uranus.content),
		SpacesimAtmosphereModel.equilibrium_temperature(
			uranus.content, materials, luminosity,
			uranus.position.distance_to(star_body.position)
		)
	)
	# **Uranus's methane is a DECK, not a fog, and that is the model improving.** It condenses at 77.3 K
	# against a 76 K base, so the level sits just *below* the reference pressure — which is where the real
	# one is, at about 1.2 bar. The old `FOG` answer could only say "condensed everywhere", because the
	# profile refused to go below its own datum; now it can say where.
	var methane_level: SpacesimAtmosphereModel.Condensation = null
	for level in uranus_levels:
		if level.species == "methane":
			methane_level = level
	h.check(methane_level != null
			and methane_level.regime == SpacesimAtmosphereModel.Condensation.Regime.LEVEL,
		"an ice giant's methane is a deck just below the reference, not a fog")
	# Less than one scale height under the datum: Uranus's is 27 km, so ~20 km is 0.74 of one, which is
	# about 2.1 bar. **The real methane deck is near 1.2 bar** — so the model gets the level, the sign and
	# the order of magnitude, and is out by roughly a factor of two on the depth. That is the dry-adiabat
	# limit again, named rather than tuned away.
	h.check(methane_level != null and methane_level.height < 0.0 and methane_level.height > -30.0e3,
		"and it sits under the datum by less than a scale height (%.0f m, about 2 bar against a real 1.2)"
			% (methane_level.height if methane_level != null else 0.0))


## **Hiding a body hides everything it draws, because the key sets the body's NODE.**
##
## So the property to assert is that everything a body draws is under that node: its surface, its deck
## shells and its point of light. **Read off the scene tree rather than off `scene.meshes()`**, which
## returns `body.mesh` and nothing else — an earlier version of this test asserted "no deck shell"
## against that helper, so the decks came back and the test stayed green, which is worse than not having
## it.
func _test_hiding_a_body_hides_everything_it_draws(h, scene: SpacesimSystemScene) -> void:
	var owned := 0
	var orphaned: Array[String] = []
	for node in scene.container.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var owned_now := false
		var parent: Node = mesh.get_parent()
		while parent != null and parent != scene.container:
			for body in scene.bodies:
				if body.node == parent:
					owned_now = true
					break
			parent = parent.get_parent()
		if owned_now:
			owned += 1
		else:
			orphaned.append(mesh.name)
	h.check(owned > 0, "every body's surface, decks and point are under its own node (%d meshes)" % owned)
	h.check(orphaned.is_empty(),
		"and nothing a body draws sits outside that node, because `P` sets the node alone (%s)"
			% [orphaned])


## **How far away an atmosphere is worth drawing at all** — the air's own limb ring in pixels, not the size of
## its disc.
##
## The gate used to be "is the atmosphere bigger than a point", which let the march run out to **13.5 Gm** for
## Jupiter. At that distance the body is nine pixels across, so *every* pixel of it is a grazing chord: the
## transmittance collapses at the rim and the in-scatter peaks there, and the whole picture is a sub-pixel ring
## point sampled. Evert, flying: *"we are drawing the atmosphere from way too far away, as it changes the
## albedo"* — and with the frame meter pinned at its ceiling on an empty scene, that ring blooms.
##
## The numbers below are the ones that matter: the sunset flown at 15-18 Mm sits comfortably inside the band,
## and the 6.95 Gm view that showed the halo sits far outside it.
func _test_the_air_is_drawn_only_where_its_ring_resolves(h, scene: SpacesimSystemScene) -> void:
	var pixel := SpacesimLod.pixel_angle(70.0, 1080.0)
	h.check(pixel > 0.0, "the projection's own pixel angle is available (%.6f rad)" % pixel)
	var earth := scene.body_by_id("planet:earth")
	var jupiter := scene.body_by_id("planet:jupiter")
	h.check(earth != null and jupiter != null, "with two bodies that have air")
	if earth == null or jupiter == null:
		return
	var earth_depth: float = earth.sky_top
	var jupiter_depth: float = jupiter.sky_top

	# The flown sunset: a ring of several pixels, so the air is drawn at full strength.
	var sunset := SpacesimLod.air_ring_pixels(earth_depth, 1.6e7, pixel)
	h.check(sunset > SpacesimLod.AIR_RING_FADE.y,
		"Earth's ring at 16 Mm is %.1f px, inside the band — the sunset stays" % sunset)

	# The reported failure: a fraction of a pixel, so the air is not drawn at all.
	var far := SpacesimLod.air_ring_pixels(jupiter_depth, 6.95e9, pixel)
	h.check(far < SpacesimLod.AIR_RING_FADE.x,
		"Jupiter's ring at 6.95 Gm is %.2f px, below the band — the halo cannot be drawn" % far)

	# And the old gate's reach, for the record: where the atmosphere's *disc* was 4 px.
	var old_gate := 6.95e9
	var old_disc := SpacesimLod.screen_radius_pixels(
		SpacesimLod.angular_radius(jupiter.radius + jupiter_depth, old_gate), pixel
	)
	h.check(old_disc > SpacesimLod.POINT_TIER_SCREEN_RADIUS,
		"the old gate admitted that view, because the disc was %.1f px" % old_disc)

	# The crossover, so the band cannot drift silently: 2 px of ring on Earth is 44,000 km, not 1.25 Gm.
	var crossover := earth_depth / (SpacesimLod.AIR_RING_FADE.x * pixel)
	h.check(crossover > 3.0e7 and crossover < 7.0e7,
		"Earth's air fades in at about %.0f km, not at a million" % (crossover / 1000.0))
	h.check(SpacesimLod.air_ring_pixels(0.0, 1.0e7, pixel) == 0.0,
		"an airless body has no ring, so its air is never drawn")
	h.check(SpacesimLod.air_ring_pixels(earth_depth, 0.0, pixel) == 0.0,
		"and a degenerate distance is zero rather than a division")
	# **The call site, because a law nobody calls is decoration.** Read as source: `main.gd` owns the frame, and
	# the pass is the only thing that consumes this.
	h.check(FileAccess.get_file_as_string("res://game/main.gd").contains(
		"SpacesimLod.air_ring_pixels("),
		"and the frame gate is what uses it, so the march is not gated on a disc's size")


## **The air takes its share of the star's light on the way IN, and that share is the sunset.**
##
## The quantity is `exp(-tau)` along the star's own ray, per channel. Three things have to be true for the
## picture to be right, and none of them is visible to a headless run:
##
##   1. the air mass is ~1 overhead and diverges to a finite horizon value (the Chapman function — the
##      plane-parallel `1/cos` is unbounded there and wrong by a factor of two a few degrees above it);
##   2. **it is per channel**, which is the whole point: on Earth at the horizon blue is cut ~140x and red ~7x,
##      so the light arrives orange and dim. That is why a ridge near the terminator, and a cloud at the limb,
##      can no longer be white — Evert, 2026-10-25: *"you should never see bright spots for these clouds from
##      the far side of the planet"*;
##   3. **a point above the surface sees further past its own horizon**, `sqrt(1 - (R/(R+h))^2)` — 0 at the
##      ground, 1.2 deg at 1.4 km, 1.8 deg at 3 km. That is what keeps a cloud lit after the ground beneath it
##      has gone dark, from geometry rather than from a knob.
##
## **The law lives in `SpacesimAtmosphereModel` and the shader transcribes it**, the arrangement
## `SpacesimCloudBand` has: a closed form in a shader cannot be run headlessly, so the arithmetic is the
## model's and a source check pins the shape the shader carries.
func _test_the_air_takes_its_share_of_the_starlight(h, scene: SpacesimSystemScene) -> void:
	var earth_radius := 6.371e6
	var scale_height := 8.5e3
	# (1) The air mass: 1 overhead, sqrt(pi*R/2H) ≈ 34 at the horizon, monotone between, and it beats the
	# secant it replaced everywhere above the horizon.
	var overhead := SpacesimAtmosphereModel.air_mass(1.0, scale_height, earth_radius)
	h.check_near(overhead, 1.0, "the air mass overhead is 1 (%.4f)" % overhead, 5.0e-3)
	var horizon := SpacesimAtmosphereModel.air_mass(0.0, scale_height, earth_radius)
	h.check_near(horizon, sqrt(PI * earth_radius / (2.0 * scale_height)),
		"and at the horizon it is sqrt(pi*R/2H), the spherical answer rather than an infinity (%.1f)"
			% horizon, 1.0e-6)
	h.check(horizon > 30.0 and horizon < 40.0,
		"which is the 38 the Chapman function gives for Earth, inside 20 %% (%.1f)" % horizon)
	var last := INF
	var monotone := true
	for i in 21:
		var mu := float(i) / 20.0
		var got := SpacesimAtmosphereModel.air_mass(mu, scale_height, earth_radius)
		if got > last + 1.0e-9:
			monotone = false
		last = got
	h.check(monotone, "and it decreases all the way from the zenith to the horizon")
	h.check(SpacesimAtmosphereModel.air_mass(0.5, scale_height, earth_radius) < 2.05,
		"and at 60 degrees of zenith it is still the secant, near 2.0")

	# (2) Per channel. Earth's own derived coefficients, so this is the air the game actually draws.
	var earth := scene.body_by_id("planet:earth")
	h.check(earth != null and not earth.air.is_empty(), "Earth has an air to test")
	if earth == null or earth.air.is_empty():
		return
	var rayleigh: Vector3 = earth.air["rayleigh"]
	var absorption: Vector3 = earth.air["absorption"]
	var mie := float(earth.air["mie"])
	var rayleigh_height := float(earth.air["rayleigh_scale_height"])
	var mie_height := float(earth.air["mie_scale_height"])
	var no_air := SpacesimAtmosphereModel.sun_transmittance(
		Vector3.ZERO, 0.0, Vector3.ZERO, 0.0, 0.0, 1.0, 0.0, earth_radius
	)
	h.check(no_air.is_equal_approx(Vector3.ONE),
		"an airless body's transmittance is exactly 1, which is why the airless case needs no branch")
	# **And at the horizon, which is the case that broke.** With a zero scale height the horizon term is zero,
	# so an unlimited `1/sqrt(mu^2 + 0)` is infinity at `mu = 0` — and the caller multiplies it by a zero
	# column, `0 * inf` is NaN, and the NaN reaches `ALBEDO`. Airless bodies went supernova: Luna's whole night
	# side bloomed white with its chunks showing through. Tested at 0 and *not only overhead*, because overhead
	# is the one elevation where the broken form still returned a finite number.
	for mu in [0.0, 0.5, 1.0]:
		h.check(not is_nan(SpacesimAtmosphereModel.air_mass(mu, 0.0, earth_radius))
			and is_finite(SpacesimAtmosphereModel.air_mass(mu, 0.0, earth_radius)),
			"the air mass of an airless body is finite at mu = %.1f" % mu)
	var no_air_horizon := SpacesimAtmosphereModel.sun_transmittance(
		Vector3.ZERO, 0.0, Vector3.ZERO, 0.0, 0.0, 0.0, 0.0, earth_radius
	)
	h.check(not is_nan(no_air_horizon.x) and is_finite(no_air_horizon.x),
		"so an airless body's transmittance at its horizon is a number, not NaN (%.4f)" % no_air_horizon.x)
	h.check_near(no_air_horizon.x, 1.0, "and it is exactly 1: no air, no extinction", 1.0e-9)
	# **Luna's own coefficients**, which is the body it actually happened to.
	var luna := scene.body_by_id("moon:luna")
	if luna != null:
		h.check(luna.air.is_empty(), "Luna has no air dictionary at all")
		var luna_t := SpacesimAtmosphereModel.sun_transmittance(
			Vector3.ZERO, 0.0, Vector3.ZERO, 0.0, 0.0, 0.0, 0.0, 1737400.0
		)
		h.check(luna_t.is_equal_approx(Vector3.ONE) and not is_nan(luna_t.x),
			"and her night side is drawn in the star's own light, not in a NaN")
	var overhead_t := SpacesimAtmosphereModel.sun_transmittance(
		rayleigh, rayleigh_height, absorption, mie, mie_height, 1.0, 0.0, earth_radius
	)
	h.check(overhead_t.x > 0.85 and overhead_t.x > overhead_t.z,
		"overhead, the red survives best (%.3f red, %.3f blue)" % [overhead_t.x, overhead_t.z])
	var horizon_t := SpacesimAtmosphereModel.sun_transmittance(
		rayleigh, rayleigh_height, absorption, mie, mie_height, 0.0, 0.0, earth_radius
	)
	h.check(horizon_t.z < 0.05 * horizon_t.x,
		"and at the horizon blue is cut far harder than red, so the light is orange (%.4f vs %.4f)"
			% [horizon_t.z, horizon_t.x])
	# **The band is wide on purpose.** Its ends are what matter — not white, not black — because the absolute
	# number is the *model's* optical depth, not a textbook's: Earth's derived red column comes to ~0.12
	# against the 0.047 a 650 nm Rayleigh coefficient would give, so the sunset here is dimmer and redder than
	# the standard figure. That is a calibration question and it lives in `clear_sky_albedo`, not here; what
	# this check pins is that the picture is a sunset at all.
	h.check(horizon_t.x > 0.005 and horizon_t.x < 0.5,
		"a sunset's red is dim but present, not white and not black (%.3f)" % horizon_t.x)

	# (3) The dip. A tangent clears the ground for a point above it.
	h.check_near(SpacesimAtmosphereModel.horizon_dip(0.0, earth_radius), 0.0,
		"the ground's own horizon is the vertical one", 1.0e-9)
	var deck_dip := SpacesimAtmosphereModel.horizon_dip(1436.0, earth_radius)
	h.check_near(rad_to_deg(asin(deck_dip)), 1.2,
		"a deck at 1.4 km sees 1.2 degrees past the ground's horizon (%.2f deg)"
			% rad_to_deg(asin(deck_dip)), 0.1)
	# **The consequence, and the reason it is worth a check**: a cloud one degree above its OWN horizon is
	# still lit where the ground beside it is dark, and what it is lit by is orange.
	var cloud_t := SpacesimAtmosphereModel.sun_transmittance(
		rayleigh, rayleigh_height, absorption, mie, mie_height,
		-sin(deg_to_rad(0.2)), 1436.0, earth_radius
	)
	var ground_t := SpacesimAtmosphereModel.sun_transmittance(
		rayleigh, rayleigh_height, absorption, mie, mie_height,
		-sin(deg_to_rad(0.2)), 0.0, earth_radius
	)
	h.check(cloud_t.x > ground_t.x,
		"a lit cloud edge outlives the ground beneath it (%.4f against %.4f)"
			% [cloud_t.x, ground_t.x])

	# The shader carries the same law, and the same shape is what makes it a transcription rather than a
	# second opinion. Checked as source, because a shader cannot be run here at all.
	var code := FileAccess.get_file_as_string(
		"res://addons/spacesim/render/star_transmission.gdshaderinc"
	)
	h.check(code.contains("star_air_mass(") and code.contains("2.0 * scale_height / (PI *"),
		"the shader's air mass is the round/spherical form, not the secant")
	h.check(code.contains("max(2.0 * scale_height / (PI * max(solid_radius, 1.0)), 1.0e-12)"),
		"with its denominator floored, or an airless body's night side is 0 * inf = NaN")
	h.check(code.contains("star_air_transmittance(") and code.contains("vec3(air_mie) * mie_path"),
		"and its transmittance is per channel, with Mie through its own column")
	h.check(FileAccess.get_file_as_string(
		"res://addons/spacesim/render/body_surface.gdshader"
	).contains("star_air_transmittance(up, body_sun, air_altitude, planet_radius)"),
		"which the ground applies to the light it reflects")
	h.check(FileAccess.get_file_as_string(
		"res://addons/spacesim/render/body_deck.gdshader"
	).contains("star_air_transmittance(p, body_sun, air_altitude, planet_radius)"),
		"and so does a cloud — the limb spots were a cloud drawn in top-of-atmosphere sunlight")

	# **And on the two surfaces with a specular lobe, the transmittance is SPLIT**: its brightness goes into
	# `AO`, which the engine applies to the whole light contribution, and only its hue stays on `ALBEDO`. Scaling
	# the albedo alone left the sun's path across the water blazing at top-of-atmosphere brightness while the sea
	# around it went almost black — a specular lobe is built from the light, not from the reflectance.
	for path in ["res://addons/spacesim/render/body_surface.gdshader"]:
		var spec := FileAccess.get_file_as_string(path)
		var named := String(path).get_file()
		h.check(spec.contains("float air_brightness = dot(air_through"),
			"%s measures how much light the air left (its brightness)" % named)
		h.check(spec.contains("ALBEDO *= air_through / max(air_brightness, 1.0e-3);"),
			"and keeps only the HUE on the reflectance, at unit brightness")
		h.check(spec.contains("AO *= air_brightness;"),
			"with the brightness on the light itself, so the specular loses it too")
		# **And a highlight behind a cloud owes a BEAM's transmittance, not the diffuse one the composite applies.**
		h.check(spec.contains("SPECULAR *= deck_specular_share("),
			"%s dims a specular highlight by the deck's beam transmittance, not its diffuse one" % named)
	h.check(FileAccess.get_file_as_string(
		"res://addons/spacesim/render/deck_shadow.gdshaderinc"
	).contains("return exp(-x) * (1.0 + x);"),
		"the share is exp(-x)*(1+x): the ratio of a beam's to a diffuse transmittance, and never above 1")


## **A body occludes itself, and the surface has to be told so.**
##
## A surface's `NORMAL` is a shading *fiction*: `body_surface.gdshader` tilts it by the ground's own relief so a
## planet shades like terrain instead of like a billiard ball. A tilted normal faces the star from **past the
## geometric terminator**, so a ridge that should be in darkness is drawn lit — thin bright outlines tracing every
## coastline in the planet's dark half. Two flights have reported it, and `relief_exaggeration` 12 -> 5 with a 19°
## clamp only narrowed it: **a clamp bounds how far a normal may lean and says nothing about where the star is.**
##
## So the light is zeroed where the geometry says the star is below the horizon, through `AO` with
## `AO_LIGHT_AFFECT = 1.0` — which is the engine's direct-light occlusion, exactly a shadow, and needs no BRDF of
## our own. Headless cannot draw it and `tests/shader_check.sh` only proves it compiles, so what is pinned here is
## the wiring that would fail **silently**: the law is in both surface materials, and **every** drawn body is told
## where the star is and how wide it looks.
##
## **The body is chosen for having no deck, and that is the point of the check.** The publish used to live inside
## the deck's own per-frame function, after its `decks.is_empty()` early return, so an airless body kept the
## uniform's default `Vector3.UP` — a northern sun on every terminator in the system, and nothing would have said
## so.
func _test_the_star_occludes_itself(h, scene: SpacesimSystemScene, root: Node) -> void:
	for path in ["res://addons/spacesim/render/body_surface.gdshader"]:
		var shader: Shader = load(path)
		var named := String(path).get_file()
		if shader == null:
			h.check(false, "%s loads" % named)
			continue
		h.check(shader.code.contains("star_transmission.gdshaderinc"),
			"%s includes the star's own transmission" % named)
		h.check(shader.code.contains("AO = star_transmission("),
			"and applies it to the light, not to the normal" % [])
	h.check(
		FileAccess.get_file_as_string(
			"res://addons/spacesim/render/star_transmission.gdshaderinc"
		).contains("uniform float star_angle"),
		"the law takes the star's own angular radius, which varies 77x across Sol"
	)

	# **Luna: an airless body, so it has no deck at all** — which is the case the publish used to miss, and the
	# reason it does not live in the deck's per-frame call any more.
	var body := scene.body_by_id("moon:luna")
	h.check(body != null and body.decks.is_empty() and body.mesh_material != null,
		"the system has an airless body whose surface has to be told anyway")
	if body == null or body.mesh_material == null:
		return
	var star_body := scene.star()
	h.check(star_body != null, "with a star to be lit by")
	if star_body == null:
		return

	# **Three radii out, because the walk skips a body whose disc is under the point tier** — and a headless
	# viewport is a few tens of pixels tall, so its pixel angle is a hundred times the flying one and a distant
	# moon rounds to two pixels. This is the distance `test_cloud_decks` drives Earth from for the same reason.
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.global_position = body.node.global_position + Vector3(0.0, 0.0, body.radius * 3.0)
	camera.basis = Basis.looking_at(
		(body.node.global_position - camera.global_position).normalized(), Vector3.UP
	)
	camera.current = true
	scene.update_lod(camera, 0.016)

	var to_star: Vector3 = star_body.position - body.position
	var sun: Variant = body.mesh_material.get_shader_parameter("body_sun")
	h.check(sun is Vector3, "the body's surface is told where the star is")
	if sun is Vector3:
		# Not the uniform's default, which is what an unpublished body keeps — and which would put every
		# terminator in the system under a sun that is not there.
		h.check((sun as Vector3).dot(to_star.normalized()) > 0.999,
			"and it is the star's own direction in the body's frame (%s)" % [sun])
	# **The eye, in body radii.** The upward ray needs a position rather than a direction, because the camera is
	# a few radii away and the viewing angle varies across a disc — and it is what a specular highlight's own
	# attenuation is computed from. Unpublished it defaults to straight above, which would put every glint's
	# cloud over its own zenith.
	var eye: Variant = body.mesh_material.get_shader_parameter("body_eye_local")
	h.check(eye is Vector3, "and where the eye is, in the body's own frame")
	if eye is Vector3:
		var expected := (camera.global_position - body.node.global_position) / body.radius
		h.check_near((eye as Vector3).distance_to(expected), 0.0,
			"which is the camera's offset in body radii (%.3f)" % (eye as Vector3).length(), 1.0e-3)
	var angle: Variant = body.mesh_material.get_shader_parameter("star_angle")
	h.check(angle is float and float(angle) > 0.0,
		"with the star's angular radius, which is what sizes the penumbra (%s)" % [angle])
	if angle is float:
		h.check_near(float(angle), SpacesimLod.angular_radius(star_body.radius, to_star.length()),
			"derived from the body's distance, not fixed at one astronomical unit", 1.0e-9)
	camera.queue_free()


## **A shader uniform's default is the picture a material that missed its publish will draw**, so it has to
## move when the constant behind it moves. Every entry below has been the *superseded* value at some point,
## and three of them reproduced a fault this project has already fixed: the ocean's ramp defaulted to the
## 2 m / 40 m pair whose own comment said "every pixel of the ocean was deep", `detail_relief` defaulted to
## zero — the whole 18-rung ladder for no picture — and the sea's `wave_stretch` defaulted to 1.0, which is
## isotropic. (The sea's own five entries went with the sea on 2026-10-28; the rule is what matters.)
##
## **Checked against the source text**, because a `ShaderMaterial` whose parameter was never set returns
## `null` rather than the shader's own default: the mistake is invisible to anything that reads a material.
func _test_shader_defaults_are_the_hosts(h) -> void:
	var surface := "res://addons/spacesim/render/body_surface.gdshader"
	var pairs := [
		[surface, "detail_variation", SpacesimBodyRenderer.DETAIL_VARIATION],
		[surface, "detail_strength", SpacesimBodyRenderer.SURFACE_DETAIL_STRENGTH],
		[surface, "detail_relief", SpacesimBodyRenderer.DETAIL_RELIEF],
		[surface, "relief_exaggeration", SpacesimBodyRenderer.RELIEF_EXAGGERATION],
		[surface, "relief_max_tilt", SpacesimBodyRenderer.RELIEF_MAX_TILT],
		["res://addons/spacesim/render/body_deck.gdshader", "softness", SpacesimBodyRenderer.DECK_SOFTNESS],
	]
	for pair in pairs:
		var shader: Shader = load(pair[0])
		if shader == null:
			h.check(false, "%s loads" % String(pair[0]).get_file())
			continue
		var found: Variant = _shader_default(shader.code, String(pair[1]))
		if found == null:
			h.check(false, "%s declares %s with a default" % [String(pair[0]).get_file(), pair[1]])
			continue
		h.check_near(found, float(pair[2]),
			"%s's default is the host's value, so a material that missed a publish draws the intended "
				% pair[1] + "look (%.4f)" % found, 1.0e-6)


## `uniform <type> <name> ... = <number>;` — the declared default, or null if the name is not there.
func _shader_default(code: String, name: String) -> Variant:
	var pattern := RegEx.new()
	pattern.compile("uniform\\s+\\w+\\s+" + name + "\\b[^;]*=\\s*([-0-9.]+)\\s*;")
	var found := pattern.search(code)
	if found == null:
		return null
	return found.get_string(1).to_float()
