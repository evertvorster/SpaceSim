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

## **Seconds from the Big Bang to `world_time = 0`** — the age of the universe, `13.787 Gyr`
## (Planck 2018), over Julian years. The strip shows both clocks as a count from here, because a count from
## a calendar epoch says nothing at the aeons this engine can cross, and `world_time`'s own year 0 is the
## calendar's, not the cosmos's.
const SECONDS_SINCE_BANG := 13.787e9 * 365.25 * 86400.0

## **How fast the world's clock runs per second of the player's**. **1.0, and that is deliberate for now** —
## Evert, 2026-11-08: *"The clock should be ticking, one second at a time. When we do relativistic travel,
## the universe clock will be running faster."*
##
## The divergence is a real design (`Relativity and the Two Clocks` §1: `v_eff = c·tanh(v_f/c)`, and the
## world's clock advances by `v_f / v_eff` per second of the crew's), and **it is not built**. When it is,
## this function is where it lands and everything that advances a clock already goes through it.
static func clock_rate(_fantastical_speed: float) -> float:
	return 1.0


## A world (or player) time as seconds since the Big Bang, in whole seconds.
##
## **The number is float64 seconds at 4.35e17, where one ULP is about 97 s**, so the last two digits of the
## count are noise at that scale — an hour of flight lands within a minute or two of where it should. That is
## worth nothing against a geological clock and it is why the display shows whole seconds with separators
## rather than pretending to a precision the arithmetic does not have.
static func since_bang(seconds: float) -> int:
	return int(round(SECONDS_SINCE_BANG + seconds))


## **A long number a person can read**: thousands separators every three digits.
##
## Deliberately hand-rolled rather than `String.num_int64` or a locale: the answer must not change with the
## machine's locale, and a nineteen-digit count is the one number in this interface that needs the eye's
## help. Negative numbers keep their sign and group on the magnitude, which is what a clock before the
## epoch has to do.
static func grouped(value: int) -> String:
	var text := str(absi(value))
	var grouped_text := ""
	for index in text.length():
		if index > 0 and (text.length() - index) % 3 == 0:
			grouped_text += ","
		grouped_text += text[index]
	return ("-" if value < 0 else "") + grouped_text


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
