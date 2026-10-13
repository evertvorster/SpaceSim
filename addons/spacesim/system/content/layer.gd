class_name SpacesimLayer
extends Resource
## One shell of a body's interior. `radius` is the layer's **outer boundary**, not its thickness,
## so a thickness can never contradict the boundary it sits inside.

@export var layer_name: String = ""
@export var radius: float = 0.0 ## metres, outer boundary
## Mass fractions per species, summing to 1. Keys are species in the material table.
@export var composition: Dictionary[String, float] = {}
