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
## **A fragment is a body for exactly as long as the field holds it**: the field drops a fragment when it
## leaves the ball and makes up a new one, and the body is created and freed with it. Nothing is stored,
## which is the population's own rule.

## One body per live fragment, keyed by the fragment's designation — the id `hash()` seeds the shape with.
var _bodies: Dictionary = {}
var _population: SpacesimPopulation
## **The scene builds them**, through its own body path — this class only asks and then keeps the tally.
var _system: SpacesimSystemScene


func _init(population: SpacesimPopulation = null, system: SpacesimSystemScene = null) -> void:
	_population = population
	_system = system


## **Mirror the field**: a body for every fragment it holds, none for one it has dropped, and each of
## those bodies advanced exactly as [method SpacesimSystemScene.update_lod] advances an irregular one.
##
## `eye` is the observer, `camera` supplies the pixel size — the render target's height, as `update_lod`
## takes it, because the extraction threshold is a screen size.
func update(
	field: SpacesimPopulationField, parent_position: Vector3, eye: Vector3, camera: Camera3D,
	wireframe: bool
) -> void:
	if field == null or _population == null or _system == null or camera == null:
		return
	var viewport := camera.get_viewport()
	if viewport == null:
		return
	var pixel := SpacesimLod.pixel_angle(camera.fov, float(viewport.size.y))
	if pixel <= 0.0:
		return

	var live := {}
	for fragment in field.fragments():
		live[fragment.designation] = true
		var body: SpacesimSceneBody = _bodies.get(fragment.designation)
		if body == null:
			body = _system.add_body(
				content_for(_population, fragment.designation, fragment.diameter),
				field.position_of(fragment, parent_position)
			)
			_bodies[fragment.designation] = body
		if body != null:
			# **The whole lifecycle, from the scene that owns it** — extraction, the splat that stands in
			# while it runs, and the wireframe. A rock's splat is far fainter than a planet's by
			# construction: it is sized to the disc a 10 m body would have.
			_system.advance_irregular(body, eye, camera, pixel, wireframe)

	for designation in _bodies.keys():
		if live.has(designation):
			continue
		var gone: SpacesimSceneBody = _bodies[designation]
		_bodies.erase(designation)
		# **The frame goes with it**, through the scene that made both — a frame that outlived its rock
		# would be a coordinate space with nothing at the origin of it.
		_system.discard_body(gone)


## How many rocks are bodies right now — one per fragment the field holds.
func count() -> int:
	return _bodies.size()


## **A fragment as content**, so it can be a body: its radius, and what the population says it is made
## of. That composition is the whole of what the builder needs — the material's colour, its strength and
## its density all follow, so a rock's lumpiness is derived rather than chosen.
##
## **`id` is the designation**, because [method SpacesimIrregularBody.request] seeds the shape from
## `hash(body.id)`: the same rock has to be the same shape every time it is extracted, and it is.
static func content_for(
	population: SpacesimPopulation, designation: String, diameter: float
) -> SpacesimSystemBody:
	var content := SpacesimSystemBody.new()
	content.id = designation
	content.display_name = designation
	content.kind = SpacesimSystemBody.Kind.MOON
	content.radius = maxf(diameter * 0.5, 0.5)
	var layer := SpacesimLayer.new()
	layer.layer_name = "bulk"
	layer.radius = content.radius
	layer.composition = population.composition.duplicate()
	content.layers.append(layer)
	return content
