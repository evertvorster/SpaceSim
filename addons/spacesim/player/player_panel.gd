class_name SpacesimPlayerPanel
extends SpacesimScreen
## The player's own data: what they are, what they carry, and the histories they have played.
##
## The personal-data screen, on Tab. **This is where saving lives**, because a save is a deliberate
## act: there is no autosave and no save key, so the button here is the only way one happens.
##
## **What you can do to a row lives on the row**, as a right-click menu. That is not only tidier: a
## menu is opened *on* something, so there is no separate selection that can be empty and leave an
## action doing nothing at all.
##
## The two renames are different things and are named differently: **Rename history** is on a history
## row, and the player's own name is a value of theirs, changed with *Change my values*.
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
const FIELD_ASSET := "Name"

enum HistoryAction { PLAY, RENAME, DELETE }
enum SaveAction { DETAILS, LOAD, DELETE }
enum AssetAction { RENAME }

var _player: SpacesimPlayer
var _session: SpacesimSession
var _system: SpacesimSolarSystem

var _dialog: SpacesimDialog
var _assets: ItemList
var _histories: ItemList
var _saves: ItemList
var _history_menu: PopupMenu
var _save_menu: PopupMenu
var _asset_menu: PopupMenu

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

## The row a menu was opened on, so an answer knows what it was about.
var _menu_history: String = ""
var _menu_hash: String = ""
var _menu_asset: String = ""


func configure(player: SpacesimPlayer, session: SpacesimSession, system: SpacesimSolarSystem) -> void:
	_player = player
	_session = session
	_system = system
	build_screen("Personal data")
	add_button("Save", _on_save)
	add_button("New Story", _on_new_story)
	add_button("Close", func() -> void: closed.emit())

	_history_menu = _build_history_menu()
	_save_menu = _build_save_menu()
	_asset_menu = _build_asset_menu()

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

	_add_heading("%s   %s" % [_session.repo.current_history(), _system.format_time(_session.world_time)])
	_add_heading(_system.describe(_player.location, _player.assets))
	if not _session.message.is_empty():
		_add_heading(_session.message)

	_add_section("Attributes", ["Attribute", "Value"], _attribute_rows(_player.attributes))
	_button_under("Change my values", _on_change_attributes)
	_add_assets()
	_add_browser()


# --- the player's own values ----------------------------------------------------------------------

## Every value of the player's, the name among them. Not the history's name: that is a label on a
## timeline, and it is renamed on its own row.
func _on_change_attributes() -> void:
	var keys: Array = _player.attributes.keys()
	_pending = "change_attributes"
	_dialog.ask(
		"Change my values",
		"Everything of your own. A number stays a number.\n\nThe history's name is separate — rename "
		+ "that on its own row.",
		["Apply", "Cancel"],
		keys
	)
	for key in keys:
		_dialog.set_value(String(key), str(_player.attributes[key]))
	_dialog.focus_first_field()


func _apply_attributes() -> void:
	for key in _player.attributes.keys():
		var original: Variant = _player.attributes[key]
		var typed: String = _dialog.value(String(key))
		_player.attributes[key] = _coerce(original, typed)
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


func _add_assets() -> void:
	_add_heading("Assets — right-click one for what you can do with it")
	_assets = _new_list()
	content.add_child(_assets)
	_assets.item_clicked.connect(_on_asset_clicked)

	_assets.clear()
	_asset_ids.clear()
	for asset in _player.assets:
		_assets.add_item(_asset_line(asset))
		_asset_ids.append(String(asset.get("id", "")))


func _on_asset_clicked(index: int, at: Vector2, button: int) -> void:
	if index < 0 or index >= _asset_ids.size():
		return
	_assets.select(index)
	_menu_asset = String(_asset_ids[index])
	if button == MOUSE_BUTTON_RIGHT:
		_refresh_menu_state()
		_popup(_asset_menu, at)


## The id is what locations point at, so a rename cannot break one — which is the whole reason an
## asset has an id at all.
func _asset_of(id: String) -> Dictionary:
	return _player.asset_by_id(id)


func _rename_asset() -> void:
	var asset := _asset_of(_menu_asset)
	if asset.is_empty():
		return
	_pending = "rename_asset"
	_pending_asset = _menu_asset
	_dialog.ask("Rename this", "What should it be called?", ["Rename", "Cancel"], [FIELD_ASSET])
	_dialog.set_value(FIELD_ASSET, String(asset.get("name", "")))
	_dialog.focus_first_field()


