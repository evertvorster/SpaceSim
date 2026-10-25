class_name SpacesimSystemScene
extends RefCounted
## A solar system's **built scene**: the coordinate frames, geometry, scale bodies and transition
## rules, and the content they were built from.
##
## The content is authored ([SpacesimSolarSystem], a `Resource`); this half owns the nodes, because a
## resource is cached and shared and must not reference them. Bodies are placed by solving their
## orbits at the system's start time, or at their fixed position.
##
## A body that is not `landable` gets geometry and a scale body but no frames — it is something
## to fly past or into, not somewhere to go.

const Frame := preload("res://addons/spacesim/coordinate/frame.gd")
const FrameTree := preload("res://addons/spacesim/coordinate/frame_tree.gd")
const TransitionRule := preload("res://addons/spacesim/coordinate/transition_rule.gd")
const ScaleBody := preload("res://addons/spacesim/travel/scale_body.gd")
const Proximity := preload("res://addons/spacesim/travel/proximity.gd")

## Frame ids an asset owns, so the player can be *inside* something they own. Nothing can be entered
## yet; the ids exist so a location can name one when it can.
const ASSET_FRAME_PREFIX := "asset:"


## The authored content this scene was built from.
var content: SpacesimSolarSystem

var name: String ## read from the primary star
var bodies: Array[SpacesimSceneBody] = []

## Built by build().
var container: Node3D
var system_frame: SpacesimFrame
var frame_tree: SpacesimFrameTree

var start_body_id: String
var start_altitude: float
## Which side of the start body to begin on; zero means the side facing the star.
var start_direction: Vector3 = Vector3.ZERO

## The world's clock at the beginning of a story that has not been played yet.
var start_time: float = 0.0

## The environment the scene built, so the game can turn its volumetric fog on and off.
var environment: Environment
## The background sky: the real star field. Null when the catalogue did not load, in which case the
## environment keeps a flat background colour rather than rendering a black sky that reads as a bug.
var star_sky: SpacesimStarSky
var _framing: SpacesimFraming
## The baked surface maps, one cache for the whole system.
var _surface_maps := SpacesimSurfaceMaps.new()
## **The baked cloud maps, one cache for the whole system** — keyed `(body, layer)`, so a stack is entries
## rather than a second cache. Unlike the surface's, this one stays open: it has no local `RenderingDevice` of
## its own beyond the one `SpacesimCloudGpu` opens for a bake, and a deck refines on approach like the ground.
var _cloud_maps := SpacesimCloudMaps.new()
## **Draw the bodies' tessellation instead of the bodies.** Set by the game's wireframe toggle; read by
## `update_lod`, which swaps the line meshes and an unshaded white material in and out. Off, and nothing
## changes — it is a debug view, not a mode the renderer has to reason about.
var wireframe := false
## The frame the last `update_lod` ran in, so a change of frame can be seen and paid for.
var _last_frame_id := ""
## The star depth the ambient was last summed to. The ambient is the star field's own illuminance, and
## summing it walks the whole catalogue, so it is recomputed when this changes rather than every frame.
var _ambient_depth := -1.0
## World-clock seconds at which the orbital elements are stated — the content's `epoch`.
var _epoch_time: float = 0.0
## The star as a light source; null until build(). The node is `star_light.light`.
var star_light: SpacesimStarLight
## Triangles in the geometry the last `update_lod` left in place — the instrument the plan's first trap
## names: if this does not move when a body's screen size does, the policy is not being consulted.
var _triangles := 0


static func from_file(path: String) -> SpacesimSystemScene:
	var loaded: Variant = load(path)
	if loaded == null or not (loaded is SpacesimSolarSystem):
		push_error("SpacesimSystemScene: '%s' is not a solar system" % path)
		return null
	# A resource is shared, and building hangs nodes off what it is given: work on a copy, so two
	# scenes cannot fight over one authored system.
	var copy: SpacesimSolarSystem = loaded.duplicate(true)
	return from_content(copy)


static func from_content(content: SpacesimSolarSystem) -> SpacesimSystemScene:
	if content == null:
		return null
	var scene := SpacesimSystemScene.new()
	scene.content = content
	scene.name = content.system_name()
	scene._framing = content.framing if content.framing != null else SpacesimFraming.new()
	scene._epoch_time = SpacesimWorldTime.clock_at_epoch(content.epoch)
	scene.start_body_id = content.start_body_id
	scene.start_altitude = content.start_altitude
	scene.start_direction = content.start_direction
	scene.start_time = content.start_world_time
	for entry in content.bodies:
		scene.bodies.append(SpacesimSceneBody.from_content(entry, _materials()))
	return scene


## The material table a scene derives from: the one the engine ships. Held so one load serves every
## body rather than one per body.
static func _materials() -> SpacesimMaterialTable:
	return SpacesimMaterialTable.engine_table()


## The content revision this scene came from. A save records it so a mismatch is visible rather
## than silent.
func content_version() -> int:
	return content.content_version if content != null else 0


## Build the solar system's scene under `parent`. The observer is the caller's business: set
## `frame_tree.observer` and call `enter_frame()` afterwards.
func build(parent: Node) -> SpacesimSystemScene:
	container = Node3D.new()
	container.name = "SolarSystem"
	parent.add_child(container)

	_add_lighting()

	system_frame = Frame.new()
	system_frame.name = "System"
	system_frame.kind = Frame.Kind.SPACE
	system_frame.frame_id = Frame.SYSTEM_ID
	system_frame.travel_length_min = _framing.system_band.x
	system_frame.travel_length_max = _framing.system_band.y
	container.add_child(system_frame)

	frame_tree = FrameTree.new()
	frame_tree.name = "FrameTree"
	frame_tree.automatic = false # stepped explicitly, so the order with the observer's own step
	container.add_child(frame_tree)
	frame_tree.register(system_frame)

	_place_bodies()
	for body in bodies:
		_build_body(body)
	# **Every map is baked, so let go of the device.** Nothing bakes during flight by design, and a local
	# `RenderingDevice` alive for the length of a session is both the teardown segfault and the risk
	# `SpacesimSurfaceMaps.prepare()` exists to remove.
	_surface_maps.close()
	# **Every task added must be awaited before the engine goes away**, or the exit segfaults with no
	# output at all — the pool has to free what the task allocated. A rebuild is milliseconds, so the join
	# is one poll long.
	container.tree_exiting.connect(await_patch_builds)
	# **And the bake device, on the same signal.** A local `RenderingDevice` left alive to be destroyed at
	# teardown segfaults the process on exit, and the exit that matters here is not the player's: the engine's
	# own `--quit-after` tears the tree down without going anywhere near `main.gd`'s exit button.
	container.tree_exiting.connect(close)
	return self


func body_by_id(id: String) -> SpacesimSceneBody:
	for body in bodies:
		if body.id == id:
			return body
	return null


func scale_bodies() -> Array[SpacesimScaleBody]:
	var list: Array[SpacesimScaleBody] = []
	for body in bodies:
		if body.scale_body != null:
			list.append(body.scale_body)
	return list


## Every mesh in the system, so a debug key can hide or re-tessellate all of it.
func meshes() -> Array[MeshInstance3D]:
	var list: Array[MeshInstance3D] = []
	for body in bodies:
		if body.mesh != null:
			list.append(body.mesh)
	return list


## The bodies worth marking, in file order. Content decides which those are.
## For every **moon**, the body it orbits — keyed by the moon's node, so the navigation overlay can
## tell a moon's marker from a planet's without knowing anything about the system's structure.
##
## **Moons only.** A planet's own `parent_id` is its star, and "hidden by the thing you orbit" is not
## the same claim at all there: a star's disc is a fraction of a pixel from any distance, so the rule
## would hide planets for being roughly in the Sun's direction — which is where they spend half of
## every orbit. A moon is the case where the parent really does dominate what you can see.
##
## A fact about the system rather than about a frame, so it is built once.
func orbit_parents() -> Dictionary:
	var parents := {}
	for body in bodies:
		if body.kind != "moon" or body.node == null:
			continue
		var parent := body_by_id(body.parent_id)
		if parent != null and parent.node != null:
			parents[body.node] = parent
	return parents


func significant_nodes() -> Array[Node3D]:
	var list: Array[Node3D] = []
	for body in bodies:
		if body.significant and body.node != null:
			list.append(body.node)
	return list


## Where a fresh story puts the ship: above the start body, **on the side facing the star** unless
## content says otherwise.
##
## The default matters. A fixed +X put the ship on whichever side of the body happened to face *away*
## from the star — Earth sits at +X and the star is at the origin, so +X is night — and every fresh
## story began in the dark. That read as two unrelated faults: *"the scene looks too dark"* and *"I
## don't see the air at all"*, because volumetric fog needs light to be seen.
func ship_start() -> Vector3:
	var body := body_by_id(start_body_id)
	if body == null:
		return Vector3.ZERO
	var outward := start_direction
	if outward.length() < 0.5:
		outward = -body.node.global_position.normalized()
		if outward.length() < 0.5:
			outward = Vector3.RIGHT # the start body is the star itself
	return body.node.global_position + outward.normalized() * (body.radius + start_altitude)


## How far the camera must be able to see to draw this system: the outer edge of the system frame's
## band. **A body beyond the far plane is not drawn at all**, which reads as a missing body rather
## than a clipped one — Sol sat 0.67 au away from a camera whose far plane was 1e11 m, which is less
## than one au, so pointing at it drew nothing.
func view_distance() -> float:
	if system_frame == null:
		return 1.0e11
	return system_frame.travel_length_max


