class_name SpacesimSurfaceMaps
extends RefCounted
## **A body's baked surface maps, and the numbers measured off them.**
##
## Two bakes of one field, each with a fixed job:
##
##  - **coarse** — `COARSE_WIDTH` wide, baked once per body and **never refined**. It carries the ocean mask,
##    the band ramp's input and the sea level. It has to be an *absolute* resolution, which is why it is a
##    bake of its own rather than a mip of the detail map: mip N of a 1,024-wide map and mip N of a 4,096-wide
##    one are different low-passes, so the coastline would move every time the detail refined.
##  - **detail** — the width the distance law asks for, refined as a body is approached. It carries the
##    shading height and the gradient the normals are made from.
##
## **Nothing here decides anything about the surface.** The seed, the frequencies, the band structure and the
## ocean fraction are the derivation's ([code]SpacesimSurfaceField[/code] and
## [code]SpacesimSurfaceModel[/code]); this class bakes, caches, and **measures** — the one thing a map can
## tell you that a formula cannot is where its own distribution puts a percentile.
##
## ## Where the percentile table comes from, and why it is the useful object
##
## Bands are authored as *area fractions* ("oceans are 70.8 % of it") and a shader needs *heights*. The
## bridge is the baked field's own distribution, so every coarse bake produces **65 quantiles** — the value
## at each 1/64th of the area — and everything downstream interpolates that table: the sea level, the band
## edges, the ramp texture. Measured rather than assumed, the same relationship
## `SpacesimCloudMaps.threshold_for()` has with cloud coverage.
##
## ## The bake is on the main thread, and it is small enough that this is fine
##
## A local `RenderingDevice`'s calls are render-thread-only, so a GPU bake cannot go to the worker pool. The
## cloud field needed a pool because its bake is 27 s at 8,192; **this one measured 0.5 ms at 1,024 and 0.7 ms
## at 256**, so a refinement is a frame that costs a millisecond rather than a mechanism. If it ever grows,
## the split is the cloud map's: publish the smaller map now, land the bigger one later.

## The absolute low-pass. Fixed forever: this is the map the masks and the bands read, so it cannot move with
## the detail map's refinement.
const COARSE_WIDTH := 1024
## The width the detail map starts at — the same as the coarse one, because a detail map coarser than the
## coarse map would be a map that adds nothing.
const FLOOR_WIDTH := COARSE_WIDTH
## **The ceiling**, and it is a cost decision rather than a limit: 4,096×2,048 is 8.4 Mtexel, which measured
## **~8 ms** at the field's own rate of about 1 ns a texel. That is a hitch of two frames, once, when a body
## is very close — and the detail below it is the ladder's job (S3), not the map's.
const MAX_WIDTH := 4096
## **The interpolation every band edge and the sea level goes through**, so there is one definition of what
## a percentile means in field units: clamped, linear between the table's 1/64th entries.
static func value_at(table: PackedFloat32Array, share: float) -> float:
	if table.is_empty():
		return 0.0
	var position := clampf(share, 0.0, 1.0) * float(table.size() - 1)
	var low := int(floor(position))
	var high := mini(low + 1, table.size() - 1)
	return lerpf(table[low], table[high], position - float(low))


## Quantiles per table: 65 values, one per 1/64th of the area. 1.5 % resolution on a percentile is finer than
## any band edge needs to be, and the table is 260 bytes.
const QUANTILES := 65

## How many bodies' maps are kept. The coarse map is 1 MB and the detail map up to 32 MB, so this bounds a
## leak across a journey rather than a working set — `_trim()` drops the least recently used whole entry, and
## a body being flown past is re-baked in a millisecond if it is ever wanted again.
const MAX_ENTRIES := 12


## One body's maps and everything measured from them.
class Entry:
	var coarse: ImageTexture
	var detail: ImageTexture
	## The detail map's width; 0 until the first bake lands.
	var width := 0
	## The coarse map's width, which never changes.
	var coarse_width := 0
	## The value at each 1/64th of the area, ascending — the percentile table.
	var quantiles := PackedFloat32Array()
	var last_used := 0
	## Why this body has no map, or an empty string. A body whose bake failed is not retried every frame.
	var error := ""

	## **The field value at a given area fraction** — the sea level for an ocean fraction, a band edge for a
	## coverage.
	func value_at(share: float) -> float:
		return SpacesimSurfaceMaps.value_at(quantiles, share)


## The GPU bake. Kept as a member rather than a parameter so the device is opened once for the whole cache.
var _gpu: SpacesimSurfaceGpu
var _entries: Dictionary = {}
var _clock := 0
var _bakes := 0
var _failed := false


## **The width the detail map should have at a distance** — the same law the cloud maps use, capped. A texel
## `2*pi*r/W` long stops resolving when it projects past a pixel, so the width worth having is
## `2*pi*r/(pixel_angle * distance)`; the law lives in `SpacesimCloudMaps.required_width` and this only
## clamps it to this class's own floor and ceiling.
##
## `distance` is to the **surface**, not to the centre: at 2,000 km altitude the two differ by a fifth and
## using the centre costs two quantisation steps, which reads as an obviously blocky map.
static func required_width(radius: float, distance: float, pixel_angle: float) -> int:
	var wanted := SpacesimCloudMaps.required_width(radius, distance, pixel_angle)
	return clampi(wanted, FLOOR_WIDTH, MAX_WIDTH)


