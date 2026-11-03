extends Node
## **Every deck's optical depth, and what it does — the audit after one tau replaced two.**
##
##     timeout 60 xvfb-run -a godot-double-mono --headless --path . res://tests/probe_tau_audit.tscn
##
## Before 2026-11-03 a deck had TWO optical depths and no law relating them: it DREW with the depth its map's
## mean thickness implied (`−ln(1 − mean exceedance)`) and SHADOWED with the depth its content stated
## (`−ln(1 − opacity)`) — 3.07x apart on Earth and 6.81x on Neptune, and the other way round on Titan. They
## are one number now (`SpacesimSceneBody.Deck.tau`), so this prints the single value and the three things it
## drives: how opaque the deck is at a full column, at its mean column, and the gain that fits it back to the
## layer's calibrated albedo.
##
## **A probe that measures a default is worthless**, so it refuses to print if no map was baked — see the
## guard below.

const SOL_PATH := "res://systems/sol.tres"


func _ready() -> void:
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	var scene := SpacesimSystemScene.from_content(sol)
	scene.build(self)
	var was_on: bool = SpacesimSettings.get_value("render.cloud_decks")
	SpacesimSettings.set_value("render.cloud_decks", true)
	# **The maps are baked through the call the frame walk makes**, not through `update_lod` — a camera far
	# enough out gives every body a LOD that asks for no deck, so nothing bakes and every number below is a
	# default. Same arguments as `_update_decks`: three radii, close enough that the floor map answers
	# synchronously.
	for body in scene.bodies:
		for deck in body.decks:
			scene._cloud_maps.map(
				body.id, deck.index, body.radius, deck.coverage, body.radius * 3.0, deck.morphology,
				deck.tau
			)

	var baked := 0
	for body in scene.bodies:
		for deck in body.decks:
			if scene._cloud_maps.width_of(body.id, deck.index) > 0:
				baked += 1
	if baked == 0:
		push_error("no map was baked, so every number below would be a default — fix the probe first")
		_teardown(scene)
		return
	print("(%d of %d decks have a baked map)" % [baked, _deck_count(scene)])

	print("\n== one tau per deck ==")
	print("%-13s %-3s %-14s %5s %7s %7s %7s %7s %6s %6s" % [
		"body", "#", "species", "cov", "tau", "mean_t", "a_full", "a_mean", "meanR", "gain"])
	for body in scene.bodies:
		for deck in body.decks:
			var extent := _mean_thickness(scene, body, deck)
			var mean_r := scene._cloud_maps.opacity_mean_of(body.id, deck.index)
			var luminance := maxf(deck.palette.get_luminance(), 1.0e-6)
			print("%-13s %-3d %-14s %5.2f %7.3f %7.3f %7.3f %7.3f %6.3f %6.2f" % [
				body.id, deck.index, deck.level.species, deck.coverage, deck.tau, extent,
				_alpha(deck.tau, 1.0), _alpha(deck.tau, extent), mean_r,
				clampf(deck.albedo / (luminance * maxf(mean_r, 1.0e-6)), 0.0, 1.0)])

	print("\n== and what it means for the star behind the deck ==")
	for body in scene.bodies:
		for deck in body.decks:
			var extent := _mean_thickness(scene, body, deck)
			print("%-13s %-14s: at the mean column %.3f of the star arrives, and at a full column %.3f" % [
				body.id, deck.level.species, 1.0 - _alpha(deck.tau, extent), 1.0 - _alpha(deck.tau, 1.0)])
	_teardown(scene)


## **The cache must be closed before the tree goes away, and the order matters.** A `WorkerThreadPool` task
## still in flight takes the process down with it at teardown, and a local `RenderingDevice` left alive until
## process exit segfaults — both are written up on `SpacesimCloudMaps.close()`, and both were reproduced by
## this probe the moment it started baking: one run exited 139, the next sat until its timeout. A probe that
## never bakes (like `probe_cloud_audit`) never meets either.
func _teardown(scene: SpacesimSystemScene) -> void:
	SpacesimSettings.set_value("render.cloud_decks", true)
	scene._cloud_maps.close()
	scene.container.free()
	get_tree().quit()


func _deck_count(scene: SpacesimSystemScene) -> int:
	var count := 0
	for body in scene.bodies:
		count += body.decks.size()
	return count


## The map's mean thickness where there IS cloud, measured the way the bake measures it.
func _mean_thickness(
	scene: SpacesimSystemScene, body: SpacesimSceneBody, deck: SpacesimSceneBody.Deck
) -> float:
	var texture := scene._cloud_maps.map(
		body.id, deck.index, body.radius, deck.coverage, body.radius * 3.0, deck.morphology, deck.tau
	)
	if texture == null:
		return 0.0
	var measured := SpacesimCloudMaps.measure(texture.get_image(), deck.coverage, deck.tau)
	return float(measured["exceedance"])


## `ALPHA = covered · veil · (1 − exp(−tau · thickness / mu))` at `mu = 1` and full coverage.
func _alpha(tau: float, thickness: float) -> float:
	return 1.0 - exp(-maxf(tau * thickness, 0.0))
