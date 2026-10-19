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

## **One slot in the tile table**: a tile of one body's map, sitting in a layer of the shared array.
##
## The table is fixed (`SpacesimSurfaceTiles.MAX_TILES`) and belongs to the *cache* rather than to a body, because
## the array is one allocation for the whole scene: the eye is only ever close to one body, and a tile nobody wants
## is simply overwritten by the next one somebody does.
class Slot:
	var body_id := ""
	var level := -1
	var x := 0
	var y := 0
	var layer := -1
	var ready := false
	## True while a bake for this slot is in flight — so a slot is never asked for twice because the pass was
	## busy the first time.
	var pending := false


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
	## **The eye this body's request was last decided at** — the gate's state, kept where the answer's inputs
	## live. Zero distance means "never decided", which is due.
	var last_distance := 0.0
	var last_pixel := 0.0
	var last_cap := 0
	## Bumped when a rung lands; compared with what a material was last told, so a bake reaches the picture
	## without every frame republishing on the chance that it has.
	var version := 0
	var published_version := 0
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


## **The tiles worth drawing for one body, walked and requested** — and the near field's whole policy.
##
## The walk is `SpacesimSurfaceTiles.select`, gated by `walk_is_due` so it re-runs only when the answer can change.
## A selected tile that has no slot gets one, and a slot with no bake asks the pass for it — one request at a time,
## so the tiles land over successive frames and the ground sharpens rather than stalling.
##
## Returns **true when the published set changed**, so the scene republishes rects to the materials. That is the
## whole interface: the cache owns the table, the scene owns the materials.
func update_tiles(
	body_id: String, radius: float, distance: float, pixel_angle: float,
	eye_direction: Vector3, cap: int
) -> bool:
	if _bake_pass == null:
		return false
	# **No near field until the whole-body map has run out.** A far body's disc is smaller than the map that already
	# covers it, so its tiles are work without a need and — because the table is shared — they cost the body the eye
	# *is* looking at. See [method near_field_is_worth_it].
	if not near_field_is_worth_it(radius, distance, pixel_angle, cap):
		return _release_tiles(body_id)
	# **The walk is gated; the requests are not.** Those are two different things and conflating them was a bug:
	# a walk whose requests were all refused because the pass was busy with a whole-body rung would record the eye
	# state as walked, and the gate would then keep it closed until the eye moved — so the near field never
	# arrived at all. The walk is expensive and must be rare; asking the pass for a slot that is still empty is
	# cheap and idempotent, and `request_tile` refuses while one is in flight anyway.
	var entry: Entry = _entries.get(body_id)
	var base_width: int = entry.width if entry != null else BUILD_WIDTH
	var last: Dictionary = _tile_last.get(body_id, {})
	if SpacesimSurfaceTiles.walk_is_due(
		float(last.get("distance", 0.0)), last.get("direction", Vector3.ZERO),
		float(last.get("pixel", 0.0)), int(last.get("base_width", 0)),
		distance, eye_direction, pixel_angle, base_width
	):
		_tile_last[body_id] = {
			"distance": distance, "direction": eye_direction, "pixel": pixel_angle,
			"base_width": base_width,
		}
		var wanted: Array = SpacesimSurfaceTiles.select(
			radius, distance, eye_direction, pixel_angle, base_width
		)
		_reconcile_slots(body_id, wanted)
	_request_missing_slots(body_id, radius)
	return _republish_if_changed(body_id)


## **Republish only when what a material would be told has changed** — a slot freed, a slot made, or a tile that
## landed. A walk that changes nothing costs the rects nothing.
func _republish_if_changed(body_id: String) -> bool:
	var version := int(_tile_version.get(body_id, 0))
	if version == int(_published_version.get(body_id, -1)):
		return false
	_published_version[body_id] = version
	return true


