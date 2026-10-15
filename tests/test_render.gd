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
	_test_the_star_is_a_source(h, scene)
	_test_the_background_is_the_real_sky(h, scene)
	_test_the_exposure_follows_the_view(h, scene)
	_test_the_sky_is_derived(h, scene, sol, earth, luna)
	_test_the_air_shells_reach_the_right_height(h, scene, sol)
	_test_the_temperature_profile(h, scene, sol)
	_test_the_greenhouse(h, scene)
	_test_hiding_bodies_hides_their_air(h, scene)

	scene.container.free()


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


## **The exposure is anchored to what the eye is looking at, not to the light arriving at the
## observer.** Both faults Evert reported come from that difference and both are arithmetic, so they
## are checked here without a GPU:
##
##   * looking at Sol from Saturn's distance faded the whole sky 122x, which it must not — a point
##     source has no surface brightness to adapt to;
##   * flying close to Saturn was blown out, because nothing in the frame could affect the exposure.
##
## The instrument is `MIN_SOLID_ANGLE`, the eye's ~0.2 degree pooling scale. The Sun's disk is 0.53
## degrees at 1 au — above it, so it is a sky you adapt to — and 0.053 at Saturn, ten times below, so
## it is a glare source and no more. That is the whole fix, in one number.
func _test_the_exposure_follows_the_view(h, scene: SpacesimSystemScene) -> void:
	var sun := scene.body_by_id("star:sol")
	if sun == null or sun.node == null:
		return
	# A 37.8 degree vertical field at 16:9, which is what the game runs at.
	var tan_half := Vector2(tan(deg_to_rad(18.9)) * (16.0 / 9.0), tan(deg_to_rad(18.9)))
	var sun_position := sun.node.global_position
	var au := 1.495978707e11

	# --- empty space, far from every body --------------------------------------------------------
	# 25 au out, where the Sun is 0.021 degrees across. Nothing else is anywhere near.
	var empty := sun_position + Vector3(0.0, 0.0, 25.0 * au)
	var to_sun := (sun_position - empty).normalized()
	h.check(scene.view_luminance_at(empty, to_sun, tan_half) == 0.0,
		"25 au out the Sun is ten times under the eye's pooling scale, so it is a glare source and "
		+ "nothing more — looking at it from there leaves the sky alone, which is the bug this fixes")
	h.check(scene.view_luminance_at(empty, -to_sun, tan_half) == 0.0,
		"and looking away from it there is nothing at all, which is the dark-adapted case")

	# --- at 1 au the Sun IS a sky you adapt to ----------------------------------------------------
	# Placed 0.9 au out rather than on top of a planet, so that the body the observer would otherwise
	# be sitting on cannot be what the check is really measuring.
	var near := sun_position + Vector3(0.0, 0.0, 0.9 * au)
	var at_sun := (sun_position - near).normalized()
	var looking: float = scene.view_luminance_at(near, at_sun, tan_half)
	h.check(looking > 0.0,
		"at 1 au the Sun's disk is five times the pooling scale, so it is a sky you adapt to "
		+ "(%.1f e5 lux/sr)" % (looking * 1e-5))
	var at_one_au := SpacesimExposure.target_multiplier_for_luminance(looking)
	h.check(at_one_au < SpacesimExposure.DARK_ADAPTED_MULTIPLIER,
		"so staring at the Sun stops the exposure down to %.1f from %.0f"
			% [at_one_au, SpacesimExposure.DARK_ADAPTED_MULTIPLIER])

	# --- a planet filling the frame ---------------------------------------------------------------
	# On the SUB-SOLAR side, so it is fully lit and its phase is 1. The first version of this placed the
	# observer on the night side, which measured 0.0 — correctly — and read as a broken body term.
	var saturn := scene.body_by_id("planet:saturn")
	if saturn == null or saturn.node == null:
		return
	var toward_sun := (sun_position - saturn.node.global_position).normalized()
	var close := saturn.node.global_position + toward_sun * (saturn.radius + 4.0e5)
	var down := (saturn.node.global_position - close).normalized()
	var body: float = scene.view_luminance_at(close, down, tan_half)
	h.check(body > 0.0,
		"a lit body filling the frame is what the exposure follows now (%.1f lux/sr)" % body)
	h.check(SpacesimExposure.target_multiplier_for_luminance(body)
			< SpacesimExposure.DARK_ADAPTED_MULTIPLIER,
		"so flying close to Saturn stops the exposure down instead of blowing out")
	h.check(scene.view_luminance_at(close, -down, tan_half) == 0.0,
		"while looking away from it at the same place is empty sky again")

	# --- a source the planet is standing in front of -------------------------------------------------
	# The Sun is *in the frame* from Earth's night side whenever the camera points at the ground — which
	# it does by pointing at the planet's centre, and the Sun is behind that. Counting it as a sky you
	# adapt to stopped the exposure down 75,000x (measured) for a Sun that cannot be seen, and took the
	# whole sky with it for as long as the adaptation takes to come back.
	var earth := scene.body_by_id("planet:earth")
	if earth != null and earth.node != null:
		var earth_position: Vector3 = earth.node.global_position
		var to_sun_from_earth: Vector3 = (sun_position - earth_position).normalized()
		var night := earth_position - to_sun_from_earth * (earth.radius + 2000.0)
		# A **bound** rather than zero, and the reason is a consequence of the phase fix: a crescent Luna
		# now contributes where the clamped cosine dropped it. The Sun's own term is what this is about,
		# and without the occlusion test this value is 71,356 lux/sr — so four orders of margin, and the
		# check no longer depends on where Luna happens to be.
		var night_ground := scene.view_luminance_at(night, to_sun_from_earth, tan_half)
		h.check(night_ground < 100.0,
			"the planet hides the Sun from its night side, so looking down at the ground is not a sky "
			+ "you adapt to — a Sun that cannot be seen is not 71,356 lux/sr (%.1f)" % night_ground)
		h.check(scene.view_luminance_at(night, -to_sun_from_earth, tan_half) < 1.0,
			"and looking up at the actual night sky leaves the exposure dark-adapted")

		# The control, and it is the half that matters: with the same geometry on the **lit** side the Sun
		# is overhead and must still count. Without it, discarding the term would pass the checks above.
		var day := earth_position + to_sun_from_earth * (earth.radius + 2000.0)
		h.check(scene.view_luminance_at(day, to_sun_from_earth, tan_half) > 0.0,
			"while on the day side it is overhead and counts, as it must — occlusion is not a deleted term")

	# --- the phase function, against the values it is defined by ------------------------------------
	# Three points of the Lambert phase function are fixed rather than fitted, and the fourth is the
	# regression: the clamped cosine this replaced returned **exactly zero** for every body past the
	# half moon, so a crescent planet filling the frame was dropped from the sum and the exposure rested
	# at the dark-adapted ceiling while the lit part blew out.
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

	# The two gradient stops come from the derived colour, so a world keeps its identity while gaining
	# structure — rather than two hand-picked colours that could belong to anything.
	h.check(material.get_shader_parameter("base_color") == earth.color.darkened(0.35),
		"the base colour is the derived colour, darkened")
	h.check(material.get_shader_parameter("detail_color") == earth.color.lightened(0.25),
		"and the detail colour is the derived colour, lightened")

	# One noise field, shared. Two bodies differ by offset, not by texture.
	var luna_material: ShaderMaterial = luna.mesh.material_override
	h.check(material.get_shader_parameter("noise_field") == luna_material.get_shader_parameter("noise_field"),
		"every body draws from the same noise field")
	h.check(material.get_shader_parameter("noise_offset") != luna_material.get_shader_parameter("noise_offset"),
		"and each body is given its own place in it")
	h.check(SpacesimBodyRenderer.offset_for("planet:earth") == material.get_shader_parameter("noise_offset"),
		"which is stable for a given id")


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

	# The shell reaches where the framing says the air ends, and only bodies with air get one.
	h.check(luna.atmosphere_mesh == null, "Luna has no atmosphere shell — content gives it no air")
	h.check(earth.atmosphere_mesh != null, "Earth has one")
	if earth.atmosphere_mesh == null:
		return
	# **The shell's radius is on the NODE's scale, not on the mesh.** The mesh is a shared unit icosphere,
	# so a body's size is its transform — which is what lets one mesh serve a moon and a gas giant.
	var shell := earth.atmosphere_mesh
	# **The shell's top is derived from the air's own scale height**, floored by the frame's
	# transition altitude -- see SpacesimAtmosphereModel.shell_reach.
	var top := earth.radius + earth.sky_top
	h.check_near(shell.scale.x, top, "reaching where the body's own air ends", 1.0)
	# Earth's ten scale heights come to ~84 km, *under* the frame's 100 km floor, so the floor wins --
	# which is the rule that stops a shell being shorter than the atmosphere the game puts you in.
	h.check(SpacesimAtmosphereModel.shell_reach(
		earth.content.atmosphere, materials, 288.15,
		SpacesimAtmosphereModel.surface_gravity(earth.content)) < sol.framing.atmosphere_altitude,
		"Earth's derived reach is under the frame's floor, so the floor is what is drawn (%.0f km)"
			% (earth.sky_top / 1000.0))

	var material: ShaderMaterial = earth.atmosphere_mesh.material_override
	h.check(material != null and material.shader != null, "with the scattering shader")
	if material == null:
		return
	# **Additive, and that is what keeps the star visible through the sky.** A sky is something you look
	# *through*: with `blend_mix` and alpha 1 an opaque sky would hide the star's own disc, so a sun seen
	# from the surface would vanish from its own sky. Asserted rather than assumed, because a
	# `blend_mix` regression is silent — and it has to hold **from inside an atmosphere as well as from
	# space**, which is the note the lighting plan inherits.
	h.check(material.shader.code.contains("blend_add"),
		"and drawn ADDITIVELY, so the star stays visible through the sky it is seen through")
	h.check_near(material.get_shader_parameter("atmosphere_radius"), top,
		"and the shader knows both radii, so its ray test matches the mesh", 1.0)
	h.check_near(material.get_shader_parameter("planet_radius"), earth.radius,
		"planet radius included", 1.0)

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

	# **A named gap, not a silent one.** Every species the authored atmospheres use has a
	# cross-section except water vapour and hydrogen, and what that costs is written down here.
	var uncovered: Array[String] = []
	for body in scene.bodies:
		if body.content == null or body.content.atmosphere == null:
			continue
		if SpacesimAtmosphereModel.coverage(body.content.atmosphere, materials) < 1.0:
			uncovered.append(body.name)
	h.check(uncovered == ["Earth"],
		"and the only air short of a cross-section is Earth's water vapour: %s" % [uncovered])


