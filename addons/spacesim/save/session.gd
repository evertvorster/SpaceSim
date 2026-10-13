class_name SpacesimSession
extends RefCounted
## One playthrough: the player, the world clock, and the repository that holds them.
##
## The repository knows git and nothing about what a save contains; the player knows what a player
## is. This is the piece that knows **a save is the player, the clock and the world** — and it is
## the only place that composes them.
##
## The pipeline, in the order the save plan gives it: bring the repository up → load the last save →
## (the world regenerates itself) → reconcile the player → advance the clock → put the ship back
## where it was.

const Repo := preload("res://addons/spacesim/save/world_repo.gd")
const Player := preload("res://addons/spacesim/player/player.gd")

## The history the very first story gets, when nobody has been asked for a name yet.
const FIRST_HISTORY := "Traveller"

var repo: SpacesimWorldRepo
var player: SpacesimPlayer

## The world's clock, in seconds from the world's epoch. Saved with the player, because it is the
## point in the world's time that this history stands at.
var world_time: float = 0.0

## What the last operation has to say, for the screen to show. Empty when there is nothing to say.
var message: String = ""

## The player and the clock as they were last written or loaded. A save with nothing changed is
## refused rather than committed — and the real-time stamp is deliberately not part of this, or the
## file would differ from the last one by a few seconds every time and nothing would ever be
## "nothing changed".
var _last_body: String = ""


static func for_world(world_name: String) -> SpacesimSession:
	return SpacesimSession.new(Repo.for_world(world_name))


func _init(repository: SpacesimWorldRepo) -> void:
	repo = repository
	player = Player.new()


## Bring the world up. A save is a commit, so anything uncommitted was never a save — most likely a
## crash between writing the files and committing — and is dropped first.
##
## With no repository, or none with a save on the current history, the first story starts at the
## world's beginning and is saved straight away, so the next startup has something to load.
func start(system: SpacesimSystemScene) -> Dictionary:
	if repo.exists():
		repo.discard_working_tree()
		if load_last():
			message = "the last save"
			return {"ok": true, "reason": ""}
	else:
		# The reference field is named "world" on disk — the persistence sense, not the system.
		var created := repo.create({"world": system.name, "format_version": system.format_version})
		if not created["ok"]:
			return created
	var began := repo.create_history(FIRST_HISTORY)
	if not began["ok"]:
		return began
	player.reset()
	world_time = system.start_time
	var written := save(system)
	message = "a new story" if written["ok"] else written["reason"]
	return written


## The state as it stands at the last save. No git operation at all: HEAD already *is* the last
## save, which is why loading on startup needs no bookkeeping.
func load_last() -> bool:
	if not _apply(Repo.read_state(repo.read_text(Repo.STATE_FILE))):
		return false
	_read_deleted()
	return true


## Load a save — which is the do-over, and costs everything after it: the history's tip moves back
## so the later saves leave the list. The world's own state is not among the restored paths, so the
## world has moved on regardless.
func load(hash: String) -> Dictionary:
	var restored := repo.restore(hash)
	if restored["ok"]:
		_apply(Repo.read_state(repo.read_text(Repo.STATE_FILE)))
		_read_deleted()
	return restored


## Start a history from the trunk: a fresh world and a fresh player, without ending the one being
## played. The history and the player are named separately, because they are separate things.
func new_story(name: String, system: SpacesimSystemScene, player_name := Player.DEFAULT_NAME) -> Dictionary:
	var created := repo.create_history(name)
	if not created["ok"]:
		return created
	player.reset(player_name)
	world_time = system.start_time
	return save(system)


## Write the player and the clock out as a save.
func save(system: SpacesimSystemScene) -> Dictionary:
	if _body() == _last_body:
		message = "nothing has changed since the last save"
		return {"ok": false, "reason": message}
	var files := {Repo.STATE_FILE: Repo.state_text(player.to_dictionary(), world_time, now())}
	var written := repo.save(files, label(system))
	if written["ok"]:
		_last_body = _body()
	# Saved silently would leave the player unable to tell whether it worked: the header above them
	# only changes when the clock does.
	message = written["reason"] if not written["ok"] else "saved"
	return written


## Everything about the player and the clock, as it would be written.
func _body() -> String:
	return "%s|%s" % [JSON.stringify(player.to_dictionary()), world_time]


## A save's label: the world's date and time, and where the player is. Never coordinate numbers.
func label(system: SpacesimSystemScene) -> String:
	return "%s   %s" % [system.format_time(world_time), system.describe(player.location, player.assets)]


## The saves on this history, newest first, less the ones that have been deleted.
func saves() -> Array:
	var kept: Array = []
	for entry in repo.saves():
		if not player.deleted.has(String(entry["hash"])):
			kept.append(entry)
	return kept


## What loading this save would destroy, for the confirmation.
func affected_saves(hash: String) -> Array:
	var kept: Array = []
	for entry in repo.affected_saves(hash):
		if not player.deleted.has(String(entry["hash"])):
			kept.append(entry)
	return kept


## A save's state as it stood, for looking at one before loading it.
func preview(hash: String) -> Dictionary:
	return Repo.read_state(repo.preview(hash))


## Deleting a save is a tombstone, not a rewrite: taking a save out of the middle of a history needs
## a rebase, which can conflict, while a tombstone cannot. The commit stays in the repository.
func delete_save(hash: String) -> Dictionary:
	if player.deleted.has(hash):
		return {"ok": true, "reason": ""}
	player.deleted.append(hash)
	var written := _write_deleted()
	if not written["ok"]:
		player.deleted.erase(hash)
	return written


## A tombstone is its own file and its own commit: writing the player's state here would make
## deleting a save *be* a save, and it would appear in the very list it was just removed from.
func _write_deleted() -> Dictionary:
	var written := repo.save(
		{Repo.DELETED_FILE: JSON.stringify(player.deleted.duplicate()) + "\n"}, "deleted a save"
	)
	message = written["reason"] if not written["ok"] else "deleted a save"
	return written


## Seconds from the world's epoch to now, for the clock and for how long the player was away.
static func now() -> float:
	return Time.get_unix_time_from_system()


func _apply(state: Dictionary) -> bool:
	if state.is_empty():
		return false
	player.from_dictionary(state)
	world_time = float(state.get(Repo.FIELD_WORLD_TIME, 0.0))

	# While the player was away the slow things kept happening, so the world's clock has moved on
	# and the player has not. Loading an old save therefore costs *more* elapsed time than the
	# player lived through — and the clock never runs backwards, even if the machine's does.
	var away := now() - float(state.get(Repo.FIELD_SAVED_REALTIME, now()))
	if away > 0.0:
		world_time += away
	_last_body = _body()
	return true


## The tombstones are their own file, and are the record of what the player has deleted.
func _read_deleted() -> void:
	var text := repo.read_text(Repo.DELETED_FILE)
	if text.strip_edges().is_empty():
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) == TYPE_ARRAY:
		player.deleted = Array(parsed)
		_last_body = _body()
