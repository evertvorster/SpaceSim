class_name SpacesimOverlay
extends Control
## The navigation overlay: a ring where each object is, and a short line to its label.
##
## Drawn in **one pass** rather than as a node each. Twelve markers would otherwise be twelve
## Controls to build, place and hide every frame — and none of them would know about the others,
## which is exactly what placing a label clear of the others needs to know.
##
## **The ring is where the object actually is, and may be off screen.** The label stays in view: on
## screen it sits against its own ring, and over the edge it sits at the edge of the window on its
## own, with **no line** — there is no ring in sight to point from, and a line to one nobody can see
## points at nothing.

const RING_RADIUS := 10.0
const RING_WIDTH := 1.0
const LINE_WIDTH := 1.0

## How much clear space a label keeps from its own ring, and from another label.
const GAP := 12.0

## How far a label creeps, and in how many steps, when the place beside its ring is taken. **Small
## steps matter**: a label that leaps to twice the distance because one spot was occupied reads as
## belonging to the screen rather than to the object, and the line to it stops being a pointer.
const STEP_RATIO := 1.22
const STEPS := 14

const RING_SEGMENTS := 24

const COLOR := Color(0.85, 0.92, 1.0, 0.9)
const SELECTED_COLOR := Color(1.0, 0.85, 0.42, 0.95)

## One entry per marker, set by [SpacesimMarkers] each frame:
## `{"circle": Vector2, "start": Vector2, "end": Vector2, "color": Color}` — or without `start`
## and `end` for a ring that carries no label, which is what a moon gives up.
var marks: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _draw() -> void:
	for mark in marks:
		var colour: Color = mark["color"]
		if mark.has("start"):
			draw_line(mark["start"], mark["end"], colour, LINE_WIDTH, true)
		# After the line, so the ring sits on top of it.
		draw_arc(mark["circle"], RING_RADIUS, 0.0, TAU, RING_SEGMENTS, colour, RING_WIDTH, true)


# --- placement -------------------------------------------------------------------------------------

## Where a label goes: **as near its ring as it can be without landing on another label**, and
## always inside `bounds`.
##
## Candidates are eight places round the anchor — each as close as the label's own shape allows — at
## growing distances from it. The first that fits and collides with nothing wins, so a label **hugs
## its own ring** and only moves when another label is in that spot.
##
## Labels are placed nearest-first, so what matters most picks its spot first and the rest arrange
## themselves around it. **Another label is the only thing that moves one**: nothing is reserved
## around the HUD, because the readout is usually where markers are, and pushing labels clear of it
## throws them hundreds of pixels off objects that are plainly on screen.
##
## A last-resort fallback is returned when nothing is free, so a label is never silently dropped: an
## overlapping label still says where something is, and a missing one does not. [method nearest_free] is
## the other question — *is there space within `steps`?* — which a caller asks when a label away from its
## own ring would be worse than no label at all.
static func place_label(
	anchor: Vector2, label_size: Vector2, taken: Array[Rect2], bounds: Rect2
) -> Rect2:
	var box := nearest_free(anchor, label_size, taken, bounds, STEPS)
	# Nowhere within reach is still a label: an overlapping one says where something is, and a missing
	# one says nothing.
	return box if box.has_area() else fitted(Rect2(anchor - label_size * 0.5, label_size), bounds)


## The first free spot in up to `steps` rings of candidates, or an empty rect when there is none.
static func nearest_free(
	anchor: Vector2, label_size: Vector2, taken: Array[Rect2], bounds: Rect2, steps: int
) -> Rect2:
	var half := label_size * 0.5
	var offsets := _offsets(half, RING_RADIUS + GAP)
	# Never across its own ring: near the edge of the screen, fitting a candidate back inside can slide
	# it straight over the circle it belongs to.
	var own_ring := Rect2(anchor - Vector2.ONE * RING_RADIUS, Vector2.ONE * RING_RADIUS * 2.0)
	var scale := 1.0
	for step in steps:
		for offset in offsets:
			var box := fitted(Rect2(anchor + offset * scale - half, label_size), bounds)
			if not box.intersects(own_ring) and free_of(box, taken):
				return box
		scale *= STEP_RATIO
	return Rect2()


## The eight places a label can sit, **each as near its ring as the label's own shape allows** — a
## wide one goes beside the ring, a tall one above or below it.
##
## This is why the offsets are not a radius: one radius has to be the label's *largest* dimension, so a
## short wide label ends up a hundred pixels off in every direction, including straight up. Sideways
## it needs half its width and no more; vertically it needs half its height.
static func _offsets(half: Vector2, clearance: float) -> Array[Vector2]:
	var side := Vector2(half.x + clearance, half.y + clearance)
	# Diagonally the label's *corner* faces the ring, so the clearance is measured to there.
	var corner := clearance * 0.7071
	return [
		Vector2(side.x, 0.0),
		Vector2(-side.x, 0.0),
		Vector2(0.0, side.y),
		Vector2(0.0, -side.y),
		Vector2(half.x + corner, half.y + corner),
		Vector2(-half.x - corner, -half.y - corner),
		Vector2(half.x + corner, -half.y - corner),
		Vector2(-half.x - corner, half.y + corner),
	]


## A rect slid the smallest distance that puts it inside `bounds`. One bigger than the bounds is left
## where it is rather than squashed — a label that does not fit is a font-size problem, not a
## placement one.
static func fitted(box: Rect2, bounds: Rect2) -> Rect2:
	var moved := box
	if box.size.x <= bounds.size.x:
		moved.position.x = clampf(box.position.x, bounds.position.x, bounds.end.x - box.size.x)
	if box.size.y <= bounds.size.y:
		moved.position.y = clampf(box.position.y, bounds.position.y, bounds.end.y - box.size.y)
	return moved


static func free_of(box: Rect2, taken: Array[Rect2]) -> bool:
	for other in taken:
		if other.intersects(box):
			return false
	return true


## The point where the border of `rect` is crossed on the way to `towards`, seen from its centre.
##
## The one piece of geometry the overlay needs twice: a leader line should meet a label's box rather
## than run under its text, and a ring that is off screen should put its line on the viewport edge.
static func border_point(rect: Rect2, towards: Vector2) -> Vector2:
	var centre := rect.get_center()
	var delta := towards - centre
	if delta.length_squared() < 0.000001:
		return centre
	var reach := INF
	if absf(delta.x) > 0.0001:
		reach = minf(reach, (rect.size.x * 0.5) / absf(delta.x))
	if absf(delta.y) > 0.0001:
		reach = minf(reach, (rect.size.y * 0.5) / absf(delta.y))
	return centre + delta * reach
