extends SceneTree
## **What a publish costs on the main thread, with a real rendering device.**
##
## The headless RendererServer is a dummy, so `mesh_from` measured there is the CPU copy and nothing else — which is
## why the hitch this is chasing does not show up in the suite. Run it both ways and compare:
##
##   godot-double-mono --headless --path . --script res://tests/probe_publish_cost.gd
##   xvfb-run -a godot-double-mono --path . --script res://tests/probe_publish_cost.gd
##
## Reported per mode: the mesh creation (a `RenderingServer` call, so it cannot leave the main thread), and the
## release of the arrays it was built from.

const RADIUS := 6371000.0
const PIXEL := 1.3e-3
const EPSILON := 0.5


func _init() -> void:
	for altitude in [1000.0, 10.0]:
		var chunks := SpacesimPatches.select(
			RADIUS + altitude, Vector3.UP, RADIUS, PIXEL, EPSILON
		)
		var origin := Vector3.UP * RADIUS
		var flat: Array = SpacesimPatches.arrays_of(chunks, RADIUS, origin)
		var lines: Array = SpacesimPatches.lines_of(chunks, RADIUS, origin)
		var flat_verts: int = (flat[0] as PackedVector3Array).size()
		var line_verts: int = (lines[0] as PackedVector3Array).size()

		print("%.0f m  %d tri  (%d flat verts, %d line verts)" % [
			altitude, SpacesimPatches.triangle_count(chunks), flat_verts, line_verts
		])
		print("  flat  mesh_from         %7.1f ms" % _time(func(): return SpacesimPatches.mesh_from(flat)))
		print("  WIRE  lines_mesh_from   %7.1f ms" % _time(func(): return SpacesimPatches.lines_mesh_from(lines)))
		print("  release the arrays      %7.1f ms  (flat %d B, lines %d B)" % [
			_time(func(): return _release(flat, lines)),
			(flat[0] as PackedVector3Array).size() * 12,
			(lines[0] as PackedVector3Array).size() * 12
		])
	quit(0)


## Dropping the last reference is what the publish does to the arrays it consumed, on the main thread.
func _release(flat: Array, lines: Array) -> int:
	var copied := flat.duplicate()
	var released := (copied[0] as PackedVector3Array).size()
	copied = []
	var other := lines.duplicate()
	other = []
	return released


## Minimum of three: this machine's noise is multiplicative.
func _time(action: Callable) -> float:
	var best := INF
	for _run in 3:
		var started := Time.get_ticks_usec()
		action.call()
		best = minf(best, Time.get_ticks_usec() - started)
	return best / 1000.0
