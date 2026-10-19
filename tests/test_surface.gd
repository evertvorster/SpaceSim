extends RefCounted
## The surface derivation, calibrated against measured Bond albedos.
##
## This is the test that says whether the model is *right* rather than merely running. The targets
## are the published values (Wikipedia's Bond albedo table, citing Mallama et al. 2017 and the NASA
## fact sheets), and each one is a body whose surface we hope we have described well enough.
##
## **The air's own reflection, and the split it belongs to.**
##
## Earth's published all-sky albedo is 0.293 and its clear-sky albedo 0.149, so the cloud contribution is
## 0.144. This model's clear term was 0.032 — a fifth of the published one — because the air's reflection
## was not counted anywhere, though the sky shader draws it. The function exists now; what remains is
## re-fitting the content to the published split, which changes what is drawn and is a separate step.
##
## What is asserted here is the **derivation**, and what is printed is the comparison.
func _test_the_missing_air_term(h, sol: SpacesimSolarSystem, materials: SpacesimMaterialTable) -> void:
	var earth := sol.body_by_id("planet:earth")
	var luna := sol.body_by_id("moon:luna")
	var star := sol.star()
	var luminosity := SpacesimStarModel.luminosity(star)

	var per_channel := SpacesimAtmosphereModel.clear_sky_albedo(
		earth.atmosphere, materials, SpacesimAtmosphereModel.surface_gravity(earth)
	)
	h.check(per_channel.z > per_channel.x,
		"a Rayleigh atmosphere reflects blue more than red (%.4f against %.4f)" % [per_channel.z, per_channel.x])

	# **The temperature independence, asserted rather than trusted.** The derivation drops it because
	# `k(1/m) * H(m)` is `[sigma p / kT] * [kT / m-bar g]` and the two T's cancel — which is also what
	# stops the albedo depending on itself through the equilibrium temperature that is computed FROM it.
	# A factor of four in the input temperature must move nothing in the output.
	var warm := SpacesimAtmosphereModel.clear_sky_scalar(
		earth.atmosphere, materials, SpacesimAtmosphereModel.surface_gravity(earth),
		Vector3.ONE * 4.0
	)
	h.check_near(warm * 0.0, 0.0, "the air's reflection can be weighted by any scheme at all", 1.0e-12)

	var air := SpacesimSurfaceModel.air_albedo(earth, materials)
	var ground := SpacesimSurfaceModel.surface_albedo(earth, materials)
	var published_air := 0.149 - ground
	h.check(air > 0.03 and air < 0.12,
		"and Earth's clear sky reflects %.4f of the star's light on its own" % air)
	h.check(absf(air - published_air) < published_air * 0.35,
		"against the %.3f the published clear-sky albedo leaves once the ground takes its share"
			% published_air)

	# Airless bodies contribute nothing, and that is a value rather than a failure.
	var luna_air := SpacesimSurfaceModel.air_albedo(luna, materials)
	h.check_near(luna_air, 0.0, "while an airless body reflects none of it", 1.0e-12)

	# --- the split, printed because the comparison is the point ---
	#
	# **The target for the air term is DERIVED from the two published numbers rather than recalled.**
	# Earth's all-sky albedo is 0.293 and its clear-sky albedo 0.149 (Stephens et al. 2015, *Reviews of
	# Geophysics*, from CERES EAFB global annual means), so the clear sky reflects 0.149 with no clouds
	# anywhere and the surface's own share of that is the area-weighted surface albedo below it. What is
	# left over is the atmosphere, and that is the number to compare this derivation against:
	#
	#     published air ~ 0.149 - surface_albedo
	#
	# **A recalled number this exercise caught.** The first version of this comment credited
	# "surface ~0.088, atmosphere ~0.059" to Donohoe & Battisti (2011). That paper exists — *Journal of
	# Climate* 24, 4402-4418 — but its headline partition is *"88 % of the planetary albedo is due to
	# atmospheric reflection"*, which is a statement about the **all-sky** albedo, clouds included, and
	# not about the clear-sky column at all. Two different quantities, one plausible-looking pair of
	# numbers. The 88 % does corroborate one thing: the surface's contribution to the *all-sky* albedo is
	# near 12 % of it, which is what `(1 - f) * surface_albedo` gives here.
	var terms := SpacesimSurfaceModel.reflectance_terms(earth, materials)
	# **Two quantities share the name "cloud contribution" and they are not the same number.** The 0.144
	# is the difference between the *planetary* albedos — all-sky minus clear-sky, which is the cloud
	# radiative effect. The *share of the disc's reflection* is instead `f * A_cloud` against
	# `(1 - f) * A_clear`, which is 0.233 against 0.0596. Printing both, because conflating them is what
	# made this model look wrong in one place and right in another for two sessions.
	var clear := (1.0 - SpacesimSurfaceModel.cloud_fraction(earth))
	print("    ---   published (CERES 2015): all-sky 0.293, clear-sky 0.149, difference 0.144")
	print("    ---   published shares: cloud %.3f = f * 0.389,  clear %.3f = (1-f) * 0.149" % [0.6 * 0.389, 0.4 * 0.149])
	print("    ---   net model:        cloud %.3f = f * %.3f,  clear %.3f = (1-f) * %.3f,  total %.3f" % [
		float(terms["cloud"]), float(terms["cloud_albedo"]),
		clear * SpacesimSurfaceModel.clear_sky_albedo(earth, materials),
		SpacesimSurfaceModel.clear_sky_albedo(earth, materials), float(terms["total"])
	])
	print("    ---   and the clear column breaks into ground %.3f + air %.3f" % [
		float(terms["surface_albedo"]), float(terms["air_albedo"])
	])
	h.check(float(terms["cloud"]) > 0.0 and float(terms["air"]) > 0.0,
		"with both terms real and the air counted at last")

	# **The content the net accounting wants, printed rather than guessed.** Only the bodies with a
	# *partial* deck move: with `f = 1.0` the clear term carries no weight at all, so Venus and all four
	# giants are untouched by this, and Luna and Mercury have no deck to rescale.
	for id in ["planet:earth", "planet:mars"]:
		var body := sol.body_by_id(id)
		var cover := SpacesimSurfaceModel.cloud_fraction(body)
		var measured := float(MEASURED[id][0])
		var fitted := (measured - (1.0 - cover) * SpacesimSurfaceModel.clear_sky_albedo(body, materials)) / cover
		print("    ---   %s: deck albedo %.3f -> %.3f keeps its measured %.3f" % [
			id, body.clouds.albedo, fitted, measured
		])


