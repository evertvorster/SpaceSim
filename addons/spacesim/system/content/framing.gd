class_name SpacesimFraming
extends Resource
## The frame conventions a system declares: the travel bands each kind of frame spans, and the
## altitudes at which an observer crosses between them.
##
## Real scale needs a wide system band: the playground spanned 1e11 m, but Neptune sits at
## 4.5e12 m. Widened here accordingly.

@export var system_band: Vector2 = Vector2(1.0e4, 1.0e13) ## metres, min/max local length
@export var atmosphere_band: Vector2 = Vector2(2.0e3, 4.0e5)
@export var surface_band: Vector2 = Vector2(1.0e2, 5.0e3)
@export var atmosphere_altitude: float = 1.0e5 ## metres above the surface: space -> atmosphere
@export var surface_altitude: float = 2.0e3 ## metres above the surface: atmosphere -> surface
@export var pad_size: float = 4.0e3 ## metres; the landing pad at the zone
