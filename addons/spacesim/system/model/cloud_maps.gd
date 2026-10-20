class_name SpacesimCloudMaps
extends RefCounted
## **Baked coverage maps, one per (body, layer), and the size each of them deserves.**
##
## The shader samples a map; this produces them. Three things it decides, and all three are derived
## rather than picked:
##
##  1. **how big a map to bake, from the body's distance** — the law `tests/probe_cloud_maps.gd`
##     measured: a map of `W` texels around a body of radius `r` has a texel `2*pi*r/W` long, and it
##     stops resolving when that texel projects past a pixel, so the width worth having is
##     `2*pi*r / (pixel_angle * distance)`. Refinement is then automatic: closing on a body asks for a
##     bigger map, and nothing has to be tuned or laddered.
##  2. **when to bake** — a floor map is baked **synchronously** on first sight, because a body with no
##     map draws no cloud and a stall would be worse: measured 26 ms at 256x128, which is a frame or two.
##     Everything above the floor goes to a `WorkerThreadPool` task and arrives when it arrives.
##  3. **the threshold the layer's coverage implies** — a *percentile* of the map's own field, so the
##     achieved coverage is the requested one rather than a guess. This is the rule
##     [[SpaceSim/Atmospheres|Atmospheres]] §11 carries, and the reason the numbers here are measured.
##
## **Nothing here touches the renderer except `ImageTexture.create_from_image`, and that happens on the
## main thread** in `poll()` — the project's law, and the reason a finished bake sits in an `Image` until
## the next poll rather than becoming a texture in the task.

## The map baked synchronously on first sight. **Measured 0.80 us a pixel, so this is 26 ms** — a frame
## or two of stall, once, in exchange for a body never being cloudless by accident.
const FLOOR_WIDTH := 256

## The ceiling. The device allows 32,768 (measured, RTX 4090); 8,192 is where an 8k Earth map already
## stops resolving at 3,768 km and a bake costs 27 s, so a bigger one is for nobody.
const MAX_WIDTH := 8192

## **How many maps are kept, and the bound is SOFT.** A session visits systems, and every entry is up to
## 33 MB at 8k, so this bounds a leak that would otherwise grow with the journey. But `_trim()` cannot
## evict a map whose refinement is still in flight — a task holds its entry, and only the main thread can
## release the id — so a burst of newly-seen bodies can carry the cache to `MAX_ENTRIES` plus however
## many bakes the pool has running at once. That overshoot is transient and bounded by the pool's thread
## count, and it is named here rather than hidden behind a cap that does not quite hold.
const MAX_ENTRIES := 24

## The centre pixel's angle at 1080p and the game's 70-degree field of view — the same number
## `SpacesimLod`'s suite carries, and the one the map law needs.
const DEFAULT_PIXEL_ANGLE := 1.2966806e-3

## One body-layer's map and everything derived from it.
class Entry:
	extends RefCounted

	var image: Image
	var texture: ImageTexture
	## The width of the map in `image` and `texture`, which are always the same bake.
	var width := 0
	## **Metres of surface per texel this map actually carries.** The size law is checked against it.
	var texel := 0.0
	## **The percentile the layer's coverage implies**, 0 to 1, computed when the map was baked.
	var threshold := 0.0
	## **The mean exceedance above that threshold**, measured from the same map — what a reflectance ramp
	## needs to know so that the deck's *average* reflectance is the calibrated one while its thick tops
	## are near white. One for a body with no map, whose field is uniformly at its top.
	var ramp_mean := 1.0
	## **The mean of `1 - exp(-tau * thickness)` over the covered texels** — what a tau layer's reflectance
	## ramp must be fitted to, since the drawn average is `ALBEDO * ALPHA` and `ALPHA` is now that exponential
	## rather than the thickness itself. One where the layer states no tau, which is the flat case.
	var opacity_mean := 1.0
	## The `WorkerThreadPool` task id of a refinement in flight, or -1.
	var task := -1
	## The width that task is baking, so a second request does not start a third.
	var requested := 0
	var last_used := 0
	## Kept so a refinement can rebuild the field with the same morphology the floor used.
	var morphology: SpacesimCloudModel.Morphology


