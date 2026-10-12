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

## World

`addons/spacesim/world/` — a world loaded from data, and the scene it builds. **Content, not
engine:** the file says what exists; the engine builds the frames, geometry, scale bodies and
transition rules from it. A different world file should not require engine changes.

### World file

JSON, in `worlds/`. `worlds/playground.json` is the placeholder system. On-disk formats are part of
the public interface, so the format is versioned (`format_version`).

| Field | |
|---|---|
| `format_version` | int |
| `name` | world name, shown in the demo readout |
| `frames` | `system_band`, `atmosphere_band`, `surface_band` ([min, max] metres), `atmosphere_altitude`, `surface_altitude` (metres), `pad_size` |
| `start` | `body` (an id) and `altitude` (metres above that body's surface) |
| `bodies[]` | `id`, `name`, `kind`, `radius`, `position` (system frame, metres), `color`, `landable`, `significant` |

A body that is not `landable` gets geometry and a scale body but no frames — something to fly past
or into, not somewhere to go. `significant` is whether it is worth marking on screen: a body can be
worth flying to without being worth a label, and every rock in a belt is the latter. A generated
universe will add `seed` and `generator_version` here; the playground is hand-authored and has
neither.

### `SpacesimWorldBody` — `RefCounted`

The data half comes from the file; the node half is filled in by `build()`.

| Member | |
|---|---|
| `id`, `name`, `kind: String` | |
| `radius: float` | metres |
| `position: Vector3` | in the system frame |
| `color: Color`, `landable: bool` | |
| `node: Node3D`, `mesh: MeshInstance3D` | built |
| `atmosphere`, `surface: SpacesimFrame` | built when landable, null otherwise |
| `scale_body: SpacesimScaleBody` | built |
| `static from_dictionary(data) -> SpacesimWorldBody` | |

### `SpacesimWorld` — `RefCounted`

| Member | |
|---|---|
| `static from_file(path) -> SpacesimWorld` | null on a read or parse failure |
| `static from_dictionary(data) -> SpacesimWorld` | |
| `build(parent) -> SpacesimWorld` | builds the scene; the observer is the caller's business |
| `name`, `bodies: Array[SpacesimWorldBody]` | |
| `container: Node3D`, `system_frame: SpacesimFrame`, `frame_tree: SpacesimFrameTree` | built |
| `body_by_id(id) -> SpacesimWorldBody` | |
| `scale_bodies() -> Array[SpacesimScaleBody]` | every body, for the travel unit |
| `meshes() -> Array[MeshInstance3D]` | every body's mesh, for the hide/detail debug keys |
| `ship_start() -> Vector3` | the world's start position |
| `star() -> SpacesimWorldBody` | |
| `aim_sun_at(position) -> void` | aims the star's light at a position |
| `body_for_surface_frame(frame) -> SpacesimWorldBody` | |
| `place_landing_zone(body, point) -> void` | puts a body's landing zone on the surface under `point` |

**Landing zone.** A surface frame's origin is wherever the ship came down, not one fixed site —
otherwise landing anywhere else would leave the ship millions of metres from its own frame's
origin, which defeats the frame. On entering a surface frame the world moves that body's zone
under the observer and then puts the observer back where it was: the frame moves, the world does
not.

**Lighting.** A single directional light cannot light a whole system from its star, so
`aim_sun_at()` re-aims it at wherever the player is. The planet you are at is lit correctly; the
one on the far side of the star is lit from its own side rather than the near one.

## Navigation

`addons/spacesim/navigation/` — navigation markers: a name and distance for the objects that
matter right now.

Two presentations, one projection. **On screen:** a `Label3D` at the object's position,
billboarded and at a constant screen size, depth tested — because it sits at the object's *centre*,
the object's own projected area eats it, so it needs no distance or size test and no fade.
**Off screen:** a `Label` in a `CanvasLayer`, clamped to the viewport edge in the direction that
would bring the object into view.

The set is rebuilt every frame and the nodes are **pooled, not allocated**; the pool size is the
screen-space budget in one place.

### `SpacesimMarkers` — `Node3D`

| Member | |
|---|---|
| `Priority` | `CONTEXT`, `MISSION`, `SELECTED` |
| `pool_size: int` | the cap, and the screen-space budget |
| `context_targets`, `mission_targets: Array[Node3D]` | ambient group, then mission objectives |
| `selected: Node3D` | the selected target, or null |
| `refresh(camera) -> void` | rebuild the set and draw it; call once a frame |
| `static choose(candidates, limit) -> Array[Dictionary]` | the keyed union for one frame |
| `static clamp_to_edge(point, size, margin) -> Vector2` | the smallest turn that brings a point into view |
| `static screen_direction(camera, target) -> Vector2` | viewport direction, valid behind the camera |
| `static format_distance(metres) -> String` | `1.50 Gm`, `2.5 km`, `12 m` |

**The set is keyed, prioritised and capped.** One marker per object — a body that is both a
mission target and in the ambient group gets one label, not two stacked on it. Priority decides
what survives the cap: selected target, then mission targets, then the ambient group, nearest
first within a group. Capping by distance instead would cut off precisely the off-screen objects
the pointers exist for.

**`unproject_position()` is wrong behind the camera** (it mirrors, so a pointer would send you the
opposite way). `screen_direction()` exists for that case and is tested for it.

Which objects are marked is the caller's business; this decides only how they are drawn.

## Settings

`addons/spacesim/settings/` — declared defaults in code, and **one machine-written file** for what
differs.

This is the shape Godot recommends and the shape Godot itself uses: `project.godot` carries only
values that differ from the engine defaults, and `override.cfg` layers a sparse per-install file
over it. `ConfigFile.get_value(section, key, default)` is built around the same idea — the default
argument exists because the key is expected to be absent.

### Where it lives

```
$XDG_CONFIG_HOME/spacesim/settings.cfg      player settings          (fallback ~/.config/...)
$XDG_DATA_HOME/spacesim/                    worlds and save branches (fallback ~/.local/share/...)
```

Not Godot's `user://`: that is a single writable directory, under the *data* home and nested
through `godot/app_userdata`, so it cannot separate configuration from data and it is not
`~/.config`. `SpacesimXdg` resolves the paths properly, and per the specification a variable that
is unset, empty, or **not an absolute path** is ignored.

### The file

INI via `ConfigFile`, machine read and written. Keys are `section.key`, which is how they appear:

```
[camera]
fov=85.0
range_space=Vector2(50, 50000000000)
[markers]
pool_size=8
```

**Sparse and self-cleaning.** A value equal to its declared default is erased rather than written,
so the file only ever holds what was changed, and returning a value to its default removes it. An
unknown key is preserved — a newer build may have written it.

**Reading is as careful as writing.** The file is the player's to edit, so every value is
sanitised on the way in: coerced when it is merely a whole number stored as an int, and replaced
by the declared default when it is the wrong type or out of range. A wrong camera range is a black
screen, so the `camera.range_*` keys carry component-wise bounds. Relational guards (a near plane
staying below a far plane) are not expressible in the registry; whichever code consumes the value
holds that end.

### Scope

A setting is either the player's business or the world's. World settings (`frames.*`) are read
from the world's own file, travel with the world as content, and **are never written to the
player's file** — a world value cannot be set by the player, and a player value cannot come from
the world.

### Hot by construction

> **Read through `get_value` and listen to `changed`. Never cache a setting in a variable at
> startup.**

That is the one thing that turns a hot setting cold, and retrofitting it means hunting down every
cached copy. A cheap setting is read at the point of use (`mouse.sensitivity`, the camera ranges);
an expensive one is pushed into an object by an `_apply_settings()` that runs at startup and again
on change (`camera.fov`, the marker pool and font size).

### The registry

| Key | Scope | Default |
|---|---|---|
| `mouse.sensitivity` | player | 0.0015 |
| `camera.fov` | player | 70.0 |
| `camera.range_space` / `_orbital` / `_atmosphere` / `_surface` / `_interior` | player | `Vector2(100, 1e11)` and so on |
| `markers.pool_size` | player | 12 |
| `markers.font_size` | player | 20 |
| `markers.margin` | player | 100.0 |
| `frames.system_band` / `_atmosphere_band` / `_surface_band` | world | `Vector2(1e4, 1e11)` and so on |
| `frames.atmosphere_altitude` / `_surface_altitude` / `_pad_size` | world | 100000.0 / 2000.0 / 4000.0 |

### Bindings

Input bindings live in the same file, under `[bindings]`, declared in the registry like any other
setting — a string with the `key_binding` validator:

```
[bindings]
settings_screen=Alt+C
throttle_up=W
detail_down=BracketLeft
```

Text rather than a raw keycode, so the file stays readable and hand-editable: the key name is
whatever `OS.get_keycode_string` produces, which `OS.find_keycode_from_string` parses back, so the
two agree by construction. Modifiers are prefixes and are **normalised** on write — `Alt+Shift+X`
comes back as `Shift+Alt+X`.

Matching uses the **physical** key, so WASD stays under the same fingers on a layout that puts A
somewhere else — which is why a binding stores a key rather than a character. Modifiers must match
exactly, so `W` does not fire while Alt is held.

| `SpacesimBindings` (static) | |
|---|---|
| `parse(text) -> Dictionary` | parts, or empty when the text is not a binding |
| `is_valid(text) -> bool` | |
| `keycode_of(text) -> int` | or `KEY_NONE`; for asking whether it is held |
| `matches(event, text) -> bool` | |
| `from_event(event) -> String` | for capturing a key press |
| `format(binding) -> String` | |

### The settings screen

**Alt+C** pauses the game and opens it — a binding, so it is rebindable. Modelled on the vegastrike
config screen:

- a control edits a **staging area**, not the live settings;
- **Reset** puts a setting back to its engine default, also staged;
- **Apply** commits everything staged and writes the file;
- **Close** discards the staged edits;
- **both Apply and Close change colour while something is staged** — since Close throws the work
  away, the colour is the warning rather than decoration;
- **Exit Game** leaves.

Rows come from the registry, so a newly declared setting appears without the panel changing.
Bindings are edited as text for now; capturing a key press is the next step.

| `SpacesimSettingsEdit` — `RefCounted` | |
|---|---|
| `static editable_keys() -> Array` | the player-scope keys, in registry order |
| `value(key) -> Variant` | staged if edited, otherwise what stands |
| `stage(key, value) -> bool` | false when the store would refuse it |
| `reset_to_default(key) -> bool` | staged, like any other edit |
| `discard() -> void`, `apply() -> int` | |
| `has_changes() -> bool` | |
| `changed` | emitted on any staging change |

`SpacesimSettingsPanel` — `Control` — is built in code, since the project has no editor-authored
scenes: `configure(settings)`, and the `closed` / `exit_requested` signals. The buttons drive the
edit directly.

### `SpacesimXdg` — `RefCounted` (static)

| Member | |
|---|---|
| `config_home()`, `data_home()`, `state_home()` | XDG base directories, with fallbacks applied |
| `config_dir()`, `data_dir()` | those, plus `spacesim` |
| `settings_path()` | `config_dir()/settings.cfg` |
| `ensure_directory(path)` | create it, recursively |

### `SpacesimSettings` — `Node`, registered as the `SpacesimSettings` autoload

| Member | |
|---|---|
| `Scope` | `PLAYER`, `WORLD` |
| `REGISTRY` | every declared setting, with the single declaration of its default |
| `changed(key, value)` | emitted after a value changes |
| `open(path := "")` | load; an empty path means the XDG location |
| `get_value(key) -> Variant` | the value that stands |
| `set_value(key, value, save_now := false) -> bool` | player settings only; false if refused |
| `reset_value(key, save_now := false) -> bool` | back to the default, erasing the key |
| `set_world_values(values)` | adopt the world's settings; never written to the player's file |
| `save(force := false) -> bool` | write, if there is anything to write |
| `static declared_keys()`, `scope_of(key)`, `default_of(key)` | |
| `static is_acceptable(key, value) -> bool` | whether the store would accept it — what the screen asks before staging |
| `KNOWN_VALIDATORS` | the named checks; a row naming anything else is a registry mistake |

`get_value` never touches the disk. Tests use their own instance with their own path, so the suite
never writes to the real file.

## Screens

`addons/spacesim/ui/screen.gd` — the chrome every full-screen modal shares: a dimmed backdrop, a
centred panel with a title, a scrollable content column and a button bar. Two screens with the
same chrome would drift apart, so there is one.

### `SpacesimScreen` — `Control`

| Member | |
|---|---|
| `PANEL_SIZE` | how big the panel is |
| `build_screen(title)` | build the chrome; a subclass then fills `content` and `actions` |
| `content: VBoxContainer` | where a subclass puts its rows |
| `actions: HBoxContainer` | where it puts its buttons |
| `add_button(label, on_pressed) -> Button` | add and connect a button in one line |
| `opened()` | called just before the screen is shown; rebuild anything stale here |
| `dismissed()` | called just before it is hidden, **whatever the route** — so tidying up does not depend on which button happened to be pressed |
| `closed` | signal, emitted to ask the scene to hide the screen |

`SpacesimSettingsPanel` and `SpacesimPlayerPanel` are the two subclasses. The settings panel uses
`dismissed()` to throw staged edits away, which is what its amber Close button warns about.

## Player

`addons/spacesim/player/` — the player's own state: what they are and what they carry.
Player-owned per the world/player boundary; a save will hold it, and nothing persists it yet.

### `SpacesimPlayer` — `RefCounted`

| Member | |
|---|---|
| `DEFAULT_NAME`, `DEFAULT_ATTRIBUTES`, `DEFAULT_ASSETS` | the placeholder starting state |
| `attributes: Dictionary` | named values, starting with `Name`. Currency lives here too, being a quantity rather than a thing |
| `assets: Array` | things held, each `{name, type, value}` — the shape leaves room for the rest of an asset |
| `display_name() -> String` | |
| `reset(player_name) -> void` | back to the starting state, as copies rather than the consts |

Both sets are placeholder content: one line each to change, and the screen reads whatever is there
rather than naming anything itself.

### `SpacesimPlayerPanel` — `SpacesimScreen`

The personal-data screen, on **Tab**. Sections are built from the player's own dictionaries —
attributes as a two-column table, assets as name / type / value — so adding an attribute needs no
change here. Rebuilt on `opened()`, so a value that changed while it was hidden cannot be stale.

**Save and load will live here.**

## Save and load

`addons/spacesim/save/` — a world per repository, a history per playthrough, a save per commit. The
design and the measured feasibility are in the vault (`Save and Load Plan`); this is what exists.

### `SpacesimGit` — `RefCounted`

The git command line, and nothing else. **Git decides what a valid branch name is**, so
`is_valid_branch_name` asks it rather than reimplementing the rules; `slug` only gets close, and a
test feeds it a corpus of awkward names and asserts git accepts every result.

Every call passes `-c user.name`, `-c user.email` and `-c commit.gpgsign=false`, so nothing depends
on the machine's git config.

| Member | |
|---|---|
| `REFUSED` | what `slug` replaces: space, `~ ^ : ? * [ ] \ / @` |
| `run(arguments) -> Dictionary` | `{"ok", "code", "lines"}` — blocking, and only ever for a deliberate act |
| `text(result) -> String` | |
| `is_clean() -> bool` | |
| `is_valid_branch_name(name) -> bool` | asked of git |
| `static slug(text) -> String` | a branch name a typed name can become; total, so it always yields something |

### `SpacesimWorldRepo` — `RefCounted`

```
world.json    which world this is
world/        the world's durable state, written only when something changes it
player/       the player's state
```

The repo knows git and **nothing about what a save contains** — `save()` is handed the files to
write, so the format stays the caller's business, and `state_text`/`read_state` are only the
envelope.

| Member | |
|---|---|
| `static for_world(name) -> SpacesimWorldRepo` | under `$XDG_DATA_HOME/spacesim/worlds/` |
| `exists() -> bool`, `create(world_reference) -> Dictionary` | |
| `save(files, label) -> Dictionary`, `commit(label) -> Dictionary` | `{"ok", "reason"}`; a save with nothing changed is refused rather than faked |
| `discard_working_tree() -> bool` | a save is a commit, so uncommitted writes were never a save |
| `saves() -> Array`, `affected_saves(hash) -> Array` | `{"hash", "time", "subject"}` |
| `preview(hash, path) -> String` | read out of the commit; the working tree is untouched |
| `restore(hash) -> Dictionary` | the do-over: `reset --soft`, then a path-scoped checkout |
| `histories() -> Array`, `current_history()`, `has_history(name)` | |
| `create_history(name)`, `rename_history(from, to)`, `delete_history(name)`, `switch_history(name)` | all `{"ok", "reason"}` |
| `TRUNK`, `PLAYER_DIR`, `STATE_FILE`, `STATE_FORMAT_VERSION` | |
| `static state_text(player_data, world_time)`, `static read_state(text)` | |

**The trunk and the history you are playing cannot be deleted** — a new story branches from the
trunk, and git refuses a worktree's own branch anyway. Creating a history or switching first drops
anything uncommitted, because a dirty tree makes git refuse the switch.

### `SpacesimLocation` — `RefCounted`

Where something is: a frame, and a position in it. Turned into words by `SpacesimWorld.describe()`,
because saying "landed on Nix" needs the world's names and the player's assets — and `coordinate/`
should depend on neither.

| Member | |
|---|---|
| `frame_id: String`, `position: Vector3` | |
| `is_set() -> bool` | |
| `to_dictionary()`, `static from_dictionary(data)` | unreadable data gives an *unset* location, not an error |

`SpacesimFrame` gains `frame_id` (and `SYSTEM_ID` for the one frame every world has).
`SpacesimFrameTree` gains `register(frame)`, `frame_by_id(id)` and `resolve_frame(id)` — the last
resolving the **longest existing prefix**, so a save naming a frame the world no longer has is
placed at the frame that remains, at its origin, rather than refused.

### `SpacesimWorld` additions

| Member | |
|---|---|
| `frame_phrase(frame_id) -> String` | "landed on Nix", "above Nix", empty for a frame it does not have |
| `nearest_body_name(position) -> String` | |
| `format_time(seconds) -> String` | the world clock as a date, e.g. "Year 512, day 121" |
| `describe(location, assets) -> String` | the location chain as prose, innermost first |

`SECONDS_PER_DAY` and `DAYS_PER_YEAR` are placeholder calendar constants — a world that needs its own
calendar is a thing to build when a story does.

### `SpacesimPlayer` additions

| Member | |
|---|---|
| `location: SpacesimLocation` | the player and their ships are separate; they coincide when the player is inside one, which is containment |
| assets carry `id`, `name`, `type`, `value`, `location` | the id is generated once and never edited, because a location refers to it |
| `add_asset(name, type, value, at) -> Dictionary` | |
| `asset_by_id(id) -> Dictionary` | |
| `to_dictionary()` / `from_dictionary(data)` | unknown keys are ignored, so a newer save may carry more than this build knows |

## The game

`game/main.*` — fly around the playground system and land on planets. The world comes from a world
file; the scene adds input, the camera's render range, the two screens and a readout.
`game/player_ship.gd` builds and places the player's ship, so the headless tests fly the identical
world and ship.

| Key | |
|---|---|
| W / S | throttle |
| mouse | pitch and yaw (click to recapture after Esc) |
| A / D | roll |
| T | cycle the selected target |
| P | hide/show the bodies |
| `[` `]` | body tessellation, for attributing frame cost |
| Tab | pause and open the personal data screen |
| Alt+C | pause and open the settings screen |

Every one of those except Esc is a binding in the settings file and can be changed there. The two
screen hotkeys are read in `_input` rather than `_unhandled_input`, because Tab is also the UI's
focus key and the UI system would consume it first.

## Tests

`tests/` — headless, synchronous, no test framework dependency. See the README for the command.

## See also

- [`../README.md`](../README.md)
