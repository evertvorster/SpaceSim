extends SceneTree
## **Does a windowed bake of one tile actually carry the field, or a constant?**
##
## The flying report, 2026-10-27: a tile-sized rectangle on the ground is flat mid-grey while the ground around it has
## texture. A constant height inside a tile means the land's sea-level discard hands that whole region to the ocean,
## which draws a colour and not a picture — so this asks the first question: **is the bake of a tile window fine, and
## the fault is in the copy into the layer array or in the rect/layer pairing?**
##
##   xvfb-run -a godot-double-mono --path . --script res://tests/probe_tile_window.gd
##
## It bakes the same *window* the tile path asks for — a level-9 rectangle of the equirect, 512 texels — through the
## same entry point, and reports the value range. A constant means the bake; a varying field means the plumbing.

const TILE_TEXELS := 512


func _init() -> void:
	var gpu := SpacesimSurfaceGpu.new()
	if not gpu.open():
		print("no rendering device: ", gpu.error())
		quit(1)
		return
	var plan := SpacesimSurfaceField.plan("planet:earth", 6.371e6)
	# **A tile under the equator, not at `(0, 0)`** — that corner is the north pole, where every u maps to the same
	# point and the field is constant by construction. The first run of this probe chose it and reported "almost
	# constant" for every level, which is true and useless.
	for level in [0, 4, 9, 11]:
		var span: int = 1 << level
		var rect := SpacesimSurfaceTiles.rect_of(level, span / 2, span / 2)
		var image := gpu.bake(
			plan, TILE_TEXELS, TILE_TEXELS,
			Vector2(rect.x, rect.y), Vector2(rect.z, rect.w) - Vector2(rect.x, rect.y)
		)
		if image == null:
			print("  level %2d: bake returned null (%s)" % [level, gpu.error()])
			continue
		var lowest := INF
		var highest := -INF
		var mean := 0.0
		for y in TILE_TEXELS:
			for x in TILE_TEXELS:
				var value := image.get_pixel(x, y).r
				lowest = minf(lowest, value)
				highest = maxf(highest, value)
				mean += value
		mean /= float(TILE_TEXELS * TILE_TEXELS)
		var verdict := "CONSTANT — the bake is empty" if highest - lowest < 1.0e-4 else "carries the field"
		print("  level %2d: %.4f .. %.4f  mean %+.4f   %s" % [
			level, lowest, highest, mean, verdict])
	gpu.close()
	quit()
