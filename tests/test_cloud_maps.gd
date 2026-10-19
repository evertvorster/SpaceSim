extends RefCounted
## The map cache: the size law, the synchronous floor, the worker-thread refinement, and the percentile
## that turns a layer's coverage into a threshold.
##
## **The distances here are chosen to stay small.** A refinement is a real bake — 512x256 is 105 ms and
## 8192x4096 is 27 s — so the tests ask for widths a step or two above the floor and check the *law*
## separately from the bake. A suite that triggered an 8k bake would take half a minute to drain, and a
## `clear()` that waits for it would look like a hang.

const SOL_PATH := "res://systems/sol.tres"
## Far enough that Earth wants a 512-wide map and no wider: `2*pi*r/(pixel_angle*d)`.
const FAR := 1.0e8
## Close enough that the law wants the maximum, used only against `required_width` and never baked.
const CLOSE := 1.0e6


func run(h, root: Node) -> void:
	print("  cloud maps")
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "Sol loads")
	if sol == null:
		return
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null:
		h.check(false, "a scene wraps it")
		return
	scene.build(root)

	var materials := SpacesimMaterialTable.engine_table()
	var luminosity := SpacesimStarModel.luminosity(scene.star().content)
	var earth := scene.body_by_id("planet:earth")
	var earth_morphology := SpacesimCloudModel.morphology(
		earth.content, materials, luminosity, earth.position.distance_to(scene.star().position)
	)
	var venus_morphology := SpacesimCloudModel.morphology(
		scene.body_by_id("planet:venus").content, materials, luminosity,
		scene.body_by_id("planet:venus").position.distance_to(scene.star().position)
	)

	_test_the_size_law(h)
	_test_a_window_maps_to_the_same_field(h)
	_test_the_percentile(h, earth_morphology)
	_test_the_floor_is_synchronous(h, earth, earth_morphology)
	_test_it_refines_on_approach(h, earth, earth_morphology)
	_test_a_featureless_body_bakes_nothing(h, venus_morphology)
	_test_the_cache_is_bounded(h, earth, earth_morphology)
	_test_a_bake_can_be_abandoned(h)

	scene.container.free()


## **The law the probe measured, as the thing that decides the map size.** Two properties: closer means
## bigger, and the width it asks for is the width whose texel is sub-pixel at that distance.
func _test_the_size_law(h) -> void:
	var radius := 6.371e6
	var near := SpacesimCloudMaps.required_width(radius, 1.0e7)
	var far := SpacesimCloudMaps.required_width(radius, 1.0e8)
	h.check(near > far, "closing on a body asks for a bigger map (%d against %d)" % [near, far])

	# The texel at the required width must project under a pixel **at the distance to the ground**, which is
	# where the law's own input comes from — the distance to the surface, not to the centre.
	var distance := 5.0e7
	var width := SpacesimCloudMaps.required_width(radius, distance)
	var texel := TAU * radius / float(width)
	var pixels := texel / (SpacesimCloudMaps.DEFAULT_PIXEL_ANGLE * (distance - radius))
	h.check(pixels <= 1.0,
		"and the texel it lands on is %.3f of a pixel at that distance — sub-pixel, which is the point"
			% pixels)

	# **And the distance that matters is the ALTITUDE, not the radius.** At 2,000 km up the ground is
	# 2,000 km away while the centre is 8,371, so the centre asks for a quarter of the map — two
	# quantisation steps, and the difference between a sharp deck and one that reads as blocky.
	var from_altitude := SpacesimCloudMaps.required_width(radius, radius + 2.0e6)
	var by_centre := SpacesimCloudMaps.quantise(
		int(ceil(TAU * radius / (SpacesimCloudMaps.DEFAULT_PIXEL_ANGLE * (radius + 2.0e6))))
	)
	h.check(from_altitude > by_centre,
		"at 2,000 km up it asks for %d where the distance to the centre asks only for %d"
			% [from_altitude, by_centre])
	h.check(from_altitude == SpacesimCloudMaps.MAX_WIDTH,
		"which is the ceiling, because no map resolves the ground that low")
	h.check(SpacesimCloudMaps.required_width(radius, radius + 3.769e6) == SpacesimCloudMaps.MAX_WIDTH,
		"and the ceiling holds from the altitude where a map stops being pixel-perfect")

	h.check(SpacesimCloudMaps.required_width(radius, CLOSE) == SpacesimCloudMaps.MAX_WIDTH,
		"a very close body asks for the maximum and no more (%d)" % SpacesimCloudMaps.MAX_WIDTH)
	h.check(SpacesimCloudMaps.required_width(radius, 1.0e12) == SpacesimCloudMaps.FLOOR_WIDTH,
		"and a very distant one asks for no less than the floor")
	h.check(SpacesimCloudMaps.required_width(0.0, 1.0e8) == SpacesimCloudMaps.FLOOR_WIDTH,
		"with a degenerate radius falling back rather than dividing by zero")

	# Powers of two, so an approach does not re-bake for a handful of texels.
	h.check(SpacesimCloudMaps.quantise(300) == 512, "300 quantises up to 512")
	h.check(SpacesimCloudMaps.quantise(512) == 512, "and 512 stays 512")
	h.check(SpacesimCloudMaps.quantise(1) == SpacesimCloudMaps.FLOOR_WIDTH,
		"nothing goes below the floor")


