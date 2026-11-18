class_name SpacesimRingView
extends Node3D
## **A ring, drawn.** One `MultiMesh` of point quads, written once; two draw nodes holding it, cut into the
## half in front of the planet and the half behind; and a handful of uniforms a frame.
##
## **Nothing here is per-frame geometry.** The particles never move, so their transforms, radii and their place
## in the planet's shadow are baked at build. What changes is the eye — and the shader turns that into the
## quad's size, the particle's share of the band's optical depth and the sheet's brightness.
##
## ## One draw, since 2026-11-18
##
## **Two draws were cut, and the cut was the bug.** The split existed so that the half of the band *behind* the
## planet could be drawn before the planet's air (which is transparent with the depth test off) and the half in
## front of it after. But the planet's own body hides the far half by depth — Evert: *"the far rings are covered
## by this body"* — so the split was buying only the haze over the far half's outer part, at the limb, and paying
## for it with every ordering fault this feature ever had: nine flight reports, a tie in the engine's sort, two
## failed reorderings, and finally a classification that hid the whole front half at some camera positions.
##
## A probe settled it: with the cut disabled (`split_side = 0`, so both nodes drew every particle) the front ring
## appeared over the planet correctly. Evert: *"now the rings actually stay put. So why do we have two overlapping
## rings again? If we draw both all the time, then we need only 1, right?"* Right. So there is one draw, drawn
## after everything a planet wears, and the 300,000 quads are halved with it.
##
## **What is given up, deliberately:** the far half's arc beyond the planet's limb is no longer veiled by the
## air's haze; it is drawn over it. That is a thin detail at the limb, and it is the price of not having a cut.
##
## ## The layer contract
##
## The two halves sit **outside** the planet's own transparent stack, which is declared and tested in
## [SpacesimBodyRenderer]. A tie is not an order: Godot sorts by `render_priority` and then by distance, and
## every one of these layers is a child of the planet's node, so their distances are equal to the metre. The
## previous attempt left the air and a cloud deck both at 0 and took a flight to find out.
## **The two halves sit outside the planet's whole stack**: the air and the decks run `0 … −n` and the sea `−8`,
## so −100 is beyond all of them and +100 ahead of all of them. The engine's sort rule is written down at
## `SpacesimBodyRenderer.INTERIOR_RENDER_PRIORITY`, and so is the reason the body's own stack is not touched.
## **After everything a planet wears**, and there is nothing above it: the band is one draw now, so this is the
## only priority it has. The body's stack runs from −8 (the sea) to 0 (air, decks, interior), see
## `SpacesimBodyRenderer`.
const RING_PRIORITY := 100


const SHADER := preload("res://addons/spacesim/render/shaders/ring_splats.gdshader")

var _population: SpacesimPopulation
var _cloud: SpacesimParticleCloud
var _multimesh: MultiMesh
var _materials: Array[ShaderMaterial] = []
var _nodes: Array[MultiMeshInstance3D] = []
## Which particles a body stands for, so their splats are not drawn. Keyed by particle index; the difference
## is written to the instance's custom data only when it changes.
var _hidden := {}
## What the shader is being told, so a test can read it back rather than guess from a picture.
var _uniforms := {}
## Each particle's baked shadow, so hiding one can rewrite its custom data without losing the shadow it was
## given. Only the spots that have bodies are ever touched, so this is a handful of entries.
var _transmissions := {}
## What fraction of the particles ended up in the planet's shadow — reported, so a test can assert it.
var shaded_fraction := 0.0


## Build the draw for one population, parented to the node of the body it orbits.
##
## **`local_axis` is the ring plane's normal in the PARENT's frame**, and it defaults to the population's own
## `ring_axis` — which is right only when the parent is not itself tilted. The scene tilts a ringed planet so its
## own pole is the ring's axis (see `SpacesimSystemScene._build_rings`), because a planet's mesh is drawn with
## model-space +Y as its pole and an untilted node would put the rings across the poles; once that is done the
## plane is `Vector3.UP` in the parent's frame and nothing else has to know.
static func of(
	population: SpacesimPopulation, cloud: SpacesimParticleCloud, local_axis := Vector3.ZERO
) -> SpacesimRingView:
	var view := SpacesimRingView.new()
	view.name = "Ring_%s" % (population.id if population != null else "?")
	view._population = population
	view._cloud = cloud
	# **The ring plane is the population's axis**, so a band can lie in its planet's equatorial plane rather
	# than the world's. The particles are generated in this node's own x-y plane, so the basis orients every
	# one of them and nothing else has to know about the tilt.
	if population != null:
		var axis := local_axis if local_axis.length_squared() > 0.0 else population.ring_axis
		view.basis = basis_for(axis)
	if cloud == null or cloud.size() == 0:
		return view
	view._build_multimesh()
	view._build_draws()
	return view


