class_name SpacesimFrame
extends Node3D
## A coordinate space with its own local origin.
##
## A frame's own transform is its origin and orientation expressed in its *parent* frame. Frames
## nest, so the frame chain is the chain of coordinate spaces, outermost first, and a frame's
## children are what lives in that coordinate space.
##
## All frames use metres. There is no unit scaling between frames: an AU-scale system frame and a
## metre-scale surface frame differ only in how far their children sit from the origin. Keeping one
## unit avoids scaled-parent artefacts in physics and rendering, and the double-precision engine
## build carries the range.


enum Kind {
	SPACE, ## deep space, origin at the system barycentre
	ORBITAL, ## origin at a body's centre
	ATMOSPHERE, ## origin at a body's centre
	SURFACE, ## origin at a landing zone
	INTERIOR, ## origin at a room or ship
}

## The one frame every world has, and the id a thing flying in open space is in.
const SYSTEM_ID := "system"

@export var kind: Kind = Kind.SPACE

## Stable identity, so a save can name this space and the loader can find it again. Assigned by
## whoever creates the frame; see [constant SYSTEM_ID] for the one every world has.
@export var frame_id: String = ""

## The band of local lengths this frame spans, in metres. The travel unit
## ([code]SpacesimTravelScale[/code]) holds the distance to the nearest significant thing
## within this band, so the frame declares its own scale rather than the travel code
## hard-coding one per frame kind.
##
## These should agree with the frame's transition thresholds: a lurch in speed at a frame
## boundary means the band and the thresholds have drifted apart.
@export var travel_length_min: float = 1_000.0
@export var travel_length_max: float = 1.0e11


## Position expressed in this frame, given a position in the outermost coordinate space.
func to_frame_position(outer_position: Vector3) -> Vector3:
	return to_local(outer_position)


## Position in the outermost coordinate space, given a position expressed in this frame.
func to_outer_position(frame_position: Vector3) -> Vector3:
	return global_transform * frame_position
