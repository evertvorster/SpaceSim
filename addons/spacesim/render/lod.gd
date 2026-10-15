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


## The triangles in a level. Exact, and an integer: each subdivision turns one triangle into four.
static func triangles_at(level: int) -> int:
	return ICO_BASE_TRIANGLES << (2 * clampi(level, 0, MAX_LEVEL))
