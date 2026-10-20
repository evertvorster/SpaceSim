extends RefCounted
## **The band laws, as arithmetic** — the near regime's P0, branch `cloud-volumes`, 2026-10-20.
##
## This file exists because of how three previous attempts at the cloud failed: the picture was unobservable,
## not wrong. A deck that is `1 − exp(−39)` opaque in its first limb sample has a transmittance of zero for
## every step after it, so any rewrite of the *integration* is invisible — and three were made, each reported
## as "visually nothing changed". **What would have ended that in one run is these numbers**, which are pure
## arithmetic over a body's own derived quantities and need no GPU, no shader and no flight.
##
## So the checks are chosen to be the ones that fail when the mechanism is a lid:
##
## - the chord at the limb is the square root law and is **two orders of magnitude** longer than the columns
##   straight down, which is why one step budget cannot serve both views;
## - the sample count follows from the optical depth rather than being chosen, and rises with both the chord
##   and the extinction;
## - a march on Earth's limb reports **≈0.0094, not 3e-30**, because the opacity bound stops it — and that
##   number is asserted against the exponential it replaces, so a regression to "just exp(−τ)" goes red;
## - and the stop is reachable for **every deck on every body in Sol**, not only the one worth looking at.
##
## What it deliberately cannot check: anything about the picture. Whether the result looks like a cloud is a
## flight, and Evert's eye is the verdict. This file's job is to make the *lid* impossible to ship quietly.

const SOL_PATH := "res://systems/sol.tres"


func run(h, root: Node) -> void:
	print("  cloud band")
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "Sol loads")
	if sol == null:
		return
	var scene := SpacesimSystemScene.from_content(sol)
	h.check(scene != null, "a scene wraps it")
	if scene == null:
		return
	scene.build(root)

	var materials := SpacesimMaterialTable.engine_table()
	var luminosity := SpacesimStarModel.luminosity(scene.star().content)

	_test_column_top(h)
	_test_extinction(h)
	_test_the_chord(h, scene)
	_test_the_samples(h)
	_test_the_bound(h)
	_test_the_march(h, scene, materials, luminosity)
	_test_every_deck_in_sol(h, scene, materials, luminosity)

	scene.container.free()


## The map's value is a **height**, not an alpha — so a column at the threshold has no cloud in it at all and
## its chord falls to zero by arithmetic. "No cloud here" is then a gap rather than a special case, and the
## lateral edge is a taper instead of a cut.
func _test_column_top(h) -> void:
	h.check_near(SpacesimCloudBand.column_top(1.0, 0.4, 2000.0), 2000.0,
		"an opaque column is the layer's full depth", 1.0e-9)
	h.check_near(SpacesimCloudBand.column_top(0.4, 0.4, 2000.0), 0.0,
		"and a column at the threshold has no cloud in it", 1.0e-9)
	h.check_near(SpacesimCloudBand.column_top(0.2, 0.4, 2000.0), 0.0,
		"nor does one below it", 1.0e-9)
	h.check_near(SpacesimCloudBand.column_top(0.7, 0.4, 2000.0), 1000.0,
		"half way through the range is half the depth", 1.0e-9)
	# The degenerate inputs a shader will eventually hand it: no depth, or a threshold of 1 where the
	# denominator vanishes. A division by zero here is an infinity that becomes a black pixel.
	h.check_near(SpacesimCloudBand.column_top(1.0, 0.4, 0.0), 0.0,
		"a layer with no derived thickness has no column", 1.0e-9)
	h.check_near(SpacesimCloudBand.column_top(1.0, 1.0, 2000.0), 0.0,
		"and a threshold of 1 does not divide by zero", 1.0e-9)


## **The fallback is the one every layer but the giants takes, and it is what made the deck a lid.** One
## e-fold per half scale height is a defensible picture of "opaque over its own depth"; the failure was a step
## budget that ignored what it implies at the limb, so the coefficient itself is checked here and its
## consequence is checked in `_test_the_chord`.
func _test_extinction(h) -> void:
	var air := 8400.0
	h.check_near(SpacesimCloudBand.extinction(0.0, air), 1.0 / 4200.0,
		"an unstated optical depth gives one e-fold per half scale height", 1.0e-12)
	h.check_near(SpacesimCloudBand.extinction(4.0, air), 4.0 / 4200.0,
		"and a stated one is that tau over half a scale height", 1.0e-12)
	# The factor of two in the design: a column one full scale height deep is 2*tau, not tau.
	h.check_near(SpacesimCloudBand.extinction(4.0, air) * air, 8.0,
		"so a full-scale-height column of it comes to 2*tau", 1.0e-12)
	h.check_near(SpacesimCloudBand.extinction(4.0, 0.0), 0.0,
		"a body with no air has a clear deck, not an infinite one", 1.0e-12)


