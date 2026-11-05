extends SceneTree
## What Godot sees of the input devices that are attached, printed and then quit.
##
## A probe, not a test: it reports what the engine says on this machine rather than asserting a
## contract, so it is deliberately outside the suite.
##
##     godot-double-mono --path . --script res://tests/probe_devices.gd
##
## **It works headless** — measured 2026-11-04: the joypad driver is started by the platform layer and
## does not need a display server, so `--headless` reports a connected pad normally. Run it under
## `xvfb-run` only if that ever stops being true.

const AXES := ["LEFT_X", "LEFT_Y", "RIGHT_X", "RIGHT_Y", "TRIGGER_LEFT", "TRIGGER_RIGHT"]

## JoyButton's order in Godot 4.7. Named here because the engine exposes the constants but no
## string lookup for them.
const BUTTONS := [
	"A / down", "B / right", "X / left", "Y / up", "BACK", "GUIDE", "START", "LEFT_STICK",
	"RIGHT_STICK", "LEFT_SHOULDER", "RIGHT_SHOULDER", "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT",
	"DPAD_RIGHT", "MISC1", "PADDLE1", "PADDLE2", "PADDLE3", "PADDLE4", "TOUCHPAD",
]


func _init() -> void:
	print("display server: ", DisplayServer.get_name())
	print("os:             ", OS.get_name())
	var pads := Input.get_connected_joypads()
	print("joypads:        ", pads, "  (", pads.size(), ")")
	if pads.is_empty():
		print("  none, or none visible to this display server")

	for device in pads:
		print("")
		print("--- device ", device)
		print("  name       ", Input.get_joy_name(device))
		print("  guid       ", Input.get_joy_guid(device))
		print("  known      ", Input.is_joy_known(device), "   (a mapping in SDL's database)")
		print("  vibration  ", Input.has_joy_vibration(device))
		print("  info       ", Input.get_joy_info(device))
		var axes := PackedStringArray()
		for axis in AXES.size():
			axes.append("%s %.3f" % [AXES[axis], Input.get_joy_axis(device, axis)])
		print("  axes at rest: ", ", ".join(axes))
		var down := PackedStringArray()
		for button in BUTTONS.size():
			if Input.is_joy_button_pressed(device, button):
				down.append(BUTTONS[button])
		print("  buttons held: ", "none" if down.is_empty() else ", ".join(down))
	quit()
