class_name SpacesimDebug
## **`--debug` on the command line, and nothing else.** The diagnostic prints this project has grown —
## what a shell was handed, what a walk answered, what the wireframe did — are worth keeping and worth
## reading, but they are not worth a line of stderr on every launch: a real fault report and a debug
## echo read the same way in a log, and the log is where a flight gets diagnosed.
##
## Evert, 2026-11-02: *"The debug printouts that have already been added to the game needs to be behind
## a --debug switch."*
##
## **Set once, in `game/main.gd::_ready`, before anything can print.** `enabled` is a plain static
## because a worker thread may want to say something too and must not reach for a node to ask.
##
## Usage: `godot-double-mono --path . -- --debug`, or `spacesim --debug` once packaged.
static var enabled := false


## Say one line, if it was asked for.
static func say(message: String) -> void:
	if enabled:
		print(message)