## **The geometry, and the ratio that forbids a single step budget.** Earth's own derived numbers: a 1.6 km
## condensate deck on a 6,371 km body.
func _test_the_chord(h, scene: SpacesimSystemScene) -> void:
	var earth := scene.body_by_id("planet:earth")
	var deck := _top_deck(h, earth, "Earth")
	if deck == null:
		return
	var base := earth.radius + deck.height
	var outer := base + deck.thickness
	var depth := deck.thickness
	print("    (Earth's deck: %.0f m base, %.0f m deep, %.0f m radius)"
		% [deck.height, deck.thickness, earth.radius])

	h.check_near(SpacesimCloudBand.chord(outer, base, 0.0), depth,
		"straight down, the chord is exactly the slab's thickness", 1.0e-3)

	var limb := SpacesimCloudBand.chord(outer, base, base)
	var expected_limb := 2.0 * sqrt(outer * outer - base * base)
	h.check_near(limb, expected_limb,
		"seen edge-on, it is 2*sqrt(outer^2 - base^2)  (%.1f km)" % (limb / 1000.0), 1.0e-3)

	# **The number that matters**: the same deck is a few kilometres deep one way and hundreds the other, so a
	# sample count chosen for a view down is wildly wrong at the limb — 39 to 68 optical depths in one step.
	var ratio := limb / depth
	print("    (limb chord is %.0fx the vertical column)" % ratio)
	h.check(ratio > 100.0 and ratio < 1000.0,
		"and that is two orders of magnitude longer, so no single step budget serves both views")

	# **There is no continuity at the base, and the step is the physics rather than a defect.** A grazing ray
	# passes through the band on both sides; a ray that reaches the ground is stopped by it after one crossing.
	# So the chord halves — not doubles — as the closest approach passes inside the base, and the grazing value
	# is the maximum the chord ever reaches.
	var grazing := SpacesimCloudBand.chord(outer, base, base)
	h.check(SpacesimCloudBand.chord(outer, base, base - 1.0) < grazing * 0.51,
		"a ray that reaches the ground crosses the band once, so it sees half the grazing chord")

	h.check_near(SpacesimCloudBand.chord(outer, base, outer * 1.001), 0.0,
		"a ray that misses the band has no chord", 1.0e-9)

	# Swept properties rather than single values, because a sign or an argument-order slip survives any one
	# check: the chord grows from the column underfoot to its maximum at the grazing ray, then falls away.
	var rising_to_the_limb := true
	var before := 0.0
	for i in 21:
		var value := SpacesimCloudBand.chord(outer, base, base * float(i) / 20.0)
		if value < before - 1.0e-3:
			rising_to_the_limb = false
		before = value
	h.check(rising_to_the_limb,
		"the chord grows from the column underfoot to its maximum, the grazing chord at the base")

	var falling_past_the_limb := true
	before = grazing
	for i in 21:
		var value := SpacesimCloudBand.chord(outer, base, base + (outer - base) * float(i + 1) / 21.0)
		if value > before + 1.0e-3:
			falling_past_the_limb = false
		before = value
	h.check(falling_past_the_limb, "and falls to nothing as the ray moves out past the top of the band")

	h.check_near(SpacesimCloudBand.chord(base, base, 0.0), 0.0,
		"a band of zero thickness has no chord at all", 1.0e-9)


## The count is a consequence, not a choice: a sample may not advance more than a sixth of an e-fold.
func _test_the_samples(h) -> void:
	h.check(SpacesimCloudBand.samples(0.0, 0.238e-3) == 1,
		"a ray that misses the band asks for one sample, not zero")
	h.check(SpacesimCloudBand.samples(5000.0, 0.0) == 1,
		"and a clear column asks for one as well")

	var rising_with_chord := true
	var previous := -1
	for i in 13:
		var count := SpacesimCloudBand.samples(1000.0 * float(i + 1), 0.238e-3)
		if count < previous:
			rising_with_chord = false
		previous = count
	h.check(rising_with_chord and previous > 1, "while a longer chord asks for more samples")

	var rising_with_extinction := true
	previous = -1
	for i in 13:
		var count := SpacesimCloudBand.samples(300000.0, 0.05e-3 * float(i + 1))
		if count < previous:
			rising_with_extinction = false
		previous = count
	h.check(rising_with_extinction and previous > 1, "and a denser band asks for more samples at the same chord")

	# One exact case, so the formula is pinned rather than merely monotone: 1 km at 0.5/km is tau 0.5, which
	# is three samples at six per e-fold.
	h.check(SpacesimCloudBand.samples(1000.0, 0.5e-3) == 3,
		"a chord of one optical depth less a bit comes to three samples")


## The ceiling that makes the limb affordable: whatever the chord, the march stops.
func _test_the_bound(h) -> void:
	var derived := ceili(log(1.0 / SpacesimCloudBand.OPACITY_BOUND) / SpacesimCloudBand.TAU_PER_STEP)
	h.check(SpacesimCloudBand.stop_steps() == derived,
		"the stop is derived from the bound and the step: %d samples" % derived)
	h.check(SpacesimCloudBand.stop_steps() == 28,
		"and lands on the 28 the design quotes, rather than being that number")
	h.check(SpacesimCloudBand.TAU_PER_STEP * float(SpacesimCloudBand.stop_steps()) >= log(1.0 / SpacesimCloudBand.OPACITY_BOUND),
		"the steps reach the opacity bound rather than stopping short of it")