var _entries: Dictionary = {}
var _clock := 0
## The question every bake in flight asks once a row. **One per cache**, so closing the cache stops them
## all — see `close()`.
var _bail := SpacesimCloudField.Bail.new()
## How many bakes have been started, including the synchronous floors. For the suite, which needs to
## show that a cache hit is a hit.
var _bakes := 0
## The GPU path: one local device for the whole cache, created on the first bake that can use one.
## Null until asked for, and it stays non-null: `open()` failing is remembered.
var _gpu: SpacesimCloudGpu = null
## How many maps actually came off the GPU. **Reported rather than inferred**, because "the GPU path is
## wired in" is exactly the kind of claim that stays true while the path is dead, and the only honest
## evidence is a count from the run that baked.
var _gpu_bakes := 0

## **Whether a bake may open a local `RenderingDevice` — FALSE by default, and it is the frame loop that
## makes it so.**
##
## A local device's calls are render-thread-only, and **it shares the driver with the frame's own**, so a
## bake driven from `_process` exhausts the engine's RID pools in a few minutes of flight: the damage shows
## up in an unrelated pass, as `_allocate_rid` — *"Element limit reached"* — and a frame that stops shading.
## That is why the surface maps were moved off `_process` onto a render-thread bake pass.
##
## **The deck made that trap reachable again**, because this cache is now driven from `update_lod` on
## approach, so its refinements ran from the frame loop for the first time. Evert, 2026-10-20, closing on
## Venus's clouds: *"the atmosphere suddenly disappeared"*, with the allocator errors that name it.
##
## **But the GPU bake was not that leak, and it is the whole point of having one** (Evert, 2026-10-20: *"that's
## why we bake on the GPU, not the CPU"*). The allocator was exhausted by `SpacesimAtmospherePass`'s per-frame
## uniform set, which is fixed and now instrumented; this device frees every RID it creates, on every bake and
## at `close()`, and `SpacesimCloudGpu` counts them so a leak cannot be silent. The speed is not a detail:
## **47 ms for 8192x4096 against 26.8 s** on the CPU path, which is the difference between a refinement that
## arrives while it is still wanted and one that lands below the altitude it was baked for.
##
## So the GPU is on by default and the CPU path is what a headless run falls back to, by construction —
## `create_local_rendering_device()` returns null there. A caller that wants the CPU path explicitly (a test
## comparing the two, say) can set this false.
var gpu_allowed := true


## **The map width worth having at a distance**, from the law the probe measured — and the distance is to
## the *surface*, not to the body's centre.
##
## A texel of length `2*pi*r/W` subtends `texel / distance_to_it`, so what the law needs is how far away
## the ground being looked at is. Using the distance to the centre instead is 4x wrong at 2,000 km
## altitude (8,371 km against 2,000) and 4x in width is two quantisation steps — which is a map that
## reads as obviously blocky while every test says the refinement is working. It was, on the wrong
## number.
##
## **The size therefore saturates, and that is information rather than a limitation.** Below about
## 3,800 km an 8,192-wide Earth map can no longer be pixel-perfect — a 4.89 km texel is `4.89e3 / h`
## radians against a pixel of `1.297e-3`, so it is good down to `h = 3,769 km` and no further, whatever
## the map. That altitude is where the near regime has to take over, and it is derived here rather than
## asserted in a plan.
static func required_width(
	radius: float, distance: float, pixel_angle: float = DEFAULT_PIXEL_ANGLE
) -> int:
	if radius <= 0.0 or distance <= 0.0 or pixel_angle <= 0.0:
		return FLOOR_WIDTH
	# `max(..., 1.0)` rather than a negative distance: a camera at or under the surface asks for the
	# ceiling, which is what "as fine as this map can be" means.
	var to_surface := maxf(distance - radius, 1.0)
	return quantise(int(ceil(TAU * radius / (pixel_angle * to_surface))))


