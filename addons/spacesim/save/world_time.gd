class_name SpacesimWorldTime
extends RefCounted
## The world clock as a **Terran** date and time — the calendar players already know, and Godot's own
## (proleptic Gregorian) date arithmetic rather than a table of months of ours.
##
## Here rather than on `SpacesimSystemScene`, where it used to live: **a built scene knows about its
## bodies, and nothing about calendars.** It was tested through a built system too, which is the tell —
## the test needed a system only because that is where the function was. Now it needs a number.
##
## The epoch is the world's, not Godot's: seconds are counted from the world's own year 0, so this
## constant is what a saved `world_time` *means*. Anything that stores or displays a world time goes
## through here.

## The unix time of `0000-01-01`, which is what a `world_time` of `0.0` reads as.
const EPOCH_AT_YEAR_ZERO := -62167219200


## A world time as `Y-M-D HH:MM`. Minutes are the finest thing any screen shows, so they are the finest
## thing this returns.
static func format(seconds: float) -> String:
	var when := Time.get_datetime_dict_from_unix_time(int(seconds) + EPOCH_AT_YEAR_ZERO)
	return "%d-%02d-%02d %02d:%02d" % [
		when["year"], when["month"], when["day"], when["hour"], when["minute"],
	]


## World-clock seconds for an ISO 8601 epoch, on the same calendar [method format] reads. The clock
## counts from year zero, so J2000 is a large positive number rather than a special case — which is what
## lets a system's authored epoch be a plain ISO date.
##
## The companion of [method format]; they are the two directions of one conversion and are here together
## so the epoch cannot mean one thing in one direction and another in the other.
static func clock_at_epoch(iso: String) -> float:
	if iso.is_empty():
		return 0.0
	return float(Time.get_unix_time_from_datetime_string(iso)) - EPOCH_AT_YEAR_ZERO