func _apply_asset_name() -> void:
	var asset := _asset_of(_pending_asset)
	if asset.is_empty():
		return
	asset["name"] = _dialog.value(FIELD_ASSET)
	_session.message = "changed — press Save"


# --- the browser -----------------------------------------------------------------------------------

func _add_browser() -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 24)
	content.add_child(row)
	_add_histories(row)
	_add_saves(row)
	_fill_browser()


func _add_histories(row: HBoxContainer) -> void:
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left)
	left.add_child(_title_label("Histories — right-click one"))
	_histories = _new_list()
	left.add_child(_histories)
	_histories.item_selected.connect(_on_history_chosen)
	_histories.item_clicked.connect(_on_history_clicked)


func _add_saves(row: HBoxContainer) -> void:
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)
	right.add_child(_title_label("Saves — click one to see it, right-click for more"))
	_saves = _new_list()
	right.add_child(_saves)
	# item_clicked, not item_selected: clicking the same save twice should open it twice, and a
	# selection that has not changed emits nothing.
	_saves.item_clicked.connect(_on_save_clicked)


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

	_refresh_menu_state()


## Which of the menu entries apply to the row it was opened on.
func _refresh_menu_state() -> void:
	var playing := _browsing == _session.repo.current_history()
	var trunk := _browsing == Repo.TRUNK
	# Switching to where you already are is what you are doing, and the trunk is the world rather
	# than a playthrough, so neither is offered.
	_history_menu.set_item_disabled(HistoryAction.PLAY, playing)
	_history_menu.set_item_disabled(HistoryAction.DELETE, playing or trunk)
	_asset_menu.set_item_disabled(AssetAction.RENAME, _menu_asset.is_empty())
	# A save in another history cannot be loaded from here — you switch history, then pick a save.
	_save_menu.set_item_disabled(SaveAction.LOAD, not playing)
	_save_menu.set_item_disabled(SaveAction.DELETE, not playing)


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


func _on_history_clicked(index: int, at: Vector2, button: int) -> void:
	if index < 0 or index >= _history_names.size():
		return
	_on_history_chosen(index)
	_menu_history = String(_history_names[index])
	if button == MOUSE_BUTTON_RIGHT:
		_refresh_menu_state()
		_popup(_history_menu, at)


func _on_save_clicked(index: int, at: Vector2, button: int) -> void:
	if index < 0 or index >= _save_entries.size():
		return
	_saves.select(index)
	_menu_hash = String(_save_entries[index]["hash"])
	if button == MOUSE_BUTTON_RIGHT:
		_refresh_menu_state()
		_popup(_save_menu, at)
	else:
		_show_save(index)


func _popup(menu: PopupMenu, at: Vector2) -> void:
	menu.position = Vector2i(get_screen_position() + at)
	menu.popup()


# --- the menus -------------------------------------------------------------------------------------

func _build_history_menu() -> PopupMenu:
	var menu := PopupMenu.new()
	menu.add_item("Play this history", HistoryAction.PLAY)
	menu.add_item("Rename history…", HistoryAction.RENAME)
	menu.add_item("Delete history…", HistoryAction.DELETE)
	menu.id_pressed.connect(_on_history_action)
	add_child(menu)
	return menu


func _build_save_menu() -> PopupMenu:
	var menu := PopupMenu.new()
	menu.add_item("Show this save", SaveAction.DETAILS)
	menu.add_item("Load this save…", SaveAction.LOAD)
	menu.add_item("Delete this save", SaveAction.DELETE)
	menu.id_pressed.connect(_on_save_action)
	add_child(menu)
	return menu


func _build_asset_menu() -> PopupMenu:
	var menu := PopupMenu.new()
	menu.add_item("Rename this…", AssetAction.RENAME)
	menu.id_pressed.connect(_on_asset_action)
	add_child(menu)
	return menu


func _on_history_action(action: int) -> void:
	match action:
		HistoryAction.PLAY:
			_switch_to(_menu_history)
		HistoryAction.RENAME:
			_rename_history(_menu_history)
		HistoryAction.DELETE:
			_delete_history(_menu_history)


