extends SceneTree
## **What the fragment mesh actually is** — size, normals, and how many triangles.
##
## The report: a 17 m asteroid whose nearest triangles vanish as the ship inches closer (stationary ship),
## whose marker sits about 100 m off it, and whose lit area moves when the camera orbits it.
##
##   timeout 120 godot-double-mono --headless --path . --script res://tests/probe_fragment.gd \
##       > /tmp/probe_fragment.log 2>&1
##
## `quit()` is required or the process runs forever, and the output goes to a FILE because a `timeout`
## kill takes the pipe with it (godot skill, `references/verification.md`).

const DIAMETER := 17.0
const RESOLUTION := 24


func _initialize() -> void:
	_shapes()
	_field()
	quit()


## **The mesh's own size, against the diameter it was asked for.** A near plane of 100 m cannot cut into a
## 20 m rock, so if the geometry is the size the label says, the clipping has another cause.
func _shapes() -> void:
	for radius in [DIAMETER * 0.5, 1.0, 1000.0]:
		var surface: Array = SpacesimBlobShape.arrays(12345, radius, RESOLUTION)
		var points: PackedVector3Array = surface[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = surface[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = surface[Mesh.ARRAY_INDEX]
		var low := Vector3.INF
		var high := -Vector3.INF
		for point in points:
			low = low.min(point)
			high = high.max(point)
		var shortest := INF
		var longest := 0.0
		for normal in normals:
			shortest = minf(shortest, normal.length())
			longest = maxf(longest, normal.length())
		print("radius %10.3f -> vertices %6d triangles %6d" % [radius, points.size(), indices.size() / 3])
		print("    extent   %.3f .. %.3f  (x), so %.3f across" % [low.x, high.x, high.x - low.x])
		print("    ratio to 2*radius   %.4f" % ((high.x - low.x) / (2.0 * radius)))
		print("    normal length %.4f .. %.4f" % [shortest, longest])
		# **Do they point OUTWARD?** A unit normal that points inward passes every length check and lights
		# the body from the inside: the lit area then depends on which faces the camera can see, which is
		# exactly the report *"the lit area is changing as if it is anchored on something else"*.
		var inward := 0
		for index in points.size():
			if (points[index] as Vector3).dot(normals[index]) < 0.0:
				inward += 1
		print("    normals pointing INWARD: %d of %d (%.1f%%)" % [
			inward, points.size(), 100.0 * float(inward) / float(points.size())
		])
		# **Is the winding consistent?** A face whose geometric normal opposes its own vertex normals is
		# culled from one side and drawn from the other, so triangles wink in and out as the eye moves.
		var disagree := 0
		var triangles := 0
		for triangle in range(0, indices.size(), 3):
			var a := points[indices[triangle]]
			var b := points[indices[triangle + 1]]
			var c := points[indices[triangle + 2]]
			var face := (b - a).cross(c - a)
			var average := normals[indices[triangle]] + normals[indices[triangle + 1]] + normals[indices[triangle + 2]]
			triangles += 1
			if face.dot(average) < 0.0:
				disagree += 1
		print("    triangles wound against their normals: %d of %d (%.1f%%)" % [
			disagree, triangles, 100.0 * float(disagree) / float(triangles)
		])


## **The field, and where a ship parked beside the nearest fragment actually is.**
func _field() -> void:
	var sol: SpacesimSolarSystem = load("res://systems/sol.tres")
	var belt := sol.population_by_id("population:main_belt")
	var field := SpacesimPopulationField.new(belt)
	var parent := Vector3.ZERO
	var ship := Vector3(2.5 * 1.495978707e11, 0.0, 0.0)
	field.update(parent, 1.3271244e20, ship, 0.0)

	var fragments := field.fragments()
	var nearest := fragments[0]
	var best := INF
	for fragment in fragments:
		var distance: float = field.position_of(fragment, parent).distance_to(ship)
		if distance < best:
			best = distance
			nearest = fragment
	print("")
	print("nearest %s, diameter %.1f m, %.1f km away" % [nearest.designation, nearest.diameter, best / 1e3])
	print("resolve distance %.0f m; near plane in space is 100 m" % (
		SpacesimFragmentRenderer.resolve_distance(nearest.diameter)
	))
	print("its speed %.2f km/s" % (nearest.velocity().length() / 1e3))
	var spread := 0.0
	var closest_other := INF
	for fragment in fragments:
		if fragment == nearest:
			continue
		var distance: float = field.position_of(fragment, parent).distance_to(
			field.position_of(nearest, parent)
		)
		closest_other = minf(closest_other, distance)
		spread = maxf(spread, fragment.diameter)
	print("the nearest OTHER fragment is %.0f km from it" % (closest_other / 1e3))
	print("diameters: %.1f .. %.1f m" % [nearest.diameter, spread])