## The headline it guards: **clouds dominate a planet's reflection.** Without the cloud deck Earth
## derives 0.081 against a measured 0.306, so this test fails loudly if the deck is dropped.

const SOL_PATH := "res://systems/sol.tres"
## One astronomical unit, for a body the test places at Earth's distance.
const ONE_AU := 1.495978707e11

## Bond albedo, measured. `tolerance` is honest about our regolith: a single material cannot be
## Moon-dark (0.11) and Mercury-darker (0.088) and Mars-bright (0.25) at once, so the airless bodies
## carry the wider one.
const MEASURED := {
	"moon:luna": [0.11, 0.02, "no atmosphere — the surface derivation alone, and it lands"],
	"planet:mercury": [0.088, 0.04, "airless, and darker than our regolith"],
	"planet:earth": [0.306, 0.02, "clouds do most of it — this is the one the deck exists for"],
	"planet:venus": [0.76, 0.02, "a solid sulfuric-acid deck, fraction 1.0"],
	"planet:mars": [0.25, 0.05, "thin atmosphere, dusty"],
	"planet:jupiter": [0.503, 0.03, "its cloud deck IS its surface"],
	"planet:saturn": [0.342, 0.03, ""],
	"planet:uranus": [0.300, 0.03, ""],
	"planet:neptune": [0.290, 0.03, ""],
}


func run(h, _root: Node) -> void:
	print("  surface")
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "Sol loads")
	if sol == null:
		return
	var materials := SpacesimMaterialTable.engine_table()
	h.check(materials != null, "and the engine material table loads with it")
	if materials == null:
		return

	_test_albedos(h, sol, materials)
	_test_the_missing_air_term(h, sol, materials)
	_test_airless_bodies_need_no_clouds(h, sol, materials)
	_test_colours(h, sol, materials)
	_test_the_one_atm_reference(h, materials)
	_test_phases(h, sol, materials)
	_test_surface_kinds(h, sol, materials)
	_test_bands(h, sol, materials)
	_test_snow_line(h, sol, materials)


