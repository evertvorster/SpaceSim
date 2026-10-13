# SpaceSim Engine API

> **This file documents the engine as it is.** Only interfaces that exist in the code are listed
> here. Design, planning and bug-hunting notes live in the project notes (Obsidian,
> `Notes/Projects/SpaceSim/`) — not in this repo.

## The addon

`addons/spacesim/plugin.cfg` and `plugin.gd` are the Godot plugin entry point, so Godot can enable
the addon in the editor. The engine's classes are global by `class_name`, so nothing in the game
depends on the plugin being switched on.

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

## Solar system

`addons/spacesim/system/` — a solar system loaded from data, and the scene it builds, plus the
**content classes** ([code]content/[/code]) the derivation will read. **Content, not engine:** the
file says what exists; the engine builds the frames, geometry, scale bodies and transition rules
from it. A different system file should not require engine changes.

### System **content** — `content/`

The authored shape the derivation reads and the generator will emit: Godot **Resources**, saved as
`.tres`. **One format, not two** — this replaced a JSON system file on 2026-10-13, and there is no
converter and no second dialect.

A body that is not `landable` gets geometry and a scale body but no frames — something to fly past
or into, not somewhere to go. `significant` is whether it is worth marking on screen: a body can be
worth flying to without being worth a label, and every rock in a belt is the latter.

| Class | |
|---|---|
| `SpacesimSolarSystem` | `content/solar_system.gd` — the system: `content_version`, `epoch`, `framing`, `start_body_id`, `start_altitude`, `start_direction`, `start_world_time`, `bodies`. `system_name()` reads the primary star's name; `validate()` returns problems as prose |
| `SpacesimSystemBody` | `content/system_body.gd` — one body: `id`, `display_name`, `kind`, `parent_id`, `primary`, `radius`, `mass`, `rotation_period`, `axial_tilt`, `layers`, `orbit`, `fixed_position`, `atmosphere`, `surface`, `clouds`, `overrides`, `landable`, `significant` |
| `SpacesimLayer` | `content/layer.gd` — `layer_name`, `radius` (outer boundary), `composition` |
| `SpacesimOrbit` | `content/orbit.gd` — the six Keplerian elements, degrees |
| `SpacesimAtmosphere` | `content/atmosphere.gd` — `surface_pressure`, `species`, `variable_species` |
| `SpacesimSurface` | `content/surface.gd` — `coverage` |
| `SpacesimClouds` | `content/clouds.gd` — `fraction`, `albedo`, `color`, `opacity`. **Authored for now, derived later.** On the body rather than in the atmosphere, because a gas giant's visible surface *is* its cloud deck and the giants carry no atmosphere block. **Nothing draws a deck at present** — the shell that did was removed for standing `radius * 1.012` above the surface (76 km at Earth), which made it the outermost silhouette of every body. The content stays and is still read: `bond_albedo` needs `fraction` and `albedo`, and `color` is what a body with no surface coverage is drawn in |
| `SpacesimBodyOverrides` | `content/overrides.gd` — pinned derived values |
| `SpacesimFraming` | `content/framing.gd` — the travel bands and thresholds |
| `SpacesimMaterialTable`, `SpacesimSpecies` | `content/material_table.gd`, `content/species.gd` — the substances compositions name. `rayleigh`, `heat_capacity` (J/(kg·K)) and `greenhouse` (the grey infrared mass-absorption coefficient, or an explicit zero for a gas transparent in the infrared) are populated for every gas the authored atmospheres use **except water vapour's and ammonia's `rayleigh`**; `materials.tres` records where each number came from |

Data files: `addons/spacesim/system/content/materials.tres` (the material table; ships with the
engine) and `systems/sol.tres` (Sol — the **development and calibration** system, not shipped
content, since every system in the game is generated).

**Conventions.** SI units; angles in degrees. A layer's `radius` is its **outer boundary**, so a
thickness cannot contradict it. `rotation_period` is never negative and **retrograde is
`axial_tilt > 90`** (Venus 177.4, Uranus 97.77) — one place for the direction. `mass` is authored
for stars **and gas giants** (a constant-density layer model cannot represent a self-gravitating
body or a compressed envelope) and derived from the layers for everything else; 0.0 means derive. A
body with no `orbit` is fixed, so "orbiting *and* fixed" cannot happen rather than being rejected.

**`validate()`** reports fraction sums that are not 1 (skipping `variable_species`, which are
reference values for condensables), layer boundaries that do not ascend with the outermost equal to
the body radius, layer or surface fractions that are empty where they are required, a body that is
its own parent, a parent that is not in the system, a moon of a star, a parent chain that is a
cycle, a negative rotation period, and an axial tilt outside `[0, 180]`. It reports rather than
corrects: a silently repaired world is a wrong world nobody notices.

A body with **no `orbit` does not move** — it stands at its `fixed_position` — and that is a
perfectly good arrangement (a station, or a hand-placed placeholder such as every body in the
playground), not an error. The primary star is the exception: it is the centre of the system and
must not orbit anything.

### `SpacesimSceneBody` — `RefCounted`

One body's **built** half: the content it came from, and the nodes it was built into. The content
lives in `SpacesimSystemBody`; a resource is cached and shared, so the nodes live here instead.

| Member | |
|---|---|
| `content: SpacesimSystemBody` | the authored body this was built from |
| `id`, `name`, `kind: String` | |
| `radius: float` | metres |
| `position: Vector3` | in the system frame — fixed, or solved from the orbit |
| `color: Color`, `landable: bool`, `significant: bool` | |
| `parent_id: String`, `fixed_position: Vector3`, `orbit: SpacesimOrbit` | |
| `node: Node3D`, `mesh: MeshInstance3D` | built |
| `atmosphere_mesh: MeshInstance3D` | built — the air, on its own sphere reaching `radius + sky_top`; null when the body has no atmosphere |
| `sky_top: float` | **how far above the surface this body's air is worth drawing**, metres — derived from the air's own scale height, floored by `frames.atmosphere_altitude`. The camera's far plane needs it (`sky_reach()`); zero for a body with no air |
| `atmosphere`, `surface: SpacesimFrame` | built when landable, null otherwise |
| `scale_body: SpacesimScaleBody` | built |
| `static from_content(content) -> SpacesimSceneBody` | |
| `static color_of(content, materials) -> Color` | what content pinned, or `SpacesimSurfaceModel.color` — the derivation, not a placeholder |
| `orbits() -> bool` | |