## Point the star's light correctly for something at `position`, and set its strength for that
## distance. A single directional light cannot light a whole system from a star, so it lights
## wherever the player is: the planet you are at is lit from the right side, and a planet on the far
## side of the star is lit from its own side rather than the near one. That is also the only distance
## whose illuminance is worth computing, because it is the only one the player can see.
func aim_sun_at(position: Vector3) -> void:
	if star_light == null:
		return
	var star_body := star()
	var origin := Vector3.ZERO
	if star_body != null and star_body.node != null:
		origin = star_body.node.global_position
	star_light.aim_at(position, origin)


func star() -> SpacesimSceneBody:
	for body in bodies:
		if body.kind == "star":
			return body
	return null


func body_for_surface_frame(frame: SpacesimFrame) -> SpacesimSceneBody:
	for body in bodies:
		if body.surface == frame:
			return body
	return null


## **The body whose air this frame is inside** — its atmosphere or surface frame, and null in space.
##
## Both are inside the body's air and the system frame is not, so this is the containment the frames
## already express rather than a second opinion about altitude.
func air_body(frame: SpacesimFrame) -> SpacesimSceneBody:
	for body in bodies:
		if body.atmosphere == frame or body.surface == frame:
			return body
	return null


## How far away the sky can be, from an observer inside this frame. Zero in space, where there is
## none.
##
## **The camera's far plane has to reach this or the sky is simply not drawn**, and the number is much
## larger than it looks. The air is a *thin skin* — 100 km over a 6,371 km planet — so the distance
## out to it is ~100 km straight up and ~1,130 km at the horizon. A far plane of 200 km, which is what
## `camera.range_surface` defaulted to, therefore drew the sky above 29° elevation and left everything
## from there down to the horizon beyond the plane: a black ring around the observer. It read as
## *"something black surrounding you"* at the surface, and vanished at 2 km because that is where the
## frame changes to the atmosphere frame and its 10,000 km range.
##
## **And the longest ray is not the horizontal one.** For an observer at radius `r`,
##
##     t(elevation) = -r sin(elevation) + sqrt((r sin(elevation))^2 + outer^2 - r^2)
##
## and `dt/d elevation` is negative everywhere — so `t` is *maximised* by the most negative elevation
## that still misses the planet, which is the ray that **grazes the limb and then climbs out**:
##
##     t_max = sqrt(r^2 - planet^2) + sqrt(outer^2 - r^2)
##             the horizon distance     the horizon exit
##
## At 1.5 km that is 138 km + 1,133 km = **1,272 km**, and the first version of this returned only the
## second term — 138 km short, which clipped a 1,460-pixel arc of haze exactly where the sky is
## brightest. Evert: *"the atmosphere that you look through is still much bigger radius."*
##
## Maximised over every altitude inside the air the two terms are equal, so the worst case is neat:
## `sqrt(2) * sqrt(outer^2 - planet^2)`. Earth derives 1,603 km — and this is a floor on `far`, so it
## is the cheap side to be generous on.
func sky_reach(frame: SpacesimFrame) -> float:
	var body := air_body(frame)
	if body == null:
		return 0.0
	# **The body's own air top**, not the framing's altitude: a giant's air is worth reaching far
	# higher than 100 km, and the far plane has to reach wherever the air actually ends.
	var outer := body.radius + body.sky_top
	return sqrt(2.0 * (outer * outer - body.radius * body.radius))


## Put a body's landing zone on the surface directly under `point`, with local up pointing away
## from the body's centre.
##
## The Coordinate doc's surface frame is "relative to landing zone", so the zone sits wherever
## the ship came down rather than at one fixed site — otherwise landing anywhere but that site
## would put the ship millions of metres from its frame's origin, which defeats the frame.
func place_landing_zone(body: SpacesimSceneBody, point: Vector3) -> void:
	if body.surface == null or body.node == null:
		return
	var outward := (point - body.node.global_position).normalized()
	if outward.length() < 0.5:
		outward = Vector3.RIGHT
	var reference := Vector3.BACK
	if absf(outward.dot(reference)) > 0.999:
		reference = Vector3.RIGHT
	var tangent := (reference - outward * outward.dot(reference)).normalized()
	var basis := Basis(tangent, outward, tangent.cross(outward))
	body.surface.global_transform = Transform3D(basis, body.node.global_position + outward * body.radius)


## Landing: the zone moves under the ship, and then the ship is put back where it was. The
## frame moved; the ship did not.
func _on_frame_changed(observer: Node3D, _from: SpacesimFrame, to: SpacesimFrame) -> void:
	if observer == null or to == null or to.kind != SpacesimFrame.Kind.SURFACE:
		return
	_aim_zone_under(observer, to)


## Put the landing zone under whatever is standing on it, without moving that thing.
func _aim_zone_under(subject: Node3D, frame: SpacesimFrame) -> void:
	var body := body_for_surface_frame(frame)
	if body == null:
		return
	var keep := subject.global_transform
	place_landing_zone(body, keep.origin)
	subject.global_transform = keep
	# **And reset the interpolator AGAIN, because the subject's PARENT moved — not the subject.**
	#
	# This is the same trap `SpacesimFrameTree.enter_frame` documents, one step further on: it resets the
	# interpolation when the observer is reparented, and then this function moves the frame the observer is
	# now a child of. The pose is written back so nothing has moved, but the *interpolator* was reset
	# against the frame's old transform, so the pose it holds is the one from before the move. With physics
	# interpolation on, the renderer then draws the ship — and the camera hanging off it — **gliding** from
	# where the frame used to be, which on the first landing is the build-time landing zone, a hemisphere
	# away. A frame rendered from there has no ground in it at all: the metre's mean collapses, it clamps to
	# `MAX_MULTIPLIER`, and a 32-stop correction in one frame is the white flash Evert sees at 1.7 km, at
	# exactly the moment the frame changes to `surface` — and only the first time, because afterwards the
	# zone is already under the ship and the move is nothing.
	subject.reset_physics_interpolation()


## Put the observer where a save says it was, and answer whether the system still had the frame that
## save named. A frame that is gone means the thing stands at the frame that remains, at its origin
## — the stored position would mean something else there.
##
## Note what is *not* restored: a surface frame's placement is the system's business (the zone moves
## under you as you land), so the saved position is where you were **in your locale**, not a point on
## a globe. Nothing here changes when terrain arrives; a surface will need its own placement.
func place_observer(location: SpacesimLocation) -> bool:
	if frame_tree.observer == null or location == null or not location.is_set():
		return false
	var exact := frame_tree.frame_by_id(location.frame_id) != null
	var frame := frame_tree.resolve_frame(location.frame_id)
	if frame == null:
		return false
	frame_tree.place_in_frame(frame_tree.observer, frame, location.position if exact else Vector3.ZERO)
	frame_tree.enter_frame(frame)
	if frame.kind == Frame.Kind.SURFACE:
		_aim_zone_under(frame_tree.observer, frame)
	return exact


func _parent_id_of(body: SpacesimSceneBody) -> String:
	if body.content != null and body.content.primary:
		return ""
	if not body.parent_id.is_empty():
		return body.parent_id
	return _primary_id()


func _primary_id() -> String:
	var primary := content.star() if content != null else null
	return primary.id if primary != null else ""


## Place every body in the system frame: the primary where it stands, everything else by solving
## its orbit at the start time, relative to whatever it orbits.
##
## Order is dependency, not file order — a moon is placed relative to its planet — and a body whose
## parent is not in the system says so instead of quietly landing at the origin, which is inside
## the star.
func _place_bodies() -> void:
	var placed := {}
	var pending: Array[SpacesimSceneBody] = bodies.duplicate()

	for _pass in bodies.size() + 1:
		if pending.is_empty():
			break
		var progressed := false
		for body in pending.duplicate():
			var parent_id := _parent_id_of(body)
			if not parent_id.is_empty() and not placed.has(parent_id):
				continue
			var origin: Vector3 = placed.get(parent_id, Vector3.ZERO)
			body.position = _position_of(body, origin, parent_id)
			placed[body.id] = body.position
			pending.erase(body)
			progressed = true
		if not progressed:
			break

	for body in pending:
		push_warning(
			"SpacesimSystemScene: '%s' orbits '%s', which is not in this system" % [body.id, body.parent_id]
		)
		body.position = body.fixed_position


## Where a body sits, given where its parent sits. A body with no orbit does not move; one with an
## orbit is solved, and does not move either when its parent's mass is not known — a body whose
## mass has not been derived yet should stand still rather than drift wrongly.
func _position_of(body: SpacesimSceneBody, origin: Vector3, parent_id: String) -> Vector3:
	if body.orbit == null:
		return body.fixed_position
	var parent := body_by_id(parent_id)
	var parent_mass := 0.0
	if parent != null and parent.content != null:
		parent_mass = parent.content.mass
	var body_mass := 0.0
	if body.content != null:
		body_mass = body.content.mass
	# Two bodies, so G(M + m) — a giant's own mass measurably shortens its own orbit.
	var mu := SpacesimKepler.mu_of(parent_mass + body_mass)
	return origin + SpacesimKepler.position_at(body.orbit, mu, start_time, _epoch_time)


