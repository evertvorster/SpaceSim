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
	# `set_anchors_and_offsets_preset`, not `set_anchors_preset`. The latter defaults to keeping the
	# rect the control *currently* has — which for a control that has just been made is 0x0, so it
	# stays 0x0 and everything anchored inside it lands off the corner of the window. The screens get
	# away with the difference because they are built before they are in the tree; a dialog, built
	# while it is already in one, does not.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.0, 0.0, 0.0, 0.65)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
	# **Vertical expansion, so a screen can give its sections the room the window has instead of
	# scrolling as soon as they are taller than their minimums.** A `ScrollContainer` gives a child
	# with `SIZE_EXPAND` on an axis `max(its own size, the child's minimum)` (4.7.2,
	# `scene/gui/scroll_container.cpp`, `_reposition_children`) — without the flag the column is
	# pinned to its minimum and the extra height is lost. A column whose rows are all minimum-sized
	# looks the same either way, which is why this went unnoticed while every screen was a list.
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
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


## A section heading in the column.
func _add_heading(text: String) -> void:
	content.add_child(_title_label(text))


func _title_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	return label


## A name, editable, with the button that commits it. The button is **disabled until the text
## differs**, so a control never offers to do nothing, and it says what it does: *Apply* stages a
## change that Save writes, *Rename* does it now.
##
## Enter in the field is the same as pressing it, when there is something to do.
##
## Here because both screens edit names and neither should own the widget: the personal-data screen
## edits the player's and its assets', the saved-games screen a history's.
func _name_field(current: String, on_apply: Callable, action := "Apply") -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var field := LineEdit.new()
	field.text = current
	field.custom_minimum_size = Vector2(240.0, 0.0)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)

	var button := Button.new()
	button.name = "NameAction"
	button.text = action
	button.disabled = true
	row.add_child(button)

	field.text_changed.connect(
		func(text: String) -> void: button.disabled = text.strip_edges() == current
	)
	field.text_submitted.connect(
		func(_text: String) -> void:
			if not button.disabled:
				button.pressed.emit()
	)
	button.pressed.connect(func() -> void: on_apply.call(field.text.strip_edges()))
	return row


## Called just before the screen is shown. Rebuild anything that could be stale here.
func opened() -> void:
	pass


## Called just before it is hidden, whatever the route — so tidying up does not depend on which
## button happened to be pressed.
func dismissed() -> void:
	pass
