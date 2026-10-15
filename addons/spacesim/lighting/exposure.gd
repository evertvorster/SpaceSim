class_name SpacesimExposure
extends RefCounted
## How bright the camera treats the scene.
##
## **Computed from the physics, not metered from the image.** Godot's auto-exposure averages the
## frame and drives that average toward middle grey, and it has no metering mode — probed on 4.7.2,
## the API is `auto_exposure_enabled`, `_scale`, `_speed` and an EV clamp, and nothing else. So on a
## frame that is mostly empty space with one lit body in it, it has exactly one way to reach its
## target: raise exposure until that body is white. Which is what it did.
##
## We do not have to guess, because the illuminance at the observer is already derived. The exposure
## that puts a lit body at middle grey is therefore arithmetic — and unlike image-based metering it is
## deterministic, it cannot be fooled by an empty frame, it does not pump, and it can be tested
## headlessly.
##
## On the emitter: the star is a *source*, not a reflector. It cannot be brought into range without
## making everything else black, so it is allowed to clip and `glow_*` handles how that reads. Nothing
## here tries to expose for it.

## Godot's own reference for a directional light: `light_intensity_lux` defaults to 100,000, so a
## multiplier of 1.0 is "the light Godot considers normal". Everything else is measured from there,
## which is why this is 100,000 rather than the measured 128,000 lux of daylight — the difference is
## a fraction of a stop and one fewer constant to explain.
const REFERENCE_LUX := 100000.0

## The brightest **scene luminance a human eye adapts to rather than only squints at** — sunlit snow,
## which is as bright as a surface gets on Earth. It is the light-adapted end of the eye's range, and
## the only place the exposure's floor comes from.
const LIGHT_ADAPTED_LUMINANCE := 100000.0

## **The exposure's range, and both ends of it are states of the eye** rather than numbers chosen to
## be far apart.
##
## `MIN_MULTIPLIER` is **fully light-adapted**: past a scene luminance of `LIGHT_ADAPTED_LUMINANCE`
## the eye has nowhere left to go, and that ceiling on adaptation is what being dazzled IS. Rendering
## darker than that models a state that does not exist — and it is the shape that takes the whole
## frame away from you because one bright thing is in it, when the eye would still be seeing the
## rest. It comes to 1/pi. A sunlit surface filling the view (12,730 lux/sr) lands at 2.5 and the day
## sky with the Sun in it (71,368) at 0.45, both inside the floor; **the Sun starts to dazzle inside
## about 0.83 au** (its disc over the view is 69,000 lux/sr at one au, and the floor is 100,000), so
## Venus and Mercury reach it and nothing further out does. That is the behaviour the floor exists
## for: past it the picture saturates rather than the exposure continuing to chase a light the eye
## has already given up on.
##
## `MAX_MULTIPLIER` is the other end, and the range between them is **32 stops** (Evert,
## 2026-10-15: *"open the EV range to 32"*) — `2^32` times the floor, which is the wide end of what a
## human eye spans. It is nowhere near a state of anything on its own; what it has to do is sit above
## `DARK_ADAPTED_MULTIPLIER` at the **widest field the settings allow** (140 degrees, where the anchor
## is 64x its reference value), and it does so with a 26x margin. Pinned by test.
const MIN_MULTIPLIER := REFERENCE_LUX / (LIGHT_ADAPTED_LUMINANCE * PI)
const MAX_MULTIPLIER := MIN_MULTIPLIER * 4294967296.0 ## 2^32: the range is 32 stops

## How fast exposure follows a change. Slow on purpose: what you notice about a night side is that it
## stays dark, and a hard cut when flying between planets looks like a bug.
const ADAPTATION_RATE := 0.6

## A clear blue sky's own **luminance**, in lux per steradian (the same number as cd/m²). Schlyter's
## "full daylight, not direct sun" is 10,000-25,000 lux *on a horizontal surface*, and a uniform sky of
## luminance L gives pi*L on the ground — so L = 25,000/pi = 8,000, which is the order a real clear sky
## measures.
##
## It matters because **you do not have to look at the Sun to lose the stars.** Stand in a lit
## atmosphere with the Sun behind you and the sky in front of you is still daylight.
const DAYLIGHT_SKY_LUMINANCE := 8000.0

