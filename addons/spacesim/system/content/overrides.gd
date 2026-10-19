class_name SpacesimBodyOverrides
extends Resource
## **Content wins.** Any derived value may be pinned here, and the derivation then leaves it alone.
##
## `set` names which of the following are actually pinned, because 0.0 is a legitimate value for
## several of them — without it an absent field and a zero one look alike.

@export var set: PackedStringArray = []
@export var luminosity: float = 0.0 ## watts
@export var albedo: float = 0.0 ## Bond albedo
@export var mean_surface_temperature: float = 0.0 ## kelvin
@export var surface_color: Color = Color.WHITE
@export var atmosphere_tint: Color = Color.WHITE