func _build_body(body: SpacesimSceneBody) -> void:
	body.node = Node3D.new()
	body.node.name = body.name
	body.node.position = body.position
	body.node.set_meta("spacesim_body", body.id)
	system_frame.add_child(body.node)

	# **The map is baked here, and here only** — `build()` runs inside `_ready`, so this is before the first frame
	# and outside the frame loop. `SpacesimSurfaceMaps.prepare()` records what happens when it is moved into
	# `_process`: the engine's RID pools are exhausted in a few minutes of flight, because a local
	# `RenderingDevice`'s calls are render-thread-only and the device shares the driver with the frame's own.
	#
	# The ramp is then built from the *measured* quantiles, so the picture's band edges are the ones the map
	# actually has. A body with no bands at all — a gas giant, whose visible surface is its deck — keeps its
	# derived colour flat, which is what it was drawn in before.
	var light := _light_at(body)
	var bands: Array = []
	var entry: SpacesimSurfaceMaps.Entry = null
	# **A star samples no height map**, so it gets no bake: `material_for` picks the material by kind, and a star's
	# is `body_star.gdshader`, which has no `height_map` at all — so the bake would measure a field nothing draws.
	# The test is on the kind because the kind is what chooses the material (`a star emits, everything else
	# reflects`, the distinction that has been needed twice here), and naming the question is what stopped the
	# last version of this bug (`d57eb39`).
	if body.content != null and body.content.kind != SpacesimSystemBody.Kind.STAR:
		body.surface_ocean_fraction = SpacesimSurfaceModel.sea_level_percentile(
			body.content, _materials(), light.x, light.y
		)
		bands = SpacesimSurfaceModel.bands(body.content, _materials(), light.x, light.y)
		entry = _surface_maps.prepare(body.id, body.radius)
	var quantiles := SpacesimSurfaceMaps.linear_quantiles()
	if entry != null and not entry.quantiles.is_empty():
		quantiles = entry.quantiles
	# **One of these per body, and the ocean only where the derivation found liquid.** `bands()` carries each
	# material's phase, so a body with no sea gets no sea layer rather than one with zero coverage.
	body.ocean_material = SpacesimBodyRenderer.ocean_material(body, bands)
	body.mesh_material = SpacesimBodyRenderer.material_for(
		body, SpacesimBodyRenderer.surface_ramp(bands, quantiles, body.color),
		body.ocean_material != null
	)
	if entry != null and entry.base != null:
		var level := entry.value_at(body.surface_ocean_fraction)
		var surface := body.mesh_material as ShaderMaterial
		surface.set_shader_parameter("sea_level", level)
		SpacesimBodyRenderer.apply_surface_maps(surface, entry.base, entry.width,
			SpacesimSurfaceField.plan(body.id, body.radius).continent_frequency)
		# **The two layers share one threshold and one map** — the land culls below it and the ocean draws below
		# it, so a published sea level that reached only one of them would put a seam along every coast.
		if body.ocean_material != null:
			body.ocean_material.set_shader_parameter("sea_level", level)
			SpacesimBodyRenderer.apply_surface_maps(body.ocean_material, entry.base, entry.width)
			# 0.0 = no ladder on this material, which is what the ocean has.
	# The mesh itself is built by the first `update_lod`, from the patch tree — there is no whole-sphere
	# level to start from any more.
	body.mesh = _add_body_mesh(
		body.node, body.radius, body.mesh_material, "%sSurface" % body.name, 0
	)
	body.mesh.mesh = null
	# **The ocean is the body's own triangles, coplanar**, and it exists only where content and phase put water.
	# Sharing the mesh is the deck's arrangement: the sea's triangles *are* the ground's, so the two cannot
	# disagree about where the surface is, and the shore is a threshold on one map rather than a fitted edge.
	if body.ocean_material != null:
		body.ocean = _add_body_mesh(
			body.node, body.radius, body.ocean_material, "%sOcean" % body.name, 0
		)
		body.ocean.mesh = null
	body.point = _add_point(body.node, body.name)
	body.scale_body = ScaleBody.new(body.node, body.radius)
	_derive_air(body)
	_build_decks(body)
	_publish_air(body)

	if not body.landable:
		return

	var atmosphere_altitude := _framing.atmosphere_altitude
	var surface_altitude := _framing.surface_altitude

	body.atmosphere = Frame.new()
	body.atmosphere.name = "Atmosphere"
	body.atmosphere.kind = Frame.Kind.ATMOSPHERE
	body.atmosphere.frame_id = "%s/atmosphere" % body.id
	body.atmosphere.travel_length_min = _framing.atmosphere_band.x
	body.atmosphere.travel_length_max = _framing.atmosphere_band.y
	body.node.add_child(body.atmosphere)
	frame_tree.register(body.atmosphere)

	body.surface = Frame.new()
	body.surface.name = "Surface"
	body.surface.kind = Frame.Kind.SURFACE
	body.surface.frame_id = "%s/surface" % body.id
	body.surface.travel_length_min = _framing.surface_band.x
	body.surface.travel_length_max = _framing.surface_band.y
	body.node.add_child(body.surface)
	frame_tree.register(body.surface)
	place_landing_zone(body, body.node.global_position + Vector3(body.radius, 0.0, 0.0))
	_add_landing_site(body.surface)

	frame_tree.add_rule(
		TransitionRule.new(
			system_frame, body.atmosphere, body.node, body.radius, atmosphere_altitude, TransitionRule.Direction.ENTER
		)
	)
	frame_tree.add_rule(
		TransitionRule.new(
			body.atmosphere,
			system_frame,
			body.node,
			body.radius,
			atmosphere_altitude * 1.2,
			TransitionRule.Direction.EXIT
		)
	)
	frame_tree.add_rule(
		TransitionRule.new(
			body.atmosphere, body.surface, body.node, body.radius, surface_altitude, TransitionRule.Direction.ENTER
		)
	)
	frame_tree.add_rule(
		TransitionRule.new(
			body.surface,
			body.atmosphere,
			body.node,
			body.radius,
			surface_altitude * 1.5,
			TransitionRule.Direction.EXIT
		)
	)


func _add_lighting() -> void:
	# The star is a real light source: its luminosity and the distance to the observer give an
	# illuminance in lux, and the camera exposes for that. Nothing is hand-tuned per location, so the
	# same code lights Mercury and Neptune correctly — which a fixed energy cannot, since they differ
	# by 6,000:1.
	var luminosity := 0.0
	var temperature := 0.0
	var star_radius := 0.0
	var star_body := star()
	if star_body != null and star_body.content != null:
		luminosity = SpacesimStarModel.luminosity(star_body.content)
		temperature = SpacesimStarModel.effective_temperature(luminosity, star_body.radius)
		star_radius = star_body.radius
	star_light = SpacesimStarLight.new()
	star_light.create(container, luminosity, temperature, star_radius)

	var environment := Environment.new()
	# **The background is the real sky.** It used to be `BG_COLOR` with `Color(0.01, 0.012, 0.02)` — a
	# *look* value, and the exposure multiplier scaled it like everything else, so empty space
	# rendered bright blue at outer-system distances (measured 0.655, 0.733, 0.890 at Saturn) and
	# outshone every atmospheric limb. A star field is black where there are no stars, so multiplying
	# it by the exposure is *correct* — that is what dark adaptation is, and it needs no carve-out.
	star_sky = SpacesimStarSky.new()
	if star_sky.create():
		environment.background_mode = Environment.BG_SKY
		environment.sky = star_sky.sky
	else:
		# Said out loud, because a missing catalogue would otherwise look like a broken shader.
		push_warning("the star catalogue did not load; the sky is a flat colour")
		star_sky = null
		environment.background_mode = Environment.BG_COLOR
		environment.background_color = Color(0.01, 0.012, 0.02)
	SpacesimExposure.configure(environment)
	# **The ambient is the star field's own light, and it is set here as well as once a frame.** Here, so
	# that a night side is lit before the first frame and a scene built by a test is complete; once a
	# frame, so it follows `sky.star_depth` — see `update_sky`.
	if star_sky != null:
		_ambient_depth = float(SpacesimSettings.get_value("sky.star_depth"))
		SpacesimExposure.set_ambient_illuminance(environment, star_sky.illuminance(_ambient_depth))
	self.environment = environment
	var world_environment := WorldEnvironment.new()
	world_environment.name = "Environment"
	world_environment.environment = environment
	container.add_child(world_environment)


## **Which body's air the frame is looking through** — the nearest one that has any, from the observer, with
## everything the march needs. Empty when there is nothing to draw.
##
## **A star is not one of these.** A star's register is a photosphere, not an atmosphere this pass can march:
## treating the space around a star as air would extinguish its own disc. That is the accurate test; a distance
## limit is not.
func air_for_eye(observer: Vector3) -> Dictionary:
	var best := {}
	var best_distance := INF
	for body in bodies:
		if body.air.is_empty():
			continue
		if body.content != null and body.content.kind == SpacesimSystemBody.Kind.STAR:
			continue
		var distance := observer.distance_to(body.position)
		if distance >= best_distance:
			continue
		var sun := Vector3.UP
		var star_body := star()
		if star_body != null:
			sun = (star_body.position - body.position).normalized()
		best_distance = distance
		best = {
			"body": body,
			"centre": body.position,
			"planet_radius": body.radius,
			"atmosphere_radius": body.radius + body.sky_top,
			"sun_direction": sun,
			"air": body.air,
			"deck": near_deck(body, observer),
		}
	return best


