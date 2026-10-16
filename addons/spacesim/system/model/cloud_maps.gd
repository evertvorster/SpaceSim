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
	## **The percentile the layer's coverage implies**, 0 to 1, computed when the map was baked.
	var threshold := 0.0
	## The `WorkerThreadPool` task id of a refinement in flight, or -1.
	var task := -1
	## The width that task is baking, so a second request does not start a third.
	var requested := 0
	var last_used := 0


var _entries: Dictionary = {}
var _clock := 0
## How many bakes have been started, including the synchronous floors. For the suite, which needs to
## show that a cache hit is a hit.
var _bakes := 0


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


## The map for one body's layer, baking or refining as this distance needs.
##
## **Returns whatever is available now** — never null once a floor has been baked, and never a stall. A
## refinement that is still in flight leaves the previous map in place, so the picture improves rather
## than blinking.
func map(
	body_id: String,
	layer: int,
	radius: float,
	coverage: float,
	distance: float,
	morphology: SpacesimCloudModel.Morphology
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
		_bake_floor(entry, body_id, layer, coverage, morphology)

	entry.last_used = _clock
	if entry.task == -1 and wanted > entry.width:
		_start_refinement(entry, body_id, layer, coverage, morphology, wanted)
	_trim()
	return entry.texture


## Finishes every bake that has completed, **on the main thread**, and returns how many it took.
##
## Call it once a frame. The texture is created here rather than in the task because a `RenderingServer`
## texture is the main thread's.
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
		if entry.image != null:
			entry.width = entry.image.get_width()
			entry.texture = ImageTexture.create_from_image(entry.image)
		finished += 1
	return finished


## How many refinements are in flight.
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


## How many bakes have been started. The suite uses it to show a cache hit is a hit.
func bakes() -> int:
	return _bakes


## Drop everything. **Waits for anything in flight**, because a task holds its entry and a released id is
## cheaper than a task nobody owns.
func clear() -> void:
	for key in _entries:
		var entry: Entry = _entries[key]
		if entry.task != -1:
			WorkerThreadPool.wait_for_task_completion(entry.task)
			entry.task = -1
	_entries.clear()


## The synchronous floor: a body gets *a* map on the frame it is first seen.
func _bake_floor(
	entry: Entry, body_id: String, layer: int, coverage: float,
	morphology: SpacesimCloudModel.Morphology
) -> void:
	var height := maxi(FLOOR_WIDTH / 2, 1)
	var image := SpacesimCloudField.bake(
		SpacesimCloudField.seed_for(body_id, layer), morphology, FLOOR_WIDTH, height
	)
	_bakes += 1
	entry.image = image
	entry.width = FLOOR_WIDTH
	entry.threshold = threshold_for(image, coverage)
	entry.texture = ImageTexture.create_from_image(image)


func _start_refinement(
	entry: Entry, body_id: String, layer: int, coverage: float,
	morphology: SpacesimCloudModel.Morphology, width: int
) -> void:
	entry.requested = width
	entry.task = WorkerThreadPool.add_task(
		Callable(self, "_bake_refinement").bind(
			entry, body_id, layer, coverage, morphology, width
		)
	)
	_bakes += 1


## Runs on a worker thread. **Writes only into the entry it was handed**, and the main thread does not
## read it until `poll()` has seen the task complete — which is what makes the handoff safe without a
## lock.
func _bake_refinement(
	entry: Entry, body_id: String, layer: int, coverage: float,
	morphology: SpacesimCloudModel.Morphology, width: int
) -> void:
	var height := maxi(width / 2, 1)
	var image := SpacesimCloudField.bake(
		SpacesimCloudField.seed_for(body_id, layer), morphology, width, height
	)
	entry.image = image
	entry.threshold = threshold_for(image, coverage)


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
