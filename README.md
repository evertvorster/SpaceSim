# SpaceSim

**SpaceSim is a game engine** built on [Godot](https://godotengine.org) — rendering, physics, the
simulation framework, persistence, coordinate spaces and a modding platform.

**Cladogenesis** is a story/world built on it (not yet a repo). SpaceSim uses **no vegastrike
assets** and is not a vegastrike port; that codebase is only a reference for what to avoid.

## Status

**Pre-code.** Design and planning are in progress; there is no engine code yet.

## Layout

```
addons/spacesim/   the engine library (idiomatic Godot addon layout)
demo/              validation scenes
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

## Documentation

- [`docs/API.md`](docs/API.md) — the engine as it is. Updated with the code.
- Design, planning and bug-hunting notes live in the project notes vault (Obsidian,
  `Notes/Projects/SpaceSim/`), not in this repo.

## License

**GPL-3.0-or-later.** See [`LICENSE`](LICENSE).

The engine is copyleft; content and stories built on it choose their own terms.