## **The deck the near regime can draw, as `SpacesimAtmospherePass` needs it** — or `{}` when there is
## nothing to draw, which is the honest answer for a body with no deck, a layer with no thickness, or a map
## that has not landed.
##
## **The material is the source, not a second copy of it.** Threshold, gain and colour are what the shell is
## drawing with this frame, fitted to the map it is sampling, so reading them back is what stops the slab and
## the shell from disagreeing about the same cloud. The extinction comes from the same law the test asserts
## (`SpacesimCloudBand.extinction`) over the air's own derived scale height.
##
## **A layer's vertical optical depth at full thickness**, which is the one number opacity, the base's
## transmittance and the near regime's march all come from.
##
## A tau layer states it; a RAMP layer's equivalent is `SpacesimCloudMaps.column_depth()`, **which is where
## that law lives** — this function reads it rather than restating it. It used to carry its own copy with
## different clamps (`0.02..0.98` against the model's `0..0.999`), so the depth the deck drew with was not the
## depth its own `opacity_mean` was measured at: they agree at a mean of 0.5 and part company to 3.9 against
## 4.6 at 0.99. That is the "two copies drift apart on exactly the bodies nobody looks at" failure, in this
## function, while its own comment claimed one home.
func _deck_tau_full(body: SpacesimSceneBody, deck: SpacesimSceneBody.Deck) -> float:
	return SpacesimCloudMaps.column_depth(
		_cloud_maps.ramp_mean_of(body.id, deck.index), deck.optical_depth
	)


## The per-metre coefficient a march needs, from the layer's own column — `tau_full / thickness`, so the near
## regime integrates exactly the depth the shell draws with.
func _deck_extinction(body: SpacesimSceneBody, deck: SpacesimSceneBody.Deck) -> float:
	return _deck_tau_full(body, deck) / maxf(deck.thickness, 1.0)


## **The top layer only, and that is this rung's named limit.** The near regime is live inside or just under
## the top deck, where a lower deck is seen through the gaps of the one above — so the stack arrives with a
## sampler array and a per-deck loop, not before.
func near_deck(body: SpacesimSceneBody, observer: Vector3) -> Dictionary:
	if body == null or body.decks.is_empty() or body.air.is_empty():
		return {}
	var deck: SpacesimSceneBody.Deck = body.decks[0]
	if deck.material == null or deck.node == null or deck.thickness <= 0.0:
		return {}
	var cover = deck.material.get_shader_parameter("cover")
	if cover == null or deck.published_width <= 0:
		return {}
	var palette: Color = deck.material.get_shader_parameter("cloud_color")
	var gain := float(deck.material.get_shader_parameter("ramp_gain"))
	var extinction := _deck_extinction(body, deck)
	return {
		"base_radius": body.radius + deck.height,
		"top_radius": body.radius + deck.height + deck.thickness,
		"extinction": extinction,
		"threshold": float(deck.material.get_shader_parameter("threshold")),
		"column_height": deck.thickness,
		"radiance": Vector3(palette.r, palette.g, palette.b) * gain,
		"texture": cover,
		"basis": deck.node.global_transform.basis,
		# **Where the camera is, in the deck's OWN model space, computed here in double.** The fog samples the map
		# by the column above the camera, and that lookup used to be derived inside the shader from a float32
		# matrix — which is how it came to sample somewhere other than where the camera was: random fog in clear
		# air, and none where there was cloud. Computed here, the maths is double, it is one line to test, and the
		# shader only normalises it.
		"eye_model": (deck.node.global_transform.basis.inverse()
			* (observer - deck.node.global_position)),
		# What the march needs to choose a mip: texels around the equator.
		"width": deck.published_width,
	}


## **The air's numbers, derived once per body**: its scattering coefficients, its heights, and the
## dictionary `SpacesimAtmospherePass` reads.
##
## **How tall it is, and why that is derived.** `SHELL_SCALE_HEIGHTS` scale heights, floored by the
## framing's own atmosphere altitude — one authored altitude for the whole system is right for exactly one
## body: 100 km is twelve scale heights over Earth and four over Jupiter, where the air is still 2% of
## surface density at the top. `SpacesimSystemScene.sky_reach()` then reads it, because the camera's far
## plane has to reach the sky.
##
## **Nothing here draws anything.** The shell that used to be built from these numbers is gone; the march
## that draws the air (`SpacesimAtmospherePass`) is given the numbers, and that is the only consumer.
func _derive_air(body: SpacesimSceneBody) -> void:
	if body.content == null or body.content.atmosphere == null:
		return
	# The coefficients are evaluated at the body's equilibrium temperature, which is §3.6's first row
	# and the only temperature there is. Named in SpacesimAtmosphereModel, not guessed here.
	var light := _light_at(body)
	var temperature := SpacesimAtmosphereModel.reference_temperature(
		body.content, _materials(), light.x, light.y
	)
	var gravity := SpacesimAtmosphereModel.surface_gravity(body.content)
	var air_reach := SpacesimAtmosphereModel.shell_reach(
		body.content.atmosphere, _materials(), temperature, gravity
	)
	body.sky_top = maxf(air_reach, _framing.atmosphere_altitude)
	# **The air's scattering numbers, derived once**, in the one dictionary `SpacesimAtmospherePass` reads. A
	# second derivation on the draw side would be a second sky, and it is the numbers rather than the shader
	# that decide what colour the air is. `sun_intensity` is `sky_scale(illuminance)` — the frame's own
	# currency (`radiance / UNIT_LUX_PER_SR`), not lux.
	body.air = {
		"rayleigh": SpacesimAtmosphereModel.rayleigh_coefficient(
			body.content.atmosphere, _materials(), temperature
		),
		"rayleigh_scale_height": SpacesimAtmosphereModel.scale_height(
			body.content.atmosphere, _materials(), temperature, gravity
		),
		"absorption": SpacesimAtmosphereModel.absorption_coefficient(
			body.content.atmosphere, _materials(), temperature
		),
		"mie": SpacesimAtmosphereModel.MIE_COEFFICIENT,
		"mie_scale_height": SpacesimAtmosphereModel.MIE_SCALE_HEIGHT,
		"mie_anisotropy": SpacesimAtmosphereModel.MIE_ANISOTROPY,
		"sun_intensity": SpacesimAtmosphereModel.sky_scale(
			SpacesimStarLight.illuminance(SpacesimStarModel.luminosity(
				star().content if star() != null and star().content != null else null
			), _light_at(body).y)
		),
		"temperature": temperature,
	}


## **The cloud stack: one deck per layer the model places a level for.**
##
## **A loop, not a field.** Earth happens to author one deck and Jupiter two, and the code does not know the
## difference — a stack is what the next step asks for anyway and a loop costs a `for`. Evert, 2026-10-20.
##
## **A layer is paired to its level by SPECIES**, which is the only thing tying the two together: the level's
## altitude is derived from the air and the species' own condensation temperature, and the layer states what
## it is made of. A layer that names no species — the flat shorthand every body but Jupiter and Saturn
## authors — takes the highest unclaimed level, which is the deck seen from outside.
##
## A body with no air, no authored deck, or no condensable that forms a `LEVEL` gets no deck at all, which is
## three different reasons for the same empty answer and none of them a zero-height shell.
func _build_decks(body: SpacesimSceneBody) -> void:
	if body.content == null or body.content.atmosphere == null or body.content.clouds == null:
		return
	var clouds := body.content.clouds
	if clouds.layer_count() <= 0:
		return
	var light := _light_at(body)
	var materials := _materials()
	var gravity := SpacesimAtmosphereModel.surface_gravity(body.content)
	# **`equilibrium_temperature`, never `reference_temperature`** — see `condensation_levels`. The latter
	# returns what content *pinned* as a mean surface temperature, and the tropopause is the equilibrium's
	# skin temperature: passed the pinned one, Venus's ceiling rises to 620 K and its deck disappears.
	var equilibrium := SpacesimAtmosphereModel.equilibrium_temperature(
		body.content, materials, light.x, light.y
	)
	var morphology := SpacesimCloudModel.morphology(body.content, materials, light.x, light.y)
	var unclaimed := SpacesimCloudModel.layers(
		body.content.atmosphere, materials, gravity, equilibrium, body.content
	)
	for index in clouds.layer_count():
		var level := _claim_level(unclaimed, clouds.species_at(index))
		if level == null:
			continue
		var deck := SpacesimSceneBody.Deck.new()
		deck.index = index
		deck.level = level
		deck.height = level.height
		deck.thickness = level.thickness
		deck.coverage = clouds.coverage_at(index)
		deck.albedo = clouds.albedo_at(index)
		deck.palette = _cloud_palette(clouds, index, materials)
		deck.optical_depth = clouds.optical_depth_at(index)
		# **What the SHADOW is cast with.** A layer on the ramp path states no optical depth, and its honest
		# equivalent is `−ln(1 − opacity)` — "how opaque it is where it covers" already means `α = 1 − e^{−τ}`.
		deck.shadow_tau = deck.optical_depth
		if deck.shadow_tau <= 0.0:
			deck.shadow_tau = -log(maxf(1.0 - clouds.opacity_at(index), 1.0e-3))
		deck.morphology = morphology
		deck.material = SpacesimBodyRenderer.deck_material(body, level, deck.palette, index)
		# **The node is the body's own unit sphere scaled to the slab's BASE** (2026-10-21) — *a condensation
		# level is a level*, so every column starts at the same altitude and the base is the one surface a single
		# sphere can honestly be. The tops vary by column, which is what the map's luminance-as-height encodes and
		# what no one sphere can hold. From altitude the radius difference is 1.6 km in 6,374 — invisible — and
		# from underneath it is the difference between the cloud's real underside and a mirrored sheet at the top
		# of the tallest column.
		var base_radius := body.radius + deck.height
		deck.node = _add_body_mesh(
			body.node, base_radius, deck.material, "%sDeck%d" % [body.name, index], 0
		)
		deck.node.mesh = null
		body.decks.append(deck)