## **Make the slots match the selection**: free what this body no longer wants, and make a slot for each tile that
## has none. Nothing is baked here — a slot with no bake is what [method _request_missing_slots] fills.
func _reconcile_slots(body_id: String, wanted: Array) -> void:
	var keep := {}
	for tile in wanted:
		keep["%d/%d/%d" % [int(tile[0]), int(tile[1]), int(tile[2])]] = true
	for index in _slots.size():
		var slot: Variant = _slots[index]
		if slot == null:
			continue
		var own: Slot = slot
		if own.body_id != body_id:
			continue
		if keep.has("%d/%d/%d" % [own.level, own.x, own.y]):
			continue
		# **An ancestor is kept until the tiles inside it have landed.** Crossing a level used to free a tile's
		# pixels and queue its four children, so the region fell back to the whole-body map and sharpened again a
		# frame later — the pulse Evert saw in flight. Now the coarser tile stays published underneath (the shader
		# takes the finest rectangle, so the children win the moment they are ready) and it is let go then.
		if _holds_unready_child(own, keep, body_id):
			continue
		_slots[index] = null
		_bump_tiles(body_id)
	var placed := {}
	for slot in _slots:
		if slot == null:
			continue
		var own: Slot = slot
		if own.body_id == body_id:
			placed["%d/%d/%d" % [own.level, own.x, own.y]] = true
	# Nearest first — the walk emitted them in that order, and the budget leaves room for exactly this.
	for tile in wanted:
		var key := "%d/%d/%d" % [int(tile[0]), int(tile[1]), int(tile[2])]
		if placed.has(key):
			continue
		var layer := _free_layer()
		if layer < 0:
			# **Required work outranks a retained fallback.** The reserve is meant to keep this from happening, but a
			# table can still fill — a second body inside its own crossover, or a fast descent crossing two levels
			# before the first one's children land — and the right casualty is an ancestor that is only being kept as
			# a fallback, never the tile that is actually needed. Without this the walk silently stops placing, which
			# is the pulse arriving by another route.
			layer = _reclaim_layer(body_id, keep)
		if layer < 0:
			return
		var slot := Slot.new()
		slot.body_id = body_id
		slot.level = int(tile[0])
		slot.x = int(tile[1])
		slot.y = int(tile[2])
		slot.layer = layer
		_slots[layer] = slot
		placed[key] = true
		_bump_tiles(body_id)


## **Whether a slot that is no longer wanted still covers tiles that have not landed** — in which case it is the
## fallback rather than a waste, and stays until they do.
##
## Only a *descendant* counts: a tile whose rectangle lies inside the slot's. A slot whose area the eye has left
## falls straight out, which is what keeps a recede from holding anything.
func _holds_unready_child(own: Slot, keep: Dictionary, body_id: String) -> bool:
	var mine := SpacesimSurfaceTiles.rect_of(own.level, own.x, own.y)
	for slot in _slots:
		if slot == null:
			continue
		var other: Slot = slot
		if other.body_id != body_id or other == own:
			continue
		var theirs := SpacesimSurfaceTiles.rect_of(other.level, other.x, other.y)
		if not SpacesimSurfaceTiles.rect_contains(mine, theirs):
			continue
		if not keep.is_empty() and not keep.has("%d/%d/%d" % [other.level, other.x, other.y]):
			continue
		if not other.ready:
			return true
	return false


## **Let go of a body's whole near field** — the eye has receded past the point where tiles beat the map, so their
## layers are worth more to whatever comes next. Returns whether anything was actually freed, which is what the
## caller needs to know to republish.
func _release_tiles(body_id: String) -> bool:
	var freed := false
	for index in _slots.size():
		var slot: Variant = _slots[index]
		if slot == null:
			continue
		var own: Slot = slot
		if own.body_id != body_id:
			continue
		_slots[index] = null
		freed = true
	if freed:
		_bump_tiles(body_id)
	# **Forget the eye state**, so the next approach walks at once rather than waiting for a tenth of the distance.
	_tile_last.erase(body_id)
	return freed and _republish_if_changed(body_id)


## **Free a slot this body is only holding as a fallback**, and hand its layer back. The tiles worth sacrificing are
## exactly the ones no longer in the selection — everything still wanted is in `requested` — so a reclaim never costs
## a tile the eye is asking for.
func _reclaim_layer(body_id: String, requested: Dictionary) -> int:
	for index in _slots.size():
		var slot: Variant = _slots[index]
		if slot == null:
			continue
		var own: Slot = slot
		if own.body_id != body_id:
			continue
		if requested.has("%d/%d/%d" % [own.level, own.x, own.y]):
			continue
		_slots[index] = null
		_bump_tiles(body_id)
		return index
	return -1


