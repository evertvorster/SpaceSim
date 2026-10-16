extends RefCounted
## The deck on the sphere: which bodies get one, where it sits, what it is drawn with, and the one
## geometric law that keeps it above the surface.
##
## **Not whether it looks right.** Nothing headless can say that a cloud reads as cloud — that is Evert's
## eyes and a render. What can be checked is that the shell exists where the derivation says it should,
## that it carries a map or the veil that stands in for one, and that its facets cannot sink into the
## planet, which is the fault that took the first deck out of the tree.
##
## The mapping between the shader's `uv` and `SpacesimCloudField.bake`'s parameterisation is a fact in
## two languages, and this suite cannot check it: the shader is text. `shader_check.sh` proves it
## compiles and a screenshot proves the bands land the right way up — which is why the render is part of
## this phase rather than an afterthought.

const SOL_PATH := "res://systems/sol.tres"


func run(h, root: Node) -> void:
	print("  cloud deck")
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "Sol loads")
	if sol == null:
		return
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null:
		h.check(false, "a scene wraps it")
		return
	scene.build(root)

	_test_the_sagitta_law(h)
	_test_who_gets_a_deck(h, scene)
	_test_where_it_sits(h, scene)
	_test_what_it_carries(h, scene)
	_test_the_air_above_it(h, scene)
	_test_one_writer(h, scene)
	_test_it_refines_through_to_the_material(h, scene)

	scene.cloud_maps.clear()
	scene.container.free()


## **The law that keeps a shell above the surface**, as arithmetic rather than as a picture.
##
## A facet is a chord and dips below the sphere by `radius * relative_sagitta(level)`. If that exceeds the
## deck's altitude, the facet's plane is inside the planet and the depth test eats it — a honeycomb of
## corners. So the level is chosen from the altitude, and the check is the inequality itself.
func _test_the_sagitta_law(h) -> void:
	var radius := 6.371e6
	var altitude := 1779.0
	var level := SpacesimLod.level_for_sagitta(radius, altitude)
	h.check(level > 0 and level <= SpacesimLod.MAX_LEVEL, "a level comes back (%d)" % level)
	h.check(radius * SpacesimIcosphere.relative_sagitta(level) <= altitude,
		"whose facets sag %.0f m, inside the deck's own %.0f m altitude"
			% [radius * SpacesimIcosphere.relative_sagitta(level), altitude])
	# And the floor is *tight*: one level down would sink, which is what makes it a floor rather than a
	# guess. A level lower than 0 is not a case.
	if level > 0:
		h.check(radius * SpacesimIcosphere.relative_sagitta(level - 1) > altitude,
			"while one level down would put the facets %.0f m inside the planet"
				% (radius * SpacesimIcosphere.relative_sagitta(level - 1)))

	# A higher deck is easier to satisfy, and a lower one needs more triangles. Monotone, and that is the
	# whole shape of the tradeoff.
	h.check(SpacesimLod.level_for_sagitta(radius, 20000.0) <= SpacesimLod.level_for_sagitta(radius, 1779.0),
		"a higher deck needs no finer mesh than a low one")
	h.check(SpacesimLod.level_for_sagitta(radius, 0.0) == 0,
		"and a deck with no altitude has no floor at all")


## **Which bodies get a deck, and which do not** — three gates, each a different honest answer.
func _test_who_gets_a_deck(h, scene: SpacesimSystemScene) -> void:
	h.check(scene.body_by_id("planet:earth").deck_mesh != null, "Earth has a deck")
	h.check(scene.body_by_id("planet:jupiter").deck_mesh != null, "so does Jupiter")
	h.check(scene.body_by_id("moon:luna").deck_mesh == null,
		"Luna has none — no air, so no condensation level to sit on")

	# **Venus gets a deck even though the model calls it FEATURELESS.** The gate is the *air's* level and
	# the *content's* coverage, not the verdict: a featureless deck is a uniform one, and for Venus the
	# deck IS the disc. Nothing here may treat "no structure" as "nothing to draw".
	h.check(scene.body_by_id("planet:venus").deck_mesh != null,
		"Venus has one too, because featureless means without structure rather than absent")

	# The decks are meshes in the scene, so a debug key that hides the bodies hides them as well.
	var decks := 0
	for mesh in scene.meshes():
		if mesh.name.ends_with("Deck"):
			decks += 1
	h.check(decks >= 5, "and the scene's mesh list includes them (%d decks)" % decks)


