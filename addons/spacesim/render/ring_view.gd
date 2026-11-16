class_name SpacesimRingView
extends Node3D
## **A ring, drawn.** One `MultiMesh` of point quads, written once; two draw nodes holding it, cut into the
## half in front of the planet and the half behind; and a handful of uniforms a frame.
##
## **Nothing here is per-frame geometry.** The particles never move, so their transforms, radii and their place
## in the planet's shadow are baked at build. What changes is the eye — and the shader turns that into the
## quad's size, the particle's share of the band's optical depth and the sheet's brightness.
##
## ## Why two draws
##
## A planet's air is a transparent shader with the depth test **off**, so a single draw cannot be both in front
## of that air and behind it. Evert, 2026-11-15: *"Cut the rings exactly on the planet's centre so you split it
## into a front half that faces the camera and goes in front of the planet, and a back half that goes behind
## the planet."*
##
## The cut is the plane through the planet's centre at right angles to the **eye**, and both draws hold every
## particle — each collapses the ones on the other side in its vertex stage. Sorting 300,000 instances on the
## CPU every frame as the eye moves is the cost this design exists to avoid.
##
## ## The layer contract
##
## The two halves sit **outside** the planet's own transparent stack, which is declared and tested in
## [SpacesimBodyRenderer]. A tie is not an order: Godot sorts by `render_priority` and then by distance, and
## every one of these layers is a child of the planet's node, so their distances are equal to the metre. The
## previous attempt left the air and a cloud deck both at 0 and took a flight to find out.
const FAR_PRIORITY := -100
const NEAR_PRIORITY := 100

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
static func of(population: SpacesimPopulation, cloud: SpacesimParticleCloud) -> SpacesimRingView:
	var view := SpacesimRingView.new()
	view.name = "Ring_%s" % (population.id if population != null else "?")
	view._population = population
	view._cloud = cloud
	# **The ring plane is the population's axis**, so a band can lie in its planet's equatorial plane rather
	# than the world's. The particles are generated in this node's own x-y plane, so the basis orients every
	# one of them and nothing else has to know about the tilt.
	if population != null:
		view.basis = basis_for(population.ring_axis)
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
	for side in [1.0, -1.0]:
		var node := MultiMeshInstance3D.new()
		node.name = "SplatsNear" if side > 0.0 else "SplatsFar"
		node.multimesh = _multimesh
		# **A ring is a medium, not an obstacle**: it must not cast a shadow of its own, and the planet's shadow
		# on it is baked rather than rendered.
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := ShaderMaterial.new()
		material.shader = SHADER
		material.set_shader_parameter("split_side", side)
		material.render_priority = NEAR_PRIORITY if side > 0.0 else FAR_PRIORITY
		node.material_override = material
		add_child(node)
		_materials.append(material)
		_nodes.append(node)


## **The particles worth being rocks**, in the shape [SpacesimFragmentBodies] takes — an id, a world position,
## a diameter and a label.
##
## **One list, and it is the nearest few spots.** A spot that is a body is a rock: it has a node, a marker, a
## splat sized to the disc it would have, and a scale body that sets the travel unit — and it is `RESOLVE_PIXELS`
## away from becoming geometry. Nothing else promotes anything, so "every spot is a rock you can fly to" (`R16`)
## and "the next 24 are marked" (`R23`) are the same list at different zoom levels.
##
## **Ordered resolvable-first, then nearest**, because both matter and they are different questions: a big
## component resolves long before a small one at the same distance (`R22`), and the nearest one is what the
## ship is closing on and what the HUD's *Closest* line names (`R17`, `R18`).
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
	# **Which of them have earned geometry already**, so those come first and the rest fill the list by distance.
	var resolvable: Array[int] = []
	var ordered: Array[int] = []
	for index in candidates:
		var distance := plane_eye.distance_to(_cloud.positions[index])
		var screen := SpacesimLod.screen_radius_pixels(
			SpacesimLod.angular_radius(_cloud.radii[index], distance), pixel_angle
		)
		if screen >= SpacesimIrregularBody.RESOLVE_PIXELS:
			resolvable.append(index)
		ordered.append(index)
	var chosen: Array[int] = []
	for index in resolvable + ordered:
		if chosen.size() >= count:
			break
		if chosen.has(index):
			continue
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
## `illuminance` is the star's light at the ring and `albedo` the particles' bond albedo — the same derivation a
## moon's colour comes from — so the band's brightness is a physical quantity rather than a tuned scale.
func update(
	pixel_angle: float, illuminance: float, albedo: float, centre: Vector3, star_position: Vector3,
	observer: Vector3
) -> void:
	if _materials.is_empty() or _cloud == null:
		return
	var normal := (global_transform.basis * Vector3(0.0, 0.0, 1.0)).normalized()
	var sun_cosine := SpacesimRingModel.cosine(normal, star_position - centre)
	var eye_cosine := SpacesimRingModel.cosine(normal, observer - centre)
	var tau := _population.optical_depth
	var distance := maxf((observer - centre).length(), 1.0)
	# **How many particles land on one pixel**, which is what turns a share of `tau` into an alpha: the band's
	# projected area in pixels against the particles' own screen area. It is a host computation because it needs
	# the band's area, the mean size and the geometry, none of which a vertex stage has.
	var mean := maxf(_cloud.mean_radius(), 1.0)
	var pixel_length := maxf(distance * pixel_angle, 1.0e-9)
	var overlaps := (
		float(_cloud.size()) * PI * pow(maxf(mean, pixel_length), 2.0)
		/ maxf(SpacesimRingModel.area(_population) * maxf(eye_cosine, 0.02), 1.0)
	)
	var radiance := SpacesimRingModel.radiance(illuminance, albedo, tau, sun_cosine, eye_cosine)
	var split := observer - centre
	var direction := split.normalized() if split.length_squared() > 0.0 else Vector3.RIGHT
	for material in _materials:
		material.set_shader_parameter("pixel_angle", pixel_angle)
		material.set_shader_parameter("tau", tau)
		material.set_shader_parameter("eye_cosine", eye_cosine)
		material.set_shader_parameter("overlaps", maxf(overlaps, 1.0e-6))
		material.set_shader_parameter("mean_radius_px", maxf(mean / pixel_length, 1.0))
		material.set_shader_parameter("glow_linear", Color(radiance, radiance, radiance))
		var floor := SpacesimRingModel.unlit_radiance(radiance)
		material.set_shader_parameter("unlit_linear", Color(floor, floor, floor))
		material.set_shader_parameter("planet_origin", centre)
		material.set_shader_parameter("split_direction", direction)
	_uniforms = {
		"radiance": radiance, "sun_cosine": sun_cosine, "eye_cosine": eye_cosine,
		"overlaps": overlaps, "transmittance": SpacesimRingModel.transmittance(tau, eye_cosine),
	}


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
