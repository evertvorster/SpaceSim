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

## The icosphere level a body gets before anything has asked how big it is. A scene is built before it
## has a camera, and `update_lod` corrects this on the first **drawn** frame — `_update_view` runs
## before anything is rendered, so no wrong level is ever seen in the game. It exists so a scene built
## without a game is not a spray of 20-triangle spheres.
const INITIAL_MESH_LEVEL := 2

## How much larger an air shell's error budget is than a body's.
##
## **An atmosphere is soft** (Evert, 2026-10-15): its outer edge is where the density reaches nothing, so
## there is no hard line for a facet to break, and a silhouette error several times a planet's is not
## visible on one. The shell therefore uses the same law with a looser budget rather than a different
## mechanism — and the budget still follows the trim, so one number keeps governing both.
##
## **Suspected at 4, not measured.** The way to judge it is to fly out from a body and watch where its
## limb ring starts to read as a polygon; the ring is the only hard-ish edge the shell has.
const SHELL_BUDGET_SOFTNESS := 4.0

## The screen thickness, in pixels, at which an air shell's **limb ring** is too thin to be worth
## drawing.
##
## A shell is a fill-bound shader — 128 samples per pixel it covers, the heaviest thing here — so its
## LOD is *draw or not draw*, and the only question worth asking is whether it puts anything on the
## screen. From outside, what it puts there is the ring between `radius` and `radius + sky_top`; below a
## pixel of thickness that is a smear across one pixel rather than a ring, and it is bought with the
## whole march. Earth's ring comes to 4.9 px at 19,000 km, 319 px at 400 km, and **0.05 px at 750 Mm**,
## so the planet's own limb stops being drawn somewhere around 77,000 km — where its disc is 13 px and a
## 0.2 px ring around it was never going to be seen.
##
## **Suspected at one pixel, not measured**, like the point tier's 4. It wants looking at in flight: the
## trade it makes is a sub-pixel limb tint for the march, so the way to judge it is to fly out from a
## body and watch where its ring stops reading.
const ATMOSPHERE_RING_MIN_PIXELS := 1.0

## The screen radius below which a body **stops being geometry and becomes a point of light**.
##
## Below a few pixels a shaded disc and a flat blob are indistinguishable, so a mesh buys nothing — and a
## mesh *smaller than a pixel* aliases badly, appearing and disappearing as it crosses pixel centres.
## **Four is a suspected number, not a measured one**: it is the value the mesh LOD plan's §3 proposes,
## and it wants looking at in flight the way `lod.error_budget` did. Unlike the error budget it is not a
## setting, because it is not a quality trim — it is where one representation gives way to another, and
## a player who moved it would be moving a boundary rather than a budget.
const POINT_TIER_SCREEN_RADIUS := 4.0

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
	scene._epoch_time = clock_at_epoch(content.epoch)
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


## World-clock seconds for an ISO 8601 epoch, on the same calendar [method format_time] reads. The
## clock counts from year zero, so J2000 is a large positive number rather than a special case.
static func clock_at_epoch(iso: String) -> float:
	if iso.is_empty():
		return 0.0
	return float(Time.get_unix_time_from_datetime_string(iso)) - EPOCH_AT_YEAR_ZERO


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

	frame_tree.frame_changed.connect(_on_frame_changed)
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


## Every mesh in the system, so a debug key can hide or re-tessellate all of it. The cloud decks are
## included: hiding the bodies but leaving their clouds behind would look like a bug.
func meshes() -> Array[MeshInstance3D]:
	var list: Array[MeshInstance3D] = []
	for body in bodies:
		if body.mesh != null:
			list.append(body.mesh)
		if body.atmosphere_mesh != null:
			list.append(body.atmosphere_mesh)
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


## The illuminance at a position, in lux: the light falling on a surface there.
##
## **This is not what the camera exposes for.** Adaptation follows what the eye is *looking at*, which
## is `view_luminance_at()` — and the two are genuinely different quantities (an irradiance versus a
## luminance), which was a real bug when they were conflated. This one is used for the one-time
## `snap_to()` at startup and for the atmosphere's own inputs.
func illuminance_at(position: Vector3) -> float:
	if star_light == null:
		return 0.0
	var star_body := star()
	var origin := Vector3.ZERO
	if star_body != null and star_body.node != null:
		origin = star_body.node.global_position
	return star_light.lux_at(position.distance_to(origin))


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
	# **The body's own shell top**, not the framing's altitude: a giant's air is worth drawing far
	# higher than 100 km, and the far plane has to reach wherever the shell actually ends.
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

	body.mesh_level = INITIAL_MESH_LEVEL
	body.mesh = _add_body_mesh(
		body.node, body.radius, SpacesimBodyRenderer.material_for(body), "%sSurface" % body.name,
		body.mesh_level
	)
	body.point = _add_point(body.node, body.name)
	body.scale_body = ScaleBody.new(body.node, body.radius)
	_add_atmosphere_shell(body)

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


