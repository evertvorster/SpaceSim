class_name SpacesimSolarSystem
extends Resource
## A solar system as **content**: a star and its bodies, their orbits and what they are made of.
##
## This is the authored shape the derivation reads and the generator will emit. It holds no nodes
## and no derived values — [code]SpacesimSystemScene[/code] builds the scene, and the derivation
## produces the physics. See the vault: Solar System Content Format.

@export var content_version: int = 1
## ISO 8601. Every [member SpacesimOrbit.mean_anomaly_at_epoch] is measured from here. Sol is J2000.
@export var epoch: String = "2000-01-01T12:00:00"
@export var framing: SpacesimFraming
@export var start_body_id: String = ""
@export var start_altitude: float = 1.0e7 ## metres above that body's surface
## The side of the start body to begin on. **Zero means the side facing the star** — the day side,
## which is what a fresh story should have. Content overrides it for a world laid out so that the
## interesting places are elsewhere: the playground's bodies run along +X from a star at the origin,
## so its day side faces away from all the others.
@export var start_direction: Vector3 = Vector3.ZERO
@export var start_world_time: float = 0.0 ## seconds from the world epoch
@export var bodies: Array[SpacesimSystemBody] = []

## How far a fraction may be from 1 before it is a mistake rather than rounding.
const FRACTION_TOLERANCE := 1.0e-3


## The star the system is named after.
func star() -> SpacesimSystemBody:
	for body in bodies:
		if body.primary:
			return body
	return null


## **A system is named after its star**, so the name is read rather than stored and the two cannot
## drift apart.
func system_name() -> String:
	var primary := star()
	return primary.display_name if primary != null else "unnamed"


func body_by_id(id: String) -> SpacesimSystemBody:
	for body in bodies:
		if body.id == id:
			return body
	return null


## Problems with this content, as prose. Empty means sound.
##
## A content file is a trust boundary, so nothing here is corrected silently — a quietly repaired
## world is a wrong world nobody notices.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()

	if bodies.is_empty():
		problems.append("no bodies")

	var primaries := 0
	for body in bodies:
		if body.primary:
			primaries += 1
			if body.kind != SpacesimSystemBody.Kind.STAR:
				problems.append("%s is primary but is a %s" % [body.id, body.kind_name()])
	if primaries != 1:
		problems.append("expected exactly one primary star, found %d" % primaries)

	var primary := star()

	for body in bodies:
		if body.id.is_empty():
			problems.append("a body has no id")
		if body.radius <= 0.0:
			problems.append("%s has no radius" % body.id)
		if body.rotation_period < 0.0:
			problems.append("%s has a negative rotation period (retrograde is axial_tilt > 90)" % body.id)
		if body.axial_tilt < 0.0 or body.axial_tilt > 180.0:
			problems.append("%s has an axial tilt outside [0, 180]" % body.id)

		# Every body but the primary must orbit something: a body left without an orbit would
		# silently stand at the system origin. The primary has no parent, so it is never checked
		# against one.
		# A body with no orbit does not move: it stands at its fixed position, and that is a perfectly
		# good arrangement (a station, or a hand-placed placeholder) rather than an error. The
		# primary is the exception — it is the centre of the system and must not orbit anything.
		if body.primary:
			if body.orbits():
				problems.append("%s is the primary star and should not orbit" % body.id)
		else:
			var parent_id := body.parent_id
			if parent_id.is_empty():
				parent_id = primary.id if primary != null else ""
			if parent_id == body.id:
				problems.append("%s is its own parent" % body.id)
			elif body_by_id(parent_id) == null:
				problems.append("%s orbits '%s', which is not a body here" % [body.id, parent_id])
			elif body.kind == SpacesimSystemBody.Kind.MOON:
				var parent := body_by_id(parent_id)
				if parent != null and parent.kind == SpacesimSystemBody.Kind.STAR:
					problems.append("%s is a moon of a star" % body.id)

		problems.append_array(_check_layers(body))
		problems.append_array(_check_fractions(body))

	problems.append_array(_check_cycles())
	return problems


func _check_layers(body: SpacesimSystemBody) -> PackedStringArray:
	var problems := PackedStringArray()
	if body.layers.is_empty():
		return problems
	var previous := 0.0
	for layer in body.layers:
		if layer.radius <= previous:
			problems.append("%s: layer '%s' does not sit outside the one below it (%s <= %s)"
				% [body.id, layer.layer_name, String.num(layer.radius), String.num(previous)])
		previous = layer.radius
	var outermost := body.layers[body.layers.size() - 1].radius
	if absf(outermost - body.radius) > 1.0:
		problems.append("%s: its outermost layer ends at %s but its radius is %s"
			% [body.id, String.num(outermost), String.num(body.radius)])
	return problems


func _check_fractions(body: SpacesimSystemBody) -> PackedStringArray:
	var problems := PackedStringArray()
	for layer in body.layers:
		problems.append_array(
			_sum_check(body.id, "layer '%s'" % layer.layer_name, layer.composition, PackedStringArray())
		)
	if body.surface != null:
		problems.append_array(_sum_check(body.id, "surface", body.surface.coverage, PackedStringArray()))
	if body.atmosphere != null:
		problems.append_array(
			_sum_check(body.id, "atmosphere", body.atmosphere.species, body.atmosphere.variable_species)
		)
	return problems


## `excluded` names are reference values rather than fixed ones: a condensable's fraction is not
## part of the sum, which is what lets a water world's greenhouse depend on its own temperature
## without a feedback loop in the data.
func _sum_check(
	body_id: String, what: String, fractions: Dictionary, excluded: PackedStringArray
) -> PackedStringArray:
	var problems := PackedStringArray()
	var total := 0.0
	var counted := 0
	for key in fractions:
		if excluded.has(String(key)):
			continue
		total += float(fractions[key])
		counted += 1
	if counted == 0:
		return problems
	if absf(total - 1.0) > FRACTION_TOLERANCE:
		problems.append("%s/%s fractions sum to %.4f, not 1" % [body_id, what, total])
	return problems


## A parent chain that never reaches the primary star is a cycle, and nothing would ever place
## those bodies.
func _check_cycles() -> PackedStringArray:
	var problems := PackedStringArray()
	for body in bodies:
		var seen := {body.id: true}
		var current := body
		while current != null and not current.primary:
			var parent_id := current.parent_id
			if parent_id.is_empty():
				break
			if seen.has(parent_id):
				if current != body:
					problems.append("%s is in a parent cycle" % body.id)
				break
			seen[parent_id] = true
			current = body_by_id(parent_id)
	return problems