## **The level a content layer is made of**, taken out of the unclaimed pool so two layers cannot land on
## the same altitude — which on a body with one level would otherwise draw the same deck twice.
func _claim_level(
	unclaimed: Array, species: String
) -> SpacesimAtmosphereModel.Condensation:
	if unclaimed.is_empty():
		return null
	var chosen := -1
	if species.is_empty():
		chosen = 0
	else:
		for index in unclaimed.size():
			if (unclaimed[index] as SpacesimAtmosphereModel.Condensation).species == species:
				chosen = index
				break
	if chosen < 0:
		return null
	var level: SpacesimAtmosphereModel.Condensation = unclaimed[chosen]
	unclaimed.remove_at(chosen)
	return level


## **What colour a deck is** — stated beats derived, the rule the whole table runs on: `Color(0, 0, 0, 0)`
## means "not stated", and then the species' own scattering colour is used, so water is white because water
## is white. A giant's tint is a chromophore that no species carries yet, which is why content states it.
func _cloud_palette(
	clouds: SpacesimClouds, index: int, materials: SpacesimMaterialTable
) -> Color:
	var stated := clouds.color_at(index)
	if stated.a > 0.0:
		return stated
	var material := materials.by_name(clouds.species_at(index))
	if material != null and material.color.a > 0.0:
		return material.color
	return Color.WHITE


## The star's luminosity and this body's distance from it — the pair every per-body derivation needs and
## none of them can work out for itself. Distance rather than position, because a GLSL float's seven
## significant digits at 1.5e11 m are worth about 16 km — coarser than an air column is deep — so a
## subtraction done in the shader would lose the answer.
func _light_at(body: SpacesimSceneBody) -> Vector2:
	var star_body := star()
	if star_body == null or star_body.content == null:
		return Vector2.ZERO
	return Vector2(
		SpacesimStarModel.luminosity(star_body.content),
		body.position.distance_to(star_body.position)
	)


## Point the sky at the camera and set how deep it is drawn.
##
## Called once a frame: the sky follows the **camera**, not the ship, because it is the eye that sees it
## and nothing about it depends on which body the player is attached to. The depth is read from settings every frame rather than cached, so it is hot by
## construction like every other setting.
func update_sky(camera: Camera3D) -> void:
	if star_sky == null or camera == null:
		return
	star_sky.set_limit_magnitude(float(SpacesimSettings.get_value("sky.star_depth")))
	# The manual brightness scaler, in DECADES. Read every frame so it is hot by construction and can
	# be dragged while flying.
	star_sky.set_gain(pow(10.0, float(SpacesimSettings.get_value("sky.star_gain"))))
	star_sky.update(camera)

	# **The ambient is that same star field, summed from the catalogue.** Recomputed only when the depth
	# changes, because the sum walks all 119,613 stars and this runs every frame — a float compare once
	# a frame is the price of the depth being hot. Nothing else can make it disagree with the sky above
	# it, which is the whole reason the ambient is taken from the sky rather than authored.
	var depth := float(SpacesimSettings.get_value("sky.star_depth"))
	if not is_equal_approx(depth, _ambient_depth):
		_ambient_depth = depth
		SpacesimExposure.set_ambient_illuminance(environment, star_sky.illuminance(depth))


## A body's geometry: a shared unit icosphere, scaled by the body's radius.
##
## **Levels are built once at unit radius and shared by every body**, which is the whole point of the
## primitive: a level change is a pointer assignment, where `SphereMesh` re-tessellated on every
## property change — and re-tessellating per body per crossing is what made adaptive detail look
## unaffordable. The radius goes on the node's scale, so the mesh resources stay shared.
##
## No triplanar or `world_vertex_coords`: neither gets the double-precision vertex transform emulation,
## and both jitter at planet scale. **A scaled unit mesh is a new case for that emulation**, and this
## project has been bitten by render modes that skip it — so it is confirmed by a render at planet
## scale rather than by reasoning.
func _add_body_mesh(
	parent: Node3D, radius: float, material: Material, mesh_name: String, level: int
) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = mesh_name
	mesh.mesh = SpacesimIcosphere.mesh_at(level)
	mesh.scale = Vector3.ONE * radius
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh)
	return mesh


## The **point of light** a body becomes once it is too small to be a disc: a camera-facing quad, sized
## to the disc it would have had and coloured by its radiance. Hidden until `update_lod` says otherwise.
func _add_point(parent: Node3D, body_name: String) -> MeshInstance3D:
	var point := MeshInstance3D.new()
	point.name = "%sPoint" % body_name
	point.mesh = SpacesimBodyRenderer.point_quad()
	point.material_override = SpacesimBodyRenderer.point_material()
	point.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	point.visible = false
	parent.add_child(point)
	return point


## Hand every body the tessellation its angular size has earned, once a frame.
##
## **The surface is a patch tree, not one level per body.** `SpacesimPatches` selects which chunks to
## subdivide from the same pixel budget, and the walk re-runs only when the eye has moved
## logarithmically far enough to matter — `SpacesimPatches.walk_is_due`.
##
## **And a body too small to be a disc stops being geometry at all**: its mesh goes, and its point of
## light appears in its place, coloured by `body_luminance`. A body that stops being drawn is still lit
## by, still marked, and still an effect on everything else: this reads `bodies`.
##
## **No body is exempt, the star included.** A star's disc is a fraction of a pixel from any distance,
## so it spends almost all of its time as a point of light — and that is right: what it puts on the
## screen is its own emission, over the same area, so its glare survives the handoff exactly as a
## planet's brightness does. See `SpacesimBodyRenderer.point_colour` for the one by-kind difference
## that remains, which is that a star **emits** and everything else reflects.
## `delta` is the frame's own — the only thing F5's projection needs, and **optional**, because an instrument (the
## profiler, a probe) may call this without a clock and should then get no speculative work rather than a wrong rate.
func update_lod(camera: Camera3D, delta: float = 0.0) -> void:
	if camera == null:
		return
	var viewport := camera.get_viewport()
	if viewport == null:
		return
	# The **render target's** height, not the canvas rect's — see `SpacesimLod.pixel_angle`.
	var pixel := SpacesimLod.pixel_angle(camera.fov, float(viewport.size.y))
	if pixel <= 0.0:
		return
	var epsilon := float(SpacesimSettings.get_value("lod.error_budget"))
	# **The surface map's ceiling is derived from the resolution the scene is being rendered at**, as a fraction
	# of it (`surface.max_base_fraction`, 0.5 = half). Read per frame rather than cached: the setting exists to
	# be moved **while flying**, to watch the cost move with it.
	var surface_cap := SpacesimSurfaceMaps.base_max_width(
		Vector2i(viewport.size), float(SpacesimSettings.get_value("surface.max_base_fraction"))
	)
	# **The interpolated eye**, because this runs once a drawn frame and `get_global_transform()` is
	# only accurate to the most recent physics tick. It is the same transform the camera is drawn with,
	# so the level chosen belongs to the frame on screen — see `game/main.gd::_update_view`.
	#
	# Typed explicitly: `get_global_transform_interpolated()` has no inferable return type, so `:=`
	# here is the `INFERENCE_ON_VARIANT` error, and everything derived from the result with it.
	var observer: Vector3 = camera.get_global_transform_interpolated().origin
	# **Publish whatever landed since the last frame**, before any of it is counted: a rebuild is a mesh
	# that appears a frame or two after it was asked for, never a stall in the frame that asked.
	# **Collected before the bodies are walked**, so a bake that landed this frame is drawn this frame.
	_surface_maps.poll()
	# **A deck's map lands the same way the ground's does**, and it is polled before the walk so a bake that
	# arrived this frame is drawn this frame. The cloud cache has no bake pass of its own — a floor bake is
	# synchronous and a refinement is a pool task (or a main-thread dispatch), so there is nothing to attach.
	_cloud_maps.poll()
	_poll_patch_builds()
	for body in bodies:
		if body.node == null:
			continue
		var distance := observer.distance_to(body.node.global_position)
		var energy := SpacesimLod.angular_radius(body.radius, distance)
		var screen := SpacesimLod.screen_radius_pixels(energy, pixel)
		var is_point: bool = screen < SpacesimLod.POINT_TIER_SCREEN_RADIUS
		if body.mesh != null:
			body.mesh.visible = not is_point
		if body.ocean != null:
			body.ocean.visible = not is_point
		# **A wireframe view is about triangles**, and a cloud deck would cover the ones under test.
		for deck in body.decks:
			deck.node.visible = not is_point and not wireframe
		# **A body too small to be a disc is its own light, and nothing else is drawn for it.** The air is
		# not drawn by anything yet, and a deck is not a thing this tree has.
		if body.point != null:
			body.point.visible = is_point
		if is_point:
			_place_point(body, observer, energy, distance, pixel, screen, camera)
			continue
		if body.mesh == null:
			continue
		_refine_surface_map(body, distance, pixel, surface_cap, delta)
		_refine_surface_tiles(
			body, distance, pixel, (observer - body.node.global_position).normalized(), surface_cap
		)
		_face_bodies_at_star(body, observer)
		_update_decks(body, observer, distance)
		# **The surface is a PATCH TREE, not a sphere at one level.** Evert, 2026-10-17: *"it suddenly
		# switches to a higher density of triangles, but once only, and for the whole sphere"* — which is
		# what one level per body is. `SpacesimPatches` refines where the eye is and culls over the limb,
		# so the triangle count is now a consequence of what is visible rather than of the body's size.
		#
		# **The walk is gated**, because it is a pure function of (distance, direction, ε) and only has to
		# run when one of those has changed its answer. That replaced a brittle rebuild *key* — the selection
		# count plus a quantised altitude and direction — which took two faults to get right (a packed int
		# that collided, then a bucket on `log(d/R)` that went flat near the ground and stopped refining).
		# A gate on what the law actually depends on cannot go stale in either of those ways.
		var to_eye := (observer - body.node.global_position).normalized()
		if SpacesimPatches.walk_is_due(
			body.patch_walk_distance, body.patch_walk_direction, distance, to_eye,
			pixel, epsilon, body.radius, body.patch_walk_epsilon
		) or wireframe != body.patch_walk_wireframe:
			body.patch_chunks = SpacesimPatches.select(
				distance, to_eye, body.radius, pixel, epsilon
			)
			# **A selection of nothing has a reason, and it is worth printing once.** `select()` refuses a
			# sphere it cannot see round — the eye at or below the surface, or a pixel angle or budget of
			# zero — and an empty answer looks exactly like a body that was never walked.
			if body.patch_chunks.is_empty() and not body.patch_empty_reported:
				body.patch_empty_reported = true
				print(
					"PATCH: %s has no patches — distance %.1f m, radius %.1f m, altitude %.1f m, "
					% [body.name, distance, body.radius, distance - body.radius]
					+ "pixel %.6f, epsilon %.2f" % [pixel, epsilon]
				)
			body.patch_walk_distance = distance
			body.patch_walk_direction = to_eye
			body.patch_walk_epsilon = epsilon
			body.patch_walk_wireframe = wireframe
			_request_patch_build(body, wireframe)
	# **A frame change is a synchronous rebuild.** A mesh belongs to a viewpoint, and a transition is a
	# discrete event — the near and far planes change, the observer is moved, and the frame that follows is a
	# different scene. Drawing it with the geometry selected for the previous one is wrong however it looks,
	# and a frame carrying the previous regime's surface is a large change of luminance to the exposure metre:
	# from orbit, the selection's facets sag up to half a kilometre, so from 1.5 km up you are looking at a
	# surface built for a viewpoint 100 km away. Paying the build here is a few milliseconds at a moment that
	# already costs a teleport; a frame of the wrong geometry is not.
	var frame_id := frame_tree.active_frame.frame_id if frame_tree.active_frame != null else ""
	if frame_id != _last_frame_id:
		_last_frame_id = frame_id
		await_patch_builds()
	# **Counted once, from what is visible**, rather than accumulated as the loop goes: the HUD's number and
	# an instrument's independent count then cannot disagree about a body that landed or was culled
	# mid-frame.
	_triangles = _count_drawn_triangles()


