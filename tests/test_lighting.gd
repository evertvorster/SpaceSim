extends RefCounted
## The star as a light source, and the camera that exposes for it.
## The physics here is checkable against measured values, and that is the point: the solar constant
## and the Sun's effective temperature are two independently measured numbers the model has to land
## on. Whether it *looks* right, and whether exposure pumps while flying, are not checkable and are
## not claimed to be.

const SOL_PATH := "res://systems/sol.tres"
const AU := 1.495978707e11
const SOLAR_CONSTANT := 1361.0 ## W/m² at 1 au, measured
const SUN_EFFECTIVE_TEMPERATURE := 5772.0 ## K, measured


func run(h, root: Node) -> void:
	print("  light")

	# Without this project setting Godot ignores light_intensity_lux entirely, and every number below
	# would be correct and invisible.
	if not bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)):
		h.check(false, "physical light units are ON — with them off Godot ignores light_intensity_lux")
		return
	h.check(true, "physical light units are on, so a lux means something")

	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "Sol loads")
	if sol == null:
		return
	var star := sol.star()

	_test_the_star(h, star)
	_test_the_star_light(h, sol, root)


func _test_the_star(h, star: SpacesimSystemBody) -> void:
	var luminosity := SpacesimStarModel.luminosity(star)
	h.check_near(luminosity, 3.828e26, "the Sun's pinned luminosity is 3.828e26 W", 1.0e24)

	# L and R are measured independently, so this checks the data rather than restating it.
	var temperature := SpacesimStarModel.effective_temperature(luminosity, star.radius)
	h.check_near(temperature, SUN_EFFECTIVE_TEMPERATURE,
		"Stefan-Boltzmann gives 5772 K from L and R (%.1f)" % temperature, 5.0)

	# The colour follows the temperature, by the blackbody fit the Shaders project already uses —
	# taken rather than invented, and linearised on the way out.
	var sun_color := SpacesimStarModel.color(temperature)
	h.check(sun_color.r >= sun_color.g and sun_color.g >= sun_color.b,
		"so the Sun is warm white (%.3f, %.3f, %.3f)" % [sun_color.r, sun_color.g, sun_color.b])
	h.check(sun_color.r > 0.9 and sun_color.b > 0.6, "and near-white rather than strongly tinted")

	# A cooler star is markedly redder and a hotter one bluer — the point of deriving it at all, since
	# it means every stellar class is free.
	var cool := SpacesimStarModel.color(3000.0)
	var hot := SpacesimStarModel.color(15000.0)
	h.check(cool.r > cool.b * 3.0,
		"a 3000 K star is markedly redder (%.3f red against %.3f blue)" % [cool.r, cool.b])
	h.check(hot.b > hot.r, "and a 15000 K star is bluer than it is red")


