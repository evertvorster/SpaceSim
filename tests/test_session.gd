extends RefCounted
## The session: one playthrough, its clock, and the saves that hold it.
##
## Runs against a real git repository in a temp directory, like the save suite — the point of the
## session is what it writes to git and what it reads back, so a mock would test nothing.

const Session := preload("res://addons/spacesim/save/session.gd")
const Repo := preload("res://addons/spacesim/save/world_repo.gd")
const Player := preload("res://addons/spacesim/player/player.gd")
const PlayerPanel := preload("res://addons/spacesim/player/player_panel.gd")
const Dialog := preload("res://addons/spacesim/ui/dialog.gd")
const Location := preload("res://addons/spacesim/coordinate/location.gd")
const PlayerShip := preload("res://game/player_ship.gd")

const SYSTEM_PATH := "res://systems/playground.tres"
const TEST_ROOT := "/tmp/spacesim-session-test"


func run(h, root: Node) -> void:
	print("  session")
	_clean()

	var system := SpacesimSystemScene.from_file(SYSTEM_PATH)
	system.build(root)
	var ship := PlayerShip.create()
	PlayerShip.place(system, ship)

	_test_first_run(h, system)
	_test_starting_again(h, system)
	_test_saving(h, system)
	_test_the_do_over(h, system)
	_test_deleting_a_save(h, system)
	_test_the_clock_moves_on(h, system)
	_test_putting_the_ship_back(h, system, ship)
	_test_the_browser(h, root, system)
	_test_the_dialog(h, root)

	system.container.free()
	_clean()


func _test_first_run(h, system: SpacesimSystemScene) -> void:
	var session := _session()
	h.check(not session.repo.exists(), "there is no repository to begin with")
	h.check(session.start(system)["ok"], "starting brings one up")
	h.check(session.repo.exists(), "and now there is one")
	h.check(session.repo.current_history() == Session.FIRST_HISTORY, "on the first history")
	h.check(session.message == "a new story", "reported as a new story")
	h.check(session.repo.saves().size() == 1, "with the first save already made, so there is something to load")
	h.check(session.player.display_name() == Player.DEFAULT_NAME, "and a player at their defaults")


func _test_starting_again(h, system: SpacesimSystemScene) -> void:
	var session := _session()
	h.check(session.start(system)["ok"], "starting again")
	h.check(session.message == "the last save", "picks up the last save rather than starting over")
	h.check(session.repo.current_history() == Session.FIRST_HISTORY, "on the same history")
	h.check(session.repo.histories().size() == 2, "and did not make another history")


func _test_saving(h, system: SpacesimSystemScene) -> void:
	var session := _session()
	session.player.attributes["Credits"] = 500
	session.player.location = Location.new("planet:terra/surface", Vector3(10.0, 0.0, 20.0))
	h.check(session.save(system)["ok"], "a save")
	h.check(session.message == "saved", "says so, rather than leaving the player guessing")
	h.check(session.save(system)["ok"] == false, "and saving again with nothing changed is refused")
	h.check(session.saves().size() == 2, "two saves are listed (%d)" % session.saves().size())
	h.check(session.label(system).contains("landed on Terra"), "a label says where you were: %s" % session.label(system))


