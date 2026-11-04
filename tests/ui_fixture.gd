extends RefCounted
## Finding things in a screen's tree, so a test asks what a person sees rather than holding a
## reference the screen might not build.
##
## **One copy, because two drifted the moment there were two suites**: `_shows` matched a fragment
## in one file and the whole text in another, and `_menus` took an accumulator in a third. A test
## helper with two meanings is a test that passes for a reason nobody chose.
##
## Static, because none of it carries state — `Ui.shows(panel, "Saves")`.

## Whether anything under `node` shows this fragment of text. Menus, fields and lists count: what a
## row can do lives in them, so a test that cannot see them cannot see the affordances.
static func shows(node: Node, fragment: String) -> bool:
	if node is Label and node.text.contains(fragment):
		return true
	if node is Button and node.text.contains(fragment):
		return true
	# A field shows what it holds as much as a label does.
	if node is LineEdit and node.text.contains(fragment):
		return true
	if node is ItemList:
		for index in node.item_count:
			if node.get_item_text(index).contains(fragment):
				return true
	if node is PopupMenu:
		for index in node.item_count:
			if node.get_item_text(index).contains(fragment):
				return true
	for child in node.get_children():
		if shows(child, fragment):
			return true
	return false


## Every button under `node` whose label is exactly this — a count is what most checks want.
static func buttons(node: Node, label: String) -> Array:
	var found: Array = []
	if node is Button and node.text == label:
		found.append(node)
	for child in node.get_children():
		found.append_array(buttons(child, label))
	return found


static func fields(node: Node) -> Array:
	var found: Array = []
	if node is LineEdit:
		found.append(node)
	for child in node.get_children():
		found.append_array(fields(child))
	return found


## The field holding this text, so a test can find one the way a person does — by what is in it.
static func field_holding(node: Node, text: String) -> LineEdit:
	if node is LineEdit and node.text == text:
		return node
	for child in node.get_children():
		var found := field_holding(child, text)
		if found != null:
			return found
	return null


static func menus(node: Node) -> Array:
	var found: Array = []
	if node is PopupMenu:
		found.append(node)
	for child in node.get_children():
		found.append_array(menus(child))
	return found