## The solid angle below which a source is a **POINT** and does not set adaptation: about 9.6e-6 sr,
## a disk 0.2 degrees across.
##
## That is the eye's own pooling scale — the vault's note is that a dark-adapted eye sums over roughly
## 0.2 degrees — and it is the whole reason a star field behaves differently from a planet. Below it a
## source cannot be resolved as a surface, so there is no surface brightness for the eye to adapt to;
## it can only dazzle.
##
## **It is what makes "looking at the Sun" mean different things in different places**, which was the
## bug it fixes. The Sun's disk is 0.53 degrees at 1 au — five times the pooling scale, so it is a sky
## you adapt to and the stars go. At Saturn it is 0.053 degrees, ten times *smaller* than the scale, so
## it is a glare source and no more, and the sky must be left alone. Evert reported exactly that on
## 2026-10-14, and it is why the exposure was anchored to the wrong thing.
const MIN_SOLID_ANGLE := 9.6e-6

## The multiplier a fully dark-adapted eye corresponds to — the exposure's resting state when there
## is nothing bright in front of it, and the whole of what "a night sky" means on screen.
##
## **`target_multiplier()` above cannot serve for a star field, and the reason is worth stating.**
## That rule exposes a lit *surface*, which has a mean luminance the eye adapts to. A star field has
## no mean luminance — it is point sources on black — so there is nothing there to adapt to. What an
## observer has instead is a RANGE, and dark adaptation opens that range onto the sky. So the anchor
## is the observer, not the scene.
##
## **Anchored at the FAINT end, and that was the bug** (Evert, 2026-10-15). The first derivation put
## the *brightest* star at the display's white point — and the naked-eye range is Sirius at V = -1.44
## down to the 6.5th magnitude, which is **7.94 magnitudes, or 1,502:1**. Anchoring the top of that at
## white puts the bottom 3.18 decades below it, under the display's own floor. The picture that
## produces is a handful of stars, which is exactly what it showed.
##
## Anchored at the faint end it is the dark-adapted eye instead: **the 6.5th magnitude — by definition
## the faintest thing a fully dark-adapted eye can see — sits at the faintest thing the display shows**, 
## and the whole range above it is visible at once, with the brightest stars saturating. Evert, on what
## he is asking for: *"I want to re-create the relative brightness as if you took a long exposure shot,
## as cameras can't naturally step down to what a human eye is capable of."* A long exposure is the same
## statement: the top blows out and the faint field appears.
##
## Derived, at the reference the sky is judged at (1920x1080, a 37.8 degree field):
##     mag 6.5, the naked-eye limit      2.54e-6 * 10^(-0.4 * 6.5)   = 6.375e-9 lux
##     one pixel's solid angle          4 * tan18.9^2 * 1.778 / (1920*1080) = 4.020e-7 sr
##     its radiance                     6.375e-9 / 4.020e-7          = 1.586e-2 lux/sr
##     in Godot's units                 1.586e-2 / (100000/pi)       = 4.984e-7
##     to the display's floor           ~0.05 -> 0.05 / 4.984e-7     = 1.0e5
##
## **The one number in that chain that is not physics is the display's floor**, and it is why this is
## 800,000 rather than 100,000: the floor is not a property of the sky, it is a property of the screen
## and the room it is looked at in, and Evert measured it at **10^2** — the same correction the old
## `sky.star_gain` 2.1 was carrying all along, now placed where it belongs instead of in a fudge on the
## field. Anchoring at the faint end is the fix; the exact height of the floor is the free parameter,
## and it is the one thing here that a person's eye decides rather than a measurement.
##
## **The sky's brightness follows the resolution and the field; this does not.** Evert chose that on
## 2026-10-14: a higher resolution concentrates the same flux into a smaller angle and the stars get
## brighter, which is what a larger aperture does to a point source.
##
## The field of view the value below was derived at. It is REFERENCE ONLY — the multiplier that is
## actually used comes from `dark_adapted_multiplier(fov)`, because a star's rendered radiance goes as
## `(height / tan(half vfov))^2` and a constant derived at one field is wrong at every other.
const DARK_ADAPTED_REFERENCE_FOV := 37.8

const DARK_ADAPTED_MULTIPLIER := 800000.0


## The dark-adapted multiplier **for the field of view actually in use**.
##
## Evert's idea, 2026-10-14: *"can't we use the FOV for the dark adapted multiplier?"* It is the right
## correction, and it fixes a self-inconsistency rather than papering over one — the shader's output
## goes as `(height / tan(half vfov))^2`, so a multiplier derived at one field cannot be right at
## another. Deriving it also *chooses a behaviour*: with this, the sky is **independent of the field of
## view and still dependent on the resolution**, which is the consistent reading of Evert's choice that
## stars should brighten with more pixels. A narrower field stops changing brightness; a bigger frame
## still does.
##
## Number to check it against: at 70 degrees this is 4.18x the reference value, because
## `(tan 35 / tan 18.9)^2 = (0.7002 / 0.3424)^2`.
static func dark_adapted_multiplier(fov_degrees: float) -> float:
	var tan_reference := tan(deg_to_rad(DARK_ADAPTED_REFERENCE_FOV * 0.5))
	var tan_now := tan(deg_to_rad(clampf(fov_degrees, 1.0, 179.0) * 0.5))
	var scale := tan_now / tan_reference
	return DARK_ADAPTED_MULTIPLIER * scale * scale

