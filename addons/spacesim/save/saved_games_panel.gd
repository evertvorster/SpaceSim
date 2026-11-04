class_name SpacesimSavedGamesPanel
extends SpacesimScreen
## The histories the player has played, and the saves in them.
##
## Reached from a button on the personal-data screen, not by a key of its own: one screen for what
## the player is, one for what they have played.
##
## ## Histories above, saves below
##
## A history is a branch and a save is a commit on it, so this is one browser with two levels:
## choosing a history fills the saves list under it, and everything below the histories is about what
## is selected there. Stacked rather than side by side, because a save's label is a date and a place
## and it needs the whole width to be one readable line.
##
## ## The lists are a browser, and the file path is the ownership
##
## The world's own state is never among the paths a load touches, whatever is clicked here.
##
## ## Nothing is behind a right-click
##
## What a row can do is written on the screen: Play, Delete and the history's name field sit above
## the histories list, and a save's Load and Delete are in the dialog its own row opens — a menu
## beside a save could only repeat them. Entries that do not apply are **disabled rather than
## absent**: the current history cannot be played or deleted, and the trunk can be neither.

## A load, a switch or a new story moved the player, so whoever is flying the ship has to be told.
signal session_reloaded

const Dialog := preload("res://addons/spacesim/ui/dialog.gd")
const Repo := preload("res://addons/spacesim/save/world_repo.gd")
const Location := preload("res://addons/spacesim/coordinate/location.gd")

## A minimum, not the height: the saves list takes whatever is left, so the browser grows with the
## window instead of scrolling three rows at a time.
const LIST_HEIGHT := 96.0
const FIELD_HISTORY := "History name"
const FIELD_PLAYER := "Your name"

var _player: SpacesimPlayer
var _session: SpacesimSession
var _system: SpacesimSystemScene

var _dialog: SpacesimDialog
var _histories: ItemList
var _saves: ItemList
var _play_button: Button
var _delete_history_button: Button

## The history whose saves are being shown, and each list's rows. Kept because a row index means
## nothing on its own: it has to stay in step with the thing it stands for.
var _browsing: String = ""
var _history_names: Array = []
var _save_entries: Array = []

## What a dialog was opened about, and what it is about.
var _pending: String = ""
var _pending_history: String = ""
var _pending_hash: String = ""


func configure(player: SpacesimPlayer, session: SpacesimSession, system: SpacesimSystemScene) -> void:
	_player = player
	_session = session
	_system = system
	build_screen("Saved Games")
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
	# A save, a load and a delete all answer here, and the list behind the answer is already gone —
	# so the message is the only report of what happened.
	if not _session.message.is_empty():
		_add_heading(_session.message)
	_add_browser()


## Rebuild the screen, but not while a control inside [member content] is still emitting the signal
## that asked for it: [method opened] frees everything in there, and a control cannot be freed from
## inside its own signal.
func _rebuild() -> void:
	opened.call_deferred()


# --- the browser -----------------------------------------------------------------------------------

func _add_browser() -> void:
	# Before the lists, because the rename field shows what is being browsed.
	if _browsing.is_empty() or not _session.repo.has_history(_browsing):
		_browsing = _session.repo.current_history()

	_add_histories()
	_add_saves()
	_fill_browser()


func _add_histories() -> void:
	# **One row for everything you can do to the browsed history**, so what acts on the list is
	# beside it rather than under both lists. A history's name is a branch name, and renaming one is
	# a `git branch -m` — the repository's business rather than the save's — so it happens now and
	# says Rename.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	content.add_child(row)
	row.add_child(_title_label("Histories"))
	var controls := _name_field(_browsing, _rename_history, "Rename")
	controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(controls)
	_play_button = _add_action(row, "Play", _play_browsed)
	_delete_history_button = _add_action(row, "Delete", _delete_browsed_history)

	_histories = _new_list()
	_histories.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	content.add_child(_histories)
	# The selection is what the saves list and the rename field are about, so it is the only thing
	# this list emits; the buttons below act on it.
	_histories.item_selected.connect(_on_history_chosen)


func _add_saves() -> void:
	_add_heading("Saves — click one to see it")
	_saves = _new_list()
	_saves.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_saves)
	# item_clicked, not item_selected: clicking the same save twice should open it twice, and a
	# selection that has not changed emits nothing.
	_saves.item_clicked.connect(_on_save_clicked)


func _fill_browser() -> void:
	var current := _session.repo.current_history()

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
	# than a playthrough — git refuses to delete it, and playing there would leave the next startup
	# with nothing to load.
	_play_button.disabled = _browsing == current
	_delete_history_button.disabled = _browsing == current or _browsing == Repo.TRUNK


## The saves of a history, less the ones it has deleted. Only the history being played has
## tombstones to hand: they live in that history's own working tree, so another history's list is
## shown as it was left.
func _saves_of(history: String) -> Array:
	if history == _session.repo.current_history():
		return _session.saves()
	return _session.repo.saves(history)


