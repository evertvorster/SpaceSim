class_name SpacesimWorldRepo
extends RefCounted
## The world's repository: one world, a history per playthrough, a save per commit.
##
## This class knows git and nothing about what a save *contains* — [method save] is handed the files
## to write, so the format of the player's state stays the caller's business.
##
## ```
## world.json    which world this is
## world/        the world's own durable state, written only when something changes it
## player/       the player's own state
## ```
##
## Every rewrite here is local and safe, for one reason: **a history is never pushed and never
## shared.** The trunk has no knowledge of player histories, and histories are never merged with
## each other. See `Save and Load Plan` §6.

const TRUNK := "main"
const STATE_FILE := "player/state.json"

## The player's tombstones, in their own file **so that deleting a save is not itself a save in the
## list**. The list is built from commits that touched [constant STATE_FILE].
const DELETED_FILE := "player/deleted.json"

const REFERENCE_FILE := "world.json"
const DEFAULT_REPO_NAME := "playground"

## The envelope every save carries. The repo does not know what a player *is* — this is only the
## wrapping, so the format lives in one place and the caller composes the rest.
const STATE_FORMAT_VERSION := 1
const FIELD_VERSION := "save_format_version"
const FIELD_WORLD_TIME := "world_time"
const FIELD_SAVED_REALTIME := "saved_realtime"

var root: String

var _git: SpacesimGit


func _init(repo_root: String) -> void:
	root = repo_root
	_git = SpacesimGit.new(repo_root)


## The repository for a world, under the XDG data directory.
static func for_world(world_name := DEFAULT_REPO_NAME) -> SpacesimWorldRepo:
	return SpacesimWorldRepo.new(SpacesimXdg.data_dir().path_join("worlds").path_join(world_name))


func exists() -> bool:
	return DirAccess.dir_exists_absolute(root.path_join(".git"))


## Create the repository and its trunk. The trunk holds only which world this is — a history
## branches from it and adds the player.
func create(world_reference: Dictionary) -> Dictionary:
	if exists():
		return {"ok": true, "reason": ""}
	if not SpacesimXdg.ensure_directory(root):
		return {"ok": false, "reason": "cannot create %s" % root}
	var initialised := _git.run(["init", "-q", "-b", TRUNK])
	if not initialised["ok"]:
		return {"ok": false, "reason": "git could not make a repository here"}
	write_json(REFERENCE_FILE, world_reference)
	return commit("trunk: %s" % String(world_reference.get("world", "world")))


# --- state ---------------------------------------------------------------------------------------

