class_name SpacesimSurfaceBakePass
extends CompositorEffect
## **The surface map, refined on the render thread** — the map grows as the eye approaches, and no frame ever
## touches a `RenderingDevice` from the wrong thread.
##
## ## Why this exists
##
## The surface map is a *texture*, so it must get finer as the eye closes, or a planet is drawn at the same
## texel size from orbit and from a hundred kilometres up. Refining it from `_process` was tried and abandoned
## **for the wrong reason** — the RID exhaustion that ended that flight was the exposure pass leaking three
## uniform sets a frame, not this bake, which ran five times in the whole session. But the instinct was right
## even though the diagnosis was not: a local `RenderingDevice`'s calls belong on the render thread, and a
## `CompositorEffect`'s `_render_callback` **is** the render thread. That is also the shape the air march needs
## (roadmap R3), so this pass is the first user of the machinery rather than a detour.
##
## ## How a bake happens, in order
##
## 1. The main thread **requests** a width for a body (`request()`), at most one body in flight.
## 2. On the render thread, in the frame's own submission: a fresh `R16F` texture, one dispatch of the field
##    kernel, and the texture's RID is left in `_ready` for the main thread. **No `submit()` is called** —
##    this rides the frame's submission exactly as `SpacesimExposurePass` does, which is what makes it legal
##    from a callback.
## 3. The main thread wraps the RID in a `Texture2DRD` and hands it to the material. It becomes visible the
##    next frame, because the surface is drawn *before* a `POST_TRANSPARENT` effect runs — so the texture is
##    never sampled in the frame that wrote it.
## 4. Superseded textures are pushed to `release()`, and freed **here**, on the render thread, two frames
##    later — long after the material stopped pointing at them.
##
## ## Why only one in flight, and why the width is quantised
##
## A bake costs a texture allocation and a dispatch on the frame's critical path. One in flight and a power of
## two between steps means a fast approach asks for a handful of bakes, not one a frame. The *width law* is
## `SpacesimSurfaceMaps.required_width` — a texel stops resolving when it projects past a pixel — so the map is
## always at least as fine as the screen, which is also why these textures need **no mip chain**: they are only
## ever magnified. The build-time map (which is read back, measured, and never refined) is the one that carries
## mips, for the far end where it is minified.

## The request being baked, or an empty Dictionary. `body_id`, `width`, `height`, `plan`.
var _pending: Dictionary = {}
## Bakes finished on the render thread and not yet collected: `body_id` -> `{rid, width}`.
var _ready: Dictionary = {}
## Textures the main thread has finished with, with the frame count they arrived on.
var _graveyard: Array = []
## **Two frames of grace before a released texture is freed.** The frame that drew with it must be submitted
## before the RID goes; `RenderingDevice::free_rid` defers to the frame index itself, and the extra frame costs
## nothing and removes the question.
const GRAVEYARD_FRAMES := 2

var _built := false
## The array the tiles live in, created on the render thread by the first tile bake.
var _tiles: RID
var _tiles_texture: Texture2DArrayRD
var _status := "not built"
var _bakes := 0
var _frames := 0
var _shader: RID
var _pipeline: RID


func _init() -> void:
	# `POST_TRANSPARENT` because it must run **after** the frame's geometry: the surface is drawn with the
	# texture this pass is about to replace, which is what makes the swap hazard-free.
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT


## **Free what this pass created, or the engine names it a leak at exit.** The shader and the pipeline are ours
## — created on the engine's device, but not created *by* the engine, so its teardown only reports them
## (*"1 RID of type Compute was leaked"*). This is the same shape `SpacesimExposurePass` uses, and the guard
## matters: if the device is already gone, a `free_rid` on it reports *"Attempted to free invalid ID"*, which is
## noise that reads as a fault.
func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or not _built:
		return
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return
	if _pipeline.is_valid():
		rd.free_rid(_pipeline)
	if _shader.is_valid():
		rd.free_rid(_shader)
	if _tiles.is_valid():
		rd.free_rid(_tiles)
	_pipeline = RID()
	_shader = RID()
	for entry in _graveyard:
		if (entry["rid"] as RID).is_valid():
			rd.free_rid(entry["rid"])
	_graveyard.clear()
	for body_id in _ready:
		var ready: Dictionary = _ready[body_id]
		# **Not every entry owns an RID.** A whole-map bake keeps its texture for the material; a tile bake
		# is copied into the layer array and frees its own texture straight away, so it stores no `rid`. An
		# unguarded read threw on this teardown the first time a tile bake had landed — an error only on the
		# quit path, which is why the suite never saw it.
		if ready.has("rid") and (ready["rid"] as RID).is_valid():
			rd.free_rid(ready["rid"])
	_ready.clear()
	_status = "deleted"


