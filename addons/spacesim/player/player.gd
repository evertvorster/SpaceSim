class_name SpacesimPlayer
extends RefCounted
## The player: what they are and what they carry.
##
## **Player-owned state**, per the world/player boundary — the world keeps the record of what the
## player did, the player keeps who they are, where they are and what they have. A save holds this.
##
## **Attributes** are named values, starting with the player's own name; currency belongs here too,
## because it is a quantity rather than a thing. **Assets** are things the player holds: each has a
## stable `id` (a location refers to it, and a name can change), a name, a type, a value and a
## location of its own.
##
## **The name is the player's own, independent of the history's** — the history is a label on a
## timeline ("mankind") and the player is a person ("Adam") — and it is changeable, since it is
## just an attribute.
##
## The player and their ships are **separate** — they coincide when the player is inside a ship,
## which is expressed by the player's frame being the ship's interior frame, and the ship is
## elsewhere when they do not.

const DEFAULT_NAME := "Traveller"
const DEFAULT_ATTRIBUTES := {
	"Name": DEFAULT_NAME,
	"Credits": 0,
	"Condition": 100,
	"Knowledge": 0,
}
const DEFAULT_ASSETS := [
	{"name": "Playground Lander", "type": "ship", "value": 120000},
]

const FIELD_ATTRIBUTES := "attributes"
const FIELD_LOCATION := "location"
const FIELD_ASSETS := "assets"
const FIELD_ID := "id"
const FIELD_NAME := "name"
const FIELD_TYPE := "type"
const FIELD_VALUE := "value"

var attributes: Dictionary = {}
var location: SpacesimLocation
var assets: Array = []


func _init(player_name := DEFAULT_NAME) -> void:
	reset(player_name)


## Back to the starting state, without throwing the player away. Asset ids are made fresh, because
## the old ones are gone with the old state.
func reset(player_name := DEFAULT_NAME) -> void:
	attributes = DEFAULT_ATTRIBUTES.duplicate()
	attributes["Name"] = player_name
	location = SpacesimLocation.new(SpacesimFrame.SYSTEM_ID, Vector3.ZERO)
	assets = []
	for record in DEFAULT_ASSETS:
		assets.append(_make_asset(record))


func display_name() -> String:
	return String(attributes.get("Name", DEFAULT_NAME))


## Give the player something. The id is generated here because a location refers to it.
func add_asset(asset_name: String, type: String, value: int, at: SpacesimLocation) -> Dictionary:
	var record := {FIELD_NAME: asset_name, FIELD_TYPE: type, FIELD_VALUE: value}
	if at != null:
		record[FIELD_LOCATION] = at.to_dictionary()
	var asset := _make_asset(record)
	assets.append(asset)
	return asset


func asset_by_id(id: String) -> Dictionary:
	for asset in assets:
		if String(asset.get(FIELD_ID, "")) == id:
			return asset
	return {}


func to_dictionary() -> Dictionary:
	return {
		FIELD_ATTRIBUTES: attributes.duplicate(true),
		FIELD_LOCATION: location.to_dictionary(),
		FIELD_ASSETS: assets.duplicate(true),
	}


## Restore from a save. Keys this build does not know are ignored, so a newer save may carry more
## than it understands rather than failing.
func from_dictionary(data: Dictionary) -> void:
	attributes = data.get(FIELD_ATTRIBUTES, {}).duplicate(true)
	assets = data.get(FIELD_ASSETS, []).duplicate(true)
	location = SpacesimLocation.from_dictionary(data.get(FIELD_LOCATION, {}))


func _make_asset(record: Dictionary) -> Dictionary:
	var asset := record.duplicate(true)
	asset[FIELD_ID] = _new_asset_id()
	if not asset.has(FIELD_LOCATION):
		asset[FIELD_LOCATION] = SpacesimLocation.new().to_dictionary()
	return asset


## Generated once and never edited, so a location naming it keeps working when the player renames
## the thing.
func _new_asset_id() -> String:
	var candidate := ""
	while candidate.is_empty():
		candidate = "%08x" % (randi() & 0xffffffff)
		for asset in assets:
			if String(asset.get(FIELD_ID, "")) == candidate:
				candidate = ""
				break
	return candidate