## To a power of two, and inside the bounds. Powers of two because a texture wants them and because a
## map that grows by a few texels at a time would be re-baked on every metre of approach.
static func quantise(width: int) -> int:
	var size := FLOOR_WIDTH
	while size < width and size < MAX_WIDTH:
		size *= 2
	return clampi(size, FLOOR_WIDTH, MAX_WIDTH)


## **The level a layer's coverage implies, as a percentile of the map's own field.**
##
## A threshold admits the fraction of the field *above* it, which equals the requested coverage only if
## the distribution is known — so the distribution is read off the map being used, in 256 bins, and the
## coverage is what the threshold then *achieves*. Iterative rather than exact, and it terminates:
## thirty-two passes move a byte-quantised level by at most one step each.
static func threshold_for(image: Image, coverage: float) -> float:
	if image == null:
		return 1.0
	var wanted := clampf(coverage, 0.0, 1.0)
	if wanted <= 0.0:
		return 1.0
	if wanted >= 1.0:
		return 0.0
	var data := image.get_data()
	var total := data.size()
	if total == 0:
		return 1.0
	var histogram := PackedInt32Array()
	histogram.resize(256)
	for byte in data:
		histogram[byte] += 1

	# The level whose *upper tail* is the requested fraction. Walked from the bottom, so the answer is
	# `255 - level` in byte terms and converts back to the field's 0-1 range.
	var tail := int(round(float(total) * wanted))
	var level := 255
	var above := 0
	while level >= 0 and above + histogram[level] < tail:
		above += histogram[level]
		level -= 1
	return clampf(float(level) / 255.0, 0.0, 1.0)


## **How much cloud there is above the threshold, averaged over the covered area** — 0 at the threshold,
## 1 at the top of the field.
##
## This is the number that lets the drawn deck carry its own calibrated reflectance. A ramp from thin to
## thick has a *mean* that depends on the field's distribution, which the host cannot know by argument —
## but it can measure, from the same histogram `threshold_for()` already builds.
static func mean_exceedance(image: Image, threshold: float) -> float:
	if image == null:
		return 1.0
	var data := image.get_data()
	if data.is_empty():
		return 1.0
	var level := int(clampf(threshold, 0.0, 1.0) * 255.0)
	var span := 255.0 - float(level)
	if span <= 0.0:
		return 1.0
	var total := 0.0
	var count := 0
	for byte in data:
		if byte >= level:
			total += (float(byte) - float(level)) / span
			count += 1
	if count == 0:
		return 0.0
	return total / float(count)


## The depth a ramp layer's mean thickness implies, or the depth the layer stated.
static func _column_depth(ramp_mean: float, stated: float) -> float:
	if stated > 0.0:
		return stated
	return -log(maxf(1.0 - clampf(ramp_mean, 0.0, 0.999), 1.0e-3))


## **How much light the layer actually blocks, averaged over the area it covers**: the mean of `R(tau)`, the
## complement of the transmittance the march integrates.
##
## **One law for both faces and both layer kinds.** The reflectance ramp this replaced saturated at 1 — it was
## the column's normalised thickness — so a tau-1.5 deck hid everything from above while transmitting a fifth of
## the sky underneath it. Evert, flying: *"looking down at the clouds, there is a lot of alpha applied that seems
## to be missing from the bottom up."* Fitted to `R(tau)` instead, the layer's average drawn reflectance is still
## its albedo (which is what `bond_albedo` assumes and what the tests hold), and the two faces cannot disagree
## about how much light gets through.
##
## **Measured at the local vertical**, `mu = 1`. The limb is deliberately brighter than this, because that is
## what a slab does; the budget is fitted at normal incidence.
static func mean_opacity(image: Image, threshold: float, depth: float) -> float:
	if image == null or depth <= 0.0:
		return 1.0
	var data := image.get_data()
	if data.is_empty():
		return 1.0
	var level := int(clampf(threshold, 0.0, 1.0) * 255.0)
	var span := 255.0 - float(level)
	if span <= 0.0:
		return 1.0
	var total := 0.0
	var count := 0
	for byte in data:
		if byte >= level:
			total += SpacesimCloudBand.two_flux(depth * (float(byte) - float(level)) / span).x
			count += 1
	return 0.0 if count == 0 else total / float(count)


