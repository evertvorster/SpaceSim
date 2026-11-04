class_name SpacesimPlayerPanel
extends SpacesimScreen
## The player's own data: what they are, what they carry, and the way out of the game.
##
## **Nothing here is written or loaded.** A value you have belongs on this screen and a list you
## browse does not: the histories and their saves — and the **Save** button, since a save is a
## deliberate act and the row it writes appears in that list — are the Saved Games screen, one
## button away. One screen holding both made the browser scroll inside a screen that was already
## scrolling.
##
## **Exit Game is here rather than on the settings screen**, which is where it used to be. Settings
## is where a value is edited and throwing the edits away is Close's job; leaving the game is about
## the player, and this is the screen that is about the player.
##
## **Configuration is here as well as on its key.** This screen is where a player looks when they are
## not sure where something lives; the hotkey stays for the times they are.
##
## ## Only names are editable
##
## A name — the player's, an asset's — is the one thing a person legitimately types. Everything else
## a player has is a *gameplay* value: credits move when something is bought, condition when
## something is damaged, knowledge when something is learned. Typing into those would be a cheat
## with extra steps, so they are shown and not offered.
##
## ## A name's button says what commits it
##
## The player's name and an asset's name are player state, so their button says **Apply** and it
## stages the change; **Save**, on the Saved Games screen, is what writes it. (A history's name is a
## repository operation, so it says *Rename* and happens at once — that one is there too, beside the
## list it renames.)
##
## Every one of those buttons is **disabled until its field differs** from what stands, so a control
## never offers to do nothing.

## The player asked for the saved-games screen. Whoever hosts this one opens it.
signal saved_games_requested
## The player asked for the settings screen, which is otherwise reached by its own key.
signal settings_requested
## The player asked to leave. Whoever hosts this screen tears the game down.
signal exit_requested

var _player: SpacesimPlayer
var _session: SpacesimSession
var _system: SpacesimSystemScene


func configure(player: SpacesimPlayer, session: SpacesimSession, system: SpacesimSystemScene) -> void:
	_player = player
	_session = session
	_system = system
	build_screen("Personal data")
	add_button("Saved Games", func() -> void: saved_games_requested.emit())
	add_button("Configuration", func() -> void: settings_requested.emit())
	add_button("Close", func() -> void: closed.emit())
	add_button("Exit Game", func() -> void: exit_requested.emit())


## Nothing here is cached: everything is rebuilt every time the screen opens, so a value that changed
## while it was hidden cannot be shown stale.
func opened() -> void:
	for child in content.get_children():
		child.free()

	# One line for where and when, because the screen is tall enough already and three heading lines
	# pushed what matters below the fold.
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


## Rebuild the screen, but not while a control inside [member content] is still emitting the signal
## that asked for it: [method opened] frees everything in there, and a control cannot be freed from
## inside its own signal. Found by the tests, which reported the object being freed mid-emit.
func _rebuild() -> void:
	opened.call_deferred()


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


func _set_player_name(named: String) -> void:
	if named.is_empty():
		# A player with no name reads as a bug everywhere their name is shown, so an empty field is
		# refused rather than written.
		_session.message = "a name cannot be empty"
		_rebuild()
		return
	_player.attributes[SpacesimPlayer.ATTRIBUTE_NAME] = named
	_session.message = "changed — not saved yet"
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
	_session.message = "changed — not saved yet"
	_rebuild()


func _asset_where(asset: Dictionary) -> String:
	return _system.describe(
		SpacesimLocation.from_dictionary(asset.get("location", {})), _player.assets
	)


# --- rows -----------------------------------------------------------------------------------------

func _text_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


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
