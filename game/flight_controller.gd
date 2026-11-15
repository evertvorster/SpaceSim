extends Node3D
## The flyable ship.
##
## It **applies the engine's travel unit**; the flight model an episode uses is content, and the
## engine owns only the unit. (`game/` rather than `addons/` for that reason.) Input is fed in as a
## dictionary so the same ship can be flown by a test without a keyboard — which is what lets the
## headless suite fly the identical ship the game does.
##
##   throttle : -TOP_THROTTLE..TOP_THROTTLE, in multiples of the local travel unit. **Signed**, so astern
##              flies at the same speed as ahead — comparing a cloud's two faces needs it.
##   aim      : world-space point to point the ship at (tests use this)
##   pitch/yaw/roll : radians to rotate by this step (the interactive path uses these)

const TravelScale := preload("res://addons/spacesim/travel/travel_scale.gd")
const Proximity := preload("res://addons/spacesim/travel/proximity.gd")

## **How many local travel units per second full stick is worth.** The engine owns the UNIT
## (`SpacesimTravelScale`: one neighbourhood per `TRAVERSE_SECONDS`), and this is the episode's multiple of
## it — which is why it lives here and not there. 10 is an inspection budget: fast enough to cross a cloud
## deck in one pass, slow enough to stop inside it.
const TOP_THROTTLE := 10.0

## The frame tree whose active frame supplies the travel band. Required: a ship without one has
## nowhere to fly, so its absence is a programming error rather than a state to handle.
var frame_tree: SpacesimFrameTree

## Significant bodies: what sets the local unit.
var bodies: Array[SpacesimScaleBody] = []

## The nearest body as of this step, so one scan serves the readout and the surface constraint
## both.
##
## ponytail: cached for the step rather than queried twice. Re-query if bodies ever move fast
## enough to change which one is nearest inside a single step.
var _nearest_body: SpacesimScaleBody

# Readouts, for the HUD and for tests.
var throttle := 0.0
var speed := 0.0
var travel_length := 0.0
var nearest_distance := INF
var nearest_name := ""

## True while the ship is in contact with a surface this step. Recomputed every step: this
## is contact, not a latch.
var landed := false


## The band the active frame spans.
func travel_band() -> Vector2:
	var frame := frame_tree.active_frame
	return Vector2(frame.travel_length_min, frame.travel_length_max)


## Advance one step. `delta` is seconds; the caller owns the timestep.
func step(delta: float, input: Dictionary) -> void:
	_apply_attitude(input)
	throttle = clampf(float(input.get("throttle", throttle)), -TOP_THROTTLE, TOP_THROTTLE)

	_update_proximity()
	var band := travel_band()
	travel_length = TravelScale.local_length(nearest_distance, band.x, band.y)
	# **One travel unit of speed, times the stick** — signed, so the top speed ahead and astern are the same.
	speed = TravelScale.speed_for(1.0, nearest_distance, band.x, band.y) * throttle

	# Forward is -Z, as everywhere in Godot, so a negative throttle moves along +Z.
	landed = false
	var closing := Vector3.ZERO
	if speed != 0.0:
		closing = -global_transform.basis.z * speed
	# **The ship is carried by whatever it is nearest to**, so its speed is relative to that body and
	# the world does not need to stand still for it to arrive. See `SpacesimTravelScale.carried_step`.
	var carried := Vector3.ZERO if _nearest_body == null else _nearest_body.velocity
	if closing != Vector3.ZERO or carried != Vector3.ZERO:
		global_position += TravelScale.carried_step(carried, closing, delta)

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
	# **Which body is nearest is a sphere question; how far above it is not.** The choice is a scan over every
	# significant body, so it stays the cheap comparison; the reported altitude is one call, for the body already
	# chosen, and it asks that body's own surface — a mean radius is wrong by the whole relief.
	_nearest_body = Proximity.nearest_body(global_position, bodies)
	nearest_distance = (
		INF if _nearest_body == null else _nearest_body.surface_distance_mesh(global_position)
	)
	# **A fragment has no node**, so it answers with its own designation — it is the only thing in range
	# out there, and the readout has to be able to name it.
	nearest_name = "—"
	if _nearest_body != null:
		nearest_name = _nearest_body.name if _nearest_body.node == null else _nearest_body.node.name


## Altitude above the nearest significant surface, in metres.
func altitude() -> float:
	return nearest_distance


## The surface is a constraint, not a latch.
##
## Motion into the surface is absorbed by putting the ship back on it; motion along or away
## from it is left alone, so the ship can slide and can take off. Latching here instead is
## what made landing a one-way trip.
func _constrain_to_surface() -> void:
	if _nearest_body == null:
		return
	# **A rock has no node, and is still solid.** Evert, 2026-11-14: *"while not exactly landable, they
	# should be dockable, which amounts to the same thing."* The constraint is a sphere test against the
	# nearest body's own radius, and a `SpacesimScaleBody` carries a position whether or not a node does.
	var origin: Vector3 = (
		_nearest_body.node.global_position if _nearest_body.node != null else _nearest_body.position
	)
	var offset := global_position - origin
	var distance := offset.length()
	if distance >= _nearest_body.radius:
		return

	var outward := Vector3.UP
	if distance > 0.0:
		outward = offset / distance
	global_position = origin + outward * _nearest_body.radius
	landed = true