func _on_history_chosen(index: int) -> void:
	if index < 0 or index >= _history_names.size():
		return
	_browsing = String(_history_names[index])
	# Everything below the lists is about what is selected, so the screen is rebuilt rather than
	# patched in four places.
	_rebuild()


## **The wheel is a click to this item list, so the button is what decides.** `ItemList::gui_input`
## emits `item_clicked` for a press over an item whatever the button, and it emits it from the branch
## a button that cannot select lands in — so a wheel notch while scrolling the saves opened the save
## under the cursor. (4.7.2, `scene/gui/item_list.cpp`, the `else if (closest != -1)` case. The
## histories list is safe because the wheel cannot reach `item_selected`.)
func _on_save_clicked(index: int, _at: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_LEFT or index < 0 or index >= _save_entries.size():
		return
	_saves.select(index)
	_show_save(index)


# --- histories -------------------------------------------------------------------------------------

func _rename_history(named: String) -> void:
	var renamed := _session.repo.rename_history(_browsing, named)
	if renamed["ok"]:
		_browsing = String(renamed["name"])
		_session.message = "renamed the history to %s" % _browsing
	else:
		_session.message = renamed["reason"]
	_rebuild()


func _play_browsed() -> void:
	var switched := _session.repo.switch_history(_browsing)
	if not switched["ok"]:
		_session.message = switched["reason"]
		_rebuild()
		return
	_session.message = "switched to %s" % _browsing
	_session.load_last()
	session_reloaded.emit()
	_rebuild()


func _delete_browsed_history() -> void:
	_pending = "delete_history"
	_pending_history = _browsing
	_dialog.ask(
		"Delete history",
		(
			"Delete '%s' and every save in it?\n\nThe history goes from the list. Its commits stay "
			% _browsing
			+ "in the repository, but nothing in the game will reach them again."
		),
		["Delete history", "Cancel"]
	)


# --- saves -----------------------------------------------------------------------------------------

## One dialog per save, holding what it is and what reading it means. **A load discards nothing** —
## the later saves are named as what a save from here *would* remove, and the asking happens at the
## Save button.
##
## This is also where a save's Load and Delete live: the row it belongs to is what opened it, so
## there is nothing a menu beside it could add.
func _show_save(index: int) -> void:
	var entry: Dictionary = _save_entries[index]
	_pending = "save_details"
	_pending_hash = String(entry["hash"])
	var playing := _browsing == _session.repo.current_history()
	var buttons := ["Close"] if not playing else ["Delete", "Load", "Close"]
	_dialog.ask("Save   %s" % entry["subject"], _save_details(_pending_hash, playing), buttons)


func _load(hash: String) -> void:
	var loaded := _session.load(hash)
	if loaded["ok"]:
		session_reloaded.emit()
	else:
		_session.message = loaded["reason"]


## What a save holds, and what reading it would cost — which is nothing. **Continuing from it is
## what costs**, and that is asked at the Save button, not here.
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
	lines.append("This is another history. Switch to it to load from it." if not playing else _load_note(hash))
	return "\n".join(lines)


## Reading any save is free, and the saves after it stay where they are. They go only when the
## story continues from here — which is why the warning belongs at the Save button, not at this one.
func _load_note(hash: String) -> String:
	var affected := _session.repo.affected_saves(hash, _session.repo.current_history())
	if affected.is_empty():
		return "Nothing was saved after this, so loading it costs nothing."
	var lines := PackedStringArray(
		["Loading this costs nothing. The %d save(s) after it stay:" % affected.size()]
	)
	for later in affected:
		lines.append("     %s" % later["subject"])
	lines.append("")
	lines.append("Saving from here would remove them, and the story would continue from this point.")
	lines.append("The world is not rewound — what you did to it stays done.")
	return "\n".join(lines)


# --- the dialogs -----------------------------------------------------------------------------------

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
				_browsing = _session.repo.current_history()
				session_reloaded.emit()
			else:
				_session.message = started["reason"]
		"delete_history":
			var deleted := _session.repo.delete_history(_pending_history)
			if deleted["ok"]:
				_browsing = _session.repo.current_history()
				_session.message = "deleted the history %s" % _pending_history
			else:
				_session.message = deleted["reason"]
		"save_details":
			match action:
				"Load":
					_load(_pending_hash)
				"Delete":
					_session.delete_save(_pending_hash)
					_session.message = "deleted a save"
	_pending = ""
	opened()


## The player's name is optional at New Story: left empty they keep the default, and can change it
## on the personal-data screen whenever they like, because it is only a value of theirs.
func _player_name_from_dialog() -> String:
	var typed: String = _dialog.value(FIELD_PLAYER)
	return typed if not typed.is_empty() else SpacesimPlayer.DEFAULT_NAME


# --- rows -----------------------------------------------------------------------------------------

func _add_action(row: HBoxContainer, label: String, on_pressed: Callable) -> Button:
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
