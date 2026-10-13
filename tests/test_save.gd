extends RefCounted
## Saves: the repository, the history names, the state, and how a location reads.
##
## These run against a **real git repository in a temp directory**, so they exercise git itself
## rather than a mock. The numbers in the save plan came from the same kind of exercise.

const Git := preload("res://addons/spacesim/save/git.gd")
const Repo := preload("res://addons/spacesim/save/world_repo.gd")
const Player := preload("res://addons/spacesim/player/player.gd")
const Location := preload("res://addons/spacesim/coordinate/location.gd")
const Frame := preload("res://addons/spacesim/coordinate/frame.gd")

const SYSTEM_PATH := "res://systems/playground.tres"
const TEST_ROOT := "/tmp/spacesim-save-test"


func run(h, root: Node) -> void:
	print("  saves")
	_clean()
	# Git is asked about branch names, and `-C` needs somewhere to point.
	SpacesimXdg.ensure_directory(TEST_ROOT)
	_test_slug_survives_git(h)
	_test_history_names(h)
	_test_save_and_list(h)
	_test_preview_does_not_touch_the_tree(h)
	_test_do_over(h)
	_test_state_round_trip(h)
	_test_reading_a_location(h, root)
	_clean()


# --- names ---------------------------------------------------------------------------------------

## The slug's contract is that git accepts what it produces. So the corpus is the awkward names
## themselves, and git is the judge — the rules are never enumerated by hand.
func _test_slug_survives_git(h) -> void:
	var git := Git.new(TEST_ROOT)
	var refused: Array[String] = []
	var corpus := [
		"Evert Vorster",
		"with space",
		"trailing.",
		"double..dot",
		"end.lock",
		"-leadingdash",
		"a/b",
		"Ünïcode",
		"  padded  ",
		"",
		"!!!",
		"@",
		"..",
		".",
		"-",
		"a\tb",
		"a:b?c*d[e]\\f",
		"Evert@home",
		"🎮 game",
		"x".repeat(120),
	]
	for name in corpus:
		var slug: String = Git.slug(name)
		if slug.is_empty() or not git.is_valid_branch_name(slug):
			refused.append("%s -> '%s'" % [name, slug])
	h.check(refused.is_empty(), "every slugged name is one git accepts%s" % _detail(refused))
	h.check(Git.slug("Evert Vorster") == "Evert-Vorster", "and a name with spaces becomes a slug")
	h.check(Git.slug("") == "player", "and nothing at all still yields something usable")


func _test_history_names(h) -> void:
	var repo := _fresh_repo(h)
	SpacesimXdg.ensure_directory(TEST_ROOT)
	h.check(repo.create({"world": "playground"})["ok"], "a repository is created with its trunk")
	h.check(repo.current_history() == Repo.TRUNK, "and starts on the trunk")

	var started := repo.create_history("Evert Vorster")
	h.check(started["ok"] and started["name"] == "Evert-Vorster", "New Story slugged the name")
	h.check(repo.current_history() == "Evert-Vorster", "and started there")

	var duplicate := repo.create_history("Evert Vorster")
	h.check(
		not duplicate["ok"] and duplicate["reason"].contains("already"),
		"the same name twice is refused: %s" % duplicate["reason"]
	)

	h.check(repo.rename_history("Evert-Vorster", "Mira")["ok"], "a history can be renamed")
	h.check(repo.current_history() == "Mira", "and renaming where you are keeps you there")
	h.check(not repo.rename_history("Mira", Repo.TRUNK)["ok"], "renaming onto a name in use is refused")

	# The slugger is total on purpose: whatever somebody types, they get a history. The prompt's job
	# is to show them the name that will result.
	var odd := repo.create_history("!!!")
	h.check(
		odd["ok"] and not String(odd["name"]).is_empty(),
		"a name of nothing usable still yields a history ('%s')" % odd.get("name", "")
	)
	h.check(repo.create_history("Second")["ok"], "and a third history starts")
	h.check(repo.histories().size() == 4, "four histories now exist (%d)" % repo.histories().size())
	var marked := 0
	for entry in repo.histories():
		if entry["current"]:
			marked += 1
			h.check(entry["name"] == repo.current_history(), "the list marks the history being played")
	h.check(marked == 1, "and marks exactly one")

	h.check(
		not repo.delete_history(repo.current_history())["ok"],
		"the one you are playing cannot be deleted — git refuses it too"
	)
	h.check(not repo.delete_history(Repo.TRUNK)["ok"], "nor the trunk, which a new story branches from")
	h.check(repo.switch_history("Mira")["ok"], "you can switch to another")
	h.check(repo.delete_history("Second")["ok"], "and delete one you are not playing")
	h.check(not repo.has_history("Second"), "which is then gone")


