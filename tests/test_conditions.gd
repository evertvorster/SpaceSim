extends RefCounted
## **The conditions where the observer is** — `SpacesimAtmosphereModel.conditions_at` and the scene's
## `conditions_at`, which is what the HUD's sensor column reads.
##
## Headless, so what is checked is the arithmetic against the model's own derived numbers, never a picture.
## The bands are wide enough that a wrong mechanism fails them and a wrong constant does not: Earth's
## pressure at sea level is a *derived* quantity here, not a literal, and one scale height up must divide
## it by e by construction.

const SOL_PATH := "res://systems/sol.tres"


func run(h, root: Node) -> void:
	print("  conditions at the observer")
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "Sol loads")
	if sol == null:
		return
	var materials := SpacesimMaterialTable.engine_table()
	var earth := _body(sol, "planet:earth")
	h.check(earth != null, "Earth is authored")
	if earth == null:
		return

	_test_the_ground(h, earth, materials)
	_test_one_scale_height(h, earth, materials)
	_test_thin_air(h, earth, materials)
	_test_airless(h, sol, materials)
	_test_the_scene(h, root)


func _body(sol: SpacesimSolarSystem, id: String) -> SpacesimSystemBody:
	for body in sol.bodies:
		if body.id == id:
			return body
	return null


## **At the surface the air is the surface.** The pressure is what content states, and the temperature lands
## inside the band a body with air has to be in — a wrong profile puts Venus or Mars outside it immediately.
func _test_the_ground(h, earth: SpacesimSystemBody, materials: SpacesimMaterialTable) -> void:
	var gravity := SpacesimAtmosphereModel.surface_gravity(earth)
	var equilibrium := SpacesimAtmosphereModel.equilibrium_temperature(
		earth, materials, _luminosity(), _distance()
	)
	h.check(gravity > 9.0 and gravity < 10.0, "Earth's surface gravity is about 9.8 m/s² (%.3f)" % gravity)

	var air := SpacesimAtmosphereModel.conditions_at(
		earth.atmosphere, materials, gravity, equilibrium, 0.0, earth
	)
	var surface: float = earth.atmosphere.surface_pressure
	h.check(
		air["pressure"] > surface * 0.99 and air["pressure"] <= surface * 1.01,
		"at the surface the pressure is the stated column (%.0f against %.0f Pa)"
			% [air["pressure"], surface]
	)
	h.check(
		air["temperature"] > 200.0 and air["temperature"] < 350.0,
		"and the temperature is one a body with air can hold (%.0f K)" % air["temperature"]
	)
	h.check(air["scale_height"] > 5000.0, "with a scale height in kilometres (%.0f m)" % air["scale_height"])


## **One scale height up is one e-fold**, which is the law and not a fit — so it is the check that says
## pressure is being computed from the scale height rather than from something that merely resembles it.
func _test_one_scale_height(h, earth: SpacesimSystemBody, materials: SpacesimMaterialTable) -> void:
	var gravity := SpacesimAtmosphereModel.surface_gravity(earth)
	var equilibrium := SpacesimAtmosphereModel.equilibrium_temperature(
		earth, materials, _luminosity(), _distance()
	)
	var ground := SpacesimAtmosphereModel.conditions_at(
		earth.atmosphere, materials, gravity, equilibrium, 0.0, earth
	)
	var up := SpacesimAtmosphereModel.conditions_at(
		earth.atmosphere, materials, gravity, equilibrium, float(ground["scale_height"]), earth
	)
	var ratio: float = up["pressure"] / ground["pressure"]
	h.check_near(ratio, 1.0 / exp(1.0), "a scale height up divides the pressure by e", 0.001)
	# **The air also cools with height**, which is the lapse rate being applied rather than a constant.
	h.check(
		up["temperature"] < ground["temperature"],
		"and it is colder there (%.0f against %.0f K)" % [up["temperature"], ground["temperature"]]
	)


## Far above the air there is effectively none, and the model must say so rather than crossing zero.
func _test_thin_air(h, earth: SpacesimSystemBody, materials: SpacesimMaterialTable) -> void:
	var gravity := SpacesimAtmosphereModel.surface_gravity(earth)
	var equilibrium := SpacesimAtmosphereModel.equilibrium_temperature(
		earth, materials, _luminosity(), _distance()
	)
	var high := SpacesimAtmosphereModel.conditions_at(
		earth.atmosphere, materials, gravity, equilibrium, 200000.0, earth
	)
	h.check(high["pressure"] >= 0.0, "200 km up the pressure is not negative (%.6f Pa)" % high["pressure"])
	h.check(high["pressure"] < 1.0, "and it is under a pascal (%.6f Pa)" % high["pressure"])


## **An airless body answers zero, not nothing**: the sensor column has to keep its shape, and a moon's
## surface is a real place to be standing.
func _test_airless(h, sol: SpacesimSolarSystem, materials: SpacesimMaterialTable) -> void:
	var moon := _body(sol, "moon:luna")
	if moon == null:
		h.check(false, "Luna is authored")
		return
	h.check(moon.atmosphere == null, "Luna has no air")
	var gravity := SpacesimAtmosphereModel.surface_gravity(moon)
	var air := SpacesimAtmosphereModel.conditions_at(null, materials, gravity, 250.0, 0.0, moon)
	h.check(air["pressure"] == 0.0, "with no air the pressure is zero (%s)" % str(air["pressure"]))
	h.check(air["temperature"] > 0.0, "and the temperature is still the body's (%.0f K)" % air["temperature"])


## **The scene answers for the body nearest the observer**, and its gravity is the EYE's — the whole reason
## this is not the surface figure.
func _test_the_scene(h, root: Node) -> void:
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	var scene := SpacesimSystemScene.from_content(sol)
	h.check(scene != null, "a scene wraps Sol")
	if scene == null:
		return
	scene.build(root)
	var earth := scene.body_by_id("planet:earth")
	h.check(earth != null, "the scene has Earth")
	if earth == null:
		scene.container.free()
		return

	# A thousand kilometres over the surface — far enough that gravity must have fallen.
	var above := earth.position + Vector3(0.0, earth.radius + 1000000.0, 0.0)
	var air := scene.conditions_at(above)
	h.check(air["body"] == earth, "the nearest body is Earth (%s)" % str(air["body"]))
	h.check(
		absf(float(air["altitude"]) - 1000000.0) < 1000.0,
		"a thousand kilometres up reads as a thousand kilometres (%.0f m)" % air["altitude"]
	)
	h.check(
		air["gravity"] < 9.0 and air["gravity"] > 6.0,
		"and gravity has fallen from its surface value (%.2f m/s²)" % air["gravity"]
	)
	scene.container.free()


## The Sun's luminosity and Earth's distance — the two numbers `equilibrium_temperature` is the function
## of. **Not a made-up equilibrium**: the model insists that its input is the EQUILIBRIUM temperature and
## not a pinned mean surface one (the 518 K Venus in `condensation_levels`), so the test feeds it the
## light rather than the answer.
static func _luminosity() -> float:
	return 3.828e26


static func _distance() -> float:
	return 1.495978707e11
