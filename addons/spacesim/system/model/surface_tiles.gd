class_name SpacesimSurfaceTiles
extends RefCounted
## **The map's raster as a CLIPMAP** — nested rings of ever-finer tiles, all resident, drawn coarse to fine.
##
## The whole-body map answers *how fine should the planet be?* for one raster covering everything. Past its
## ceiling that answer is fixed and the ground under the eye wants more, so the map is refined exactly where the
## eye is looking: the uv rectangle is split into four, the walk descends nearest-first, and each tile is baked
## through the same pass the rungs use. **The law is the mesh's law, one inversion up**: a tile is drawn when a
## pixel is not smaller than a texel, and refined when it is.
##
## ## The quantities
##
## A tile at `level` covers `1/2^level` of the map in each axis, so a tile of `TILE_TEXELS` gives a texel of
## `uv_extent / TILE_TEXELS`. On a sphere of radius `R` that texel has a linear size of about
## `R * uv_angle / TILE_TEXELS`, and seen from the eye at distance `d` it subtends `R * uv_angle / (d * TILE_TEXELS)`
## radians — so **the tile is fine enough when its own screen size is no bigger than its texel count**:
##
##     screen_pixels(tile) = R * extent / (d * pixel_angle)   ≤   TILE_TEXELS
##
## `extent` is the tile's largest corner-to-corner chord on the unit sphere, which is its angular extent to
## within a percent at the sizes a tile ever has. **`d` is the distance to the tile's NEAREST corner**, not to
## the body's centre — the lesson `SpacesimPatches` paid for: the patch under the eye is a few kilometres away
## while the body is six thousand, and a centre distance stops the recursion dead.
##
## **And a second condition, which is the one that makes a tile worth baking at all: it must be finer than the
## map it would sit on.** A tile covers `1/2^level` of the map, so it carries `TILE_TEXELS * 2^level` texels over a
## region the whole-body map covers with `base_width / 2^level` of its own — and a tile that does not beat that is a
## second texture showing what is already there. Without this test the walk emits the *whole map* as one tile from
## a few thousand kilometres out, which is both a wasted bake and a coarser picture than the map underneath. The
## first run of this walk did exactly that, and the probe that caught it printed one tile at 21,448 km.
##
## **Nothing here draws, bakes or knows a body.** It is arithmetic on a radius, a distance and a pixel angle, so
## the walk can be checked headlessly — which is the only way it can be checked at all, because a bake needs a
## rendering device.

## Texels on a tile's side. **512 is the cost knob**: one tile is 512 KiB of `R16F`, and the table holds
## `MAX_TILES` of them, so the whole tiled raster is 16 MiB whatever the eye does.
const TILE_TEXELS := 512

## **The table the shader can hold.** 32 tiles is 8 Mtexel of near field — enough to be a texel per pixel over a few
## hundred kilometres of ground and not enough over a few thousand at low altitude, where the shader's own detail
## ladder carries what the map cannot. That is the intended split, not a shortfall: a whole-body tiling of the ground
## under a 10 km descent would be some 700 Mtexel.
const MAX_TILES := 32

## **The whole table, and there is no reserve any more.** The reserve existed because a *cut* had to hold the tiles
## it was replacing until their children landed, or a region fell back to the whole-body map and the ground
## *softened then sharpened* — Evert, on the F4/F6 flight: *"a couple of cases where a texture refinement was drawn,
## and then reverted."* **A stack has no such transition**: the coarser ring is wanted anyway, so there is nothing to
## reserve for and the budget is the table.
const TILE_BUDGET := MAX_TILES

## **Tiles per ring.** The clipmap invariant is that each level up covers a quarter of the area at twice the
## resolution, so a ring holds roughly the same number of tiles at every level — this one number sets the ring's
## size, and the stack's total is `RING_TILES × the number of rings`. Four is enough for the coarsest ring to cover
## the cap at the altitudes the near field starts, and it leaves the table room for six or seven rings.
const RING_TILES := 4