var attributes: CameraAttributesPhysical


func _init() -> void:
	attributes = CameraAttributesPhysical.new()
	# **Auto-exposure off.** Leaving it on would let the engine override the number below with its
	# frame average, which is the whole failure this replaces.
	attributes.auto_exposure_enabled = false
	# **Identity.** The frame's exposure is applied by `SpacesimExposurePass` — see `identity()`.
	attributes.exposure_multiplier = 1.0


## The multiplier that puts a lit surface at middle grey, given the illuminance at the observer.
##
## A surface's luminance is proportional to the light falling on it, so the correction is proportional
## to the reciprocal of the illuminance, and `REFERENCE_LUX` is the light at which no correction is
## needed. At one au (128,000 lux) this gives 0.78; at Neptune (141 lux) it gives 709 — a little over
## nine stops, which is the honest difference between the two places.
##
## **This no longer drives the frame.** `SpacesimExposurePass` meters the rendered pixels and applies one
## number to them, on Evert's instruction that the EV *"should not be location aware at all, only adjust
## to what is on the screen"* — so what is kept here is the statement of what the currency means, which
## the light and the sky are judged against and which the tests still work from. The frame's own arithmetic
## is `SpacesimExposureMeter`'s.
static func target_multiplier(lux: float) -> float:
	if lux <= 0.0:
		return MAX_MULTIPLIER
	return clampf(REFERENCE_LUX / lux, MIN_MULTIPLIER, MAX_MULTIPLIER)


## The multiplier that puts a scene of mean **luminance** at middle grey.
##
## A luminance and an illuminance differ by pi for a Lambertian surface, so this is the rule above with
## that factor folded in — and the two agree, which is the point: `target_multiplier(E)` and
## `target_multiplier_for_luminance(E/pi)` are the same number.
##
## It is the *luminance* form that a scene wants, because adaptation follows what the eye is looking
## at, not the light arriving at the observer. See `SpacesimSystemScene.view_luminance_at`.
static func target_multiplier_for_luminance(lux_per_sr: float) -> float:
	return target_multiplier(lux_per_sr * PI)


## Put the camera's exposure at **identity**, because `SpacesimExposurePass` applies it frame-wide.
##
## **The attributes must stay attached.** Identity is `CameraAttributesPhysical` with the multiplier at
## 1.0 and *never* `attributes = null`: measured 2026-10-15, with no attributes the engine skips the
## factor that implements Godot's "100,000 lux renders a white surface as 1.0" convention
## (`light_storage.cpp:764` applies it only `if (p_render_data->camera_attributes.is_valid())`), and the
## scene renders **about 95× too bright** — 1,000 lux on a white Lambertian read 1.0 instead of 0.0103.
##
## **And `tonemap_exposure` must stay at 1.0** while a pass does the multiply: the glow applies the
## exposure itself (`copy.glsl:195`), so an exposure in both places is applied twice.
func identity() -> void:
	attributes.exposure_multiplier = 1.0


## **The adaptation is the pass's now.** `update`, `update_to` and `snap_to` lived here and drove the
## camera's multiplier from the light at the *observer*; `SpacesimExposurePass` does the same work against
## the rendered frame, on the GPU, with `ADAPTATION_RATE` below as its rate and this window as its bounds —
## so that the exposure and the frame it is applied to cannot disagree.


## Set the ambient light from the star field's own illuminance, in lux.
##
## **The energy is in `REFERENCE_LUX`'s units, and that is what makes it consistent.** `REFERENCE_LUX`
## is 100,000 lux, which is Godot's own reference for `light_intensity_lux` — the illuminance at which
## a white surface renders as 1.0 — so an illuminance becomes an energy by dividing by it and nothing
## else. The number handed in is the **whole naked-eye sky summed from the catalogue**, about 2e-4 lux,
## which is what a night side is actually lit by.
##
## It moves with `sky.star_depth` by construction, because it is summed to that depth — so the ambient
## and the sky above it cannot disagree, which was the whole point of taking it from the sky in the
## first place.
static func set_ambient_illuminance(environment: Environment, lux: float) -> void:
	if environment == null:
		return
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = maxf(lux, 0.0) / REFERENCE_LUX


func multiplier() -> float:
	return attributes.exposure_multiplier