func map(
	body_id: String,
	layer: int,
	radius: float,
	coverage: float,
	distance: float,
	morphology: SpacesimCloudModel.Morphology,
	depth: float = 0.0
) -> ImageTexture:
	var key := "%s#%d" % [body_id, layer]
	var wanted := required_width(radius, distance)
	var entry: Entry = _entries.get(key)
	_clock += 1

	if entry == null:
		# A featureless or unmeasured body has nothing to bake and nothing to refine. It is recorded
		# anyway, so the decision is made once rather than per frame.
		if morphology != null and SpacesimCloudField.mixing(morphology.banding) <= 0.0:
			var blank := Entry.new()
			blank.last_used = _clock
			_entries[key] = blank
			_trim()
			return null
		entry = Entry.new()
		_entries[key] = entry
		_bake_floor(entry, body_id, layer, coverage, morphology, depth, radius)

	entry.last_used = _clock
	if entry.task == -1 and wanted > entry.width:
		_start_refinement(entry, body_id, layer, coverage, morphology, wanted, depth)
	_trim()
	return entry.texture


func poll() -> int:
	var finished := 0
	for key in _entries:
		var entry: Entry = _entries[key]
		if entry.task == -1:
			continue
		if not WorkerThreadPool.is_task_completed(entry.task):
			continue
		WorkerThreadPool.wait_for_task_completion(entry.task)
		entry.task = -1
		entry.requested = 0
		_publish(entry)
		finished += 1
	return finished


## Hand a finished `Image` to the material: the width it implies and the texture the shader is given.
## **The one place that happens**, so a bake that completes on the main thread (every GPU bake) and one that
## completes in the pool cannot leave the entry in different states.
func _publish(entry: Entry) -> void:
	if entry.image == null:
		return
	entry.width = entry.image.get_width()
	entry.texture = ImageTexture.create_from_image(entry.image)


func pending() -> int:
	var count := 0
	for key in _entries:
		if (_entries[key] as Entry).task != -1:
			count += 1
	return count


## The width of the map currently in hand, or 0 where there is none.
func width_of(body_id: String, layer: int) -> int:
	var entry: Entry = _entries.get("%s#%d" % [body_id, layer])
	return 0 if entry == null else entry.width


## The threshold the map in hand was baked with.
func threshold_of(body_id: String, layer: int) -> float:
	var entry: Entry = _entries.get("%s#%d" % [body_id, layer])
	return 1.0 if entry == null else entry.threshold


func opacity_mean_of(body_id: String, layer: int) -> float:
	var entry: Entry = _entries.get("%s#%d" % [body_id, layer])
	return 1.0 if entry == null else entry.opacity_mean


func ramp_mean_of(body_id: String, layer: int) -> float:
	var entry: Entry = _entries.get("%s#%d" % [body_id, layer])
	return 1.0 if entry == null else entry.ramp_mean


## How many bakes have been started. The suite uses it to show a cache hit is a hit.
func bakes() -> int:
	return _bakes


## How many of those came off the GPU. Zero on a headless run, which is the documented fallback rather
## than a failure — `tests/gpu_check.sh` is where a non-zero value is asserted.
func gpu_bakes() -> int:
	return _gpu_bakes


## How many RIDs the bake device is holding, for the GPU suite's leak check. Zero unless a device is open.
func gpu_live_rids() -> int:
	return 0 if _gpu == null else _gpu.live_rids()


