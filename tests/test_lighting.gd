extends RefCounted
## The star as a light source, and the camera that exposes for it.
## The physics here is checkable against measured values, and that is the point: the solar constant
## and the Sun's effective temperature are two independently measured numbers the model has to land
## on. Whether it *looks* right, and whether exposure pumps while flying, are not checkable and are
## not claimed to be.

const SOL_PATH := "res://systems/sol.tres"
const Settings := preload("res://addons/spacesim/settings/settings.gd")
const AU := 1.495978707e11
const SOLAR_CONSTANT := 1361.0 ## W/m² at 1 au, measured
const SUN_EFFECTIVE_TEMPERATURE := 5772.0 ## K, measured


## **The exposure's approach is exponential in STOPS**, so the same rate closes a large change quickly and
## settles a small one finely. Evert, 2026-10-21: *"if there is a large difference between the current EV and
## the demanded EV it should close in on it quickly, and then fine tune."*
##
## The shader does `exp2(mix(log2(current), log2(target), 1 - exp(-rate*delta)))`; this is that arithmetic, so
## the claim "halves every ln2/rate seconds" is a test rather than a comment. The GPU side is the same formula
## with the same numbers, and the setting is what feeds `rate`.
func _test_adaptation_halves(h) -> void:
	var rate: float = SpacesimExposure.ADAPTATION_RATE
	var half_life := log(2.0) / rate
	h.check(half_life > 0.05 and half_life < 2.0,
		"the default rate halves the gap every %.2f s" % half_life)

	# A twenty-stop jump, stepped at 60 Hz: the gap must halve on schedule, and never overshoot.
	var target_ev := 20.0
	var current_ev := 0.0
	var steps := int(round(10.0 * 60.0))
	var halved_on_time := true
	for i in steps:
		var delta := 1.0 / 60.0
		var t := clampf(1.0 - exp(-rate * delta), 0.0, 1.0)
		current_ev = lerpf(current_ev, target_ev, t)
		var elapsed := float(i + 1) * delta
		# Half a second past the half-life, the gap must be under half what it was at the half-life.
		if absf(elapsed - half_life) < delta * 0.5:
			var gap_at_half_life := absf(target_ev - current_ev)
			if gap_at_half_life > 20.0 * 0.55:
				halved_on_time = false
	h.check(halved_on_time, "and a large gap is down to about half of itself one half-life later")
	h.check(absf(target_ev - current_ev) < 0.01,
		"while ten seconds of it settles within a hundredth of a stop (%.4f)" % absf(target_ev - current_ev))
	h.check(current_ev <= target_ev + 1.0e-9, "and it never overshoots")


func run(h, root: Node) -> void:
	print("  light")
	_test_adaptation_halves(h)

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
	_test_the_frame_exposure(h)