## The air, on a sphere whose outer bound is where the atmosphere is declared to end.
##
## **The shell is the sky and the limb at once.** Only its far surface is shaded, so from inside it is
## the sky dome and from outside it is the ring around the planet — see `body_atmosphere.gdshader`,
## which is where that is explained. Nothing here hides it: distance and the depth buffer decide.
func _add_atmosphere_shell(body: SpacesimSceneBody) -> void:
	if body.content == null or body.content.atmosphere == null:
		return
	# The coefficients are evaluated at the body's equilibrium temperature, which is §3.6's first row
	# and the only temperature there is. Named in SpacesimAtmosphereModel, not guessed here.
	var luminosity := 0.0
	var distance := 0.0
	var star_body := star()
	if star_body != null and star_body.content != null:
		luminosity = SpacesimStarModel.luminosity(star_body.content)
		distance = body.position.distance_to(star_body.position)
	var temperature := SpacesimAtmosphereModel.reference_temperature(
		body.content, _materials(), luminosity, distance
	)
	# **The shell's top is derived, and floored by the frame's transition altitude.** Derived because
	# it is a property of the air -- `SHELL_SCALE_HEIGHTS` scale heights of it -- and one authored
	# altitude for the whole system is right for exactly one body: 100 km is twelve scale heights over
	# Earth and four over Jupiter, where the air is still 2% of surface density at the top. Floored
	# because the atmosphere frame begins at `frames.atmosphere_altitude`: a shorter shell would leave
	# a band where the player is *in the atmosphere* with no sky to draw.
	var shell_reach := SpacesimAtmosphereModel.shell_reach(
		body.content.atmosphere, _materials(), temperature,
		SpacesimAtmosphereModel.surface_gravity(body.content)
	)
	body.sky_top = maxf(shell_reach, _framing.atmosphere_altitude)
	body.shell_level = INITIAL_MESH_LEVEL
	var material := SpacesimBodyRenderer.atmosphere_material(
		body, _materials(), body.sky_top, temperature,
		SpacesimStarLight.illuminance(luminosity, distance)
	)
	if material == null:
		return
	body.atmosphere_mesh = _add_body_mesh(
		body.node, body.radius + body.sky_top, material, "%sAir" % body.name, body.shell_level
	)


## Point every atmosphere at the observer and at its star.
##
## **Both are handed over as offsets, not positions.** Our bodies sit at ~1.5e11 m and a GLSL float
## has ~7 significant digits, so a world coordinate would arrive with ~16 km of resolution — against
## an air 100 km deep. Computed here in double precision, the difference is ~6.4e6 m and arrives with
## sub-metre resolution.
## Point the sky at the camera and set how deep it is drawn.
##
## Called once a frame, like `update_atmospheres()`: the sky follows the **camera**, not the ship,
## because it is the eye that sees it and nothing about it depends on which body the player is
## attached to. The depth is read from settings every frame rather than cached, so it is hot by
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