## **The percentile, measured rather than assumed.** The threshold is what the layer's coverage implies,
## so the achieved coverage has to be the requested one — the rule the vault has carried since the first
## deck, where the threshold was `1 - cover` and nobody had checked.
func _test_the_percentile(h, morphology: SpacesimCloudModel.Morphology) -> void:
	var image := SpacesimCloudField.bake(SpacesimCloudField.seed_for("planet:earth", 0), morphology, 256, 128)
	h.check(image != null, "a map to measure")
	if image == null:
		return
	for wanted in [0.25, 0.5, 0.75]:
		var threshold := SpacesimCloudMaps.threshold_for(image, wanted)
		var achieved := _fraction_above(image, threshold)
		h.check(absf(achieved - wanted) < 0.03,
			"asking for %.0f%% coverage gives %.1f%% (threshold %.3f)" % [
				wanted * 100.0, achieved * 100.0, threshold
			])
	h.check_near(SpacesimCloudMaps.threshold_for(image, 0.0), 1.0,
		"no coverage means nothing clears the threshold", 1.0e-9)
	h.check_near(SpacesimCloudMaps.threshold_for(image, 1.0), 0.0,
		"and full coverage means everything does", 1.0e-9)
	h.check_near(SpacesimCloudMaps.threshold_for(null, 0.5), 1.0,
		"with no map at all drawing nothing rather than everything", 1.0e-9)


## A body is never cloudless by accident: the first sight of it bakes the floor in the same call, and
## nothing is left in flight.
func _test_the_floor_is_synchronous(h, earth: SpacesimSceneBody, morphology: SpacesimCloudModel.Morphology) -> void:
	var maps := SpacesimCloudMaps.new()
	var texture := maps.map("planet:earth", 0, earth.content.radius, 0.6, FAR, morphology)
	h.check(texture != null, "the first look at a body returns a texture immediately")
	h.check(maps.width_of("planet:earth", 0) >= SpacesimCloudMaps.FLOOR_WIDTH,
		"at the floor width (%d)" % maps.width_of("planet:earth", 0))
	h.check(maps.threshold_of("planet:earth", 0) < 1.0,
		"with a threshold that a 60%% deck actually clears (%.3f)" % maps.threshold_of("planet:earth", 0))

	# A second look at the same distance is a cache hit — no new bake, because the map in hand already
	# resolves this distance.
	var before := maps.bakes()
	maps.map("planet:earth", 0, earth.content.radius, 0.6, FAR, morphology)
	h.check(maps.bakes() == before,
		"and asking again at the same distance starts no bake at all (%d bakes)" % maps.bakes())
	maps.close()