func _build_multimesh() -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = SpacesimBodyRenderer.point_quad()
	multimesh.instance_count = _cloud.size()
	for index in _cloud.size():
		# **The particle's radius rides in the instance's own basis scale**, not in the custom data: custom data
		# is packed as bytes, so a 4 mm radius quantised to zero while a transform holds floats. The shader
		# reads `length(MODELVIEW_MATRIX[0])` and builds its own quad; nothing else uses this.
		multimesh.set_instance_transform(
			index,
			Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * _cloud.radii[index]), _cloud.positions[index])
		)
		# `.r` is the baked shadow (full light until it is baked), `.g` is "draw this one".
		multimesh.set_instance_custom_data(index, Color(1.0, 1.0, 0.0, 0.0))
	_multimesh = multimesh


func _build_draws() -> void:
	var node := MultiMeshInstance3D.new()
	node.name = "Splats"
	node.multimesh = _multimesh
	# **A ring is a medium, not an obstacle**: it must not cast a shadow of its own, and the planet's shadow on
	# it is baked rather than rendered.
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.render_priority = RING_PRIORITY
	node.material_override = material
	add_child(node)
	_materials.append(material)
	_nodes.append(node)


## **The spots that have earned a BODY** — an id, a world position, a diameter and a label, in the shape
## [SpacesimFragmentBodies] takes.
##
## **Only what resolves.** Evert, 2026-11-18: *"only create a body when it becomes resolveable."* A body is a node,
## a material, a point of light and an orbital frame; a spot earns all of that when its own disc passes
## `RESOLVE_PIXELS` (`R22` — the size decides the range), and not before. A spot that is only worth naming is a
## **marker**, which costs a position and a string — see [method marker_targets].
##
## **The nearest spot is always included**, because the ship is closing on it and `advance_irregular` is what
## decides when it resolves; every other one has to have earned it.
##
## Evert, 2026-11-15: *"You already know the position of each spot on the ring, right? Can't we just range to
## the closest one? Then, when the camera gets close enough to start resolving the rocks, we can mark the
## closest few on the HUD and start instantiating meshes for them, the same way we do with asteroids and small
## moons."*
##
## `count` is how many candidates the caller will take; the answer is never longer than that.
func pieces(eye: Vector3, pixel_angle: float, count: int) -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	if _cloud == null or _population == null or pixel_angle <= 0.0 or count <= 0:
		return list
	# **This node's own frame IS the ring plane** — the basis was set from the population's axis — so the eye
	# converted into it is already the coordinate the particles live in.
	var plane_eye := global_transform.affine_inverse() * eye
	# **The band is a geometric shape, so the closest point on it is trigonometry**: clamp the ship's radius
	# into the band, keep its bearing. The search then starts where the answer is rather than at the ship's own
	# radius, which is what keeps a query from a million kilometres as cheap as one from a hundred.
	var on_sheet := SpacesimParticleCloud.closest_point(
		plane_eye, _population.semi_major_axis.x, _population.semi_major_axis.y
	)
	# A few extra, because ordering by distance from the sheet and from the ship differ when the ship is off
	# the plane; the true distances are sorted out below.
	var candidates := _cloud.nearest(on_sheet, count + 8, INF)
	var from_ship := plane_eye
	candidates.sort_custom(
		func(a: int, b: int) -> bool:
			return (
				_cloud.positions[a].distance_squared_to(from_ship)
				< _cloud.positions[b].distance_squared_to(from_ship)
			)
	)
	# **Only what resolves**, plus the nearest by distance — a big component earns geometry long before a small one
	# at the same distance, and the nearest is the one the ship is closing on.
	var chosen: Array[int] = []
	if candidates.size() > 0:
		chosen.append(candidates[0])
	for index in candidates:
		if chosen.size() >= count:
			break
		if chosen.has(index):
			continue
		var distance := plane_eye.distance_to(_cloud.positions[index])
		var screen := SpacesimLod.screen_radius_pixels(
			SpacesimLod.angular_radius(_cloud.radii[index], distance), pixel_angle
		)
		if screen >= SpacesimIrregularBody.RESOLVE_PIXELS:
			chosen.append(index)
	for index in chosen:
		var distance := plane_eye.distance_to(_cloud.positions[index])
		list.append({
			"id": spot_id(index),
			"position": global_transform * _cloud.positions[index],
			"diameter": _cloud.radii[index] * 2.0,
			"label": "%s Rock  %s" % [
				_band_name(), SpacesimMarkers.format_distance(_cloud.radii[index] * 2.0)
			],
		})
	return list


