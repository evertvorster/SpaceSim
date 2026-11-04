extends SceneTree
## Does **Add** produce rows once real frames are running — and does it keep doing so when pressed again?
##
## The suite calls `flush_rows()` by hand, which skips the thing that could be broken: whether `_process`
## runs at all inside the screen. This probe presses the button repeatedly and lets frames happen.
##
##     godot-double-mono --headless --path . --script res://tests/probe_add_row.gd

const SettingsPanel := preload("res://addons/spacesim/settings/settings_panel.gd")
const Settings := preload("res://addons/spacesim/settings/settings.gd")
const Store := preload("res://addons/spacesim/input/bindings_store.gd")

var _panel: SpacesimSettingsPanel
var _frame := 0


func _init() -> void:
	var settings := Settings.new()
	settings.open("/tmp/probe-add-row/settings.cfg")
	var store := Store.new()
	store.open("/tmp/probe-add-row/bindings.cfg", "/tmp/probe-add-row/settings.cfg")

	var layer := CanvasLayer.new()
	get_root().add_child(layer)
	_panel = SettingsPanel.new()
	_panel.configure(settings, store)
	layer.add_child(_panel)
	_panel.visible = true
	print("rows at build:           ", _rows_of("throttle_up"))


func _process(_delta: float) -> bool:
	_frame += 1
	# Press Add three times, with frames in between — the way a player does it.
	if _frame in [2, 5, 8]:
		var add: Button = _button("throttle_up", 0, "Add")
		if add == null:
			print("PROBE: no Add button at frame ", _frame)
			return true
		add.pressed.emit()
		print("frame %2d  pressed Add   rows %d  extras %s"
			% [_frame, _rows_of("throttle_up"), str(_panel.get("_extra_rows"))])
		return false
	if _frame == 11:
		print("after three Adds:        rows ", _rows_of("throttle_up"))
		print("empty fields:            ", _empty_fields())
		return true
	return false


func _rows_of(action: String) -> int:
	var count := 0
	for entry in _panel.get("_binding_rows"):
		if String(entry[0]) == action:
			count += 1
	return count


## How many of that action's fields show nothing — the rows Add is supposed to open.
func _empty_fields() -> int:
	var count := 0
	for entry in _panel.get("_binding_rows"):
		if String(entry[0]) == "throttle_up" and (entry[2] as LineEdit).text.is_empty():
			count += 1
	return count


func _button(action: String, index: int, text: String) -> Button:
	for entry in _panel.get("_binding_rows"):
		if String(entry[0]) != action or int(entry[1]) != index:
			continue
		var field: LineEdit = entry[2]
		for child in field.get_parent().get_children():
			if child is HBoxContainer:
				for button in child.get_children():
					if button is Button and String(button.text) == text:
						return button
	return null
