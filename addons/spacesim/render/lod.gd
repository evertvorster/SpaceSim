class_name SpacesimLod
extends RefCounted
## How much of the view a body takes up, and what that is worth drawing.
##
## **The primitive is geometric error in pixels, not a triangle count.** A sphere approximated by facets
## departs from the true surface by the sagitta `R * phi^2 / 8`, so requiring that departure to project
## to at most `epsilon` pixels fixes a facet's angular width:
##
##     phi = sqrt(8 * epsilon * p * d / R)
##
## and, since the triangle count rises as `1/phi^2`, it rises as `R / (epsilon * p * d)` — in proportion
## to the body's screen radius. Which is "draw what is resolvable", as a formula, out of four inputs the
## engine already has: the body's angular size, the field of view, the render height, and a budget.
##
## **A scaling law, not a count.** The constant in [constant TRIANGLES_PER_SCREEN_RADIUS] is measured,
## not derived, and the real value of `epsilon` is a judgement that only a render settles. Numbers here
## choose a level; they are not defended to a third digit.
##
## **The silhouette is the only thing the mesh carries.** A sphere with per-vertex radial normals
## interpolates its normals *exactly* along facet edges — interpolation runs linearly between two correct
## normals, which is what the true normal does along a great-circle arc. Position is what the mesh
## approximates, so the visible error is the outline, at about `epsilon` pixels. Relief that does not
## change the silhouette belongs in the shader, which is where `body_surface` already puts it.
##
## Nothing here draws anything or knows a body — it is the arithmetic, so that what remains can be
## decided with no GPU and no meshes.

## Triangles in a level-0 icosphere, and the exact four-fold subdivision of every level after it:
## `20 * 4^k`. Levels 0 to 5 are what gets built — 27,300 triangles of shared mesh data for the whole
## engine, against ~16,000 per body before this — and level 6 is headroom.
const ICO_BASE_TRIANGLES := 20
const MAX_LEVEL := 6

## How far past a level's boundary a body must go before it changes level, as a fraction of that
## boundary.
##
## **Needed because the levels are discrete and the input is continuous.** A body sitting on a boundary
## whose screen radius is jittering by a pixel would swap meshes back and forth — a visible flicker and
## a write per frame. This is the same idea as `SpacesimTransitionRule` for frame bands: a decision
## boundary with a dead band. Ten percent is comfortably more than pixel jitter at the radii a boundary
## sits at (13.7 px and up) and far less than the 4x step between levels.
const HYSTERESIS_BAND := 0.1

## The constant in `N ~ c * screen_radius / epsilon`, and **it is measured from the built mesh rather
## than derived.** A level's relative sagitta times its triangle count converges to **5.8355** — 5.7963
## at level 3, 5.8334 at level 5 — and that product is exactly what makes the law honour the budget: at
## the screen radius where a level is chosen, its error comes to `epsilon` rather than a multiple of it.
##
## The derivation in the class comment gets the *shape* right and the constant wrong: it takes a facet's
## angular width from its solid angle, `phi = sqrt(4*pi/N)`, and the real width is about **1.93x** that,
## because a facet is a triangle whose corners lie on the sphere rather than a spherical cap. `5` was
## the first estimate of this and put the drawn error **1.17x over** the budget at every level — the
## sort of thing `tests/test_icosphere.gd` exists to catch, since it measures the product against the
## geometry and so cannot drift from this number.
const TRIANGLES_PER_SCREEN_RADIUS := 5.836


## A pixel's angular size in radians, at the **centre** of a perspective frame.
##
##     p = 2 * tan(fov/2) / H
##
## **`H` is the render target's height in PIXELS, not the canvas rect's.** `Viewport.get_visible_rect()`
## is the canvas in its own units, and the two part company the moment `video.aspect` is `keep`, where
## the canvas is letterboxed over a full-width 3D buffer. `Vector2(camera.get_viewport().size)` is the
## drawn size, and is what `SpacesimStarSky.update` and `game/main.gd` already use for the same reason.
##
## **This is the centre pixel, and a pixel further out subtends more** — by `1/cos^2` of the angle from
## the axis. The frame's *average* is `fov/H`, and the two agree only at a narrow field: at 1080p and 70
## degrees the centre pixel is 0.0743 degrees against an average of 0.0648. The law wants the pixel the
## silhouette is actually in, so it takes the centre one, and the difference is recorded in the tests
## rather than quietly absorbed.
static func pixel_angle(fov_degrees: float, render_height: float) -> float:
	if render_height <= 0.0:
		return 0.0
	return 2.0 * tan(deg_to_rad(clampf(fov_degrees, 1.0, 179.0) * 0.5)) / render_height