# --- saves ---------------------------------------------------------------------------------------

func _test_save_and_list(h) -> void:
	var repo := _fresh_repo(h)
	h.check(repo.create({"world": "playground"})["ok"], "repository")
	h.check(repo.create_history("Evert")["ok"], "a history")

	h.check(
		repo.save({Repo.STATE_FILE: Repo.state_text({"attributes": {"Credits": 10}}, 100.0, 0.0)}, "first")["ok"],
		"a save is a commit"
	)
	var again := repo.save({Repo.STATE_FILE: Repo.state_text({"attributes": {"Credits": 10}}, 100.0, 0.0)}, "again")
	h.check(
		not again["ok"] and again["reason"].contains("nothing has changed"),
		"saving with nothing changed is refused rather than faked: %s" % again["reason"]
	)

	repo.save({Repo.STATE_FILE: Repo.state_text({"attributes": {"Credits": 20}}, 200.0, 0.0)}, "second")
	var third := repo.save(
		{Repo.STATE_FILE: Repo.state_text({"attributes": {"Credits": 30}}, 300.0, 0.0)}, "third"
	)
	h.check(third["ok"], "and a third")
	repo.save({Repo.STATE_FILE: Repo.state_text({"attributes": {"Credits": 40}}, 400.0, 0.0)}, "fourth")

	var saves := repo.saves()
	h.check(saves.size() == 4, "four saves are listed (%d)" % saves.size())
	h.check(saves[0]["subject"] == "fourth", "newest first")
	h.check(not String(saves[0]["hash"]).is_empty(), "each with a hash")

	var affected := repo.affected_saves(saves[1]["hash"])
	h.check(affected.size() == 1 and affected[0]["subject"] == "fourth", "and loading an older one lists what it removes")


func _test_preview_does_not_touch_the_tree(h) -> void:
	var repo := _fresh_repo(h)
	repo.create({"world": "playground"})
	repo.create_history("Evert")
	repo.save({Repo.STATE_FILE: Repo.state_text({"attributes": {"Credits": 10}}, 100.0, 0.0)}, "first")
	repo.save({Repo.STATE_FILE: Repo.state_text({"attributes": {"Credits": 20}}, 200.0, 0.0)}, "second")

	var before := repo.read_text(Repo.STATE_FILE)
	var saves := repo.saves()
	var previewed := repo.preview(saves[1]["hash"])
	h.check(previewed.contains("\"Credits\": 10"), "a save can be read as it stood")
	h.check(repo.read_text(Repo.STATE_FILE) == before, "without touching the working tree")
	h.check(repo.saves().size() == 2, "and without changing the history")


func _test_do_over(h) -> void:
	var repo := _fresh_repo(h)
	repo.create({"world": "playground"})
	repo.create_history("Evert")
	repo.save({Repo.STATE_FILE: Repo.state_text({"attributes": {"Credits": 10}}, 100.0, 0.0)}, "first")
	repo.save(
		{
			Repo.STATE_FILE: Repo.state_text({"attributes": {"Credits": 20}}, 200.0, 0.0),
			"world/delta.jsonl": "{\"village\":\"burnt\"}\n",
		},
		"second"
	)
	repo.save({Repo.STATE_FILE: Repo.state_text({"attributes": {"Credits": 30}}, 300.0, 0.0)}, "third")

	var target: String = repo.saves()[2]["hash"]  # the first save
	h.check(repo.affected_saves(target).size() == 2, "two saves are affected")
	h.check(repo.restore(target)["ok"], "the do-over runs")

	h.check(repo.saves().size() == 1, "the later saves leave the history (%d left)" % repo.saves().size())
	h.check(repo.read_text(Repo.STATE_FILE).contains("\"Credits\": 10"), "the player's state comes back")
	h.check(
		repo.read_text("world/delta.jsonl").contains("burnt"),
		"and the world's state does NOT — the world moved on"
	)


