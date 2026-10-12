class_name SpacesimPlayerPanel
extends SpacesimScreen
## The player's own data: what they are, what they carry, and the histories they have played.
##
## The personal-data screen, on Tab. **This is where saving lives**, because a save is a deliberate
## act: there is no autosave and no save key, so the button here is the only way one happens.
##
## The name and what the player holds are variables, and variables are editable here — the player's
## own name, and what each of their things is called. An asset is *referred to* by its id, which is
## why renaming one is safe: nothing points at a name.
##
## The lists are a browser, and **the file path is the ownership** — the world's own state is never
## among the paths a load touches, whatever is clicked here.

## A load, a switch or a new story moved the player, so whoever is flying the ship has to be told.
signal session_reloaded

const Dialog := preload("res://addons/spacesim/ui/dialog.gd")
const Repo := preload("res://addons/spacesim/save/world_repo.gd")
const Location := preload("res://addons/spacesim/coordinate/location.gd")

const LIST_HEIGHT := 140.0
const FIELD_HISTORY := "History name"
const FIELD_PLAYER := "Your name"

var _player: SpacesimPlayer
var _session: SpacesimSession
var _world: SpacesimWorld

var _dialog: SpacesimDialog
var _assets: ItemList
var _histories: ItemList
var _saves: ItemList
var _switch_button: Button
var _rename_button: Button
var _delete_button: Button
var _load_button: Button
var _delete_save_button: Button
var _rename_asset_button: Button

## The history whose saves are being shown, and each list's rows. Kept because a row index means
## nothing on its own: it has to stay in step with the thing it stands for.
var _browsing: String = ""
var _history_names: Array = []
var _save_entries: Array = []
var _asset_ids: Array = []

## What a dialog was opened about, and what it is about.
var _pending: String = ""
var _pending_history: String = ""
var _pending_hash: String = ""
var _pending_asset: String = ""


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


## Nothing here is cached: everything is rebuilt every time the screen opens, so a value that changed
## while it was hidden cannot be shown stale.
func opened() -> void:
	for child in content.get_children():
		child.free()

	_add_heading("%s   %s" % [_session.repo.current_history(), _world.format_time(_session.world_time)])
	_add_heading(_world.describe(_player.location, _player.assets))
	if not _session.message.is_empty():
		_add_heading(_session.message)

	_add_section("Attributes", ["Attribute", "Value"], _attribute_rows(_player.attributes))
	_button_under("Change values", _on_change_attributes)
	_add_assets()
	_add_browser()


# --- what the player is, and what they hold -------------------------------------------------------

func _on_change_attributes() -> void:
	var keys: Array = _player.attributes.keys()
	_pending = "change_attributes"
	_dialog.ask(
		"Change values",
		"Everything except the history's own name. A number stays a number.",
		["Apply", "Cancel"],
		keys
	)
	for key in keys:
		_dialog.set_value(String(key), str(_player.attributes[key]))
	_dialog.focus_first_field()


func _add_assets() -> void:
	_add_heading("Assets")
	_assets = _new_list()
	content.add_child(_assets)
	_assets.item_clicked.connect(_on_asset_chosen)
	_assets.item_selected.connect(func(_index: int) -> void: _refresh_buttons())
	var row := HBoxContainer.new()
	content.add_child(row)
	_rename_asset_button = _new_button(row, "Rename", _on_rename_asset)

	_assets.clear()
	_asset_ids.clear()
	for asset in _player.assets:
		_assets.add_item(_asset_line(asset))
		_asset_ids.append(String(asset.get("id", "")))


func _on_asset_chosen(index: int, _at: Vector2, _button: int) -> void:
	_assets.select(index)
	_refresh_buttons()


func _on_rename_asset() -> void:
	var asset := _selected_asset()
	if asset.is_empty():
		return
	_pending = "rename_asset"
	_pending_asset = String(asset.get("id", ""))
	_dialog.ask("Rename", "What should it be called?", ["Rename", "Cancel"], ["Name"])
	_dialog.set_value("Name", String(asset.get("name", "")))
	_dialog.focus_first_field()