## **What the eye is looking at**, as a mean luminance over the view — which is what the exposure must
## follow, and is emphatically NOT the light falling on a surface where the observer is.
##
## `illuminance_at()` answers "how brightly is a surface here lit", and at 1 au the answer is 128,000
## lux whether you are looking at the Sun or at empty sky. That is an **irradiance**: a property of
## where you *are*. Adaptation follows a **luminance**: a property of what you are *looking at*. Two
## faults Evert reported are the same mistake made in two directions — looking at Sol from Saturn's
## distance faded the whole sky 122x, and flying close to Saturn was blown out because a planet
## filling the frame contributed nothing at all.
##
## So this integrates what is actually in front of the eye, as radiance weighted by each source's share
## of the view:
##
## | looking at | share of the view | what it does |
## |---|---|---|
## | Sol at 1 au | 6.8e-5 sr, five times the eye's pooling scale | a sky you adapt to — the stars go |
## | Sol at Saturn | 7.4e-7 sr, ten times *smaller* | a glare source and no more — the sky is left alone |
## | a planet up close | large | stops the exposure down hard |
## | a lit sky, from inside | fills the view | stops it down |
## | empty sky | nothing extended at all | 0.0, which the caller reads as dark-adapted |
##
## **Nothing here counts a source that is behind something.** `SpacesimLuminance.in_view` asks whether a source is in
## the frame, and on a planet's night side the Sun is in the frame *through the planet*: it is 180
## degrees from the local zenith, and a fraction of a degree from the direction the camera points when
## the player looks down at the ground. Measured, that counted: the exposure stopped down 75,000x for
## a Sun that could not be seen, and took the whole sky with it for as long as the adaptation takes to
## come back. `_occluded` is that fix, and it applies to every body as well as to the star.
##
## **`MIN_SOLID_ANGLE` is the whole of the fix**, and `SpacesimExposure` carries the reasoning: a source
## below the eye's 0.2 degree pooling scale cannot be resolved as a surface, so it has no surface
## brightness to adapt to. `tan_half` is the field's tangent half-extents, the same pair the sky
## shader is given.
func view_luminance_at(observer: Vector3, forward: Vector3, tan_half: Vector2) -> float:
	var star_body := star()
	if star_body == null or star_body.node == null or star_light == null:
		return 0.0
	var star_position := star_body.node.global_position

	# The view's own solid angle, and the cone a source has to be inside. **Both are arithmetic in
	# `SpacesimLuminance`** — the shape `SpacesimLod` established: the maths is pure and testable on its
	# own, and what stays here is the policy (which bodies count, and what can occlude what).
	var view_omega := SpacesimLuminance.pyramid_solid_angle(tan_half)
	if view_omega <= 0.0:
		return 0.0
	var half_diagonal := SpacesimLuminance.half_diagonal(tan_half)

	var total := 0.0

	# --- the star -------------------------------------------------------------------------------
	# Its surface radiance is its illuminance over its own solid angle, so its share of the view comes
	# to `illuminance / view_omega` — the disc's own solid angle cancels. Which is exactly why the
	# eye's pooling scale has to be applied first: without it the Sun's *radiance* dominates everything
	# at every distance, because radiance does not fall off with distance even though its area does.
	var to_star := star_position - observer
	var star_distance := to_star.length()
	if star_distance > star_body.radius:
		var star_angle := SpacesimLod.angular_radius(star_body.radius, star_distance)
		var star_omega := SpacesimLuminance.cone_solid_angle(star_angle)
		if star_omega >= SpacesimExposure.MIN_SOLID_ANGLE \
				and SpacesimLuminance.in_view(
					forward, to_star / star_distance, half_diagonal, star_angle
				) \
				and not _occluded(observer, star_position, star_body):
			total += star_light.lux_at(star_distance) / view_omega

	# --- every lit body in the view --------------------------------------------------------------
	# A body's luminance is its albedo times the light falling on it over pi, weighted by how much of it
	# is lit. Its share of the view is what makes "close" mean something: the same body a million
	# kilometres away changes nothing, and filling half the frame changes everything.
	for body in bodies:
		if body.node == null or body == star_body:
			continue
		var to_body := body.node.global_position - observer
		var distance := to_body.length()
		if distance <= body.radius:
			continue
		var body_angle := SpacesimLod.angular_radius(body.radius, distance)
		var body_omega := SpacesimLuminance.cone_solid_angle(body_angle)
		if body_omega < SpacesimExposure.MIN_SOLID_ANGLE:
			continue
		if not SpacesimLuminance.in_view(forward, to_body / distance, half_diagonal, body_angle):
			continue
		if _occluded(observer, body.node.global_position, body):
			continue
		var luminance := body_luminance(body, observer, star_position)
		if luminance <= 0.0:
			continue
		total += luminance * minf(body_omega / view_omega, 1.0)

	# --- a lit sky, from inside it -----------------------------------------------------------------
	# It fills the view, so its share is 1 and no solid angle is needed. Answered regardless of which way
	# the camera points, because inside a lit atmosphere there is a bright sky in every direction.
	var active := frame_tree.active_frame
	var air: SpacesimSceneBody = air_body(active) if active != null else null
	if air != null and air.node != null:
		var up := observer - air.node.global_position
		var to_star_from_body := star_position - air.node.global_position
		if up.length() > 0.0 and to_star_from_body.length() > 0.0 \
				and up.normalized().dot(to_star_from_body.normalized()) > 0.0:
			total += SpacesimExposure.DAYLIGHT_SKY_LUMINANCE

	return total