## **Ask for a wider map.** One request at a time; a request for a body that is already in flight is dropped,
## because by the time it lands the eye will have moved anyway and the next frame will ask again.
##
## **`uv_origin`/`uv_size` bake a sub-rectangle**, and they are kept deliberately even though the whole-body ladder
## is the only caller today: the next rung of the map's resolution is *tiles over the cap the eye can see*, which
## is exactly a sub-rectangle bake, and the dispatch already carries it. They are not dead arguments — they are the
## pass's one remaining unused capability, and the window that used them was deleted because its *gate* was wrong
## rather than because a sub-rectangle bake is.
func request(
	body_id: String, plan: SpacesimSurfaceField.Plan, width: int,
	uv_origin: Vector2 = Vector2.ZERO, uv_size: Vector2 = Vector2.ONE
) -> bool:
	if not _pending.is_empty() or _ready.has(body_id):
		return false
	var w := maxi(width, 8)
	_pending = {
		"body_id": body_id,
		"kind": "map",
		"width": w,
		"height": maxi(int(float(w) * uv_size.y / maxf(uv_size.x, 1.0e-6)), 4),
		"plan": plan,
		"uv_origin": uv_origin,
		"uv_size": uv_size,
	}
	return true


## **Ask for one TILE of a body's map**, to be baked into `layer` of the shared array.
##
## The same dispatch as a whole-body rung — the kernel already takes a uv rectangle — and then a copy into the
## array's layer, because a shader can only index a tile it can name by layer. The scratch texture is freed at
## once: the array owns the pixels from the copy on, and the array lives as long as the pass.
##
## One request at a time, as every other bake here: the caller asks again next frame for the next tile.
func request_tile(
	body_id: String, plan: SpacesimSurfaceField.Plan, layer: int,
	level: int, x: int, y: int, texels: int
) -> bool:
	if not _pending.is_empty() or _ready.has(body_id):
		return false
	if layer < 0 or layer >= SpacesimSurfaceTiles.MAX_TILES:
		return false
	var side := maxi(texels, 8)
	var rect := SpacesimSurfaceTiles.rect_of(level, x, y)
	_pending = {
		"body_id": body_id,
		"kind": "tile",
		"width": side,
		"height": side,
		"plan": plan,
		"uv_origin": Vector2(rect.x, rect.y),
		"uv_size": Vector2(rect.z, rect.w) - Vector2(rect.x, rect.y),
		"layer": layer,
		"level": level,
		"x": x,
		"y": y,
	}
	return true


## **The tiles, as one array texture** — null until the first tile has been baked, because the array is created
## on the render thread and there is nothing to hand over before that.
##
## `MAX_TILES` layers of `TILE_TEXELS` square at `R16F`: 16 MiB of near field for the whole scene, allocated once
## and reused, because a tile nobody wants is simply overwritten by the next one somebody does.
func tile_array() -> Texture2DArrayRD:
	return _tiles_texture


## **The tile fields, held past `_pending` being cleared**: the copy into the array happens after the dispatch.
var _pending_kind := "map"
var _pending_layer := 0
var _pending_level := 0
var _pending_x := 0
var _pending_y := 0


## **Create the tile array, once, on the render thread.** Sampling and copy-to only: the dispatch targets a
## scratch texture and the array is a destination, so it needs no storage bit — and no mips, because a tile is
## only ever magnified.
func _ensure_tiles(rd: RenderingDevice) -> bool:
	if _tiles.is_valid():
		return true
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	format.width = SpacesimSurfaceTiles.TILE_TEXELS
	format.height = SpacesimSurfaceTiles.TILE_TEXELS
	format.depth = 1
	format.array_layers = SpacesimSurfaceTiles.MAX_TILES
	format.mipmaps = 1
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	_tiles = rd.texture_create(format, RDTextureView.new())
	if not _tiles.is_valid():
		_status = "the tile array could not be created"
		return false
	_tiles_texture = Texture2DArrayRD.new()
	_tiles_texture.texture_rd_rid = _tiles
	return true


## **Collect what the render thread finished.** Main thread. Returns `body_id` -> `{texture, width}`, with each
## bake wrapped in a `Texture2DRD` — the resource a `ShaderMaterial` needs for a texture that lives on the
## rendering device.
func take_ready() -> Dictionary:
	var taken := _ready
	_ready = {}
	var result := {}
	for body_id in taken:
		var bake: Dictionary = taken[body_id]
		# **A tile has no RID of its own** — its pixels are already in the array, copied there on the render
		# thread — so it is passed through as it stands. Wrapping it like a whole-body bake asked a Dictionary for
		# a `rid` it never had, and the error read as a broken cache rather than as a type confusion.
		if String(bake.get("kind", "map")) == "tile":
			result[body_id] = bake
			continue
		var texture := Texture2DRD.new()
		texture.texture_rd_rid = bake["rid"]
		result[body_id] = {
			"texture": texture,
			"width": int(bake["width"]),
			"uv_origin": bake["uv_origin"],
			"uv_size": bake["uv_size"],
		}
	return result