## Drop everything. **Waits for anything in flight**, because a task holds its entry and a released id is
## cheaper than a task nobody owns.
func clear() -> void:
	for key in _entries:
		var entry: Entry = _entries[key]
		if entry.task != -1:
			WorkerThreadPool.wait_for_task_completion(entry.task)
			entry.task = -1
	_entries.clear()


## **Stop baking, then wait for what is in flight — and in that order.**
##
## This is what the scene calls as it goes away, and both halves are load-bearing. The pool requires every
## task to be awaited before the engine goes away, and a run that quits with one still going **takes the
## process down with it**: the headless smoke load exited 139 with no output until this existed. But a
## bake can be 27 seconds, so waiting for it whole would only trade a crash for a hung exit.
##
## So the bail flag goes up first, the bake stops at its next row, and the wait is one row long — about
## 3 ms for a 4,096-wide map. The abandoned bake returns `null`, which `poll()` already treats as "no new
## map yet", so the deck keeps the one it had.
func close() -> void:
	_bail.asked = true
	clear()
	_bail.asked = false
	# **The device is freed here, and it has to be.** A local `RenderingDevice` left alive to be destroyed at
	# process teardown segfaults on exit — see `SpacesimCloudGpu.close()`.
	if _gpu != null:
		_gpu.close()
		_gpu = null


## The synchronous floor: a body gets *a* map on the frame it is first seen.
func _bake_floor(
	entry: Entry, body_id: String, layer: int, coverage: float,
	morphology: SpacesimCloudModel.Morphology, depth: float = 0.0, radius: float = 0.0
) -> void:
	var height := maxi(FLOOR_WIDTH / 2, 1)
	var image := _bake(SpacesimCloudField.seed_for(body_id, layer), morphology, FLOOR_WIDTH, height)
	_bakes += 1
	entry.image = image
	entry.morphology = morphology
	entry.width = FLOOR_WIDTH
	entry.texel = (TAU * radius) / float(FLOOR_WIDTH)
	entry.threshold = threshold_for(image, coverage)
	entry.ramp_mean = mean_exceedance(image, entry.threshold)
	# **The optical depth is derived here, from this image**, when the layer states none: `-ln(1 - ramp_mean)` is
	# the depth whose transmittance is the mean thickness, which is the equivalence the shadow already uses. So the
	# mean the gain is fitted to is `mean(R(tau))` for every layer, ramp or tau, and one map cannot carry two laws.
	entry.opacity_mean = mean_opacity(image, entry.threshold, _column_depth(entry.ramp_mean, depth))
	entry.texture = ImageTexture.create_from_image(image)


## **The one place a map is generated**, so the GPU path is a substitution and not a second code path.
##
## The GPU is tried first and the CPU is the fallback, in that order and for one reason each: the field
## costs **6.9 microseconds a texel interpreted and 1.4 nanoseconds on the GPU** (measured — see
## `tests/probe_cloud_bake.gd`), and **a local rendering device does not exist in headless mode** — so a
## headless run, which is every run of `tests/run.sh`, uses the CPU path by construction rather than by a
## flag, and the GPU path being exercised is something `tests/gpu_check.sh` asserts rather than assumes.
##
## **`bail` does not reach the GPU path, and that is an improvement rather than an omission.** A bake is
## abandoned mid-flight because it can be minutes; a dispatch cannot be interrupted but finishes in
## milliseconds, so the worst a `close()` waits for is one dispatch. The flag is still passed to the CPU
## path, which is where the long bakes are.
func _bake(
	seed: int, morphology: SpacesimCloudModel.Morphology, width: int, height: int,
	uv_origin: Vector2 = Vector2(0.0, 0.0), uv_size: Vector2 = Vector2(1.0, 1.0)
) -> Image:
	if gpu_available():
		var baked := _gpu.bake(seed, morphology, width, height, uv_origin, uv_size)
		if baked != null:
			_gpu_bakes += 1
			return baked
	return SpacesimCloudField.bake(seed, morphology, width, height, _bail, uv_origin, uv_size)


