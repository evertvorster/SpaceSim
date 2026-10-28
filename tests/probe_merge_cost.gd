extends SceneTree
## A merge that changes a few chunks, against a merge that is a fresh rebuild.
const R := 6371000.0
const P := 1.3e-3
func _init() -> void:
	var eye := Vector3.UP * (R + 10.0)
	var chunks := SpacesimPatches.select(R + 10.0, Vector3.UP, R, P, 0.5)
	var lattice := SpacesimPatches.Lattice.new()
	# cold: first merge through the lattice
	var started := Time.get_ticks_usec()
	SpacesimPatches.arrays_of(chunks, R, eye.normalized() * R, false, lattice)
	print("cold  lattice merge %7.1f ms  (%d points)" % [
		(Time.get_ticks_usec() - started) / 1000.0, lattice.points.size()])
	# warm: same selection again
	var best := INF
	for _run in 3:
		started = Time.get_ticks_usec()
		SpacesimPatches.arrays_of(chunks, R, eye.normalized() * R, false, lattice)
		best = minf(best, Time.get_ticks_usec() - started)
	print("same selection     %7.1f ms" % (best / 1000.0))
	# a tangential step: the eye moves 200 m along the surface, so a few chunks pass
	var moved := (Vector3.UP * (R + 10.0) + Vector3.RIGHT * 200.0).normalized() * (R + 10.0)
	var next := SpacesimPatches.select(R + 10.0, moved.normalized(), R, P, 0.5)
	var changed := next.size() - chunks.size()
	best = INF
	for _run in 3:
		started = Time.get_ticks_usec()
		SpacesimPatches.arrays_of(next, R, moved.normalized() * R, false, lattice)
		best = minf(best, Time.get_ticks_usec() - started)
	print("200 m tangential   %7.1f ms  (%d chunks vs %d, %+d)" % [
		best / 1000.0, next.size(), chunks.size(), changed])
	SpacesimPatches.clear_cache()
	best = INF
	for _run in 3:
		started = Time.get_ticks_usec()
		SpacesimPatches.arrays_of(next, R, moved.normalized() * R)
		best = minf(best, Time.get_ticks_usec() - started)
	print("fresh rebuild      %7.1f ms  (no lattice, what it was)" % (best / 1000.0))
	quit(0)