## A body's angular radius as seen from a distance, in radians: `asin(R / d)`.
##
## **One quantity, several consumers, and two of them want a diameter.** This radius serves the drawn
## disc, the LOD law, a body's share of the view (`view_luminance_at`, and through it the exposure), the
## penumbra of a body's shadow, and total-versus-annular — while Godot's `light_angular_distance` wants
## an angular **diameter in degrees** (the engine's own doc gives the Sun from Earth as "approximately
## 0.5"), so `SpacesimStarLight.aim_at` passes it `rad_to_deg(2 * angular_radius(R, d))`.
##
## **Deriving it rather than stating it is the whole point**, and it is the same argument as the light's
## strength: a value fixed at one distance is wrong at every other. The constant this replaced was the
## Sun's disk at 1 au, which is right there, 2.6x too small at Mercury and 30x too large at Neptune.
static func angular_radius(radius: float, distance: float) -> float:
	if radius <= 0.0 or distance <= 0.0:
		return 0.0
	return asin(clampf(radius / distance, 0.0, 1.0))


## The body's silhouette radius **in pixels**, for a given centre pixel angle.
##
## The projection rather than the linearisation: a point `theta` off the axis lands `tan(theta) / p`
## pixels from it. At the sizes the thresholds care about — one to four pixels — the two are
## indistinguishable; they differ by a fifth once a body stops fitting in the frame, where nothing
## depends on the digit.
##
## **It does not decide whether the body is drawn.** That is the cull's business, and the two must stay
## uncoupled: a body that is not drawn still contributes to the exposure, and still has a marker.
static func screen_radius_pixels(angular_radius: float, pixel_angle: float) -> float:
	if pixel_angle <= 0.0:
		return 0.0
	return tan(clampf(angular_radius, 0.0, PI * 0.5)) / pixel_angle


## The icosphere level for a screen radius at an error budget in pixels, quantised to the levels that
## can be built.
##
## **Quantised, because the answer has to be a pointer assignment.** Levels are built once and shared by
## every body, so changing level costs nothing at all; a continuous answer would rebuild a mesh every
## frame, which is worse than the problem it solves. Hysteresis on the crossing belongs to the caller —
## `SpacesimTransitionRule` is the established shape for a decision boundary with a dead band.
##
## `epsilon` is the error budget in pixels, and it is the **caller's** to supply — a setting while it is
## being judged by eye by flying, frozen to a constant once a render set justifies the number. Taking it
## as a parameter rather than reading it here is what keeps this a pure function that a test can call.
static func level_for_screen_radius(screen_radius: float, epsilon: float) -> int:
	if screen_radius <= 0.0 or epsilon <= 0.0:
		return 0
	var wanted := TRIANGLES_PER_SCREEN_RADIUS * screen_radius / epsilon
	var level := 0
	while level < MAX_LEVEL and float(triangles_at(level)) < wanted:
		level += 1
	return level


## The screen radius at which a level **gives way to the next one** — where the finer level's triangle
## count is first met, so it is the coarser level's own exit point. `level_exit(0, 4)` is 13.7 px, which
## is where level 1 begins.
static func level_exit(level: int, epsilon: float) -> float:
	return float(triangles_at(level)) * epsilon / TRIANGLES_PER_SCREEN_RADIUS


## `level_for_screen_radius` with a dead band, so a body sitting on a boundary does not flicker between
## two meshes.
##
## A change of more than one level is taken at once — that is flying, not jitter, and stepping through
## the levels one frame at a time would make a fast approach crawl. A single-level change is held off
## until the screen radius is `band` past the crossing it crossed, and the crossing between two adjacent
## levels is the **coarser** one's exit — `mini`, because the band has to be measured against the same
## radius whichever direction the body is travelling in.
static func level_with_hysteresis(
	current: int, screen_radius: float, epsilon: float, band: float = HYSTERESIS_BAND
) -> int:
	var target := level_for_screen_radius(screen_radius, epsilon)
	if absi(target - current) != 1:
		return target
	var crossing := level_exit(mini(target, current), epsilon)
	if band > 0.0:
		if target > current and screen_radius < crossing * (1.0 + band):
			return current
		if target < current and screen_radius > crossing * (1.0 - band):
			return current
	return target


## The triangles in a level. Exact, and an integer: each subdivision turns one triangle into four.
static func triangles_at(level: int) -> int:
	return ICO_BASE_TRIANGLES << (2 * clampi(level, 0, MAX_LEVEL))

## How much larger an air shell's error budget is than a body's.
##
## **An atmosphere is soft** (Evert, 2026-10-15): its outer edge is where the density reaches nothing, so
## there is no hard line for a facet to break, and a silhouette error several times a planet's is not
## visible on one. The shell therefore uses the same law with a looser budget rather than a different
## mechanism — and the budget still follows the trim, so one number keeps governing both.
##
## **Suspected at 4, not measured.** The way to judge it is to fly out from a body and watch where its
## limb ring starts to read as a polygon; the ring is the only hard-ish edge the shell has.
const SHELL_BUDGET_SOFTNESS := 4.0

