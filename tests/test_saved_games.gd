extends RefCounted
## The Saved Games screen: the histories above, the saves in them below, and what either can do.
##
## Against a real git repository in a temp directory, like the session suite — a save is a commit, and
## a browser over mocked commits proves nothing.

const Session := preload("res://addons/spacesim/save/session.gd")
const Repo := preload("res://addons/spacesim/save/world_repo.gd")
const SavedGames := preload("res://addons/spacesim/save/saved_games_panel.gd")
const PlayerPanel := preload("res://addons/spacesim/player/player_panel.gd")
const Ui := preload("res://tests/ui_fixture.gd")

const SYSTEM_PATH := "res://systems/playground.tres"
const TEST_ROOT := "/tmp/spacesim-saved-games-test"


func run(h, root: Node) -> void:
	print("  saved games")
	_clean()
	var system := SpacesimSystemScene.from_file(SYSTEM_PATH)
	system.build(root)

	_test_the_screen(h, root, system)
	_test_the_lists_are_stacked(h, root, system)
	_test_renaming_a_history(h, root, system)
	_test_the_saves_list_ignores_the_wheel(h, root, system)
	_test_saving_from_this_screen(h, root, system)
	_test_a_dialog_close_only_closes_the_dialog(h, root, system)
	_test_the_player_screen_opens_it(h, root, system)

	system.container.free()
	_clean()


## The screen itself: what it lists, what it offers, and that a dialog opens inside it.
func _test_the_screen(h, root: Node, system: SpacesimSystemScene) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var session := _session()
	session.start(system)
	# Something in both lists: a browser that cannot be opened proves nothing.
	session.player.attributes["Credits"] = 7
	session.save(system)

	var panel := _panel(layer, session, system)

	var labels: Array = []
	for button in panel.actions.get_children():
		labels.append(String(button.text))
	h.check(
		labels == ["Save", "New Story", "Close"],
		"the screen has Save, New Story and Close (%s)" % str(labels)
	)
	h.check(Ui.shows(panel, "Histories") and Ui.shows(panel, "Saves"), "and both lists")

	# **Nothing is hidden behind a right-click.** What a row can do is on the screen, in words.
	h.check(Ui.menus(panel).is_empty(), "with no menus behind a right-click")
	h.check(
		Ui.buttons(panel, "Play").size() == 1 and Ui.buttons(panel, "Delete").size() == 1,
		"the history's actions are buttons beside it"
	)
	# The word says what commits it: a history's name is a branch rename, so it is not an Apply.
	h.check(Ui.buttons(panel, "Rename").size() == 1, "and renaming one says Rename, because it happens now")
	var play: Button = Ui.buttons(panel, "Play")[0]
	var delete: Button = Ui.buttons(panel, "Delete")[0]
	h.check(
		play.disabled and delete.disabled,
		"both inactive on the history being played, which cannot be switched to or deleted"
	)

	h.check(Ui.shows(panel, Session.FIRST_HISTORY), "the history being played is listed")
	h.check(Ui.shows(panel, "(playing)"), "and marked as the one being played")
	# The whole label, not a fragment of it — "in space" also appears in the date, so a fragment
	# would pass without the save row existing at all.
	h.check(Ui.shows(panel, session.label(system)), "and the save in it is by its whole label")

	# **A dialog is inside the screen it is over.** Its panel is centred on the dialog's own rect, so
	# a dialog that has collapsed to nothing puts its panel off the corner of the window — which is
	# what happened while `build_screen` used `set_anchors_preset`, whose default is to keep the rect
	# a control already has, and a control that has just been made has none.
	panel._show_save(0)
	var dialog: SpacesimDialog = panel._dialog
	h.check(
		dialog.size == panel.size,
		"a dialog covers the screen it is over (%s against %s)" % [str(dialog.size), str(panel.size)]
	)
	var box: Control = dialog.get_node("Panel")
	h.check(
		box.get_global_rect().get_center().distance_to(dialog.get_global_rect().get_center()) < 1.0,
		"and its panel is centred on it (%s in %s)" % [str(box.get_global_rect()), str(dialog.get_global_rect())]
	)

	var sections := panel.content.get_child_count()
	panel.opened()
	h.check(panel.content.get_child_count() == sections, "opening again rebuilds rather than stacking")
	layer.free()