## **Ask the pass for one slot that has no tiles in it yet.** One request per call, because the pass takes one at a
## time; a refusal (the pass is baking a whole-body rung) simply leaves the slot unfilled and the next frame tries
## again.
func _request_missing_slots(body_id: String, radius: float) -> void:
	if _bake_pass == null:
		return
	for slot in _slots:
		if slot == null:
			continue
		var own: Slot = slot
		if own.body_id != body_id or own.ready or own.pending:
			continue
		var requested := _bake_pass.request_tile(
			body_id, SpacesimSurfaceField.plan(body_id, radius), own.layer,
			own.level, own.x, own.y, SpacesimSurfaceTiles.TILE_TEXELS
		)
		if requested:
			own.pending = true
		return


## **The rects and layers to publish for a body** — the tiles that are ready, **finest first** so the shader can
## stop at the first rectangle that contains its uv.
##
## `version` is what a caller compares to know a republish is needed; the rects themselves are the answer.
func tiles_for(body_id: String) -> Dictionary:
	var ready: Array = []
	for slot in _slots:
		if slot == null:
			continue
		var own: Slot = slot
		if own.body_id != body_id or not own.ready:
			continue
		ready.append(own)
	# Finest first: the smallest rectangle wins a pixel, and a coarser neighbour never hides a finer one.
	ready.sort_custom(func(a, b): return (a.level > b.level) if a.level != b.level else (a.y < b.y))
	var rects := PackedVector4Array()
	var layers := PackedInt32Array()
	for slot in ready:
		var own: Slot = slot
		rects.append(SpacesimSurfaceTiles.rect_of(own.level, own.x, own.y))
		layers.append(own.layer)
	return {"rects": rects, "layers": layers, "version": int(_tile_version.get(body_id, 0))}


## The shared array, or null before the first tile has been baked.
func tile_array() -> Texture2DArrayRD:
	return _bake_pass.tile_array() if _bake_pass != null else null


## The first free layer, or -1 when the table is full.
func _free_layer() -> int:
	while _slots.size() < SpacesimSurfaceTiles.MAX_TILES:
		_slots.append(null)
	for index in SpacesimSurfaceTiles.MAX_TILES:
		if _slots[index] == null:
			return index
	return -1


## Bump the body's version when what a material would be told has changed.
func _bump_tiles(body_id: String) -> void:
	_tile_version[body_id] = int(_tile_version.get(body_id, 0)) + 1


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


## **The tile table** — one slot per layer of the shared array, `SpacesimSurfaceTiles.MAX_TILES` of them.
var _slots: Array = []
## Per body: the eye state the last walk was made at, so the gate can tell whether the answer moved.
var _tile_last: Dictionary = {}
## Per body: bumped when what a material would be told has changed, and what was last handed to a material.
var _tile_version: Dictionary = {}
var _published_version: Dictionary = {}

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
		if String(bake.get("kind", "map")) == "tile":
			# **A tile fills its slot in place.** The pixels are already in the shared array — the pass copied them
			# on the render thread — so there is nothing to hand over but the news that the slot is ready.
			for slot in _slots:
				if slot == null:
					continue
				var own: Slot = slot
				if own.body_id == body_id and own.level == int(bake["level"]) \
						and own.x == int(bake["x"]) and own.y == int(bake["y"]):
					own.ready = true
					own.pending = false
					_bump_tiles(body_id)
					changed.append(body_id)
					break
			continue
		var previous := entry.refined
		entry.refined = bake["texture"]
		entry.refined_width = int(bake["width"])
		entry.width = entry.refined_width
		entry.version += 1
		if previous != null:
			_bake_pass.release(previous)
		changed.append(body_id)
	return changed


## **Whether the whole-body map's request has to be reconsidered at all** — the gate, of the same shape as
## `SpacesimPatches.walk_is_due` and `SpacesimSurfaceTiles.walk_is_due`, because they answer the same kind of
## question and a project with three different conventions has three things to keep in step.
##
## The inputs are the only things `required_width` depends on: the distance (a tenth, `log`, the loose end the patch
## walk measured), the pixel angle, and the ceiling — which moves when `surface.max_base_fraction` is changed, so
## the knob stays hot. **The width in hand is deliberately not an input**: a rung landing is not the eye moving, and
## it is handled by [member Entry.version] rather than by re-deciding.
static func map_is_due(
	last_distance: float, last_pixel: float, last_cap: int,
	distance: float, pixel_angle: float, cap: int
) -> bool:
	if last_distance <= 0.0 or last_pixel <= 0.0 or last_cap <= 0:
		return true
	if not is_equal_approx(pixel_angle, last_pixel):
		return true
	if cap != last_cap:
		return true
	# **The patch walk's own constant, not a copy of it.** Three gates now decide "has this moved enough", and
	# three copies of 0.0953 is three things to keep in step.
	return absf(log(distance / last_distance)) > SpacesimPatches.LOG_TENTH


