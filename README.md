# SpaceSim

**SpaceSim is a game engine** built on [Godot](https://godotengine.org) — rendering, physics, the
simulation framework, persistence, coordinate spaces and a modding platform.

**Cladogenesis** is a story/world built on it (not yet a repo). SpaceSim uses **no vegastrike
assets** and is not a vegastrike port; that codebase is only a reference for what to avoid.

## Status

**Early.** Coordinate frames, the travel unit and a data-driven world exist, with tests, and a demo
flies around a small solar system landing on planets. No terrain, no physics, no simulation, no
persistence yet.

## Layout

```
addons/spacesim/   the engine library (idiomatic Godot addon layout)
  coordinate/      compartmentalised coordinate spaces and threshold transitions
  travel/          the local unit of travel (speed scales with distance to the nearest body)
  world/           a world loaded from data, and the scene it builds
worlds/            world files (content)
demo/              fly the playground system and land on planets
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

It starts in `demo/space_to_surface.tscn`, flying the **playground** system from
`worlds/playground.json` — **W/S** throttle, **mouse** pitch and yaw, **A/D** roll, **Esc**
releases the mouse (click to take it back). **P** hides the bodies and **`[` `]`** change their
tessellation, which is how the frame-cost questions get answered rather than guessed at.

## Tests

```
timeout 120 godot-double-mono --headless --path . res://tests/run_tests.tscn
```

Exits non-zero on a failed check. Run it under `timeout`: a suite that fails to compile cannot
reach its own `quit()`, and a hung test process is worse than a failed one. The suite includes
flying the playground world headless: down to Terra's surface, back up, then across to Borealis.

## Documentation

- [`docs/API.md`](docs/API.md) — the engine as it is. Updated with the code.
- Design, planning and bug-hunting notes live in the project notes vault (Obsidian,
  `Notes/Projects/SpaceSim/`), not in this repo.

## License

**GPL-3.0-or-later.** See [`LICENSE`](LICENSE).

The engine is copyleft; content and stories built on it choose their own terms.
