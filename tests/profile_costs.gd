extends SceneTree
## Time the per-frame functions the 2026-10-15 engine review flagged as cleanup candidates, so they can
## be ranked by **measurement** rather than by estimate.
##
##     xvfb-run -a godot-double-mono --path . --script res://tests/profile_costs.gd
##
## `COST_CALLS` overrides the loop count for the cheap candidates.
##
## **Why time functions instead of frames.** The frame cost is not measurable in this rig — in xvfb the
## present path dominates and `TIME_PROCESS` comes to the whole frame — so any milliseconds from here
## are rig-bound. These functions are pure GDScript costs: dictionary lookups, `ConfigFile` reads,
## string building, allocation. Those are the same on any machine, so the ordering this produces holds
## everywhere even though the frame times do not.
##
## **What it measures is the CALL, not its downstream effect.** Setting a `Label`'s text is cheap here
## and expensive later when the canvas redraws; the same for `queue_redraw()`. So a small number means
## "this call is not what is costing you", never "this path is free".
##
## **No `Callable` indirection on purpose.** For functions at the microsecond scale the wrapper costs
## more than the thing being measured, so each loop is written out.
##
## **It cannot name `SpacesimSettings`.** A `--script` script is compiled *before* the autoloads are
## registered, so the identifier does not exist at compile time — the same reason `--check-only`
## reports it as "Identifier not found" and exits 0. The autoload is fetched from the tree instead.

const MAIN_SCENE := "res://game/main.tscn"
const SETTLE_FRAMES := 60
const DEFAULT_CALLS := 2000
## `_update_view` does far more work per call, so it gets its own, shorter loop.
const VIEW_CALLS := 100

var _frames := 0
var _done := false


func _initialize() -> void:
	var packed: Variant = load(MAIN_SCENE)
	if packed == null:
		print("COST: could not load the game scene")
		quit(1)
		return
	get_root().add_child(packed.instantiate())


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < SETTLE_FRAMES or _done:
		return _done
	_done = true
	_run()
	return true