func _test_the_do_over(h, system: SpacesimSystemScene) -> void:
	var session := _session()
	session.player.attributes["Credits"] = 999
	session.save(system)
	h.check(session.saves().size() == 3, "three saves")
	var oldest: String = session.saves()[2]["hash"]
	h.check(session.affected_saves(oldest).size() == 2, "and loading the oldest affects the two after it")

	var preview := session.preview(oldest)
	h.check(int(preview.get("attributes", {}).get("Credits", -1)) == 0, "a save can be looked at as it stood")

	h.check(session.load(oldest)["ok"], "loading it")
	h.check(
		session.saves().size() == 3,
		"removes nothing — the later saves stay (%d listed)" % session.saves().size()
	)
	h.check(session.player.attributes["Credits"] == 0, "and brings the player back to what they were")

	# Reading is free; it is *saving from here* that rewrites the timeline — and that asks first.
	session.player.attributes["Credits"] = 5
	var asked := session.save(system)
	h.check(not asked["ok"], "saving from an older save does not just happen")
	h.check(asked.get("needs_confirmation", false), "it asks first")
	h.check(asked["affected"].size() == 2, "naming what answering yes would remove")
	h.check(session.saves().size() == 3, "and asking removes nothing")

	h.check(session.save_confirmed(system)["ok"], "answering yes saves")
	h.check(
		session.saves().size() == 2,
		"and the later saves go, leaving the one loaded and the new one (%d left)"
		% session.saves().size()
	)
	h.check(
		session.player.attributes["Credits"] == 5,
		"with the story continuing from where it was loaded"
	)
	# Once saved, the history is back in step with what is in memory, so the next save is ordinary.
	h.check(
		not session.save(system).get("needs_confirmation", false),
		"and the save after it is an ordinary one again"
	)


func _test_deleting_a_save(h, system: SpacesimSystemScene) -> void:
	var session := _session()
	var revision_count := session.repo.saves().size()
	var newest: String = session.saves()[0]["hash"]
	h.check(session.delete_save(newest)["ok"], "a save can be deleted")
	h.check(session.saves().size() == revision_count - 1, "and stops being listed")
	h.check(
		not session.saves().any(func(entry: Dictionary) -> bool: return entry["hash"] == newest),
		"that one in particular"
	)
	h.check(
		session.repo.saves().size() == revision_count,
		"without a save being added or taken away — deleting is not itself a save"
	)
	h.check(
		not session.repo.preview(newest).is_empty(),
		"and its commit is still in the repository, reachable if a tombstone was a mistake"
	)
	h.check(
		session.repo.read_text(Repo.DELETED_FILE).contains(newest),
		"the tombstone being what records it"
	)


func _test_the_clock_moves_on(h, system: SpacesimSystemScene) -> void:
	var session := _session()
	var player_data := session.player.to_dictionary()

	# A save written a day ago: the world has moved on by a day, and the player has not.
	session.repo.write_text(Repo.STATE_FILE, Repo.state_text(player_data, 1000.0, Session.now() - 86400.0))
	h.check(session.load_last(), "a state can be read")
	h.check(
		session.world_time >= 1000.0 + 86400.0,
		"and the world has moved on by the time the player was away (%.0f)" % session.world_time
	)
	h.check(session.world_time < 1000.0 + 86500.0, "by about that much")

	# A machine clock that is ahead must not run the world backwards.
	session.repo.write_text(Repo.STATE_FILE, Repo.state_text(player_data, 5000.0, Session.now() + 86400.0))
	session.load_last()
	h.check(session.world_time == 5000.0, "and a save from the future does not take it backwards")


func _test_putting_the_ship_back(h, system: SpacesimSystemScene, ship: Node3D) -> void:
	var away := Location.new("planet:terra/surface", Vector3(5.0, 0.5, 8.0))
	h.check(system.place_observer(away), "the ship can be put back where it was")
	h.check(
		system.frame_tree.active_frame.frame_id == "planet:terra/surface",
		"in the frame the save named"
	)
	# Only the distance from the surface comes back, and that is not a shortfall: a surface frame's
	# placement is *derived* — the locale moves under you as you land — so the saved position says
	# where you were within your locale, not where on a globe. On a featureless sphere the locale is
	# anonymous. Terrain is what makes the tangential part mean something, and then a surface will
	# need a placement of its own.
	h.check(
		absf(system.frame_tree.observer.position.y - 0.5) < 0.01,
		"standing the same height above the surface it was (%.4f)" % system.frame_tree.observer.position.y
	)
	h.check(
		Vector2(system.frame_tree.observer.position.x, system.frame_tree.observer.position.z).length() < 0.01,
		"with the locale moved under it, which is what makes it *on* the surface"
	)

	h.check(
		not system.place_observer(Location.new("planet:gone/surface", Vector3.ZERO)),
		"a frame the system no longer has falls back rather than refusing the save"
	)
	h.check(
		system.frame_tree.observer.position == Vector3.ZERO,
		"to that frame's origin, because the stored position would mean something else there"
	)
	h.check(ship != null, "and the ship is still the observer")


