extends RefCounted
## **The seam between the scene and the air march**: which body the frame marches, and what it hands over.
##
## The march itself is `SpacesimAtmospherePass`'s, its source is compiled by `tests/shader_check.sh`, and the
## picture is flown. What can be asserted here is the contract either side of it, and it has failed before in
## both directions: a pass given air for the wrong body, and a pass given *no* air by a scene that could not
## find one. Both look exactly like a working pass drawing nothing.


func run(h, _root: Node) -> void:
	print("  air")
	_test_the_nearest_body_with_air_is_named(h)
	_test_a_star_is_never_the_subject(h)
	_test_the_dictionary_carries_everything_the_march_reads(h)


## A body with no air is empty, so it is never named even when it is nearest.
func _test_the_nearest_body_with_air_is_named(h) -> void:
	var scene := SpacesimSystemScene.new()
	var airless := SpacesimSceneBody.new()
	airless.name = "Airless"
	airless.position = Vector3(1.0, 0.0, 0.0)
	var with_air := SpacesimSceneBody.new()
	with_air.name = "WithAir"
	with_air.position = Vector3(100.0, 0.0, 0.0)
	with_air.radius = 6.371e6
	with_air.sky_top = 1.0e5
	with_air.air = {"rayleigh": Vector3.ONE}
	scene.bodies = [airless, with_air]
	var found := scene.air_for_eye(Vector3.ZERO)
	h.check(not found.is_empty(), "a body with air is found")
	h.check(found.get("body") == with_air, "and it is the one with air, not the nearest body")
	h.check_near(float(found.get("atmosphere_radius")), 6.471e6,
		"the air top is the radius plus `sky_top`", 1.0)
	scene.bodies = [airless]
	h.check(scene.air_for_eye(Vector3.ZERO).is_empty(),
		"and with no air in the system there is nothing to march")


## **A star is a photosphere, not an atmosphere the march can draw.** Marched as air, its own disc is
## extinguished — the one failure here that would be obvious and confusing at the same time.
func _test_a_star_is_never_the_subject(h) -> void:
	var scene := SpacesimSystemScene.new()
	var sun := SpacesimSceneBody.new()
	sun.name = "Sun"
	sun.position = Vector3.ZERO
	sun.radius = 6.957e8
	sun.sky_top = 1.0e6
	sun.air = {"rayleigh": Vector3.ONE}
	var content := SpacesimSystemBody.new()
	content.kind = SpacesimSystemBody.Kind.STAR
	sun.content = content
	scene.bodies = [sun]
	h.check(scene.air_for_eye(Vector3(1.0e11, 0.0, 0.0)).is_empty(),
		"a star with air-shaped numbers is still not the subject")


## Everything the shader reads must be present: a missing key reads as a zero, and a zero coefficient is a
## transparent sky that looks like a pass doing nothing.
func _test_the_dictionary_carries_everything_the_march_reads(h) -> void:
	var scene := SpacesimSystemScene.new()
	var body := SpacesimSceneBody.new()
	body.name = "Earth"
	body.position = Vector3(1.5e11, 0.0, 0.0)
	body.radius = 6.371e6
	body.sky_top = 1.0e5
	body.air = {
		"rayleigh": Vector3(4.8e-6, 1.1e-5, 2.8e-5),
		"rayleigh_scale_height": 8427.0,
		"absorption": Vector3.ZERO,
		"mie": SpacesimAtmosphereModel.MIE_COEFFICIENT,
		"mie_scale_height": SpacesimAtmosphereModel.MIE_SCALE_HEIGHT,
		"mie_anisotropy": SpacesimAtmosphereModel.MIE_ANISOTROPY,
		"sun_intensity": 4.0,
	}
	scene.bodies = [body]
	var found := scene.air_for_eye(Vector3(1.5e11 + 2.1e7, 0.0, 0.0))
	for key in ["rayleigh", "rayleigh_scale_height", "absorption", "mie", "mie_scale_height",
			"mie_anisotropy", "sun_intensity"]:
		h.check((found["air"] as Dictionary).has(key), "the air dictionary carries %s" % key)
	h.check_near(float(found["planet_radius"]), 6.371e6, "the planet radius is the body's", 1.0)