## **The order in the column is the browser's shape**: a history chooses what the saves below are
## about, so it is above them, and the saves list is the one that grows with the window. Layout has
## not run — the suite is synchronous — so this is the column's structure, not its pixels.
func _test_the_lists_are_stacked(h, root: Node, system: SpacesimSystemScene) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var session := _session()
	session.start(system)
	var panel := _panel(layer, session, system)

	var histories_at := panel.content.get_children().find(panel._histories)
	var saves_at := panel.content.get_children().find(panel._saves)
	h.check(
		histories_at >= 0 and saves_at >= 0 and histories_at < saves_at,
		"the histories are above the saves (%d, %d)" % [histories_at, saves_at]
	)
	h.check(
		panel._saves.size_flags_vertical == Control.SIZE_EXPAND_FILL
		and panel._histories.size_flags_vertical != Control.SIZE_EXPAND_FILL,
		"and the saves list is the one that takes the room the window has"
	)
	layer.free()


## A history's name is a branch name, so renaming it is a repository operation: it happens now and
## the button says Rename.
func _test_renaming_a_history(h, root: Node, system: SpacesimSystemScene) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var session := _session()
	session.start(system)
	var panel := _panel(layer, session, system)

	var history_name := session.repo.current_history()
	var history_field: LineEdit = Ui.field_holding(panel, history_name)
	h.check(history_field != null, "a history's name is a field")
	var rename: Button = history_field.get_parent().get_node("NameAction")
	h.check(
		rename.text == "Rename",
		"whose button says Rename, because a branch rename does not wait for anything"
	)
	h.check(rename.disabled, "and is inactive until the name differs")

	history_field.text = "mankind"
	history_field.text_changed.emit("mankind")
	rename.pressed.emit()
	h.check(session.repo.has_history("mankind"), "renaming it takes effect at once")
	h.check(not session.repo.has_history(history_name), "and the old name is gone")
	layer.free()


## The wheel is a scroll, not a choice. **`ItemList` emits `item_clicked` for a wheel notch over an
## item** — whatever the button — so scrolling a long list opened the save under the cursor. What is
## emitted here is the signal Godot's own `gui_input` emits, with the button it puts in it.
func _test_the_saves_list_ignores_the_wheel(h, root: Node, system: SpacesimSystemScene) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var session := _session()
	session.start(system)
	session.player.attributes["Credits"] = 7
	session.save(system)
	var panel := _panel(layer, session, system)

	var saves: ItemList = panel._saves
	h.check(saves.item_count > 0, "the saves list has a row to scroll over")
	saves.item_clicked.emit(0, Vector2.ZERO, MOUSE_BUTTON_WHEEL_DOWN)
	h.check(not panel._dialog.visible, "a wheel notch over a save does not open it")
	saves.item_clicked.emit(0, Vector2.ZERO, MOUSE_BUTTON_WHEEL_UP)
	h.check(not panel._dialog.visible, "and scrolling back does not either")
	saves.item_clicked.emit(0, Vector2.ZERO, MOUSE_BUTTON_LEFT)
	h.check(panel._dialog.visible, "while a left click still does")
	layer.free()