## **Whether a body is standing in front of the source.** The test itself is
## `SpacesimLuminance.occluded`; **what stays here is the policy** — which bodies may occlude, which is
## every body with a node except the source being looked at, since a body cannot occlude itself.
func _occluded(observer: Vector3, target: Vector3, source: SpacesimSceneBody) -> bool:
	for body in bodies:
		if body.node == null or body == source:
			continue
		if SpacesimLuminance.occluded(observer, target, body.node.global_position, body.radius):
			return true
	return false


## Point every atmosphere at the observer and at its star.
##
## **Both are handed over as offsets, not positions.** Our bodies sit at ~1.5e11 m and a GLSL float
## has ~7 significant digits, so a world coordinate would arrive with ~16 km of resolution — against
## an air 100 km deep. Computed here in double precision, the difference is ~6.4e6 m and arrives with
## sub-metre resolution.
func update_atmospheres(observer: Vector3) -> void:
	var star_body := star()
	if star_body == null or star_body.node == null:
		return
	for body in bodies:
		if body.atmosphere_mesh == null or body.node == null:
			continue
		var material := body.atmosphere_mesh.material_override as ShaderMaterial
		if material == null:
			continue
		material.set_shader_parameter("eye_offset", observer - body.node.global_position)
		material.set_shader_parameter(
			"sun_direction", (star_body.node.global_position - body.node.global_position).normalized()
		)


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
## **The level is a mesh assignment.** Levels are built once and shared, so a body crossing a boundary
## points at a different `ArrayMesh`; nothing is regenerated. Hysteresis holds a body that is sitting on
## a boundary still, because discrete levels changing on a continuous input is a flicker otherwise.
##
## **And a body too small to be a disc stops being geometry at all**: its mesh and its air shell go, and
## its point of light appears in their place. The two representations agree in brightness by
## construction, because the splat's colour and the exposure's sum are the *same expression* —
## `body_luminance` — so the handoff needs no cross-fade and no dead band. A body that stops being drawn
## is still lit by, still marked, and still an effect on everything else: this reads `bodies`, and so
## does `view_luminance_at`.
##
## **No body is exempt, the star included.** A star's disc is a fraction of a pixel from any distance,
## so it spends almost all of its time as a point of light — and that is right: what it puts on the
## screen is its own emission, over the same area, so its glare survives the handoff exactly as a
## planet's brightness does. See `SpacesimBodyRenderer.point_colour` for the one by-kind difference
## that remains, which is that a star **emits** and everything else reflects.
func update_lod(camera: Camera3D) -> void:
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
	# **The interpolated eye**, because this runs once a drawn frame and `get_global_transform()` is
	# only accurate to the most recent physics tick. It is the same transform the camera is drawn with,
	# so the level chosen belongs to the frame on screen — see `game/main.gd::_update_view`.
	#
	# Typed explicitly: `get_global_transform_interpolated()` has no inferable return type, so `:=`
	# here is the `INFERENCE_ON_VARIANT` error, and everything derived from the result with it.
	var observer: Vector3 = camera.get_global_transform_interpolated().origin
	# **The exposure, read off the camera the frame is being drawn with.** This is the same object
	# `SpacesimExposure` mutates, so there is no second source for it and nothing to keep in step — but
	# Godot applies it per *path* rather than to the frame, so an unshaded material has to apply it
	# itself. See `_place_point`.
	var exposure := 1.0
	if camera.attributes != null:
		exposure = camera.attributes.exposure_multiplier
	var total := 0
	for body in bodies:
		if body.node == null:
			continue
		var distance := observer.distance_to(body.node.global_position)
		var energy := SpacesimLod.angular_radius(body.radius, distance)
		var screen := SpacesimLod.screen_radius_pixels(energy, pixel)
		var is_point: bool = screen < POINT_TIER_SCREEN_RADIUS
		if body.mesh != null:
			body.mesh.visible = not is_point
		# **The air shell is a visibility question, not a tier.** Its limb ring is what it contributes from
		# outside, and below a pixel of thickness there is nothing to see — which is also why a point-tier
		# body's shell is not drawn, without this having to know about the point tier.
		if body.atmosphere_mesh != null:
			body.atmosphere_mesh.visible = _shell_is_visible(body, observer, pixel)
		if body.point != null:
			body.point.visible = is_point
		if is_point:
			_place_point(body, observer, energy, distance, pixel, screen, exposure, camera)
			total += SpacesimBodyRenderer.POINT_TRIANGLES
			# A point still has a shell to price — an air so thin it is not drawn costs nothing, and one
			# whose ring survives does, which is rare but real at a body just under the tier.
			if body.atmosphere_mesh != null and body.atmosphere_mesh.visible:
				total += SpacesimLod.triangles_at(body.shell_level)
			continue
		if body.mesh == null:
			continue
		var level := SpacesimLod.level_with_hysteresis(body.mesh_level, screen, epsilon)
		if level != body.mesh_level:
			body.mesh_level = level
			body.mesh.mesh = SpacesimIcosphere.mesh_at(level)
		# Counted from the law rather than from the meshes: `face_count` walks `get_faces()`, which
		# allocates, and this runs once a frame for every body in the system.
		total += SpacesimLod.triangles_at(body.mesh_level)
		# **The shell is judged on its own metric and its own looser budget.** Its edge is soft, and from
		# inside it there is no edge at all — see `_shell_screen_radius`. It keeps its own level and its
		# own hysteresis for that reason, rather than borrowing the body's.
		if body.atmosphere_mesh != null:
			var shell_screen := _shell_screen_radius(body, distance, pixel)
			var shell_level := SpacesimLod.level_with_hysteresis(
				body.shell_level, shell_screen, epsilon * SHELL_BUDGET_SOFTNESS
			)
			if shell_level != body.shell_level:
				body.shell_level = shell_level
				body.atmosphere_mesh.mesh = SpacesimIcosphere.mesh_at(shell_level)
			if body.atmosphere_mesh.visible:
				total += SpacesimLod.triangles_at(body.shell_level)
	_triangles = total