## **Half-width, in tiles, of the uv window a ring is searched in.** The cone's uv radius is `limit · 2^L / TAU`, and
## `limit` halves as the level doubles, so this window covers every ring at every depth — see `_ring`.
const RING_WINDOW := 3

## How deep the uv tree may go before the walk stops on its own. `2^12` of the map in each axis is a texel
## finer than any display can resolve at the altitudes the budget allows, so this is a guard rather than a
## limit that binds.
const MAX_LEVEL := 12


## A tile's rectangle in uv, as `(u0, v0, u1, v1)`. The shader's `equirect()` is the authority on the mapping,
## and this is its inverse's rectangle.
static func rect_of(level: int, x: int, y: int) -> Vector4:
	var span := 1.0 / float(1 << clampi(level, 0, MAX_LEVEL))
	return Vector4(float(x) * span, float(y) * span, float(x + 1) * span, float(y + 1) * span)


## **Whether one tile's rectangle contains another's** — how the walk tells an ancestor from an unrelated tile when
## it decides what may be let go.
static func rect_contains(outer: Vector4, inner: Vector4) -> bool:
	const EPSILON := 1.0e-6
	return (inner.x >= outer.x - EPSILON and inner.y >= outer.y - EPSILON
		and inner.z <= outer.z + EPSILON and inner.w <= outer.w + EPSILON)


## **The direction a uv pixel points at** — the inverse of the shaders' `equirect()`:
## `u = 0.5 + atan(z, x)/TAU`, `v = 0.5 - asin(y)/PI`.
##
## It exists so the walk measures the *sphere* and not the map: an equirect's rectangles are wildly unequal near
## the poles, and a walk that measured uv distance would refine the equator and starve the caps.
static func direction_of(u: float, v: float) -> Vector3:
	var longitude := (u - 0.5) * TAU
	var latitude := (0.5 - v) * PI
	var ring := cos(latitude)
	return Vector3(ring * cos(longitude), sin(latitude), ring * sin(longitude))