## The id is what locations point at, so a rename cannot break one — which is the whole reason an
## asset has an id at all.
func _selected_asset() -> Dictionary:
	var chosen := _assets.get_selected_items()
	if chosen.is_empty():
		return {}
	var index: int = chosen[0]
	if index >= _asset_ids.size():
		return {}
	return _player.asset_by_id(String(_asset_ids[index]))


# --- the browser ---------------------------------------------------------------------------------

func _add_browser() -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 24)
	content.add_child(row)
	_add_histories(row)
	_add_saves(row)
	_fill_browser()


## The histories, and what can be done to the selected one.
func _add_histories(row: HBoxContainer) -> void:
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left)
	left.add_child(_title_label("Histories"))
	_histories = _new_list()
	left.add_child(_histories)
	_histories.item_selected.connect(_on_history_chosen)
	var history_buttons := HBoxContainer.new()
	left.add_child(history_buttons)
	_switch_button = _new_button(history_buttons, "Switch", _on_switch)
	_rename_button = _new_button(history_buttons, "Rename", _on_rename)
	_delete_button = _new_button(history_buttons, "Delete", _on_delete_history)


## The saves, and what can be done to the selected one. Load is a button of its own rather than
## something you have to open a save to find.
func _add_saves(row: HBoxContainer) -> void:
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)
	right.add_child(_title_label("Saves"))
	_saves = _new_list()
	right.add_child(_saves)
	# item_clicked, not item_selected: clicking the same save twice should open it twice, and a
	# selection that has not changed emits nothing.
	_saves.item_clicked.connect(_on_save_clicked)
	_saves.item_selected.connect(func(_index: int) -> void: _refresh_buttons())
	var save_buttons := HBoxContainer.new()
	right.add_child(save_buttons)
	_load_button = _new_button(save_buttons, "Load", _on_load)
	_delete_save_button = _new_button(save_buttons, "Delete", _on_delete_save)


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

	_refresh_buttons()


func _refresh_buttons() -> void:
	var playing := _browsing == _session.repo.current_history()
	var trunk := _browsing == Repo.TRUNK
	# Switching to where you already are is what you are doing, and the trunk is the world rather
	# than a playthrough, so neither is offered.
	_switch_button.disabled = playing
	_rename_button.disabled = trunk
	_delete_button.disabled = playing or trunk
	# A save in another history cannot be loaded from here — you switch history, then pick a save.
	_load_button.disabled = not playing or _save_entries.is_empty()
	_delete_save_button.disabled = not playing or _save_entries.is_empty()
	_rename_asset_button.disabled = _assets.get_selected_items().is_empty()


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
		"What should '%s' be called?\n\nThe player's own name is separate, and is not changed here."
		% _browsing,
		["Rename", "Cancel"],
		[FIELD_HISTORY]
	)
	_dialog.set_value(FIELD_HISTORY, _browsing)
	_dialog.focus_first_field()


func _on_delete_history() -> void:
	_pending = "delete_history"
	_pending_history = _browsing
	_dialog.ask(
		"Delete a history",
		"Delete '%s' and every save in it?\n\nThe history goes from the list. Its commits stay in "
		% _browsing + "the repository, but nothing in the game will reach them again.",
		["Delete", "Cancel"]
	)


func _on_save_clicked(index: int, _at: Vector2, _button: int) -> void:
	if index < 0 or index >= _save_entries.size():
		return
	_saves.select(index)
	_show_save(index)


## One dialog per save, holding what it is and what loading it would cost. **Load is never one
## click away from a surprise** — what it discards is named before it happens.
func _show_save(index: int) -> void:
	var entry: Dictionary = _save_entries[index]
	var hash := String(entry["hash"])
	_pending = "save_details"
	_pending_hash = hash
	var playing := _browsing == _session.repo.current_history()
	var buttons := ["Close"] if not playing else ["Delete", "Load", "Close"]
	_dialog.ask("Save   %s" % entry["subject"], _save_details(hash, playing), buttons)


func _on_load() -> void:
	var hash := _selected_hash()
	if not hash.is_empty():
		_confirm_load(hash)