## The screen radius an air shell's tessellation should be judged at.
##
## **From outside** the shell's visible edge is its outer limb, so it is the ordinary silhouette:
## `tan(asin(R/d)) / p` at `radius + sky_top`, where the ring ends.
##
## **From inside there is no edge at all** — the whole frame is the shell — and what tessellation moves is
## not a boundary but the *direction of every ray the shader casts*: `body_atmosphere` takes
## `normalize(VERTEX)`, the interpolated position on the triangle, as its ray, so a facet's deviation of
## `s` radians tilts every ray by that much and moves where the air meets the ground by it too. `s`
## radians is `s / p` pixels **anywhere on screen**, so the honest screen radius for it is `1 / p` — a
## radian's worth of pixels.
##
## This is what keeps the sky dome off the maximum level. Without it an observer inside the shell has
## `radius / d > 1`, which `angular_radius` clamps, and the law reads the clamp as a body filling the
## frame and asks for the finest level there is — 81,920 triangles for a dome whose error is a direction,
## not an edge.
func _shell_screen_radius(body: SpacesimSceneBody, distance: float, pixel: float) -> float:
	if distance < body.radius + body.sky_top:
		return 1.0 / pixel
	return SpacesimLod.screen_radius_pixels(
		SpacesimLod.angular_radius(body.radius + body.sky_top, distance), pixel
	)


## Whether a body's air shell can be seen at all from here.
##
## **A fill-bound shader's LOD is draw-or-not, not resolution.** The shell's cost is per *pixel* it
## covers and tessellation barely moves it, so the only question is whether it puts anything on the
## screen. This also answers the open question in `Atmospheres` §10 — *one shell per body, or only the
## nearest?* — with visibility rather than a budget: culling to the active frame's body would take the
## limb ring off every *other* body, and §10 already settled that the ring seen from outside is wanted
## (*"atmospheres were not being drawn when I was outside them, now they are"*).
##
## From **inside** the shell it is the sky, and the answer is always yes. From outside, what the shell
## contributes is the **limb ring** between `radius` and `radius + sky_top`, so the question is whether
## that annulus is thick enough to read as a ring — measured exactly, the way every other screen size
## here is, by projecting both radii and subtracting.
##
## **An observer inside the shell needs no branch**: `radius + sky_top` over the distance exceeds 1, so
## `angular_radius` clamps, the outer radius projects to the horizon, and the "ring" spans the screen —
## the same test answers yes on its own. `tests/test_lod.gd` checks that from both sides rather than
## trusting it.
func _shell_is_visible(body: SpacesimSceneBody, observer: Vector3, pixel: float) -> bool:
	if body.atmosphere_mesh == null or body.node == null or body.sky_top <= 0.0:
		return false
	var distance := observer.distance_to(body.node.global_position)
	var outer := SpacesimLod.screen_radius_pixels(
		SpacesimLod.angular_radius(body.radius + body.sky_top, distance), pixel
	)
	var inner := SpacesimLod.screen_radius_pixels(
		SpacesimLod.angular_radius(body.radius, distance), pixel
	)
	return outer - inner >= ATMOSPHERE_RING_MIN_PIXELS


