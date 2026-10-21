extends Node
## **Every body's condensation levels, as the model computes them.** Read-only, and it duplicates nothing:
## it calls `condensation_levels` and prints what comes back.
##
##     timeout 60 godot-double-mono --headless --path . res://tests/probe_cloud_audit.tscn
##
## It began as a preview of a change that had not been applied — carrying the corrected reference
## temperatures and latent heats as a local table, so the pictures could be seen before the model moved.
## **Once the change landed, that copy became a liability**: it went on printing `FOG` for bodies the
## model had started giving decks to, which is a probe reporting yesterday's answer as today's. So the
## duplicate is gone and this is now simply a view of the derivation.

const SOL_PATH := "res://systems/sol.tres"


func _ready() -> void:
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	var scene := SpacesimSystemScene.from_content(sol)
	scene.build(self)
	var materials := SpacesimMaterialTable.engine_table()
	var luminosity := SpacesimStarModel.luminosity(scene.star().content)

	print("SpaceSim condensation levels")
	print("%-14s %-14s %8s %8s %9s %9s  %s" % [
		"body", "species", "x", "T_cond", "height km", "p (bar)", "regime"
	])
	for content in sol.bodies:
		if content.atmosphere == null:
			continue
		var body := scene.body_by_id(content.id)
		if body == null:
			continue
		var gravity := SpacesimAtmosphereModel.surface_gravity(content)
		var equilibrium := SpacesimAtmosphereModel.equilibrium_temperature(
			content, materials, luminosity, body.position.distance_to(scene.star().position)
		)
		for level in SpacesimAtmosphereModel.condensation_levels(
				content.atmosphere, materials, gravity, equilibrium, content):
			var condensation: SpacesimAtmosphereModel.Condensation = level
			var fraction: float = content.atmosphere.species.get(condensation.species, 0.0)
			print("%-14s %-14s %8.4f %8.1f %9.1f %9.3f  %s" % [
				content.id.replace("planet:", "").replace("moon:", "m."),
				condensation.species, fraction,
				SpacesimAtmosphereModel.condensation_temperature_at(
					materials.by_name(condensation.species), fraction,
					content.atmosphere.surface_pressure
				),
				condensation.height / 1000.0,
				condensation.pressure / 1.0e5,
				_regime_name(condensation.regime)
			])

	# **And the deck's own radii**, because those are the numbers the split is made of: the pass receives
	# `base_radius` and `top_radius`, puts its air/deck segment boundaries exactly there, gates the fog strictly
	# between them, and the deck shader flips its normal where the eye crosses the TOP. So an altitude question
	# about the split is a question about this table and nothing else.
	print()
	print("%-14s %4s %10s %9s %9s %14s %14s" % [
		"body", "deck", "base km", "thick m", "top km", "base radius m", "top radius m"
	])
	for content in sol.bodies:
		var body := scene.body_by_id(content.id)
		if body == null or body.decks.is_empty():
			continue
		for deck in body.decks:
			var base_altitude: float = deck.height
			var top_altitude: float = deck.height + deck.thickness
			print("%-14s %4d %10.3f %9.1f %9.3f %14.1f %14.1f" % [
				content.id.replace("planet:", "").replace("moon:", "m."),
				deck.index, base_altitude / 1000.0, deck.thickness, top_altitude / 1000.0,
				body.radius + base_altitude, body.radius + top_altitude
			])

	scene.container.free()
	get_tree().quit(0)


func _regime_name(regime: int) -> String:
	match regime:
		SpacesimAtmosphereModel.Condensation.Regime.LEVEL:
			return "LEVEL"
		SpacesimAtmosphereModel.Condensation.Regime.DEEP:
			return "DEEP (below what we model)"
		_:
			return "NONE (never condenses)"
