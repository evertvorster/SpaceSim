class_name SpacesimGit
extends RefCounted
## The git command line, and nothing else.
##
## Git is the only thing that knows git's rules, so validation asks it rather than reimplementing
## them — [method is_valid_branch_name] is the test, not this class's opinion.
##
## Identity is passed inline on every call so nothing depends on the machine's git config: a shipped
## game cannot assume `user.name` is set, and a global `commit.gpgsign` would otherwise make
## unattended commits fail.

## Characters git refuses anywhere in a branch name — plus `/`, which is legal but makes a hierarchy
## rather than a name, which is not what somebody typing their own name means.
const REFUSED := [" ", "~", "^", ":", "?", "*", "[", "]", "\\", "/", "@"]

var directory: String


func _init(repo_directory: String) -> void:
	directory = repo_directory


## Run git here. Returns `{"ok": bool, "code": int, "lines": PackedStringArray}`.
##
## Blocking, and deliberately so: every use of it is a deliberate act — a save, a listing — never
## anything per-frame. A save measures at about 11 ms.
func run(arguments: Array) -> Dictionary:
	var command := PackedStringArray(
		[
			"-c",
			"user.name=SpaceSim",
			"-c",
			"user.email=spacesim@localhost",
			"-c",
			"commit.gpgsign=false",
			"-C",
			directory,
		]
	)
	command.append_array(PackedStringArray(arguments))
	var captured: Array = []
	var code := OS.execute("git", command, captured, true)
	# OS.execute appends the program's whole output as ONE string, not one element per line — the
	# splitting is ours to do.
	var lines := PackedStringArray()
	if not captured.is_empty():
		lines = String(captured[0]).split("\n")
	return {"ok": code == 0, "code": code, "lines": lines}


## The output as one string.
func text(result: Dictionary) -> String:
	return "\n".join(result["lines"])


func is_clean() -> bool:
	var result := run(["status", "--porcelain"])
	return result["ok"] and text(result).strip_edges().is_empty()


## Whether git will accept this as a branch name. Asked, not reimplemented.
func is_valid_branch_name(name: String) -> bool:
	return run(["check-ref-format", "--branch", name])["ok"]


## A branch name that a name somebody typed can be turned into.
##
## **[method is_valid_branch_name] still decides** — this only gets close. A test feeds it a corpus
## of awkward names and asserts git accepts every result, which is why the rules need not be
## enumerated here with any confidence.
static func slug(text: String) -> String:
	var slugged := ""
	for index in text.length():
		var code := text.unicode_at(index)
		var character := text.substr(index, 1)
		if code < 32 or code == 127 or REFUSED.has(character):
			slugged += "-"
		else:
			slugged += character

	while slugged.contains("--"):
		slugged = slugged.replace("--", "-")
	while slugged.contains(".."):
		slugged = slugged.replace("..", ".")
	slugged = slugged.strip_edges()
	while slugged.begins_with("-") or slugged.begins_with("."):
		slugged = slugged.substr(1)
	while slugged.ends_with("-") or slugged.ends_with("."):
		slugged = slugged.substr(0, slugged.length() - 1)

	if slugged.ends_with(".lock"):
		slugged += "-"
	if slugged.is_empty():
		slugged = "player"
	return slugged
