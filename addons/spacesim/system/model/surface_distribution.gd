class_name SpacesimSurfaceDistribution
extends RefCounted
## **The field's own DISTRIBUTION, measured once per body** — not a map of it, and nothing draws this.
##
## The ground is no longer a texture: `body_surface.gdshader` evaluates `surface_height` at every pixel, so the
## planet has no raster to bake, refine, tile or reconstruct (Evert, 2026-10-28: *"I would like to stop having a
## raster at all."*). What the shader still cannot do is **measure** — a formula cannot tell you its own 70.8th
## percentile — and two numbers come from that measurement:
##
## - the **colour ramp's** band edges, because a band is authored as an *area fraction* ("oceans are 70.8 % of it")
##   and a shader needs *heights*;
## - the **sea level**, which is the percentile the liquid band's share implies, held as the datum the displacement
##   will measure `height - sea_level` from.
##
## So the bake survives for exactly that: one 256-wide sample of the field at build, read back and reduced to a
## `65`-entry table. **`QUANTILES` entries are the interface; the texture is an implementation detail that never
## leaves this file.**
##
## ## Why the bake is at build time, and on a local device
##
## `SpacesimSurfaceGpu` bakes on a **local `RenderingDevice`**, whose calls are render-thread-only, so this runs
## inside `_ready` and never in a frame. A refining map was tried first and exhausted the engine's RID pools inside
## a four-and-a-half-minute flight — *"Element limit reached"*, then a leaked `VersatileResourceTemplate` at exit —
## which is why the device is released the moment the measurement is taken and nothing holds one for a session.

## The width the field is sampled at for the measurement. **Its own cost knob, not a picture knob**: a 256 x 128
## sample is 32,768 evaluations of the field, which is a fraction of a millisecond on the GPU, and a percentile
## table needs no more resolution than that to be stable to three decimals.
const BUILD_WIDTH := 256

## Entries in the percentile table. One per 1/64th of the area: enough that a band edge between two of them is a
## lerp and not an assumption, and few enough to publish as a `PackedFloat32Array`.
const QUANTILES := 65

## **The most pixels `quantiles_of` will read**, which is what makes its cost independent of the sample's size.
## `get_pixel()` is a GDScript call: a full pass over a 2,048 map was already two million of them, and an 8,192 map
## would be thirty-three million — seconds per body, at build, for a percentile. A regular stride is unbiased for a
## distribution, so the subsample step is whatever brings the count under this budget.
const QUANTILE_BUDGET := 1 << 18

## Histogram bins the sample is reduced into before the quantiles are walked. Finer than the table by 30x, so the
## table's entries are the histogram's edges and not the other way round.
const HISTOGRAM_BINS := 2048


## One body's measurement: its percentile table, or why it has none.
class Entry:
	## The value at each 1/64th of the area, ascending — the percentile table.
	var quantiles := PackedFloat32Array()
	## Why this body has no table, or an empty string.
	var error := ""

	## **The field value at a given area fraction** — the sea level for an ocean fraction, a band edge for a
	## coverage.
	func value_at(share: float) -> float:
		return SpacesimSurfaceDistribution.value_at(quantiles, share)


## **The interpolation every band edge and the sea level goes through**, so there is one definition of what a
## percentile means in field units: clamped, linear between the table's 1/64th entries.
static func value_at(table: PackedFloat32Array, share: float) -> float:
	if table.is_empty():
		return 0.0
	var position := clampf(share, 0.0, 1.0) * float(table.size() - 1)
	var low := int(floor(position))
	var high := mini(low + 1, table.size() - 1)
	return lerpf(table[low], table[high], position - float(low))


## A quantile table for a field that is simply linear over [-1, 1]. **The placeholder a material is built with**,
## before any measurement exists, and what a test uses to check the ramp without a bake.
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


## **Measure one body's field, once.** Called from `SpacesimSystemScene._build_body`, inside `_ready` and therefore
## before the first frame — see the header for why that is not negotiable.
func prepare(body_id: String, radius: float) -> Entry:
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
	var image := _gpu.bake(plan, BUILD_WIDTH, BUILD_WIDTH / 2)
	if image == null:
		entry.error = _gpu.error()
		_failed = true
		return entry
	_bakes += 1
	entry.quantiles = quantiles_of(image)
	# **No `ImageTexture`, no mipmaps, no width.** Nothing samples this image — it is read here, reduced to 65
	# numbers, and dropped. Building a texture from it and handing it to a material was the *raster*, and it is what
	# the whole of this class used to be about.
	return entry


## How many bakes have run — one per body with a surface, and the suite asserts it does not grow per frame.
func bakes() -> int:
	return _bakes


## **Release the bake device.** Called from `SpacesimSystemScene.build()` once every body is prepared, so no local
## `RenderingDevice` outlives the bake that needed it — a device left alive for the process to destroy at teardown
## segfaults on exit, which this project has paid for.
func close() -> void:
	if _gpu != null:
		_gpu.close()
		_gpu = null


## Why a bake could not run, or an empty string.
func error() -> String:
	if _failed:
		return "no rendering device to measure a surface on"
	return ""


func _open() -> bool:
	if _gpu == null:
		_gpu = SpacesimSurfaceGpu.new()
	return _gpu.open()


## How many RIDs the bake device holds right now — **zero between bakes**, which the GPU suite asserts. The same
## instrument its cloud twin carries, through the same shape of accessor, so a leak in either path is a failure
## rather than a silence.
func gpu_live_rids() -> int:
	return 0 if _gpu == null else _gpu.live_rids()


# ===== THE MEASUREMENT ===============================================================

## **The value at each 1/64th of the area, ascending** — the table every band edge and the sea level is read from,
## measured off a sample of the field itself rather than assumed from its formula.
static func quantiles_of(image: Image) -> PackedFloat32Array:
	var bins := PackedInt32Array()
	bins.resize(HISTOGRAM_BINS)
	bins.fill(0)
	var total := 0
	var low := INF
	var high := -INF
	var step := 1
	while (image.get_width() / step) * (image.get_height() / step) > QUANTILE_BUDGET:
		step *= 2
	for row in range(0, image.get_height(), step):
		for column in range(0, image.get_width(), step):
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
