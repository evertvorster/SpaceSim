class_name SpacesimSurfaceMaps
extends RefCounted
## **A body's baked surface map, and the numbers measured off it.**
##
## **One map per body, one width, baked once — at scene build, before a frame is drawn.** That is a retreat from
## a refining map, and it is deliberate: see [method prepare] for the flight that forced it.
##
## The map carries the shading height, the gradient the normals come from, the ocean mask and the colour bands.
## The detail *below* the map's texel is the ladder's job (S3), which is a per-pixel evaluation and needs no
## texture at all — so a refining map was never the only way to get close-range detail, and it was the most
## dangerous way to get it.
##
## ## Where the percentile table comes from, and why it is the useful object
##
## Bands are authored as *area fractions* ("oceans are 70.8 % of it") and a shader needs *heights*. The bridge
## is the baked field's own distribution, so every bake produces **65 quantiles** — the value at each 1/64th of
## the area — and everything downstream interpolates that table: the sea level, the band edges, the ramp
## texture. Measured rather than assumed, the same relationship `SpacesimCloudMaps.threshold_for()` has with
## cloud coverage.

## **The one width.** 2,048 × 1,024 puts a texel at 19.5 km on Earth, which is a pixel at 15,000 km altitude
## and four pixels at 4,000 km. Everything finer is the ladder's, and the ladder costs nothing at distance.
const MAP_WIDTH := 2048

## Quantiles per table: 65 values, one per 1/64th of the area. 1.5 % resolution on a percentile is finer than
## any band edge needs to be, and the table is 260 bytes.
const QUANTILES := 65

## The histogram's bins, over the field's ±1: a 0.1 % resolution in height, which at Earth's 8.9 km amplitude
## is 9 m — well below anything a coastline or a band edge cares about.
const HISTOGRAM_BINS := 2048


## One body's map and everything measured from it.
class Entry:
	var map: ImageTexture
	var width := 0
	## The value at each 1/64th of the area, ascending — the percentile table.
	var quantiles := PackedFloat32Array()
	## Why this body has no map, or an empty string.
	var error := ""

	## **The field value at a given area fraction** — the sea level for an ocean fraction, a band edge for a
	## coverage.
	func value_at(share: float) -> float:
		return SpacesimSurfaceMaps.value_at(quantiles, share)


## **The interpolation every band edge and the sea level goes through**, so there is one definition of what a
## percentile means in field units: clamped, linear between the table's 1/64th entries.
static func value_at(table: PackedFloat32Array, share: float) -> float:
	if table.is_empty():
		return 0.0
	var position := clampf(share, 0.0, 1.0) * float(table.size() - 1)
	var low := int(floor(position))
	var high := mini(low + 1, table.size() - 1)
	return lerpf(table[low], table[high], position - float(low))


## A quantile table for a field that is simply linear over [-1, 1]. **The placeholder a material is built
## with**, before any map exists, and what a test uses to check the ramp without a bake.
static func linear_quantiles() -> PackedFloat32Array:
	var table := PackedFloat32Array()
	table.resize(QUANTILES)
	for index in QUANTILES:
		table[index] = lerpf(-1.0, 1.0, float(index) / float(QUANTILES - 1))
	return table


var _gpu: SpacesimSurfaceGpu
var _entries: Dictionary = {}
var _bakes := 0
var _failed := false


## **Bake a body's map, once.** Called from `SpacesimSystemScene._build_body`, which is inside `_ready` and
## therefore before the first frame.
##
## ## Why the bake is not in the frame loop, in one paragraph
##
## A refining map was tried first: the cache noticed the eye approaching and baked a wider map, up to 4,096. It
## exhausted the engine's RID pools inside a four-and-a-half-minute flight — *"Element limit reached"* at
## `_allocate_rid`, then *"Failed to create uniform set for batch"* from the **2D** renderer, then a leaked
## `VersatileResourceTemplate…` at exit, which is the signature the `godot` skill records for a RID leak whose
## damage appears somewhere else entirely. The mechanism: `SpacesimSurfaceGpu` bakes on a **local
## `RenderingDevice`**, and its calls are render-thread-only; doing that repeatedly from `_process`, on a device
## that shares the driver with the frame's own, is the class of thing this project has already paid for once
## with a HUD readback. **Baking at build time takes the calls out of the frame loop entirely**, and the
## device is released immediately afterwards — nothing holds one for the length of a session.
##
## The cost is that the map does not refine as the eye approaches. **Nothing needs it to**: below the map's
## texel the detail comes from the ladder, which is a per-pixel evaluation of the field's own formula, and the
## ladder is band-limited by what a pixel can resolve — so it is *better* at close range than a texture could be,
## and it costs nothing at distance.
func prepare(body_id: String, radius: float, ocean_fraction: float) -> Entry:
	var entry: Entry = _entries.get(body_id)
	if entry != null:
		return entry
	entry = Entry.new()
	_entries[body_id] = entry
	if _failed:
		entry.error = error()
		return entry
	if not _open():
		entry.error = error()
		return entry
	var plan := SpacesimSurfaceField.plan(body_id, radius)
	var image := _gpu.bake(plan, MAP_WIDTH, MAP_WIDTH / 2)
	if image == null:
		entry.error = _gpu.error()
		_failed = true
		return entry
	_bakes += 1
	# **Mips**, because the shader samples this map at whatever lod the hardware picks from the screen-space
	# derivatives, and from orbit it is minified — without a filtered pyramid that is aliasing rather than
	# blurring.
	image.generate_mipmaps()
	entry.quantiles = quantiles_of(image)
	entry.map = ImageTexture.create_from_image(image)
	entry.width = MAP_WIDTH
	# The sea level is not stored — it belongs to the caller's ocean fraction — but measuring it here is what
	# makes the table's meaning checkable, and `tests/probe_surface_maps` prints it.
	entry.value_at(ocean_fraction)
	return entry


