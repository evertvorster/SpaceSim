# SpaceSim Engine API

> **This file documents the engine as it is.** Only interfaces that exist in the code are listed
> here. Design, planning and bug-hunting notes live in the project notes (Obsidian,
> `Notes/Projects/SpaceSim/`) — not in this repo.

## Update rule

When a public interface is added or changed, update this file in the same commit. On-disk data
format versions are part of the public interface.

## Coordinate frames

`addons/spacesim/coordinate/` — compartmentalised coordinate spaces and the threshold rules that
move things between them. See the project notes for *why*.

All frames use metres. There is no unit scaling between frames: an AU-scale system frame and a
metre-scale surface frame differ only in how far their children sit from the origin.

### `SpacesimFrame` — `Node3D`

A coordinate space with its own local origin. A frame's own transform is its origin and
orientation expressed in its *parent* frame, so the frame chain is the chain of coordinate spaces
and a frame's children are what lives in that space.

| Member | |
|---|---|
| `kind: Kind` | `SPACE`, `ORBITAL`, `ATMOSPHERE`, `SURFACE`, `INTERIOR` |
| `travel_length_min`, `travel_length_max: float` | the band of local lengths this frame spans, in metres — see the travel unit below |
| `to_frame_position(outer_position) -> Vector3` | a position in the outermost space, expressed in this frame |
| `to_outer_position(frame_position) -> Vector3` | the inverse |

### `SpacesimTransitionRule` — `RefCounted`

A distance threshold that moves an observer between two frames. Rules are one-way and
single-shot: an `ENTER` rule fires when the observer reaches its threshold altitude *and* is in
`from_frame`. Returning is a separate `EXIT` rule with its own threshold, so hysteresis is data
rather than a special case.

```gdscript
SpacesimTransitionRule.new(from_frame, to_frame, reference, reference_radius, altitude, direction)
```

| Member | |
|---|---|
| `from_frame`, `to_frame: SpacesimFrame` | |
| `reference: Node3D` | body the altitude is measured from |
| `reference_radius: float` | its radius, in metres |
| `altitude: float` | threshold above that surface, in metres |
| `direction: Direction` | `ENTER` (fires at or below) or `EXIT` (at or above) |
| `altitude_of(outer_position) -> float` | metres above the reference surface; negative inside |
| `matches(outer_position) -> bool` | whether this rule wants a switch right now |

### `SpacesimFrameTree` — `Node3D`

Owns the rules and moves an observer between frames as it crosses thresholds.

| Member | |
|---|---|
| `observer: Node3D` | the node whose frame membership is tracked |
| `automatic: bool` | evaluate on every physics tick (default `true`) |
| `active_frame: SpacesimFrame` | read-only in practice; set via `enter_frame()` |
| `frame_changed(observer, from_frame, to_frame)` | emitted after a switch |
| `add_rule(rule) -> void` | |
| `enter_frame(frame) -> void` | move the observer into a frame without consulting rules (initial placement) |
| `evaluate() -> void` | switch frames if a threshold has been crossed; safe to call every tick |

A switch is a `reparent()` that preserves the observer's pose, so the observer does not move when
its coordinate space changes.

## Travel unit

`addons/spacesim/travel/` — how fast you move, given how close the nearest significant
thing is. Speed is never stored on the ship; motion is expressed in units of the local
neighbourhood, so travelling fast in the void and slowly near a planet or a base falls out
of the unit rather than being imposed on top of a flight model.

### `SpacesimScaleBody` — `RefCounted`

Something whose proximity sets the travel unit. Which bodies count as significant is
content's decision.

```gdscript
SpacesimScaleBody.new(node: Node3D, radius: float)
```

| Member | |
|---|---|
| `node: Node3D` | the body's origin |
| `radius: float` | metres |
| `surface_distance_to(position) -> float` | distance to the *surface*, never negative |

### `SpacesimProximity` — `RefCounted` (static)

| Member | |
|---|---|
| `nearest_body(position, bodies) -> SpacesimScaleBody` | nearest, or `null` |
| `nearest_surface_distance(position, bodies) -> float` | or `INF` when nothing is near enough to matter |

### `SpacesimTravelScale` — `RefCounted` (static)

| Member | |
|---|---|
| `TRAVERSE_SECONDS: float` | seconds to cross the local neighbourhood at full throttle |
| `local_length(distance, length_min, length_max) -> float` | the local neighbourhood, in metres, held within the frame's band; `INF` reads as the largest scale, never zero |
| `speed_for(throttle, distance, length_min, length_max, traverse_seconds) -> float` | m/s for a throttle in [0, 1] |

Speed is *derived*, never integrated: there is no speed to desync and no way to arrive too
fast, because the limit falls with the remaining distance by construction.

## Demo

`demo/space_to_surface.*` — fly from space to a planet's surface. The world is built in
code (`demo/scale_world.gd`) so `tests/test_space_to_surface.gd` can fly the identical
world headless.

## Tests

`tests/` — headless, synchronous, no test framework dependency. See the README for the command.

## See also

- [`../README.md`](../README.md)