## **Where it sits**: the derived condensation level, and nothing else. `radius * 1.012` is what the first
## attempt used, and 76 km above Earth made it every world's outermost silhouette.
func _test_where_it_sits(h, scene: SpacesimSystemScene) -> void:
	var earth := scene.body_by_id("planet:earth")
	h.check(earth.cloud_bottom > 1000.0 and earth.cloud_bottom < 2000.0,
		"Earth's deck sits at %.0f m — its condensation level, a real cloud base" % earth.cloud_bottom)
	h.check_near(earth.deck_mesh.scale.x, earth.radius + earth.cloud_bottom,
		"and the shell reaches exactly radius + that", 1.0)
	h.check(earth.deck_mesh.scale.x < earth.radius * 1.001,
		"which is a height rather than a fraction of the body: %.6f of its radius"
			% (earth.deck_mesh.scale.x / earth.radius))
	h.check(earth.deck_level >= SpacesimLod.level_for_sagitta(earth.radius, earth.cloud_bottom),
		"at a level whose facets stay above the surface (level %d)" % earth.deck_level)


## **What it carries**: a map where there is weather to bake, and a veil where there is not.
func _test_what_it_carries(h, scene: SpacesimSystemScene) -> void:
	var earth := scene.body_by_id("planet:earth")
	var material := earth.deck_mesh.material_override as ShaderMaterial
	h.check(material != null, "Earth's deck wears a shader material")
	if material == null:
		return
	var cover := material.get_shader_parameter("cover") as Texture2D
	h.check(cover != null and cover != SpacesimBodyRenderer.uniform_white(),
		"with a real baked map on it")
	h.check(scene.cloud_maps.width_of("planet:earth", 0) >= SpacesimCloudMaps.FLOOR_WIDTH,
		"baked at least at the floor width (%d)" % scene.cloud_maps.width_of("planet:earth", 0))
	var threshold: float = material.get_shader_parameter("threshold")
	h.check(threshold > 0.0 and threshold < 1.0,
		"and a threshold that a %.0f%% deck actually clears (%.3f)"
			% [earth.cloud_coverage * 100.0, threshold])
	h.check_near(float(material.get_shader_parameter("veil")), 1.0,
		"with no veil, because the map already carries the area", 1.0e-9)

	# --- the veil, which is what a body with nothing to bake gets ---
	# Venus is `FEATURELESS`: no noise was ever generated, so no map exists — and the disc is still the
	# deck, uniformly. Mars and Titan are `UNKNOWN` (no wind scale collected), and a uniform field cannot
	# carry partial area, so their coverage goes into the alpha.
	var venus := scene.body_by_id("planet:venus")
	var venus_material := venus.deck_mesh.material_override as ShaderMaterial
	h.check(venus_material.get_shader_parameter("cover") == SpacesimBodyRenderer.uniform_white(),
		"Venus carries the one-texel white field, because there is no noise to bake")
	h.check_near(scene.cloud_maps.width_of("planet:venus", 0), 0.0, "and no map at all", 1.0e-9)

	var mars := scene.body_by_id("planet:mars")
	var mars_material := mars.deck_mesh.material_override as ShaderMaterial
	h.check(mars_material != null, "Mars has a deck")
	if mars_material != null:
		h.check_near(float(mars_material.get_shader_parameter("veil")), mars.cloud_coverage,
			"and it is a veil at its own %.0f%% coverage, not a shroud" % (mars.cloud_coverage * 100.0),
			1.0e-9)
		h.check_near(scene.cloud_maps.width_of("planet:mars", 0), 0.0,
			"with nothing baked for it, because its wind scale is not known", 1.0e-9)

	# The deck's colour is scaled to its albedo, so what is drawn is the reflectance the physics uses
	# rather than the palette — the same split the surface has.
	var colour: Vector3 = material.get_shader_parameter("cloud_color")
	h.check(colour.length() > 0.0, "Earth's deck has its albedo-scaled colour (%.3f)" % colour.length())


