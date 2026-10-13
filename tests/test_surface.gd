extends RefCounted
## The surface derivation, calibrated against measured Bond albedos.
##
## This is the test that says whether the model is *right* rather than merely running. The targets
## are the published values (Wikipedia's Bond albedo table, citing Mallama et al. 2017 and the NASA
## fact sheets), and each one is a body whose surface we hope we have described well enough.
##
## The headline it guards: **clouds dominate a planet's reflection.** Without the cloud deck Earth
## derives 0.081 against a measured 0.306, so this test fails loudly if the deck is dropped.

const SOL_PATH := "res://systems/sol.tres"

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
	# Blue-dominant and pale: ocean and cloud over rock. Not a blue marble, but the direction is
	# right and it is nothing like the placeholder grey it replaces.
	var earth := SpacesimSurfaceModel.color(sol.body_by_id("planet:earth"), materials)
	h.check(earth.b > earth.g and earth.g > earth.r,
		"Earth is blue-dominant (%.2f, %.2f, %.2f)" % [earth.r, earth.g, earth.b])
	h.check(earth.b > 0.6, "and pale, because the deck is white")

	# Luna is grey-brown, and stays that way — no deck to whiten it.
	var luna := SpacesimSurfaceModel.color(sol.body_by_id("moon:luna"), materials)
	h.check(luna.r > luna.g and luna.g > luna.b,
		"Luna is grey-brown (%.2f, %.2f, %.2f)" % [luna.r, luna.g, luna.b])

	# A body with neither surface nor deck gets the deliberate placeholder, never a plausible guess.
	var bare := SpacesimSystemBody.new()
	bare.id = "planet:nothing"
	h.check(SpacesimSurfaceModel.color(bare, materials) == SpacesimSurfaceModel.UNPINNED_COLOR,
		"a body with nothing to derive from is drawn in the placeholder grey")
