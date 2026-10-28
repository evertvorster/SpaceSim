extends SceneTree
## Where a rebuild's time goes, for both render modes, at the altitudes that produce the biggest selections.
##
## Headless and `--script`: `select` is arithmetic, `arrays_of`/`lines_of` are CPU, and `mesh_from` does reach the
## RenderingServer but a headless one still converts and stores the surface — which is the cost the main thread pays.
##
## **Minimum of three runs each**, because this machine's timings vary by an order of magnitude under load and a
## single run of the first version reported a "negative" rebase cost.
##
##   godot-double-mono --headless --path . --script res://tests/probe_build_cost.gd

const RADIUS := 6371000.0
const PIXEL := 1.3e-3   ## 1080p at 70 degrees
const EPSILON := 0.5
const RUNS := 3


func _init() -> void:
	for altitude in [1000.0, 10.0]:
		var chunks := SpacesimPatches.select(
			RADIUS + altitude, Vector3.UP, RADIUS, PIXEL, EPSILON
		)
		var origin := Vector3.UP * RADIUS
		var triangles := SpacesimPatches.triangle_count(chunks)
		# Warm the chunk cache: a cold build is a different (and much bigger) number, reported separately.
		SpacesimPatches.arrays_of(chunks, RADIUS, origin)

		var flat: Array = SpacesimPatches.arrays_of(chunks, RADIUS, origin)
		var lines: Array = SpacesimPatches.lines_of(chunks, RADIUS, origin)
		var flat_vertices: int = (flat[0] as PackedVector3Array).size()
		var line_vertices: int = (lines[0] as PackedVector3Array).size()
		var flat_us := _time(func(): return SpacesimPatches.arrays_of(chunks, RADIUS, origin))
		var lines_us := _time(func(): return SpacesimPatches.lines_of(chunks, RADIUS, origin))
		var flat_mesh := _time(func(): return SpacesimPatches.mesh_from(flat))
		var line_mesh := _time(func(): return SpacesimPatches.lines_mesh_from(lines))

		print("%.0f m  %d chunks  %d tri" % [altitude, chunks.size(), triangles])
		print("  flat   arrays_of         %7.1f ms  %8d verts" % [flat_us, flat_vertices])
		print("  flat   mesh_from         %7.1f ms" % flat_mesh)
		print("  WIRE   lines_of          %7.1f ms  %8d verts  (%.1fx flat)" % [
			lines_us, line_vertices, float(line_vertices) / maxf(1.0, float(flat_vertices))
		])
		print("  WIRE   lines_mesh_from   %7.1f ms" % line_mesh)
		print("  -> the wireframe view costs %.1f ms more a rebuild, %.1f ms more on the main thread" % [
			lines_us - flat_us, line_mesh - flat_mesh
		])
	quit(0)


## The fastest of `RUNS` calls, in milliseconds — the machine's noise is multiplicative, so the minimum is the
## closest thing to the code's own cost.
func _time(action: Callable) -> float:
	var best := INF
	for _run in RUNS:
		var started := Time.get_ticks_usec()
		action.call()
		best = minf(best, Time.get_ticks_usec() - started)
	return best / 1000.0
