extends SceneTree
## A/B instrument for the facet-angle limit: how many chunks the walk asks for at a few altitudes.
## Run with `godot-double-mono --headless --path . --script res://tests/probe_tilt_ab.gd`,
## and compare against the tree with the foreshortening term removed.
func _initialize() -> void:
	var radius := 6.371e6
	var pixel := 1.2966806e-3
	for altitude in [1.0e5, 5.0e5, 2.0e6, 1.0e7]:
		var chunks := SpacesimPatches.select(radius + altitude, Vector3.UP, radius, pixel, 0.5)
		print("ALT %10.0f m : %5d chunks" % [altitude, chunks.size()])
	quit()
