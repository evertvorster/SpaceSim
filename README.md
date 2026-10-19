# SpaceSim

**SpaceSim is a game engine** built on [Godot](https://godotengine.org) — rendering, physics, the
simulation framework, persistence, coordinate spaces and a modding platform.

**Cladogenesis** is a story/world built on it (not yet a repo). SpaceSim uses **no vegastrike
assets** and is not a vegastrike port; that codebase is only a reference for what to avoid.

## Status

**Early, but real.** Sol and the player are the game now, not a demo: coordinate
frames, the travel unit, a data-driven system, navigation markers, settings, a player who can be
saved, loaded and browsed, a body whose surface **subdivides as you approach it**, and **the stars**:
the real sky above Sol, from the HYG catalogue, with an exposure that can be tuned to the observer
rather than metered from the frame.

**The surface is derived, not authored.** What a body's surface *is* comes from the phase of its
composition — a Voronoi plate partition with each plate standing or sagging, a region term slower than a plate
so one continent stands higher than another, structure inside each plate, and mountain belts where plates meet.
The field is baked to an `R16F` map on the GPU, refined on the render thread as the eye approaches, and the near
field is a quadtree of tiles. Below the map's texel a **detail ladder continues the field's own octaves** — the
same function, evaluated deeper — and the sea is its own layer, coplanar with the land and complementary to it by
one threshold.

**The air is one volumetric march over the whole frame.** A `CompositorEffect` at `POST_TRANSPARENT`, before the
exposure pass, marching one ray per pixel with sixteen samples along it and eight toward the sun, light scattered
by the species mix the body is made of. It draws the air over a planet's *disk* from space, the limb, and the sky
from underneath, because it owns every pixel rather than a shell that can only be where the geometry is. Measured
in flight the same day the surface landed: **339 fps / 2.9 ms**, from 423 m inside it.

**The clouds are not drawn.** The map, its percentile threshold and a reflectance ramp fitted to the measured mean
all exist and are tested, and the direction is a **baked deck for the far regime** composited inside the air pass
— which stands behind the switch argument in a vault doc rather than in the code. The near regime (parallax, a
silver lining, an underside) is deliberately unbuilt. There is no terrain displacement, no physics and no
simulation.

**The star data is third-party and is licensed separately from the code.** `addons/spacesim/sky/`
holds HYG v4.4 (Hipparcos + Yale Bright Star + Gliese) under **CC BY-SA 4.0**, which is compatible
with this repository's GPL-3.0 because the data and the code are separate works. Attribution, the
exact source, the file format and the calibration are in `addons/spacesim/sky/PROVENANCE.md`, and the
reduction is reproducible with `tools/build_star_catalogue.py`.

## Saves

A save is a commit: **a world per repository, a history per playthrough, a save per commit**, in
`$XDG_DATA_HOME/spacesim/worlds/<world>/`. Loading an older save moves the history back and restores
only the player's own state — the world's state is left alone, so the world has moved on. The game
loads the last save on startup and puts you back in the frame it names.

**There is no autosave: a save is a deliberate act.** The button on the personal data screen (Tab)
is the only way one happens, and the same screen browses the histories and their saves.

## Layout

```
addons/spacesim/   the engine library (idiomatic Godot addon layout)
  coordinate/      compartmentalised coordinate spaces and threshold transitions
  travel/          the local unit of travel (speed scales with distance to the nearest body)
  system/          the built scene (SpacesimSystemScene), the Kepler solver, and beneath it:
    content/       the authored content as Godot Resources — bodies, orbits, layers, species
    model/         the derivation: what a body's numbers are, from what it is made of
  lighting/        the star as a physical light (lux), and the camera exposure that keeps it readable
  render/          what is drawn: the surface, the ocean, the patch quadtree, the level law, the
                   render-thread map bake, and the air as one volumetric march over the frame
  player/          the player's own state (attributes and assets) and the screen for it
  navigation/      the overlay: a ring at each object, a short line, and its label, placed
                   so labels never overlap and a moon yields to its planet only where the two
                   compete for the same space
  settings/        declared defaults in code, one machine-written file for what differs
  save/            git-backed saves: the repository, the histories, the session, the do-over
  ui/              chrome shared by the full-screen screens, and the dialogs over them
systems/           authored systems as `.tres` — Sol, and the playground flight-test fixture
game/              the game: fly Sol and land on planets
tests/             headless tests; `shader_check.sh` compiles the shaders for real and
                   `screenshot.gd` renders a frame to a PNG, both under xvfb — headless Godot
                   compiles no shaders and draws nothing
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

It starts in `game/main.tscn`, flying **Sol** from `systems/sol.tres` — the real solar system, with
the planets placed where JPL says they were at J2000. **W/S** throttle, **mouse** pitch and yaw,
**A/D** roll, **T** to cycle
the selected target, **Esc** releases the mouse (click to take it back). **P** hides the bodies and
**`[` `]`** change their tessellation, which is how the frame-cost questions get answered rather
than guessed at. **Tab** opens the personal data screen and **Alt+C** the settings screen; both
pause the game. On the personal data screen **Save** and **New Story** act on the world, and the
histories and their saves are browsed and acted on there — playing, renaming or deleting a history,
loading or deleting a save. **Only names are editable**: the player's own, each thing they hold, and
a history's. A name of the player's waits for **Save**, a history's **Rename** happens at once
because it is a `git branch -m`, and every other value belongs to the game rather than to a field.
Loading always says first which saves it would remove.

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

Runs the suite headless and smoke-loads the game scene, and fails if Godot reported any error. Two
reasons that matters: a GDScript error aborts the function it happens in without failing the run, so
a broken check can silently skip; and the test scene never loads the game scene, so a parse error in
a game script would otherwise stay quiet until somebody launched the game.

`GODOT=/usr/bin/godot-mono tests/run.sh` runs it on another build.

```
SPACESIM_TESTS=save,session tests/run.sh
```

Runs only the suites whose path contains one of those words. The whole run takes minutes, because
the playground flight test drives ~120000 steps.

## Documentation

- [`docs/API.md`](docs/API.md) — the engine as it is. Updated with the code.
- Design, planning and bug-hunting notes live in the project notes vault (Obsidian,
  `Notes/Projects/SpaceSim/`), not in this repo.

## License

**GPL-3.0-or-later.** See [`LICENSE`](LICENSE).

The engine is copyleft; content and stories built on it choose their own terms.