## **The test that would have caught the lid.** Earth's limb is tens of optical depths, so the naive
## exponential is astronomically small and the picture it produces is finished in the first sample.
func _test_the_march(h, scene: SpacesimSystemScene, materials, luminosity) -> void:
	var earth := scene.body_by_id("planet:earth")
	var deck := _top_deck(h, earth, "Earth")
	if deck == null:
		return
	var scale_height := _scale_height(scene, earth, materials, luminosity)
	h.check(scale_height > 1000.0,
		"Earth's air scale height is derived, not assumed (%.0f m)" % scale_height)
	var coefficient := SpacesimCloudBand.extinction(deck.optical_depth, scale_height)
	var base := earth.radius + deck.height
	var outer := base + deck.thickness

	# Thin enough to finish: the answer is the plain exponential, because the discretisation must not become
	# the answer where the band is thin.
	var down := SpacesimCloudBand.chord(outer, base, 0.0)
	var tau_down := down * coefficient
	var reported_down := SpacesimCloudBand.marched_transmittance(down, coefficient)
	h.check_near(reported_down, exp(-tau_down),
		"straight down, a correctly stepped march reports exp(-tau) exactly (tau %.3f)" % tau_down, 1.0e-6)

	# The limb: capped, and finite. This is the assertion the three rewrites were missing.
	var limb := SpacesimCloudBand.chord(outer, base, base)
	var tau_limb := limb * coefficient
	var reported := SpacesimCloudBand.marched_transmittance(limb, coefficient)
	var naive := exp(-tau_limb)
	# `%e` does not exist in GDScript's formatter, and `%s` on 5e-30 reads as "0.0" — which would look like
	# an underflow rather than the astronomical number it is, so the exponent is formatted by hand.
	print("    (Earth's limb: tau %.1f, naive exp 1e%.1f, reported %.4f)"
		% [tau_limb, log(naive) / log(10.0), reported])
	h.check(tau_limb > float(SpacesimCloudBand.stop_steps()) * SpacesimCloudBand.TAU_PER_STEP,
		"the limb is past the point a march can integrate")
	h.check(reported > 1.0e-3,
		"and the reported transmittance is finite and non-zero rather than astronomically small")
	h.check(reported < SpacesimCloudBand.OPACITY_BOUND + 1.0e-4,
		"because it stopped where it should, just under the opacity bound")
	h.check(naive < reported * 1.0e-6,
		"while the uncapped exponential is the value that silences everything after the first sample")


## **Every deck on every body**, so the bound is reachable in general and not only for the planet we look at.
func _test_every_deck_in_sol(h, scene: SpacesimSystemScene, materials, luminosity) -> void:
	var decks := 0
	var all_stop := true
	var all_finite := true
	for body in scene.bodies:
		if body.content.atmosphere == null:
			continue
		var scale_height := _scale_height(scene, body, materials, luminosity)
		for deck in body.decks:
			decks += 1
			var coefficient := SpacesimCloudBand.extinction(deck.optical_depth, scale_height)
			var base: float = body.radius + deck.height
			# A deck below the datum has a negative base; the band is still a real pair of radii, and the
			# grazing chord is the worst case whatever its sign.
			var outer := maxf(base + deck.thickness, base + 1.0)
			var worst := SpacesimCloudBand.chord(outer, base, base)
			var t := SpacesimCloudBand.marched_transmittance(worst, coefficient)
			if not (t > 0.0 and t <= 1.0):
				all_finite = false
			if SpacesimCloudBand.samples(worst, coefficient) > SpacesimCloudBand.stop_steps() \
					and t > SpacesimCloudBand.OPACITY_BOUND + 1.0e-4:
				all_stop = false
	h.check(decks > 0, "Sol has decks to check (%d)" % decks)
	h.check(all_finite, "every one of them marches to a transmittance in (0, 1]")
	h.check(all_stop, "and a march that is past the bound stops at it, on every body")


## The deck the picture is actually about: the highest layer, which is the one seen from outside.
func _top_deck(h, body: SpacesimSceneBody, who: String) -> SpacesimSceneBody.Deck:
	var ok: bool = body != null and body.decks.size() > 0
	h.check(ok, "%s has a deck to do the band arithmetic on" % who)
	if not ok:
		return null
	return body.decks[0]


## The air's own scale height, through the derivation rather than from it — the same three calls the scene
## makes when it publishes the sky's coefficients.
func _scale_height(scene: SpacesimSystemScene, body: SpacesimSceneBody, materials, luminosity) -> float:
	var gravity := SpacesimAtmosphereModel.surface_gravity(body.content)
	var distance := body.position.distance_to(scene.star().position)
	var temperature := SpacesimAtmosphereModel.reference_temperature(
		body.content, materials, luminosity, distance
	)
	return SpacesimAtmosphereModel.scale_height(
		body.content.atmosphere, materials, temperature, gravity
	)
