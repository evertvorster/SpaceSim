class_name SpacesimGroup
extends Control
## **One labelled group in the HUD strip**: a thin white rounded border, a heading, and its lines.
##
## The strip is grouped rather than listed (Evert, 2026-11-07: *"Ship settings and status, Sensors,
## Location, Time. Each grouping can get a thin white border with rounded corners with a heading."*), and
## **a group grows by gaining lines** — the border and the heading are fixed, so wiring a new reading in is
## one more string in `set_lines` and nothing about the layout moves.
##
## ## Why the border is drawn and the text is a `Label`
##
## A `StyleBoxFlat` draws the rounded border: `draw_rect` has no corner radius, and a `PanelContainer`
## would put a container's layout rules between this node and the strip's own arithmetic. The text is real
## `Label`s, because they are what rasterises crisply under `canvas_items` stretch and what the rest of the
## HUD already uses.
##
## **The node owns nothing about where it is.** `fit(rect)` places it; the strip's geometry is
## `SpacesimDisplay`'s, so a changed strip height moves these exactly as it moves the picture.

const BORDER := Color(1.0, 1.0, 1.0, 0.45)
const BORDER_WIDTH := 1
const CORNER := 6
const HEADING_HEIGHT := 20.0
const PADDING := Vector2(10.0, 6.0)

## The heading's own size, a little smaller than the lines under it, so the group reads as a label over
## content rather than as a title page.
const HEADING_FONT_SIZE := 14
const BODY_FONT_SIZE := 17

var _heading: Label
var _body: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_heading = Label.new()
	_heading.name = "Heading"
	_heading.add_theme_font_size_override("font_size", HEADING_FONT_SIZE)
	_heading.add_theme_color_override("font_color", BORDER)
	add_child(_heading)

	_body = Label.new()
	_body.name = "Lines"
	_body.add_theme_font_size_override("font_size", BODY_FONT_SIZE)
	# The same outline the rest of the HUD text wears: these lines sit over a black panel but a bright
	# planet can still be behind the group's border on a narrow strip.
	_body.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	_body.add_theme_constant_override("outline_size", 6)
	add_child(_body)


## **Place the group and lay its text out inside it.** Called whenever the strip's geometry changes.
func fit(rect: Rect2) -> void:
	position = rect.position
	size = rect.size
	_place_text()


func _place_text() -> void:
	if _heading == null:
		return
	_heading.position = PADDING
	_heading.size = Vector2(maxf(size.x - PADDING.x * 2.0, 0.0), HEADING_HEIGHT)
	_body.position = PADDING + Vector2(0.0, HEADING_HEIGHT)
	_body.size = Vector2(
		maxf(size.x - PADDING.x * 2.0, 0.0),
		maxf(size.y - HEADING_HEIGHT - PADDING.y * 2.0, 0.0)
	)


## The group's name, above its lines.
func set_heading(text: String) -> void:
	if _heading == null:
		return
	_heading.text = text


## **Aligned fields, as `Label....: value`** — Evert, 2026-11-08: *"I would like the readouts in the boxes
## to be aligned. What I have seen that works well is to have something like: `Label....: <value>` /
## `Longlabel: <value>`"*.
##
## Every field is `[label, value]`. **The dots are a leader, not decoration**: they fill the space between a
## short label and the column where all the colons sit, which is the longest label in the group. So the
## longest label carries no dots at all (`Longlabel: value`) and every shorter one is padded to it — the
## colon column is one line to look down, which is what makes a list of readings scannable.
##
## **Per group, not per strip**: two groups are two panels, and a label in one should not be padded to the
## length of a label in the other.
func set_fields(fields: Array) -> void:
	var width := 0
	for field in fields:
		width = maxi(width, String(field[0]).length())
	var lines := PackedStringArray()
	for field in fields:
		var label := String(field[0])
		lines.append("%s%s: %s" % [label, ".".repeat(width - label.length()), String(field[1])])
	set_lines(lines)


## **The group's content, one string per line.** An empty array is a group with room reserved and nothing
## in it yet, which is what a reading that is not wired up should look like — not a line of dashes.
func set_lines(lines: PackedStringArray) -> void:
	if _body == null:
		return
	_body.text = "\n".join(lines)


## What the group currently reads, for a test and for a caller that needs to know whether it is empty.
func heading_text() -> String:
	return _heading.text if _heading != null else ""


func lines_text() -> String:
	return _body.text if _body != null else ""


func _draw() -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	box.border_color = BORDER
	box.set_border_width_all(BORDER_WIDTH)
	box.set_corner_radius_all(CORNER)
	draw_style_box(box, Rect2(Vector2.ZERO, size))


func _notification(what: int) -> void:
	# A group that is resized must redraw its border — `fit` moves the text, and the box is drawn rather
	# than clipped by a panel, so nothing else would ask for it.
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
		_place_text()
