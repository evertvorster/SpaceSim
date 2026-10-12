extends RefCounted
## Builds the demo world in code.
##
## Built in code rather than authored as a scene so that the headless test can construct
## the identical world and fly it. The .tscn is deliberately one node plus a script.
##
## The world is a planet at real scale, three coordinate frames (system, atmosphere,
## surface), and an observer starting well outside it.

const Frame := preload("res://addons/spacesim/coordinate/frame.gd")
const FrameTree := preload("res://addons/spacesim/coordinate/frame_tree.gd")
const TransitionRule := preload("res://addons/spacesim/coordinate/transition_rule.gd")
const ScaleBody := preload("res://addons/spacesim/travel/scale_body.gd")
const FlightController := preload("res://demo/flight_controller.gd")

const PLANET_RADIUS := 6_371_000.0 ## Earth, metres
const START_DISTANCE := 1.5e7 ## observer's distance from the planet's centre, metres
const ATMOSPHERE_ALTITUDE := 100_000.0
const SURFACE_ALTITUDE := 2_000.0
const PAD_SIZE := 4_000.0 ## landing pad edge, metres

## Travel bands. Each frame's band must *contain* the scale at the distances its
## boundaries are crossed, or the travel unit jumps when the frame changes. Keeping these
## in agreement with the transition thresholds is the rule; the test asserts it.
const BAND_SYSTEM := Vector2(1.0e4, 1.0e11)
const BAND_ATMOSPHERE := Vector2(2.0e3, 4.0e5)
const BAND_SURFACE := Vector2(1.0e2, 5.0e3)


func build(root: Node) -> Dictionary:
	var container := Node3D.new()
	container.name = "ScaleWorld"
	root.add_child(container)

	_add_environment(container)

	# --- frames -------------------------------------------------------------------
	var system := Frame.new()
	system.name = "System"
	system.kind = Frame.Kind.SPACE
	system.travel_length_min = BAND_SYSTEM.x
	system.travel_length_max = BAND_SYSTEM.y
	container.add_child(system)

	var planet := Node3D.new()
	planet.name = "Planet"
	system.add_child(planet)
	_add_planet_surface(planet)

	var atmosphere := Frame.new()
	atmosphere.name = "Atmosphere"
	atmosphere.kind = Frame.Kind.ATMOSPHERE
	atmosphere.travel_length_min = BAND_ATMOSPHERE.x
	atmosphere.travel_length_max = BAND_ATMOSPHERE.y
	planet.add_child(atmosphere)

	# The landing site, on the surface along +X. Its local up (+Y) points away from the
	# planet's centre, so a flat pad here is tangent to the sphere.
	var surface := Frame.new()
	surface.name = "Surface"
	surface.kind = Frame.Kind.SURFACE
	surface.travel_length_min = BAND_SURFACE.x
	surface.travel_length_max = BAND_SURFACE.y
	surface.position = Vector3(PLANET_RADIUS, 0.0, 0.0)
	surface.basis = Basis(Vector3(0.0, 0.0, 1.0), -PI / 2.0)
	planet.add_child(surface)
	_add_landing_site(surface)

	# --- observer -----------------------------------------------------------------
	var ship := FlightController.new()
	ship.name = "Ship"
	ship.position = Vector3(START_DISTANCE, 0.0, 0.0)
	system.add_child(ship)
	_add_ship_visuals(ship)

	var bodies: Array[SpacesimScaleBody] = [ScaleBody.new(planet, PLANET_RADIUS)]
	ship.bodies = bodies

	var tree := FrameTree.new()
	tree.name = "FrameTree"
	tree.observer = ship
	tree.automatic = false # the demo and the test both step it explicitly
	container.add_child(tree)
	ship.frame_tree = tree

	tree.add_rule(
		TransitionRule.new(system, atmosphere, planet, PLANET_RADIUS, ATMOSPHERE_ALTITUDE, TransitionRule.Direction.ENTER)
	)
	tree.add_rule(
		TransitionRule.new(
			atmosphere,
			system,
			planet,
			PLANET_RADIUS,
			ATMOSPHERE_ALTITUDE * 1.2,
			TransitionRule.Direction.EXIT
		)
	)
	tree.add_rule(
		TransitionRule.new(atmosphere, surface, planet, PLANET_RADIUS, SURFACE_ALTITUDE, TransitionRule.Direction.ENTER)
	)
	tree.add_rule(
		TransitionRule.new(
			surface, atmosphere, planet, PLANET_RADIUS, SURFACE_ALTITUDE * 1.5, TransitionRule.Direction.EXIT
		)
	)
	tree.enter_frame(system)

	return {
		"container": container,
		"frame_tree": tree,
		"system": system,
		"planet": planet,
		"atmosphere": atmosphere,
		"surface": surface,
		"ship": ship,
		"bodies": bodies,
	}


func _add_environment(parent: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(0.0, 0.6, 0.9)
	sun.light_energy = 1.4
	parent.add_child(sun)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.01, 0.012, 0.02)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.08, 0.08, 0.1)
	environment.ambient_light_energy = 1.0

	var world_environment := WorldEnvironment.new()
	world_environment.name = "Environment"
	world_environment.environment = environment
	parent.add_child(world_environment)


func _add_planet_surface(planet: Node3D) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = PLANET_RADIUS
	sphere.height = PLANET_RADIUS * 2.0
	sphere.radial_segments = 128
	sphere.rings = 64

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.36, 0.34, 0.3)
	# No triplanar or world_vertex_coords: neither gets the double-precision vertex
	# transform emulation, and both jitter at planet scale.

	var mesh := MeshInstance3D.new()
	mesh.name = "PlanetSurface"
	mesh.mesh = sphere
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	planet.add_child(mesh)


func _add_landing_site(surface: Node3D) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(PAD_SIZE, PAD_SIZE)

	var pad_material := StandardMaterial3D.new()
	pad_material.albedo_color = Color(0.18, 0.2, 0.24)

	var pad := MeshInstance3D.new()
	pad.name = "LandingPad"
	pad.mesh = plane
	pad.material_override = pad_material
	surface.add_child(pad)

	# Meter-scale references, so the scale is legible once you are down.
	var marker_material := StandardMaterial3D.new()
	marker_material.albedo_color = Color(0.85, 0.6, 0.15)
	for i in 5:
		var marker := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(20.0, 40.0, 20.0)
		marker.mesh = box
		marker.material_override = marker_material
		var angle := TAU * float(i) / 5.0
		marker.position = Vector3(cos(angle) * 600.0, 20.0, sin(angle) * 600.0)
		marker.name = "Marker%d" % i
		surface.add_child(marker)


func _add_ship_visuals(ship: Node3D) -> void:
	var box := BoxMesh.new()
	box.size = Vector3(6.0, 3.0, 18.0)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.75, 0.78, 0.85)

	var mesh := MeshInstance3D.new()
	mesh.name = "Hull"
	mesh.mesh = box
	mesh.material_override = material
	ship.add_child(mesh)

	# Chase camera. Render range is set per frame by the demo, from the frame's scale.
	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.position = Vector3(0.0, 5.0, 32.0)
	camera.fov = 70.0
	ship.add_child(camera)