## **Reconsider this body's width, and ask for the next rung if the law wants one.** The only place a whole-body
## bake is ever requested, and it is called only when [method map_is_due] says so.
##
## **The next rung, not the final width**: the ladder climbs 256 → 512 → … one bake in flight, and each rung is on
## screen while the next is baked. That is the reverse mipmap — cheap and coarse first — and it is why a ladder
## started late still shows something immediately.
func note_map_eye(
	body_id: String, radius: float, distance: float, pixel_angle: float, cap: int
) -> void:
	var entry: Entry = _entries.get(body_id)
	if entry == null:
		return
	entry.last_distance = distance
	entry.last_pixel = pixel_angle
	entry.last_cap = cap
	if _bake_pass == null:
		return
	var wanted := required_width(radius, distance, pixel_angle, cap)
	if wanted <= entry.width:
		# **The map is already as fine as the eye can use, and the extra rungs are given back** — a recede costs
		# no memory, because the build map is still the floor.
		if entry.refined != null and wanted <= BUILD_WIDTH:
			_bake_pass.release(entry.refined)
			entry.refined = null
			entry.refined_width = 0
			entry.width = BUILD_WIDTH
			entry.version += 1
		return
	# The pass refuses a second request while one is in flight, so the next rung is asked for the frame after this
	# one lands.
	_bake_pass.request(
		body_id, SpacesimSurfaceField.plan(body_id, radius), next_bake_width(entry.width, wanted)
	)


## **What this body's material should sample** — the widest thing that has landed. A lookup; it asks for nothing.
func drawn_for(body_id: String) -> Dictionary:
	var entry: Entry = _entries.get(body_id)
	if entry == null:
		return {}
	return _drawn(entry)


## **Whether a material is holding an older map than the cache has**, and the two halves of saying so.
func needs_publish(body_id: String) -> bool:
	var entry: Entry = _entries.get(body_id)
	return entry != null and entry.version != entry.published_version


func mark_published(body_id: String) -> void:
	var entry: Entry = _entries.get(body_id)
	if entry != null:
		entry.published_version = entry.version


## **Whether the near field is worth walking at all** — and the answer is the same law: tiles exist to give what the
## whole-body map cannot, so while that map still has room to refine, a tile is work without a need.
##
## **This is the gate that stops far bodies eating the table.** The walk used to run for every drawn body, and
## "finer than the base map" is satisfied at almost any distance — so Luna at 400,000 km, a 20-pixel disc, took four
## slots for tiles worth nothing, and the body the eye was actually looking at was starved of them. Evert flew it,
## 2026-10-19: *"when I see a refinement, I also see it being reverted, but not in all cases."*
##
## `required_width` saturating at the cap **is** the signal, and no new threshold is involved. At 720p that begins
## inside **~60,000 km** — the exact form would say 48,000, and the power-of-two quantisation is why it is further
## out, since a rung is rounded up before it is clamped. There Earth's disc is ~170 px against a 640-wide map, which
## is about one texel per pixel; nothing to tune, because it is the same law at a different question.
static func near_field_is_worth_it(
	radius: float, distance: float, pixel_angle: float, cap: int
) -> bool:
	return required_width(radius, distance, pixel_angle, cap) >= cap


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
	# **Give the refining maps back before the device goes.** A refined map is a `Texture2DRD` over a RID the bake
	# pass created and we own, so nothing else will ever free it — and the engine says so at exit with
	# *"1 RID of type \"Texture\" was leaked"*, one line, once, only when it is true. It was true from the day the
	# ladder landed: the base bake is an `ImageTexture` the scene owns, but a rung is ours.
	#
	# The pass frees what it is handed on its own thread, and frees whatever is still queued when it is torn down,
	# so this only has to push them into its graveyard.
	if _bake_pass != null:
		for body_id in _entries:
			var entry: Entry = _entries[body_id]
			if entry.refined != null:
				_bake_pass.release(entry.refined)
				entry.refined = null
				entry.refined_width = 0
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