## **The spots worth NAMING** — `R23`: the next few rocks on the HUD, as a position and a string and nothing else.
##
## **Marked, not simulated.** Each entry is a marker target: `{id, position, text, priority, parent}` with a
## negative id of its own, because it has no node to borrow one from. The spots that resolve are bodies and arrive
## through `significant_nodes()` instead, so they are skipped here.
func marker_targets(eye: Vector3, pixel_angle: float, count: int) -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	if _cloud == null or _population == null or count <= 0:
		return list
	var plane_eye := global_transform.affine_inverse() * eye
	var on_sheet := SpacesimParticleCloud.closest_point(
		plane_eye, _population.semi_major_axis.x, _population.semi_major_axis.y
	)
	var candidates := _cloud.nearest(on_sheet, count + 8, INF)
	var ship := plane_eye
	candidates.sort_custom(
		func(a: int, b: int) -> bool:
			return (
				_cloud.positions[a].distance_squared_to(ship)
				< _cloud.positions[b].distance_squared_to(ship)
			)
	)
	for index in candidates:
		if list.size() >= count:
			break
		if _hidden.has(index):
			continue
		list.append({
			"id": -(index + 1),
			"position": global_transform * _cloud.positions[index],
			"text": "%s Rock  %s" % [
				_band_name(), SpacesimMarkers.format_distance(_cloud.radii[index] * 2.0)
			],
			"priority": SpacesimMarkers.Priority.ASTEROID,
			"parent": SpacesimMarkers.NO_PARENT,
		})
	return list


## **The nearest spot, as a place with a radius** — the travel unit's reference, with no body behind it.
##
## `S3`: a rock is significant from the moment it exists, so the speed falls as the ship closes on the band and
## **before** anything resolves. A `SpacesimScaleBody` needs a position and a radius and nothing else, so this
## returns exactly that and no node is created.
func nearest_spot(eye: Vector3) -> Dictionary:
	if _cloud == null or _population == null:
		return {}
	var plane_eye := global_transform.affine_inverse() * eye
	var on_sheet := SpacesimParticleCloud.closest_point(
		plane_eye, _population.semi_major_axis.x, _population.semi_major_axis.y
	)
	var found := _cloud.nearest(on_sheet, 1, INF)
	if found.is_empty():
		return {}
	var index := found[0]
	return {
		"position": global_transform * _cloud.positions[index],
		"radius": _cloud.radii[index],
		"name": "%s Rock" % _band_name(),
	}


## **How far the nearest spot of this band is**, in the band's own plane — the one query the HUD's rule needs.
##
## Evert, 2026-11-15: *"when the nearest spot on the ring is nearer than any of the other bodies, you can then
## check for and mark the next 24 rocks on the HUD."* So the pool is only worth asking for when this band is
## what the ship is actually flying through, and the answer is what decides it.
func nearest_distance(eye: Vector3) -> float:
	if _cloud == null or _population == null:
		return INF
	var plane_eye := global_transform.affine_inverse() * eye
	var on_sheet := SpacesimParticleCloud.closest_point(
		plane_eye, _population.semi_major_axis.x, _population.semi_major_axis.y
	)
	var found := _cloud.nearest(on_sheet, 1, INF)
	if found.is_empty():
		return INF
	return plane_eye.distance_to(_cloud.positions[found[0]])


## **The one identity a spot has.** The particle index is the truth; the string is what a body can be keyed by
## and what seeds its shape, so the same spot is the same rock every time it is resolved.
func spot_id(index: int) -> String:
	return "%s#%d" % [_population.id, index]


## The particle a spot id names, or -1.
static func index_of(id: String) -> int:
	var cut := id.rfind("#")
	return int(id.substr(cut + 1)) if cut >= 0 else -1


## **Stop drawing the splats that bodies stand for** — `R26`: the shape replaces the dot, and a dot left behind
## grows through the shape it was standing in for.
##
## Written as a difference, because the vertex shader reads this flag on every particle every frame and the set
## changes only when a spot is picked up or let go.
func set_hidden_ids(ids: Array) -> void:
	if _multimesh == null:
		return
	var wanted := {}
	for id in ids:
		var index := index_of(String(id))
		if index >= 0 and index < _cloud.size():
			wanted[index] = true
	for index in wanted:
		if _hidden.has(index):
			continue
		_hidden[index] = true
		_write_visible(index, false)
	for index in _hidden.keys():
		if wanted.has(index):
			continue
		_hidden.erase(index)
		_write_visible(index, true)