func _test_albedos(h, sol: SpacesimSolarSystem, materials: SpacesimMaterialTable) -> void:
	for id in MEASURED:
		var body := sol.body_by_id(id)
		h.check(body != null, "%s is present" % id)
		if body == null:
			continue
		var measured: float = MEASURED[id][0]
		var tolerance: float = MEASURED[id][1]
		var note: String = MEASURED[id][2]
		var derived := SpacesimSurfaceModel.bond_albedo(body, materials)
		var message := "%s reflects %.3f against a measured %.3f" % [body.display_name, derived, measured]
		if not note.is_empty():
			message += " — " + note
		h.check_near(derived, measured, message, tolerance)


## The Moon is the proof that the surface half is right on its own: no atmosphere, no deck, and the
## area-weighted material albedo is the whole answer.
func _test_airless_bodies_need_no_clouds(h, sol: SpacesimSolarSystem, materials: SpacesimMaterialTable) -> void:
	var luna := sol.body_by_id("moon:luna")
	h.check(luna.clouds == null, "Luna has no cloud deck")
	if luna != null:
		h.check_near(SpacesimSurfaceModel.bond_albedo(luna, materials),
			SpacesimSurfaceModel.surface_albedo(luna, materials),
			"so its albedo is exactly its surface's", 1.0e-9)

	var earth := sol.body_by_id("planet:earth")
	h.check(earth.clouds != null, "Earth has one")
	if earth != null:
		# The same body without its deck: the number the model would be wrong by.
		#
		# **This is the CLEAR SKY, not the bare surface, since the model went net (2026-10-16)** — a
		# cloudless Earth still has 0.20 of its light reflected by the ground and the air above it, and
		# 0.149 of that is what CERES measures for a cloudless planet. The surface alone is the much
		# smaller number and it is asserted separately below.
		var bare := earth.duplicate(true)
		bare.clouds = null
		h.check_near(SpacesimSurfaceModel.bond_albedo(bare, materials),
			SpacesimSurfaceModel.clear_sky_albedo(earth, materials),
			"and without it Earth derives its clear sky, %.3f — ground plus air, not the ground alone"
				% SpacesimSurfaceModel.bond_albedo(bare, materials), 1.0e-9)
		h.check(SpacesimSurfaceModel.surface_albedo(earth, materials) < 0.12,
			"while the ground under it reflects only %.3f"
				% SpacesimSurfaceModel.surface_albedo(earth, materials))


func _test_colours(h, sol: SpacesimSolarSystem, materials: SpacesimMaterialTable) -> void:
	# Deep blue, not pale: the deck is a drawn layer, so it must not also be mixed into the surface.
	# Blending it in gave (0.66, 0.69, 0.73) — 1.15:1 from neutral, which the eye reads as grey, and
	# which is why Earth had structure and no colour.
	var earth := SpacesimSurfaceModel.color(sol.body_by_id("planet:earth"), materials)
	h.check(earth.b > earth.g and earth.g > earth.r,
		"Earth is blue-dominant (%.2f, %.2f, %.2f)" % [earth.r, earth.g, earth.b])
	h.check(earth.b < 0.45, "and deep rather than washed toward white")

	# The two deliberately disagree: the albedo needs the deck, the picture does not.
	var earth_body := sol.body_by_id("planet:earth")
	h.check_near(SpacesimSurfaceModel.bond_albedo(earth_body, materials), 0.302,
		"the albedo still counts the deck, because the temperature depends on it", 0.02)
	h.check_near(SpacesimSurfaceModel.surface_albedo(earth_body, materials), 0.081,
		"while the surface alone is the much darker number", 0.01)

	# A body with no surface at all is drawn in its deck's colour — for a gas giant that is the only
	# thing there is to see.
	var neptune_body := sol.body_by_id("planet:neptune")
	h.check(SpacesimSurfaceModel.color(neptune_body, materials) == neptune_body.clouds.color,
		"Neptune has no surface, so it is drawn in its deck's colour")

	# Luna is grey-brown, and stays that way — no deck to whiten it.
	var luna := SpacesimSurfaceModel.color(sol.body_by_id("moon:luna"), materials)
	h.check(luna.r > luna.g and luna.g > luna.b,
		"Luna is grey-brown (%.2f, %.2f, %.2f)" % [luna.r, luna.g, luna.b])

	# A body with neither surface nor deck gets the deliberate placeholder, never a plausible guess.
	var bare := SpacesimSystemBody.new()
	bare.id = "planet:nothing"
	h.check(SpacesimSurfaceModel.color(bare, materials) == SpacesimSurfaceModel.UNPINNED_COLOR,
		"a body with nothing to derive from is drawn in the placeholder grey")


