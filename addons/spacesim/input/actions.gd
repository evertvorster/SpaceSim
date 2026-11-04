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
## - **rate** — a value produced every frame and self-centering to zero: roll, and later a stick.
## - **level** — a value that *persists* and is changed by its inputs: throttle. A key winds it up
##   while held and releasing it leaves the level where it got to.
##
## The distinction is what makes a key and a stick the same action: a key into a `rate` is ±1 (full
## rate, instantly); a stick into a `rate` is its deflection; a key into a `level` winds it at full
## rate. See `SpacesimBinding` for how a binding declares which of those it is.
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
		"defaults": ["Tab"],
	},
	"throttle_up": {
		"label": "Throttle up",
		"kind": "level",
		"category": "Flight",
		"defaults": ["Shift+Equal"],
	},
	"throttle_down": {
		"label": "Throttle down",
		"kind": "level",
		"category": "Flight",
		"defaults": ["Minus"],
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
	"roll_left": {
		"label": "Roll left",
		"kind": "rate",
		"category": "Flight",
		"defaults": ["BracketLeft"],
	},
	"roll_right": {
		"label": "Roll right",
		"kind": "rate",
		"category": "Flight",
		"defaults": ["BracketRight"],
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
