# SpaceSim

**SpaceSim is a game engine** built on [Godot](https://godotengine.org) — rendering, physics, the
simulation framework, persistence, coordinate spaces and a modding platform.

**Cladogenesis** is a story/world built on it (not yet a repo). SpaceSim uses **no vegastrike
assets** and is not a vegastrike port; that codebase is only a reference for what to avoid.

## Status

**Early, but real.** The playground world and the player are the game now, not a demo: coordinate
frames, the travel unit, a data-driven world, navigation markers, settings and a personal data
screen, all with tests. No terrain, no physics, no simulation, no persistence yet.

## Layout

```
addons/spacesim/   the engine library (idiomatic Godot addon layout)
  coordinate/      compartmentalised coordinate spaces and threshold transitions
  travel/          the local unit of travel (speed scales with distance to the nearest body)
  world/           a world loaded from data, and the scene it builds
  player/          the player's own state: attributes and assets
  navigation/      navigation markers (targets, off-screen pointers)
  settings/        declared defaults in code, one machine-written file for what differs
  ui/              chrome shared by the full-screen screens
worlds/            world files (content)
game/              the game: fly the playground system and land on planets
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

It starts in `game/main.tscn`, flying the **playground** system from
`worlds/playground.json` — **W/S** throttle, **mouse** pitch and yaw, **A/D** roll, **T** to cycle
the selected target, **Esc** releases the mouse (click to take it back). **P** hides the bodies and
**`[` `]`** change their tessellation, which is how the frame-cost questions get answered rather
than guessed at. **Tab** opens the personal data screen and **Alt+C** the settings screen; both
pause the game.

Movement keys and the screen hotkeys are **bindings** in the settings file, so they can be changed
there without a rebuild.

## Settings

Defaults live in code (the registry in `addons/spacesim/settings/settings.gd`); the player's file
holds only what differs from them, so a default that improves reaches anyone who never changed it.
It is machine read and written:

```
$XDG_CONFIG_HOME/spacesim/settings.cfg      player settings          (fallback ~/.config/...)
$XDG_DATA_HOME/spacesim/                    worlds and save branches (fallback ~/.local/share/...)
```

Not Godot's `user://`, which is one directory under the data home and cannot separate configuration
from data. See [`docs/API.md`](docs/API.md) for the keys and the file format.

## Tests

```
tests/run.sh
```

Runs the suite headless and smoke-loads the demo scene, and fails if Godot reported any error. Two
reasons that matters: a GDScript error aborts the function it happens in without failing the run, so
a broken check can silently skip; and the test scene never loads the demo scene, so a parse error in
a demo script would otherwise stay quiet until somebody launched the game.

`GODOT=/usr/bin/godot-mono tests/run.sh` runs it on another build.

## Documentation

- [`docs/API.md`](docs/API.md) — the engine as it is. Updated with the code.
- Design, planning and bug-hunting notes live in the project notes vault (Obsidian,
  `Notes/Projects/SpaceSim/`), not in this repo.

## License

**GPL-3.0-or-later.** See [`LICENSE`](LICENSE).

The engine is copyleft; content and stories built on it choose their own terms.