func _write_visible(index: int, visible: bool) -> void:
	var shadow := float(_transmissions.get(index, 1.0))
	_multimesh.set_instance_custom_data(index, Color(shadow, 1.0 if visible else 0.0, 0.0, 0.0))


## **Bake the planet's shadow into the particles.** They never move and neither does the star, so a particle's
## place in the umbra is a fixed fact about where it is — computed once, with the engine's own two-circle law
## ([method SpacesimLuminance.shadow_fraction]) rather than a shadow map, carried in the instance's custom data
## and read by the shader as the fraction of the star's light it gets.
##
## Returns the fraction of particles that ended up shaded, so a caller — and a test — can say what happened
## rather than guess from a picture.
func bake_shadow(
	star_position: Vector3, caster_position: Vector3, caster_radius: float, star_radius: float
) -> float:
	if _multimesh == null or _cloud == null or _cloud.size() == 0:
		return 0.0
	var shaded := 0
	for index in _cloud.size():
		var world := global_transform * _cloud.positions[index]
		var transmission := SpacesimLuminance.shadow_fraction(
			world, star_position, caster_position, caster_radius, star_radius
		)
		_transmissions[index] = transmission
		_multimesh.set_instance_custom_data(
			index, Color(transmission, 0.0 if _hidden.has(index) else 1.0, 0.0, 0.0)
		)
		if transmission < 0.5:
			shaded += 1
	shaded_fraction = float(shaded) / float(_cloud.size())
	return shaded_fraction


## **Per frame**: everything the shader needs that changes with the eye.
##
## **A rock's own surface brightness, not a sheet's.** `illuminance` is the star's light at the band and
## `albedo` the particles' bond albedo — the same derivation a moon's colour comes from — and the number handed
## over is `disc_luminance`, the same expression that colours a body's point of light. The shader turns that
## into a disc's share of each pixel, so what is drawn is 300,000 rocks rather than a band.
##
## **The band's own light is not here on purpose.** The drawn particles are the largest embedded objects: their
## own optical depth is 2 x 10⁻⁷ against the band's `tau = 1.2` (see `SpacesimRingModel.drawn_optical_depth`),
## so drawing them as the sheet made the ring orders of magnitude too bright. Evert, 2026-11-16: *"We don't want
## these rocks to make up the entire reflectance, we'll add the dust layer later."*
func update(
	pixel_angle: float, illuminance: float, albedo: float, centre: Vector3, star_position: Vector3,
	observer: Vector3
) -> void:
	if _materials.is_empty() or _cloud == null:
		return
	# **`disc_luminance` with the phase left out**, because the phase is per particle and the shader computes it:
	# what is handed over is the light arriving divided by pi times the albedo, which is everything Lambert's law
	# needs that is the same for the whole band.
	var radiance := illuminance * albedo / PI
	for material in _materials:
		material.set_shader_parameter("pixel_angle", pixel_angle)
		material.set_shader_parameter("glow_linear", Color(radiance, radiance, radiance))
		var floor := SpacesimRingModel.unlit_radiance(radiance)
		material.set_shader_parameter("unlit_linear", Color(floor, floor, floor))
		material.set_shader_parameter("star_position", star_position)
	_uniforms = {"radiance": radiance}


## **What the shader is being told** — for the tests, because "it draws nothing" is answered by reading the
## numbers rather than by looking at a picture.
func light() -> Dictionary:
	return _uniforms


func shader_parameter(name: String) -> Variant:
	return _materials[0].get_shader_parameter(name) if not _materials.is_empty() else null


func count() -> int:
	return _multimesh.instance_count if _multimesh != null else 0


func draw_nodes() -> Array[MultiMeshInstance3D]:
	return _nodes


func hidden_count() -> int:
	return _hidden.size()


## The band's name as a person reads it — the planet's, because a band is *Saturn's* ring.
func _band_name() -> String:
	var parent := get_parent()
	return String(parent.name) if parent != null else "Ring"


## A basis whose +z is the ring plane's normal.
static func basis_for(axis: Vector3) -> Basis:
	if axis.length_squared() < 1.0e-12:
		return Basis.IDENTITY
	var z := axis.normalized()
	var reference := Vector3.UP if absf(z.y) < 0.9 else Vector3.RIGHT
	var x := reference.cross(z).normalized()
	return Basis(x, z.cross(x), z)
