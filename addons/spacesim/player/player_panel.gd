class_name SpacesimPlayerPanel
extends SpacesimScreen
## The player's own data: what they are, what they carry, and the histories they have played.
##
## The personal-data screen, on Tab. **This is where saving lives**, because a save is a deliberate
## act: there is no autosave and no save key, so the button here is the only way one happens.
##
## The two lists are a browser rather than a thing in themselves — **the file path is the ownership**,
## so the world's own state is never among the paths a load touches, whatever is clicked here.

## A load or a switch moved the player, so whoever is flying the ship has to be told.
signal session_reloaded

const Dialog := preload("res://addons/spacesim/ui/dialog.gd")
const Repo := preload("res://addons/spacesim/save/world_repo.gd")
const Location := preload("res://addons/spacesim/coordinate/location.gd")

const LIST_HEIGHT := 150.0
const FIELD_HISTORY := "History name"
const FIELD_PLAYER := "Your name"

var _player: SpacesimPlayer
var _session: SpacesimSession
var _world: SpacesimWorld

var _dialog: SpacesimDialog
var _histories: ItemList
var _saves: ItemList
var _switch_button: Button
var _rename_button: Button
var _delete_button: Button

## The history whose saves are being shown, and its saves as displayed. Kept because the rows and
## the entries have to stay in step: an index into an ItemList means nothing on its own.
var _browsing: String = ""
var _history_names: Array = []
var _save_entries: Array = []

## What a dialog was opened about, and what to do with the answer.
var _pending: String = ""
var _pending_history: String = ""


func configure(player: SpacesimPlayer, session: SpacesimSession, world: SpacesimWorld) -> void:
	_player = player
	_session = session
	_world = world
	build_screen("Personal data")
	add_button("Save", _on_save)
	add_button("New Story", _on_new_story)
	add_button("Close", func() -> void: closed.emit())

	_dialog = Dialog.new()
	_dialog.visible = false
	_dialog.answered.connect(_on_dialog_answered)
	_dialog.input_changed.connect(_on_dialog_input)
	add_child(_dialog)


## Nothing here is cached: the sections are rebuilt every time the screen opens, so a value that
## changed while it was hidden cannot be shown stale.
func opened() -> void:
	for child in content.get_children():
		child.free()

	_add_heading("%s   %s" % [_session.repo.current_history(), _world.format_time(_session.world_time)])
	_add_heading(_world.describe(_player.location, _player.assets))
	if not _session.message.is_empty():
		_add_heading(_session.message)

	_add_section("Attributes", ["Attribute", "Value"], _attribute_rows(_player.attributes))
	_add_section("Assets", ["Name", "Type", "Value", "Where"], _asset_rows(_player.assets))
	_add_browser()


# --- the browser ---------------------------------------------------------------------------------

func _add_browser() -> void:
	var columns := HBoxContainer.new()
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 24)
	content.add_child(columns)

	# The histories, and what can be done to the selected one. Switching to where you already are is
	# what you are doing, and the trunk is the world rather than a playthrough, so those are the two
	# that get disabled.
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(left)
	left.add_child(_title_label("Histories"))
	_histories = _new_list()
	left.add_child(_histories)
	_histories.item_selected.connect(_on_history_chosen)
	var history_buttons := HBoxContainer.new()
	left.add_child(history_buttons)
	_switch_button = _new_button(history_buttons, "Switch", _on_switch)
	_rename_button = _new_button(history_buttons, "Rename", _on_rename)
	_delete_button = _new_button(history_buttons, "Delete", _on_delete_history)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(right)
	right.add_child(_title_label("Saves"))
	_saves = _new_list()
	right.add_child(_saves)
	_saves.item_selected.connect(_on_save_chosen)

	_fill_browser()


## A scrolling list: fixed height, so a long one gets a scrollbar of its own rather than pushing
## everything below it off the panel.
func _new_list() -> ItemList:
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(0.0, LIST_HEIGHT)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return list