func _on_delete_save() -> void:
	var hash := _selected_hash()
	if hash.is_empty():
		return
	_pending = "confirm_delete_save"
	_pending_hash = hash
	_dialog.ask("Delete this save?", "Take it out of the list?\n\nIts commit stays in the repository.", ["Delete", "Cancel"])


func _confirm_load(hash: String) -> void:
	_pending = "confirm_load"
	_pending_hash = hash
	_dialog.ask("Load this save?", _load_cost(hash), ["Load", "Cancel"])


## What a save holds, and — if loading it would cost anything — exactly what it would cost.
func _save_details(hash: String, playing: bool) -> String:
	var state := _session.preview(hash)
	var assets: Array = state.get("assets", [])
	var lines := PackedStringArray()
	lines.append("Attributes   %s" % _pairs(state.get("attributes", {})))
	lines.append("Assets       %s" % _asset_list(assets))
	lines.append(
		"Where        %s" % _world.describe(Location.from_dictionary(state.get("location", {})), assets)
	)
	lines.append("")
	if not playing:
		lines.append("This is another history. Switch to it to load from it.")
	else:
		lines.append(_load_cost(hash))
	return "\n".join(lines)


func _load_cost(hash: String) -> String:
	var affected := _session.repo.affected_saves(hash, _session.repo.current_history())
	if affected.is_empty():
		return "Nothing was saved after this, so loading it costs nothing."
	var lines := PackedStringArray(["Loading this discards %d later save(s), for good:" % affected.size()])
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
			var renamed := _session.repo.rename_history(_pending_history, _dialog.value(FIELD_HISTORY))
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
		"change_attributes":
			_apply_attributes()
		"rename_asset":
			_apply_asset_name()
		"save_details":
			match action:
				"Load":
					_load(_pending_hash)
				"Delete":
					_session.delete_save(_pending_hash)
					_session.message = "deleted a save"
		"confirm_load":
			_load(_pending_hash)
		"confirm_delete_save":
			_session.delete_save(_pending_hash)
			_session.message = "deleted a save"
	_pending = ""
	_fill_browser()
	opened()


func _load(hash: String) -> void:
	var loaded := _session.load(hash)
	if loaded["ok"]:
		session_reloaded.emit()
	else:
		_session.message = loaded["reason"]


## An edit is not a save: saving stays a deliberate act, so the screen says so rather than writing
## one behind the player's back.
func _apply_attributes() -> void:
	for key in _player.attributes.keys():
		var original: Variant = _player.attributes[key]
		var typed: String = _dialog.value(String(key))
		_player.attributes[key] = _coerce(original, typed)
	_session.message = "changed — press Save"


func _apply_asset_name() -> void:
	var asset := _player.asset_by_id(_pending_asset)
	if asset.is_empty():
		return
	asset["name"] = _dialog.value("Name")
	_session.message = "changed — press Save"


## An attribute keeps the type it had: a name stays a name, and credits stay a number — refusing
## something that is not one rather than quietly reading it as zero.
static func _coerce(original: Variant, typed: String) -> Variant:
	match typeof(original):
		TYPE_INT:
			return int(typed) if typed.is_valid_int() else original
		TYPE_FLOAT:
			return float(typed) if typed.is_valid_float() else original
		_:
			return typed


func _selected_hash() -> String:
	var chosen := _saves.get_selected_items()
	if chosen.is_empty():
		return ""
	var index: int = chosen[0]
	return String(_save_entries[index]["hash"]) if index < _save_entries.size() else ""


## The player's name is optional at New Story: left empty they keep the default, and can change it
## here whenever they like, because it is only a value of theirs.
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


func _button_under(label: String, on_pressed: Callable) -> Button:
	var row := HBoxContainer.new()
	content.add_child(row)
	return _new_button(row, label, on_pressed)


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


## An asset reads as its own name, then what it is and where it is, so the panel does not need to
## know what an asset is.
func _asset_line(asset: Dictionary) -> String:
	var where := _world.describe(
		SpacesimLocation.from_dictionary(asset.get("location", {})), _player.assets
	)
	return "%s   —   %s, %s   —   %s" % [
		asset.get("name", "?"), asset.get("type", ""), asset.get("value", 0), where
	]


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
