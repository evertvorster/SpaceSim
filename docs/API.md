# SpaceSim — Engine API

> **Living document.** This is the engine's API contract, and it is updated on **every** add or
> change to an engine-facing interface — in the same commit as the code. Documentation drift is a
> defect, not a backlog item.

## Why this file exists

Two reasons, both from the engine requirements:

1. **Doc-as-contract.** Writing down an interface before depending on it catches drift early —
   including drift in our own heads.
2. **Third-party authoring.** An author with no engine knowledge must be able to build content
   and episodes from documentation alone. That only works if the documentation is true.

## Rules

- Any change to a public interface (signature, field, signal, resource schema, file format)
  requires a matching edit here **in the same commit**.
- Format versions of on-disk data (universe/save/resource) are part of this contract. Changing a
  format without a version bump and a migration note is a defect.
- "Public" means: anything a story/content author (or another engine module) may touch. Private
  internals do not belong here.

## Module index

The heavy systems are kept behind stable interfaces so that a system can be rewritten in
another language (GDScript → C# → C++/GDExtension) as a contained replacement rather than a
project-wide rewrite. Boundaries are defined before the implementations land.

| Module | Responsibility | Interface | Status |
|---|---|---|---|
| Coordinate / spatial | Compartmentalized coordinate spaces, cross-frame transforms and proxies | — | not started |
| Procedural generation | Seed-based generation, seed-LOD, story constraints | — | not started |
| Simulation | Sim tick, events, economy state | — | not started |
| Persistence | Universe files, player saves, format versioning and migration | — | not started |

Status values: `not started` · `prototype (GDScript)` · `stabilized` · `migrated`.

## See also

- `../README.md` — what SpaceSim is, stack, status.
- Vault docs (Google Drive `Notes/Projects/SpaceSim/`) — design direction: Requirements,
  Simulation and Save Design, Coordinate and Spatial Scale, Procedural Generation,
  Stack and Languages.
