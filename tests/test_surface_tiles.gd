extends RefCounted
## The near field's walk: the map's quadtree, as arithmetic.
##
## **Nothing here bakes or draws.** A bake needs a rendering device, and the shader needs a GPU; what the walk
## *is* can be checked headlessly, and that is the half where the mistakes live — a law that never converges, a
## selection that overlaps itself, a gate that says "nothing moved" through a whole descent. Those are the three
## faults this project has already paid for once each, in `SpacesimPatches`.


func run(h, _root: Node) -> void:
	print("  surface tiles")
	_test_the_mapping(h)
	_test_the_law(h)
	_test_the_selection(h)
	_test_the_gate(h)


## **The uv rectangle and the direction it names**, which have to be inverses of the shaders' `equirect()` or the
## walk refines the wrong place. `u = 0.5 + atan(z, x)/TAU`, `v = 0.5 - asin(y)/PI`.
func _test_the_mapping(h) -> void:
	var whole := SpacesimSurfaceTiles.rect_of(0, 0, 0)
	h.check(whole.is_equal_approx(Vector4(0.0, 0.0, 1.0, 1.0)), "level 0 is the whole map")
	var quarter := SpacesimSurfaceTiles.rect_of(1, 1, 1)
	h.check(quarter.is_equal_approx(Vector4(0.5, 0.5, 1.0, 1.0)), "level 1, tile 1,1 is the far quarter")
	var eighth := SpacesimSurfaceTiles.rect_of(3, 5, 2)
	h.check(eighth.is_equal_approx(Vector4(5.0 / 8.0, 2.0 / 8.0, 6.0 / 8.0, 3.0 / 8.0)),
		"level 3, tile 5,2 is the eighth it says it is")

	h.check(SpacesimSurfaceTiles.rect_contains(
		SpacesimSurfaceTiles.rect_of(1, 1, 1), SpacesimSurfaceTiles.rect_of(3, 5, 5)),
		"a level-3 tile inside a level-1 one is contained by it")
	h.check(not SpacesimSurfaceTiles.rect_contains(
		SpacesimSurfaceTiles.rect_of(3, 1, 1), SpacesimSurfaceTiles.rect_of(1, 1, 1)),
		"and containment is not symmetric — the walk needs the direction to know an ancestor from a cousin")
	h.check(not SpacesimSurfaceTiles.rect_contains(
		SpacesimSurfaceTiles.rect_of(1, 1, 1), SpacesimSurfaceTiles.rect_of(1, 0, 0)),
		"a neighbouring tile of the same level is not inside it")

	var centre := SpacesimSurfaceTiles.direction_of(0.5, 0.5)
	h.check(centre.is_equal_approx(Vector3(1.0, 0.0, 0.0)),
		"the map's centre is +X — the equator at longitude zero")
	h.check(SpacesimSurfaceTiles.direction_of(0.75, 0.5).is_equal_approx(Vector3(0.0, 0.0, 1.0)),
		"three quarters round is +Z, so u runs the right way")
	h.check(SpacesimSurfaceTiles.direction_of(0.5, 0.0).is_equal_approx(Vector3(0.0, 1.0, 0.0)),
		"and the top row is the north pole, so v runs the right way")
	h.check(SpacesimSurfaceTiles.direction_of(0.0, 0.5).is_equal_approx(Vector3(-1.0, 0.0, 0.0)),
		"u = 0 is -X, and u = 1 wraps back onto it")


