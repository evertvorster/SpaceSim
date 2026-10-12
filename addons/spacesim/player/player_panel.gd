class_name SpacesimPlayerPanel
extends SpacesimScreen
## The player's own data: what they are and what they carry.
##
## The personal-data screen, on Tab. It is also where save and load will live.

var _player: SpacesimPlayer


func configure(player: SpacesimPlayer) -> void:
	_player = player
	build_screen("Personal data")
	add_button("Close", func() -> void: closed.emit())


## Nothing here is cached: the sections are rebuilt every time the screen opens, so a value that
## changed while it was hidden cannot be shown stale.
func opened() -> void:
	for child in content.get_children():
		child.free()

	_add_section("Attributes", ["Attribute", "Value"], _attribute_rows(_player.attributes))
	_add_section("Assets", ["Name", "Type", "Value"], _asset_rows(_player.assets))


## A heading, then a table of the rows under it. The headers say what the columns are, so a
## section with more columns reads without this file changing.
func _add_section(title: String, headers: Array, rows: Array) -> void:
	var heading := Label.new()
	heading.text = title
	heading.add_theme_font_size_override("font_size", 16)
	content.add_child(heading)

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


## An asset reads as its own name, type and value, so the panel does not need to know what an
## asset is.
func _asset_rows(assets: Array) -> Array:
	var rows: Array = []
	for asset in assets:
		rows.append(
			[
				String(asset.get("name", "?")),
				String(asset.get("type", "")),
				str(asset.get("value", 0)),
			]
		)
	return rows