## The frame-wide pass's two preconditions, both of which are traps that cost a measurement each.
##
## Marked 2026-10-15: `identity()` must keep the camera attributes **attached**, and the reason is not
## cosmetic — with `attributes = null` the engine skips the factor that implements Godot's lux convention
## (`light_storage.cpp:764` applies it only `if camera_attributes.is_valid()`) and a scene renders about
## **95x too bright**. The second is that the pass owns the exposure now, so the camera's own multiplier
## must be 1.0 or the two multiply.
func _test_the_frame_exposure(h) -> void:
	var exposure := SpacesimExposure.new()
	h.check(exposure.attributes != null, "the camera's attributes always exist")
	h.check(
		not exposure.attributes.auto_exposure_enabled,
		"and Godot's own auto-exposure is off: the frame average is not allowed to set this"
	)
	exposure.identity()
	h.check(
		exposure.attributes != null,
		"identity KEEPS the camera attributes — `null` skips Godot's lux convention and is 95x bright"
	)
	h.check_near(
		exposure.attributes.exposure_multiplier, 1.0,
		"and puts the multiplier at 1.0, so the frame-wide pass owns the exposure alone", 1e-12
	)


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

	# --- the star's angular size, which is derived rather than stated -------------------------------
	# `asin(R/d)`, against the three distances the LOD plan's phase 1b names. The constant this replaced
	# was the Sun's disk at one au: right there, and wrong everywhere else — 2.6x too small at Mercury,
	# 30x too large at Neptune. The star's radius is read from the content rather than restated, so a
	# wrong radius in `sol.tres` fails here too.
	var sun_radius: float = sol.star().radius
	h.check_near(rad_to_deg(SpacesimLod.angular_radius(sun_radius, AU)), 0.266,
		"the Sun's angular radius at one au is the 0.533-degree disk halved", 0.001)
	h.check_near(rad_to_deg(SpacesimLod.angular_radius(sun_radius, 0.39 * AU)), 0.683,
		"at Mercury it is 2.6x that, which a constant fixed at 1 au could not have carried", 0.002)
	h.check_near(rad_to_deg(SpacesimLod.angular_radius(sun_radius, 30.07 * AU)), 0.0089,
		"and at Neptune it is 30x the other way (%.4f degrees)"
			% rad_to_deg(SpacesimLod.angular_radius(sun_radius, 30.07 * AU)), 0.0005)
	h.check(SpacesimLod.angular_radius(0.0, AU) == 0.0,
		"and a body with no radius has no angular size, rather than a division by nothing")

	# **The camera's own multiplier is identity**, because `SpacesimExposurePass` applies the exposure
	# frame-wide; anything else here would be applied twice. Godot's auto-exposure stays off, so the frame
	# average is not allowed to set it either.
	var attributes := SpacesimExposure.new().attributes
	h.check(not attributes.auto_exposure_enabled,
		"auto-exposure is off: the frame average is not allowed to set this")
	h.check_near(attributes.exposure_multiplier, 1.0, "and starts at Godot's own reference", 1.0e-9)

	# **The metre's arithmetic and the adaptation are not checked here.** `SpacesimExposurePass` does both
	# against the rendered frame, and **the suite cannot see it**: `tests/run.sh` runs `--headless`, where
	# there is no `RenderingDevice` and nothing is drawn. What is checkable headlessly is the arithmetic
	# (`tests/test_meter.gd`) and the wiring below; the *behaviour* needs a render, and
	# `tests/probe_frame_exposure.gd` is that instrument.

	# **The range is 32 stops, and both ends of it are states of the eye** — the floor is fully
	# light-adapted, the ceiling is how far a dark-adapted eye opens. Evert, 2026-10-15: *"open the
	# EV range to 32."* The floor being below 1.0 is the check that it is a *state* and not a guess: a
	# sunlit surface at middle grey is 1.0, and "as bright as the eye still adapts to" is a sunlit
	# surface that is BRIGHTER than middle grey, so the multiplier is smaller.
	var range_stops := log(SpacesimExposure.MAX_MULTIPLIER / SpacesimExposure.MIN_MULTIPLIER) / log(2.0)
	h.check_near(range_stops, 32.0, "the exposure can swing 32 stops (%.2f)" % range_stops, 0.01)
	h.check(SpacesimExposure.MIN_MULTIPLIER < 1.0 and SpacesimExposure.MIN_MULTIPLIER > 0.0,
		"with the floor under middle grey and above zero (%.4f)" % SpacesimExposure.MIN_MULTIPLIER)

	# **The ceiling is a setting now** — `exposure.range_stops`, in stops above the floor — because a
	# frame of nothing but stars has no mean luminance to answer with and the metre asks for the top of
	# the window. The declared default has to reproduce the derived `MAX_MULTIPLIER` exactly, or the
	# window moves the day someone edits the registry, so the two are tied here rather than trusted.
	h.check_near(SpacesimExposure.max_multiplier_for_stops(range_stops),
		SpacesimExposure.MAX_MULTIPLIER, "the ceiling formula reproduces the derived window",
		SpacesimExposure.MAX_MULTIPLIER * 1.0e-9)
	var declared_stops := float(Settings.default_of("exposure.range_stops"))
	h.check_near(declared_stops, range_stops,
		"and the setting's declared default is that same window (%.2f stops)" % declared_stops, 1.0e-6)
	h.check(SpacesimExposure.max_multiplier_for_stops(16.0) < SpacesimExposure.MAX_MULTIPLIER,
		"a smaller window caps the gain, which is what the setting is for")

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
	# **The glow has to be able to light a SINGLE pixel**, and Godot's default cannot. `glow_levels/1` is
	# the most local level and it defaults to 0.0, so the glow starts at a mip whose downsample has already
	# averaged a lone pixel away: a cluster of bright pixels survives that and blooms, an isolated one does
	# not, and the asymmetry hides. Evert, 2026-10-15, of the point of light a sub-pixel body becomes:
	# *"I see Venus as a solid white pixel."*
	h.check(float(environment.get("glow_levels/1")) > 0.0,
		"the most LOCAL glow level is on, so a single bright pixel can glare (%.2f)"
			% float(environment.get("glow_levels/1")))
	# The relations, rather than the numbers: the threshold has to be under the star's own emission or a
	# star cannot glare, and the cap has to be above it or the brightest thing in the frame glares exactly
	# as much as a merely bright one.
	h.check(environment.glow_hdr_threshold < SpacesimBodyRenderer.STAR_INTENSITY,
		"with the glow threshold under the star's emission, so a star glares at all")
	h.check(environment.glow_hdr_luminance_cap > SpacesimBodyRenderer.STAR_INTENSITY,
		"and the cap above it, so a glare can be brighter than a glimmer")
	h.check(environment.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR,
		"with the ambient set from the catalogue's starlight rather than from the sky's radiance cubemap "
			+ "— a point-source sky cannot be represented in one")

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
		# The disk's size is a fact about that same distance, so it is set from it rather than being a
		# constant. Godot's `light_angular_distance` is an angular DIAMETER in degrees, and the Sun from
		# Earth spans 0.524 to 0.542 degrees over the year — which is the window this has to land in, and
		# is what makes the old 0.533 legible as "this value, at one au".
		var diameter: float = scene.star_light.light.light_angular_distance
		h.check(diameter > 0.52 and diameter < 0.55,
			"and its angular size comes from the star's own radius at that distance (%.4f degrees)"
				% diameter)

	# **Evert's test of the dark end**, 2026-10-15: *"the shadow side of earth, with no moonlight or
	# other source of light but starlight should be barely visible, a little above black."*
	#
	# **The ratio it was written as is gone with the dark-adapted multiplier**, which was a compensation
	# dressed as a constant and was removed on 2026-10-16. What a night side renders at is
	# `SpacesimExposurePass`'s answer for that frame, which is as invisible to this suite as the rest of
	# the pass's behaviour. What is still checkable is the light that does it.
	if scene.star_sky != null:
		var sky_lux := scene.star_sky.illuminance(6.5)
		h.check(sky_lux > 1.0e-4,
			"the whole naked-eye star field is what lights a shadowed surface (%.2f e-4 lux)"
				% (sky_lux * 1.0e4))

	scene.container.free()