func _run() -> void:
	var main: Node = get_root().get_node_or_null("Main")
	if main == null:
		print("COST: no Main node")
		return
	var camera: Camera3D = _find_camera(main)
	if camera == null:
		print("COST: no camera")
		return

	var calls := DEFAULT_CALLS
	if OS.has_environment("COST_CALLS"):
		calls = int(OS.get_environment("COST_CALLS"))

	# Fetched, not named: see the note in the header.
	var settings: Node = get_root().get_node_or_null("SpacesimSettings")
	if settings == null:
		print("COST: no SpacesimSettings autoload")
		return

	var rows: Array[Array] = [] # [label, microseconds per call, calls]

	# --- the empty loop, so the floor is visible and nothing is credited to the loop itself ---------
	var empty_start := Time.get_ticks_usec()
	for _i in calls:
		pass
	rows.append(["an empty loop (the floor)", _per_call(empty_start, calls), calls])

	# --- the candidates ----------------------------------------------------------------------------
	var gv1 := Time.get_ticks_usec()
	for _i in calls:
		settings.get_value("mouse.sensitivity")
	rows.append(["SpacesimSettings.get_value  (hot key)", _per_call(gv1, calls), calls])

	var gv2 := Time.get_ticks_usec()
	for _i in calls:
		settings.get_value("sky.star_depth")
	rows.append(["SpacesimSettings.get_value  (sky key)", _per_call(gv2, calls), calls])

	var hud := Time.get_ticks_usec()
	for _i in calls:
		main._update_hud()
	rows.append(["main._update_hud  (13-line string)", _per_call(hud, calls), calls])

	var sync := Time.get_ticks_usec()
	for _i in calls:
		main._sync_player_location()
	rows.append(["main._sync_player_location  (allocates)", _per_call(sync, calls), calls])

	var markers := Time.get_ticks_usec()
	for _i in calls:
		main._update_markers(camera)
	rows.append(["main._update_markers  (solver + alloc)", _per_call(markers, calls), calls])

	# --- the yardstick: everything the frame draws, in one call -------------------------------------
	var view := Time.get_ticks_usec()
	for _i in VIEW_CALLS:
		main._update_view(1.0 / 60.0)
	rows.append(["main._update_view  (THE WHOLE VIEW)", _per_call(view, VIEW_CALLS), VIEW_CALLS])

	# --- and the same call at a different loop count, so a cost that only appears in a tight loop can
	# --- be told from a real one: the two must agree.
	var view_few := Time.get_ticks_usec()
	for _i in 10:
		main._update_view(1.0 / 60.0)
	rows.append(["  the same, over 10 calls", _per_call(view_few, 10), 10])

	# --- decomposition: `_update_view` is one call but seven operations, and 10 ms has to live in one
	# --- of them. Timed with the same values `_update_view` itself computes.
	var eye: Transform3D = camera.get_global_transform_interpolated()
	var observer: Vector3 = main._ship.get_global_transform_interpolated().origin
	var tan_y := tan(deg_to_rad(camera.fov * 0.5))
	var view_size := Vector2(camera.get_viewport().size)
	var tan_half := Vector2(tan_y, tan_y)
	if view_size.y > 0.0:
		tan_half.x = tan_y * view_size.x / view_size.y
	var decomposition_calls := 300

	var piece := Time.get_ticks_usec()
	for _i in decomposition_calls:
		main._system.aim_sun_at(observer)
	rows.append(["  of which: aim_sun_at", _per_call(piece, decomposition_calls), decomposition_calls])

	piece = Time.get_ticks_usec()
	for _i in decomposition_calls:
		main._system.update_atmospheres(eye.origin)
	rows.append(["  of which: update_atmospheres", _per_call(piece, decomposition_calls), decomposition_calls])

	piece = Time.get_ticks_usec()
	for _i in decomposition_calls:
		main._system.update_sky(camera)
	rows.append(["  of which: update_sky", _per_call(piece, decomposition_calls), decomposition_calls])

	piece = Time.get_ticks_usec()
	for _i in decomposition_calls:
		main._system.update_lod(camera)
	rows.append(["  of which: update_lod", _per_call(piece, decomposition_calls), decomposition_calls])

	piece = Time.get_ticks_usec()
	for _i in decomposition_calls:
		main._system.view_luminance_at(observer, -eye.basis.z, tan_half)
	rows.append(["  of which: view_luminance_at", _per_call(piece, decomposition_calls), decomposition_calls])

	piece = Time.get_ticks_usec()
	for _i in decomposition_calls:
		main._exposure.update_to(1.0, 1.0 / 60.0)
	rows.append(["  of which: exposure.update_to", _per_call(piece, decomposition_calls), decomposition_calls])

	piece = Time.get_ticks_usec()
	for _i in decomposition_calls:
		main._update_camera(camera)
	rows.append(["  of which: _update_camera", _per_call(piece, decomposition_calls), decomposition_calls])

	# `update_lod` is the one that came out dear, and the interpolation work changed which transform it
	# reads. These three separate "the call I introduced is expensive" from "the transform read always
	# was". The engine's own comment on the internal function warns it is dear on *invisible* nodes.
	piece = Time.get_ticks_usec()
	for _i in calls:
		camera.get_global_transform_interpolated()
	rows.append(["camera.get_global_transform_interpolated", _per_call(piece, calls), calls])

	piece = Time.get_ticks_usec()
	for _i in calls:
		camera.global_transform
	rows.append(["camera.global_transform", _per_call(piece, calls), calls])

	piece = Time.get_ticks_usec()
	for _i in calls:
		camera.get_global_transform_interpolated().origin
	rows.append(["camera.get_global_transform_interpolated().origin", _per_call(piece, calls), calls])

	rows.sort_custom(func(a: Array, b: Array) -> bool: return float(a[1]) > float(b[1]))

	# 60 Hz is the physics tick and the budget everything here is competing for.
	var budget_us := 1000000.0 / 60.0
	print("COST: per call, mean of %d calls (%d for the whole view)" % [calls, VIEW_CALLS])
	print("COST: a 60 Hz frame is %.0f us, so a percent is ~%.0f us" % [budget_us, budget_us / 100.0])
	print("COST:   %-38s %9s %11s" % ["", "us/call", "% of frame"])
	for row in rows:
		print("COST:   %-38s %9.2f %10.3f%%" % [row[0], row[1], 100.0 * float(row[1]) / budget_us])
	print("COST: candidates occur at different rates per frame (get_value ~6x, the rest once),")
	print("COST: so compare each against the frame, not against each other.")


func _per_call(start_usec: int, calls: int) -> float:
	return float(Time.get_ticks_usec() - start_usec) / float(maxi(calls, 1))


func _find_camera(node: Node) -> Camera3D:
	if node is Camera3D:
		return node
	for child in node.get_children():
		var found := _find_camera(child)
		if found != null:
			return found
	return null
