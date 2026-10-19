extends RefCounted
## The player, and the two screens built on the shared chrome.

const Player := preload("res://addons/spacesim/player/player.gd")
const PlayerPanel := preload("res://addons/spacesim/player/player_panel.gd")
const SettingsPanel := preload("res://addons/spacesim/settings/settings_panel.gd")
const Session := preload("res://addons/spacesim/save/session.gd")
const Repo := preload("res://addons/spacesim/save/world_repo.gd")
const Fixture := preload("res://tests/settings_fixture.gd")

const SYSTEM_PATH := "res://systems/playground.tres"

## The personal-data screen hosts saving, so building it needs a session and a system. Neither
## touches anything here: the screen only reads their names, so no repository is disturbed.
const TEST_ROOT := "/tmp/spacesim-player-test"

var _fixture := Fixture.new()


func run(h, root: Node) -> void:
	print("  player and the shared screen")
	Fixture.clean()
	_test_player_starts_whole(h)
	_test_reset_is_a_copy(h)
	_test_screens_build_on_the_shared_chrome(h, root)
	_test_player_screen_shows_the_player(h, root)
	Fixture.clean()
	_fixture.release()


func _test_player_starts_whole(h) -> void:
	var player := Player.new()
	h.check(player.display_name() == Player.DEFAULT_NAME, "the player starts with a name")
	h.check(player.attributes.has("Name"), "which is an attribute")
	h.check(player.attributes.has("Credits"), "currency is an attribute too, being a quantity")
	h.check(not player.assets.is_empty(), "and the player starts holding something")

	var asset: Dictionary = player.assets[0]
	h.check(
		asset.has("name") and asset.has("type") and asset.has("value"),
		"where an asset carries a name, a type and a value"
	)


func _test_reset_is_a_copy(h) -> void:
	var player := Player.new()
	player.attributes["Credits"] = 500
	player.assets.clear()
	player.reset("Evert")

	h.check(player.display_name() == "Evert", "resetting takes a name")
	h.check(
		player.attributes["Credits"] == Player.DEFAULT_ATTRIBUTES["Credits"],
		"puts the attributes back to the defaults"
	)
	h.check(player.assets.size() == Player.DEFAULT_ASSETS.size(), "and the assets")

	# The defaults are consts, so handing them out by reference would be a shared mutable state
	# bug that only shows up the second time a player is made.
	player.assets[0]["value"] = 1
	h.check(
		Player.DEFAULT_ASSETS[0]["value"] != 1, "as copies, so editing one does not touch the default"
	)


func _test_screens_build_on_the_shared_chrome(h, root: Node) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)

	var settings_panel := SettingsPanel.new()
	settings_panel.configure(_fixture.open())
	layer.add_child(settings_panel)
	h.check(
		settings_panel.content != null and settings_panel.actions != null,
		"the settings screen builds onto the shared chrome"
	)
	h.check(settings_panel.actions.get_child_count() == 3, "with its three buttons")
	h.check(settings_panel.has_signal("closed"), "and the close signal it inherits")

	var player_panel := PlayerPanel.new()
	player_panel.configure(Player.new(), Session.new(Repo.new(TEST_ROOT)), _system(root))
	layer.add_child(player_panel)
	h.check(player_panel.actions.get_child_count() == 3, "the player screen has Save, New Story and Close")
	h.check(player_panel.has_signal("closed"), "and the same close signal")
	h.check(player_panel.has_signal("session_reloaded"), "and tells whoever is flying that a load moved the player")

	layer.free()


func _test_player_screen_shows_the_player(h, root: Node) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var player := Player.new()
	var panel := PlayerPanel.new()
	panel.configure(player, Session.new(Repo.new(TEST_ROOT)), _system(root))
	layer.add_child(panel)

	panel.opened()
	h.check(panel.content.get_child_count() > 0, "opening the player screen fills it")
	var sections := panel.content.get_child_count()

	player.attributes["Credits"] = 999
	panel.opened()
	h.check(
		panel.content.get_child_count() == sections,
		"opening it again rebuilds rather than stacking sections"
	)
	h.check(_shows(panel.content, "999"), "and shows the value that changed while it was hidden")

	layer.free()


## A built playground, for the screen to read names out of.
static func _system(root: Node) -> SpacesimSystemScene:
	var system := SpacesimSystemScene.from_file(SYSTEM_PATH)
	system.build(root)
	return system


## Whether anything under `node` displays exactly this text.
static func _shows(node: Node, text: String) -> bool:
	if node is Label and node.text == text:
		return true
	for child in node.get_children():
		if _shows(child, text):
			return true
	return false
