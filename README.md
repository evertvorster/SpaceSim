# SpaceSim

**SpaceSim is a game engine** built on [Godot](https://godotengine.org) — rendering, physics, the
simulation framework, persistence, coordinate spaces and a modding platform.

**Cladogenesis** is a story/world built on it (not yet a repo). SpaceSim uses **no vegastrike
assets** and is not a vegastrike port; that codebase is only a reference for what to avoid.

## Status

**Early.** Coordinate frames and the travel unit exist, with tests, and a demo flies from
space to a planet's surface. No terrain, no physics, no persistence yet.

## Layout

```
addons/spacesim/   the engine library (idiomatic Godot addon layout)
  coordinate/      compartmentalised coordinate spaces and threshold transitions
  travel/          the local unit of travel (speed scales with distance to the nearest body)
demo/              fly from space to a planet's surface
tests/             headless test scripts
docs/API.md        what the engine exposes, as it is implemented
```

## Building and running

Requires the **double-precision Godot build** (the coordinate model works at AU scale). On this
machine:

```
/usr/bin/godot-double-mono    # 4.7.2.stable.mono.double
```

Open the project:

```
godot-double-mono --path .
```

It starts in `demo/space_to_surface.tscn` — **W/S** throttle, **mouse** pitch and yaw,
**A/D** roll, **Esc** releases the mouse.

## Tests

```
timeout 120 godot-double-mono --headless --path . res://tests/run_tests.tscn
```

Exits non-zero on a failed check. Run it under `timeout`: a suite that fails to compile cannot
reach its own `quit()`, and a hung test process is worse than a failed one. The suite includes
flying the demo world from space to the surface headless.

## Documentation

- [`docs/API.md`](docs/API.md) — the engine as it is. Updated with the code.
- Design, planning and bug-hunting notes live in the project notes vault (Obsidian,
  `Notes/Projects/SpaceSim/`), not in this repo.

## License

**GPL-3.0-or-later.** See [`LICENSE`](LICENSE).

The engine is copyleft; content and stories built on it choose their own terms.
