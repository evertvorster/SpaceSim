class_name SpacesimOrbit
extends Resource
## Keplerian elements. Position is a pure function of time from these — no integration, no state.
##
## Angles are in **degrees** (author-friendly); the solver converts. `mean_anomaly_at_epoch` is
## measured from the system's `epoch`, which for Sol is J2000.
##
## Semi-major axis is in metres; 1 au = 1.495978707e11 m.

@export var semi_major_axis: float = 0.0 ## metres
@export var eccentricity: float = 0.0
@export var inclination: float = 0.0 ## degrees, to the reference plane
@export var ascending_node: float = 0.0 ## degrees
@export var argument_of_periapsis: float = 0.0 ## degrees
@export var mean_anomaly_at_epoch: float = 0.0 ## degrees