func _on_save_action(action: int) -> void:
	match action:
		SaveAction.DETAILS:
			_show_save_row()
		SaveAction.LOAD:
			_confirm_load(_menu_hash)
		SaveAction.DELETE:
			_pending = "confirm_delete_save"
			_pending_hash = _menu_hash
			_dialog.ask(
				"Delete this save?",
				"Take it out of the list?\n\nIts commit stays in the repository.",
				["Delete", "Cancel"]
			)


func _on_asset_action(action: int) -> void:
	if action == AssetAction.RENAME:
		_rename_asset()


func _show_save_row() -> void:
	for index in _save_entries.size():
		if String(_save_entries[index]["hash"]) == _menu_hash:
			_show_save(index)
			return


## One dialog per save, holding what it is and what loading it would cost. **Load is never one
## click away from a surprise** — what it discards is named before it happens.
func _show_save(index: int) -> void:
	var entry: Dictionary = _save_entries[index]
	_pending = "save_details"
	_pending_hash = String(entry["hash"])
	var playing := _browsing == _session.repo.current_history()
	var buttons := ["Close"] if not playing else ["Delete", "Load", "Close"]
	_dialog.ask("Save   %s" % entry["subject"], _save_details(_pending_hash, playing), buttons)


func _switch_to(name: String) -> void:
	var switched := _session.repo.switch_history(name)
	_session.message = switched["reason"] if not switched["ok"] else "switched to %s" % name
	if switched["ok"]:
		_browsing = name
		_session.load_last()
		session_reloaded.emit()
	_fill_browser()
	opened()


## Renames the **history** — a label on a timeline. The player's own name is a value of theirs and is
## changed under Attributes, which is a different thing entirely.
func _rename_history(name: String) -> void:
	_pending = "rename"
	_pending_history = name
	_dialog.ask(
		"Rename history",
		"What should the history '%s' be called?\n\nThis is the label on this line of time. Your own "
		% name + "name is not changed here — it lives under Attributes.",
		["Rename history", "Cancel"],
		[FIELD_HISTORY]
	)
	_dialog.set_value(FIELD_HISTORY, name)
	_dialog.focus_first_field()


func _delete_history(name: String) -> void:
	_pending = "delete_history"
	_pending_history = name
	_dialog.ask(
		"Delete history",
		"Delete '%s' and every save in it?\n\nThe history goes from the list. Its commits stay in "
		% name + "the repository, but nothing in the game will reach them again.",
		["Delete history", "Cancel"]
	)


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
		"Where        %s" % _system.describe(Location.from_dictionary(state.get("location", {})), assets)
	)
	lines.append("")
	lines.append("This is another history. Switch to it to load from it." if not playing else _load_cost(hash))
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
	if _pending == "new_story":
		var typed: String = _dialog.value(FIELD_HISTORY)
		_dialog.hint.text = "will be called '%s'" % SpacesimGit.slug(typed) if not typed.is_empty() else ""


func _on_dialog_answered(action: String) -> void:
	if action.begins_with("Cancel") or action == "Close":
		_pending = ""
		return

	match _pending:
		"new_story":
			var started := _session.new_story(
				_dialog.value(FIELD_HISTORY), _system, _player_name_from_dialog()
			)
			if started["ok"]:
				session_reloaded.emit()
			else:
				_session.message = started["reason"]
		"rename":
			var renamed := _session.repo.rename_history(_pending_history, _dialog.value(FIELD_HISTORY))
			if renamed["ok"]:
				_browsing = String(renamed["name"])
				_session.message = "renamed the history to %s" % _browsing
			else:
				_session.message = renamed["reason"]
		"delete_history":
			var deleted := _session.repo.delete_history(_pending_history)
			if deleted["ok"]:
				_browsing = _session.repo.current_history()
				_session.message = "deleted the history %s" % _pending_history
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


## The player's name is optional at New Story: left empty they keep the default, and can change it
## here whenever they like, because it is only a value of theirs.
func _player_name_from_dialog() -> String:
	var typed: String = _dialog.value(FIELD_PLAYER)
	return typed if not typed.is_empty() else SpacesimPlayer.DEFAULT_NAME


func _on_save() -> void:
	_session.save(_system)
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
	var button := Button.new()
	button.text = label
	button.pressed.connect(on_pressed)
	row.add_child(button)
	return button


func _new_list() -> ItemList:
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(0.0, LIST_HEIGHT)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return list


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
	var where := _system.describe(
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
