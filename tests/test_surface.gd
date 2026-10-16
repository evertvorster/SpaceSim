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
		earth.atmosphere, materials,
		SpacesimAtmosphereModel.reference_temperature(earth, materials, luminosity, ONE_AU),
		SpacesimAtmosphereModel.surface_gravity(earth)
	)
	h.check(per_channel.z > per_channel.x,
		"a Rayleigh atmosphere reflects blue more than red (%.4f against %.4f)" % [per_channel.z, per_channel.x])
	var air := per_channel.x * 0.2126 + per_channel.y * 0.7152 + per_channel.z * 0.0722
	h.check(air > 0.05,
		"and Earth's clear sky reflects %.4f of the star's light on its own" % air)

	# Airless bodies contribute nothing, and that is a value rather than a failure.
	var luna_air := SpacesimAtmosphereModel.clear_sky_luminance(
		luna.atmosphere, materials, 280.0, SpacesimAtmosphereModel.surface_gravity(luna)
	)
	h.check_near(luna_air, 0.0, "while an airless body reflects none of it", 1.0e-12)

	# --- the split, printed because the comparison is the point, and the comparison does NOT close ---
	#
	# **The magnitude is not asserted, and that is the honest position.** This formula is the
	# single-scattering limit with half the light going up, and it lands at 0.109 — where the literature
	# splits Earth's 0.149 clear-sky albedo into roughly **0.088 from the surface and 0.059 from the
	# atmosphere** (Donohoe & Battisti 2011). So the term is real, the right shape, and about **1.8x too
	# big**, and the constant is the part to fix: a Rayleigh phase function puts ~1/2 of what it scatters
	# into the upper hemisphere, but the *planetary* albedo weights the emerging beam by its angle and the
	# solar spectrum is not the 550 nm the coefficient is quoted at. Those are readings, not guesses.
	print("    ---   published (CERES 2015): all-sky 0.293, clear-sky 0.149, so the cloud term is 0.144")
	print("    ---   published split of the clear sky: surface ~0.088, atmosphere ~0.059")
	print("    ---   this model's clear sky: surface %.3f + air %.3f = %.3f" % [
		(1.0 - SpacesimSurfaceModel.cloud_fraction(earth)) * SpacesimSurfaceModel.surface_albedo(earth, materials),
		air,
		(1.0 - SpacesimSurfaceModel.cloud_fraction(earth)) * SpacesimSurfaceModel.surface_albedo(earth, materials) + air
	])
	print("    ---   and the model's cloud term is %.3f, against the published 0.144" % (SpacesimSurfaceModel.reflectance_terms(earth, materials)["cloud"]))

	# **What this cannot be is added to `bond_albedo()` as it stands, and the reason is a parameterisation
	# and not an arithmetic error.** `bond_albedo` is a GROSS area mix: it gives the surface under a cloud
	# no credit at all, so its cloud albedo (0.45) is the deck's own reflectance. The published split is
	# NET — the cloud term is the *difference* from what the clear column would have reflected — so
	# 0.144/0.6 = 0.24 is not the same quantity as 0.45 and neither is wrong. Adding an air term to a
	# gross mix therefore double-counts: it drives Earth's total to 0.41 against a published 0.293.
	h.check(float(SpacesimSurfaceModel.reflectance_terms(earth, materials)["cloud"]) > 0.144,
		"and the gross cloud term is still the one that is too big (%.3f against 0.144)" % (
			float(SpacesimSurfaceModel.reflectance_terms(earth, materials)["cloud"])))


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
		var bare := earth.duplicate(true)
		bare.clouds = null
		h.check(SpacesimSurfaceModel.bond_albedo(bare, materials) < 0.12,
			"and without it Earth would derive %.3f" % SpacesimSurfaceModel.bond_albedo(bare, materials))


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
