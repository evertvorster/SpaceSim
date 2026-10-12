class_name SpacesimPlayerPanel
extends SpacesimScreen
## The player's own data: what they are, what they carry, and where it all is.
##
## The personal-data screen, on Tab. **This is where saving lives**, because a save is a deliberate
## act: there is no autosave and no save key, so the button here is the only way one happens.

var _player: SpacesimPlayer
var _session: SpacesimSession
var _world: SpacesimWorld


func configure(player: SpacesimPlayer, session: SpacesimSession, world: SpacesimWorld) -> void:
	_player = player
	_session = session
	_world = world
	build_screen("Personal data")
	add_button("Save", _on_save)
	add_button("Close", func() -> void: closed.emit())


## Nothing here is cached: the sections are rebuilt every time the screen opens, so a value that
## changed while it was hidden cannot be shown stale.
func opened() -> void:
	for child in content.get_children():
		child.free()

	_add_heading("%s   %s" % [_session.repo.current_history(), _world.format_time(_session.world_time)])
	_add_section("Attributes", ["Attribute", "Value"], _attribute_rows(_player.attributes))
	_add_section("Assets", ["Name", "Type", "Value", "Where"], _asset_rows(_player.assets))
	_add_heading(_world.describe(_player.location, _player.assets))
	if not _session.message.is_empty():
		_add_heading(_session.message)


func _on_save() -> void:
	_session.save(_world)
	opened()


func _add_heading(text: String) -> void:
	var heading := Label.new()
	heading.text = text
	heading.add_theme_font_size_override("font_size", 16)
	content.add_child(heading)


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