## **What is actually drawn this frame**, summed over the bodies: a point of light where a body is below
## the tier, its patches where it is not. One place, so the HUD's number, the instruments that compare
## against it, and the picture cannot disagree.
func _count_drawn_triangles() -> int:
	var total := 0
	for body in bodies:
		if body.node == null:
			continue
		if body.point != null and body.point.visible:
			total += SpacesimBodyRenderer.POINT_TRIANGLES
		elif body.mesh != null and body.mesh.visible:
			total += body.patch_triangles
	return total


## **Ask for a rebuild, without doing it here.** The merged chunk arrays are the expensive half of a
## rebuild and they touch nothing that needs the main thread, so they go to the pool; the mesh is built
## from them in `_poll_patch_builds`, because `add_surface_from_arrays` is a `RenderingServer` call and
## that is the one boundary that cannot be crossed.
##
## **`patch_triangles` is not written until the arrays land**: the count on the body describes the mesh
## that is actually there, never the one that was asked for.
func _request_patch_build(body: SpacesimSceneBody, lines: bool) -> void:
	body.patch_task_chunks = body.patch_chunks
	body.patch_task_wireframe = lines
	if body.patch_task != -1:
		# A build is already in flight. Its result will be published and then seen to be stale, which
		# starts the next one — cheaper than a queue and correct without one.
		return
	body.patch_arrays = []
	body.patch_task = WorkerThreadPool.add_task(
		Callable(self, "_build_patch_arrays").bind(body, body.patch_chunks, lines)
	)


## **Runs on a worker thread.** Reads the static chunk cache (which locks) and writes one field on one
## body; touches no node, no `RenderingServer` and no settings.
func _build_patch_arrays(body: SpacesimSceneBody, chunks: Array, lines: bool) -> void:
	body.patch_arrays = (
		SpacesimPatches.lines_of(chunks) if lines else SpacesimPatches.arrays_of(chunks)
	)


## **The main thread's half**, once a frame: the arrays become a mesh, and the body starts drawing it.
##
## **`is_task_completed` must be asked before `wait_for_task_completion`, never after** — waiting consumes
## the task, so a second question about it answers *no* and the poll silently does nothing. That mistake
## cost a session, and it shows up as a body with no mesh rather than as a failure.
## The surface map cache, for the probes that drive it and for anything that wants to ask what was measured.
## Read-only in practice: the cache owns its entries.
func surface_maps() -> SpacesimSurfaceMaps:
	return _surface_maps


## **Let go of the GPU bake's device.** A local `RenderingDevice` left alive to be destroyed at process
## teardown segfaults the process on exit, and the cache owns the only one the scene has. `main.gd` calls this
## on the way out.
func close() -> void:
	_surface_maps.close()
	# **The deck's cache goes the same way, and for its own reason**: a refinement is a pool task (or a local
	# device's dispatch), and the pool will not let a task outlive the engine. The bail goes up first so a 27 s
	# bake stops at its next row rather than trading a crash for a hung exit.
	_cloud_maps.close()


## **Hand the surface maps a render-thread bake pass** — from `main.gd`, which owns the camera's compositor.
## Without one, every body keeps the map baked at scene build.
func attach_surface_bake(bake_pass: SpacesimSurfaceBakePass) -> void:
	_surface_maps.attach_bake(bake_pass)


## **The air's share of the star's light, at each material's own altitude** — once, here, because the
## coefficients come from the body's composition and the levels from its condensation profile, and neither
## changes while the game runs.
##
## **A deck is published at its own height, and that is the point of the altitude argument**: a tangent clears
## the ground for a point above it, so a cloud at 1.4 km is still lit after the ground beside it has gone
## dark, and is dim and orange while it is. Publishing zero to every layer would put a cloud's sunset at the
## same instant as the ground's and take the geometry out of it.
func _publish_air(body: SpacesimSceneBody) -> void:
	for material in [body.mesh_material, body.ocean_material]:
		SpacesimBodyRenderer.apply_air(material, body.air, 0.0)
	for deck in body.decks:
		SpacesimBodyRenderer.apply_air(deck.material, body.air, deck.height)


## **Where the star is, and how wide it looks, for every drawn body** — per frame, and NOT inside `_update_decks`.
##
## **The move is the fix for a real trap, and the trap is why the name changed.** The publish used to sit after
## `_update_decks`' `decks.is_empty()` early return, so a body with no deck — Luna, Mercury, Mars — never got it
## and kept the uniform's default `Vector3.UP`. That was harmless while the only reader was a deck's shadow, and
## it is a shading error the moment the surface's own star occlusion reads it: every airless body would have had
## its terminator computed against a northern sun. Nothing would have reported it.
##
## `star_angle` is `asin(R_star / d)` off `SpacesimLod.angular_radius`, the same call the light's own
## `light_angular_distance` makes, so a body's penumbra and its light's softness are one number.
func _face_bodies_at_star(body: SpacesimSceneBody, observer: Vector3) -> void:
	var star_body := star()
	var sun := Vector3.UP
	var star_angle := 0.0
	if star_body != null:
		var to_star: Vector3 = star_body.position - body.position
		sun = to_star.normalized()
		star_angle = SpacesimLod.angular_radius(star_body.radius, to_star.length())
	var materials := [body.mesh_material, body.ocean_material]
	# **A deck is lit by the same star**, and its own shader does its own air and occlusion maths, so it needs
	# the direction and the width as well as the ground does.
	for deck in body.decks:
		materials.append(deck.material)
	# The eye in body radii — the model space every surface direction is measured in, and the same units the
	# deck's own material is handed as `eye_local`.
	var eye_local := (observer - body.node.global_position) / maxf(body.radius, 1.0)
	for material in materials:
		SpacesimBodyRenderer.face_surface_star(material, sun, star_angle, eye_local)


