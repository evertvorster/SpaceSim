# SpaceSim

**SpaceSim is a game engine** — the reusable infrastructure layer: rendering, physics, the
simulation framework, persistence, coordinate spaces, and a modding platform.

It follows the same **engine vs. story** split as vegastrike (engine vs. assets):

- **SpaceSim = the engine.**
- **Cladogenesis = a story/world built on it** *(planned; not yet a repo)* — an episodic game
  about bootstrapping a civilization across deep time. Cladogenesis is the first proof that the
  engine can carry a story, not the only one possible.

## Relationship to vegastrike

SpaceSim is **not** a vegastrike port or remake, and it uses **no vegastrike assets**. The
vegastrike codebase is a reference for *what to avoid*: config-system sprawl, save-format
fragility, coordinate precision workarounds, and a static economy. It is lessons, never spec.

## Stack

- **Godot** — engine framework, settled. Open source, so it has longevity independent of any
  vendor.
- **`precision=double` build** required for the coordinate model. On this machine:
  `godot-double-mono` (`/usr/bin/godot-double-mono`) — Godot 4.7.2 mono, double precision.
- **GDScript first** for prototyping (no build step). Systems that stabilize and prove heavy
  migrate to **C#**, or **C++ via GDExtension** for measured hot paths only. **GDScript stays**
  for UI, scenes and wiring.
- **Prototyping is not converting — graduating a system is a rewrite.** Module boundaries are
  therefore defined early so each heavy system sits behind a stable interface and the language
  swap is contained.
- **Static content is data** (JSON / `.tres`) — never code. Models are glTF/GLB authored in
  Blender; Godot does assembly and runtime procedural mesh generation, not modelling.

## Status

**Pre-code — design and planning.** The repo is being set up; no engine code yet.

Design direction lives outside this repo, in Evert's notes vault (Google Drive,
`Notes/Projects/SpaceSim/`):

| Doc | Content |
|---|---|
| `Requirements.md` | Engine requirements; engine-owns-capability / story-owns-content split |
| `Simulation and Save Design.md` | World-vs-player saves, seed-regenerable universe, semi-dynamic economy |
| `Coordinate and Spatial Scale.md` | Compartmentalized coordinate spaces; the spatial-scale validation demo |
| `Procedural Generation.md` | "Model what you see, rest is data" — seeds and seed-LOD |
| `Stack and Languages.md` | Godot; the GDScript → C#/GDExtension split |

Two of those are gates before engine work: the **save/universe format is planned before the
engine**, and the engine's **first proof is the seamless spatial-scale demo** (space → atmosphere →
land → walk → launch, with no loading screens).

## Layout

```
docs/API.md   living engine API contract (updated with every interface change)
```

More directories appear as the parts they hold appear — not before.

## Contributing / authoring

Engine-facing interfaces are documented in [`docs/API.md`](docs/API.md), which is a **contract**:
any change to a public interface carries a matching doc edit in the same commit. On-disk data
formats (universe, saves, resources) are part of that contract and are versioned.

The longer-term goal is that an author with no engine knowledge can build content — and an entire
episode — from the documentation alone.

## License

**GPL-3.0-or-later.** See [`LICENSE`](LICENSE).

The engine is copyleft. Content and stories built on it (such as Cladogenesis) are free to choose
their own terms — the engine does not mandate a license for content.
