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

## Tests

`tests/` — headless, synchronous, no test framework dependency. See the README for the command.

## See also

- [`../README.md`](../README.md)