## **A deck, per frame, per layer**: the eye in the deck's own frame, and the map it should be sampling.
##
## **Not the star** — that is `_face_bodies_at_star`'s, because it is a surface fact and every body needs it,
## deck or no deck.
##
## **Publishing happens when a map lands, not every frame.** The threshold, the ramp gain and the detail
## ladder's first octave are all measured off the map in hand, so they must move together and only when it
## moves — the same rule the ground's materials follow. What changes every frame is the eye's position, which
## is two uniform writes and no measurement at all.
##
## **The eye is handed over in the deck's model space**, divided by the top radius here, in double precision:
## a deck node's model space is a unit sphere, so nothing astronomical ever reaches a `float`.
func _update_decks(body: SpacesimSceneBody, observer: Vector3, distance: float) -> void:
	if body.decks.is_empty():
		return
	# **Read through `get_value` so the switch stays hot.** One switch for this mechanism, and it reads no
	# other one — `show_decks = render.cloud_decks and not volume` made "turn the decks on" a lie.
	if not bool(SpacesimSettings.get_value("render.cloud_decks")):
		for deck in body.decks:
			deck.node.visible = false
		return
	var to_eye := observer - body.node.global_position
	var shadowing := _shadowing_deck(body)
	for deck in body.decks:
		# Divided by the sphere's own radius, because the node's model space is a unit sphere.
		var sphere_radius := body.radius + deck.height
		SpacesimBodyRenderer.face_deck(deck.material, to_eye / maxf(sphere_radius, 1.0))
		# **The base's light, every frame**, because the star's direction and the sky above the deck are what
		# it is made of. Six uniform writes, and there is nothing to measure before doing them.
		# The size law takes the distance to the CENTRE, because it subtracts the radius itself.
		var texture := _cloud_maps.map(
			body.id, deck.index, body.radius, deck.coverage, distance, deck.morphology,
			deck.optical_depth
		)
		var width := _cloud_maps.width_of(body.id, deck.index)
		if width == deck.published_width:
			continue
		deck.published_width = width
		if texture == null or width <= 0:
			# **A `FEATURELESS` body has no map to threshold**, so its coverage goes in as a veil with
			# `threshold = 0` and the whole disc is cloud — the recipe's rule, and the reason a hazy world
			# reads as a shroud rather than as an absent deck.
			var veil := SpacesimBodyRenderer.cloud_gain(deck.albedo, deck.palette, 1.0)
			SpacesimBodyRenderer.apply_cloud_map(
				deck.material, SpacesimBodyRenderer.white_texel(), 0, 0.0, veil.value, deck.coverage,
				_deck_tau_full(body, deck)
			)
			# **A uniform veil casts a uniform shadow**: a one-texel white map with `threshold = 0` is a single
			# thickness everywhere, which is what a deck the model calls FEATURELESS actually is.
			if deck == shadowing:
				_publish_deck_shadow(body, deck, SpacesimBodyRenderer.white_texel(), 0.0, 0)
			continue
		# **One mean for every layer**: the gain is fitted to the mean of what the deck actually draws, `R(tau)`.
		# There used to be two paths — a tau layer fitted to its mean opacity and a ramp layer to its mean
		# thickness — and two laws for one quantity is how the top ended up opaque while the base transmitted.
		var mean := _cloud_maps.opacity_mean_of(body.id, deck.index)
		var gain := SpacesimBodyRenderer.cloud_gain(deck.albedo, deck.palette, mean)
		var threshold := _cloud_maps.threshold_of(body.id, deck.index)
		SpacesimBodyRenderer.apply_cloud_map(
			deck.material, texture, width, threshold, gain.value, 1.0, _deck_tau_full(body, deck)
		)
		if deck == shadowing:
			_publish_deck_shadow(body, deck, texture, threshold, width)


## **The deck nearest the ground is the one that shadows it** — the LOWEST layer, not the highest.
##
## Evert, 2026-10-20: *"only the lowest deck should be casting shadows… the deck closest to the planet will
## have the sharpest defined shadows."* A star is not a point: it subtends an angle, so a shadow's edge is a
## penumbra that widens with the distance between the casting layer and the ground. The lever arm is
## `height · tan(zenith)`, so a deck a few kilometres up smears every edge by a few kilometres while the deck
## just overhead barely smears it at all. On Earth, with one deck, this changes nothing; it is the multi-deck
## case it is written for.
##
## **Chosen by radius rather than by position in the stack**, because the rule is "closest to the planet" and
## saying that directly cannot drift from how the stack happens to be ordered.
func _shadowing_deck(body: SpacesimSceneBody) -> SpacesimSceneBody.Deck:
	var lowest: SpacesimSceneBody.Deck = null
	var lowest_top := INF
	for deck in body.decks:
		var top := deck.height + deck.thickness
		if top < lowest_top:
			lowest_top = top
			lowest = deck
	return lowest


## **One shadow, from the deck nearest the ground**, and it goes to the land and the sea together — a shadow
## that reached one and not the other would put a line down every coastline, the same failure the sea level
## already taught.
##
## The lever arm is the deck's **top** above the surface: a shadow's offset is `height · tan(zenith)`, and
## using the base would put every shadow a slab's thickness too close to its cloud.
func _publish_deck_shadow(
	body: SpacesimSceneBody, deck: SpacesimSceneBody.Deck, texture: Texture2D, threshold: float,
	width: int
) -> void:
	# **The deck's own ladder numbers, passed rather than read back off its material** — `detail_feature` is
	# two texels of the map in hand, so a refinement moves it, and the shadow has to move with it or it would
	# be a different cloud from the one casting it.
	var feature := TAU * 2.0 / float(width) if width > 0 else 0.0
	for material in [body.mesh_material, body.ocean_material]:
		SpacesimBodyRenderer.apply_deck_shadow(
			material, texture, threshold, deck.shadow_tau, deck.height + deck.thickness,
			SpacesimCloudField.seed_for(body.id, deck.index), feature
		)


## **What a body's material should be sampling this frame** — the refining map when the eye is close enough to
## want more than the build map has. Called from `update_lod` for every drawn body.
func _refine_surface_map(
	body: SpacesimSceneBody, distance: float, pixel: float, cap: int, delta: float
) -> void:
	if body.mesh_material == null or body.content == null:
		return
	if body.content.kind == SpacesimSystemBody.Kind.STAR:
		return
	# **Watching is per frame; deciding is not; publishing is on arrival.** The rate is maintained every frame because
	# it is a frame quantity, and it asks for nothing. A decision — which is the only thing that can request a bake —
	# happens when the gate opens or when a rung has landed, and publishing happens when there is something new to
	# draw. Evert, 2026-10-19: *"watching a number increase or decrease per frame is not the same as baking."*
	var entry := _surface_maps.map(body.id)
	if entry == null:
		return
	_surface_maps.observe_eye(body.id, distance, delta)
	if SpacesimSurfaceMaps.map_is_due(
		entry.last_distance, entry.last_pixel, entry.last_cap, distance, pixel, cap
	):
		_surface_maps.note_map_eye(body.id, body.radius, distance, pixel, cap)
	if not _surface_maps.needs_publish(body.id):
		return
	var chosen := _surface_maps.drawn_for(body.id)
	if chosen.is_empty():
		return
	_surface_maps.mark_published(body.id)
	SpacesimBodyRenderer.apply_surface_maps(
		body.mesh_material, chosen["texture"], chosen["width"],
		SpacesimSurfaceField.plan(body.id, body.radius).continent_frequency
	)
	# **Both layers, or the shore comes apart**: the land culls on this map and the sea draws on it, so a map
	# that reached one and not the other would put a seam along every coastline.
	if body.ocean_material != null:
		SpacesimBodyRenderer.apply_surface_maps(
			body.ocean_material, chosen["texture"], chosen["width"]
		)


## **The near field: the map's tiles, refined where the eye is looking**, as the mesh is.
##
## Called for every drawn body, and it is **cheap when nothing has moved**: the walk's own gate answers first, and a
## still eye costs a dictionary lookup. When the selection or a landed tile changes what a material should be told,
## the rects are republished to **both** layers — the land culls on the tiled height and the sea draws on it, so a
## table that reached one and not the other would put a seam along every coastline inside it.
func _refine_surface_tiles(
	body: SpacesimSceneBody, distance: float, pixel: float, eye_direction: Vector3, cap: int
) -> void:
	if body.mesh_material == null or body.content == null:
		return
	if body.content.kind == SpacesimSystemBody.Kind.STAR:
		return
	if not _surface_maps.update_tiles(
		body.id, body.radius, distance, pixel, eye_direction, cap
	):
		return
	var tiles := _surface_maps.tiles_for(body.id)
	var array := _surface_maps.tile_array()
	SpacesimBodyRenderer.apply_surface_tiles(
		body.mesh_material, array, tiles["rects"], tiles["layers"]
	)
	if body.ocean_material != null:
		SpacesimBodyRenderer.apply_surface_tiles(
			body.ocean_material, array, tiles["rects"], tiles["layers"]
		)


func _poll_patch_builds() -> void:
	for body in bodies:
		if body.patch_task == -1:
			continue
		if not WorkerThreadPool.is_task_completed(body.patch_task):
			continue
		WorkerThreadPool.wait_for_task_completion(body.patch_task)
		body.patch_task = -1
		var arrays := body.patch_arrays
		body.patch_arrays = []
		# **An empty selection is a real answer** — the eye inside the body, or a sphere whose whole surface
		# is over its own horizon — and it is not a reason to throw the geometry away. `add_surface_from_arrays`
		# refuses an empty surface (the rendering server logs `array_len == 0` every frame it is asked), so an
		# empty build publishes nothing and **the mesh that is already there stays**: a stale equator is worth
		# more than a frame with no ground in it, and a frame with no ground in it is what swings the exposure.
		if body.mesh == null:
			continue
		if arrays.is_empty() or (arrays[0] as PackedVector3Array).is_empty():
			continue
		body.mesh.mesh = (
			SpacesimPatches.lines_mesh_from(arrays) if body.patch_task_wireframe
			else SpacesimPatches.mesh_from(arrays)
		)
		# **The ocean draws the same triangles**, so a rebuild cannot leave the sea behind on older geometry.
		if body.ocean != null:
			body.ocean.mesh = body.mesh.mesh
		# **And every deck does too** — a stack is the same triangles at different scales, so a rebuild that
		# reached the ground and the sea but not the clouds would leave the weather on last frame's sphere.
		for deck in body.decks:
			deck.node.mesh = body.mesh.mesh
		# **A material is published only when it is a different material**, and never a null one: assigning
		# `material_override = null` silently falls back to the engine's default material, which is unshaded —
		# it reads as "the surface lost its shading", far from the line that did it.
		var wanted := (
			SpacesimBodyRenderer.wireframe_material() if body.patch_task_wireframe
			else body.mesh_material
		)
		if wanted == null:
			push_warning("PATCH: %s has no material to publish" % body.name)
		elif body.mesh.material_override != wanted:
			body.mesh.material_override = wanted
		body.patch_triangles = (
			arrays[0].size() / 6 if body.patch_task_wireframe
			else arrays[0].size() / 3
		)
		# The selection moved while this was building, so the answer is already out of date.
		if body.patch_task_chunks != body.patch_chunks:
			_request_patch_build(body, body.patch_walk_wireframe)