func write_text(path: String, contents: String) -> bool:
	var full := root.path_join(path)
	if not SpacesimXdg.ensure_directory(full.get_base_dir()):
		return false
	var file := FileAccess.open(full, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(contents)
	file.close()
	return true


func write_json(path: String, data: Dictionary) -> bool:
	return write_text(path, JSON.stringify(data, "\t") + "\n")


func read_text(path: String) -> String:
	return FileAccess.get_file_as_string(root.path_join(path))


## A state file: the player's own dictionary, wrapped in the envelope every save carries.
##
## `saved_realtime` is the machine's clock at the moment of saving. It is how long the player has
## been away is worked out on load, which is what advances the world's clock between sessions.
static func state_text(player_data: Dictionary, world_time: float, saved_realtime: float) -> String:
	var state := player_data.duplicate(true)
	state[FIELD_VERSION] = STATE_FORMAT_VERSION
	state[FIELD_WORLD_TIME] = world_time
	state[FIELD_SAVED_REALTIME] = saved_realtime
	return JSON.stringify(state, "\t") + "\n"


## The envelope back out of a state file — or an empty dictionary when it cannot be read, because a
## save that will not parse is a failed load, not a crash.
static func read_state(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## Write the files and commit them as a save. Returns `{"ok", "reason"}`; a save with nothing
## changed is refused rather than faked with an empty commit.
func save(files: Dictionary, label: String) -> Dictionary:
	for path in files:
		if not write_text(path, files[path]):
			return {"ok": false, "reason": "cannot write %s" % path}
	return commit(label)


## Stage everything and commit. `{"ok", "reason"}`.
func commit(label: String) -> Dictionary:
	if _git.is_clean():
		return {"ok": false, "reason": "nothing has changed since the last save"}
	var staged := _git.run(["add", "-A"])
	if not staged["ok"]:
		return {"ok": false, "reason": "git could not stage the working tree"}
	var committed := _git.run(["commit", "-q", "-m", label])
	if not committed["ok"]:
		return {"ok": false, "reason": "git could not commit"}
	return {"ok": true, "reason": ""}


## A save is a commit, so anything uncommitted was never a save — most likely a crash between
## writing the files and committing. Called at startup.
func discard_working_tree() -> bool:
	return _git.run(["reset", "--hard", "HEAD"])["ok"]


# --- saves ---------------------------------------------------------------------------------------

## The saves on a history, newest first. `{"hash", "time", "subject"}`.
##
## Takes the history rather than always using the current one, because the browser shows the saves
## of the history you have *selected* — which is not necessarily the one being played.
func saves(history := "HEAD") -> Array:
	return _parse_log(_git.run(["log", "--format=%h|%ct|%s", history, "--", STATE_FILE]))


## The saves that loading `hash` would remove from that history.
func affected_saves(hash: String, history := "HEAD") -> Array:
	return _parse_log(
		_git.run(["log", "--format=%h|%ct|%s", "%s..%s" % [hash, history], "--", STATE_FILE])
	)


## A file as it stands in a save — read without touching the working tree, which is what makes
## browsing free and only loading cost anything.
func preview(hash: String, path := STATE_FILE) -> String:
	var result := _git.run(["show", "%s:%s" % [hash, path]])
	return _git.text(result) if result["ok"] else ""


## The commit the history is standing on. A save is a commit, so this is the last save.
##
## Abbreviated, like the hashes in [method saves] — the two are compared, so they have to be written
## the same way.
func tip() -> String:
	var result := _git.run(["rev-parse", "--short", "HEAD"])
	return _git.text(result).strip_edges() if result["ok"] else ""


## Move the history's tip back to a save, so the later saves leave the list.
##
## The working tree is deliberately left alone, and that is what keeps the world honest: only the
## player's paths are ever rewritten, so a burnt village stays burnt through a do-over. The state
## being continued from arrives in memory, not by checking anything out — reading a save costs
## nothing, and this is only run when one is *saved* from.
func rewind_to(hash: String) -> Dictionary:
	var moved := _git.run(["reset", "--soft", hash])
	if not moved["ok"]:
		return {"ok": false, "reason": "git could not move the history back"}
	return {"ok": true, "reason": ""}


# --- histories -----------------------------------------------------------------------------------

func current_history() -> String:
	var result := _git.run(["rev-parse", "--abbrev-ref", "HEAD"])
	return _git.text(result).strip_edges() if result["ok"] else ""


## `{"name", "time", "current"}`, newest first.
func histories() -> Array:
	var result := _git.run(["branch", "--format=%(refname:short)|%(committerdate:unix)", "--list"])
	var list: Array = []
	if not result["ok"]:
		return list
	var current := current_history()
	for line in result["lines"]:
		var parts := String(line).split("|", true, 1)
		if parts.size() < 2:
			continue
		list.append({"name": parts[0], "time": int(parts[1]), "current": parts[0] == current})
	list.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			# Newest first, and by name when two were made in the same second — an unstable list
			# order is no good to look at.
			if int(a["time"]) != int(b["time"]):
				return int(a["time"]) > int(b["time"])
			return String(a["name"]) < String(b["name"])
	)
	return list


func has_history(name: String) -> bool:
	return _git.run(["show-ref", "--verify", "--quiet", "refs/heads/%s" % name])["ok"]


## Start a history from the trunk. The name is slugged, and checked for both validity and
## uniqueness — git refuses a duplicate on rename too, so the check belongs in front of both.
func create_history(name: String) -> Dictionary:
	var slug := SpacesimGit.slug(name)
	var rejected := _reject_name(slug)
	if not rejected.is_empty():
		return {"ok": false, "reason": rejected}
	# Drop anything uncommitted first: a dirty tree makes git refuse the switch, and a new story
	# does not want the old one's leftovers anyway.
	_git.run(["reset", "--hard"])
	var created := _git.run(["checkout", "-q", "-b", slug, TRUNK])
	if not created["ok"]:
		return {"ok": false, "reason": "git could not start the history"}
	return {"ok": true, "reason": "", "name": slug}


func rename_history(from: String, to: String) -> Dictionary:
	var slug := SpacesimGit.slug(to)
	var rejected := _reject_name(slug, from)
	if not rejected.is_empty():
		return {"ok": false, "reason": rejected}
	var renamed := _git.run(["branch", "-m", from, slug])
	if not renamed["ok"]:
		return {"ok": false, "reason": "git could not rename it"}
	return {"ok": true, "reason": "", "name": slug}


## git refuses to delete the history the worktree is in, and the trunk is what a new story branches
## from, so neither can go.
func delete_history(name: String) -> Dictionary:
	if name == TRUNK:
		return {"ok": false, "reason": "the trunk is what a new story starts from"}
	if name == current_history():
		return {"ok": false, "reason": "you are playing this history — switch to another first"}
	var deleted := _git.run(["branch", "-D", name])
	if not deleted["ok"]:
		return {"ok": false, "reason": "git could not delete it"}
	return {"ok": true, "reason": ""}


## The trunk is the shared world rather than a playthrough, so it is not somewhere to stand: it has
## no player state of its own, and playing there would leave the next startup with nothing to load.
func switch_history(name: String) -> Dictionary:
	if name == current_history():
		return {"ok": true, "reason": ""}
	if name == TRUNK:
		return {"ok": false, "reason": "the trunk is the world itself, not a playthrough"}
	_git.run(["reset", "--hard"])
	var switched := _git.run(["checkout", "-q", name])
	if not switched["ok"]:
		return {"ok": false, "reason": "git could not switch to it"}
	return {"ok": true, "reason": ""}


## Why this name cannot be used, or "" when it can. `except` is the name being renamed, which is
## allowed to be the same as itself.
func _reject_name(slug: String, except := "") -> String:
	if not _git.is_valid_branch_name(slug):
		return "'%s' is not a name git will accept" % slug
	if slug != except and has_history(slug):
		return "there is already a history called '%s'" % slug
	return ""


func _parse_log(result: Dictionary) -> Array:
	var entries: Array = []
	if not result["ok"]:
		return entries
	for line in result["lines"]:
		var parts := String(line).split("|", true, 2)
		if parts.size() < 3:
			continue
		entries.append({"hash": parts[0], "time": int(parts[1]), "subject": parts[2]})
	return entries