## **The law**: a tile is drawn when its own screen size is no bigger than its texel count, so closing on a body
## asks for smaller tiles and more of them — and never for fewer.
func _test_the_law(h) -> void:
	var earth := 6.371e6
	var pixel := 1.2966806e-3
	var eye := Vector3(1.0, 0.0, 0.0)
	var counts: Array = []
	var depths: Array = []
	print("    altitude      tiles   levels      (budget %d, %d texels a tile)" % [
		SpacesimSurfaceTiles.MAX_TILES, SpacesimSurfaceTiles.TILE_TEXELS
	])
	for altitude in [2.0e6, 1.0e6, 2.0e5, 5.0e4, 1.0e4]:
		var tiles := SpacesimSurfaceTiles.select(
			earth, earth + altitude, eye, pixel, 640
		)
		var deepest := 0
		var shallowest := 99
		for tile in tiles:
			deepest = maxi(deepest, int(tile[0]))
			shallowest = mini(shallowest, int(tile[0]))
		counts.append(tiles.size())
		depths.append(deepest)
		print("    %-12s  %-7d %d..%d" % [
			"%.0f km" % (altitude / 1000.0), tiles.size(), shallowest, deepest
		])
		h.check(tiles.size() > 0, "there are tiles to draw from %.0f km up" % (altitude / 1000.0))
		h.check(tiles.size() <= SpacesimSurfaceTiles.MAX_TILES,
			"and never more than the table holds (%d)" % tiles.size())

	# **A stack, not a cut, so the count is not the monotone thing — the DEPTH is.** Each level up covers a quarter
	# of the area, so a ring holds about the same number of tiles whatever the altitude; what changes as the eye
	# closes is how many rings there are and how deep the finest one goes.
	var deeper := true
	for index in range(1, depths.size()):
		if depths[index] < depths[index - 1]:
			deeper = false
	h.check(deeper, "closing in asks for at least as deep a finest ring (depths %s)" % str(depths))
	h.check(int(depths[depths.size() - 1]) - int(depths[0]) >= 4,
		"and by several levels between 2,000 km and 10 km (%d -> %d)" % [depths[0], depths[depths.size() - 1]])

	# A distance at or inside the surface has no visible cap, and a nonsense pixel angle has no law.
	h.check(SpacesimSurfaceTiles.select(earth, earth, eye, pixel, 640).is_empty(),
		"an eye at the surface draws no tiles")
	h.check(SpacesimSurfaceTiles.select(earth, earth * 3.0, eye, 0.0, 640).is_empty(),
		"and neither does a zero pixel angle")

	# **A tile must beat the map it would sit on** — a second texture showing what is already there is not a tile,
	# it is a waste. The first version of this walk emitted the whole map as one tile from 21,448 km.
	var tiles_wide := SpacesimSurfaceTiles.select(earth, earth + 2.1e7, eye, pixel, 640)
	var beats_the_map := tiles_wide.size() > 0
	for tile in tiles_wide:
		if float(SpacesimSurfaceTiles.TILE_TEXELS) * float(1 << int(tile[0])) <= 640.0:
			beats_the_map = false
	h.check(beats_the_map, "from 21,000 km every tile beats the 640 map it sits on (%d tiles: %s)" % [
		tiles_wide.size(), str(tiles_wide)
	])


