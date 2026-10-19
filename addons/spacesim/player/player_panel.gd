class_name SpacesimPlayerPanel
extends SpacesimScreen
## The player's own data: what they are, what they carry, and the histories they have played.
##
## The personal-data screen, on Tab. **This is where saving lives**, because a save is a deliberate
## act: there is no autosave and no save key, so the button here is the only way one happens.
##
## ## Only names are editable
##
## A name — the player's, an asset's, a history's — is the one thing a person legitimately types.
## Everything else a player has is a *gameplay* value: credits move when something is bought,
## condition when something is damaged, knowledge when something is learned. Typing into those would
## be a cheat with extra steps, so they are shown and not offered.
##
## ## Where a name is edited says what commits it
##
## The player's name and an asset's name are player state, so their button says **Apply**, it stages
## the change, and **Save** is what writes it. A history's name is a repository operation — a
## `git branch -m` — so its button says **Rename** and happens at once. That is a real difference
## rather than an inconsistency, and putting it in the button's word is the whole of how it is
## communicated.
##
## Every one of those buttons is **disabled until its field differs** from what stands, so a control
## never offers to do nothing.
##
## The lists are a browser, and **the file path is the ownership** — the world's own state is never
## among the paths a load touches, whatever is clicked here.

## A load, a switch or a new story moved the player, so whoever is flying the ship has to be told.
signal session_reloaded

const Dialog := preload("res://addons/spacesim/ui/dialog.gd")
const Repo := preload("res://addons/spacesim/save/world_repo.gd")
const Location := preload("res://addons/spacesim/coordinate/location.gd")

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

	# One line for where and when, because the screen is tall enough already and three heading lines
	# pushed the browser below the fold.
	_add_heading(
		"%s   %s   %s"
		% [
			_session.repo.current_history(),
			SpacesimWorldTime.format(_session.world_time),
			_system.describe(_player.location, _player.assets),
		]
	)
	if not _session.message.is_empty():
		_add_heading(_session.message)

	_add_attributes()
	_add_assets()
	_add_browser()


# --- the player's own values ----------------------------------------------------------------------

## Every value of the player's, in one table. **The name is the only cell that is a field** — the
## rest are shown because they are what the player has, and changed by playing rather than by typing.
func _add_attributes() -> void:
	var grid := _add_table("Attributes", ["Attribute", "Value"])
	for key in _player.attributes:
		var name_label := Label.new()
		name_label.text = String(key)
		grid.add_child(name_label)
		if String(key) == SpacesimPlayer.ATTRIBUTE_NAME:
			grid.add_child(_name_field(_player.display_name(), _set_player_name))
		else:
			grid.add_child(_text_label(str(_player.attributes[key])))


## Rebuild the screen, but not while a control inside [member content] is still emitting the signal
## that asked for it: [method opened] frees everything in there, and a control cannot be freed from
## inside its own signal. Found by the tests, which reported the object being freed mid-emit.
func _rebuild() -> void:
	opened.call_deferred()


func _set_player_name(named: String) -> void:
	if named.is_empty():
		# A player with no name reads as a bug everywhere their name is shown, so an empty field is
		# refused rather than written.
		_session.message = "a name cannot be empty"
		_rebuild()
		return
	_player.attributes[SpacesimPlayer.ATTRIBUTE_NAME] = named
	_session.message = "changed — press Save"
	_rebuild()


func _add_assets() -> void:
	var grid := _add_table("Assets", ["Name", "Type", "Value", "Location"])
	for asset in _player.assets:
		var id := String(asset.get("id", ""))
		grid.add_child(_name_field(String(asset.get("name", "")), _rename_asset.bind(id)))
		grid.add_child(_text_label(String(asset.get("type", ""))))
		grid.add_child(_text_label(str(asset.get("value", 0))))
		grid.add_child(_text_label(_asset_where(asset)))


## The id is what a location points at, so renaming cannot break one — which is the whole reason an
## asset has an id at all.
##
## `named` comes first because the id is bound onto this callable with [method Callable.bind], and
## **`bind` appends** — the bound arguments arrive after the one the call supplies.
func _rename_asset(named: String, id: String) -> void:
	var asset := _player.asset_by_id(id)
	if asset.is_empty() or named.is_empty():
		return
	asset["name"] = named
	_session.message = "changed — press Save"
	_rebuild()