## **Save lives here, beside the list it writes into.** The world's state is what it writes, and the
## row appears where the player is looking.
func _test_saving_from_this_screen(h, root: Node, system: SpacesimSystemScene) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var session := _session()
	session.start(system)
	var panel := _panel(layer, session, system)
	var saves_before := session.saves().size()
	var rows_before := panel._saves.item_count

	session.player.attributes["Credits"] = 42
	var buttons: Array = Ui.buttons(panel, "Save")
	h.check(buttons.size() == 1, "the screen has one Save button")
	if not buttons.is_empty():
		buttons[0].pressed.emit()
	h.check(session.saves().size() == saves_before + 1, "pressing it writes a save")
	h.check(
		panel._saves.item_count == rows_before + 1,
		"and the new save is in the list behind the button (%d, was %d)"
			% [panel._saves.item_count, rows_before]
	)
	h.check(Ui.shows(panel, "saved"), "with the message saying it was written")
	layer.free()


## **Closing a dialog closes the dialog and nothing else.** A dialog sits over the screen it belongs
## to, and a Close that also shut the screen would make dismissing a question cost the list the player
## was browsing.
func _test_a_dialog_close_only_closes_the_dialog(h, root: Node, system: SpacesimSystemScene) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var session := _session()
	session.start(system)
	session.player.attributes["Credits"] = 7
	session.save(system)
	var panel := _panel(layer, session, system)
	panel.visible = true

	# An array rather than a counter: a lambda captures by value.
	var closes: Array = []
	panel.closed.connect(func() -> void: closes.append(1))

	panel._show_save(0)
	var dialog: SpacesimDialog = panel._dialog
	h.check(dialog.visible, "a save opens a dialog over the screen")
	var closers: Array = Ui.buttons(dialog, "Close")
	h.check(closers.size() == 1, "the dialog has one Close (%d)" % closers.size())
	if not closers.is_empty():
		closers[0].pressed.emit()
	h.check(not dialog.visible, "pressing it closes the dialog")
	h.check(closes.is_empty(), "and does not ask the scene to close the screen (%d)" % closes.size())
	h.check(panel.visible, "which is still up")

	# The screen's own Close is what changes screens, and it is a separate button.
	var screen_closers: Array = []
	for button in panel.actions.get_children():
		if String(button.text) == "Close":
			screen_closers.append(button)
	h.check(screen_closers.size() == 1, "the screen has its own Close")
	if not screen_closers.is_empty():
		screen_closers[0].pressed.emit()
	h.check(closes.size() == 1, "and that one asks the scene to change screens (%d)" % closes.size())

	# Closing the screen by any other route must not leave a dialog standing inside it.
	panel._show_save(0)
	panel.dismissed()
	h.check(not dialog.visible, "a screen closed underneath a dialog takes the dialog with it")
	layer.free()


## Reached from the personal-data screen through a button, which is the whole reason this screen has
## no key of its own.
func _test_the_player_screen_opens_it(h, root: Node, system: SpacesimSystemScene) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var session := _session()
	session.start(system)
	var player_screen := PlayerPanel.new()
	player_screen.configure(session.player, session, system)
	layer.add_child(player_screen)
	player_screen.opened()

	# An array rather than a counter: **a lambda captures by value**, so `asked += 1` inside one
	# would leave the outer number where it started.
	var asked: Array = []
	player_screen.saved_games_requested.connect(func() -> void: asked.append(1))
	var buttons: Array = Ui.buttons(player_screen, "Saved Games")
	h.check(buttons.size() == 1, "the personal-data screen has one Saved Games button")
	if not buttons.is_empty():
		buttons[0].pressed.emit()
	h.check(asked.size() == 1, "and pressing it asks for this screen (%d)" % asked.size())
	layer.free()


func _panel(
	layer: CanvasLayer, session: SpacesimSession, system: SpacesimSystemScene
) -> SpacesimSavedGamesPanel:
	var panel := SavedGames.new()
	panel.configure(session.player, session, system)
	layer.add_child(panel)
	panel.opened()
	return panel


func _session() -> SpacesimSession:
	return Session.new(Repo.new(TEST_ROOT))


func _clean() -> void:
	OS.execute("rm", PackedStringArray(["-rf", TEST_ROOT]))
