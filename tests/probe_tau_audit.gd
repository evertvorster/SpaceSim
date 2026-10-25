extends Node
const SOL_PATH := "res://systems/sol.tres"
func _ready() -> void:
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	var scene := SpacesimSystemScene.from_content(sol)
	scene.build(self)
	print("%-10s %-8s %12s %12s %10s" % ["body", "deck", "draws with", "shadows with", "ratio"])
	for id in ["planet:earth", "planet:mars", "planet:venus", "planet:jupiter", "planet:saturn", "planet:titan"]:
		var body := scene.body_by_id(id)
		if body == null:
			continue
		for deck in body.decks:
			var draw := scene._deck_tau_full(body, deck)
			print("%-10s %-8d %12.4f %12.4f %10.2fx" % [
				id, deck.index, draw, deck.shadow_tau, deck.shadow_tau / maxf(draw, 1e-6)])
	# and the transmittance each implies at a full-thickness texel, straight up
	var earth := scene.body_by_id("planet:earth")
	if earth != null and not earth.decks.is_empty():
		var deck: SpacesimSceneBody.Deck = earth.decks[0]
		var draw := scene._deck_tau_full(earth, deck)
		print("\nEarth, full-thickness texel, straight up:")
		print("  deck draws with tau %.3f -> shell transmit 1/(1+tau) = %.3f  (ground passes this)" % [draw, 1.0/(1.0+draw)])
		print("  shadow casts with tau %.3f -> light arriving e^-tau = %.3f" % [deck.shadow_tau, exp(-deck.shadow_tau)])
	get_tree().quit()
