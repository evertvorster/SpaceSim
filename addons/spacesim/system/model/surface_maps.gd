class_name SpacesimSurfaceMaps
extends RefCounted
## **A body's baked surface map, its ladder, and the numbers measured off it.**
##
## **The map is a LADDER, not one bake.** A body is baked at `BUILD_WIDTH` when the scene is built — small, cheap,
## and enough to *measure* the field's distribution — and then refines **upward, one step at a time**, as the eye
## closes, to a ceiling set by the resolution the scene is being rendered at. See [method base_max_width]. The
## steps exist because the ceiling is derived rather than fixed, and because a cheap rung on screen immediately is
## better than one expensive bake arriving late.
##
## **Nothing here bakes on a cadence.** A width is asked for when the law asks for one the map does not have —
## the same shape as `SpacesimPatches.walk_is_due` — and an idle frame does no surface work at all. Bakes run on
## the render thread through `SpacesimSurfaceBakePass`, one in flight.
##
## The map carries the shading height, the gradient the normals come from, the ocean mask and the colour bands.
## The detail *below* the map's texel is the ladder's job (S3), which is a per-pixel evaluation and needs no
## texture at all.
##
## ## Where the percentile table comes from, and why it is the useful object
##
## Bands are authored as *area fractions* ("oceans are 70.8 % of it") and a shader needs *heights*. The bridge
## is the baked field's own distribution, so every bake produces **65 quantiles** — the value at each 1/64th of
## the area — and everything downstream interpolates that table: the sea level, the band edges, the ramp
## texture. Measured rather than assumed, the same relationship `SpacesimCloudMaps.threshold_for()` has with
## cloud coverage.

## **The width a body is baked at when the scene is built, and the floor of the ladder.** 256 × 128 puts a texel
## at 312 km on Earth, which is far too coarse to *draw* — and it is not for drawing: it is the **measurement**
## bake, whose job is the distribution the sea level and the band edges are read from (a distribution converges on
## a small sample), and it is on screen in the first frame while the ladder climbs.
##
## **What this replaced, and why:** one 4,096-wide bake per body at build, for all sixteen bodies in Sol — 16 MiB
## each plus mips plus a synchronised readback, so ~341 MiB and ~256 MiB of readback before the first frame, for
## bodies nobody approaches. Work with no predicted need is the one thing [[SpaceSim/LOD — The Principle at Work|the
## LOD principle]] forbids outright.
const BUILD_WIDTH := 256
## **The fraction of the render resolution the ceiling is**, and the registry's default. A setting rather than a
## constant because it is the one number that moves a planet's close-range cost, and it must be movable while
## flying to be useful.
const DEFAULT_BASE_FRACTION := 0.5
## The narrowest map worth baking, and the clamp on anything derived or overridden.
const MIN_WIDTH := 128
## **The hard ceiling on any width**, whatever the fraction asks for. A whole-body map past this is resolution no
## display can show: at 4K a disc that fills the frame is 2,160 px across, and an equirect of width `W` shows
## `W/pi` texels across that diameter.
const MAX_WIDTH := 8192

## Quantiles per table: 65 values, one per 1/64th of the area. 1.5 % resolution on a percentile is finer than
## any band edge needs to be, and the table is 260 bytes.
const QUANTILES := 65

## **How many texels may be read for the quantiles, and the step that keeps it there.** `get_pixel()` is a
## GDScript call, so an exhaustive pass over a 4,096 map would be 8.4 million of them and over an 8,192 map
## 33.5 million — seconds per body, at build, to estimate a percentile. The step doubles until the sample fits
## the budget, so **small images are read exactly** and a big one is subsampled regularly, which is unbiased for
## a distribution.
const QUANTILE_BUDGET := 1 << 18

## The histogram's bins, over the field's ±1: a 0.1 % resolution in height, which at Earth's 8.9 km amplitude
## is 9 m — well below anything a coastline or a band edge cares about.
const HISTOGRAM_BINS := 2048


## One body's map and everything measured from it.
class Entry:
	## The build-time map: mipmapped, and the one that is *measured*. It is what is drawn until a refined map
	## lands, and again if the eye recedes.
	var base: ImageTexture
	## The refined map, on the rendering device, with no mips — it is only ever magnified.
	var refined: Texture2DRD
	var refined_width := 0
	## The width of what is being drawn: `BUILD_WIDTH` until a rung lands, then that rung's.
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
	var image := _gpu.bake(plan, BUILD_WIDTH, BUILD_WIDTH / 2)
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
	entry.base = ImageTexture.create_from_image(image)
	entry.width = BUILD_WIDTH
	# The sea level is not stored — it belongs to the caller's ocean fraction — but measuring it here is what
	# makes the table's meaning checkable, and `tests/probe_surface_maps` prints it.
	entry.value_at(ocean_fraction)
	return entry


## The cache's entry for a body, or null if it was never prepared. **Does not bake and does not refine.**
func map(body_id: String) -> Entry:
	return _entries.get(body_id)


## **The width worth having at a distance.** The law is `SpacesimCloudMaps.required_width` — a texel stops
## resolving when it projects past a pixel — clamped to this class's own floor and ceiling, and the ceiling is the
## **caller's** to supply because it is a property of the display rather than of the body. It lives there because
## the two maps answer the same question, and one home for a law is one place for it to be wrong.
static func required_width(
	radius: float, distance: float, pixel_angle: float, cap: int = MAX_WIDTH
) -> int:
	var wanted := SpacesimCloudMaps.required_width(radius, distance, pixel_angle)
	return clampi(wanted, BUILD_WIDTH, clampi(cap, BUILD_WIDTH, MAX_WIDTH))