## **The selection is a partition of the visible cap**: no two tiles overlap, every one is inside the map, and the
## tile under the eye is at least as deep as one out at the limb.
func _test_the_selection(h) -> void:
	var earth := 6.371e6
	var pixel := 1.2966806e-3
	var eye := Vector3(1.0, 0.0, 0.0)
	var tiles := SpacesimSurfaceTiles.select(earth, earth + 5.0e4, eye, pixel, 640)

	var inside := true
	var rects: Array = []
	for tile in tiles:
		var rect := SpacesimSurfaceTiles.rect_of(int(tile[0]), int(tile[1]), int(tile[2]))
		rects.append(rect)
		if rect.x < 0.0 or rect.y < 0.0 or rect.z > 1.0 or rect.w > 1.0:
			inside = false
	h.check(inside, "every tile's rectangle is inside the map")

	# **A stack is nested by design, so overlap is the point** — a finer ring must sit inside the coarser one it is
	# drawn over. What has to hold is that no two tiles at the SAME level are the same tile, that the levels are
	# contiguous ascending (coarse first, which is the order the shader composites in), and that each ring's reach
	# shrinks as the level rises.
	var seen := {}
	var duplicates := 0
	for tile in tiles:
		var key := "%d/%d/%d" % [int(tile[0]), int(tile[1]), int(tile[2])]
		if seen.has(key):
			duplicates += 1
		seen[key] = true
	h.check(duplicates == 0, "no tile is selected twice (%d)" % duplicates)

	var levels: Array = []
	for tile in tiles:
		if levels.is_empty() or levels[levels.size() - 1] != int(tile[0]):
			levels.append(int(tile[0]))
	var ascending := true
	for index in range(1, levels.size()):
		if levels[index] != levels[index - 1] + 1:
			ascending = false
	h.check(ascending, "the rings are contiguous and coarse first (%s)" % str(levels))

	# Each ring's reach, as the largest angle from the eye's direction to a tile centre in it — it must shrink with
	# the level, or the stack is not nested and a fine ring would not sit inside the coarse one.
	var reach: Array = []
	for level in levels:
		var widest := 0.0
		for tile in tiles:
			if int(tile[0]) != level:
				continue
			var rect := SpacesimSurfaceTiles.rect_of(level, int(tile[1]), int(tile[2]))
			var centre: Vector3 = SpacesimSurfaceTiles.direction_of(
				(rect.x + rect.z) * 0.5, (rect.y + rect.w) * 0.5)
			widest = maxf(widest, eye.angle_to(centre))
		reach.append(widest)
	var nested := true
	for index in range(1, reach.size()):
		if reach[index] > reach[index - 1] + SpacesimSurfaceTiles.tile_extent(levels[index]):
			nested = false
	h.check(nested, "and every ring reaches less far than the one under it (%s)" % str(reach))

	# **Where the eye is looking is where the detail goes.** The tile containing the sub-eye point against the
	# deepest tile at the limb: the budget must be spent under the eye, not on the horizon.
	var under := -1
	var at_limb := 99
	for tile in tiles:
		var rect := SpacesimSurfaceTiles.rect_of(int(tile[0]), int(tile[1]), int(tile[2]))
		var centre := SpacesimSurfaceTiles.direction_of((rect.x + rect.z) * 0.5, (rect.y + rect.w) * 0.5)
		if centre.dot(eye) > 0.999:
			under = maxi(under, int(tile[0]))
		if centre.dot(eye) < 0.5:
			at_limb = mini(at_limb, int(tile[0]))
	h.check(under >= 0, "the tile under the eye is in the selection")
	h.check(at_limb == 99 or under >= at_limb,
		"and it is at least as fine as one out at the limb (%d against %s)" % [under, str(at_limb)])


## **The gate**: the walk re-runs when the answer can change, and not because a frame happened. The two faults it
## exists to prevent are a walk that re-runs on an eye twitch and one that says "nothing moved" through a descent —
## `log(d/R)` is flat near the ground, which is why the distance is compared as a ratio.
func _test_the_gate(h) -> void:
	var earth := 6.371e6
	var pixel := 1.2966806e-3
	var eye := Vector3(1.0, 0.0, 0.0)
	h.check(SpacesimSurfaceTiles.walk_is_due(0.0, Vector3.ZERO, 0.0, 0, earth * 2.0, eye, pixel, 640),
		"a walk that has never run is due")
	h.check(not SpacesimSurfaceTiles.walk_is_due(earth * 2.0, eye, pixel, 640, earth * 2.0, eye, pixel, 640),
		"a still eye is not due — no frame ever asks for a walk")
	h.check(not SpacesimSurfaceTiles.walk_is_due(
		earth * 2.0, eye, pixel, 640, earth * 2.0 * 1.05, eye, pixel, 640),
		"nor is a distance change of a twentieth")
	h.check(SpacesimSurfaceTiles.walk_is_due(
		earth * 2.0, eye, pixel, 640, earth * 2.0 * 1.2, eye, pixel, 640),
		"but a fifth is")
	h.check(SpacesimSurfaceTiles.walk_is_due(earth * 2.0, eye, pixel, 640, earth * 2.0, eye, pixel * 1.5, 640),
		"a different render resolution is due at once")
	h.check(not SpacesimSurfaceTiles.walk_is_due(
		earth * 2.0, eye, pixel, 640, earth * 2.0, Vector3(1.0, 1.0e-5, 0.0).normalized(), pixel, 640),
		"an eye twitch is not due")
	h.check(SpacesimSurfaceTiles.walk_is_due(
		earth * 2.0, eye, pixel, 640, earth * 2.0, Vector3(1.0, 0.4, 0.0).normalized(), pixel, 640),
		"and a real swing is")
	h.check(SpacesimSurfaceTiles.walk_is_due(
		earth * 2.0, eye, pixel, 256, earth * 2.0, eye, pixel, 640),
		"a rung landing under the eye is due, because the tiles must beat a finer map")
