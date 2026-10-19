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
## The material `mesh` is drawn with when it is **not** a wireframe, kept so the debug view can restore it.
## Set when the body is built; `update_lod` swaps a wireframe material over it and puts this one back.
var mesh_material: Material
## The **point of light** this body becomes once it is too small to be a disc: a camera-facing quad,
## sized to the disc it would have had and coloured by its radiance. Hidden while the body is drawn as
## geometry. Set by `SpacesimSystemScene.update_lod`.
var point: MeshInstance3D
## **The patch selection `mesh` currently holds**, so the tree is rebuilt only when it would differ —
## the leaf count and the camera direction, quantised. Set by `SpacesimSystemScene.update_lod`.
##
## This replaced a whole-sphere icosphere level, which could only ever refine the entire body at once.
var patch_key := Vector3i(-1, 0, 0)
var atmosphere: SpacesimFrame
var surface: SpacesimFrame
var scale_body: SpacesimScaleBody
## **How tall this body's air is**, in metres — derived from the air's own scale height, floored where the
## framing says its atmosphere frame begins.
##
## Kept on the body rather than recomputed because the camera's far plane needs it
## (`SpacesimSystemScene.sky_reach`), which falls short of the air's top otherwise. Zero for a body with
## no air. **Nothing draws anything from it**: the shell that used to be built at this radius is gone, and
## the march that will draw the air is not written yet.
var sky_top: float = 0.0


static func from_content(
	content: SpacesimSystemBody, materials: SpacesimMaterialTable = null
) -> SpacesimSceneBody:
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
	body.color = color_of(content, materials)
	return body


## The colour to draw a body in: what content pinned, or **the derivation** — surface coverage blended
## with the cloud deck, through the material table.
##
## Pinning still wins, because content overrides derived values everywhere else: a system that wants a
## particular look says so rather than being second-guessed. `UNPINNED_COLOR` is what a body with
## nothing to derive from gets.
static func color_of(
	content: SpacesimSystemBody, materials: SpacesimMaterialTable = null
) -> Color:
	if content.overrides != null and content.overrides.set.has("surface_color"):
		return content.overrides.surface_color
	return SpacesimSurfaceModel.color(content, materials)


func orbits() -> bool:
	return orbit != null