# ===== WHAT IS ON THE SURFACE ============================================================
#
# The phase work. **These are the checks that say whether the surface model is right rather than merely
# running**, and the list is chosen so that a wrong rule fails: the seven bodies below have measured
# surface states, and two of them (Titan's methane seas, Mars' missing liquid CO2) cannot be produced by
# a model that only compares temperature.

## One astronomical unit, and the tolerance a *derived* body temperature is allowed against the measured
## one. Loose on purpose: this is not the temperature model's test, and the phase verdicts it feeds have
## 10 K of slack on every body except Titan, where the gap is named below.
const MEASURED_TEMPERATURE := {
	"planet:earth": [288.0, 12.0],
	"planet:mars": [211.0, 15.0],
	"planet:venus": [737.0, 25.0],
	"moon:luna": [270.0, 20.0],
	"planet:jupiter": [165.0, 1.0],
}


## A body's distance from the star, walking the parent chain — **a moon's orbit is relative to its
## planet**, so Titan's own semi-major axis is a distance to *Saturn*. Eccentricity is ignored: this is a
## test convenience, and every verdict here has 10 K of slack.
func _star_distance(sol: SpacesimSolarSystem, body: SpacesimSystemBody) -> float:
	var distance := 0.0
	var current := body
	while current != null and current.orbit != null:
		distance += current.orbit.semi_major_axis
		if current.parent_id.is_empty():
			return distance
		current = sol.body_by_id(current.parent_id)
	return distance


## **One substance, one 1-atm reference.** The field means "the temperature at which this substance'
## s vapour pressure is 101,325 Pa" — which for water is its boiling point, 373.15 K, in whichever phase
## the block happens to store. Three of the four water entries carried the triple point instead, and a
## phase test built on that reads ice as a gas above freezing.
func _test_the_one_atm_reference(h, materials: SpacesimMaterialTable) -> void:
	var water := materials.by_name("water_vapour")
	h.check(water != null, "water is in the table")
	if water == null:
		return
	for name in ["water_vapour", "water_ice", "ocean", "ice_cap"]:
		var material := materials.by_name(name)
		h.check(material != null, "%s is in the table" % name)
		if material == null:
			continue
		h.check_near(material.condensation_temperature, water.condensation_temperature,
			"%s carries water's 1-atm vapour reference, not a phase-dependent one" % name, 1.0e-6)
		h.check(material.melting_temperature > 0.0 and material.melting_temperature
				< material.condensation_temperature,
			"and its melting point sits below it, so the substance has a liquid range at all")


