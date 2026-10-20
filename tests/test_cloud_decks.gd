extends RefCounted
## **The cloud decks: one node per layer, at its own derived altitude, sharing the body's own triangles.**
##
## All arithmetic and scene-building, no picture. What is checked is the *agreement* between three things
## that must never drift: the layer content authored in `sol.tres`, the level `SpacesimAtmosphereModel`
## derives for it, and the node the scene builds from both. What it cannot check is the look — that is a
## flight — and what it deliberately does not check is anything the update loop bakes, because a headless
## run has no renderer to bake with.
##
## The two-deck body is the point of the file: a single layer cannot tell a loop from a field, and Jupiter
## and Saturn are the only bodies in Sol where the pairing rule (layer → level, by species) can be seen
## working at all.

const SOL_PATH := "res://systems/sol.tres"


func run(h, root: Node) -> void:
	print("  cloud decks")
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "Sol loads")
	if sol == null:
		return
	var scene := SpacesimSystemScene.from_content(sol)
	h.check(scene != null, "a scene wraps it")
	if scene == null:
		return
	scene.build(root)

	_test_a_single_deck(h, scene)
	_test_a_stack(h, scene)
	_test_who_gets_no_deck(h, scene)
	_test_a_deck_below_its_datum(h, scene)
	_test_the_deck_goes_live(h, scene, root)
	_test_the_deck_casts_a_shadow(h, scene)
	_test_the_ramp_gain(h)

	scene.container.free()


## **Earth authors one deck, in the flat shorthand** — no species named, no stack. It gets one node, placed
## on the level the model places its water vapour, and the node's scale is the slab's top.
func _test_a_single_deck(h, scene: SpacesimSystemScene) -> void:
	var earth := scene.body_by_id("planet:earth")
	h.check(earth != null and earth.decks.size() == 1,
		"Earth authors one deck and gets one, from the level the model places (%d)" % earth.decks.size())
	if earth.decks.is_empty():
		return
	var deck: SpacesimSceneBody.Deck = earth.decks[0]
	h.check(deck.level.species == "water_vapour",
		"and it is its water vapour, at %.0f m" % deck.height)
	h.check_near(deck.node.scale.x, earth.radius + deck.height + deck.thickness,
		"the node is scaled to the slab's TOP: radius + height + thickness", 1.0)
	h.check(deck.node.get_parent() == earth.node,
		"and it is a child of the body, so it inherits the body's place in the frame tree")
	h.check(deck.material != null and deck.material.shader != null,
		"with a shader material, which is what carries the map")
	# **The slab's two radii are one ratio**, because both are on the same node and the top is 1.0 in model
	# space — which is all the geometry the shader needs to sample a base.
	var top := earth.radius + deck.height + deck.thickness
	h.check_near(float(deck.material.get_shader_parameter("base_ratio")),
		(earth.radius + deck.height) / top, "and its base sits inside it at the derived condensation level",
		1.0e-9)
	h.check(deck.thickness > 0.0, "with the derived thickness behind it (%.0f m)" % deck.thickness)


## **The two-deck bodies are the ones that can tell a loop from a field.** Jupiter authors ammonia above
## water, and the levels are derived from each species' own partial pressure — so the two decks land at
## different altitudes with air between them, which is what the pairing rule has to get right.
func _test_a_stack(h, scene: SpacesimSystemScene) -> void:
	for id in ["planet:jupiter", "planet:saturn"]:
		var body := scene.body_by_id(id)
		h.check(body != null and body.decks.size() == 2,
			"%s authors two layers and gets two decks (%d)" % [id, body.decks.size()])
		if body.decks.size() != 2:
			continue
		var upper: SpacesimSceneBody.Deck = body.decks[0]
		var lower: SpacesimSceneBody.Deck = body.decks[1]
		h.check(upper.level.species != lower.level.species,
			"%s's two decks are two condensables, not the same one twice (%s, %s)" % [
				id, upper.level.species, lower.level.species])
		h.check(upper.node.scale.x > lower.node.scale.x,
			"and the ammonia deck is the higher of the two (%.0f against %.0f m above the centre)" % [
				upper.node.scale.x, lower.node.scale.x])
		# **Different weather, not the same cloud twice**: the field's seed is keyed by the layer, so a stack
		# is two maps rather than one map at two heights.
		h.check(upper.material.get_shader_parameter("detail_seed")
			!= lower.material.get_shader_parameter("detail_seed"),
			"while each has its own field seed, so the two are different clouds")
		# **And the deeper deck is drawn first**, because every deck is centred on the same body and a
		# distance sort cannot separate them.
		h.check(lower.material.render_priority < upper.material.render_priority,
			"and the deepest deck is drawn first (%d before %d), so the top deck composites over it" % [
				lower.material.render_priority, upper.material.render_priority])