### `SpacesimKepler` — `RefCounted`

Where a body is, from its elements. A **pure function of time**: no integration, no state, nothing
stepped forward, so a system is reproducible at any `t`.

| Member | |
|---|---|
| `G` | `6.6743e-11` |
| `static mu_of(total_mass) -> float` | `G(M + m)` — the **two-body** parameter; Jupiter's own mass shifts its period by half a day |
| `static period(orbit, mu) -> float` | seconds, 0 when the orbit or the mass is unknown |
| `static position_at(orbit, mu, t, epoch_time) -> Vector3` | in the parent's frame, ecliptic mapped to the engine's Y-up right-handed frame |

A body whose parent mass is not known does not move rather than moving wrongly — the rocky bodies
have no derived mass yet, so a moon of one stands still.

### `SpacesimSystemScene` — `RefCounted`

| Member | |
|---|---|
| `content: SpacesimSolarSystem` | the authored content it was built from |
| `static from_file(path) -> SpacesimSystemScene` | loads a `.tres` and works on a **copy**, since a resource is shared and building hangs nodes off it |
| `static from_content(content) -> SpacesimSystemScene` | |
| `static clock_at_epoch(iso) -> float` | world-clock seconds for an ISO epoch; J2000 is 63,113,947,200 |
| `build(parent) -> SpacesimSystemScene` | places the bodies, then builds; the observer is the caller's business |
| `name` | read from the primary star |
| `bodies: Array[SpacesimSceneBody]` | |
| `content_version() -> int` | the revision a save records |
| `container: Node3D`, `system_frame: SpacesimFrame`, `frame_tree: SpacesimFrameTree` | built |
| `body_by_id(id) -> SpacesimSceneBody` | |
| `scale_bodies() -> Array[SpacesimScaleBody]` | every body, for the travel unit |
| `meshes() -> Array[MeshInstance3D]` | every body's mesh, for the hide/detail debug keys |
| `ship_start() -> Vector3` | the system's start position |
| `star() -> SpacesimSceneBody` | |
| `illuminance_at(position) -> float` | the light at a position, in lux |
| `aim_sun_at(position) -> void` | aims the star's light at a position |
| `body_for_surface_frame(frame) -> SpacesimSceneBody` | |
| `air_body(frame) -> SpacesimSceneBody` | the body whose air that frame is inside — its atmosphere or surface frame — or null in space |
| `sky_reach(frame) -> float` | **how far the sky can be, in metres** — `sqrt(2) * sqrt(outer^2 - planet^2)`, or 0 in space. See **The far plane** below |
| `update_atmospheres(observer) -> void` | points every air shell at the observer and at its star. Called once a frame, like `aim_sun_at()` |
| `place_landing_zone(body, point) -> void` | puts a body's landing zone on the surface under `point` |

**Placement.** Bodies go down in dependency order rather than file order — a moon is placed relative
to its planet — and a body whose parent is not in the system says so instead of quietly landing at
the origin, which is inside the star. A body with no `orbit` does not move.

**Landing zone.** A surface frame's origin is wherever the ship came down, not one fixed site —
otherwise landing anywhere else would leave the ship millions of metres from its own frame's
origin, which defeats the frame. On entering a surface frame the system moves that body's zone
under the observer and then puts the observer back where it was: the frame moves, the ship does
not.

**Lighting.** A single directional light cannot light a whole system from its star, so
`aim_sun_at()` re-aims it at wherever the player is. The planet you are at is lit correctly; the
one on the far side of the star is lit from its own side rather than the near one.

**The far plane. The `camera.range_*` settings are floors, not ceilings.** They exist for depth
precision, and a far plane that small clips whatever is further away — which was `1e11` for space,
*less than one au*, so every body past 0.67 au and the star itself went undrawn. `_update_camera`
therefore raises `far` to cover what must be visible: the system in space, and **inside a body's air
both the sky and the system**, because a sky has the star and the other bodies in it.

The sky is much further away than it looks, which is why `sky_reach()` exists. The air is a *thin
skin* — 100 km over a 6,371 km planet — so the distance out to the shell is ~100 km straight up and
~1,130 km at the horizon. **And the longest ray is not the horizontal one:** for an observer at
radius `r`, `t(elevation) = -r*sin(e) + sqrt((r*sin(e))^2 + outer^2 - r^2)` and `dt/de` is negative
everywhere, so `t` is maximised by the most negative elevation that still misses the planet — the ray
that **grazes the limb and then climbs out**:

```
t_max = sqrt(r^2 - planet^2)  +  sqrt(outer^2 - r^2)
        the horizon distance      the horizon exit
```

Worst case over any altitude inside the air is `sqrt(2) * sqrt(outer^2 - planet^2)` — **Earth 1,603
km**. With the surface range's 200 km default the sky was drawn above 29° of elevation and everything
from there down to the horizon fell outside the plane and drew nothing: a black ring around the
observer, gone one frame up where the range changes.

### Derivation — `model/`

What a body's numbers *are*, computed from what it is made of. This is where the physics lives, and it
is what makes the authored Sol a calibration target rather than a fixture.

| Class | |
|---|---|
| `SpacesimStarModel` | `model/star_model.gd` — `static luminosity(body)`: what content pinned, or the piecewise mass–luminosity relation. `static effective_temperature(luminosity, radius)`: Stefan-Boltzmann, and **a check on the data rather than a restatement of it** — L and R are measured independently and the Sun's give 5772 K |
| `SpacesimSurfaceModel` | `model/surface_model.gd` — `static bond_albedo(body, materials)` and `static color(body, materials)`. The surface contribution is area-weighted over the coverage fractions. **The two deliberately disagree about the deck**: the albedo *includes* it, because the temperature depends on it, and the drawn colour does *not*, because the deck was drawn as its own layer on top — counting it in both places gave Earth (0.66, 0.69, 0.73), a colour only 1.15:1 from neutral, which the eye reads as grey. The split outlives the drawn deck, and should: the reflectance is physics and the colour is a picture |
### Temperature