## The four giants have no surface to stand on, but they do have air -- and the air is most of what
## you see. **Their "surface" is the 1-bar level, which is a convention and not a boundary:** there is
## no liquid to land on, because hydrogen is supercritical above 33 K at 13 bar and every giant's 1-bar
## level is far above that. The radius is already the 1-bar radius, so the shell sits above it.
func _test_the_air_shells_reach_the_right_height(
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
	for entry in [
		{"id": "planet:venus", "reach": 159.0, "covered": 1.0},
		{"id": "planet:earth", "reach": 100.0, "covered": 0.99},
		{"id": "planet:mars", "covered": 1.0, "reach": 114.0}, {"id": "moon:triton", "covered": 1.0, "reach": 158.0},
		{"id": "moon:titan", "covered": 1.0, "reach": 215.0}, {"id": "planet:neptune", "covered": 1.0, "reach": 207.0},
		{"id": "planet:jupiter", "covered": 1.0, "reach": 227.0}, {"id": "planet:uranus", "covered": 1.0, "reach": 275.0},
		{"id": "planet:saturn", "covered": 1.0, "reach": 501.0},
	]:
		var body := scene.body_by_id(String(entry["id"]))
		h.check(body != null and body.atmosphere_mesh != null,
			"%s has an air shell" % entry["id"])
		if body.atmosphere_mesh == null:
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
	# An airless body stays airless: no air block, no shell.
	var mercury := scene.body_by_id("planet:mercury")
	h.check(mercury.atmosphere_mesh == null, "Mercury still has no air at all")


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
	var temperature := SpacesimAtmosphereModel.reference_temperature(
		earth.content, materials_earth,
		SpacesimStarModel.luminosity(star.content), earth.position.distance_to(star.position))
	var tropopause := SpacesimAtmosphereModel.tropopause_temperature(temperature)
	var lapse := SpacesimAtmosphereModel.lapse_rate(
		earth.content.atmosphere, materials_earth,
		SpacesimAtmosphereModel.surface_gravity(earth.content))
	h.check(absf(tropopause / temperature - 0.8409) < 1.0e-4,
		"the tropopause is the grey skin temperature, %.1f K for an effective %.1f"
			% [tropopause, temperature])
	# **The profile's shape, and the check that the greenhouse landed.** Before the greenhouse this
	# surface was 256.5 K — below freezing — so water "condensed" 1.7 km *below ground*. It is now
	# above freezing and the base is where cloud bases are, from the profile and the material table.
	var water := materials_earth.by_name("water_vapour")
	var base := (temperature - water.condensation_temperature) / lapse / 1000.0
	h.check(temperature > water.condensation_temperature,
		"the surface is %.1f K, above water's condensation temperature" % temperature)
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


func _test_hiding_bodies_hides_their_air(h, scene: SpacesimSystemScene) -> void:
	# `P` hides the bodies. Leaving the air behind would look like a bug rather than a debug key.
	# **Nothing draws a cloud deck any more** — the shell that did was removed for standing 76 km above
	# Earth and reading as the atmosphere from space. `SpacesimClouds` stays and is still read by
	# `bond_albedo`, which `test_surface.gd` guards: Earth's 0.302 against a measured 0.306.
	var meshes := scene.meshes()
	var air := 0
	for mesh in meshes:
		if mesh.name.ends_with("Air"):
			air += 1
	h.check(air > 0, "the debug key's mesh list includes the air shells (%d)" % air)