## **The tiles worth drawing for one eye, as a stack of nested rings** — coarse first, then every ring finer.
##
## ## Why a stack and not a cut
##
## The first version selected a **quadtree cut**: a partition of the visible cap in which each region was covered by
## exactly one tile, the one whose texel was about a pixel. It worked, and it needed three pieces of machinery to be
## correct — a cross-fade at every tile edge (two rasters of the field had to *agree* at a boundary), an ancestor
## hold so a region did not fall back to the whole-body map while its children baked (the pulse), and a
## "must beat the map" gate. **A stack makes all three unnecessary**: a finer ring is drawn *over* a coarser one, so
## nothing has to agree with anything, nothing falls into a hole, and a level change is just another layer.
##
## ## The shape
##
## Level `k` of the stack is a ring of tiles at quadtree level `L`, and the rings nest: **each level up halves its
## angular radius**, so it covers a quarter of the previous level's area at twice the resolution. A tile at level
## `L+1` has a quarter of the area of one at `L`, so a ring holds *the same number of tiles at every level* — that
## invariant is what makes the stack affordable in a fixed table, and it is why `per_ring` is the only size knob.
##
## **Each ring is a cone around the eye's own direction**, in tiles whose centre falls inside it. The cone is the
## clipmap's clip: what falls outside a ring is drawn by the ring below it, and what falls outside the coarsest ring
## is drawn by the whole-body map, which is always there underneath.
##
## `eye_direction` is the unit vector from the body's centre toward the eye and `distance` is how far the eye is
## from that centre. The result is a list of `[level, x, y]`, **coarse first** — the order the shader composites in.
static func select(
	radius: float, distance: float, eye_direction: Vector3, pixel_angle: float,
	base_width: int, per_ring: int = RING_TILES, budget: int = TILE_BUDGET
) -> Array:
	var tiles: Array = []
	if radius <= 0.0 or distance <= radius or pixel_angle <= 0.0 or budget <= 0 or per_ring <= 0:
		return tiles
	var to_eye := eye_direction.normalized()
	# **The horizon, exactly**: a point at unit direction `u` is visible from `distance` along `v` if and only if
	# `dot(u, v) >= R/d`. Widened per tile by its own extent, because a tile whose centre is over the limb can
	# still have visible ground in it — the same correction the patch walk needed.
	var horizon := acos(clampf(radius / distance, -1.0, 1.0))
	# The eye's height, and the floor for any tile's distance: the eye is outside the body, so no part of the
	# sphere is nearer than this. Without it the recursion never converges under the eye.
	var altitude := maxf(distance - radius, 1.0)
	var camera := to_eye * distance
	# **Where the stack starts**: the first level whose tiles beat the map (`TILE_TEXELS · 2^L > base_width`),
	# because below that a tile is a second raster showing what the map already has.
	var first_level := 0
	while float(TILE_TEXELS) * float(1 << first_level) <= float(base_width):
		first_level += 1
	# **And where it ends**: the level whose tile is already no bigger on screen than its own texel count, at the
	# nearest ground the eye can see. Deeper than that is a tile finer than a pixel.
	# **The first level that satisfies the law**, not the one before it: `screen(level) ≤ TILE_TEXELS` is the test a
	# ring has to pass, so the stack ends *on* the level that passes rather than one short of it.
	var last_level := first_level
	while last_level < MAX_LEVEL \
			and radius * tile_extent(last_level) / altitude / pixel_angle > float(TILE_TEXELS):
		last_level += 1
	var rings := last_level - first_level + 1
	var per_kind := maxi(1, budget / maxi(rings, 1))
	for level in range(first_level, last_level + 1):
		# **Half the angular radius per level**: a quarter of the area, at twice the resolution — the clipmap's
		# own invariant, and the reason each ring can hold the same number of tiles.
		var limit := horizon * pow(0.5, float(level - first_level))
		var ring := _ring(radius, camera, to_eye, horizon, level, limit, pixel_angle,
			float(per_kind), float(TILE_TEXELS))
		# **Coarse first**, so the shader can composite in list order and a finer ring overwrite a coarser one.
		tiles.append_array(ring)
	return tiles


## **One ring**: the tiles at `level` whose centre lies within `limit` of the eye's own direction, nearest first.
##
## **The window is small and it does not grow with depth**, which is the clipmap invariant paying off: the cone's
## uv window is `limit · 2^L / TAU` and `limit` halves as `2^L` doubles, so a ±`RING_WINDOW` tile window around the
## eye's uv covers every ring at every depth. A walk that enumerated the quadtree instead re-did the same work at
## every level for no gain.
static func _ring(
	radius: float, camera: Vector3, to_eye: Vector3, horizon: float,
	level: int, limit: float, pixel_angle: float, per_ring: float, texels: float
) -> Array:
	var span := 1 << level
	var uv := direction_to_uv(to_eye)
	var centre_u := int(floor(uv.x * float(span)))
	var centre_v := int(floor(uv.y * float(span)))
	var candidates: Array = []
	for dy in range(-RING_WINDOW, RING_WINDOW + 1):
		for dx in range(-RING_WINDOW, RING_WINDOW + 1):
			var x := centre_u + dx
			var y := centre_v + dy
			# **The poles and the seam wrap**: `u` is longitude, so it is periodic; `v` is not.
			x = posmod(x, span)
			if y < 0 or y >= span:
				continue
			var rect := rect_of(level, x, y)
			var centre: Vector3 = direction_of((rect.x + rect.z) * 0.5, (rect.y + rect.w) * 0.5)
			if centre.dot(to_eye) < cos(minf(horizon + tile_extent(level), PI)):
				continue
			if centre.dot(to_eye) < cos(minf(limit + tile_extent(level), PI)):
				continue
			var extent := tile_extent(level)
			var nearest := INF
			for corner_u in [rect.x, rect.z]:
				for corner_v in [rect.y, rect.w]:
					var corner: Vector3 = direction_of(corner_u, corner_v)
					nearest = minf(nearest, (camera - corner * radius).length())
			var to_tile := maxf(nearest, maxf(camera.length() - radius, 1.0))
			var screen := radius * extent / to_tile / pixel_angle
			candidates.append({"tile": [level, x, y], "distance": to_tile, "screen": screen})
	# Nearest first, and never a tile finer than a pixel — the ring's own band-limit.
	candidates.sort_custom(func(a, b): return float(a["distance"]) < float(b["distance"]))
	var ring: Array = []
	for candidate in candidates:
		if ring.size() >= int(per_ring):
			break
		ring.append(candidate["tile"])
	return ring