| | |
|---|---|
| `static heat_capacity(atmosphere, materials) -> float` | the mix's specific heat, J/(kg·K) — **mass-weighted**, unlike every other mix here, because it is per kilogram. From `SpacesimSpecies.heat_capacity` |
| `static lapse_rate(atmosphere, materials, gravity) -> float` | the dry adiabatic lapse rate, `g/c_p`, K/m. **Derived, and a real check**: Earth's composition and gravity give 9.72 K/km against a textbook 9.8; Venus 10.46 against 10.5; Mars 4.43 against 4.4 |
| `static greenhouse_optical_depth(atmosphere, materials, gravity) -> float` | `sum(kappa_i * column_i)` over the infrared, where `column_i = x_i * (M_i/m-bar) * (p_surface/g)`. `kappa` is `SpacesimSpecies.greenhouse[0]`, and is **explicitly zero** for the gases transparent in the infrared, so "known transparent" and "not known" do not look alike |
| `static surface_temperature(atmosphere, materials, gravity, equilibrium) -> float` | **the greenhouse**: `T_eff * (1 + 3*tau/4)^(1/4)`, the grey-atmosphere result |
| `static reference_temperature(body, materials, luminosity, distance) -> float` | **what everything reads.** A content pin first, then the greenhouse, then plain equilibrium. See **Calibration** below |
| `static tropopause_temperature(equilibrium) -> float` | the grey-atmosphere skin temperature, `2^-1/4 * T_eff` = 0.8409 |
| `static temperature_at(height, surface_temperature, lapse, tropopause_temperature) -> float` | the profile: the adiabat down from the tropopause, flat above it |

**Calibration, and what is checked against what.** Three infrared absorptivities are each fixed
against one measured surface temperature — water vapour against Earth's 288 K, CO₂ against Venus's
737 K, methane against Titan's 94 K — and then **Mars and Triton are untouched checks**: Mars derives
212.9 K against ~210 (its residual is its albedo, not its greenhouse) and Triton 41.6 against 38, with
a greenhouse of zero, which is right for a body with almost no air. The absorbers are ordered as
physics says (H₂O ≫ CH₄ > CO₂), and N₂, O₂, Ar, He and H₂ are zero — which is why Earth is warmed by
1% water vapour rather than by the 78% nitrogen under it.

**A season is free.** Insolation is evaluated at the body's *current* orbit position, so Earth swings
4.2 K between perihelion and aphelion and sits 2.2 K above its own mean at J2000. Nothing models a
season — it falls out of asking the orbit for a position.

**Two named limitations.** The adiabat is **dry**, so Earth's tropopause comes out 4 km low (moist
convection is the fix; cloud *bases* are unaffected). And the sky is **single-scattering only**, which
is why Venus renders nearly dark at an optical depth of 16.6 — see the plan doc.