## A body with no air has nothing to condense, and a body with air but no authored deck has nothing to
## draw — both are the same empty answer rather than a shell at zero height.
func _test_who_gets_no_deck(h, scene: SpacesimSystemScene) -> void:
	var luna := scene.body_by_id("moon:luna")
	h.check(luna != null and luna.decks.is_empty(),
		"an airless body has no deck (%d)" % (luna.decks.size() if luna != null else -1))
	var counted := 0
	for body in scene.bodies:
		counted += body.decks.size()
	h.check(counted >= 6, "while the bodies with air and a deck account for %d nodes" % counted)


## **A gas giant's deck base is BELOW its own datum**, because the datum is a pressure and not a floor — so
## `radius + height` can be smaller than the radius and there is nothing to clamp.
##
## That is drawable only because the bodies with a sub-datum deck are the ones with no reference sphere: the
## four giants author no `surface` block, so nothing occludes a deck inside the datum. **A body with both a
## reference sphere and a negative base would draw its weather inside its own ground**, and the pair is
## asserted here rather than assumed, because the failure is a silently missing layer.
func _test_a_deck_below_its_datum(h, scene: SpacesimSystemScene) -> void:
	var found := false
	for body in scene.bodies:
		for deck in body.decks:
			if deck.height >= 0.0:
				continue
			found = true
			h.check(deck.node.scale.x > 0.0,
				"%s's %s deck sits %.0f m below the datum and still has a positive radius" % [
					body.id, deck.level.species, -deck.height])
			h.check(not SpacesimBodyRenderer.draws_reference_sphere(body.content),
				"and %s draws no reference sphere to hide it behind" % body.id)
	h.check(found, "at least one body has a deck under its datum, so the case is real")


## **The whole chain, driven the way the game drives it** — a camera, `update_lod`, and the numbers the
## material ends up holding. This is the check that the deck is *drawable*: the plan's rule is that a probe
## must drive the real entry point, because three probes in this project have measured something adjacent to
## the thing and reported health while the path was dead.
##
## It cannot say what the deck looks like — that is a flight — but it can say that a map was baked, that the
## threshold came from its own distribution, that the eye's position reached the material, and that turning
## the switch off hides it.
func _test_the_deck_goes_live(h, scene: SpacesimSystemScene, root: Node) -> void:
	var earth := scene.body_by_id("planet:earth")
	if earth == null or earth.decks.is_empty():
		h.check(false, "Earth has a deck to drive")
		return
	var camera := Camera3D.new()
	root.add_child(camera)
	# Three radii out, aimed at the body. **A `Basis` assigned directly**, because `look_at` fails silently
	# when its target is the origin and a rig that can fail silently will lie about where it aimed.
	camera.global_position = earth.node.global_position + Vector3(0.0, 0.0, earth.radius * 3.0)
	camera.basis = Basis.looking_at(
		(earth.node.global_position - camera.global_position).normalized(), Vector3.UP
	)
	camera.current = true
	# **Until a rebuild has actually landed**: the walk is a pool task, and three frames is a guess rather
	# than a wait. The first version of this check failed intermittently for exactly that reason.
	for frame in 30:
		scene.update_lod(camera, 0.016)
		if earth.patch_triangles > 0 and earth.decks[0].node.mesh != null:
			break

	var deck: SpacesimSceneBody.Deck = earth.decks[0]
	h.check(deck.node.visible, "the deck is visible once the frame has walked it")
	h.check(deck.node.mesh != null and deck.node.mesh == earth.mesh.mesh,
		"and it draws the body's own triangles, not a mesh of its own")
	h.check(deck.published_width > 0, "with a map the size law asked for (%d wide)" % deck.published_width)
	h.check(deck.material.get_shader_parameter("cover") != SpacesimBodyRenderer.white_texel(),
		"sampling that map rather than the white texel")
	var threshold := float(deck.material.get_shader_parameter("threshold"))
	h.check(threshold > 0.0 and threshold < 1.0,
		"at the percentile its coverage implies (%.3f)" % threshold)
	var gain := float(deck.material.get_shader_parameter("ramp_gain"))
	h.check(gain > 0.0 and gain <= 1.0, "and a ramp gain inside its ceiling (%.3f)" % gain)
	h.check_near(float(deck.material.get_shader_parameter("veil")), 1.0,
		"at full veil, because it has a map to threshold", 1.0e-6)
	var eye: Vector3 = deck.material.get_shader_parameter("eye_local")
	h.check(eye.length() > 1.0 and eye.length() < 4.0,
		"and the eye in the deck's own frame, above its top (%.2f radii)" % eye.length())

	# **A rung landing is NOT asserted here, and that is a finding rather than laziness.** Driving the cache
	# toward a 1024-wide map and waiting four seconds left the task pending, and timing the CPU bake directly
	# says why: **1024x512 takes 3.8 s — 7.2 us a texel, nine times the 0.80 us the plan and `docs/API.md`
	# record.** At 8192 that is minutes, so on the CPU path a refinement effectively never arrives and the
	# material keeps the 256 floor map. `tests/test_cloud_maps.gd` covers the cache's own contract; the cost
	# is recorded in MemPalace and needs re-measuring before the LOD reasoning is trusted again.

	# **One switch, and it hides every deck.** Read through `get_value` every frame, so it is hot.
	SpacesimSettings.set_value("render.cloud_decks", false)
	scene.update_lod(camera, 0.016)
	h.check(not deck.node.visible, "and the switch hides it without touching the map")
	SpacesimSettings.set_value("render.cloud_decks", true)
	scene.update_lod(camera, 0.016)
	h.check(deck.node.visible, "and brings it back")
	camera.queue_free()


