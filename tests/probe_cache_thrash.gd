extends SceneTree
## **Does the chunk cache survive a flight?** It is cleared *wholesale* when it passes `CHUNK_CACHE_LIMIT`, and a
## selection at 10 m altitude is now ~11,000 chunks — so a slow walk across the ground replaces the whole selection
## every time and the cap is crossed repeatedly. A cleared cache means the next build is a cold rebuild of every
## chunk's geometry, which is the difference between 50 ms and 350 ms and only happens **while moving**.
##
##   godot-double-mono --headless --path . --script res://tests/probe_cache_thrash.gd

const RADIUS := 6371000.0
const PIXEL := 1.3e-3
const EPSILON := 0.5
const STEP_METRES := 200.0
const STEPS := 24


func _init() -> void:
	SpacesimPatches.clear_cache()
	var eye := Vector3.UP * (RADIUS + 10.0)
	var clears := 0
	var previous := 0
	print("step  chunks  cached  build ms  chunks rebuilt")
	for step in STEPS:
		# Walk 200 m along the ground each step: the same thing a slow flight does to the selection.
		eye = (Vector3.UP * (RADIUS + 10.0) + Vector3.RIGHT * STEP_METRES * step).normalized() * (RADIUS + 10.0)
		var chunks := SpacesimPatches.select(eye, eye.normalized(), RADIUS, PIXEL, EPSILON)
		var before := SpacesimPatches.cached_chunks()
		var started := Time.get_ticks_usec()
		SpacesimPatches.arrays_of(chunks, RADIUS, eye.normalized() * RADIUS)
		var elapsed := Time.get_ticks_usec() - started
		var after := SpacesimPatches.cached_chunks()
		if after < before:
			clears += 1
		print("%4d  %6d  %6d  %7.1f  %+6d%s" % [
			step, chunks.size(), after, elapsed / 1000.0, after - before,
			"   <- CLEARED" if after < before else ""
		])
		previous = after
	print("cleared %d times in %d steps of %.0f m (limit %d)" % [
		clears, STEPS, STEP_METRES, SpacesimPatches.CHUNK_CACHE_LIMIT
	])
	quit(0)
