class_name SpacesimGroup
extends Control
## **One labelled group in the HUD strip**: a thin white rounded border, a heading, and its fields.
##
## The strip is grouped rather than listed (Evert, 2026-11-07: *"Ship settings and status, Sensors,
## Location, Time. Each grouping can get a thin white border with rounded corners with a heading."*), and
## **a group grows by gaining a field** — the border and the heading are fixed, so wiring a new reading in is
## one more pair and nothing about the layout moves.
##
## ## The alignment is two columns, because the font is proportional
##
## Evert, 2026-11-08: *"I would like the readouts in the boxes to be aligned ... `Label....: <value>` /
## `Longlabel: <value>`"*, and then: *"The font is not monospaced, so it still does not line up."*
##
## He was right, and it is the reason this is not one string per line. Dot leaders counted in **characters**
## only line up in a monospaced face; in a proportional one a dot is a different width from an `m`, and the
## colons drift apart. So the group measures its own labels with the font it actually draws with and puts
## **the names in one right-aligned column and the values in another**. The leaders fall out of the
## measurement rather than out of a character count, so the colon column is exact in any face.
##
## ## Why the border is drawn and the text is a `Label`
##
## A `StyleBoxFlat` draws the rounded border: `draw_rect` has no corner radius, and a `PanelContainer`
## would put a container's layout rules between this node and the strip's own arithmetic. The text is real
## `Label`s, because they are what rasterises crisply under `canvas_items` stretch.

const BORDER := Color(1.0, 1.0, 1.0, 0.45)
const BORDER_WIDTH := 1
const CORNER := 6
const HEADING_HEIGHT := 20.0
const PADDING := Vector2(10.0, 6.0)

## The gap used until a font has been measured. Once it has, the gap is **one space in that font**, which
## is what "a single space after the colon" means when the colon and its value are in different labels —
## Evert, 2026-11-08.
const VALUE_GAP_FALLBACK := 6.0

## The heading's own size, a little smaller than the fields under it, so the group reads as a label over
## content rather than as a title page.
const HEADING_FONT_SIZE := 14
const BODY_FONT_SIZE := 17

var _heading: Label
## The names, right-aligned, so every colon ends in the same column.
var _names: Label
## The values, left-aligned, starting at that column.
var _values: Label

## The label column's width in pixels, measured from the longest label in this group.
var _column := 0.0

## The gap between the colon and the value, in pixels — one space in the body font.
var _gap := VALUE_GAP_FALLBACK


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_heading = Label.new()
	_heading.name = "Heading"
	_heading.add_theme_font_size_override("font_size", HEADING_FONT_SIZE)
	_heading.add_theme_color_override("font_color", BORDER)
	add_child(_heading)

	_names = _make_body("Names")
	_names.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_names)

	_values = _make_body("Values")
	add_child(_values)


func _make_body(node_name: String) -> Label:
	var label := Label.new()
	label.name = node_name
	label.add_theme_font_size_override("font_size", BODY_FONT_SIZE)
	# The same outline the rest of the HUD text wears: these lines sit over a black panel, but a bright
	# planet can still be behind the group's border on a narrow strip.
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	label.add_theme_constant_override("outline_size", 6)
	return label


## **Place the group and lay its text out inside it.** Called whenever the strip's geometry changes.
func fit(rect: Rect2) -> void:
	position = rect.position
	size = rect.size
	_place_text()


func _place_text() -> void:
	if _heading == null:
		return
	var inner := Vector2(maxf(size.x - PADDING.x * 2.0, 0.0), maxf(size.y - PADDING.y * 2.0, 0.0))
	_heading.position = PADDING
	_heading.size = Vector2(inner.x, HEADING_HEIGHT)

	var body := Vector2(inner.x, maxf(inner.y - HEADING_HEIGHT, 0.0))
	var at := PADDING + Vector2(0.0, HEADING_HEIGHT)
	var column := minf(_column, body.x)
	_names.position = at
	_names.size = Vector2(column, body.y)
	_values.position = at + Vector2(column + _gap, 0.0)
	_values.size = Vector2(maxf(body.x - column - _gap, 0.0), body.y)


## The group's name, above its fields.
func set_heading(text: String) -> void:
	if _heading == null:
		return
	_heading.text = text


## **The group's content as `[label, value]` pairs**, drawn as two aligned columns.
##
## The column is measured from the longest label **with the font the values are drawn in**, so the colons
## line up in a proportional face — a character count cannot do that, which is what the first version got
## wrong. Each shorter label is then filled with dots to that column, which keeps the leader look while
## being exact rather than approximately aligned.
##
## **Per group, not per strip**: two panels are two panels, and a label in one should not be padded to the
## length of a label in another.
func set_fields(fields: Array) -> void:
	if _names == null:
		return
	var font := _values.get_theme_font("font")
	# **One space either side of the colon** — Evert, 2026-11-08: *"I want some visual space around the
	# colons. Like ' Label : variable'"*. The space BEFORE it is part of the name (`Label :`), so the
	# right-aligned column carries it into every row identically; the space AFTER it is the gap between the
	# two labels, measured in the same font rather than guessed in pixels.
	_gap = font.get_string_size(" ", HORIZONTAL_ALIGNMENT_LEFT, -1, BODY_FONT_SIZE).x

	var names := PackedStringArray()
	var values := PackedStringArray()
	for field in fields:
		names.append("%s :" % String(field[0]))
		values.append(String(field[1]))

	# **Measured with the space included**, so the column is the widest name plus its own space and colon —
	# otherwise the longest label's colon would land a space's width past every other one.
	var column := 0.0
	for name in names:
		column = maxf(column, font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, BODY_FONT_SIZE).x)
	_column = column

	_names.text = "\n".join(names)
	_values.text = "\n".join(values)
	_place_text()


## **Raw text, one entry per line, in the values column** — for a group with nothing to label, and for the
## empty case a reading that is not wired up yet should look like rather than a line of dashes.
func set_lines(lines: PackedStringArray) -> void:
	if _names == null:
		return
	_column = 0.0
	_names.text = ""
	_values.text = "\n".join(lines)
	_place_text()


## What the group currently reads, for a test and for a caller that needs to know whether it is empty.
func heading_text() -> String:
	return _heading.text if _heading != null else ""


func names_text() -> String:
	return _names.text if _names != null else ""


func values_text() -> String:
	return _values.text if _values != null else ""


## The width the label column was measured to, in pixels.
func column_width() -> float:
	return _column


## The gap between the colon column and the values, in pixels — one space in the body font.
func value_gap() -> float:
	return _gap


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