func _asset_where(asset: Dictionary) -> String:
	return _system.describe(
		SpacesimLocation.from_dictionary(asset.get("location", {})), _player.assets
	)


# --- the browser -----------------------------------------------------------------------------------

func _add_browser() -> void:
	# Before the lists, because the rename field below them shows what is being browsed.
	if _browsing.is_empty() or not _session.repo.has_history(_browsing):
		_browsing = _session.repo.current_history()

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
	left.add_theme_constant_override("separation", 8)
	row.add_child(left)
	left.add_child(_title_label("Histories"))
	_histories = _new_list()
	left.add_child(_histories)
	# The selection is what the saves list and the rename field are about, so it is the only thing
	# this list emits; the buttons below act on it.
	_histories.item_selected.connect(_on_history_chosen)

	# **One row for everything you can do to the browsed history.** A history's name is a branch name,
	# and renaming one is a `git branch -m` — the repository's business rather than the save's — so
	# this one happens now and says Rename.
	var controls := _name_field(_browsing, _rename_history, "Rename")
	left.add_child(controls)
	_play_button = _add_action(controls, "Play", _play_browsed)
	_delete_history_button = _add_action(controls, "Delete", _delete_browsed_history)


func _add_saves(row: HBoxContainer) -> void:
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	row.add_child(right)
	right.add_child(_title_label("Saves — click one to see it"))
	_saves = _new_list()
	right.add_child(_saves)
	# item_clicked, not item_selected: clicking the same save twice should open it twice, and a
	# selection that has not changed emits nothing.
	_saves.item_clicked.connect(
		func(index: int, _at: Vector2, _button: int) -> void: _show_save_at(index)
	)


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


func _show_save_at(index: int) -> void:
	if index < 0 or index >= _save_entries.size():
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
		"confirm_save":
			_session.save_confirmed(_system)
	_pending = ""
	opened()


## The player's name is optional at New Story: left empty they keep the default, and can change it
## here whenever they like, because it is only a value of theirs.
func _player_name_from_dialog() -> String:
	var typed: String = _dialog.value(FIELD_PLAYER)
	return typed if not typed.is_empty() else SpacesimPlayer.DEFAULT_NAME


func _on_save() -> void:
	var written := _session.save(_system)
	# Continuing from an older save is what removes the later ones, so it is asked here — and asked
	# with their names, before anything is written.
	if written.get("needs_confirmation", false):
		_pending = "confirm_save"
		_dialog.ask("Save from here?", _rewrite_note(written["affected"]), ["Save", "Cancel"])
		return
	opened()


## What saving from where the story was loaded would remove. The mirror of [method _load_note]:
## reading is free, and continuing is what costs.
func _rewrite_note(affected: Array) -> String:
	var lines := PackedStringArray(
		["You loaded a save from the past, so the %d save(s) after it are removed:" % affected.size()]
	)
	for later in affected:
		lines.append("     %s" % later["subject"])
	lines.append("")
	lines.append("The story continues from where you loaded, and the world is not rewound.")
	return "\n".join(lines)


# --- rows -----------------------------------------------------------------------------------------

## A name, editable, with the button that commits it. The button is **disabled until the text
## differs**, so a control never offers to do nothing, and it says what it does: *Apply* stages a
## change that Save writes, *Rename* does it now.
##
## Enter in the field is the same as pressing it, when there is something to do.
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


func _add_heading(text: String) -> void:
	content.add_child(_title_label(text))


func _title_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	return label


func _text_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


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


## A heading, then a grid with its column headers. The caller adds the rows, because a row may hold
## a field rather than a label.
func _add_table(title: String, headers: Array) -> GridContainer:
	_add_heading(title)

	var grid := GridContainer.new()
	grid.columns = headers.size()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 6)
	content.add_child(grid)

	for header in headers:
		var header_label := Label.new()
		header_label.text = String(header)
		header_label.modulate = Color(1.0, 1.0, 1.0, 0.55)
		grid.add_child(header_label)
	return grid


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