static func _new_button(row: HBoxContainer, text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(on_pressed)
	row.add_child(button)
	return button


func _fill_browser() -> void:
	var current := _session.repo.current_history()
	if _browsing.is_empty() or not _session.repo.has_history(_browsing):
		_browsing = current

	_histories.clear()
	_history_names.clear()
	var chosen := -1
	for entry in _session.repo.histories():
		var name := String(entry["name"])
		_histories.add_item("%s%s" % [name, "   (playing)" if bool(entry["current"]) else ""])
		_history_names.append(name)
		if name == _browsing:
			chosen = _history_names.size() - 1
	if chosen >= 0:
		_histories.select(chosen)

	_saves.clear()
	_save_entries.clear()
	for entry in _saves_of(_browsing):
		_saves.add_item("%s" % entry["subject"])
		_save_entries.append(entry)

	# Switching to where you already are is what you are doing, and the trunk is the world rather
	# than a playthrough — so neither is offered.
	var playing := _browsing == current
	var trunk := _browsing == Repo.TRUNK
	_switch_button.disabled = playing
	_rename_button.disabled = trunk
	_delete_button.disabled = playing or trunk


## The saves of a history, less the ones it has deleted. Only the history being played has
## tombstones to hand: they live in that history's own working tree, so another history's list is
## shown as it was left.
func _saves_of(history: String) -> Array:
	if history == _session.repo.current_history():
		return _session.saves()
	return _session.repo.saves(history)


func _on_history_chosen(index: int) -> void:
	if index >= 0 and index < _history_names.size():
		_browsing = String(_history_names[index])
		_fill_browser()


func _on_switch() -> void:
	var switched := _session.repo.switch_history(_browsing)
	_session.message = switched["reason"] if not switched["ok"] else "switched to %s" % _browsing
	if switched["ok"]:
		_session.load_last()
		session_reloaded.emit()
	opened()


func _on_rename() -> void:
	_pending = "rename"
	_pending_history = _browsing
	_dialog.ask(
		"Rename a history",
		"What should '%s' be called?\n\nThe player's own name is separate, and is not changed here." % _browsing,
		["Rename", "Cancel"],
		[FIELD_HISTORY]
	)
	_dialog.focus_first_field()


func _on_delete_history() -> void:
	_pending = "delete_history"
	_pending_history = _browsing
	_dialog.ask(
		"Delete a history",
		"Delete '%s' and every save in it?\n\nThe history is gone from the list. Its commits stay in "
		% _browsing + "the repository, but nothing in the game will reach them again.",
		["Delete", "Cancel"]
	)


func _on_save_chosen(index: int) -> void:
	if index < 0 or index >= _save_entries.size():
		return
	var entry: Dictionary = _save_entries[index]
	var hash := String(entry["hash"])
	_pending = "save"
	_pending_history = _browsing

	var playing := _browsing == _session.repo.current_history()
	var affected := _session.repo.affected_saves(hash, _browsing) if playing else []
	var buttons := ["Close"] if not playing else ["Delete", "Load", "Close"]
	_dialog.ask("Save  %s" % entry["subject"], _save_details(hash, affected, playing), buttons)


## What a save holds, and — if loading it would cost anything — exactly what it would cost.
func _save_details(hash: String, affected: Array, playing: bool) -> String:
	var state := _session.preview(hash)
	var assets: Array = state.get("assets", [])
	var lines := PackedStringArray()
	lines.append("Attributes   %s" % _pairs(state.get("attributes", {})))
	lines.append("Assets       %s" % _asset_list(assets))
	lines.append("Location     %s" % _world.describe(Location.from_dictionary(state.get("location", {})), assets))

	if not playing:
		lines.append("")
		lines.append("This is another history. Switch to it to load from it.")
	elif affected.is_empty():
		lines.append("")
		lines.append("Loading this costs nothing: nothing was saved after it.")
	else:
		lines.append("")
		lines.append("Loading this discards %d later save(s), for good:" % affected.size())
		for later in affected:
			lines.append("     %s" % later["subject"])
		lines.append("")
		lines.append("The world is not rewound — what you did to it stays done.")
	return "\n".join(lines)


func _on_new_story() -> void:
	_pending = "new_story"
	_dialog.ask(
		"New Story",
		"Start a fresh world, without ending the one you are playing.",
		["Start", "Cancel"],
		[FIELD_HISTORY, FIELD_PLAYER]
	)
	_dialog.focus_first_field()
	_on_dialog_input()


# --- what the dialogs were asked ------------------------------------------------------------------

func _on_dialog_input() -> void:
	if _pending == "new_story" or _pending == "rename":
		var typed: String = _dialog.value(FIELD_HISTORY)
		_dialog.hint.text = "will be called '%s'" % SpacesimGit.slug(typed) if not typed.is_empty() else ""


func _on_dialog_answered(action: String) -> void:
	# Cancel, and closing a details dialog, share the one answer.
	if action.begins_with("Cancel") or action == "Close":
		_pending = ""
		return

	match _pending:
		"new_story":
			var started := _session.new_story(
				_dialog.value(FIELD_HISTORY), _world, _player_name_from_dialog()
			)
			if started["ok"]:
				session_reloaded.emit()
			else:
				_session.message = started["reason"]
		"rename":
			var renamed := _session.repo.rename_history(
				_pending_history, _dialog.value(FIELD_HISTORY)
			)
			if renamed["ok"]:
				_browsing = String(renamed["name"])
				_session.message = "renamed to %s" % _browsing
			else:
				_session.message = renamed["reason"]
		"delete_history":
			var deleted := _session.repo.delete_history(_pending_history)
			if deleted["ok"]:
				_browsing = _session.repo.current_history()
				_session.message = "deleted %s" % _pending_history
			else:
				_session.message = deleted["reason"]
		"save":
			match action:
				"Load":
					var loaded := _session.load(_selected_hash())
					if loaded["ok"]:
						session_reloaded.emit()
					else:
						_session.message = loaded["reason"]
				"Delete":
					_session.delete_save(_selected_hash())
	_pending = ""
	_fill_browser()
	opened()


func _selected_hash() -> String:
	var chosen := _saves.get_selected_items()
	if chosen.is_empty():
		return ""
	var index: int = chosen[0]
	return String(_save_entries[index]["hash"]) if index < _save_entries.size() else ""


## The player's name is optional at New Story: left empty they keep the default, and can change it
## from this screen whenever they like, because it is only an attribute of theirs.
func _player_name_from_dialog() -> String:
	var typed: String = _dialog.value(FIELD_PLAYER)
	return typed if not typed.is_empty() else SpacesimPlayer.DEFAULT_NAME


func _on_save() -> void:
	_session.save(_world)
	opened()


# --- rows -----------------------------------------------------------------------------------------

func _add_heading(text: String) -> void:
	content.add_child(_title_label(text))


func _title_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	return label


## A heading, then a table of the rows under it. The headers say what the columns are, so a
## section with more columns reads without this file changing.
func _add_section(title: String, headers: Array, rows: Array) -> void:
	_add_heading(title)

	var grid := GridContainer.new()
	grid.columns = headers.size()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 4)
	content.add_child(grid)

	for header in headers:
		var header_label := Label.new()
		header_label.text = String(header)
		header_label.modulate = Color(1.0, 1.0, 1.0, 0.55)
		grid.add_child(header_label)

	for row in rows:
		for cell in row:
			var cell_label := Label.new()
			cell_label.text = String(cell)
			grid.add_child(cell_label)


func _attribute_rows(attributes: Dictionary) -> Array:
	var rows: Array = []
	for key in attributes:
		rows.append([key, str(attributes[key])])
	return rows


## An asset reads as its own name, type, value and where it is, so the panel does not need to know
## what an asset is.
func _asset_rows(assets: Array) -> Array:
	var rows: Array = []
	for asset in assets:
		rows.append(
			[
				String(asset.get("name", "?")),
				String(asset.get("type", "")),
				str(asset.get("value", 0)),
				_world.describe(SpacesimLocation.from_dictionary(asset.get("location", {})), assets),
			]
		)
	return rows


static func _pairs(attributes: Dictionary) -> String:
	var parts := PackedStringArray()
	for key in attributes:
		parts.append("%s %s" % [key, attributes[key]])
	return ", ".join(parts)


static func _asset_list(assets: Array) -> String:
	if assets.is_empty():
		return "none"
	var names := PackedStringArray()
	for asset in assets:
		names.append(String(asset.get("name", "?")))
	return ", ".join(names)