## The two lists, with something in them — a browser that cannot be opened proves nothing.
func _test_the_browser(h, root: Node, system: SpacesimSystemScene) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var session := _session()
	session.start(system)
	# Save something, so the lists have something in them: a browser that cannot be opened proves
	# nothing, and by this point in the suite the earlier saves have been loaded over and deleted.
	session.player.attributes["Credits"] = 7
	session.save(system)

	var panel := PlayerPanel.new()
	panel.configure(session.player, session, system)
	layer.add_child(panel)
	panel.opened()

	h.check(panel.actions.get_child_count() == 3, "the screen has Save, New Story and Close")
	h.check(_shows(panel, "Histories") and _shows(panel, "Saves"), "and both lists")
	# What can be done to a row lives on the row.
	h.check(
		_shows(panel, "Play this history") and _shows(panel, "Delete history"),
		"with a menu on a history row"
	)
	h.check(
		_shows(panel, "Show this save") and _shows(panel, "Load this save"),
		"and one on a save row, which is where Load lives"
	)
	h.check(_shows(panel, "Rename this"), "and one on a thing the player holds")
	# The two renames are different things, so they are named differently.
	h.check(_shows(panel, "Rename history"), "renaming a history says so")
	h.check(_shows(panel, "Change my values"), "and the player's own name is a value of theirs, not a history")
	h.check(
		_shows(panel, "Assets") and _shows(panel, "Playground Lander"),
		"and what the player holds, by name"
	)
	h.check(_shows(panel, Session.FIRST_HISTORY), "the history being played is listed")
	h.check(_shows(panel, "(playing)"), "and marked as the one being played")
	# The whole label, not a fragment of it — "in space" also appears in the header and the date on
	# its own appears twice, so a fragment would pass without the save row existing at all.
	h.check(_shows(panel, session.label(system)), "and the save in it is listed by its whole label")

	var sections := panel.content.get_child_count()
	panel.opened()
	h.check(panel.content.get_child_count() == sections, "opening again rebuilds rather than stacking")
	layer.free()


## The dialog is generic on purpose — a confirmation, a name prompt, a details view — so what is
## worth checking is that it asks, collects and answers.
func _test_the_dialog(h, root: Node) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var dialog := Dialog.new()
	layer.add_child(dialog)

	var answers: Array = []
	dialog.answered.connect(func(action: String) -> void: answers.append(action))
	dialog.ask("Rename a history", "What should it be called?", ["Rename", "Cancel"], ["History name"])

	h.check(dialog.content != null and dialog.actions.get_child_count() == 2, "a dialog opens with its answers")
	h.check(dialog.value("History name") == "", "and its field starts empty")
	h.check(_shows(dialog, "What should it be called?"), "and shows what it is asking")

	# Answering hides it and reports which button was pressed, which is the whole contract.
	dialog.actions.get_child(0).pressed.emit()
	h.check(answers == ["Rename"], "pressing an answer reports which one (%s)" % str(answers))
	h.check(not dialog.visible, "and closes it")
	layer.free()


## Whether anything under `node` shows this text, as part of a longer line. Menus count: what you
## can do to a row lives in them, so a test that cannot see them cannot see the affordances.
static func _shows(node: Node, fragment: String) -> bool:
	if node is Label and node.text.contains(fragment):
		return true
	if node is Button and node.text.contains(fragment):
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
		if _shows(child, fragment):
			return true
	return false


func _session() -> SpacesimSession:
	return Session.new(Repo.new(TEST_ROOT))


func _clean() -> void:
	OS.execute("rm", PackedStringArray(["-rf", TEST_ROOT]))
