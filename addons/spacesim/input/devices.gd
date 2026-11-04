class_name SpacesimDevices
extends RefCounted
## What the operating system's gamepads look like through Godot: **the names of their controls, and
## readers for them**.
##
## `AXIS_NAMES` and `BUTTON_NAMES` are **Godot's own order and Godot's own names** — the engine exposes no
## name-to-index helper at all (no `get_joy_button_string`, nothing joypad-related on `OS`), so this table
## is the only form the names have. That makes it two things at once, deliberately:
##
## - what the Devices tab labels its rows with;
## - **the vocabulary the binding text uses** — `Joy:<device>/Button:A`, `Joy:<device>/Axis:LEFT_X` — so a
##   control that can be seen can be written, and there is no second list to drift.
##
## Nothing here binds anything yet: the grammar that would use these names is reserved and rejected by
## `SpacesimBinding` until the pad work lands.
##
## **Godot normalises a recognised pad and does not for an unknown one**: a device with a mapping reports
## named buttons and axes in `[-1, 1]`, and one without reports raw indices. `is_known()` is that
## difference, and it is the one thing worth showing beside a device's name.

## In `JoyAxis` order, which is what `Input.get_joy_axis` takes.
const AXIS_NAMES := ["LEFT_X", "LEFT_Y", "RIGHT_X", "RIGHT_Y", "TRIGGER_LEFT", "TRIGGER_RIGHT"]

## In `JoyButton` order, which is what `Input.is_joy_button_pressed` takes. The first four are a pad's
## face buttons in Godot's own naming — a, b, x, y are positions, not letters printed on plastic.
const BUTTON_NAMES := [
	"A", "B", "X", "Y", "BACK", "GUIDE", "START", "LEFT_STICK", "RIGHT_STICK",
	"LEFT_SHOULDER", "RIGHT_SHOULDER", "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT",
	"MISC1", "PADDLE1", "PADDLE2", "PADDLE3", "PADDLE4", "TOUCHPAD",
]

## How far from the centre an axis has to be before it is worth colouring, so a worn stick that rests
## at 0.02 does not look deflected. This is a *display* threshold, not a binding's deadband.
const SHOWN_AS_MOVED := 0.1

## **How much a reading has to change between two looks to count as the axis moving** — not a deadband, a
## threshold on the *delta*, so a slow drift is not mistaken for an intent and a flick is.
const MOVED_ENOUGH := 0.15

## `SpacesimAxisProfile` is referenced by [method most_moved]; preloaded rather than named, so this module
## stays loadable on its own.
const AxisProfile := preload("res://addons/spacesim/input/axis_profile.gd")


## The connected devices, as device indices — **which are enumeration order**, so they are never stored.
static func connected() -> Array:
	return Input.get_connected_joypads()


static func name_of(device: int) -> String:
	var named := Input.get_joy_name(device)
	return named if not named.is_empty() else "unnamed device %d" % device


static func guid_of(device: int) -> String:
	return Input.get_joy_guid(device)


## Whether the engine has a mapping for it — the difference between named controls and raw indices.
static func is_known(device: int) -> bool:
	return Input.is_joy_known(device)


## The operating system's own name for the device, before Godot's controller database renamed it. A
## **diagnostic**: a name that matches `name_of` is a device the database agrees about.
static func raw_name_of(device: int) -> String:
	return String(Input.get_joy_info(device).get("raw_name", ""))


## The device index a **name** refers to, or −1 when it is not attached.
##
## **Names are the identity and indices are not** — an index is enumeration order — so a binding stores the
## name and this is what turns it back into something the engine takes.
static func device_index(named: String) -> int:
	for device in connected():
		if name_of(int(device)) == named:
			return int(device)
	return -1


## The index of an axis, by Godot's own name — `LEFT_X` → 0. −1 when the name is not one.
static func axis_index(named: String) -> int:
	return AXIS_NAMES.find(named)


## The index of a button, by Godot's own name — `A` → 0. −1 when the name is not one.
static func button_index(named: String) -> int:
	return BUTTON_NAMES.find(named)


static func axis(device: int, index: int) -> float:
	return Input.get_joy_axis(device, index)


## The buttons held down right now, by name.
static func pressed(device: int) -> Array:
	var down: Array = []
	for index in BUTTON_NAMES.size():
		if Input.is_joy_button_pressed(device, index):
			down.append(BUTTON_NAMES[index])
	return down


## **The axis that is being moved**, by index, or −1.
##
## An axis has no event to catch — it has a position — so detecting one means **watching the positions and
## taking the largest change since the last look**: whatever the player just did is the axis with the
## biggest delta, and nothing else comes close. Two guards keep that from firing on noise:
##
## - **the change has to be outside the deadband**, judged by that axis's own profile, or a worn stick at
##   rest would win the contest every time it was looked at;
## - **a button press suppresses it** (the caller's job, since it knows about buttons), because a player
##   pressing to bind means a button, and a stick nudged by the same hand should not steal it.
##
## `previous` is the readings from the last call, `axis name → value`; the caller keeps it, which is what
## makes "since the last look" a fact rather than a guess.
static func most_moved(
	device: int, previous: Dictionary, profile_of: Callable
) -> Array:
	var best_axis := -1
	var best_change := 0.0
	for index in AXIS_NAMES.size():
		var named: String = AXIS_NAMES[index]
		if not previous.has(named):
			continue
		var now: float = axis(device, index)
		var change: float = absf(now - float(previous[named]))
		if change < MOVED_ENOUGH:
			continue
		var profile: AxisProfile = profile_of.call(named)
		# **Outside the deadband by the profile's own reckoning**: shape() is exactly "is this axis doing
		# anything", and it is already the number the bindings will read.
		if absf(profile.shape(now)) <= 0.0:
			continue
		if change > best_change:
			best_change = change
			best_axis = index
	return [best_axis, best_change]


## Every axis, as `[name, value]` pairs, in `JoyAxis` order.
static func axes(device: int) -> Array:
	var found: Array = []
	for index in AXIS_NAMES.size():
		found.append([AXIS_NAMES[index], axis(device, index)])
	return found
