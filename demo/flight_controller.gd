extends Node3D
## Minimal flyable ship for the scale demo.
##
## DEMO CODE, not engine. The flight model an episode uses is content, and the real one
## arrives with physics; what is engine is the travel unit this applies. Input is fed in
## as a dictionary so the same ship can be flown by a test without a keyboard.
##
##   throttle : 0..1, fraction of the local travel unit
##   aim      : world-space point to point the ship at (tests use this)
##   pitch/yaw/roll : radians to rotate by this step (the interactive path uses these)

const TravelScale := preload("res://addons/spacesim/travel/travel_scale.gd")
const Proximity := preload("res://addons/spacesim/travel/proximity.gd")

## The frame tree whose active frame supplies the travel band. Set by the world builder.
var frame_tree: Node3D

## Significant bodies: what sets the local unit.
var bodies: Array[SpacesimScaleBody] = []

## Band used if no frame is active.
var fallback_length_min := 100.0
var fallback_length_max := 1.0e11

# Readouts, for the HUD and for tests.
var throttle := 0.0
var speed := 0.0
var travel_length := 0.0
var nearest_distance := INF
var nearest_name := ""

## True while the ship is in contact with a surface this step. Recomputed every step: this
## is contact, not a latch.
var landed := false


## The band the active frame spans, or the fallback when there is no frame.
func travel_band() -> Vector2:
	var frame = frame_tree.active_frame if frame_tree != null else null
	if frame == null:
		return Vector2(fallback_length_min, fallback_length_max)
	return Vector2(frame.travel_length_min, frame.travel_length_max)


## Advance one step. `delta` is seconds; the caller owns the timestep.
func step(delta: float, input: Dictionary) -> void:
	_apply_attitude(input)
	throttle = clampf(float(input.get("throttle", throttle)), 0.0, 1.0)

	_update_proximity()
	var band := travel_band()
	travel_length = TravelScale.local_length(nearest_distance, band.x, band.y)
	speed = TravelScale.speed_for(throttle, nearest_distance, band.x, band.y)

	# Forward is -Z, as everywhere in Godot.
	landed = false
	if speed > 0.0:
		global_position -= global_transform.basis.z * speed * delta

	_constrain_to_surface()


func _apply_attitude(input: Dictionary) -> void:
	if input.has("aim"):
		var target: Vector3 = input["aim"]
		var to_target := target - global_position
		if to_target.length() < 0.001:
			return
		var up := global_transform.basis.y
		if absf(to_target.normalized().dot(up.normalized())) > 0.999:
			up = global_transform.basis.x # straight up or down: pick another reference
		global_transform = global_transform.looking_at(target, up)
		return

	# Local-axis rotation: post-multiplying keeps it in the ship's own frame.
	var pitch := float(input.get("pitch", 0.0))
	var yaw := float(input.get("yaw", 0.0))
	var roll := float(input.get("roll", 0.0))
	if pitch != 0.0:
		basis = basis * Basis(Vector3.RIGHT, pitch)
	if yaw != 0.0:
		basis = basis * Basis(Vector3.UP, -yaw)
	if roll != 0.0:
		basis = basis * Basis(Vector3.BACK, -roll)
	basis = basis.orthonormalized()


func _update_proximity() -> void:
	nearest_distance = Proximity.nearest_surface_distance(global_position, bodies)
	var body := Proximity.nearest_body(global_position, bodies)
	nearest_name = body.node.name if body != null and body.node != null else "—"


## Altitude above the nearest significant surface, in metres.
func altitude() -> float:
	return nearest_distance


## The surface is a constraint, not a latch.
##
## Motion into the surface is absorbed by putting the ship back on it; motion along or away
## from it is left alone, so the ship can slide and can take off. Latching here instead is
## what made landing a one-way trip.
##
## The query is repeated rather than reused from `_update_proximity`, because the ship has
## moved since then. TODO: cache it properly once there is more than one body.
func _constrain_to_surface() -> void:
	var body := Proximity.nearest_body(global_position, bodies)
	if body == null or body.node == null:
		return
	var offset := global_position - body.node.global_position
	var distance := offset.length()
	if distance >= body.radius:
		return

	var outward := Vector3.UP
	if distance > 0.0:
		outward = offset / distance
	global_position = body.node.global_position + outward * body.radius
	landed = true