## **The deck's shadow reaches the ground, and the sea with it.** What can be asserted is the *contract*
## between the deck and the surface it darkens: the same map, the same percentile, a depth, and the lever arm
## the offset is measured along. What cannot be asserted here is how the shadow looks — one tap of a field in
## the star's direction is arithmetic GLSL does, not GDScript.
func _test_the_deck_casts_a_shadow(h, scene: SpacesimSystemScene) -> void:
	var earth := scene.body_by_id("planet:earth")
	if earth == null or earth.decks.is_empty() or earth.mesh_material == null:
		h.check(false, "Earth has a deck and a land material to shadow")
		return
	var deck: SpacesimSceneBody.Deck = earth.decks[0]
	h.check(deck.shadow_tau > 0.0,
		"Earth's deck has an optical depth to cast with (%.3f), derived from its opacity" % deck.shadow_tau)
	var land := earth.mesh_material as ShaderMaterial
	# **Already published, by the frame walk this suite drove a moment ago** — which is the stronger claim:
	# the shadow is wired into `update_lod`, not merely available to be set.
	h.check_near(float(land.get_shader_parameter("deck_tau")), deck.shadow_tau,
		"and the frame walk has already given the land that depth", 1.0e-9)

	# Publish what a landed map would publish, and check both surfaces took it.
	var cover := SpacesimBodyRenderer.white_texel()
	SpacesimBodyRenderer.apply_deck_shadow(
		earth.mesh_material, cover, 0.843, deck.shadow_tau, deck.height + deck.thickness,
		deck.material.get_shader_parameter("detail_seed"), TAU * 2.0 / 2048.0
	)
	SpacesimBodyRenderer.apply_deck_shadow(
		earth.ocean_material, cover, 0.843, deck.shadow_tau, deck.height + deck.thickness,
		deck.material.get_shader_parameter("detail_seed"), TAU * 2.0 / 2048.0
	)
	var sea := earth.ocean_material as ShaderMaterial
	for pair in [[land, "land"], [sea, "sea"]]:
		var material: ShaderMaterial = pair[0]
		if material == null:
			continue
		h.check_near(float(material.get_shader_parameter("deck_tau")), deck.shadow_tau,
			"the %s is shadowed by the deck's own depth" % pair[1], 1.0e-9)
		h.check_near(float(material.get_shader_parameter("deck_height")),
			deck.height + deck.thickness,
			"with the lever arm at the deck's TOP, %.0f m above the surface" % (deck.height + deck.thickness),
			1.0)
		h.check_near(float(material.get_shader_parameter("deck_threshold")), 0.843,
			"and the same percentile the cloud is drawn with", 1.0e-9)
		# **A shadow does not remove the ambient**, and with one `AO` value driving both the ambient and the
		# direct light the only way to say that is a floor: below `DECK_SHADOW_FLOOR` the light stops falling.
		h.check_near(float(material.get_shader_parameter("deck_shadow_floor")),
			SpacesimBodyRenderer.DECK_SHADOW_FLOOR,
			"lit from a floor of %.2f, so shade is not night" % SpacesimBodyRenderer.DECK_SHADOW_FLOOR,
			1.0e-9)

	# **And a REFINEMENT reaches it.** The deck's map is republished on every rung, and the shadow's copy has to
	# move with it or the shadow stays at the width of the first bake while the cloud sharpens — which is
	# exactly what it looked like in flight. Published here with a different texture, as a rung would.
	var refined := Image.create_empty(8, 4, false, Image.FORMAT_L8)
	refined.fill(Color(0.5, 0.5, 0.5, 1.0))
	var refined_texture := ImageTexture.create_from_image(refined)
	SpacesimBodyRenderer.apply_deck_shadow(
		earth.mesh_material, refined_texture, 0.7, deck.shadow_tau, deck.height + deck.thickness,
		deck.material.get_shader_parameter("detail_seed"), TAU * 2.0 / 4096.0
	)
	h.check(land.get_shader_parameter("deck_cover") == refined_texture,
		"and a refined map replaces the shadow's copy of it")
	h.check_near(float(land.get_shader_parameter("deck_threshold")), 0.7,
		"with the percentile of the map it arrived with", 1.0e-9)
	# **And the ladder moves with it**, because the ladder is what makes the visible texture: a shadow that
	# sampled only the map would be blotchy where the cloud is whispy — which is what flight showed.
	h.check_near(float(land.get_shader_parameter("deck_detail_feature")), TAU * 2.0 / 4096.0,
		"and the ladder's first feature follows the map's width, as the deck's own does", 1.0e-12)
	h.check(int(land.get_shader_parameter("deck_detail_seed"))
		== int(deck.material.get_shader_parameter("detail_seed")),
		"with the deck's own field seed, so the shadow is the same cloud")

	# **A body with no deck keeps its shadow switched off**, which is the shader's `deck_shadow_present()` gate
	# and the reason the path costs nothing on the bodies without air.
	var luna := scene.body_by_id("moon:luna")
	if luna != null and luna.mesh_material != null:
		h.check_near(float((luna.mesh_material as ShaderMaterial).get_shader_parameter("deck_tau")), 0.0,
			"while an airless body has no shadow at all", 1.0e-9)
		h.check_near(float((luna.mesh_material as ShaderMaterial).get_shader_parameter("deck_shadow_floor")),
			1.0, "and a floor of 1.0, which is no shadow by arithmetic as well as by gate", 1.0e-9)