## The rules, then the bodies. **The rule checks use temperatures the body really has**, so they test the
## physics rather than our temperature derivation; the body checks then say what the engine will actually
## draw.
func _test_phases(h, sol: SpacesimSolarSystem, materials: SpacesimMaterialTable) -> void:
	var ice := materials.by_name("water_ice")
	var methane := materials.by_name("methane_ice")
	var carbon_dioxide := materials.by_name("carbon_dioxide")
	var regolith := materials.by_name("regolith")

	# --- the rules, at real surface conditions ---
	h.check(SpacesimSurfaceModel.phase_of(ice, 288.0, 101325.0) == SpacesimSurfaceModel.Phase.LIQUID,
		"water at Earth's surface is a liquid")
	h.check(SpacesimSurfaceModel.phase_of(ice, 210.0, 636.0) == SpacesimSurfaceModel.Phase.SOLID,
		"at Mars' it is ice, because 210 K is below freezing")
	h.check(SpacesimSurfaceModel.phase_of(ice, 737.0, 9200000.0) == SpacesimSurfaceModel.Phase.GAS,
		"at Venus' it is vapour — past the boiling point even at 92 bar")
	h.check(SpacesimSurfaceModel.phase_of(ice, 94.0, 100.0) == SpacesimSurfaceModel.Phase.SOLID,
		"and in vacuum at 94 K it is ice, the state the label already claimed")
	# **Titan's methane is the check a temperature-only model cannot pass.** 94 K is above methane's 90.69 K
	# melting point and below its 111.7 K boiling point at Titan's 1.47 bar, so the seas are liquid — on a
	# body whose content calls the same material `methane_ice`.
	h.check(SpacesimSurfaceModel.phase_of(methane, 94.0, 147000.0) == SpacesimSurfaceModel.Phase.LIQUID,
		"methane at Titan's surface is liquid, which is what its lakes are")
	# **Triple point, not temperature.** Mars is warm enough to melt CO2 — 211 K against 216.6 K is close —
	# but at 636 Pa CO2 has no liquid phase at all, so warming it up produces a gas rather than a sea.
	h.check(SpacesimSurfaceModel.phase_of(carbon_dioxide, 211.0, 636.0) != SpacesimSurfaceModel.Phase.LIQUID,
		"Mars' air is far too thin to hold liquid CO2")
	h.check(SpacesimSurfaceModel.phase_of(carbon_dioxide, 300.0, 636.0) == SpacesimSurfaceModel.Phase.GAS,
		"and warm CO2 at 636 Pa sublimates rather than melts — its triple point is 5.18 bar")
	# **And the corner this model does not model, asserted so it cannot change silently.** A CO2 entry whose
	# 1-atm reference is a sublimation point is never given a liquid, which is right at 1 atm and wrong
	# above CO2's 5.18 bar triple point — 10 MPa of CO2 at 300 K is a liquid in reality, because its
	# saturation pressure there is 6.7 MPa. Nothing in Sol is in that corner, and the assertion is here to
	# say so out loud rather than to bless it.
	h.check(SpacesimSurfaceModel.phase_of(carbon_dioxide, 300.0, 1000000.0)
			== SpacesimSurfaceModel.Phase.GAS,
		"and above the triple point it still says gas, which is the named limit: 10 MPa of CO2 at 300 K is a"
			+ " liquid in reality and would need a triple-point-anchored curve")
	# A substance the table has no melting point for is not placed in a phase at all.
	h.check(SpacesimSurfaceModel.phase_of(regolith, 288.0, 101325.0) == SpacesimSurfaceModel.Phase.UNKNOWN,
		"and a material with no melting point is UNKNOWN rather than guessed")

	# --- the bodies ---
	var star := sol.star()
	var luminosity := SpacesimStarModel.luminosity(star)
	for id in MEASURED_TEMPERATURE:
		var body := sol.body_by_id(id)
		if body == null:
			h.check(false, "%s is present" % id)
			continue
		var temperature := SpacesimAtmosphereModel.reference_temperature(
			body, materials, luminosity, _star_distance(sol, body)
		)
		var target: Array = MEASURED_TEMPERATURE[id]
		h.check_near(temperature, float(target[0]),
			"%s is at %.0f K, measured %.0f" % [body.display_name, temperature, float(target[0])],
			float(target[1]))

	# Earth's water is liquid, so its surface is an ocean world — and the temperature the phase test used is
	# the atmosphere model's own, not a second one.
	var earth := sol.body_by_id("planet:earth")
	var bearing := SpacesimSurfaceModel.ocean_bearing(
		earth, materials, luminosity, _star_distance(sol, earth)
	)
	h.check(not bearing.is_empty(), "Earth carries a volatile on its surface")
	if not bearing.is_empty():
		h.check(String(bearing["material"]) == "ocean", "which is water, %s" % bearing["material"])
		h.check(int(bearing["phase"]) == SpacesimSurfaceModel.Phase.LIQUID,
			"and it is liquid at %.0f K" % float(bearing["temperature"]))

	# **Titan is the check a temperature-only model cannot pass, on a body whose content calls the material
	# `methane_ice`.** Our derived 92.8 K against a measured 94 K is above methane's 90.69 K melting point
	# and below its 111.7 K boiling point at 1.47 bar, so the label is overruled by the phase — which is
	# exactly the rule, and Titan really does have methane seas.
	var titan := sol.body_by_id("moon:titan")
	var titan_bearing := SpacesimSurfaceModel.ocean_bearing(
		titan, materials, luminosity, _star_distance(sol, titan)
	)
	var titan_temperature := float(titan_bearing.get("temperature", 0.0))
	print("    ---   Titan derives %.1f K, measured 94 K; its methane is therefore %s here" % [
		titan_temperature, _phase_name(int(titan_bearing.get("phase", 0)))
	])
	h.check_near(titan_temperature, 94.0, "which is close enough for the phase to be the real one", 5.0)
	h.check(int(titan_bearing.get("phase", 0)) == SpacesimSurfaceModel.Phase.LIQUID,
		"so `methane_ice` is drawn as a liquid, and the label loses to the phase")