## **A body's maps for this frame** — baked on first sight, refined when the distance law asks for more.
##
## `ocean_fraction` is `SpacesimSurfaceModel.sea_level_percentile()`, `pixel_angle` is the camera's.
func map(
	body_id: String, radius: float, distance: float, pixel_angle: float, ocean_fraction: float
) -> Entry:
	# **A failure is remembered rather than retried.** Without this a headless run — where there is no local
	# `RenderingDevice`, so every bake fails — would allocate an entry per body per frame for the whole run.
	if _failed:
		var none := Entry.new()
		none.error = error()
		return none
	var entry: Entry = _entries.get(body_id)
	_clock += 1
	if entry == null:
		entry = Entry.new()
		_entries[body_id] = entry
		_bake_entry(entry, body_id, radius, ocean_fraction)
		if entry.error != "":
			_entries.erase(body_id)
			return entry
	entry.last_used = _clock
	var wanted := required_width(radius, distance, pixel_angle)
	if entry.width < wanted and not _failed:
		_bake_detail(entry, body_id, radius, wanted)
	_trim()
	return entry


## How many bakes have run, including the coarse ones. For the suite, which needs to show that a second look
## at the same body is a cache hit rather than another bake.
func bakes() -> int:
	return _bakes


func entry_for(body_id: String) -> Entry:
	return _entries.get(body_id)


## **Release the device.** A local `RenderingDevice` left alive to be destroyed at process teardown
## segfaults the process on exit, so this has to be called — `SpacesimSystemScene.close()` is the caller.
func close() -> void:
	if _gpu != null:
		_gpu.close()
	_entries.clear()


## Why a bake could not run, or an empty string — an empty one means the cache is working or has not tried.
func error() -> String:
	if _failed:
		return "no rendering device to bake a surface map on"
	return ""


func _bake_entry(entry: Entry, body_id: String, radius: float, ocean_fraction: float) -> void:
	if not _open():
		entry.error = error()
		return
	var plan := SpacesimSurfaceField.plan(body_id, radius)
	var coarse := _gpu.bake(plan, COARSE_WIDTH, COARSE_WIDTH / 2)
	if coarse == null:
		entry.error = _gpu.error()
		_failed = true
		return
	_bakes += 1
	entry.quantiles = quantiles_of(coarse)
	entry.coarse = ImageTexture.create_from_image(coarse)
	entry.coarse_width = COARSE_WIDTH
	# The detail map starts at the floor, which is the coarse width — and it is a second bake rather than the
	# same image, because the two are separate textures with separate jobs and a shared one would be the
	# classification trap this class exists to avoid.
	_bake_detail(entry, body_id, radius, FLOOR_WIDTH)


func _bake_detail(entry: Entry, body_id: String, radius: float, width: int) -> void:
	var plan := SpacesimSurfaceField.plan(body_id, radius)
	var image := _gpu.bake(plan, width, width / 2)
	if image == null:
		entry.error = _gpu.error()
		return
	_bakes += 1
	# **Mips**, because the shader samples this map at whatever lod the hardware picks and a live procedural
	# would have no filtered pyramid at all.
	image.generate_mipmaps()
	entry.detail = ImageTexture.create_from_image(image)
	entry.width = width


func _open() -> bool:
	if _gpu == null:
		_gpu = SpacesimSurfaceGpu.new()
	return _gpu.open()


func _trim() -> void:
	if _entries.size() <= MAX_ENTRIES:
		return
	var oldest := ""
	var oldest_clock := _clock + 1
	for key in _entries:
		var entry: Entry = _entries[key]
		if entry.last_used < oldest_clock:
			oldest_clock = entry.last_used
			oldest = key
	if oldest != "":
		_entries.erase(oldest)


# ===== THE MEASUREMENTS ==============================================================

## **The value at each 1/64th of the area, ascending** — the table every band edge and the sea level is read
## from, measured off the map that will be used rather than assumed from the field's formula.
##
## A histogram rather than a sort: 524 k texels is 524 k `get_pixel()` calls, and sorting them in GDScript is
## tens of milliseconds for a number that a 2,048-bin pass gets in one.
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
			# The field is about ±1; a value outside that is clamped into the end bins rather than dropped.
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
	# ramp over exactly `-1 .. 1` cannot catch it, because there the two conventions coincide — which is the
	# documented trap of testing the degenerate case.
	var span := 2.0 / float(HISTOGRAM_BINS - 1)
	var walked := 0
	var target_index := 0
	for bin in HISTOGRAM_BINS:
		walked += bins[bin]
		var share := float(walked) / float(total)
		# Every quantile the cumulative count has reached, filled in order — so the table is monotone even
		# where a bin holds many texels.
		while target_index < QUANTILES and share >= float(target_index) / float(QUANTILES - 1):
			table[target_index] = -1.0 + span * float(bin)
			target_index += 1
	# Anything left (a histogram that ended early on a clamped tail) takes the top value.
	while target_index < QUANTILES:
		table[target_index] = high
		target_index += 1
	# **The ends are the observed extremes, not the clamped bin edges.** Everything outside the field's own
	# range lands in the first or last bin, which reconstructs as ±1 and is a lie of up to the field's headroom
	# — harmless for a band edge, and wrong for a probe or a print that reads the first quantile as a minimum.
	table[0] = low
	table[QUANTILES - 1] = high
	return table


## **The bins in `quantiles_of`.** 2,048 over the field's ±1 gives a 0.1 % resolution in height, which at
## Earth's 8.9 km amplitude is 9 m — well below anything a coastline or a band edge cares about.
const HISTOGRAM_BINS := 2048


## A quantile table for a field that is simply linear over [-1, 1]. **The placeholder a material is built
## with**, before any map exists, and what a test uses to check the ramp without a bake.
static func linear_quantiles() -> PackedFloat32Array:
	var table := PackedFloat32Array()
	table.resize(QUANTILES)
	for index in QUANTILES:
		table[index] = lerpf(-1.0, 1.0, float(index) / float(QUANTILES - 1))
	return table
