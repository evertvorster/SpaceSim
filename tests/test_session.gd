extends RefCounted
## The session: one playthrough, its clock, and the saves that hold it.
##
## Runs against a real git repository in a temp directory, like the save suite — the point of the
## session is what it writes to git and what it reads back, so a mock would test nothing.

const Session := preload("res://addons/spacesim/save/session.gd")
const Repo := preload("res://addons/spacesim/save/world_repo.gd")
const Player := preload("res://addons/spacesim/player/player.gd")
const Location := preload("res://addons/spacesim/coordinate/location.gd")
const PlayerShip := preload("res://game/player_ship.gd")

const WORLD_PATH := "res://worlds/playground.json"
const TEST_ROOT := "/tmp/spacesim-session-test"


func run(h, root: Node) -> void:
	print("  session")
	_clean()

	var world := SpacesimWorld.from_file(WORLD_PATH)
	world.build(root)
	var ship := PlayerShip.create()
	PlayerShip.place(world, ship)

	_test_first_run(h, world)
	_test_starting_again(h, world)
	_test_saving(h, world)
	_test_the_do_over(h, world)
	_test_deleting_a_save(h, world)
	_test_the_clock_moves_on(h, world)
	_test_putting_the_ship_back(h, world, ship)

	world.container.free()
	_clean()


func _test_first_run(h, world: SpacesimWorld) -> void:
	var session := _session()
	h.check(not session.repo.exists(), "there is no repository to begin with")
	h.check(session.start(world)["ok"], "starting brings one up")
	h.check(session.repo.exists(), "and now there is one")
	h.check(session.repo.current_history() == Session.FIRST_HISTORY, "on the first history")
	h.check(session.message == "a new story", "reported as a new story")
	h.check(session.repo.saves().size() == 1, "with the first save already made, so there is something to load")
	h.check(session.player.display_name() == Player.DEFAULT_NAME, "and a player at their defaults")


func _test_starting_again(h, world: SpacesimWorld) -> void:
	var session := _session()
	h.check(session.start(world)["ok"], "starting again")
	h.check(session.message == "the last save", "picks up the last save rather than starting over")
	h.check(session.repo.current_history() == Session.FIRST_HISTORY, "on the same history")
	h.check(session.repo.histories().size() == 2, "and did not make another history")


func _test_saving(h, world: SpacesimWorld) -> void:
	var session := _session()
	session.player.attributes["Credits"] = 500
	session.player.location = Location.new("planet:terra/surface", Vector3(10.0, 0.0, 20.0))
	h.check(session.save(world)["ok"], "a save")
	h.check(session.message == "saved", "says so, rather than leaving the player guessing")
	h.check(session.save(world)["ok"] == false, "and saving again with nothing changed is refused")
	h.check(session.saves().size() == 2, "two saves are listed (%d)" % session.saves().size())
	h.check(session.label(world).contains("landed on Terra"), "a label says where you were: %s" % session.label(world))


func _test_the_do_over(h, world: SpacesimWorld) -> void:
	var session := _session()
	session.player.attributes["Credits"] = 999
	session.save(world)
	h.check(session.saves().size() == 3, "three saves")
	var oldest: String = session.saves()[2]["hash"]
	h.check(session.affected_saves(oldest).size() == 2, "and loading the oldest affects the two after it")

	var preview := session.preview(oldest)
	h.check(int(preview.get("attributes", {}).get("Credits", -1)) == 0, "a save can be looked at as it stood")

	h.check(session.load(oldest)["ok"], "loading it")
	h.check(session.saves().size() == 1, "removes the later saves (%d left)" % session.saves().size())
	h.check(session.player.attributes["Credits"] == 0, "and brings the player back to what they were")


func _test_deleting_a_save(h, world: SpacesimWorld) -> void:
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


func _test_the_clock_moves_on(h, world: SpacesimWorld) -> void:
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


func _test_putting_the_ship_back(h, world: SpacesimWorld, ship: Node3D) -> void:
	var away := Location.new("planet:terra/surface", Vector3(5.0, 0.5, 8.0))
	h.check(world.place_observer(away), "the ship can be put back where it was")
	h.check(
		world.frame_tree.active_frame.frame_id == "planet:terra/surface",
		"in the frame the save named"
	)
	# Only the distance from the surface comes back, and that is not a shortfall: a surface frame's
	# placement is *derived* — the locale moves under you as you land — so the saved position says
	# where you were within your locale, not where on a globe. On a featureless sphere the locale is
	# anonymous. Terrain is what makes the tangential part mean something, and then a surface will
	# need a placement of its own.
	h.check(
		absf(world.frame_tree.observer.position.y - 0.5) < 0.01,
		"standing the same height above the surface it was (%.4f)" % world.frame_tree.observer.position.y
	)
	h.check(
		Vector2(world.frame_tree.observer.position.x, world.frame_tree.observer.position.z).length() < 0.01,
		"with the locale moved under it, which is what makes it *on* the surface"
	)

	h.check(
		not world.place_observer(Location.new("planet:gone/surface", Vector3.ZERO)),
		"a frame the world no longer has falls back rather than refusing the save"
	)
	h.check(
		world.frame_tree.observer.position == Vector3.ZERO,
		"to that frame's origin, because the stored position would mean something else there"
	)
	h.check(ship != null, "and the ship is still the observer")


func _session() -> SpacesimSession:
	return Session.new(Repo.new(TEST_ROOT))


func _clean() -> void:
	OS.execute("rm", PackedStringArray(["-rf", TEST_ROOT]))
