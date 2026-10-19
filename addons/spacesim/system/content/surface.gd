class_name SpacesimSurface
extends Resource
## What a body's surface is made of, as area fractions. Drives the area-weighted Bond albedo and
## the blended colour; both are derived.

@export var coverage: Dictionary[String, float] = {}