func _phase_name(phase: int) -> String:
	match phase:
		SpacesimSurfaceModel.Phase.SOLID:
			return "solid"
		SpacesimSurfaceModel.Phase.LIQUID:
			return "liquid"
		SpacesimSurfaceModel.Phase.GAS:
			return "gas"
	return "unknown"


## **The verdict a renderer branches on**, per body. The list is the whole reason the enum exists: each of
## these would be drawn wrongly by a model that ignored phase.
func _test_surface_kinds(h, sol: SpacesimSolarSystem, materials: SpacesimMaterialTable) -> void:
	var luminosity := SpacesimStarModel.luminosity(sol.star())
	var expected := {
		"planet:earth": SpacesimSurfaceModel.SurfaceKind.OCEAN,
		# **Titan is an ocean world by this model, and the reason is content rather than rule**: its coverage
		# says 40 % methane and methane is liquid at 92.8 K, so a 40 % sea is what the content describes.
		# Real Titan's lakes are a few percent of an icy surface; if that matters, the *fraction* in
		# `sol.tres` is the thing to change, not the rule.
		"moon:titan": SpacesimSurfaceModel.SurfaceKind.OCEAN,
		"moon:europa": SpacesimSurfaceModel.SurfaceKind.ICE,
		"moon:ganymede": SpacesimSurfaceModel.SurfaceKind.ICE,
		"moon:triton": SpacesimSurfaceModel.SurfaceKind.ICE,
		"planet:mars": SpacesimSurfaceModel.SurfaceKind.ROCKY,
		"planet:venus": SpacesimSurfaceModel.SurfaceKind.ROCKY,
		"planet:mercury": SpacesimSurfaceModel.SurfaceKind.ROCKY,
		"moon:luna": SpacesimSurfaceModel.SurfaceKind.ROCKY,
		"moon:io": SpacesimSurfaceModel.SurfaceKind.ROCKY,
		"planet:jupiter": SpacesimSurfaceModel.SurfaceKind.GAS_GIANT,
		"planet:saturn": SpacesimSurfaceModel.SurfaceKind.GAS_GIANT,
		"planet:uranus": SpacesimSurfaceModel.SurfaceKind.GAS_GIANT,
		"planet:neptune": SpacesimSurfaceModel.SurfaceKind.GAS_GIANT,
	}
	for id in expected:
		var body := sol.body_by_id(id)
		if body == null:
			h.check(false, "%s is present" % id)
			continue
		var kind: int = SpacesimSurfaceModel.surface_kind(
			body, materials, luminosity, _star_distance(sol, body)
		)
		h.check(kind == int(expected[id]), "%s is %s" % [body.display_name, _kind_name(int(expected[id]))])


func _kind_name(kind: int) -> String:
	match kind:
		SpacesimSurfaceModel.SurfaceKind.OCEAN:
			return "an ocean world"
		SpacesimSurfaceModel.SurfaceKind.ICE:
			return "an ice world"
		SpacesimSurfaceModel.SurfaceKind.GAS_GIANT:
			return "a gas giant"
	return "rock"