## **Give a texture back.** Main thread; the free happens on the render thread, after
## [constant GRAVEYARD_FRAMES].
func release(texture: Texture2DRD) -> void:
	if texture == null:
		return
	var rid := texture.texture_rd_rid
	if rid.is_valid():
		_graveyard.append({"rid": rid, "frame": _frames})


func bakes() -> int:
	return _bakes


func _render_callback(_callback_type: int, _render_data: RenderData) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_status = "no RenderingDevice"
		return
	if not _built:
		_build(rd)
	if not _built:
		return
	_frames += 1

	# 1. Free what the material finished with — on this thread, two frames after the request.
	var keep: Array = []
	for entry in _graveyard:
		if _frames - int(entry["frame"]) < GRAVEYARD_FRAMES:
			# Still inside the grace window: the frame that drew with it may not be submitted yet.
			keep.append(entry)
		elif (entry["rid"] as RID).is_valid():
			rd.free_rid(entry["rid"])
	_graveyard = keep

	# 2. One bake, if one was asked for.
	if _pending.is_empty():
		_status = "ready"
		return
	var body_id := String(_pending["body_id"])
	var width := int(_pending["width"])
	var height := int(_pending["height"])
	var plan: SpacesimSurfaceField.Plan = _pending["plan"]
	var uv_origin: Vector2 = _pending["uv_origin"]
	var uv_size: Vector2 = _pending["uv_size"]
	_pending_kind = String(_pending.get("kind", "map"))
	_pending_layer = int(_pending.get("layer", 0))
	_pending_level = int(_pending.get("level", 0))
	_pending_x = int(_pending.get("x", 0))
	_pending_y = int(_pending.get("y", 0))
	_pending = {}

	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	format.width = width
	format.height = height
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	# **Sampled and storage**: the dispatch writes it, the surface shader reads it. No mipmaps — these are only
	# ever magnified, and the build-time map carries the filtered pyramid for the far end.
	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	var texture := rd.texture_create(format, RDTextureView.new())
	if not texture.is_valid():
		_status = "texture_create() gave an invalid RID"
		return

	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(texture)
	var uniform_set := rd.uniform_set_create([uniform], _shader, 0)
	if not uniform_set.is_valid():
		_status = "uniform_set_create() gave an invalid RID"
		rd.free_rid(texture)
		return

	var params := SpacesimSurfaceField.push_constants(plan, width, height, uv_origin, uv_size)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, params, params.size())
	rd.compute_list_dispatch(list, ceili(width / 8.0), ceili(height / 8.0), 1)
	rd.compute_list_end()

	# **The set is freed at once; the texture is not.** A uniform set is only needed while the list is being
	# built, and `free_rid` defers it to the frame index. The texture belongs to the main thread from here on —
	# it comes back through `release()` when the material stops using it.
	rd.free_rid(uniform_set)

	_bakes += 1
	if _pending_kind == "tile":
		# **The tile lands in the array, and the scratch is let go.** A shader indexes a tile by layer, so the array
		# is what a material samples; the standalone texture was only the dispatch's target.
		var layer := _pending_layer
		if not _ensure_tiles(rd):
			rd.free_rid(texture)
			return
		rd.texture_copy(
			texture, _tiles, Vector3.ZERO, Vector3.ZERO,
			Vector3(width, height, 1), 0, 0, 0, layer
		)
		rd.free_rid(texture)
		_ready[body_id] = {
			"kind": "tile", "width": width, "layer": layer,
			"level": _pending_level, "x": _pending_x, "y": _pending_y,
			"uv_origin": uv_origin, "uv_size": uv_size,
		}
		_status = "tile %d,%d at level %d into layer %d" % [
			_pending_x, _pending_y, _pending_level, layer
		]
		return
	_ready[body_id] = {
		"kind": "map", "rid": texture, "width": width, "uv_origin": uv_origin, "uv_size": uv_size
	}
	_status = "baked %dx%d over %s" % [width, height, str(uv_size)]


func _build(rd: RenderingDevice) -> void:
	_built = true
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = SpacesimSurfaceField.source()
	var spirv := rd.shader_compile_spirv_from_source(source)
	var message := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not message.is_empty():
		_status = "the kernel did not compile: " + message
		print("SURFACE BAKE: ", _status)
		return
	_shader = rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		_status = "shader_create_from_spirv() gave an invalid RID"
		return
	_pipeline = rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_status = "compute_pipeline_create() gave an invalid RID"
		return
	# Said once, because a pass that silently never runs reads exactly like a map that never refines.
	print("SURFACE BAKE: kernel compiled, refining on the render thread")
