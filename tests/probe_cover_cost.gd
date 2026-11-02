extends SceneTree
## **What it costs to cover the topmost layer, not just the ground.**
##
## The walk's cap is now the furthest any layer drawn on the body can be seen (`SpacesimPatches.cover_angle`), because
## every layer wears the same array. That makes the ground and the sea build out past their own horizon whenever a
## deck stands above them — hidden geometry, so the question is only how much.
##
##   godot-double-mono --headless --path . --script res://tests/probe_cover_cost.gd
##
## Reports, per altitude: the two caps, and the emitted chunks and triangles for each — the ground's own selection as
## it was, and the union.
##
## **The deck's height and the basin's depth are the ones Earth's model derives** — 1.4 km up and 10.8 km down — so
## these are the cases Evert flies.

const RADIUS := 6_371_000.0
const DECK_HEIGHT := 1400.0
const BASIN_DEPTH := 10830.0
const PIXEL := 1.3e-3
const EPSILON := 1.0


func _init() -> void:
	print("%10s %12s %12s %8s %8s %9s %9s %7s" % [
		"altitude", "ground cap", "cover cap", "chunks", "chunks", "triangles", "triangles", "extra"
	])
	print("           (deck 1.4 km, basin 10.8 km below the datum)")
	for altitude in [2.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0]:
		var distance: float = RADIUS + altitude
		var direction := Vector3.UP
		var ground: float = SpacesimPatches.cover_angle(distance, RADIUS, RADIUS)
		var deck: float = SpacesimPatches.cover_angle(distance, RADIUS, RADIUS + DECK_HEIGHT)
		var basin: float = SpacesimPatches.cover_angle(distance, RADIUS, RADIUS - BASIN_DEPTH)
		var cover: float = maxf(maxf(ground, deck), basin)
		var before: Array = SpacesimPatches.select(
			distance, direction, RADIUS, PIXEL, EPSILON, ground
		)
		var after: Array = SpacesimPatches.select(
			distance, direction, RADIUS, PIXEL, EPSILON, cover
		)
		var before_triangles := SpacesimPatches.triangle_count(before)
		var after_triangles := SpacesimPatches.triangle_count(after)
		print("%9.0f m %9.1f km %9.1f km %8d %8d %9d %9d %7.2fx" % [
			altitude, ground * RADIUS / 1000.0, cover * RADIUS / 1000.0,
			before.size(), after.size(), before_triangles, after_triangles,
			float(after_triangles) / maxf(float(before_triangles), 1.0)
		])
	quit(0)