## The screen thickness, in pixels, at which an air shell's **limb ring** is too thin to be worth
## drawing.
##
## A shell is a fill-bound shader — 128 samples per pixel it covers, the heaviest thing here — so its
## LOD is *draw or not draw*, and the only question worth asking is whether it puts anything on the
## screen. From outside, what it puts there is the ring between `radius` and `radius + sky_top`; below a
## pixel of thickness that is a smear across one pixel rather than a ring, and it is bought with the
## whole march. Earth's ring comes to 4.9 px at 19,000 km, 319 px at 400 km, and **0.05 px at 750 Mm**,
## so the planet's own limb stops being drawn somewhere around 77,000 km — where its disc is 13 px and a
## 0.2 px ring around it was never going to be seen.
##
## **Suspected at one pixel, not measured**, like the point tier's 4. It wants looking at in flight: the
## trade it makes is a sub-pixel limb tint for the march, so the way to judge it is to fly out from a
## body and watch where its ring stops reading.
const ATMOSPHERE_RING_MIN_PIXELS := 1.0

## The screen radius below which a body **stops being geometry and becomes a point of light**.
##
## Below a few pixels a shaded disc and a flat blob are indistinguishable, so a mesh buys nothing — and a
## mesh *smaller than a pixel* aliases badly, appearing and disappearing as it crosses pixel centres.
## **Four is a suspected number, not a measured one**: it is the value the mesh LOD plan's §3 proposes,
## and it wants looking at in flight the way `lod.error_budget` did. Unlike the error budget it is not a
## setting, because it is not a quality trim — it is where one representation gives way to another, and
## a player who moved it would be moving a boundary rather than a budget.
const POINT_TIER_SCREEN_RADIUS := 4.0


## **The floor under a cloud deck's tessellation, and it is NOT a screen-size law.**
##
## Every other level here is chosen so a facet's deviation projects under a pixel budget. A deck cannot be:
## it is a skin a kilometre or two above the ground, so a facet that sags further than its own altitude
## puts the shell **inside the planet**, and what survives is a honeycomb of corners. That is measured
## rather than reasoned — the same shell drawn at 20x its altitude was a proper cloud deck with soft
## edges and large gaps, and at its real 1.5 km it was a honeycomb.
##
## So the constraint is geometric and holds at every distance: `radius * relative_sagitta(level)` must
## stay under the altitude. **The cost is fixed and can be large** — Earth's 1.5 km deck needs level 6,
## about 82,000 triangles, where the body's own disc at the same distance is a few thousand. That is the
## honest price of a thin shell over a sphere, and it is why this is its own law rather than a borrowed
## one.
static func deck_level(radius: float, altitude: float) -> int:
	if radius <= 0.0 or altitude <= 0.0:
		return 0
	var allowed := altitude / radius
	# **`MAX_LEVEL`, not `built_levels()`** — that one reports how many are *cached so far*, so early in a
	# build it reads as a low ceiling and the floor comes out as whatever happens to exist. It did: the
	# first version returned level 2 and the test caught it at 113 km of sag.
	for level in range(MAX_LEVEL, -1, -1):
		if SpacesimIcosphere.relative_sagitta(level) <= allowed:
			return level
	return MAX_LEVEL


## **The screen radius an air shell's tessellation is judged at.**
##
## **From outside** the shell's visible edge is its outer limb, so it is the ordinary silhouette:
## `tan(asin(R/d)) / p` at `radius + sky_top`, where the ring ends.
##
## **From inside there is no edge at all** — the whole frame is the shell — and what tessellation moves
## is not a boundary but the *direction of every ray the shader casts*: `body_atmosphere` takes
## `normalize(VERTEX)`, the interpolated position on the triangle, as its ray. A facet's surface is flat
## where the true shell curves, so the ray is off by the facet's tilt, and a shell that fills the frame
## is worth tessellating for **direction** accuracy even though it has no silhouette to break. Returning
## `1 / p` for that case is "unit angular size" — a radius of one radian — which the law reads as a body
## filling the frame, and it asks for the finest level there is.
static func shell_screen_radius(radius: float, sky_top: float, distance: float, pixel: float) -> float:
	if distance < radius + sky_top:
		return 1.0 / maxf(pixel, 1.0e-9)
	return screen_radius_pixels(angular_radius(radius + sky_top, distance), pixel)


## The air shell's visible **ring thickness** in pixels: its outer limb less the planet's own limb.
##
## This is the quantity [constant ATMOSPHERE_RING_MIN_PIXELS] is compared against, and it is the whole
## of the shell's draw-or-not decision from outside — see that constant for why the ring is the only
## thing that matters and what it measures at several distances.
static func shell_ring_pixels(radius: float, sky_top: float, distance: float, pixel: float) -> float:
	var outer := screen_radius_pixels(angular_radius(radius + sky_top, distance), pixel)
	var inner := screen_radius_pixels(angular_radius(radius, distance), pixel)
	return outer - inner