## Size and colour a body's point of light.
##
## **Sized to the disc, floored at one pixel** — not pinned at one pixel — so a body is one continuous
## object from a distant dot, through a two-pixel disc, to the handover to a mesh. Below a pixel it
## cannot shrink further, which is what stops a receding body flickering out.
##
## The colour is the body's mean radiance in the engine's units, **tinted by the body's own colour** and
## **multiplied by the exposure itself** — see below for why it has to be.
##
## **The exposure has to be applied here by hand, and that is Godot's doing rather than a choice.**
## Godot does not scale the frame by the camera's exposure; it *bakes* the factor into specific paths:
##
##   * the **sky**, which is why the star field responds to the EV (`sky.glsl` says so in as many words
##     — *"we also bake in the exposure value for the environment and camera"*);
##   * the **light energy**, `light_data.energy *= exposure_normalization_factor` — which is why every
##     lit surface responds, and which phase 1a measured as a planet view going 86.7 to 52.5;
##   * and the **tonemap** uses the *Environment's* `tonemap_exposure` — which this project never sets,
##     so it is 1.0.
##
## So a material that is **`unshaded`** — no light, no sky — receives **no exposure at all**, and this is
## the only such material in the 3D pass that is not the star's own disc. Found by flight test: flying
## toward Venus with Sol entering and leaving the frame stepped the whole sky up and down and left the
## splat at exactly the same brightness (Evert, 2026-10-15). The handoff at the mesh threshold had looked
## free because it was measured at a multiplier of about 1, where the two agree either way.
##
## **The engine's factor is `exposure_multiplier * exposure_normalization`, and only the first is readable**
## from GDScript. The second is a constant here — the physical camera's aperture and shutter are left at
## their defaults and nothing changes them — so this gets the *variation* exactly right, which is what the
## flight test is about, and what remains is a constant. That constant belongs with the splat's absolute
## brightness rather than with its response to the EV, and it is one of the reasons that level is still an
## open question.
##
## **A star's point is deliberately NOT scaled, because its disc is not either.** `body_star.gdshader` is
## `unshaded` too, so the Sun's own disc receives no exposure — for the same reason, and over the same
## range of EVs. Scaling only the splat would break the very handoff this file works to keep free, so the
## two are left consistent and the fact is recorded here instead. It is invisible while the star's emission
## is 24x and clips whatever the exposure does; it would stop being invisible if the exposure ever
## stopped the Sun out of the white point, and that belongs with the star's glare and bloom.
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
	screen: float, exposure: float, camera: Camera3D
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
	material.albedo_color = SpacesimBodyRenderer.point_colour(body, radiance * exposure)


## **What the eye sees of a body**, in lux/sr: the light falling on it, the fraction it reflects, and the
## disc-averaged lit fraction.
##
##     L = illuminance_at_body * albedo * lambert_phase(phase) / pi
##
## **One expression, used by two things** — the exposure's sum in `view_luminance_at`, and the point of
## light a body becomes when it is too small to be a disc. That is what makes the handoff at the mesh
## threshold free: the splat and the disc agree in brightness there because they are the same number,
## not because two arithmetics happen to coincide.
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


## Triangles the bodies and air shells are currently drawn with, summed over the levels in use.
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


## The world clock as a **Terran** date and time — the calendar players already know, and Godot's own
## (proleptic Gregorian) date arithmetic rather than a table of months of ours. Seconds are counted
## from the world's epoch, which reads as year 0.
const EPOCH_AT_YEAR_ZERO := -62167219200 ## the unix time of 0000-01-01

func format_time(seconds: float) -> String:
	var when := Time.get_datetime_dict_from_unix_time(int(seconds) + EPOCH_AT_YEAR_ZERO)
	return "%d-%02d-%02d %02d:%02d" % [when["year"], when["month"], when["day"], when["hour"], when["minute"]]


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
