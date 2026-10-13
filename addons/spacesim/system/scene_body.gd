class_name SpacesimSceneBody
extends RefCounted
## One body in a solar system: the data describing it, and the scene it was built into.
##
## The data half comes from the system file; the node half is filled in by
## [code]SpacesimSystemScene.build()[/code]. Which bodies count as significant — for the travel unit,
## and for having frames at all — is content's decision, expressed in the file.

var id: String
var name: String
var kind: String ## "star", "planet", "moon", ...
var radius: float ## metres
var position: Vector3 ## in the system frame, metres
var color: Color
var landable: bool ## whether it gets atmosphere and surface frames
## Whether it is worth marking on screen. A body can be worth flying to without being worth a
## label — every rock in a belt is the latter.
var significant: bool

# Built by SpacesimSystemScene.
var node: Node3D
var mesh: MeshInstance3D
var atmosphere: SpacesimFrame
var surface: SpacesimFrame
var scale_body: SpacesimScaleBody


static func from_dictionary(data: Dictionary) -> SpacesimSceneBody:
	var body := SpacesimSceneBody.new()
	body.id = String(data.get("id", ""))
	body.name = String(data.get("name", body.id))
	body.kind = String(data.get("kind", "planet"))
	body.radius = float(data.get("radius", 0.0))
	body.position = _vector_from(data.get("position", [0.0, 0.0, 0.0]))
	body.landable = bool(data.get("landable", false))
	body.significant = bool(data.get("significant", true))
	var channels: Array = data.get("color", [0.8, 0.8, 0.8])
	body.color = Color(float(channels[0]), float(channels[1]), float(channels[2]))
	return body


static func _vector_from(values: Variant) -> Vector3:
	var components: Array = values
	if components.size() < 3:
		return Vector3.ZERO
	return Vector3(float(components[0]), float(components[1]), float(components[2]))