## Whether a bake can go to the GPU — which is also the answer to **which thread it may run on**.
##
## The class reference says a local `RenderingDevice` "can be used to do draw and compute operations on a
## separate thread", and the next reading of that is that a `WorkerThreadPool` task may use it. **It
## cannot** (measured 2026-10-17): every call reports
## *"This function (...) can only be called from the render thread"*, the dispatch does nothing, and the
## bake falls back to the CPU — 230 seconds where the GPU would have taken a quarter of a second, with a
## page of errors in the log to explain it. So a GPU bake is done **where the device was opened, on the
## main thread**, and a refinement with a GPU present is not a pool task at all.
func gpu_available() -> bool:
	if not gpu_allowed:
		return false
	if _gpu == null:
		_gpu = SpacesimCloudGpu.new()
	return _gpu.open()


## **The dispatch is main-thread; the MEASUREMENT is not.** Measured 2026-10-17: an 8192×4096 map's
## statistics are `threshold_for` **615 ms** plus `mean_exceedance` **1,145 ms** of GDScript over 33 M
## texels, against 47 ms for the bake itself — so publishing the map in the same call froze the game for
## ~1.8 s on approach, which is what "the game pauses for a bit" was. The GPU cannot do the dispatch on
## another thread; the arithmetic over its result can and does.
func _start_refinement(
	entry: Entry, body_id: String, layer: int, coverage: float,
	morphology: SpacesimCloudModel.Morphology, width: int, depth: float = 0.0
) -> void:
	entry.requested = width
	_bakes += 1
	if gpu_available():
		# Milliseconds of main thread, against minutes of worker thread — see `gpu_available()`.
		var image := _bake(
			SpacesimCloudField.seed_for(body_id, layer), morphology, width, maxi(width / 2, 1)
		)
		if image != null:
			entry.image = image
			# And the statistics go where the CPU bake's already were.
			entry.task = WorkerThreadPool.add_task(
				Callable(self, "_measure").bind(entry, coverage, depth)
			)
			return
	entry.task = WorkerThreadPool.add_task(
		Callable(self, "_bake_refinement").bind(
			entry, body_id, layer, coverage, morphology, width, depth
		)
	)


## **The measurement, on a worker thread**, for whichever path produced the `Image`.
##
## One function because it is one job: the threshold the layer's coverage implies, and the two means the
## ramp or the slab is fitted to. `entry.image` is already set by the caller in both cases.
func _measure(entry: Entry, coverage: float, depth: float) -> void:
	if entry.image == null:
		return
	entry.threshold = threshold_for(entry.image, coverage)
	entry.ramp_mean = mean_exceedance(entry.image, entry.threshold)
	entry.opacity_mean = mean_opacity(
		entry.image, entry.threshold, _column_depth(entry.ramp_mean, depth)
	)


func _bake_refinement(
	entry: Entry, body_id: String, layer: int, coverage: float,
	morphology: SpacesimCloudModel.Morphology, width: int, depth: float = 0.0
) -> void:
	var height := maxi(width / 2, 1)
	var image := _bake(SpacesimCloudField.seed_for(body_id, layer), morphology, width, height)
	entry.image = image
	if image != null:
		_measure(entry, coverage, depth)


## **Least-recently-used, and never a map with a task in flight** — its id has to be released on the
## main thread, and a task holding an evicted entry would release it into nothing.
func _trim() -> void:
	while _entries.size() > MAX_ENTRIES:
		var oldest_key := ""
		var oldest := 1 << 62
		for key in _entries:
			var entry: Entry = _entries[key]
			if entry.task != -1:
				continue
			if entry.last_used < oldest:
				oldest = entry.last_used
				oldest_key = key
		if oldest_key.is_empty():
			return
		_entries.erase(oldest_key)
