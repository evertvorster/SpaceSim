class_name SpacesimScreen
extends Control
## Shared chrome for a full-screen modal: a dimmed backdrop, a centred panel with a title, a
## scrollable content column, and a button bar.
##
## Two screens with the same chrome would drift apart, so there is one. A subclass calls
## [method build_screen] and then fills [member content] and [member actions].

signal closed

const PANEL_SIZE := Vector2(860.0, 640.0)

## How big this screen's panel is. A dialog overrides it before [method build_screen]; the full-screen
## chrome is 860x640 and a question does not need that much.
var panel_size := PANEL_SIZE

## Where a subclass puts its rows.
var content: VBoxContainer

## Where a subclass puts its buttons.
var actions: HBoxContainer

## The heading, kept so a reused screen can change what it is asking.
var title_label: Label


func build_screen(title: String) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.0, 0.0, 0.0, 0.65)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -panel_size.x * 0.5
	panel.offset_top = -panel_size.y * 0.5
	panel.offset_right = panel_size.x * 0.5
	panel.offset_bottom = panel_size.y * 0.5
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 16)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var heading := Label.new()
	heading.name = "Title"
	heading.text = title
	heading.add_theme_font_size_override("font_size", 22)
	column.add_child(heading)
	title_label = heading

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	content = VBoxContainer.new()
	content.name = "Content"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	scroll.add_child(content)

	actions = HBoxContainer.new()
	actions.name = "Actions"
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 8)
	column.add_child(actions)


## Add a button to the bar, connected as it is made.
func add_button(label: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.name = label.replace(" ", "")
	button.text = label
	button.pressed.connect(on_pressed)
	actions.add_child(button)
	return button


## Called just before the screen is shown. Rebuild anything that could be stale here.
func opened() -> void:
	pass


## Called just before it is hidden, whatever the route — so tidying up does not depend on which
## button happened to be pressed.
func dismissed() -> void:
	pass
