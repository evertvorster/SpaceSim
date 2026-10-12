class_name SpacesimPlayer
extends RefCounted
## The player: attributes and assets.
##
## **Player-owned state**, per the world/player boundary — the world keeps the record of what the
## player did, the player keeps who they are and what they carry. A save will hold this; nothing
## persists it yet.
##
## **Attributes** are named values, starting with the player's own name; currency belongs here
## too, because it is a quantity rather than a thing. **Assets** are things the player holds, each
## with a name, a type and a value, so there is somewhere for the rest of an asset to go without
## the screen having to change.
##
## Both sets are placeholder content — one line each to change, and the screen reads whatever is
## here rather than naming anything itself.

const DEFAULT_NAME := "Traveller"
const DEFAULT_ATTRIBUTES := {
	"Name": DEFAULT_NAME,
	"Credits": 0,
	"Condition": 100,
	"Knowledge": 0,
}
const DEFAULT_ASSETS := [
	{"name": "Playground Lander", "type": "lander", "value": 120000},
]

var attributes: Dictionary = {}
var assets: Array = []


func _init(player_name := DEFAULT_NAME) -> void:
	reset(player_name)


## Back to the starting state, without throwing the player away.
func reset(player_name := DEFAULT_NAME) -> void:
	attributes = DEFAULT_ATTRIBUTES.duplicate()
	attributes["Name"] = player_name
	assets = []
	for asset in DEFAULT_ASSETS:
		assets.append((asset as Dictionary).duplicate())


## The name to show for the player. Kept here rather than beside the player so there is one copy.
func display_name() -> String:
	return String(attributes.get("Name", DEFAULT_NAME))
