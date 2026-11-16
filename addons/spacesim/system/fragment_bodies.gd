class_name SpacesimFragmentBodies
extends Node3D
## **The rocks you can see, as bodies** — one [SpacesimSceneBody] per fragment of a population, built by
## [SpacesimIrregularBody]: the same builder, the same generator, the same taper and the same wireframe
## the moons of Mars get.
##
## **This replaces a parallel renderer, and the reason is worth keeping.** The first version called
## `SpacesimBlobShape.arrays` directly at a fixed resolution and kept one `MeshInstance3D`. It was a
## second, thinner implementation of a problem already solved: no `show_wireframe` (so the wireframe
## toggle did nothing to a rock), no `_teleport` on the node, no `RESOLVE_PIXELS` rule, no point-of-light
## handover, and only ever one rock drawn. Evert, 2026-11-14: *"I was under the impression that asteroids
## would be created in the same way that other irregular bodies would be created, like the moons of
## mars."* — and `SpacesimIrregularBody`'s own class comment had already named this reuse as the plan for
## asteroids.
##
## **A rock is a body for exactly as long as its source offers it**: the belt's field drops a fragment when it
## leaves the ball, a ring stops offering a spot when the eye leaves it, and the body is created and freed with
## it. Nothing is stored, which is the population's own rule.
##
## **The source is anything that lists pieces** — `{id, position, diameter}` — so a belt and a ring share this
## one lifecycle rather than growing one each. Evert, 2026-11-15: *"Most of what we are doing is re-using stuff
## in the engine we made for other parts, the amount of novel things should be small."*

## One body per live rock, keyed by its id — which is also what `hash()` seeds the shape with, so a rock is the
## same rock every time it is resolved.
var _bodies: Dictionary = {}
## Bumped whenever a body is created or let go, so a caller that keeps a list of rocks can tell whether it is
## stale without diffing the dictionary.
var _version := 0
var _population: SpacesimPopulation
## **The scene builds them**, through its own body path — this class only asks and then keeps the tally.
var _system: SpacesimSystemScene


func _init(population: SpacesimPopulation = null, system: SpacesimSystemScene = null) -> void:
	_population = population
	_system = system


## **Mirror the source**: a body for every piece it offers, none for one it has dropped, and each of those
## bodies advanced exactly as [method SpacesimSystemScene.update_lod] advances an irregular one.
##
## `pixel` is the pixel's angular size, which the caller already has; the extraction threshold is a screen
## size, so it is the one number that decides when a rock earns a mesh.
func update(
	pieces: Array[Dictionary], eye: Vector3, camera: Camera3D, pixel: float, wireframe: bool
) -> void:
	if _population == null or _system == null or camera == null or pixel <= 0.0:
		return

	var live := {}
	for piece in pieces:
		var designation := String(piece["id"])
		live[designation] = true
		var body: SpacesimSceneBody = _bodies.get(designation)
		if body == null:
			body = _system.add_body(
				content_for(
					_population, designation, float(piece["diameter"]), String(piece.get("label", ""))
				),
				piece["position"]
			)
			_bodies[designation] = body
			# **A rock, not a place**: ranked as an asteroid on the HUD, and it never stops the ship — there is no
			# physics yet, and a rock that stopped the ship would be a collision by accident.
			body.rock = true
			if body.scale_body != null:
				body.scale_body.solid = false
			_version += 1
		if body != null:
			# **The whole lifecycle, from the scene that owns it** — extraction, the splat that stands in while
			# it runs, and the wireframe. A rock's splat is far fainter than a planet's by construction: it is
			# sized to the disc the body would have.
			_system.advance_irregular(body, eye, camera, pixel, wireframe)

	for designation in _bodies.keys():
		if live.has(designation):
			continue
		var gone: SpacesimSceneBody = _bodies[designation]
		_bodies.erase(designation)
		_version += 1
		# **The frame goes with it**, through the scene that made both — a frame that outlived its rock would be
		# a coordinate space with nothing at the origin of it.
		_system.discard_body(gone)


## How many rocks are bodies right now — one per piece the source offers.
func count() -> int:
	return _bodies.size()


## Bumped when a rock appears or is let go.
func version() -> int:
	return _version


## **The rocks themselves**, for the marker path and the ship's travel unit. One list, read by both: a rock is
## one object, not a marker entry and a scale body and a node that might disagree.
func rocks() -> Array[SpacesimSceneBody]:
	var list: Array[SpacesimSceneBody] = []
	for designation in _bodies:
		var body: SpacesimSceneBody = _bodies[designation]
		if body != null:
			list.append(body)
	return list


## The ids the bodies are keyed by, so a renderer can stop drawing the splat each one replaced.
func ids() -> Array[String]:
	var list: Array[String] = []
	for designation in _bodies:
		list.append(String(designation))
	return list


## **A fragment as content**, so it can be a body: its radius, and what the population says it is made
## of. That composition is the whole of what the builder needs — the material's colour, its strength and
## its density all follow, so a rock's lumpiness is derived rather than chosen.
##
## **`id` is the designation**, because [method SpacesimIrregularBody.request] seeds the shape from
## `hash(body.id)`: the same rock has to be the same shape every time it is extracted, and it is.
##
## `label` is what a person reads — *"Saturn Rock  250 m"* — while `designation` stays the key the body is stored
## under and the string its shape is seeded from, so a rock keeps its shape while nothing about its name has to
## stay fixed. Evert, 2026-11-15: *"the labels suck. I think we can call it Saturn Ring Rock <diameter>
## <distance> much like we do with asteroids."*
static func content_for(
	population: SpacesimPopulation, designation: String, diameter: float, label := ""
) -> SpacesimSystemBody:
	var content := SpacesimSystemBody.new()
	content.id = designation
	content.display_name = label if not label.is_empty() else designation
	content.kind = SpacesimSystemBody.Kind.MOON
	content.radius = maxf(diameter * 0.5, 0.5)
	var layer := SpacesimLayer.new()
	layer.layer_name = "bulk"
	layer.radius = content.radius
	layer.composition = population.composition.duplicate()
	content.layers.append(layer)
	return content