## **A tile's largest corner-to-corner chord on the unit sphere, at `level`** — its angular size to within a percent
## at anything this walk selects, which is what the screen-size law is measured in.
static func tile_extent(level: int) -> float:
	var span := 1.0 / float(1 << clampi(level, 0, MAX_LEVEL))
	# **Measured at the equator, centred**, which is where a tile is its largest: an equirect's tiles collapse
	# towards the poles, so a size taken at the poles would say a level is finer than it is over most of the body.
	var half := span * 0.5
	var a := direction_of(0.5 - half, 0.5 - half)
	var b := direction_of(0.5 + half, 0.5 + half)
	return a.distance_to(b)


## The uv of a direction — `equirect()`'s inverse's other half, and the one place a level's grid meets a direction.
static func direction_to_uv(direction: Vector3) -> Vector2:
	return Vector2(
		0.5 + atan2(direction.z, direction.x) / TAU,
		0.5 - asin(clampf(direction.y, -1.0, 1.0)) / PI
	)


## A child's distance from the eye, **for the ordering only** — the law itself uses the nearest corner, but the
## stack only has to be ordered, and the centre is cheap.
static func _child_distance(child: Array, radius: float, camera: Vector3) -> float:
	var rect: Vector4 = rect_of(int(child[0]), int(child[1]), int(child[2]))
	var centre: Vector3 = direction_of((rect.x + rect.z) * 0.5, (rect.y + rect.w) * 0.5)
	return camera.distance_to(centre * radius)


## **Whether the walk has to run again at all** — the gate, of the same shape as `SpacesimPatches.walk_is_due`
## and for the same reason: the answer is a pure function of the distance, the eye's direction and the pixel
## angle, so it needs recomputing only when one of them has moved enough to change a boundary. A walk that runs
## because a frame happened is work with no need, and this one is not free.
##
## **A tenth on the distance** is the loose end the patch walk measured: the selection is quantised by the tree,
## so a smaller change cannot move a tile boundary. **Half the finest tile** is the equivalent for the eye's
## swing, and the pixel angle is compared exactly because it changes with the render resolution rather than
## continuously.
static func walk_is_due(
	last_distance: float, last_direction: Vector3, last_pixel: float, last_base_width: int,
	distance: float, direction: Vector3, pixel_angle: float, base_width: int
) -> bool:
	if last_distance <= 0.0 or last_direction.is_zero_approx() or last_pixel <= 0.0:
		return true
	if not is_equal_approx(pixel_angle, last_pixel):
		return true
	# **The width in hand counts as movement**, because it changes the answer: a tile has to beat the map it sits
	# on, so a rung landing under the eye makes the previous selection too coarse. The trigger is a change in what
	# is needed, and this is one that no eye movement caused.
	if base_width != last_base_width:
		return true
	# **The patch walk's own constant, not a copy of it** — see `SpacesimPatches.LOG_TENTH`.
	if absf(log(distance / last_distance)) > SpacesimPatches.LOG_TENTH:
		return true
	# Half of the finest tile the budget can be spending, as the angle the eye may swing before the tile under it
	# changes: a tile at `MAX_LEVEL` is `TAU/2^MAX_LEVEL` of the map across.
	var finest := TAU / pow(2.0, float(MAX_LEVEL)) * 0.5
	return last_direction.angle_to(direction) > finest