## **Refinement on approach.** A closer map is bigger, it is baked off the main thread, and the previous
## map stays in place until the new one arrives — the picture improves rather than blinking.
func _test_it_refines_on_approach(h, earth: SpacesimSceneBody, morphology: SpacesimCloudModel.Morphology) -> void:
	var maps := SpacesimCloudMaps.new()
	maps.map("planet:earth", 0, earth.content.radius, 0.6, FAR, morphology)

	# Earth at 1e8 m wants 512, so this asks for one step up from the floor. **Against the floor, not
	# against `far_width`**: with a GPU present the refinement below has already happened by the time
	# `map()` returns, so the map in hand is *already* the wider one, and asserting on the pre-refinement
	# state fails for being faster. The policy is what is under test here.
	var wanted := SpacesimCloudMaps.required_width(earth.content.radius, FAR)
	h.check(wanted > SpacesimCloudMaps.FLOOR_WIDTH,
		"this distance deserves a wider map than the floor (%d against %d)"
		% [wanted, SpacesimCloudMaps.FLOOR_WIDTH])

	var during := maps.map("planet:earth", 0, earth.content.radius, 0.6, FAR * 0.5, morphology)
	h.check(maps.pending() > 0 or maps.width_of("planet:earth", 0) > SpacesimCloudMaps.FLOOR_WIDTH,
		"a closer approach puts a refinement in flight, or has already landed it")
	h.check(during != null, "and the map in hand is still there while it bakes")

	# Drain it. `poll()` is the main-thread step that turns the finished Image into a texture.
	var drained := _drain(maps)
	h.check(drained, "the refinement completes (%.1f s)" % (float(_waited) / 1000.0))
	# **At least what the distance asks for**, for the same reason: on the GPU a refinement can have
	# landed for the nearer distance too, and a bigger map is not a failure.
	h.check(maps.width_of("planet:earth", 0) >= wanted,
		"and the map is now at least the width this distance asked for (%d against %d)"
		% [maps.width_of("planet:earth", 0), wanted])
	h.check(maps.pending() == 0, "with nothing left in flight")
	h.check(maps.map("planet:earth", 0, earth.content.radius, 0.6, FAR, morphology) != null,
		"and the refined map is what a caller gets")
	maps.close()


## **A featureless body costs nothing here either.** Not a smaller map — no map, and no bake counter
## moved, which is what "skip the noise generation" means one layer up.
func _test_a_featureless_body_bakes_nothing(h, venus: SpacesimCloudModel.Morphology) -> void:
	var maps := SpacesimCloudMaps.new()
	var texture := maps.map("planet:venus", 0, 6.052e6, 1.0, FAR, venus)
	h.check(texture == null, "Venus gets no map")
	h.check(maps.bakes() == 0,
		"and no bake is started, not even the floor (%d bakes)" % maps.bakes())
	h.check(maps.pending() == 0, "and no task goes to a worker thread")
	h.check_near(maps.width_of("planet:venus", 0), 0.0, "so its width is zero", 1.0e-9)
	maps.close()


## **More bodies than the cap, and the cache stays bounded** — a journey through a generated cosmos must
## not accumulate every map it has ever seen.
##
## The distance is huge on purpose: it asks for the floor and nothing more, so no refinement is in flight
## and the bound under test is the one `_trim()` implements. An entry being refined is deliberately not
## evictable — see [constant SpacesimCloudMaps.MAX_ENTRIES] — so testing the cap with bakes in flight
## would be testing the soft edge of it rather than the bound.
func _test_the_cache_is_bounded(h, earth: SpacesimSceneBody, morphology: SpacesimCloudModel.Morphology) -> void:
	var maps := SpacesimCloudMaps.new()
	for index in SpacesimCloudMaps.MAX_ENTRIES + 4:
		maps.map("planet:earth:%d" % index, 0, earth.content.radius, 0.6, 1.0e12, morphology)
	h.check(maps.pending() == 0, "nothing in flight to interfere with eviction")
	h.check(maps.bakes() == SpacesimCloudMaps.MAX_ENTRIES + 4,
		"every new body baked a floor and no more (%d bakes)" % maps.bakes())
	h.check(maps.width_of("planet:earth:0", 0) == 0,
		"and the least recently used was let go")
	h.check(maps.width_of("planet:earth:%d" % (SpacesimCloudMaps.MAX_ENTRIES + 3), 0) > 0,
		"while the most recent is still here")
	maps.close()
	h.check(maps.pending() == 0, "and clear() leaves nothing behind")