## **Join every rebuild in flight**, for a rig that has to know the mesh exists before it looks.
##
## Part of the feature rather than a test helper: a body draws nothing until its first build lands, so
## anything reading a mesh has to be able to wait for it. Polls between rounds because a publish can start
## the next build.
func await_patch_builds(rounds: int = 8) -> void:
	for _round in rounds:
		var waiting := false
		for body in bodies:
			while body.patch_task != -1 and not WorkerThreadPool.is_task_completed(body.patch_task):
				OS.delay_usec(100)
			if body.patch_task != -1:
				waiting = true
		_poll_patch_builds()
		_triangles = _count_drawn_triangles()
		if not waiting:
			return


## Size and colour a body's point of light.
##
## **Sized to the disc, floored at one pixel** — not pinned at one pixel — so a body is one continuous
## object from a distant dot, through a two-pixel disc, to the handover to a mesh. Below a pixel it
## cannot shrink further, which is what stops a receding body flickering out.
##
## The colour is the body's mean radiance in the engine's units, **tinted by the body's own colour**.
## **No exposure is applied here**: `SpacesimExposurePass` scales the finished frame, which covers this and
## every disc together, by construction. It used to be applied by hand because an `unshaded` material
## receives none of Godot's per-path baking — the flight test that found that is in
## `Lighting and Exposure`.
##
## **Still missing, and named rather than hidden:** §5 of the plan has the splat carry the body's whole
## flux into one pixel — `L * omega_disc / omega_px` — which for a disc under the floor falls as `1/d^2`,
## because a point source on a fixed pixel gets fainter and that is the correct behaviour. This carries
## `L` alone, so its value does not fall with the observer's distance once the disc is under the floor: a
## body at 0.077 px is about 170x brighter than the law says. Not applied yet because it makes distant
## bodies *dimmer* and the flight test says they are already too dim, so the splat's absolute level has
## to be settled first. Two renders — one body at 0.8 px and the same body at 0.4 px — would measure it.
func _place_point(
	body: SpacesimSceneBody, observer: Vector3, angular: float, distance: float, pixel: float,
	screen: float, camera: Camera3D
) -> void:
	# **The quad is oriented here rather than by the material, and that is deliberate** — a billboarded
	# material rewrites `MODELVIEW_MATRIX` with `INV_VIEW_MATRIX`, which is the transform chain the
	# double-precision emulation cannot follow. See `SpacesimBodyRenderer.point_material`. Copying the
	# camera's basis onto the node *is* a billboard, in a place the emulation can see: the quad's +Z then
	# points back at the eye, and its own scale sizes it, so nothing has to be kept by hand.
	var size := 2.0 * distance * tan(maxf(pixel, angular))
	body.point.global_transform = Transform3D(
		camera.get_global_transform_interpolated().basis.scaled(Vector3.ONE * size), body.node.global_position
	)
	var material := body.point.material_override as StandardMaterial3D
	if material == null:
		return
	var star_body := star()
	if star_body == null or star_body.node == null:
		return
	# **Its WHOLE FLUX into one pixel, once the disc is smaller than one.** Below the floor the body's
	# flux falls as `1/d^2` while its pixel does not grow, so what is drawn is the radiance times the
	# disc's share of the pixel's solid angle — `omega_disc / omega_px = pi * r_px^2` — capped at 1 once
	# the splat covers the disc, which it does from about 0.56 px of radius. This is the same term the
	# star field carries as `lux / d_omega`, and it is what makes a distant body *faint* rather than a
	# full-brightness dot: without it a body at 0.077 px is some 170x brighter than the law says.
	var fade := minf(1.0, PI * screen * screen)
	var radiance := body_luminance(body, observer, star_body.node.global_position) * fade
	# **No exposure here.** This used to be the one place in the 3D pass that applied the camera's exposure
	# by hand, because an `unshaded` material receives none of Godot's per-path baking and a splat is the
	# only such thing that is not the star's own disc. `SpacesimExposurePass` scales the *finished frame*
	# now, which covers this and the disc together and by construction — applying it here as well would be
	# a second application, and the two together are why the splat's brightness used to need reconciling
	# against everything else.
	material.albedo_color = SpacesimBodyRenderer.point_colour(body, radiance)


## **What the eye sees of a body**, in lux/sr: the light falling on it, the fraction it reflects, and the
## disc-averaged lit fraction.
##
##     L = illuminance_at_body * albedo * lambert_phase(phase) / pi
##
## **One expression, and one consumer** — the point of light a body becomes when it is too small to be a
## disc. It was the exposure's sum too, until the pass began metering the frame; with that gone it is the
## statement of what a body is worth at a distance, and the splat is what draws it.
func body_luminance(body: SpacesimSceneBody, observer: Vector3, star_position: Vector3) -> float:
	if body.content == null or body.node == null or star_light == null:
		return 0.0
	var to_body := body.node.global_position - observer
	if to_body.length_squared() <= 0.0:
		return 0.0
	var to_body_star := star_position - body.node.global_position
	if to_body_star.length_squared() <= 0.0:
		return 0.0
	# The phase, the albedo and the light are gathered here; the expression itself is
	# `SpacesimLuminance.disc_luminance`, because the exposure and the point of light must be **the same
	# number** and a second copy of the arithmetic is how they would drift.
	var phase := SpacesimLuminance.phase_angle(body.node.global_position, observer, star_position)
	var albedo := SpacesimSurfaceModel.bond_albedo(body.content, _materials())
	return SpacesimLuminance.disc_luminance(
		star_light.lux_at(to_body_star.length()), albedo, phase
	)


## Triangles the bodies are currently drawn with, summed over the patches in use.
func triangles() -> int:
	return _triangles


## Meter-scale references at the landing zone, so the scale is legible once you are down.
func _add_landing_site(surface: SpacesimFrame) -> void:
	var pad_size := _framing.pad_size

	var plane := PlaneMesh.new()
	plane.size = Vector2(pad_size, pad_size)
	var pad_material := StandardMaterial3D.new()
	pad_material.albedo_color = Color(0.18, 0.2, 0.24)

	var pad := MeshInstance3D.new()
	pad.name = "LandingPad"
	pad.mesh = plane
	pad.material_override = pad_material
	# A hair above the surface plane: the pad is coplanar with the planet's sphere otherwise,
	# and coplanar geometry z-fights.
	pad.position = Vector3(0.0, 0.5, 0.0)
	surface.add_child(pad)

	var marker_material := StandardMaterial3D.new()
	marker_material.albedo_color = Color(0.85, 0.6, 0.15)
	for i in 5:
		var box := BoxMesh.new()
		box.size = Vector3(20.0, 40.0, 20.0)
		var marker := MeshInstance3D.new()
		marker.name = "Marker%d" % i
		marker.mesh = box
		marker.material_override = marker_material
		var angle := TAU * float(i) / 5.0
		marker.position = Vector3(cos(angle) * 600.0, 20.5, sin(angle) * 600.0)
		surface.add_child(marker)


## How a system frame reads: "landed on Nix", "above Nix". Empty for a frame this system does not
## have — and empty for open space, which reads by what is nearby instead.
func frame_phrase(frame_id: String) -> String:
	var parts := frame_id.split("/", false)
	if parts.size() != 2:
		return ""
	var body := body_by_id(parts[0])
	if body == null:
		return ""
	match parts[1]:
		"surface":
			return "landed on %s" % body.name
		"atmosphere":
			return "above %s" % body.name
	return ""


func nearest_body_name(position: Vector3) -> String:
	var body := Proximity.nearest_body(position, scale_bodies())
	return body.node.name if body != null and body.node != null else ""


## How a location reads to a player: "in space, near Terra", "landed on Nix", "in Base Foo, landed
## on Bar". No coordinate numbers — see `Save and Load Plan` §3.
##
## Containment is frame membership, so this walks outward: an asset frame recurses into where that
## asset is, and a system frame reads from its own id. **The whole chain is named, innermost first** —
## being in a vehicle is worth saying, because it is where the player left it.
func describe(location: SpacesimLocation, assets: Array) -> String:
	if location == null or not location.is_set():
		return "somewhere"

	if location.frame_id.begins_with(ASSET_FRAME_PREFIX):
		var asset := _asset_at(assets, location.frame_id)
		if asset.is_empty():
			return "somewhere"
		var inner := describe(SpacesimLocation.from_dictionary(asset.get("location", {})), assets)
		return "in %s, %s" % [String(asset.get("name", "?")), inner]

	if location.frame_id == Frame.SYSTEM_ID:
		var near := nearest_body_name(location.position)
		return "in space, near %s" % near if not near.is_empty() else "in space"

	var phrase := frame_phrase(location.frame_id)
	return phrase if not phrase.is_empty() else "somewhere"


static func _asset_at(assets: Array, frame_id: String) -> Dictionary:
	var parts := frame_id.split("/", false)
	if parts.is_empty():
		return {}
	var id := parts[0].substr(ASSET_FRAME_PREFIX.length())
	for asset in assets:
		if String(asset.get("id", "")) == id:
			return asset
	return {}
