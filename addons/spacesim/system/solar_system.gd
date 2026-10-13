class_name SpacesimSolarSystem
extends RefCounted
## A solar system loaded from data, and the scene it builds.
##
## **Content, not engine.** The file says what exists — bodies, sizes, positions, colours, the
## frame conventions, where the player starts. This builds the coordinate frames, the geometry,
## the scale bodies and the transition rules from it. "playground" is a placeholder; the engine
## should not need to change when Cladogenesis content replaces it.
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
const INTERIOR_SUFFIX := "/interior"

var format_version: int
var name: String
var bodies: Array[SpacesimSystemBody] = []

## Built by build().
var container: Node3D
var system_frame: SpacesimFrame
var frame_tree: SpacesimFrameTree

var start_body_id: String
var start_altitude: float

## The world's clock at the beginning of a story that has not been played yet.
var start_time: float = 0.0

var _framing: Dictionary = {}
var _sun_light: DirectionalLight3D


static func from_file(path: String) -> SpacesimSolarSystem:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("SpacesimSolarSystem: cannot read '%s'" % path)
		return null
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("SpacesimSolarSystem: '%s' is not a JSON object" % path)
		return null
	return from_dictionary(parsed)


static func from_dictionary(data: Dictionary) -> SpacesimSolarSystem:
	var system := SpacesimSolarSystem.new()
	system.format_version = int(data.get("format_version", 0))
	system.name = String(data.get("name", "unnamed"))
	system._framing = data.get("frames", {})
	for entry in data.get("bodies", []):
		system.bodies.append(SpacesimSystemBody.from_dictionary(entry))
	var start: Dictionary = data.get("start", {})
	system.start_body_id = String(start.get("body", ""))
	system.start_altitude = float(start.get("altitude", 1.0e7))
	# A story may begin at any point in the world's time; a world with none begins at its epoch.
	system.start_time = float(start.get("world_time", 0.0))
	return system


## Build the solar system's scene under `parent`. The observer is the caller's business: set
## `frame_tree.observer` and call `enter_frame()` afterwards.
func build(parent: Node) -> SpacesimSolarSystem:
	container = Node3D.new()
	container.name = "SolarSystem"
	parent.add_child(container)

	_add_lighting()

	system_frame = Frame.new()
	system_frame.name = "System"
	system_frame.kind = Frame.Kind.SPACE
	system_frame.frame_id = Frame.SYSTEM_ID
	system_frame.travel_length_min = _band("system_band").x
	system_frame.travel_length_max = _band("system_band").y
	container.add_child(system_frame)

	frame_tree = FrameTree.new()
	frame_tree.name = "FrameTree"
	frame_tree.automatic = false # stepped explicitly, so the order with the observer's own step
	container.add_child(frame_tree)
	frame_tree.register(system_frame)

	for body in bodies:
		_build_body(body)

	frame_tree.frame_changed.connect(_on_frame_changed)
	return self


func body_by_id(id: String) -> SpacesimSystemBody:
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
func significant_nodes() -> Array[Node3D]:
	var list: Array[Node3D] = []
	for body in bodies:
		if body.significant and body.node != null:
			list.append(body.node)
	return list


func ship_start() -> Vector3:
	var body := body_by_id(start_body_id)
	if body == null:
		return Vector3.ZERO
	return body.node.global_position + Vector3(body.radius + start_altitude, 0.0, 0.0)


## Point the star's light correctly for something at `position`. A single directional light
## cannot light a whole system from a star, so it is aimed at wherever the player is: the
## planet you are at is lit from the right side, and a planet on the far side of the star is
## lit from its own side rather than the near one.
func aim_sun_at(position: Vector3) -> void:
	if _sun_light == null:
		return
	var star := star()
	var direction := Vector3.BACK
	if star != null and star.node != null:
		direction = (position - star.node.global_position).normalized()
	if direction.length() < 0.5:
		return # standing on the star
	var up := Vector3.UP
	if absf(direction.dot(up)) > 0.999:
		up = Vector3.RIGHT
	_sun_light.global_transform = _sun_light.global_transform.looking_at(
		_sun_light.global_position + direction, up
	)


func star() -> SpacesimSystemBody:
	for body in bodies:
		if body.kind == "star":
			return body
	return null


func body_for_surface_frame(frame: SpacesimFrame) -> SpacesimSystemBody:
	for body in bodies:
		if body.surface == frame:
			return body
	return null


## Put a body's landing zone on the surface directly under `point`, with local up pointing away
## from the body's centre.
##
## The Coordinate doc's surface frame is "relative to landing zone", so the zone sits wherever
## the ship came down rather than at one fixed site — otherwise landing anywhere but that site
## would put the ship millions of metres from its frame's origin, which defeats the frame.
func place_landing_zone(body: SpacesimSystemBody, point: Vector3) -> void:
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


func _build_body(body: SpacesimSystemBody) -> void:
	body.node = Node3D.new()
	body.node.name = body.name
	body.node.position = body.position
	body.node.set_meta("spacesim_body", body.id)
	system_frame.add_child(body.node)

	body.mesh = _add_sphere(body.node, body.radius, body.color)
	body.scale_body = ScaleBody.new(body.node, body.radius)

	if not body.landable:
		return

	var atmosphere_altitude := float(_framing.get("atmosphere_altitude", 100000.0))
	var surface_altitude := float(_framing.get("surface_altitude", 2000.0))

	body.atmosphere = Frame.new()
	body.atmosphere.name = "Atmosphere"
	body.atmosphere.kind = Frame.Kind.ATMOSPHERE
	body.atmosphere.frame_id = "%s/atmosphere" % body.id
	body.atmosphere.travel_length_min = _band("atmosphere_band").x
	body.atmosphere.travel_length_max = _band("atmosphere_band").y
	body.node.add_child(body.atmosphere)
	frame_tree.register(body.atmosphere)

	body.surface = Frame.new()
	body.surface.name = "Surface"
	body.surface.kind = Frame.Kind.SURFACE
	body.surface.frame_id = "%s/surface" % body.id
	body.surface.travel_length_min = _band("surface_band").x
	body.surface.travel_length_max = _band("surface_band").y
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
	_sun_light = DirectionalLight3D.new()
	_sun_light.name = "StarLight"
	_sun_light.light_energy = 1.4
	container.add_child(_sun_light)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.01, 0.012, 0.02)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.07, 0.07, 0.09)
	environment.ambient_light_energy = 1.0
	var world_environment := WorldEnvironment.new()
	world_environment.name = "Environment"
	world_environment.environment = environment
	container.add_child(world_environment)


func _add_sphere(parent: Node3D, radius: float, color: Color) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 128
	sphere.rings = 64

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	# No triplanar or world_vertex_coords: neither gets the double-precision vertex transform
	# emulation, and both jitter at planet scale.

	var mesh := MeshInstance3D.new()
	mesh.name = "%sSurface" % parent.name
	mesh.mesh = sphere
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh)
	return mesh


## Meter-scale references at the landing zone, so the scale is legible once you are down.
func _add_landing_site(surface: SpacesimFrame) -> void:
	var pad_size := float(_framing.get("pad_size", 4000.0))

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


func _band(key: String) -> Vector2:
	var values: Array = _framing.get(key, [1.0, 1.0e11])
	return Vector2(float(values[0]), float(values[1]))
