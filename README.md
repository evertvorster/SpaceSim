# SpaceSim

**SpaceSim is a game engine** built on [Godot](https://godotengine.org) — rendering, physics, the
simulation framework, persistence, coordinate spaces and a modding platform.

**Every planet in it is derived from its chemistry, and so is the picture of it.** No body here is a
texture, a hand-picked colour or a height map drawn in an editor: a system file states what a body is
*made of*, and its mass, its air, its temperature, its clouds, its colour and its terrain all come out of
that.

**Cladogenesis** is a story/world built on it (not yet a repo). SpaceSim uses **no vegastrike
assets** and is not a vegastrike port; that codebase is only a reference for what to avoid.

## Everything is derived

**A body is what it is made of.** A system file gives composition — how much iron, how much water, how much
ammonia, how much of it is rock — and an orbit. Everything else is arithmetic on that, including everything
you can see:

```
composition            →   mass and radius, at the density it implies
mass and the star's lux →   surface gravity, and the air it can hold
the air and the star    →   temperature, and the greenhouse that air implies
temperature and pressure→   which volatiles condense, and at what altitude
the minerals and ices   →   albedo and colour
all of the above        →   what the shader draws
```

**Nothing in that column is authored on the right.** A cloud's base is not a number someone chose: it is
the altitude where the air reaches the condensation point of something it carries — which is why Earth's
water sits at 1.4 km and its ice at 7.7 km, at the tropopause where rising air stops and what it carried
freezes out. It is why Venus has clouds at 52 km made of **sulphuric acid rather than water**: the model
puts the condensate at the right level, and the atmosphere has the wrong molecule in it. It is why Jupiter
bands twice — cream and brown circulation cells, and a broad white veil above them whose opacity varies
across a latitude envelope — while a body with no surface gets an opaque interior floor at the depth the
model stops claiming to know its air.

**The surface is the same discipline**, one level down: plates standing and sagging, a region term slower
than a plate so one continent stands higher than another, mountain belts where plates meet, and every
octave weighted by what the pixel can resolve. The coast is a level set of the height, not a line drawn
anywhere.

**Sol is the falsifier, not the target.** The model is *plausible, not exact*, and derived from composition
rather than fitted to the solar system: when a body comes out wrong the derivation is wrong, and a body
that comes out right for the right reason is the evidence. Values are computed once when the system loads
and then held, so a number that can change while playing is an exception that has to justify itself.

**Every number the engine invents says so.** A constant that is neither derived nor measured is marked
`A GUESS:` in the code with what would settle it, and the register is `grep -rn "A GUESS:" addons/`.

## Status

**Early, but real — and the drawing side of it is done.** Sol and the player are the game now, not a demo:
coordinate frames, the travel unit, a data-driven system, navigation markers, settings, a player who can be
saved, loaded and browsed, bodies whose surfaces **subdivide as you approach them**, and **the stars**: the real
sky above Sol, from the HYG catalogue, with an exposure metered from the **rendered frame** on the GPU and
adapting in **stops** — exponential, so it closes a large gap quickly and fine-tunes a small one.

**The surface is derived, not authored, and it is not a texture.** What a body's surface *is* comes from the
phase of its composition — a Voronoi plate partition with each plate standing or sagging, a region term slower
than a plate so one continent stands higher than another, structure inside each plate, and mountain belts where
plates meet. **The shader evaluates that field itself, per pixel**, at the resolution the pixel can resolve: a
coastline is a level set of the height, so it is exactly as smooth as whatever carries it, and a raster carries
it as a staircase one texel wide. The octave count is the pixel footprint's, which is what makes it affordable —
a 20-pixel moon pays for one octave, the ground at walking height for eighteen. **The relief is the geometry's**:
vertices are translated on the CPU to their height, so the light falls on the slope that was drawn. The sea is a
level on its own mesh at the datum, coplanar with the land and complementary to it by one threshold.

**The air is a stack of shells, one band per shell, worn by the body.** Each marches its own ray's chord through
its band, which is why bands sum to the column and no shell needs to know the eye's altitude. It draws the far
face as well as the near one (`cull_front`), so **the air in front of a mountain is drawable**, and where the
march stops comes from the frame's depth rather than a depth test — a mountain standing in the way is harmless.
A `CompositorEffect` before the exposure pass draws the **fog** and nothing else: the fog is a medium at the eye,
over the whole view, which a per-pixel shell clipped at the frame's depth cannot express.

**The clouds are drawn, and a stack of them.** A deck is **the ground's own patch mesh translated to its level** —
the same lattice, the same chunks, the same index array — so one tessellation serves the surface and every deck
over it. Its thickness is not built, it is **sampled**: the layer's base and top are both real derived radii, and
the shader composites a slab whose opacity is Beer–Lambert, `1 − exp(−τ·thickness/μ)`, so a deck thickens at the
limb for the physical reason. Which face a fragment is decides how it is lit — **reflection above, transmission
below** — so a deck seen from underneath shows what got through the slab rather than a black void. The coverage
is **reconstructed** rather than interpolated (a cloud's edge is a level set, and bilinear has a corner at every
texel), and **one optical depth per layer** feeds the alpha, the base's light and the ground's shadow, which is a
ray test against the same map rather than a shadow map.

**A body can have several, and two of them are new.** Earth draws water at 1.4 km under an **ice sheet at 7.7 km**
— a gas that states a `solid_form` gets a level at the **tropopause**, where rising air stops and what it carried
freezes out, which needs no authored altitude. Jupiter draws a **diffuse white veil above its ammonia**, a haze
layer whose opacity varies over a broad latitude envelope, because Jupiter bands *twice*: the cream and brown
bands are the circulation cells and the broad white zones span several of them. A body with **no surface** draws
an opaque interior floor at the depth the model stops claiming to know the troposphere, so a gap between two decks
shows darkness and never stars.

**What a stack still wants, now that the decks themselves are done**: the air as **one band per stack level**
rather than one per body, and a fog that reads **the deck the eye is inside** instead of the top one. Neither is
needed for the decks to look right from outside.

There is no physics and no simulation.

## Saves

A save is a commit: **a world per repository, a history per playthrough, a save per commit**, in
`$XDG_DATA_HOME/spacesim/worlds/<world>/`. Loading an older save moves the history back and restores
only the player's own state — the world's state is left alone, so the world has moved on. The game
loads the last save on startup and puts you back in the frame it names.

**There is no autosave: a save is a deliberate act.** The button on the personal data screen (Escape)
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
  render/          what is drawn: the surface (the field itself, per pixel, with the ramp and the
                   relief normal), the ocean, the patch quadtree and the level law, the cloud
                   decks (the ground's mesh per layer, coverage reconstructed, one tau per layer),
                   the opaque interior of a surface-less body, the air as a stack of shells, and
                   the atmosphere pass, which now draws only the fog
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
the planets placed where JPL says they were at J2000. **`+` `-`** throttle, ten seconds from a stop
to full and the same speed astern, **Backspace** stops, **mouse** yaws and pitches, **`[` `]`** roll,
and **`1`–`6`** fix the view forward, back, left, right, up and down — six fixed directions, so one
cloud can be looked at from every side while the mouse still steers. **T** cycles the selected target,
**P** hides the bodies, **O** the ship and **L** draws wireframe. **Escape** opens the personal data
screen, **Alt+C** the settings screen — and the mouse is the ship's while flying and the screen's while
one is open. **`F10`** frees the pointer, and a click in the view takes it back. Every one of these
is a binding in the settings file — see `bindings.*` in [`docs/API.md`](docs/API.md). Both screens
pause the game. On the personal data screen **Save** and **New Story** act on the world, and the
histories and their saves are browsed and acted on there — playing, renaming or deleting a history,
loading or deleting a save. **Only names are editable**: the player's own, each thing they hold, and
a history's. A name of the player's waits for **Save**, a history's **Rename** happens at once
because it is a `git branch -m`, and every other value belongs to the game rather than to a field.
Loading always says first which saves it would remove.

Movement keys and the screen hotkeys are **bindings** in the settings file, so they can be changed
there without a rebuild.

## Settings

**Frame rate**: `vsync` (enabled, disabled, adaptive, mailbox) and a cap that is either a fixed rate or a
**fraction of the panel's own refresh** — half of a 240 Hz laptop is 120, and the same setting on a 60 Hz
screen is 30. Both are choices on the settings screen's **Display** tab.

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
