extends SceneTree
const R := 6371000.0
const P := 1.3e-3
func _init() -> void:
	for altitude in [10000.0, 1000.0, 10.0]:
		var best := INF
		var chunks: Array = []
		for _run in 5:
			var started := Time.get_ticks_usec()
			chunks = SpacesimPatches.select(R + altitude, Vector3.UP, R, P, 0.5)
			best = minf(best, Time.get_ticks_usec() - started)
		print("%8.0f m  select() %6.1f ms  %6d chunks  %8d tri" % [
			altitude, best / 1000.0, chunks.size(), SpacesimPatches.triangle_count(chunks)
		])
	quit(0)