| `SpacesimAtmosphereModel` | `model/atmosphere_model.gd` — the air's scattering: `static rayleigh_coefficient(atmosphere, materials, temperature)` (the per-channel `kRlh` the sky shader takes, summed as each species' cross-section times its number density), `static scale_height(...)` (`kT/(m-bar g)`), `static shell_reach(...)` (**how many scale heights of air to draw** — see **The sky**), `static surface_gravity(body)`, `static reference_temperature(...)` (what content **pinned**, or equilibrium temperature), `static equilibrium_temperature(...)` (§3.6's first row, the placeholder), and `static coverage(...)` |

**Calibrated against measured Bond albedos** (`test_surface.gd`): Luna 0.120 vs 0.110 measured,
Earth **0.302 vs 0.306**, Venus 0.760 vs 0.760, Jupiter 0.520 vs 0.503, Saturn 0.340, Uranus 0.300,
Neptune 0.290. Earth *without* its deck derives 0.081, which is what the deck exists for.

Known data limitation, named rather than fudged: **one `regolith` material cannot be Moon-dark
(0.11), Mercury-darker (0.088) and Mars-bright (0.25) at once**, so the airless bodies carry a wider
tolerance. Io and Europa are not asserted at all — their bright frosts (SO₂ in particular) need their
own species and verified albedos.

Shared with the scene: the colour the renderer draws is `SpacesimSurfaceModel.color`, unless content
pinned `surface_color`. A body with neither surface nor deck gets `UNPINNED_COLOR`, deliberately
unlovely so a placeholder is never mistaken for a result.

## Lighting

`addons/spacesim/lighting/` — the star as a physical light source, and the camera that exposes for it.

A fixed light energy cannot work across a solar system: Mercury to Neptune is **6,000:1**, about 12.6
stops, before surface albedo. So the star's light is set in **lux** and the camera exposes. The same
code lights every distance; nothing is hand-tuned per location.

**Requires `rendering/lights_and_shadows/use_physical_light_units = true`** in `project.godot`. With
it off, Godot ignores `light_intensity_lux` entirely and every number below is correct and invisible.

### `SpacesimStarLight` — `RefCounted`

| Member | |
|---|---|
| `LUMINOUS_EFFICACY` | 94 lm/W for sunlight; a constant, with a Planck-derived value as a later refinement |
| `luminosity`, `light: DirectionalLight3D` | |
| `create(parent, luminosity, temperature) -> DirectionalLight3D` | sets `light_temperature` and the Sun's 0.533° `light_angular_distance`, so a terminator reads as one |
| `static irradiance(luminosity, distance) -> float` | W/m² — the solar constant, 1361, at 1 au |
| `static illuminance(luminosity, distance) -> float` | lux — 128,000 at 1 au |
| `aim_at(observer_position, star_position) -> void` | aims the light and sets its strength for that distance |

### `SpacesimExposure` — `RefCounted`

**Computed from the light, not metered from the frame.** Godot's auto-exposure averages the frame and
drives that average toward middle grey, and it has **no metering mode** — the API is `enabled`,
`scale`, `speed` and an EV clamp, and nothing else. On a frame that is mostly empty space with one lit
body in it, it has exactly one way to reach its target: raise exposure until that body is white. Which
is what it did.

The illuminance at the observer is already derived, so the exposure that puts a lit body at middle
grey is arithmetic: `multiplier = REFERENCE_LUX / illuminance`. Deterministic, impossible to fool with
an empty frame, no pumping, and **testable headlessly** — which image-based metering is not.

| Member | |
|---|---|
| `REFERENCE_LUX` | 100,000 — Godot's own default for `light_intensity_lux`, so a multiplier of 1.0 means "the light Godot considers normal" |
| `MAX_MULTIPLIER` | the clamp: past this, a very dark or very bright body keeps some of its own character instead of every body rendering alike |
| `ADAPTATION_RATE` | how fast exposure follows a change, per second |
| `AMBIENT_ENERGY` | 0.02 — a floor, so a shadowed side reads as dark rather than as a hole. **Not physics**: space has almost no ambient |
| `attributes: CameraAttributesPhysical` | **auto-exposure off**; assign to `Camera3D.attributes` |
| `static target_multiplier(lux) -> float` | 0.78 at one au (128,000 lux), 707 at Neptune (141 lux) — the 9.8 stops between them is derived, not tuned |
| `update(lux, delta)` / `snap_to(lux)` | follow the light, or land on it at once |
| `static configure(environment, ambient_color)` | AgX, `tonemap_white`, the ambient floor, `glow_*` |

**The star is a source, not a reflector**: it cannot be brought into range without making everything
else black, so it is allowed to clip and `glow_*` handles how that reads. Nothing here exposes for it.

### The star's numbers

Luminosity and effective temperature come from `SpacesimStarModel` — see **Derivation — `model/`**
under Solar system above.

## Render layers

`addons/spacesim/render/` — what a body looks like. Everything these shaders are given comes from **the
derivation**, so a shader cannot quietly disagree with the model.

| | |
|---|---|
| `body_surface.gdshader` | the surface layer: a height field from Godot's own 3D noise, colour as a two-stop gradient, relief from the field's gradient projected onto the surface |
| `body_star.gdshader` | the star's own surface: **unshaded and emissive**, coloured from its temperature. Unshaded because a star is a source — drawn with the ordinary surface material it was lit by *its own* light, and its near face, the one facing the observer, came out black |
| `body_atmosphere.gdshader` | the air: **Rayleigh and Mie scattering**, from `glsl-atmosphere` by <https://wwwtyro.net/> (Unlicense). One shell, drawn `cull_front` |
| `SpacesimBodyRenderer` | `body_renderer.gd` — builds the materials and the air shells from derived values; owns the one shared `NoiseTexture3D` and gives each body a stable offset from its id. **Nothing draws a cloud deck:** the shell that did stood at `radius * 1.012`, which put Earth's clouds 76 km up and made them the outermost silhouette of every body — what read as "an atmosphere" from space while the air itself was invisible |

The gradient's two stops are the derived colour **darkened and lightened**, not two hand-picked colours,
so a world keeps its identity while gaining structure. Roughness, specularity and relief strength are
constants in the renderer because the material table does not carry them yet — named there rather than
buried in the shader, so they can be found when the picture is wrong.

**The field is sampled on the unit sphere, mapped into a quarter of the texture.** Sampling world
metres puts every pixel in an arbitrary voxel — a field of dots; and *scaling* the unit direction wraps
the texture, which repeated the (since removed) cloud deck as a visible 8×8 grid. Detail comes from how much noise the
texture holds, not from how often it is wrapped. `VERTEX` inside `fragment()` is **view space**, so the
model-space position is captured in `vertex()` and passed as a varying.

### The sky

A body with an atmosphere gets a second sphere reaching `radius + sky_top`, drawn
with `body_atmosphere.gdshader` — **Rayleigh and Mie scattering**, and the one shader here that is not
ours: it is [`glsl-atmosphere`](https://github.com/wwwtyro/glsl-atmosphere) by
<https://wwwtyro.net/> (Unlicense, public domain), applied to a shell instead of a fullscreen quad.

**One shell, one material, every regime**, because `cull_front` shades only the far surface — the view
ray's exit point — and the march runs from the camera to `min(exit, planet hit)`, with the planet hit
computed *in the shader* (a spatial shader cannot read the depth buffer). The depth buffer then does
the occlusion for free: from outside, the far side is depth-rejected wherever the planet covers it, so
only the ring around the limb is shaded; from inside, the far side **is** the sky dome.

**So a body's air is drawn from outside it as well as from within** — the limb is a real scattering
ring standing off the planet, warm near the terminator. That was the thing the earlier fog shell could
not do at all, and it is the one place the two regimes differ: the haze over the planet's *disk* seen
from outside is not drawn, because the shell's far side is behind the planet there. The limb is what
reads from a distance; if the disk haze is ever wanted it needs a second pass over the near face.

| | |
|---|---|
| `rayleigh_coefficient` | the derivation's `kRlh`, per channel — blue scattering most is the whole reason the sky is blue |
| `rayleigh_scale_height` | `kT/(m-bar g)`. Earth derives **8,371 m** against the model doc's 8.5 km and `glsl-atmosphere`'s own 8.0 km |
| `mie_*` | **named constants, not derivation.** Mie is aerosols, not the species mix — Earth-like values from `glsl-atmosphere`'s example |
| `sun_intensity` | `SKY_INTENSITY * illuminance / REFERENCE_LUX`, so the sky keeps its proportion to the surface the star lights instead of brightening with distance |
| `eye_offset`, `sun_direction` | **refreshed per frame, as offsets.** Bodies sit at ~1.5e11 m and a GLSL float has ~7 digits, so a world coordinate would arrive with ~16 km of resolution against an air 100 km deep |

**How far the shell reaches is derived, not authored.** `SHELL_SCALE_HEIGHTS` scale heights of the
air's own `kT/(m-bar g)`, because one altitude for the whole system is right for exactly one body: a
fixed 100 km is **twelve** scale heights over Earth and **four** over Jupiter, where the air is still
2% of surface density at the top and the shell would end in visible haze. It is then floored by
`frames.atmosphere_altitude`, so a shell can never be shorter than the atmosphere frame the game puts
the player in — 100 km is a *gameplay* convention and stays one.

Printed from the running code, and asserted in `test_render.gd`:

| body | scale height | shell reaches |
|---|---|---|
| Venus | 5.0 km | 100 km (the floor wins) |
| Earth | 7.5 km | 100 km (the floor wins) |
| Mars | 11.4 km | 114 km |
| Triton | 15.8 km | 158 km |
| Titan | 19.4 km | 194 km |
| Neptune | 20.7 km | 207 km |
| Jupiter | 22.7 km | 227 km |
| Uranus | 27.5 km | 275 km |
| Saturn | 50.1 km | 501 km |

**Venus is where the placeholder temperature hurts most**, and it is worth knowing: `T_eq` puts its
surface at 229 K against a measured 737 K, so its derived scale height is 5.0 km against a real ~16.
Earth is 256 K against 288; the giants are pinned. The greenhouse stage is what fixes the rest.

**A gas giant's "surface" is the 1-bar level, and that is a convention rather than a boundary.**
Hydrogen's critical point is 33.15 K at 13.2 bar and every giant's 1-bar level is far above it, so the
H2/He envelope is a **supercritical fluid** from the cloud tops down to metallic hydrogen — there is
no liquid to land on and no sharp interface at any depth. 1 bar is the standard level for a giant's
radius, which is what `radius` already is; the visible clouds condense between roughly 0.5 and 10 bar,
so the floor sits just above what you would actually see. The giants carry an `atmosphere` block like
anything else and are `landable = false`, so they have air and **no frames** — which is why their sky
works without a landable surface.

**Their temperature is pinned through `overrides`**, at the measured 1-bar value, because a giant
radiates more than it receives: Jupiter's equilibrium temperature is ~101 K against a measured 165 K.

**The march starts at the camera, and that is not incidental.** `glsl-atmosphere`'s own example has
the eye *outside* the atmosphere, where both roots of the ray-sphere test lie ahead of it; from
inside, the near root is **behind** the camera and comes back negative. Two bugs lived in that one
fact — a step size thousands of times too large, and a planet clamp that ran the march backwards — and
the shader now says so where the span is computed.

Cost: 16 primary steps with an 8-step sun ray, so **128 samples per pixel** on every pixel the shell
covers, spaced quadratically so they crowd toward the camera where the air is densest. The heaviest
shader in the project — measured at **120 fps / 8.3 ms** at 9.8 km over Earth, which is where the
standing frame-rate question was answered for this case at least.

### Checking a shader

**Headless Godot does not compile shaders.** `load()` returns a valid `Shader` with a syntax error
sitting inside it, and `--import` reports nothing — verified 2026-10-13 by breaking one deliberately
and watching both say it was fine. So `tests/run.sh` cannot check them, and `test_render.gd` checks the
**wiring** rather than the compile.

```
./tests/shader_check.sh        # xvfb-run + a real compile; catches SHADER ERROR
```

That script needs a window (`xvfb-run` counts), which is why it is not part of `run.sh`.

## Navigation

`addons/spacesim/navigation/` — navigation markers: **a ring where each object is, a short line, and
a label**. The beginning of the HUD's navigation overlay.

- **The ring** is the object's own screen position, and **may be off screen**. It is the label that
  stays in view, which is why the ring is not clamped along with it.
- **The line** runs from the ring's edge to the label's box, and exists **only when the ring is on
  screen**: off screen there is no ring to point from, and the label at the edge is the whole marker.
  It leaves a *visible* ring at the ring's edge rather than its middle, so it does not run across the
  circle it belongs to.
- **The label** is a name and a distance, beside its own ring when the ring is on screen, and at the
  edge of the window when it is not. **Another label is the only thing that moves one.**

The set is rebuilt every frame and the labels are **pooled, not allocated**; the pool size is the
screen-space budget in one place.

### `SpacesimMarkers` — `Node3D`

| Member | |
|---|---|
| `Priority` | `CONTEXT`, `MISSION`, `SELECTED` |
| `pool_size: int` | the cap, and the screen-space budget |
| `font_size: int`, `margin: float` | applied from the settings; `margin` is the inset the labels are fitted inside |
| `selected_color: Color` | the selected target's own colour — see `markers.selected_color` |
| `colour_of(priority) -> Color` | that colour for `SELECTED`, `SpacesimOverlay.COLOR` otherwise |
| `context_targets`, `mission_targets: Array[Node3D]` | ambient group, then mission objectives |
| `selected: Node3D` | the selected target, or null |
| `refresh(camera) -> void` | rebuild the set, place its labels, hand the rings to the overlay; call once a frame |
| `orbits: Dictionary` | moon node → the [SpacesimSceneBody] it orbits; handed in once, a fact about the system |
| `static choose(candidates, limit) -> Array[Dictionary]` | the keyed union for one frame |
| `static clamp_to_edge(point, size, margin) -> Vector2` | the edge point in a direction — **and the point itself when it is already inside** |
| `static screen_direction(camera, target) -> Vector2` | viewport direction, valid behind the camera |
| `static format_distance(metres) -> String` | `1.50 Gm`, `2.5 km`, `12 m` |

### `SpacesimOverlay` — `Control`

Draws every ring and line in **one `_draw()` pass** rather than as a node each. Twelve markers
would otherwise be twelve Controls to build, place and hide every frame — and none of them would know
about the others, which is exactly what placing a label clear of the others needs to know.

| Member | |
|---|---|
| `marks: Array[Dictionary]` | one per marker, set each frame: `{"circle", "color"}` plus `"start"`/`"end"` when there is a line to draw |
| `RING_RADIUS`, `RING_WIDTH`, `LINE_WIDTH` | 10 px across, 1 px strokes |
| `COLOR` | the colour everything is drawn in; the selected target's comes from the setting |
| `static place_label(anchor, label_size, taken, bounds) -> Rect2` | **the overlap avoidance** — always a rect, because an overlapping label beats no label |
| `static nearest_free(anchor, label_size, taken, bounds, steps) -> Rect2` | the first free spot within `steps` rings, or an empty rect — what a moon's crowding test is built on |
| `static fitted(box, bounds)`, `free_of(box, taken)` | the two halves of it |
| `static border_point(rect, towards) -> Vector2` | where a rect's border is crossed on the way to a point |

**`place_label` is the whole of the label placement.** Candidates are eight places round the anchor,
each **as near it as the label's own shape allows** — a wide label goes beside the ring, a tall one
above or below — at fourteen growing distances, `STEP_RATIO` 1.22 apart. The first that fits inside
`bounds` and collides with nothing already in `taken` wins.

Neither the per-axis offsets nor the small steps are incidental, and both were wrong first:

- **One radius for every direction** has to be the label's *largest* dimension, so a short wide label
  ends up a hundred pixels off in every direction, including straight up — which reads as labels tied
  to the edges of the screen rather than to their objects. A label needs half its *width* to sit
  beside a ring and half its *height* to sit above it.
- **Coarse steps** (1, 1.9, 3.2, 5 …) make one occupied spot throw a label twice as far as it needed
  to go. Creeping by 1.22 keeps it as near its object as the space allows.

**Nothing is reserved around the HUD**: another label is the only thing that moves one. Reserving the
readout pushed labels hundreds of pixels off objects that were plainly on screen, because the readout
is usually exactly where the markers are. Labels are placed nearest-first, so what matters most picks
its spot first and the rest arrange themselves around it. A last-resort fallback is returned when
nothing is free: an overlapping label still says where something is, and a missing one does not.

### A moon gives up its label, not its ring — but only where the two compete

**A moon's label is dropped only where the body it orbits has taken its space.** The nearest spot
beside the moon's ring *ignoring the planet's own label* is worked out; if the planet's label is what
holds it, the moon yields. Io is a pixel from Jupiter from anywhere short of close approach, so there
its label has nowhere to go that is not where Jupiter's already is — while **by Earth the two rings
are well apart, both labels have room, and both are drawn**.

An earlier version hid a moon whenever its planet was marked at all, which is not the same rule: it
hid Luna while sitting in a clear patch of sky.

It is a fact about the two *labels*, and says nothing about whether the moon is there: the ring is
still drawn, with nothing written beside it. A moon that is the **target** is never dropped, and
neither is one whose planet is not marked — there is nothing to compete with.

The set is ordered **parents before their own moons**, so a planet's label is placed by the time its
moon asks. `SpacesimMarkers._parents_before_their_moons` does that, keeping the order within each
part.

The map it uses is `SpacesimSystemScene.orbit_parents()`, which is **moons only**. A planet's own
`parent_id` is its star, and "hidden by the thing you orbit" is not the same claim there — a star's
disc is a fraction of a pixel from any distance, so the rule would hide planets for being roughly in
the Sun's direction, which is where they spend half of every orbit.

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
| `video.mode` | player | `windowed` — `windowed` / `fullscreen` / `exclusive` |
| `video.aspect` | player | `expand` — `expand` / `keep` |
| `video.screen` | player | 0 — which monitor; a list, so it is offered rather than typed |
| `video.canvas_resolution` | player | `Vector2i(1280, 720)` — the UI's coordinate space |
| `video.render_resolution` | player | `Vector2i(1280, 720)` — what the 3D is drawn at |
| `video.window_size` | player | `Vector2i(1280, 720)` — the windowed window, remembered |
| `mouse.sensitivity` | player | 0.0015 |
| `camera.fov` | player | 70.0 |
| `camera.range_space` / `_orbital` / `_atmosphere` / `_surface` / `_interior` | player | `Vector2(100, 1e11)` and so on — **floors, not ceilings**: `_update_camera` raises the far plane to cover the sky and the system. See **The far plane** |
| `markers.pool_size` | player | 12 |
| `markers.font_size` | player | 17 — the HUD's own size, so markers read as part of the screen |
| `markers.margin` | player | 24.0 — breathing room; labels are fitted inside it, so it is not the clearance a clamped pointer needed |
| `markers.selected_color` | player | `Color(1.0, 0.9, 0.3)` — the one thing on the overlay that stands out, so it can be made to stand out against what it is seen against |
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

**A row that declares `choices` is offered rather than typed into** — an `OptionButton`, whose list
is the row's own array, or `"screens"` for the one list that is the machine's rather than ours. What
a choice *is* depends on the setting: an enum's value is its word, a screen's is its number, since
the position in the list is the screen index. A `Vector2i` row — a resolution — is a pair of integer
fields, so an arrow key offers whole pixels rather than 1279.7. A `Color` row is a `ColorPickerButton`:
a colour is a thing you look at, so typing one as text would be a spelling test.

**A setting type with no editor leaves its row with no control at all**, and `_refresh` then indexes
the first one — so a new type has to arrive with its editor, which is what the settings suite checks.

**A resolution row also carries a `MenuButton` of presets** beside its two fields, filled when the
menu opens rather than when the row is built. Picking one fills the fields, which is a staged edit
like any other: it changes nothing until **Apply**, and **Close** throws it away.

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

### `SpacesimDisplay` — `Node`, registered as the `SpacesimDisplay` autoload, after `SpacesimSettings`

**Three sizes, and they are three different things.** Confusing them is the usual way this goes
wrong:

- **canvas resolution** — the UI's coordinate space. Screens and the HUD are laid out in these units
  and the whole space is scaled to the window, so this sets how large the text reads. The stretch
  mode is `canvas_items`, so a font is re-rasterised for the window rather than magnified, and stays
  crisp at any size. `viewport` stretch would render the HUD *and* the 3D into the canvas resolution
  and blow both up; that was measured, and the HUD text goes soft.
- **render resolution** — what the 3D is drawn at, independent of the window. A space sim is
  GPU-bound long before it is CPU-bound, so this is the performance knob.
- **window size** — how big the window is. **Windowed fullscreen is not a mode**: it is this set to
  the screen's size.

**Nothing is ever stretched.** The aspect is `expand`, never `ignore` — the one that distorts.
`expand` grows the root viewport by one axis to match the window, so the pixel grid stays square and
a differently-shaped window shows *more* rather than a wider-looking ship. The 3D scale is one factor
for both axes, so its buffer has exactly the viewport's aspect, and the camera is a stock `Camera3D`
whose `keep_aspect` grows the horizontal field of view. So the render resolution's **height is exact
and its width follows the window** — the extra width has to come from somewhere, and it comes from
more world rather than from distortion.

| Member | |
|---|---|
| `apply() -> void` | put the window where the settings say it should be; called at startup, which is what makes these *startup* settings |
| `use(settings)` | read from somewhere other than the autoload — for tests |
| `screen_index() -> int` | the screen to open on, clamped: a stored number outlives the monitor it named |
| `mode_of(name)` / `aspect_of(name)` | a setting's word to the engine's enum; anything unknown lands on the safe default |
| `render_scale(render_height, drawn_height) -> float` | pure, and clamped to the range the engine allows |
| `screen_names() -> Array` | the monitors, as `"1: 2560 x 1440  (primary)"` |
| `resolution_presets() -> Array` | what the menu beside a resolution row offers, as `{"label", "size"}` — built on demand, because the window and the monitors move |

**Through the window, not the display server.** `DisplayServer.window_set_size` changes what the
display server says the size is and leaves the root `Window` — and so the viewport that is actually
drawn — where it was. Setting `Window.size` moves both. This was found by probing, not by reading:
the window reported `1280x800` while the root viewport stayed `1152x648`, and the render resolution
was worked out against a window that was no longer there. Only `window_set_current_screen` has no
window equivalent, because the list of screens is the display server's.

A resize re-fits the 3D and **writes nothing**. Every `video.*` value is committed by the settings
screen's **Apply** and discarded by **Close**, with no third route — no "it remembered on its own"
case to reconcile with the staged screen. To make the window's current size the one the game starts
at, pick *This window* from the resolution menu and press Apply.

**Godot cannot enumerate the resolutions a monitor supports.** The display server's whole screen API
is `get_screen_count`, `screen_get_size` (the mode it is *in*), `screen_get_usable_rect`,
`screen_get_position`, `screen_get_scale`, `screen_get_max_scale`, `screen_get_dpi`,
`screen_get_refresh_rate` and `screen_get_orientation` — there is no mode list to ask for. So the
menu offers each monitor's current resolution, this window's, and a curated list of common ones.

## Screens

`addons/spacesim/ui/screen.gd` — the chrome every full-screen modal shares: a dimmed backdrop, a
centred panel with a title, a scrollable content column and a button bar. Two screens with the
same chrome would drift apart, so there is one.

### `SpacesimScreen` — `Control`

| Member | |
|---|---|
| `PANEL_SIZE` | how big the panel is |
| `panel_size: Vector2` | …and a dialog overrides it before `build_screen` |
| `build_screen(title)` | build the chrome; a subclass then fills `content` and `actions` |
| `content: VBoxContainer` | where a subclass puts its rows |
| `actions: HBoxContainer` | where it puts its buttons |
| `title_label: Label` | the heading, so a reused dialog can change what it is asking |
| `add_button(label, on_pressed) -> Button` | add and connect a button in one line |
| `opened()` | called just before the screen is shown; rebuild anything stale here |
| `dismissed()` | called just before it is hidden, **whatever the route** — so tidying up does not depend on which button happened to be pressed |
| `closed` | signal, emitted to ask the scene to hide the screen |

`SpacesimSettingsPanel` and `SpacesimPlayerPanel` are the two subclasses. The settings panel uses
`dismissed()` to throw staged edits away, which is what its amber Close button warns about.

### `SpacesimDialog` — a `SpacesimScreen`

`addons/spacesim/ui/dialog.gd` — a modal *inside* another screen: the same chrome, smaller and
generic, because the save browser needs three shapes of it and they are all "a title, some words,
maybe a field, and a row of answers" — a confirmation that names what it will destroy, a name
prompt, and a save's details.

| Member | |
|---|---|
| `ask(title, message, buttons, inputs = [])` | show a question; `inputs` are field labels to collect |
| `answered(action: String)` | which button was pressed |
| `input_changed` | any field edited, so a caller can say what a typed name will become |
| `value(label) -> String` | what was typed, trimmed |
| `hint: Label` | a line under the fields |

It is a **child of the screen that uses it**, not a screen of its own, so the pause handling and the
screen hotkeys stay where they are: one thing open is what being paused means, and a dialog over a
screen is still one thing.

### `SpacesimPlayerPanel`

The personal-data screen, on Tab, and **the only way a save happens** — there is no save key, because
a save is a deliberate act. Save, New Story, and Close; the attributes, the assets and where each of
them is; and the browser:

| Member | |
|---|---|
| `configure(player, session, system)` | it hosts saving, so it needs all three |
| `session_reloaded` | signal: a load, a switch or a new story moved the player, so whoever is flying the ship has to be told |
| `opened()` | rebuilds everything, so a value that changed while hidden cannot be shown stale |

**Histories** and **Saves** are two scrolling `ItemList`s side by side. Selecting a history shows
its saves and is what the controls under the lists act on; clicking a save shows what it holds.

**Nothing is behind a right-click.** What a row can do is written on the screen: Play, Delete and
the history's name field sit under the Histories list, and a save's Load and Delete are in the
dialog its own row opens — a menu beside a save could only repeat them. Entries that do not apply
are **disabled rather than absent**: the current history cannot be played or deleted, and the trunk
can be neither.

**Reading a save is free** — loading one removes nothing, and the saves after it are named as what a
save from here *would* remove. **It is the save that asks**: nothing is written until it is
answered, and the dialog says the world is not rewound.

## Only names are editable

A name — the player's, an asset's, a history's — is the one thing a person legitimately types.
**Everything else a player has is a gameplay value**: credits move when something is bought,
condition when something is damaged. Typing into those would be a cheat with extra steps, so they
are shown and not offered. There is no longer a *Change my values* dialog, and its removal is the
point rather than a side effect.

**The word on the button says what commits the name**, which is the whole of how the difference is
communicated:

| | Button | Commits |
|---|---|---|
| the player's name | **Apply** | on **Save** — it is player state |
| an asset's name | **Apply** | on **Save** — likewise |
| a history's name | **Rename** | at once — it is a `git branch -m`, a repository operation |

Every one of them is **disabled until its field differs** from what stands, so a control never
offers to do nothing; Enter in the field is the same as pressing it. **An asset is referred to by
its id, which is why renaming one is safe**: nothing points at a name, so a location survives a
rename — the whole reason the id exists. An empty name is refused rather than written, because a
player with no name reads as a bug everywhere their name is shown.

**An edit is not a save**: the screen says `changed — press Save` rather than writing one behind the
player's back.

### Rebuilding from inside a control

`opened()` frees everything in `content`, so a control in there **cannot call it from its own
signal** — the button would be freed mid-emit, which Godot reports as *"freed or unreferenced while
a signal is being emitted"*. `_rebuild()` defers it by a frame, and is what a field, a list
selection or a rename calls instead. Found by the tests, which said exactly that.

## `SpacesimPlayer`

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
| `saves(history) -> Array`, `affected_saves(hash, history) -> Array` | `{"hash", "time", "subject"}`; the history is explicit because the browser shows the saves of the history you have *selected*, which is not necessarily the one being played |
| `preview(hash, path) -> String` | read out of the commit; the working tree is untouched |
| `tip() -> String` | the commit the history stands on, abbreviated like `saves()`'s hashes |
| `rewind_to(hash) -> Dictionary` | move the tip back so the later saves leave the list; **the working tree is left alone**, which is what keeps the world's own state out of a do-over |
| `histories() -> Array`, `current_history()`, `has_history(name)` | |
| `create_history(name)`, `rename_history(from, to)`, `delete_history(name)`, `switch_history(name)` | all `{"ok", "reason"}` |
| `TRUNK`, `STATE_FILE`, `DELETED_FILE`, `STATE_FORMAT_VERSION` | |
| `static state_text(player_data, world_time)`, `static read_state(text)` | |

**The trunk and the history you are playing cannot be deleted** — a new story branches from the
trunk, and git refuses a worktree's own branch anyway. Creating a history or switching first drops
anything uncommitted, because a dirty tree makes git refuse the switch.

### `SpacesimSession` — `RefCounted`

One playthrough: the player, the world clock, and the repository that holds them. The repository
knows git and nothing about what a save contains; the player knows what a player is — **this is the
only place that knows a save is the player, the clock and the world.**

| Member | |
|---|---|
| `static for_world(name) -> SpacesimSession` | under `$XDG_DATA_HOME/spacesim/worlds/` |
| `start(system) -> Dictionary` | brings the repository up, loads the last save, or starts the first story |
| `load_last() -> bool` | the state at HEAD; no git operation, because HEAD already *is* the last save |
| `load(hash) -> Dictionary` | reads the save out of the commit; nothing moves, in the history or the tree |
| `save(system) -> Dictionary`, `save_confirmed(system)`, `label(system) -> String` | |
| `new_story(name, system, player_name)` | branches from the trunk; history and player named separately |
| `saves()`, `affected_saves(hash)`, `preview(hash)`, `delete_save(hash)` | deletions are tombstones |
| `world_time: float`, `message: String`, `player`, `repo` | |

**Reading a save is free; continuing from one is what costs.** `load()` reads the state out of the
commit, so every save stays in the list and nothing is lost by looking. The session remembers which
commit the state in memory came from, and when a save would continue from somewhere other than the
tip, `save()` **writes nothing at all** and returns `{"needs_confirmation", "affected"}` for the
screen to put to the player; `save_confirmed()` is the answer, and it is the one that moves the tip
back (`reset --soft`) — only the player's own paths are ever rewritten, so the world is not rewound.

**A save with nothing changed is refused, and the real-time stamp is deliberately not part of that
comparison** — otherwise the file would differ from the last one by a few seconds every time and
nothing would ever be "nothing changed".

`player/deleted.json` is the single record of deletions, and **its own commit**: writing the player's
state on a delete would make deleting a save *be* a save, appearing in the very list it was just
removed from. The list is built from commits that touched `player/state.json`.

On load the clock advances by how long the player was really away (`now − saved_realtime`), and never
runs backwards — a machine clock that is ahead does not take the world back with it.

### `SpacesimLocation` — `RefCounted`

Where something is: a frame, and a position in it. Turned into words by `SpacesimSystemScene.describe()`,
because saying "landed on Nix" needs the system's names and the player's assets — and `coordinate/`
should depend on neither.

| Member | |
|---|---|
| `frame_id: String`, `position: Vector3` | |
| `is_set() -> bool` | |
| `to_dictionary()`, `static from_dictionary(data)` | unreadable data gives an *unset* location, not an error |

`SpacesimFrame` gains `frame_id` (and `SYSTEM_ID` for the one frame every system has).
`SpacesimFrameTree` gains `register(frame)`, `frame_by_id(id)`, `place_in_frame(subject, frame,
position)` — which *sets* the transform rather than preserving it, because a save says where
something is — and `resolve_frame(id)` — resolving the **longest existing prefix**, so a save naming
a frame the system no longer has is placed at the frame that remains, at its origin, rather than
refused.

### `SpacesimSystemScene` additions

| Member | |
|---|---|
| `frame_phrase(frame_id) -> String` | "landed on Nix", "above Nix", empty for a frame it does not have |
| `nearest_body_name(position) -> String` | |
| `format_time(seconds) -> String` | the world clock as a Terran date and time, e.g. "512-05-02 14:33" |
| `describe(location, assets) -> String` | the location chain as prose, innermost first |
| `place_observer(location) -> bool` | puts the observer back where a save says it was; false when the frame had to fall back |
| `start_time: float` | the clock a story begins at, from the system file's `start.world_time` |

**A surface location restores the distance from the surface and the frame, not the tangential
offset** — and that is not a shortfall. A surface frame's placement is *derived*: the locale moves
under you as you land, so its origin is not saved and the saved position says where you were within
your locale, not where on a globe. On a featureless sphere the locale is anonymous. Terrain is what
makes the tangential part mean something, and then a surface will need a placement of its own.

`SECONDS_PER_DAY` and `DAYS_PER_YEAR` are placeholder calendar constants — a world that needs its own
calendar is a thing to build when a story does.

### `SpacesimPlayer` additions

| Member | |
|---|---|
| `location: SpacesimLocation` | the player and their ships are separate; they coincide when the player is inside one, which is containment |
| assets carry `id`, `name`, `type`, `value`, `location` | the id is generated once and never edited, because a location refers to it |
| `add_asset(name, type, value, at) -> Dictionary` | |
| `asset_by_id(id) -> Dictionary` | |
| `deleted: Array` | the saves this player has deleted, by hash; recorded in `player/deleted.json` |
| `to_dictionary()` / `from_dictionary(data)` | unknown keys are ignored, so a newer save may carry more than this build knows |

## The game

`game/main.*` — fly around the playground system and land on planets. The solar system comes from a
system file; the scene adds input, the camera's render range, the two screens and a readout.
`game/player_ship.gd` builds and places the player's ship, so the headless tests fly the identical
system and ship.

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

**The personal data screen is where the world is saved and browsed**: Save and New Story act on the
world, and **names are the only thing editable there** — a name each for the player, for what they
hold, and for the history being browsed. There is deliberately no save
key: a save is a deliberate act, and **a save that continues from an older one says first which saves
it removes** — reading a timeline costs nothing, and it is saving from it that rewrites the future.

## Tests

`tests/` — headless, synchronous, no test framework dependency. See the README for the command.

Three things the headless suite cannot cover, each with its own tool:

```
./tests/shader_check.sh    compile the shaders for real — headless Godot does not compile them at all
./tests/screenshot.gd      render one frame offscreen and save a PNG
```

**The screenshot rig is how the visual work gets reviewed without asking a person.** Headless Godot
neither compiles shaders nor draws, so "is it visible" is not a question any test can answer:

```
xvfb-run -a godot-double-mono --path . --script res://tests/screenshot.gd
SHOT_BODY=Earth SHOT_ALT=20000000 SHOT_PATH=/tmp/shot.png SHOT_FRAMES=90
```

| Variable | |
|---|---|
| `SHOT_BODY` / `SHOT_ALT` | put the ship above that body on its **day side**, at that altitude, and aim at it |
| `SHOT_PATH` / `SHOT_FRAMES` | where to save, and how many frames to settle for |
| `SHOT_AIM` | `level` along the **horizon**, `up` straight up the body's vertical. Without it the camera is aimed down a radial, so no shot can contain a horizon, a limb or a sky |
| `SHOT_PITCH` | aim at an **elevation in degrees** (0 level, 90 up, -90 down). The general case — `level` and `up` are its two ends. **This is what a sky gradient has to be measured with** |

## See also

- [`../README.md`](../README.md)