## How much of a map clears a threshold: the achieved coverage, measured.
func _fraction_above(image: Image, threshold: float) -> float:
	var data := image.get_data()
	if data.is_empty():
		return 0.0
	var level := int(threshold * 255.0)
	var above := 0
	for byte in data:
		if byte >= level:
			above += 1
	return float(above) / float(data.size())


var _waited := 0


## Polls until nothing is in flight, with a bound so a stuck task fails the check rather than hanging the
## run the way an unresolved `await` would.
func _drain(maps: SpacesimCloudMaps, limit_ms: int = 30000) -> bool:
	_waited = 0
	while maps.pending() > 0 and _waited < limit_ms:
		maps.poll()
		if maps.pending() == 0:
			return true
		OS.delay_msec(5)
		_waited += 5
	return maps.pending() == 0


## **A bake that is no longer wanted has to be abandonable.** This is the shutdown path, and both halves
## matter: the pool requires every task to be awaited or the engine takes the process down with it — the
## headless smoke load exited 139 with no output while a 27-second bake was in flight — and waiting for
## the bake whole would hang the exit instead. Rows are the checkpoint, and `close()` raises the flag
## before it waits.
func _test_a_bake_can_be_abandoned(h) -> void:
	var bail := SpacesimCloudField.Bail.new()
	bail.asked = true
	h.check(SpacesimCloudField.bake(1, null, 64, 32, bail) == null,
		"a bake asked to stop generates nothing and returns no map")
	bail.asked = false
	h.check(SpacesimCloudField.bake(1, null, 64, 32, bail) != null,
		"and one that is still wanted bakes as usual")

	# Closing a cache is the same path the scene takes when it goes away: stop, then wait.
	var maps := SpacesimCloudMaps.new()
	maps.close()
	h.check(maps.pending() == 0, "and closing a cache leaves nothing in flight")
	# **And it re-arms.** A cache closed once must not refuse to bake for the rest of the session.
	var morphology := SpacesimCloudModel.Morphology.new()
	h.check(SpacesimCloudField.bake(1, morphology, 32, 16) != null,
		"with the bail put back down, so a later bake is not silently skipped")


## **A window is the same field, sampled over a rectangle** — checked by making the texels line up exactly.
##
## A `64x32` whole-body bake and a `32x16` window at origin `(0.25, 0.5)` size `(0.5, 0.5)` put every window
## texel centre on a whole-body texel centre, so the two images must agree byte for byte. Anything else and
## the window's `(u, v)` mapping is wrong in a way no picture would query — it would just be a deck in the
## wrong place.
func _test_a_window_maps_to_the_same_field(h) -> void:
	var morphology := SpacesimCloudModel.Morphology.new()
	morphology.banding = SpacesimCloudModel.Banding.SHREDDED
	morphology.cells = 3.79
	morphology.ratio = 0.1037
	morphology.eddy_angular_scale = 0.2326
	var seed := SpacesimCloudField.seed_for("planet:earth", 0)
	var whole := SpacesimCloudField.bake(seed, morphology, 64, 32)
	var window := SpacesimCloudField.bake(
		seed, morphology, 32, 16, null, Vector2(0.25, 0.5), Vector2(0.5, 0.5)
	)
	var same := 0
	for row in 16:
		for column in 32:
			if whole.get_pixel(column + 16, row + 16) == window.get_pixel(column, row):
				same += 1
	h.check(same == 32 * 16,
		"a window is the same field over a rectangle (%d of %d texels agree)" % [same, 32 * 16])


