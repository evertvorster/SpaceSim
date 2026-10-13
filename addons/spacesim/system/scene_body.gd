class_name SpacesimSceneBody
extends RefCounted
## One body's **built** half: the content it came from, and the nodes it was built into.
##
## The content lives in [SpacesimSystemBody]. A Godot `Resource` is cached and shared, so one
## holding node references would hand the same nodes to a second build — the nodes live here, and
## this is the object the scene hands out.

## The authored body this was built from. The fields below are copied out of it so the scene does
## not have to reach through it everywhere; `content` is kept for anything the derivation will need.
var content: SpacesimSystemBody
var id: String
var name: String
var kind: String ## "star", "planet", "moon", ...
var radius: float ## metres
var position: Vector3 ## in the system frame, metres — fixed, or solved from the orbit
var color: Color
var parent_id: String
var fixed_position: Vector3
var orbit: SpacesimOrbit
var landable: bool
var significant: bool

# Built by SpacesimSystemScene.
var node: Node3D
var mesh: MeshInstance3D
var atmosphere: SpacesimFrame
var surface: SpacesimFrame
var scale_body: SpacesimScaleBody

## Until the derivation supplies a colour from composition this is what an unpinned body is drawn
## in — visibly a placeholder rather than a plausible-looking guess.
const UNPINNED_COLOR := Color(0.62, 0.62, 0.66)


static func from_content(content: SpacesimSystemBody) -> SpacesimSceneBody:
	var body := SpacesimSceneBody.new()
	body.content = content
	body.id = content.id
	body.name = content.display_name
	body.kind = content.kind_name()
	body.radius = content.radius
	body.parent_id = content.parent_id
	body.fixed_position = content.fixed_position
	body.orbit = content.orbit
	body.landable = content.landable
	body.significant = content.significant
	body.color = color_of(content)
	return body


## The colour to draw a body in: what content pinned, or a placeholder.
##
## Colour is **derived** — from composition and surface coverage, via the material table. That
## derivation does not exist yet, which is why an unpinned body is deliberately unlovely.
static func color_of(content: SpacesimSystemBody) -> Color:
	if content.overrides != null and content.overrides.set.has("surface_color"):
		return content.overrides.surface_color
	return UNPINNED_COLOR


func orbits() -> bool:
	return orbit != null
