extends RefCounted
## The star as a light source, and the camera that exposes for it.
##
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

	# The exposure window has to span what the light actually covers, or the two drift apart and the
	# symptom is a world that is black or white at one end of the system.
	var mercury := sol.body_by_id("planet:mercury")
	var ratio := SpacesimStarLight.irradiance(luminosity, mercury.orbit.semi_major_axis) \
		/ SpacesimStarLight.irradiance(luminosity, neptune.orbit.semi_major_axis)
	var stops := log(ratio) / log(2.0)
	var window := SpacesimExposure.MAX_EXPOSURE_EV - SpacesimExposure.MIN_EXPOSURE_EV
	h.check(stops < window,
		"the camera's %.0f-stop window spans the system's %.1f stops" % [window, stops])

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

	scene.container.free()
