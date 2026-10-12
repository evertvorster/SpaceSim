class_name SpacesimDialog
extends SpacesimScreen
## A modal *inside* another screen: the same chrome, smaller.
##
## Generic on purpose, because the save browser needs three shapes of it and they are all "a title,
## some words, maybe a field, and a row of answers": a confirmation that names what it will destroy,
## a name prompt, and a save's details.
##
## It is a child of the screen that uses it rather than a screen of its own, so the pause handling
## and the screen hotkeys stay exactly where they are — one thing open is what being paused means,
## and a dialog over a screen is still one thing.

signal answered(action: String)

## Any field edited, so a caller can say what a typed name will become.
signal input_changed

const DIALOG_SIZE := Vector2(640.0, 440.0)

## A line under the fields, for saying what will happen to what was typed.
var hint: Label

var _fields: Dictionary = {}


## Show a question. `inputs` are field labels to collect; `buttons` are the answers, in order.
func ask(title: String, message: String, buttons: Array, inputs: Array = []) -> void:
	if content == null:
		panel_size = DIALOG_SIZE
		build_screen(title)
	elif title_label != null:
		title_label.text = title

	for child in content.get_children():
		child.free()
	for child in actions.get_children():
		child.free()
	_fields.clear()

	if not message.is_empty():
		var body := Label.new()
		body.text = message
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.custom_minimum_size = Vector2(DIALOG_SIZE.x - 80.0, 0.0)
		content.add_child(body)

	for label in inputs:
		var row := HBoxContainer.new()
		var name_label := Label.new()
		name_label.text = String(label)
		name_label.custom_minimum_size = Vector2(170.0, 0.0)
		row.add_child(name_label)
		var field := LineEdit.new()
		field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		field.text_changed.connect(func(_text: String) -> void: input_changed.emit())
		row.add_child(field)
		content.add_child(row)
		_fields[String(label)] = field

	hint = Label.new()
	hint.modulate = Color(1.0, 1.0, 1.0, 0.6)
	content.add_child(hint)

	for label in buttons:
		add_button(String(label), func() -> void: _answer(String(label)))

	opened()
	visible = true


## What was typed into a field, trimmed.
func value(label: String) -> String:
	var field: LineEdit = _fields.get(label)
	return field.text.strip_edges() if field != null else ""


func focus_first_field() -> void:
	for field in _fields.values():
		field.grab_focus()
		return


func _answer(action: String) -> void:
	visible = false
	answered.emit(action)