func _test_the_star_light(h, sol: SpacesimSolarSystem, root: Node) -> void:
	var luminosity := SpacesimStarModel.luminosity(sol.star())

	h.check_near(SpacesimStarLight.irradiance(luminosity, AU), SOLAR_CONSTANT,
		"one au receives the solar constant, 1361 W/m²", 2.0)
	h.check_near(SpacesimStarLight.illuminance(luminosity, AU), 128000.0,
		"which is 128,000 lux of daylight", 2000.0)

	var earth := sol.body_by_id("planet:earth")
	h.check_near(SpacesimStarLight.irradiance(luminosity, earth.orbit.semi_major_axis), SOLAR_CONSTANT,
		"and Earth's own orbit gives the same number", 10.0)

	var neptune := sol.body_by_id("planet:neptune")
	var dim := SpacesimStarLight.illuminance(luminosity, neptune.orbit.semi_major_axis)
	h.check(dim > 100.0 and dim < 200.0,
		"Neptune gets about 140 lux — dim, and not black (%s lux)" % String.num(dim))

	# The exposure that puts a lit body at middle grey is arithmetic, not a measurement. Godot's
	# auto-exposure averages the frame and has no metering mode, so on a frame that is mostly empty
	# space it raises exposure until the one lit body in it is white — which is what it did.
	var attributes := SpacesimExposure.new().attributes
	h.check(not attributes.auto_exposure_enabled,
		"auto-exposure is off: the frame average is not allowed to set this")
	h.check_near(attributes.exposure_multiplier, 1.0, "and starts at Godot's own reference", 1.0e-9)

	# One au is a little over the reference light, so slightly less exposure than neutral.
	var at_one_au := SpacesimExposure.target_multiplier(SpacesimStarLight.illuminance(luminosity, AU))
	h.check_near(at_one_au, 0.78, "one au lands at %.3f times neutral" % at_one_au, 0.01)

	# Neptune is nine and a half stops dimmer, and the correction is exactly that — derived, not tuned.
	var at_neptune := SpacesimExposure.target_multiplier(dim)
	h.check_near(at_neptune, 707.0, "Neptune lands at %.0f times neutral" % at_neptune, 5.0)
	var stops := log(at_neptune / at_one_au) / log(2.0)
	h.check_near(stops, 9.8, "which is the %.1f stops between them" % stops, 0.1)

	# Monotonic, and clamped: nothing here may chase a frame that contains no light at all.
	h.check(SpacesimExposure.target_multiplier(1000.0) > SpacesimExposure.target_multiplier(10000.0),
		"a dimmer light gets more exposure")
	h.check(SpacesimExposure.target_multiplier(0.0) == SpacesimExposure.MAX_MULTIPLIER,
		"and with no light at all it settles at the clamp rather than flying off")

	# Following a change is gradual: what you notice about a night side is that it stays dark, and a
	# hard cut when flying between planets looks like a bug.
	var exposure := SpacesimExposure.new()
	exposure.snap_to(dim)
	h.check_near(exposure.multiplier(), at_neptune, "a snap lands exactly on the target", 5.0)
	exposure.update(SpacesimStarLight.illuminance(luminosity, AU), 0.016)
	h.check(exposure.multiplier() < at_neptune and exposure.multiplier() > at_one_au,
		"while one 16 ms step only moves part of the way (%.1f)" % exposure.multiplier())

	# The dark-adapted multiplier follows the FIELD OF VIEW, because a star's rendered radiance goes as
	# `(height / tan(half vfov))^2` and a constant derived at one field is wrong at every other. Evert's
	# idea, 2026-10-14, and the point of checking it is that it *chooses a behaviour*: the sky becomes
	# independent of the field and stays dependent on the resolution.
	var reference := SpacesimExposure.DARK_ADAPTED_MULTIPLIER
	h.check_near(SpacesimExposure.dark_adapted_multiplier(SpacesimExposure.DARK_ADAPTED_REFERENCE_FOV),
		reference, "at its reference field it is the reference value", 1.0)
	var wide := SpacesimExposure.dark_adapted_multiplier(70.0)
	h.check_near(wide / reference, 4.18,
		"and at the game's 70 degrees it is %.2fx that, because (tan35/tan18.9)^2 = 4.18"
			% (wide / reference), 0.05)
	h.check(SpacesimExposure.dark_adapted_multiplier(20.0) < reference,
		"a narrower field needs LESS, since the same flux is already concentrated into a smaller angle")

	# The invariant the whole thing rests on. A star's rendered radiance goes as 1/tan^2(half fov) and
	# this multiplier goes as tan^2(half fov), so it is their PRODUCT that is field-independent — which
	# is another way of saying what lands on the screen does not change when the field does. The first
	# version of this check had the ratio the wrong way up, and the two numbers were three orders of
	# magnitude apart, which is what made the mistake obvious rather than subtle.
	var a := SpacesimExposure.dark_adapted_multiplier(30.0) / pow(tan(deg_to_rad(15.0)), 2.0)
	var b := SpacesimExposure.dark_adapted_multiplier(110.0) / pow(tan(deg_to_rad(55.0)), 2.0)
	h.check_near(a, b, "so radiance x multiplier — what actually lands on the screen — is the same "
		+ "at 30 degrees as at 110 (%.1f against %.1f)" % [a, b], 0.01 * a)

	# **The clamp must sit above the anchor at the WIDEST field the settings allow**, not merely at the
	# reference one, because the anchor goes as tan^2(half fov): 140 degrees — `camera.fov`'s own maximum
	# in `settings.gd` — is 64x its reference value. Checked at the widest field rather than at the 70
	# the game runs at, since that is where it would fail, and the clamp is now derived from the anchor
	# so that it keeps holding the next time the anchor moves, which it has now done once.
	var widest := SpacesimExposure.dark_adapted_multiplier(140.0)
	h.check(widest < SpacesimExposure.MAX_MULTIPLIER,
		"the clamp sits above the dark-adapted anchor even at the widest field (%s against %s)"
			% [widest, SpacesimExposure.MAX_MULTIPLIER])
	h.check(widest * 10.0 < SpacesimExposure.MAX_MULTIPLIER,
		"with real headroom rather than a coincidence")

	# **The range is 32 stops, and both ends of it are states of the eye** — the floor is fully
	# light-adapted, the ceiling is the dark-adapted anchor's headroom. Evert, 2026-10-15: *"open the
	# EV range to 32."* The floor being below 1.0 is the check that it is a *state* and not a guess: a
	# sunlit surface at middle grey is 1.0, and "as bright as the eye still adapts to" is a sunlit
	# surface that is BRIGHTER than middle grey, so the multiplier is smaller.
	var stops := log(SpacesimExposure.MAX_MULTIPLIER / SpacesimExposure.MIN_MULTIPLIER) / log(2.0)
	h.check_near(stops, 32.0, "the exposure can swing 32 stops (%.2f)" % stops, 0.01)
	h.check(SpacesimExposure.MIN_MULTIPLIER < 1.0 and SpacesimExposure.MIN_MULTIPLIER > 0.0,
		"with the floor under middle grey and above zero (%.4f)" % SpacesimExposure.MIN_MULTIPLIER)

	# **AgX ignores `tonemap_white`**, and the engine says so outright: *"tonemap_agx_white will be
	# used instead when using the TONE_MAPPER_AGX tonemapper"*. The derivation this file is built on
	# is done against a white point of **6.0**, so setting only `tonemap_white` left the curve running
	# at its own default of 16.29 — a curve the exposure's arithmetic was never written against.
	# Checked as an equality between the two rather than against a second constant, so they cannot
	# drift apart again. (The magnitude of the fix is small — the white parameter shapes the shoulder
	# only, and Sirius moves about 4% — but a constant and a curve that disagree about white is a trap
	# for the next person either way.)
	var environment := Environment.new()
	SpacesimExposure.configure(environment)
	h.check(environment.tonemap_mode == Environment.TONE_MAPPER_AGX,
		"the tone curve is AgX, the one built for a wide range without ACES' highlight colour shifts")
	h.check_near(environment.tonemap_agx_white, environment.tonemap_white,
		"and the white point actually in force is the one the arithmetic uses (%.2f)"
			% environment.tonemap_agx_white, 1.0e-6)
	h.check(environment.ambient_light_source == Environment.AMBIENT_SOURCE_BG,
		"with the sky as the ambient source, so a night side is lit by the stars that are there")

	# And the light is aimed from the star through the observer, with the strength for that distance.
	var scene := SpacesimSystemScene.from_content(sol)
	h.check(scene != null, "a scene wraps Sol")
	if scene == null:
		return
	scene.build(root)
	var lit_earth := scene.body_by_id("planet:earth")
	var star_node := scene.body_by_id("star:sol")
	scene.aim_sun_at(lit_earth.node.global_position)

	h.check(scene.star_light != null, "and makes a star light")
	if scene.star_light != null:
		var distance := lit_earth.node.global_position.distance_to(star_node.node.global_position)
		h.check_near(scene.star_light.light.light_intensity_lux,
			SpacesimStarLight.illuminance(luminosity, distance),
			"whose strength is the illuminance at the observer", 10.0)
		# A DirectionalLight3D shines along its -Z, so its +Z points back at the star.
		var to_star := (star_node.node.global_position - lit_earth.node.global_position).normalized()
		h.check(scene.star_light.light.global_transform.basis.z.dot(to_star) > 0.99,
			"and it shines from the star toward the observer")

	# **Evert's test of the dark end**, 2026-10-15: *"the shadow side of earth, with no moonlight or
	# other source of light but starlight should be barely visible, a little above black."* That is a
	# statement about the ANCHOR and it is arithmetic — the surface renders at the ratio between the
	# exposure in force and the exposure that would put it at middle grey:
	#
	#     rendered = dark_adapted_multiplier(fov) / target_multiplier_for_luminance(albedo * sky_lux / pi)
	#
	# The whole naked-eye star field is the only light there, so `sky_lux` is the sky's own integrated
	# illuminance — the number the calibration was checked against, not a constant chosen here.
	if scene.star_sky != null:
		var materials := SpacesimMaterialTable.engine_table()
		var albedo := SpacesimSurfaceModel.bond_albedo(lit_earth.content, materials)
		var sky_lux := scene.star_sky.illuminance(6.5)
		var ground_luminance := albedo * sky_lux / PI
		var rendered := SpacesimExposure.dark_adapted_multiplier(70.0) \
			/ SpacesimExposure.target_multiplier_for_luminance(ground_luminance)
		# A band and not a point: "barely visible" is a person's judgement, and the band is what a
		# factor of five either way looks like. Through the tone curve's toe, 2e-3 lands near 2/255.
		h.check(rendered > 5.0e-4 and rendered < 5.0e-3,
			"starlight alone on a shadowed surface is barely visible, a little above black (%s)"
				% rendered)
		h.check(scene.star_sky.illuminance(6.5) > 1.0e-4,
			"because the field lighting it is the real one (%.2f e-4 lux)" % (sky_lux * 1.0e4))

	scene.container.free()
