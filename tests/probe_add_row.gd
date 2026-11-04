extends SceneTree
## Does **Add** produce a row once real frames are running?
##
## The suite calls `flush_rows()` by hand, which skips the thing that could be broken: whether `_process`
## runs at all inside the screen. This probe presses the button and then lets frames happen.
##
##     godot-double-mono --headless --path . --script res://tests/probe_add_row.gd

const SettingsPanel := preload("res://addons/spacesim/settings/settings_panel.gd")
const Settings := preload("res://addons/spacesim/settings/settings.gd")
const Store := preload("res://addons/spacesim/input/bindings_store.gd")
const Actions := preload("res://addons/spacesim/input/actions.gd")

var _panel: SpacesimSettingsPanel
var _game: Node
var _frame := 0


func _init() -> void:
	# The **real game scene**, because that is where the fault is reported: the panel on its own works.
	if OS.get_environment("PROBE_GAME") == "1":
		var scene: PackedScene = load("res://game/main.tscn")
		var game := scene.instantiate()
		get_root().add_child(game)
		_game = game
		return

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

	print("rows at build:            ", _rows_of("throttle_up"))
	var add: Button = _button("throttle_up", 0, "Add")
	print("add button found:         ", add != null)
	if add == null:
		quit()
		return
	add.pressed.emit()
	print("rows right after press:   ", _rows_of("throttle_up"))
	print("dirty flag set:           ", _panel.get("_rows_dirty"))
	print("extra rows:               ", _panel.get("_extra_rows"))


func _process(_delta: float) -> bool:
	_frame += 1
	if _game != null:
		return _game_frame()
	if _frame == 3:
		print("rows after 3 frames:      ", _rows_of("throttle_up"))
		print("dirty flag now:           ", _panel.get("_rows_dirty"))
		print("panel visible in tree:    ", _panel.is_visible_in_tree())
		print("panel is processing:      ", _panel.is_processing())
		return true
	return false


## Drive the screen **inside the real game scene**: open it the way the game does, then press Add.
func _game_frame() -> bool:
	if _frame < 3:
		return false
	if _frame == 3:
		_panel = _game.find_child("Settings", true, false)
		if _panel == null:
			print("PROBE: no settings screen found")
			return true
		_game.call("_open_screen", _panel)
		print("PROBE: screen open, rows ", _rows_of("throttle_up"), " visible ", _panel.is_visible_in_tree())
		return false
	if _frame == 5:
		var add: Button = _button("throttle_up", 0, "Add")
		print("PROBE: add button ", add != null)
		if add != null:
			add.pressed.emit()
			print("PROBE: dirty ", _panel.get("_rows_dirty"), " extras ", _panel.get("_extra_rows"))
		return false
	if _frame == 8:
		print("PROBE: rows after 3 more frames: ", _rows_of("throttle_up"))
		print("PROBE: processing ", _panel.is_processing(), " visible ", _panel.is_visible_in_tree())
		return true
	return false


func _rows_of(action: String) -> int:
	var count := 0
	for entry in _panel.get("_binding_rows"):
		if String(entry[0]) == action:
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