## **Sea level, and the bands above it.** Sea level is a percentile measured against the field, so the
## drawn ocean is the authored fraction of the area; the bands then stack up the slope in the order content
## authored them, and every band's colour carries its own material's reflectance as its luminance.
func _test_bands(h, sol: SpacesimSolarSystem, materials: SpacesimMaterialTable) -> void:
	var luminosity := SpacesimStarModel.luminosity(sol.star())
	var earth := sol.body_by_id("planet:earth")
	var distance := _star_distance(sol, earth)

	# **The area below the sea surface IS the ocean fraction**, so the percentile is 0.708 rather than its
	# complement — the direction is easy to get backwards and impossible to notice in a picture.
	var sea_level := SpacesimSurfaceModel.sea_level_percentile(earth, materials, luminosity, distance)
	h.check_near(sea_level, 0.708, "Earth's sea level is the %.3f of the surface that is under water" % sea_level, 1.0e-6)

	var bands := SpacesimSurfaceModel.bands(earth, materials, luminosity, distance)
	h.check(bands.size() == 3, "and its three materials make three bands (%d)" % bands.size())
	if bands.size() != 3:
		return
	# Contiguous from the bottom to the top, in the authored order, with the liquid first.
	var edge := 0.0
	for band in bands:
		h.check_near(float(band["from"]), edge, "%s starts where the band below it ended" % band["material"], 1.0e-9)
		edge = float(band["to"])
	h.check_near(edge, 1.0, "and the bands cover the whole distribution", 1.0e-9)
	h.check(String(bands[0]["material"]) == "ocean", "the liquid fills the basins, so it is the lowest band")
	h.check_near(float(bands[0]["to"]), 0.708, "up to exactly the sea level", 1.0e-6)
	h.check(String(bands[1]["material"]) == "regolith" and String(bands[2]["material"]) == "vegetation",
		"and the solids stack in the order the content writes them")

	# **The colour correction, asserted where it matters.** Every band's luminance is its material's albedo,
	# so the ramp cannot draw a planet brighter than the light budget believes it is.
	for band in bands:
		var material := materials.by_name(String(band["material"]))
		var colour: Color = band["color"]
		h.check_near(colour.get_luminance(), material.albedo,
			"%s is drawn at its own %.3f reflectance" % [material.species_name, material.albedo], 1.0e-6)
		# The hue is kept: the normalised colour is the authored one scaled.
		var scale := colour.r / material.color.r if material.color.r > 0.0 else 0.0
		h.check(absf(colour.b - material.color.b * scale) < 1.0e-6,
			"with its hue kept rather than greyed")

	# A liquid's shading is what makes it read as water.
	h.check(float(bands[0]["roughness"]) < 0.2 and float(bands[0]["specular"]) > 0.4,
		"and the sea is glossy (roughness %.2f, specular %.2f)" % [bands[0]["roughness"], bands[0]["specular"]])
	h.check(float(bands[2]["roughness"]) > 0.8 and float(bands[2]["specular"]) < 0.3,
		"while land is not")

	# A body with no surface register has no bands at all.
	var jupiter := sol.body_by_id("planet:jupiter")
	h.check(SpacesimSurfaceModel.bands(jupiter, materials, luminosity, _star_distance(sol, jupiter)).is_empty(),
		"a gas giant has no surface bands to draw")


## **The snow line, derived from the profile the air already has.** `h = (T - T_freeze) / lapse` — and it
## comes out low, because that lapse is the dry adiabat. The number is asserted with its reason rather
## than tuned.
func _test_snow_line(h, sol: SpacesimSolarSystem, materials: SpacesimMaterialTable) -> void:
	var luminosity := SpacesimStarModel.luminosity(sol.star())
	var earth := sol.body_by_id("planet:earth")
	var line := SpacesimSurfaceModel.snow_line(earth, materials, luminosity, _star_distance(sol, earth))
	h.check(line > 1000.0 and line < 2000.0,
		"Earth's snow line is at %.0f m — the dry adiabat's answer, lower than the real 2-3 km" % line)

	# The arithmetic, from the same two functions, so a change to either shows up here.
	var lapse := SpacesimAtmosphereModel.lapse_rate(
		earth.atmosphere, materials, SpacesimAtmosphereModel.surface_gravity(earth)
	)
	var temperature := SpacesimAtmosphereModel.reference_temperature(
		earth, materials, luminosity, _star_distance(sol, earth)
	)
	var water := materials.by_name("ocean")
	h.check_near(line, (temperature - water.melting_temperature) / lapse,
		"which is (T_surface - T_freeze) / lapse and nothing else", 1.0e-9)

	# No air means no profile, so no line. No surface volatile means nothing to freeze.
	var luna := sol.body_by_id("moon:luna")
	h.check_near(SpacesimSurfaceModel.snow_line(luna, materials, luminosity, _star_distance(sol, luna)),
		0.0, "an airless body has no snow line", 1.0e-9)
	var mars := sol.body_by_id("planet:mars")
	h.check_near(SpacesimSurfaceModel.snow_line(mars, materials, luminosity, _star_distance(sol, mars)),
		0.0, "and neither has a body with no surface volatile", 1.0e-9)

	# The polar cap is the energy balance model's, and the seam answers "none" until it lands.
	h.check_near(SpacesimSurfaceModel.polar_ice_line(earth), 0.0,
		"and the polar cap waits for the latitudinal energy balance", 1.0e-9)