## **The ceiling of the whole-body ladder, as a width** — **a fraction of the resolution the scene is being
## rendered at**, and it is *always* derived: there is no absolute width to override, only the fraction.
##
## Evert, 2026-10-19: *"surface.max_base_width should always be derived, expressed as a percentage. 0.5 would
## be the default setting, making the texture 50% of the scene resolution."* So the knob is
## `surface.max_base_fraction` — 0.5 by default — and it is read per frame rather than cached, because a cached
## setting is a cold setting and this one exists to be moved **while flying**, to watch a planet's close-range
## cost move with it.
##
## **The render resolution and not the window's**, because that is where the pixel angle comes from and where
## the pixels actually are ([[SpaceSim/Display and Window|Display and Window]]). A quarter of the width is the
## map's height, since an equirect is 2:1: at the 1280x720 render default, half gives 640x320.
##
## **Deliberately soft, and that is the point:** at 1920x1080 half the width is 960, and a disc that fills the
## frame is 1,080 px across, so the map shows `960/pi` = 306 texels across it — about 3.5 pixels per texel. The
## base only has to hold the picture while the disc is a fraction of the screen; the near field is the tiles'
## business.
static func base_max_width(render_size: Vector2i, fraction: float = DEFAULT_BASE_FRACTION) -> int:
	if render_size.x <= 0:
		return MIN_WIDTH
	var wanted := int(round(float(render_size.x) * maxf(fraction, 0.0)))
	return clampi(wanted, MIN_WIDTH, MAX_WIDTH)


## **The refinement, if the game attached one.** Null in a headless run, in the suite and in a probe — there is
## no camera and no compositor there, and the build-time map is the whole answer.
var _bake_pass: SpacesimSurfaceBakePass


## Hand the cache the render-thread bake pass. From then on, approaching a body asks for a wider map.
func attach_bake(bake_pass: SpacesimSurfaceBakePass) -> void:
	_bake_pass = bake_pass


## **Collect finished bakes.** Main thread, once a frame. Returns the bodies whose map changed, so the scene
## can repoint a material — the cache does not own materials and will not reach into one.
func poll() -> Array:
	var changed: Array = []
	if _bake_pass == null:
		return changed
	var ready := _bake_pass.take_ready()
	for body_id in ready:
		var entry: Entry = _entries.get(body_id)
		if entry == null:
			continue
		var bake: Dictionary = ready[body_id]
		var previous := entry.refined
		entry.refined = bake["texture"]
		entry.refined_width = int(bake["width"])
		entry.width = entry.refined_width
		if previous != null:
			_bake_pass.release(previous)
		changed.append(body_id)
	return changed


## **What to draw this body with, and at what width — and the one place a bake is ever asked for.**
##
## The law gives the width the eye wants; the map in hand is what it has. If the law wants more, **the NEXT RUNG**
## is asked for — not the final width — so the ladder climbs 256 → 512 → … one bake in flight, and each rung is
## on screen while the next is baked. That is the reverse mipmap: cheap and coarse first, and it means a ladder
## started late still shows something immediately.
##
## **Nothing is baked because a frame happened.** A width is asked for only when the law asks for one the map does
## not have; with the eye still, this returns the same texture and asks for nothing.
##
## The texture becomes visible the frame after it lands, so this returns the old one until then; that is why
## `poll()` reports *changes* rather than the scene asking "is it different".
func map_for(
	body_id: String, radius: float, distance: float, pixel_angle: float, cap: int
) -> Dictionary:
	var entry: Entry = _entries.get(body_id)
	if entry == null:
		return {}
	if _bake_pass == null:
		return {"texture": entry.base, "width": entry.width}
	var wanted := required_width(radius, distance, pixel_angle, cap)
	if wanted <= entry.width:
		# **The map is already as fine as the eye can use, and the extra rungs are given back** — a recede costs
		# no memory, because the build map is still the floor.
		if entry.refined != null and wanted <= BUILD_WIDTH:
			_bake_pass.release(entry.refined)
			entry.refined = null
			entry.refined_width = 0
			entry.width = BUILD_WIDTH
		return _drawn(entry)
	# **One rung up, or straight to the width the law wants if that is nearer.** The pass refuses a second request
	# while one is in flight, so the next rung is asked for the frame after this one lands.
	_bake_pass.request(
		body_id, SpacesimSurfaceField.plan(body_id, radius), next_bake_width(entry.width, wanted)
	)
	return _drawn(entry)


## **The next rung of the ladder**: double the width in hand, and no further than what is needed.
##
## A pure function, so the ascent is checkable headlessly — the pass and the GPU are not required to know that
## 256 → 512 → 1,024 and that a request never overshoots the law. `wanted` is already clamped to the cap.
static func next_bake_width(width_in_hand: int, wanted: int) -> int:
	var current := maxi(width_in_hand, BUILD_WIDTH)
	if wanted <= current:
		return current
	return mini(current * 2, wanted)


## What the material should be sampling now, plus the window when one is in hand.
static func _drawn(entry: Entry) -> Dictionary:
	if entry.refined != null:
		return {"texture": entry.refined, "width": entry.refined_width}
	return {"texture": entry.base, "width": entry.width}


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
## **Sampled, not exhaustive.** `get_pixel()` is a GDScript call, so a full pass over a 2,048 map was already
## two million of them and an 8,192 map would be thirty-three — measured in seconds per body, at build, for a
## percentile. Every `QUANTILE_STEP`th texel in each axis is a regular subsample: unbiased for a distribution,
## and it makes the cost independent of the map's size.
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
