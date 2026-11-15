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
var _materials: SpacesimMaterialTable


func _init(population: SpacesimPopulation = null) -> void:
	_population = population
	_materials = SpacesimMaterialTable.engine_table()


## **Mirror the field**: a body for every fragment it holds, none for one it has dropped, and each of
## those bodies advanced exactly as [method SpacesimSystemScene.update_lod] advances an irregular one.
##
## `eye` is the observer, `camera` supplies the pixel size — the render target's height, as `update_lod`
## takes it, because the extraction threshold is a screen size.
func update(
	field: SpacesimPopulationField, parent_position: Vector3, eye: Vector3, camera: Camera3D,
	wireframe: bool
) -> void:
	if field == null or _population == null or camera == null:
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
			body = _make(fragment, field.position_of(fragment, parent_position))
			_bodies[fragment.designation] = body
		_advance(body, eye, pixel, wireframe)

	for designation in _bodies.keys():
		if live.has(designation):
			continue
		var gone: SpacesimSceneBody = _bodies[designation]
		_bodies.erase(designation)
		if gone.node != null:
			gone.node.queue_free()


## **The four calls an irregular body gets, in `update_lod`'s own order.** Extracted when the eye is close
## enough to resolve it — 2 px of radius, half the point tier — published on the main thread, drawn from
## then on, and in whichever mode is current.
func _advance(body: SpacesimSceneBody, eye: Vector3, pixel: float, wireframe: bool) -> void:
	var distance := body.position.distance_to(eye)
	var screen := SpacesimLod.screen_radius_pixels(
		SpacesimLod.angular_radius(body.radius, distance), pixel
	)
	SpacesimIrregularBody.poll(body)
	if not body.irregular_built and screen >= SpacesimIrregularBody.RESOLVE_PIXELS:
		SpacesimIrregularBody.request(body)
	body.mesh.visible = body.irregular_built and screen >= SpacesimLod.POINT_TIER_SCREEN_RADIUS
	if body.mesh.visible:
		SpacesimIrregularBody.show_wireframe(body, wireframe)


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


## The body, its node, and the builder's own mesh material — nothing else.
func _make(fragment: SpacesimPopulationField.Fragment, where: Vector3) -> SpacesimSceneBody:
	var body := SpacesimSceneBody.from_content(
		content_for(_population, fragment.designation, fragment.diameter), _materials
	)
	body.position = where
	body.node = Node3D.new()
	body.node.name = fragment.designation
	body.node.position = where
	add_child(body.node)
	SpacesimIrregularBody.build(body.node, body, _materials)
	# **The splat stands down.** A fragment's point of light would be one or two pixels, and placing it is
	# `SpacesimSystemScene._place_point`'s job — so an unbuilt rock is simply not drawn for the moment its
	# extraction takes, rather than drawn as a wrongly-sized white disc.
	body.point.visible = false
	return body
