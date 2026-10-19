class_name SpacesimSurfaceTiles
extends RefCounted
## **The map's raster as a quadtree over uv** — the near field subdivides under the eye, as the mesh does.
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

## **The table the shader can hold, and therefore the walk's budget.** At 32 tiles the near field is
## 8 Mtexel — enough to be a texel per pixel over a few hundred kilometres of ground and not enough over a few
## thousand at low altitude, where the shader's own detail ladder carries what the map cannot. That is the
## intended split, not a shortfall: a whole-body tiling of the ground under a 10 km descent would be some
## 700 Mtexel.
const MAX_TILES := 32

## How deep the uv tree may go before the walk stops on its own. `2^12` of the map in each axis is a texel
## finer than any display can resolve at the altitudes the budget allows, so this is a guard rather than a
## limit that binds.
const MAX_LEVEL := 12


## A tile's rectangle in uv, as `(u0, v0, u1, v1)`. The shader's `equirect()` is the authority on the mapping,
## and this is its inverse's rectangle.
static func rect_of(level: int, x: int, y: int) -> Vector4:
	var span := 1.0 / float(1 << clampi(level, 0, MAX_LEVEL))
	return Vector4(float(x) * span, float(y) * span, float(x + 1) * span, float(y + 1) * span)


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


## **The tiles worth drawing for one eye**, nearest first, at most `budget` of them.
##
## `eye_direction` is the unit vector from the body's centre toward the eye and `distance` is how far the eye is
## from that centre. The result is a list of `[level, x, y]`, and it **partitions the visible cap**: every tile
## is a leaf of one tree, so no two overlap and a pixel is covered at most once — the base map underneath is what
## a pixel falls back to when the budget stopped the walk above it.
static func select(
	radius: float, distance: float, eye_direction: Vector3, pixel_angle: float,
	base_width: int, budget: int = MAX_TILES
) -> Array:
	var tiles: Array = []
	if radius <= 0.0 or distance <= radius or pixel_angle <= 0.0 or budget <= 0:
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
	var stack: Array = [[0, 0, 0]]
	while not stack.is_empty():
		var tile: Array = stack.pop_back()
		var level := int(tile[0])
		var x := int(tile[1])
		var y := int(tile[2])
		var rect := rect_of(level, x, y)
		# The four corners, on the sphere: the extent is the largest chord, which is the tile's angular size to
		# within a percent at anything this walk recurses into.
		var corners: Array = [
			direction_of(rect.x, rect.y), direction_of(rect.z, rect.y),
			direction_of(rect.x, rect.w), direction_of(rect.z, rect.w),
		]
		var extent := 0.0
		var nearest := INF
		for a in corners:
			for b in corners:
				extent = maxf(extent, a.distance_to(b))
			nearest = minf(nearest, (camera - a * radius).length())
		# **The tile's centre direction is its uv midpoint, NOT the sum of its corners.** A root tile has two
		# corners at each pole, and that sum comes out as `(-1.2e-16, 0, 0)` — so normalising it amplifies rounding
		# noise into `(-1, 0, 0)`, the root tests as facing away from the eye, and the walk returns nothing at all.
		# The midpoint of a rectangle is well defined everywhere, including at the caps.
		var centre: Vector3 = direction_of((rect.x + rect.z) * 0.5, (rect.y + rect.w) * 0.5)
		if centre.dot(to_eye) < cos(minf(horizon + extent, PI)):
			continue
		var to_tile := maxf(nearest, altitude)
		var screen := radius * extent / to_tile / pixel_angle
		# **finer than the map in hand**, or there is nothing to gain: `TILE_TEXELS * 2^level` texels over the
		# region the whole-body map covers with `base_width / 2^level` of its own.
		var finer_than_base := float(TILE_TEXELS) * float(1 << level) > float(base_width)
		# **The budget is the table, and a full table simply stops.** What is left over falls back to the
		# whole-body map — which is always drawn underneath, so a refusal here is softness rather than a hole. The
		# selection is nearest-first, so what gets dropped is the far field, which is the cheap thing to lose.
		if tiles.size() >= budget:
			continue
		if level >= MAX_LEVEL or (screen <= float(TILE_TEXELS) and finer_than_base):
			if finer_than_base:
				tiles.append([level, x, y])
			continue
		# **Nearest last, because the stack pops from the back** — so the budget is spent under the eye rather
		# than on the limb, which is the whole point of refining where the eye is.
		var children: Array = [
			[level + 1, x * 2, y * 2], [level + 1, x * 2 + 1, y * 2],
			[level + 1, x * 2, y * 2 + 1], [level + 1, x * 2 + 1, y * 2 + 1],
		]
		children.sort_custom(
			func(a, b): return _child_distance(a, radius, camera) > _child_distance(b, radius, camera)
		)
		for child in children:
			stack.append(child)
	return tiles


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
	if absf(log(distance / last_distance)) > LOG_TENTH:
		return true
	# Half of the finest tile the budget can be spending, as the angle the eye may swing before the tile under it
	# changes: a tile at `MAX_LEVEL` is `TAU/2^MAX_LEVEL` of the map across.
	var finest := TAU / pow(2.0, float(MAX_LEVEL)) * 0.5
	return last_direction.angle_to(direction) > finest


## `log(1.1)`: a tenth, the same loose end the patch walk uses.
const LOG_TENTH := 0.09531017980432486