func _test_state_round_trip(h) -> void:
	var player := Player.new("Evert")
	player.attributes["Credits"] = 500
	player.location = Location.new("planet:terra/surface", Vector3(1.0, 2.0, 3.0))
	var ship := player.add_asset(
		"Cargo hauler", "ship", 45000, Location.new("planet:terra/surface", Vector3(40.0, 0.0, 0.0))
	)
	h.check(not String(ship.get("id", "")).is_empty(), "an asset gets an id")

	var text := Repo.state_text(player.to_dictionary(), 16156800000.0, 0.0)
	var state := Repo.read_state(text)
	h.check(state.get(Repo.FIELD_VERSION) == Repo.STATE_FORMAT_VERSION, "the state carries a format version")
	h.check(state.get(Repo.FIELD_WORLD_TIME) == 16156800000.0, "and the world clock")
	h.check(text.contains("\n\t\"attributes\""), "and is written one key per line, to diff well")

	var restored := Player.new()
	restored.from_dictionary(state)
	h.check(restored.display_name() == "Evert", "the name comes back")
	h.check(restored.attributes["Credits"] == 500, "so does an attribute")
	h.check(restored.location.frame_id == "planet:terra/surface", "and the location")
	h.check(
		is_equal_approx(restored.location.position.y, 2.0), "with its position"
	)
	h.check(restored.assets.size() == 2, "both assets are there")
	h.check(
		restored.asset_by_id(String(ship["id"])).get("name") == "Cargo hauler", "found by the id a location uses"
	)


func _test_reading_a_location(h, root: Node) -> void:
	var system := SpacesimSystemScene.from_file(SYSTEM_PATH)
	if system == null:
		h.check(false, "the playground system loads")
		return
	system.build(root)

	h.check(
		system.frame_tree.frame_by_id("planet:terra/surface") != null, "a frame can be found by the id a save names"
	)
	h.check(
		system.frame_tree.resolve_frame("planet:nonexistent/surface") == system.system_frame,
		"a frame the system does not have falls back towards the system frame"
	)

	var assets: Array = []
	h.check(
		system.describe(Location.new("planet:nix/surface", Vector3.ZERO), assets) == "landed on Nix",
		"a surface location reads as prose"
	)
	h.check(
		system.describe(Location.new(Frame.SYSTEM_ID, Vector3(3.0e10, 0.0, 0.0)), assets).begins_with("in space, near"),
		"open space reads by what is near"
	)

	var base := Player.new()
	var made := base.add_asset("Base Foo", "base", 900000, Location.new("planet:borealis/surface", Vector3.ZERO))
	h.check(
		system.describe(Location.new("asset:%s/interior" % made["id"], Vector3.ZERO), base.assets)
		== "in Base Foo, landed on Borealis",
		"and something inside a base names the base and where the base is"
	)

	h.check(system.format_time(0.0) == "0-01-01 00:00", "the world's epoch reads as year 0")
	h.check(system.format_time(86400.0) == "0-01-02 00:00", "and a day later is a day later")
	# Not an exact year: the Terran year is 365.2425 days, so half a millennium of seconds lands on or
	# beside 500-01-01. What matters is that it is there at all, and that it grows.
	var later := system.format_time(31556952.0 * 500.0)
	h.check(int(later.split("-")[0]) >= 499, "and half a millennium later reads as a year near 500 ('%s')" % later)
	system.container.free()


# --- plumbing ------------------------------------------------------------------------------------

func _fresh_repo(h) -> SpacesimWorldRepo:
	_clean()
	var repo := Repo.new(TEST_ROOT)
	return repo


func _detail(problems: Array[String]) -> String:
	return "" if problems.is_empty() else ": " + ", ".join(problems)


func _clean() -> void:
	OS.execute("rm", PackedStringArray(["-rf", TEST_ROOT]))
