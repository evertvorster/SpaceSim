class_name SpacesimActions
extends RefCounted
## Every action a player can take, declared once.
##
## **An action is what a player can do; a binding is one way to do it.** They used to be the same
## identifier — the settings key *was* the action, one key each. Separating them is what lets an action
## have several bindings, on several devices, and what lets the settings screen show "Throttle up"
## instead of `bindings.throttle_up`.
##
## ## `kind` — what the control *is*
##
## - **trigger** — edge-triggered. It fires and holds nothing: cycle target, bodies on/off.
## - **rate** — a value produced every frame and self-centering to zero: roll, and throttle up/down.
## - **level** — a value that *persists* and is set by its inputs: **nothing uses this yet.**
##
## The distinction is what makes a key and a stick the same action: a key into a `rate` is ±1 (full
## rate, instantly), and a stick into a `rate` is its deflection. See `SpacesimBinding` for how a
## binding declares which of those it is.
##
## ## Why throttle is a pair of rates and not a level
##
## `throttle_up` and `throttle_down` are **rates**: each says "+1 while I am held" or "-1", and the
## level they wind is the ship's own `throttle` field, integrated and clamped in `FlightController`
## where the rest of the flight model lives. Modelling throttle as one `level` action would need a
## direction per binding, which is a bigger change than the swap deserved.
##
## **`level` is reserved for the day a stick sets a value directly** — absolute or relative — which is
## the pad work, and it is why the kind exists in the vocabulary before anything uses it.
##
## ## `category` — where it is shown
##
## Groups the rows on the settings screen's Bindings tab. It is presentation, not behaviour.

const KINDS := ["trigger", "rate", "level"]

## The actions, in the order the settings screen shows them. **The ids are the old settings keys with
## `bindings.` dropped**, so an existing `settings.cfg` migrates by removing five characters.
const REGISTRY := {
	"settings_screen": {
		"label": "Settings",
		"kind": "trigger",
		"category": "Interface",
		"defaults": ["Alt+C"],
	},
	"player_screen": {
		"label": "Personal data",
		"kind": "trigger",
		"category": "Interface",
		# **Escape rather than Tab**: Escape is where a player's hand already goes for a menu, and the mouse
		# is released by opening any screen, which is what the key used to do on its own.
		"defaults": ["Escape"],
	},
	"throttle_stop": {
		"label": "Throttle stop",
		"kind": "trigger",
		"category": "Flight",
		"defaults": ["Backspace"],
	},
	"view_forward": {
		"label": "View forward",
		"kind": "trigger",
		"category": "Camera",
		"defaults": ["1"],
	},
	"view_back": {
		"label": "View aft",
		"kind": "trigger",
		"category": "Camera",
		"defaults": ["2"],
	},
	"view_left": {
		"label": "View left",
		"kind": "trigger",
		"category": "Camera",
		"defaults": ["3"],
	},
	"view_right": {
		"label": "View right",
		"kind": "trigger",
		"category": "Camera",
		"defaults": ["4"],
	},
	"view_up": {
		"label": "View up",
		"kind": "trigger",
		"category": "Camera",
		"defaults": ["5"],
	},
	"view_down": {
		"label": "View down",
		"kind": "trigger",
		"category": "Camera",
		"defaults": ["6"],
	},
	# **Turning had no action**: pitch and yaw came from the mouse's own motion, so a stick had nothing to
	# bind to and no key ever shipped for them. These four start with **no default binding**, which is why
	# adding them changes nothing for a keyboard and mouse player.
	# **The one key that gives the pointer back, as a toggle.** Flying needs the mouse captured — mouse look
	# reads relative motion, and a free pointer hits edges and sits over the view — so there has to be a way
	# out that is not a whole screen. Press to free it, press it again (or click in the view) to take it
	# back. **F10** because it is on every laptop's top row with no Fn combination, and nothing in this game
	# or in Godot's own `ui_*` defaults wants it.
	"mouse_release": {
		"label": "Free the mouse",
		"kind": "trigger",
		"category": "Interface",
		"defaults": ["F10"],
	},
	"cycle_target": {
		"label": "Cycle target",
		"kind": "trigger",
		"category": "Interface",
		"defaults": ["T"],
	},
	"bodies_toggle": {
		"label": "Bodies on/off",
		"kind": "trigger",
		"category": "Interface",
		"defaults": ["P"],
	},
	"wireframe_toggle": {
		"label": "Wireframe",
		"kind": "trigger",
		"category": "Interface",
		"defaults": ["L"],
	},
}

## The categories, in the order the Bindings tab shows them.
const CATEGORIES := ["Flight", "Camera", "Interface"]


static func ids() -> Array:
	return REGISTRY.keys()


static func has(id: String) -> bool:
	return REGISTRY.has(id)


static func row(id: String) -> Dictionary:
	return REGISTRY.get(id, {})


static func label_of(id: String) -> String:
	return String(row(id).get("label", id))


static func kind_of(id: String) -> String:
	return String(row(id).get("kind", ""))


static func category_of(id: String) -> String:
	return String(row(id).get("category", ""))


## The texts an action is bound to when the player has not changed anything.
static func defaults_of(id: String) -> Array:
	return row(id).get("defaults", [])


## The ids in one category, in registry order.
static func in_category(category: String) -> Array:
	var found: Array = []
	for id in REGISTRY:
		if category_of(id) == category:
			found.append(id)
	return found