## **The air it is lit through.** A deck is a surface under the same air the ground is, and without this
## it is lit by the star's full beam and read as a flat white lid.
func _test_the_air_above_it(h, scene: SpacesimSystemScene) -> void:
	var earth := scene.body_by_id("planet:earth")
	var material := earth.deck_mesh.material_override as ShaderMaterial
	if material == null:
		return
	h.check_near(material.get_shader_parameter("planet_radius"), earth.radius,
		"the deck knows the body's radius", 1.0)
	h.check_near(material.get_shader_parameter("atmosphere_radius"), earth.radius + earth.sky_top,
		"and where the air above it ends", 1.0)
	var rayleigh: Vector3 = material.get_shader_parameter("rayleigh_coefficient")
	# **`%.2e` is not a thing in GDScript.** `%e` and `%g` are runtime errors rather than formatting
	# surprises, they sail through `--check-only`, and the error does not abort the run — so the suite's
	# error guard is what catches them, which is how this line was found.
	h.check(rayleigh.length() > 0.0,
		"so the air dims it: a Rayleigh coefficient of %.4f per Mm" % (rayleigh.length() * 1.0e6))

	# And the per-frame half, which is what makes it lit by the same sun as everything else.
	scene.update_clouds(Vector3(1.0e7, 0.0, 0.0))
	h.check(material.get_shader_parameter("eye_offset") != null, "the eye is set every frame")
	var to_sun: Vector3 = material.get_shader_parameter("sun_direction")
	h.check_near(to_sun.length(), 1.0, "and the sun arrives as a direction", 1.0e-6)


## **The wiring from a finished bake to the shader, which is the half that was missing.**
##
## `SpacesimCloudMaps`'s own suite proves the cache refines; this proves the *material* ends up with the
## better map. A render showed Earth still at the floor up close and very pixellated, so the cache cannot
## be where the fault is — and this is the guard that should have existed before the render was taken.
func _test_it_refines_through_to_the_material(h, scene: SpacesimSystemScene) -> void:
	var earth := scene.body_by_id("planet:earth")
	var material := earth.deck_mesh.material_override as ShaderMaterial
	var before := scene.cloud_maps.width_of("planet:earth", 0)
	var before_cover := material.get_shader_parameter("cover") as Texture2D

	# **The observer has to be near the body.** The map's width is derived from the distance to it, so an
	# absolute position anywhere in the system says nothing about how much of Earth is on screen.
	var near := earth.node.global_position + Vector3(1.0e8, 0.0, 0.0)
	var waited := 0
	while waited < 30000:
		scene.update_clouds(near)
		if scene.cloud_maps.pending() == 0 and scene.cloud_maps.width_of("planet:earth", 0) > before:
			break
		OS.delay_msec(5)
		waited += 5

	var after := scene.cloud_maps.width_of("planet:earth", 0)
	h.check(after > before,
		"a closer observer refines the deck's map (%d -> %d in %.1f s)" % [
			before, after, float(waited) / 1000.0
		])
	h.check(material.get_shader_parameter("cover") != before_cover,
		"and the material is handed the new map rather than left on the floor")
	h.check_near(float(material.get_shader_parameter("softness")), SpacesimBodyRenderer.DECK_SOFTNESS,
		"with the shader's own parameters intact", 1.0e-9)


## **One writer for the material's state.** The map is set by the same function at build and every frame
## after it, because the material's defaults are a solid white shroud — a deck that waited for the first
## `update_clouds` would flash white for one frame, which reads as a bug rather than as a missing map.
func _test_one_writer(h, scene: SpacesimSystemScene) -> void:
	var earth := scene.body_by_id("planet:earth")
	var material := earth.deck_mesh.material_override as ShaderMaterial
	var before := material.get_shader_parameter("cover") as Texture2D
	h.check(scene.cloud_maps.bakes() > 0,
		"the floor is baked at build, not on the first frame (%d bakes)" % scene.cloud_maps.bakes())
	h.check(before != null, "so the deck has a map the moment the scene exists")
	scene.update_clouds(Vector3(1.0e8, 0.0, 0.0))
	h.check(material.get_shader_parameter("cover") != null,
		"and the frame after it sets the same thing through the same call")