## The map for a body, or null if it was never prepared.
func map(body_id: String) -> Entry:
	return _entries.get(body_id)


func entry_for(body_id: String) -> Entry:
	return _entries.get(body_id)


## How many bakes have run — one per body with a surface, and the suite asserts it does not grow per frame.
func bakes() -> int:
	return _bakes


## **Release the bake device.** Called from `SpacesimSystemScene.build()` once every body is prepared, so no
## local `RenderingDevice` outlives the bake that needed it — a device left alive to be destroyed at process
## teardown segfaults the process on exit, and one alive across a session is the risk this class is trying to
## stop taking.
func close() -> void:
	if _gpu != null:
		_gpu.close()
		_gpu = null


## Why a bake could not run, or an empty string.
func error() -> String:
	if _failed:
		return "no rendering device to bake a surface map on"
	return ""


func _open() -> bool:
	if _gpu == null:
		_gpu = SpacesimSurfaceGpu.new()
	return _gpu.open()


# ===== THE MEASUREMENTS ==============================================================

## **The value at each 1/64th of the area, ascending** — the table every band edge and the sea level is read
## from, measured off the map that will be used rather than assumed from the field's formula.
##
## A histogram rather than a sort: 2 Mtexels is 2 M `get_pixel()` calls, and sorting them in GDScript is
## hundreds of milliseconds for a number a single pass gets in one.
static func quantiles_of(image: Image) -> PackedFloat32Array:
	var bins := PackedInt32Array()
	bins.resize(HISTOGRAM_BINS)
	bins.fill(0)
	var total := 0
	var low := INF
	var high := -INF
	for row in image.get_height():
		for column in image.get_width():
			var value := image.get_pixel(column, row).r
			low = minf(low, value)
			high = maxf(high, value)
			# The field is about ±1; a value outside that lands in the end bins rather than being dropped.
			var bin := int(clampf((value + 1.0) * 0.5 * float(HISTOGRAM_BINS - 1), 0.0,
				float(HISTOGRAM_BINS - 1)))
			bins[bin] += 1
			total += 1
	var table := PackedFloat32Array()
	table.resize(QUANTILES)
	if total == 0 or not is_finite(low) or not is_finite(high):
		return table
	# **The reconstruction uses the SAME mapping the binning did** — `-1 .. 1`, fixed — and not the observed
	# `low .. high`. Using the observed range was a real bug for two days: every quantile came back shifted
	# toward the top of the distribution, Earth's sea level landed near the 95th percentile instead of the
	# 70.8th, and the planet drew as a featureless blue ball with a few specks of land. A test on a *linear*
	# ramp over exactly `-1 .. 1` cannot catch it, because there the two conventions coincide — the documented
	# trap of testing the degenerate case.
	var span := 2.0 / float(HISTOGRAM_BINS - 1)
	var walked := 0
	var target_index := 0
	for bin in HISTOGRAM_BINS:
		walked += bins[bin]
		var share := float(walked) / float(total)
		while target_index < QUANTILES and share >= float(target_index) / float(QUANTILES - 1):
			table[target_index] = -1.0 + span * float(bin)
			target_index += 1
	while target_index < QUANTILES:
		table[target_index] = high
		target_index += 1
	# **The ends are the observed extremes, not the clamped bin edges.** Everything outside the field's own
	# range lands in the first or last bin, which reconstructs as ±1 and is a lie of up to the field's headroom
	# — harmless for a band edge, and wrong for a probe or a print that reads the first quantile as a minimum.
	table[0] = low
	table[QUANTILES - 1] = high
	return table