## **The ramp gain is what keeps the light budget honest**, and its ceiling is real: with the gain set from
## the map's own mean, the deck's average drawn reflectance is the calibrated albedo exactly — and where the
## field wants more contrast than a single reflectance can give, the gain stops at white and reports the
## shortfall instead of hiding it.
func _test_the_ramp_gain(h) -> void:
	var palette := Color(0.95, 0.96, 1.0)
	var luminance := palette.get_luminance()
	# Earth's deck, at a mean thickness the gain can afford: 0.419 of reflectance over 0.45.
	var gain := SpacesimBodyRenderer.cloud_gain(0.419, palette, 0.45)
	h.check_near(gain.value * luminance * 0.45, 0.419,
		"the gain puts the deck's average reflectance on the calibrated albedo", 1.0e-6)
	h.check_near(gain.achieved, 1.0, "and nothing was given up to do it", 1.0e-9)

	# **And a field without the contrast to carry it hits the ceiling** — a mean thickness of 0.34 asks for a
	# gain of 1.29, which would be a cloud reflecting more than white. So the gain stops at 1 and the deck
	# draws about 78 % of its calibrated reflectance: the honest signal that the field wants more contrast,
	# reported rather than hidden. It is a property of the field, not a fault in this arithmetic.
	var low := SpacesimBodyRenderer.cloud_gain(0.419, palette, 0.34)
	h.check_near(low.value, 1.0, "a low-contrast field is capped at white", 1.0e-9)
	h.check(low.achieved > 0.7 and low.achieved < 0.85,
		"and reaches %.0f %% of the budget, which is the contrast it has" % (low.achieved * 100.0))

	# **A field with almost no contrast is the same ceiling, much further short.**
	var thin := SpacesimBodyRenderer.cloud_gain(0.419, palette, 0.02)
	h.check_near(thin.value, 1.0, "a field with almost no contrast is capped too", 1.0e-9)
	h.check(thin.achieved < 0.5, "and reports that it fell short (%.0f %%)" % (thin.achieved * 100.0))

	# **A layer with no albedo draws nothing** rather than a black deck.
	h.check_near(SpacesimBodyRenderer.cloud_gain(0.0, palette, 0.5).value, 0.0,
		"and a layer with no albedo has no gain at all", 1.0e-9)
