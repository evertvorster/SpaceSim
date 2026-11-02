extends SceneTree
## **Is the sea level a property of the terrain, or a special case we invented?**
##
## Evert, 2026-11-02: *"a planet has to have a certain amount of rock, with a surface roughness that turns into
## continents and islands. Then it also needs to have an amount of liquid, which would then fill the lower surfaces
## first, and give us the ocean level. Should be calculable.... special casing things below the ocean surface would make
## later work more difficult."*
##
## He is right, and this prints the number that says whether the special case (a separate scale above and below the
## datum) is repairing a real asymmetry or hiding a broken distribution. The sea level is the field value at the
## liquid's area fraction; with ONE relief scale, the land's height is `(1 - sea) * relief` and the deepest basin
## `(sea + 1) * relief`.
##
##   xvfb-run -a godot-double-mono --path . --script res://tests/probe_surface_distribution.gd

const RADIUS := 6_371_000.0
const RELIEF := 0.0014
const OCEAN := 0.71


func _init() -> void:
	var cache := SpacesimSurfaceDistribution.new()
	var entry := cache.prepare("planet:earth", RADIUS)
	if not entry.error.is_empty():
		print("no table: %s" % entry.error)
		quit(1)
		return
	print("Earth's field, area percentiles (field units, the field is bounded to ±1):")
	for share in [0.0, 0.05, 0.1, 0.25, 0.5, float(OCEAN), 0.75, 0.9, 1.0]:
		print("  %5.0f %%  %+.4f" % [share * 100.0, entry.value_at(share)])
	var sea := entry.value_at(OCEAN)
	var relief := RADIUS * RELIEF
	print("")
	print("  liquid covers %.0f %% of the area -> sea level %+.4f field units" % [OCEAN * 100.0, sea])
	print("  ONE scale of %.0f m over the field's ±1:" % relief)
	print("    highest ground  %+8.0f m   (Earth   +8849)" % ((1.0 - sea) * relief))
	print("    deepest basin   %+8.0f m   (Earth  -10994)" % ((0.0 - 1.0 - sea) * relief))
	print("")
	print("  and the mean depth of the water, if it filled to that level: the area below sea level times")
	print("  its own mean deficit — the number an honest liquid volume has to reproduce.")
	var below := 0.0
	var deficit := 0.0
	var steps := 200
	for index in steps:
		var share := float(index) / float(steps) * OCEAN
		below += 1.0
		deficit += (sea - entry.value_at(share)) / float(steps)
	print("    mean deficit below sea level  %+.4f field units = %.0f m" % [deficit, deficit * relief])
	# **The device must be freed**, or the process segfaults at exit — the trap `SpacesimSurfaceGpu` documents.
	cache.close()
	quit(0)