## The tone curve, the ambient and the star's glare.
##
## AgX rather than ACES: it is the one built for a wide range without the highlight colour shifts ACES
## can produce, and "not fully black or white" is the tone curve's job rather than the light's.
##
## The tone curve is deliberately left alone in the same change as the exposure, so that if the
## picture improves we know which one did it.
##
## **The ambient comes from the catalogue, and not from the background.** Evert, 2026-10-14: *"The sky
## should be the ambient light source."* That is still the intent — a night side is lit by the stars
## that are actually there — but `AMBIENT_SOURCE_BG` could not deliver it, for two reasons and both of
## them mine:
##
## 1. Godot builds that ambient from a radiance **cubemap**, and a sky of point sources cannot be
##    represented in one. It is the wrong object for the light.
## 2. The star shader's basis is the camera's, and Godot renders the cubemap by walking cube faces, so
##    the field it integrated was placed by a mapping with no relationship to the face. The pixel size
##    it measured could then collapse toward zero, and `radiance = lux / d_omega` went with it. That
##    cubemap **is** the ambient: Evert's report is *"the ambient light is far too bright"*, with a
##    body's night side rendering white.
##
## So the number is summed from the same catalogue, directly, by `SpacesimStarSky.illuminance()` and
## handed over in `REFERENCE_LUX`'s units — the convention every other light here is set in. The sky is
## still the light source; it is no longer asked to travel through a cubemap to say so.
##
## **Re-applied 2026-10-15 after a rollback, and this is the ambient half only.** Its companion change —
## having the star shader stand down in the radiance pass — is *not* part of this and is not needed by
## it: `AMBIENT_SOURCE_COLOR` takes the colour and never the cubemap, which is `update_ubo`'s own
## `use_ambient_cubemap` flag. So the ambient and that stand-down are separable, and the stand-down's
## history (a guard that tested `#ifdef` on a bool, which took the whole star field out of every pass)
## does not come back with this.
static func configure(environment: Environment) -> void:
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	# **Both white points, and that is not belt-and-braces.** AgX IGNORES `tonemap_white` — the engine
	# says so in as many words, *"tonemap_agx_white will be used instead when using the
	# TONE_MAPPER_AGX tonemapper"* — and the derivation of `DARK_ADAPTED_MULTIPLIER` is done against
	# **6.0**. Setting only `tonemap_white` therefore left the curve running at its own default of
	# **16.29**, which is not the value the arithmetic above was written against.
	#
	# **What this does and does not buy, measured rather than assumed.** The white parameter shapes the
	# curve's shoulder only — the toe is independent of it — so on our numbers Sirius moves from
	# 245/255 to 254/255 and the faint half of the field does not move at all. It is a correctness fix,
	# not a brightness one, and it is worth having because the constant and the curve have to be
	# talking about the same white. (The first version of this comment claimed 2.72x, from the
	# semantics of `tonemap_white` as described in the class reference. That was wrong, and the
	# magnitude is recorded here so nobody re-derives it from the same description.)
	environment.tonemap_white = 6.0
	environment.tonemap_agx_white = 6.0
	# The source and the energy are set from the catalogue once a frame — see
	# `set_ambient_illuminance`, and the note above on why it is not `AMBIENT_SOURCE_BG`.
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.0
	# The star's disk should roll off through the tonemapper rather than sit in the frame as the
	# brightest thing in the exposure histogram.
	environment.glow_enabled = true
	environment.glow_intensity = 0.4
	environment.glow_bloom = 0.05
	environment.glow_hdr_threshold = 1.0
	# **The most local glow level was OFF, and that is the one a lone bright pixel needs.** Godot's defaults
	# are 0.0 for `glow_levels/1` and 0.8, 0.4, 0.1 for 2, 3 and 4 — so the glow *starts* at a mip whose
	# downsample has already averaged a single pixel away. The consequence is asymmetric and hides well:
	# **a cluster of bright pixels survives that downsample and blooms, and an isolated one does not**, so
	# a distant planet or a lone star reads as a flat white pixel rather than as a point of light. Evert,
	# 2026-10-15, on the point of light a sub-pixel body becomes: *"I see Venus as a solid white pixel."*
	#
	# Written through `set()` rather than `set_glow_level()`: **the method is 0-BASED while the property is
	# `glow_levels/(i+1)`**, so `set_glow_level(1, x)` writes level 2 and leaves the local one off — looking
	# entirely reasonable in a diff while doing nothing.
	environment.set("glow_levels/1", 1.0)
	# The cap is where brightness stops mattering *for the glow*, so above it the brightest thing in the
	# frame glares exactly as much as a merely bright one. Raised rather than left at 12, so a glare can be
	# brighter than a glimmer. **A trim, not a measurement** — the number to judge it by is how the Sun and
	# a bright planet compare when both are in frame.
	environment.glow_hdr_luminance_cap = 64.0
