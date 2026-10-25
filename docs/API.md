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
| `SpacesimSystemBody` | `content/system_body.gd` — one body: `id`, `display_name`, `kind`, `parent_id`, `primary`, `radius`, `mass`, `internal_heat_flux` (**W/m2 of radiogenic and primordial heat, added to the absorbed flux before the equilibrium temperature's fourth root** — Jupiter's 5.44 against 6.25 of sunlight takes it from 102 K to 120 K; **authored, because nothing in an orbit or an atmosphere yields it**, and zero for the rocky bodies), `rotation_period`, `axial_tilt`, `layers`, `orbit`, `fixed_position`, `atmosphere`, `surface`, `clouds`, `overrides`, `landable`, `significant` |
| `SpacesimLayer` | `content/layer.gd` — `layer_name`, `radius` (outer boundary), `composition` |
| `SpacesimOrbit` | `content/orbit.gd` — the six Keplerian elements, degrees |
| `SpacesimAtmosphere` | `content/atmosphere.gd` — `surface_pressure`, `species`, `variable_species`, and the two **dynamics** inputs `SpacesimCloudModel` cannot derive: `atmospheric_rotation_period` (seconds; **0 = the air turns with the body**, which is what `rotation_period` is then used for — Venus's air superrotates in ~4 days against a 243-day rotation, a factor of **61**) and `wind_speed` (**the velocity scale the band and eddy laws use**, m/s; **0 = not known**, and the model returns `UNKNOWN` rather than a verdict from a guessed wind) |
| `SpacesimSurface` | `content/surface.gd` — `coverage` |
| `SpacesimClouds` | `content/clouds.gd` — `fraction`, `albedo`, `color`, `opacity`. **Authored for now, derived later.** On the body rather than in the atmosphere, because a gas giant's visible surface *is* its cloud deck — the deck is what a body *looks like*, not a property of its air, and the giants **do** carry atmospheres (four of them, 101,325 Pa each). **Nothing draws a deck at present, and the render method is being re-thought.** A deck was drawn twice and removed twice: first for standing `radius * 1.012` above the surface (76 km at Earth), which made it the outermost silhouette of every body, and again (`688005c`) because the **shape** was wrong — a shell carries no thickness, so it gives neither parallax within the deck nor a silver lining, and a 2D field over a sphere stretches without bound at grazing angles. The content stays and is still read: `bond_albedo` needs `fraction` and `albedo`, and `color` is what a body with no surface coverage is drawn in |
| `SpacesimBodyOverrides` | `content/overrides.gd` — pinned derived values |
| `SpacesimFraming` | `content/framing.gd` — the travel bands and thresholds |
| `SpacesimMaterialTable`, `SpacesimSpecies` | `content/material_table.gd`, `content/species.gd` — the substances compositions name. `rayleigh`, `formed_from` (the reactants this species is **made from**, empty for an ordinary gas — see `condensation_levels`), **`condensation_temperature`, which is the 1-ATMOSPHERE VAPOUR-PRESSURE REFERENCE** (the normal boiling point for a liquid, the sublimation point for a solid with no liquid phase at 1 atm — **not** a melting or triple point, which is what the table held for water until 2026-10-16 and which made its dew point 60 K too low), `latent_heat` (**J/mol**, what converts that 1-atm reference into a condensation temperature at the species' own partial pressure; **zero means not known**, and the 1-atm value is then used unchanged), `heat_capacity` (J/(kg·K)) and `greenhouse` (the grey infrared mass-absorption coefficient, or an explicit zero for a gas transparent in the infrared) are populated for every gas the authored atmospheres use **except water vapour's and ammonia's `rayleigh`**; `materials.tres` records where each number came from. **`melting_temperature`** (K) and **`triple_point_pressure`** (Pa) complete a phase: solid below the melting point, liquid between it and the 1-atm reference above, gas beyond — and **no liquid at all below the triple point**, which is why Mars has no liquid CO2 at 636 Pa whatever its temperature. Both are `0.0` where not known, and `SpacesimSurfaceModel.phase_of()` then answers `UNKNOWN` rather than guessing. **The bulk water entries (`ocean`, `ice_cap`, `water_ice`) carried water's *triple point* as their 1-atm reference until 2026-10-19**, which is a different quantity; they now carry 373.15 like `water_vapour`, and `tests/test_surface.gd` asserts all four agree |

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
| `decks: Array[Deck]` | **the cloud stack**, one deck per layer the model places a level for, highest first. Each is a `MeshInstance3D` on the body's own patch mesh, scaled to `radius + base + thickness`, with its own material, map and field seed; `Deck` carries the level, the two altitudes it was built from, the coverage and albedo the ramp gain is fitted to, and the width of the map currently published. Empty for a body with no air, no authored deck, or no condensable that forms a `LEVEL` |
| `point: MeshInstance3D` | the **point of light** this body becomes once it is too small to be a disc: a camera-facing quad sized to the disc it would have had and coloured by its radiance. Hidden while the body is drawn as geometry |
| `sky_top: float` | **how tall this body's air is**, metres — derived from the air's own scale height, floored by `SpacesimFraming.atmosphere_altitude`. **Nothing draws from it**: the shell that used to is gone and the march that will draw the air is not written. The camera's far plane reads it (`sky_reach()`); zero for a body with no air |
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
| `SpacesimWorldTime.clock_at_epoch(iso) -> float` | world-clock seconds for an ISO epoch; J2000 is 63,113,947,200. **Moved out of the scene class** — see `save/world_time.gd` |
| `build(parent) -> SpacesimSystemScene` | places the bodies, then builds; the observer is the caller's business |
| `name` | read from the primary star |
| `bodies: Array[SpacesimSceneBody]` | |
| `content_version() -> int` | the revision a save records |
| `container: Node3D`, `system_frame: SpacesimFrame`, `frame_tree: SpacesimFrameTree` | built |
| `body_by_id(id) -> SpacesimSceneBody` | |
| `scale_bodies() -> Array[SpacesimScaleBody]` | every body, for the travel unit |
| `meshes() -> Array[MeshInstance3D]` | every body's mesh, for the hide debug key |
| `ship_start() -> Vector3` | the system's start position |
| `star() -> SpacesimSceneBody` | |
| `update_sky(camera) -> void` | points the sky at the camera, hands it the depth and the gain, and re-sums the ambient when the depth changes. Called once a frame |
| `update_lod(camera) -> void` | **hands every body the representation its angular size has earned**, once a frame: the screen radius from `camera`'s field, the render target's height and the observer's distance, a level from `SpacesimLod`, and a mesh assignment. **Below `SpacesimLod.POINT_TIER_SCREEN_RADIUS` the body stops being geometry** — mesh hidden, point of light shown, **the star included**, since its disc is a fraction of a pixel from any distance and what it puts on the screen is its own emission over the same area — and `lod.error_budget` is read here, so it is hot. **Nothing about the cull is visible outside this function**: a hidden body is still an entry in `bodies`, and nothing else reads whether it is drawn |
| `body_luminance(body, observer, star_position) -> float` | **what the eye sees of a body**, lux/sr: `illuminance · albedo · lambert_phase(α) / π`. The gathering is here; **the expression itself is `SpacesimLuminance.disc_luminance`**, so the number the point of light is coloured by has one home |
| `_place_point(…)` | sizes and colours a body's point of light. **It carries the body's whole flux into the pixel once the disc is under one**: `min(1, pi * r_px^2)`, the disc's share of the pixel's solid angle — the same term `sky_stars.gdshader` carries as `lux / d_omega`. Without it a receding body keeps its full surface brightness instead of fading as `1/d^2` (a body at 0.077 px is ~170x over the law), and with it a distant planet lands in the same currency as the star field, which is where it is judged. **It applies no exposure at all** — `SpacesimExposurePass` scales the finished frame, which covers the splat and every disc together, and a second application would be one too many. It used to be applied by hand here because an `unshaded` material receives none of Godot's per-path baking, and the flight test that found that is in `Lighting and Exposure` |
| `triangles() -> int` | triangles the bodies and points are currently drawn with — the instrument for "the picture is unchanged and so is the cost", which means the policy is not being consulted |

**The projection is `SpacesimLod`'s** — `pixel_angle()`, `angular_radius()`, `screen_radius_pixels()` and
`POINT_TIER_SCREEN_RADIUS`, each with the reasoning that produced it. **The per-body level law is gone**
(2026-10-25): `SpacesimPatches` decides per patch from the same pixel budget, so a level is no longer one
uniform choice per body. (The shell's own law, `SHELL_BUDGET_SOFTNESS`, `ATMOSPHERE_RING_MIN_PIXELS`,
`shell_screen_radius()` and `shell_ring_pixels()`, went with the shell on 2026-10-19.)
| `orbit_parents() -> Dictionary` | for every **moon**, the body it orbits, keyed by the moon's node — what the navigation overlay's crowding rule uses. Moons only |
| `significant_nodes() -> Array[Node3D]` | the bodies worth marking, in file order. Content decides which those are |
| `aim_sun_at(position) -> void` | aims the star's light at a position |
| `body_for_surface_frame(frame) -> SpacesimSceneBody` | |
| `air_body(frame) -> SpacesimSceneBody` | the body whose air that frame is inside — its atmosphere or surface frame — or null in space |
| `sky_reach(frame) -> float` | **how far the sky can be, in metres** — `sqrt(2) * sqrt(outer^2 - planet^2)`, or 0 in space. See **The far plane** below |
| `place_landing_zone(body, point) -> void` | puts a body's landing zone on the surface under `point` |

**Placement.** Bodies go down in dependency order rather than file order — a moon is placed relative
to its planet — and a body whose parent is not in the system says so instead of quietly landing at
the origin, which is inside the star. A body with no `orbit` does not move.

**Landing zone.** A surface frame's origin is wherever the ship came down, not one fixed site —
otherwise landing anywhere else would leave the ship millions of metres from its own frame's
origin, which defeats the frame. On entering a surface frame the system moves that body's zone
under the observer and then puts the observer back where it was: the frame moves, the ship does
not.

**And the interpolator is reset after that move, which is not belt-and-braces.** The observer is a
child of the frame now, and `reset_physics_interpolation()` writes the pose the *renderer* eases
from — so resetting it before the frame moves (which is what `enter_frame` does, for the reparent)
leaves it holding the frame's old transform, and the renderer draws one frame **gliding** out of the
old position. On the first landing that is the build-time zone, a hemisphere away, and a frame from
there has no ground in it. That frame reads as near-darkness to the exposure metre, which answers
with its 32-stop ceiling: the white flash Evert saw at 1.7 km, `b38b323`. See `Lighting and Exposure`
§4. **Any code that moves a frame's transform must reset the interpolation of what it carries
afterwards.**

**Lighting.** A single directional light cannot light a whole system from its star, so
`aim_sun_at()` re-aims it at wherever the player is. The planet you are at is lit correctly; the
one on the far side of the star is lit from its own side rather than the near one.

**The far plane. The `camera.range_*` settings are floors, not ceilings.** They exist for depth
precision, and a far plane that small clips whatever is further away — which was `1e11` for space,
*less than one au*, so every body past 0.67 au and the star itself went undrawn. `_update_camera`
therefore raises `far` to cover what must be visible: the system in space, and **inside a body's air
both the sky and the system**, because a sky has the star and the other bodies in it.

The sky is much further away than it looks, which is why `sky_reach()` exists. The air is a *thin
skin* — 100 km over a 6,371 km planet — so the distance out to its top is ~100 km straight up and
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
| `SpacesimStarModel` | `model/star_model.gd` — `static luminosity(body)`: what content pinned, or the piecewise mass–luminosity relation. `static effective_temperature(luminosity, radius)`: Stefan-Boltzmann, and **a check on the data rather than a restatement of it** — L and R are measured independently and the Sun's give 5772 K. Deliberately small: what a star *puts out*. Its angular size is geometry rather than output and lives in `SpacesimLod.angular_radius` |
| `SpacesimSurfaceModel` | `model/surface_model.gd` — `static bond_albedo(body, materials)` and `static color(body, materials)`. **`bond_albedo` is NET as of 2026-10-16**: `A = (1 - f) * clear_sky + f * deck`, with `clear_sky = surface_albedo + air_albedo` — the whole planet cloudless, which is the form the published split is in. It replaced a GROSS mix (`f * cloud + (1 - f) * surface`) that gave the surface under a cloud no credit at all; both are valid and they are different numbers, and calibrating the total never distinguished them. That is how the model came to have its **cloud term 1.9x** the published one and its **clear term a fifth** of it, cancelling to the right answer: Earth's all-sky albedo is 0.293 and its clear-sky 0.149 (Stephens et al. 2015, CERES EAFB), so the cloud's share is 0.144. Under the net accounting every term is within 9% — cloud 0.251 against 0.233, clear 0.054 against 0.060, total 0.306. `static air_albedo(body, materials)` is the air's own reflection (0 for an airless body, a value and not a missing one), `static clear_sky_albedo(...)` is surface + air, and `static reflectance_terms(body, materials)` returns the four terms as a Dictionary so the *split* can be compared with the published one rather than only the total. The surface contribution is area-weighted over the coverage fractions. `static lambert_phase(phase_angle)` is the **disc-averaged illuminated fraction** used to weight a body's share of the view: `(sin a + (pi - a)*cos a)/pi`, 1 at full, 1/pi at half, and 0 only at new — so a crescent contributes, where a clamped cosine returns exactly zero for everything past the half moon. **It is Bond-albedo normalised** (its phase integral is 3/2), which is why no geometric albedo is needed anywhere. **The two deliberately disagree about the deck**: the albedo *includes* it, because the temperature depends on it, and the drawn colour does *not*, because the deck was drawn as its own layer on top — counting it in both places gave Earth (0.66, 0.69, 0.73), a colour only 1.15:1 from neutral, which the eye reads as grey. The split outlives the drawn deck, and should: the reflectance is physics and the colour is a picture. **What the surface IS, since 2026-10-19, is the other half of this class.** `enum Phase { UNKNOWN, SOLID, LIQUID, GAS }` and `static phase_of(material, temperature, pressure)` settle a substance's phase from the ambient total pressure and the substance as pure — a sea, not a trace gas, which is the opposite of `condensation_temperature_at`'s partial-pressure use. `enum SurfaceKind { ROCKY, OCEAN, ICE, GAS_GIANT }` and `static surface_kind(body, materials, luminosity, distance)` are the one word a renderer branches on, so a gas giant cannot be handed a sea level (**there is no `MOLTEN`: it needs a solidus the table does not carry, and an unreachable verdict is worse than none**). `static ocean_bearing(...)` is the heaviest volatile in the coverage with its phase — Titan's `methane_ice` comes back **liquid** at its own 92.8 K, which is real physics overruling a label. `static sea_level_percentile(...)` is the liquid fraction, and **the percentile runs from the bottom**: Earth's 0.708 of ocean puts sea level at the 0.708 mark, the same relationship `SpacesimCloudMaps.threshold_for` has with coverage, so a fraction of the area means the fraction. `static bands(...)` is the surface as bands up the slope (`{material, from, to, color, albedo, roughness, specular}`) — liquids first because a liquid fills the basins, then the solids **in the order content authored the coverage dictionary** (Godot keeps insertion order, so the order an author writes is the height order), with each colour's **luminance set to its own albedo and its hue kept** because the authored palette is 2.3-3.4x brighter than the reflectance it claims. `static snow_line(...)` is `(T_surface - T_freeze) / lapse_rate(...)` in metres — derived, and low, because that lapse is the *dry* adiabat. `static polar_ice_line(body)` returns **0**: a polar cap is a latitude and the engine has no horizontal temperature yet |
| `SpacesimCloudBand` | `model/cloud_band.gd` — **the band's laws and the slab's light.** `static two_flux(tau)` returns `(reflectance, transmittance)` — `tau/(1+tau)` and `1/(1+tau)`, so the two faces are exact complements, which is what lets one texture serve both and why a thick base darkens by the amount the top whitens. `static henyey_greenstein(cos, g)` is the normalised lobe that puts a base's bright side where physics does: looking *through* the slab at the star. `static sky_radiance(cos, rayleigh_tau, mie_tau, intensity, g)` is the closed form of the sky's own single-scatter loop over a slab, `p(theta)·beta·H` — a `vec3` because `beta` is, so **the colour is the Rayleigh ratio and there is no blue constant to choose**. **And it is a slab on a ray:** how deep a column is, how far through it the eye looks, and how many samples that chord deserves.** Arithmetic only, and it exists because of how the three previous attempts on the cloud failed: not from a wrong picture but from an **unobservable** one. A deck is `1 - exp(-39)` opaque within its first limb sample, so every later sample contributes `transmittance = 0` and any rewrite of the integration is invisible — three were made, each reported as *"visually nothing changed"*. These are the numbers that end that in one run. `static column_top(value, threshold, full_height)` is the map's value read as a **height, not an alpha**: the base is a plane and only the top follows the field, so a lateral edge is a taper rather than a cut and "no cloud here" is a gap rather than a special case (`h -> 0` makes the chord zero by arithmetic). `static extinction(optical_depth, scale_height)` is `tau / (scale_height * 0.5)` — a column one scale height deep is `2*tau`, stated rather than discovered — with the **`1 / (scale_height * 0.5)` fallback** for a layer that states no tau, which is every layer but the two giants and is what made the deck a lid. `static chord(outer, base, impact)` is the path inside the band: `0` past the top, `2*sqrt(outer^2 - impact^2)` for a grazing ray, and one arc for a ray that reaches the ground — **so the chord halves, not doubles, as the closest approach passes inside the base**, because the march ends at the surface rather than the far side. `impact = 0` returns exactly the slab's thickness, which is the anchor. `static samples(chord, extinction)` is `ceil(chord * extinction * 6)` and the six is the law: **a sample may not advance more than a sixth of an e-fold**, because past that it integrates through a quantity it cannot represent, which is what a lid is — so the count follows from the geometry instead of being chosen. `static stop_steps()` is the ceiling that makes the limb affordable, **derived** from `OPACITY_BOUND`(0.01) and `TAU_PER_STEP` rather than typed in, and lands on **28**. `static marched_transmittance(chord, extinction)` is what a correctly stepped march actually reports: `exp(-min(tau, 28/6))`, so a **thin band is exactly `exp(-tau)`** and a thick one stops just under the bound at **~0.0094** — where the naive exponential gives `1e-29.5` and silences everything after the first sample. Measured on Earth by `tests/test_cloud_band.gd` (39 checks): a 1,436 m base, 1,604 m deep, scale height 8,427 m, **tau 0.381 straight down against 67.9 at the limb**, and the limb chord **286 km, 178x the vertical column** — so no single step budget serves both views. **Scalar, deliberately**: per-channel extinction is what a tinted deck needs, but no layer in Sol states a tau yet, so the change is one signature and not a rewrite |
| `SpacesimCloudModel` | `model/cloud_model.gd` — **how a body's clouds are organised, and nothing about how they are drawn.** Two competing length scales: the **Rhines scale** `L_Rh = sqrt(U/beta)` (where zonal bands form, `beta = 2*Omega*cos(latitude)/a`) and the **Rossby deformation radius** `L_D = N*H/f` (how big one eddy is, evaluated at 45 degrees because `f` vanishes at the equator). `static banding(ratio)` turns `L_Rh/a` into the verdict a renderer reads — `BANDED` / `SHREDDED` / `FEATURELESS` / `UNKNOWN` — and **`FEATURELESS` is what lets a renderer skip generating a field at all**, which is why there is a verdict rather than a naked ratio. `static morphology(body, materials, luminosity, distance)` returns the ratio, both scales, the cell count and the `Rotation` the air actually has; `static rotation_of(body)` prefers content's `atmospheric_rotation_period` and **reports which it used**, because the fallback is out by 61x on Venus. `static cell_count(ratio)` and `static condensation_favouring(latitude, cells)` are where condensation is favoured, from the circulation cells — Earth's three give rising at 0 and 60 degrees and sinking at 30 and 90, which is the ITCZ, the subtropical deserts, the storm track and the polar high. `static layers(atmosphere, materials, gravity, equilibrium, body)` is the deck stack, a **selection** from `SpacesimAtmosphereModel.condensation_levels()` rather than a second derivation. **A parameterisation, not a simulation**: plausible morphology, not a weather model. Two limits are named rather than hidden — `buoyancy_frequency` is the **isothermal** value standing in for a gap (the profile's lapse IS the dry adiabat, so the model's own `N` is zero by construction; Earth comes to 0.018 against a real ~0.01), and `U` is authored per body. The three planets check: Jupiter 0.045 `BANDED`, Earth 0.104 `SHREDDED`, Venus 0.674 `FEATURELESS` — asserted, with the numbers behind them, by `tests/test_clouds.gd` |
| `SpacesimSurfaceMaps` | `model/surface_maps.gd` — **a body's baked surface map, and the numbers measured off it.** **A map is a LADDER now, not one bake.** `prepare()` bakes `BUILD_WIDTH` (256) once per body from `SpacesimSystemScene._build_body` — inside `_ready`, before the first frame — and the device is released immediately afterwards; that small bake is the **measurement** (the quantiles the sea level and the band edges are read from) and it is what draws until a refinement lands. Refinement climbs **one rung per request** (`static next_bake_width(width_in_hand, wanted)`, a pure function: double, capped by what the law wants), asked for only when the law wants more than the map in hand, so an idle frame bakes nothing. **Watching is per frame; deciding is not; publishing is on arrival** (F4, then F5): `observe_eye(id, distance, delta)`
maintains the **closing rate** every frame and **asks for nothing** — Evert, 2026-10-19: *"watching a number increase or
decrease per frame is not the same as baking. We should still only bake when it might become necessary."* A **decision**
is the only thing that can request a bake, and it happens when the gate opens — distance a tenth, pixel angle, ceiling —
**or when a rung lands** (`poll()` zeroes `Entry.last_distance`, because the width in hand is an input to what is needed
next; without that the ladder climbs one rung per gate opening and sits a rung behind through a slow approach).
`static speculative_width(radius, distance, closing_rate, pixel_angle, cap, width_in_hand)` is F5's whole arithmetic:
where the eye will be in `SPECULATION_SECONDS` at its closing rate, one rung above what is in hand, and **0 for a still
eye** — the check that keeps prediction from becoming a cadence. Then publishing is version-compared, so a material is
repointed only when something has actually arrived. The older shape was a gated decision and split publishing: `static map_is_due(last_distance, last_pixel, last_cap, distance, pixel_angle, cap)` answers whether the law's inputs have moved enough to reconsider — a tenth of the distance (`log`, `SpacesimPatches.LOG_TENTH`, the one copy of that number), the pixel angle, or **the ceiling**, so `surface.max_base_fraction` stays hot; `note_map_eye(id, radius, distance, pixel_angle, cap)` is the only place a whole-body bake is requested and it is called only when the gate says so; `drawn_for(id)` is a lookup that asks for nothing; and `needs_publish(id)` / `mark_published(id)` are compared through `Entry.version`, which a landed bake bumps. So **nothing is baked because a frame happened**, and a material is repointed when a rung lands rather than every frame on the chance that one has. `static base_max_width(render_size, fraction)` is the ceiling, and **it is always derived**: `render_width * fraction`, clamped `MIN_WIDTH`(128)..`MAX_WIDTH`(8192). The fraction is the registry's **`surface.max_base_fraction`** (default **0.5**, so the texture is half the scene's resolution), read per frame so it can be moved while flying to watch the cost move with it. **The window is gone** — it was a second texture whose gate compared the cap's desired *pixels* against the whole map's *texel count*, so it could never fire below a 4K render and asked for a coarser raster than the map where it could; the near field is the tiles' rung, not a window's. A refining map was tried and it exhausted the engine's RID pools in four and a half minutes of flight (*"Element limit reached"* at `_allocate_rid`, then *"Failed to create uniform set for batch"* from the 2D renderer): the bake runs on a **local `RenderingDevice`**, whose calls are render-thread-only and which shares the driver with the frame's own device. `map()` is a lookup and `prepare()` is the one call that bakes, so a cache that bakes on lookup is not available to write by accident. Everything else is unchanged: `static quantiles_of(image)` is the 65-entry percentile table measured off the map (fixed `-1..1` binning, reconstructed the same way — the observed-range reconstruction was a real bug that put Earth's sea level at the 95th percentile), `static value_at(table, share)` is the one interpolation every band edge and the sea level goes through, and `linear_quantiles()` is the placeholder a material starts with. `static required_width(radius, distance, pixel_angle, cap)` is `SpacesimCloudMaps.required_width` clamped to `BUILD_WIDTH`..`cap` — so the distance law can ask for *less* than a maximal bake, which is what makes the ladder a ladder. **Bands are area fractions and a shader needs heights, so every coarse bake produces 65 `quantiles`** — the field value at each 1/64th of the area — and everything downstream interpolates that one table: `Entry.value_at(share)` is the sea level for an ocean fraction and a band edge for a coverage, measured rather than assumed. Measured: **0.5 ms at 1,024, ~8 ms at 4,096**, so the bake runs on the main thread (a local `RenderingDevice` is render-thread-only) with no pool and no async publish. `close()` **releases every refined map back to the bake pass and then frees the device**, and is called from `SpacesimSystemScene.close()`, wired to the container's `tree_exiting`. Releasing the refined maps is not tidiness: a rung is a `Texture2DRD` over a RID the pass created and nothing else would ever free, so without it the engine prints *"1 RID of type Texture was leaked"* at exit — which is exactly what it did until 2026-10-19 |
| `SpacesimCloudField` | `model/cloud_field.gd` — **the field itself**: from a seed and a body's morphology, how much cloud is in a given direction. `plan(seed, morphology)` derives everything once — the four scalars, the meander phase, the eddy spectrum and the two generators — and both bake paths read *it* rather than deriving again, which is what stops two paths baking two worlds from one seed. `intensity_at(direction, mix, cells, ratio, feature, noise, stack, phase, fine)` is **the whole field and the only implementation**: the sample is carried by the vortices, the bands are read at the **carried** position, the eddies are read there too, and the fine half is read at the still one — then a soft ceiling instead of a clamp. `bands_at`, `advect`, `vortices`, `eddy_at`, `mixing`, `feature_angle`, `fine_for` and `seed_for` are its parts; `seed_for(body_id, layer)` is deterministic from the body's id, so a world regains its own weather. **`FEATURELESS` skips the noise entirely** — no generator is built and the field is uniform. `static bake(...)` returns one `FORMAT_L8` channel, equirectangular, north at the top row, **pure and safe on a worker thread**. **Measured 7.0 µs a pixel end to end** (2026-10-25, `PROBE_CPU=1 tests/probe_cloud_bake.gd`: 1,024x512 in 3.7 s), so an 8192x4096 map is ~230 s on the CPU against 4.3 ms on the GPU — which is why a refinement that waits on the CPU can simply never arrive, and why the GPU is the default (see `SpacesimCloudMaps`). The earlier `0.80 µs` figure predates the vortices, the meander and the fine half, and `92 ns` is the noise generator alone |
| `SpacesimCloudField` (the laws) | **What each mechanism is driven by, since 2026-10-17 — every one from a quantity the model already derives.** *The band floor* is `mixing(banding)`: a sinking lane is cloud-poor, never cloud-free, and one derived number answers both "how much do the bands matter" and "how much survives in the descending branch". *The band meander* is the stationary Rossby wavenumber `m(lat) = a·cos(lat)/L_Rh = cos(lat)/ratio` — **rounded to an integer, because only whole waves close at the seam**, plus a second golden-ratio harmonic so it is not a purely periodic valance. *The eddies* are `vortices(morphology, seed)`: sizes log-spaced over `[L_D, L_Rh]` (both already in `Morphology`), counts `N(s) ∝ s^-2`, one differential of ~2 rad at the largest size decaying per generation, **the largest generation placed freely and smaller ones on band edges**; `advect()` turns the sample about each centre, and `intensity_at()` reads **the bands at the carried position** (so an arm drags cloud across a lane) while the **fine octaves are sampled unwarped** — a full-turn vortex folds whatever passes through it, and only the coarse half should fold. **The perturbation is scale-invariant by construction**: `cells = 0.25·(π/2)/ratio` makes `span = 4·L_Rh/a` exactly, so a vortex is always a quarter of a band on every body. A body with no `L_D` or `L_Rh` gets **no vortices and no meander** rather than an invented spectrum |
| `SpacesimAtmospherePass` | `render/atmosphere_pass.gd` — **the air, as one volumetric march over the whole frame.** A `CompositorEffect` at `POST_TRANSPARENT` declaring `access_resolved_color`, sitting **before the exposure pass** so the metre measures the finished frame, reading the resolved colour through a storage image and writing it back in place: one dispatch, no copy, no read-back. **A pass and not a shell**, because a shell cannot shade the air over the planet's *disk* — those pixels belong to the planet — so the air over the disc, the limb and the sky from underneath are one mechanism with one ray, with no far side to depth-reject and no mesh to keep centred on the camera. `prepare(camera, body_centre, planet_radius, atmosphere_radius, sun_direction, air, blend, deck := {})` is the whole interface: the numbers come from `SpacesimAtmosphereModel` through the body's `air` dictionary, and **the caller decides whether there is air to draw** (`blend = 0` leaves the frame exactly as it was drawn — no dispatch, no uniform set). **Everything is computed in `double` on the host and handed over in view space**, because a GLSL float holds seven digits and a world coordinate of 1.5e11 m cannot be subtracted inside the shader; the march's own frame is **body-centred**, with the eye as the ray origin. `I = 16` along the ray and `J = 8` toward the sun at each sample — **128 taps a pixel, and the source's own constants are the ones that run** (two GDScript copies that changed nothing were deleted). `status()` plus one printed line on the first dispatch are the instruments, because a pass that quietly does nothing looks exactly like a correct one. **No material may apply air of its own while this is on** — one integral, one place. Measured in flight, 2026-10-19: **339 fps / 2.9 ms** with the air on, from 423 m inside it. **And since 2026-10-20 it also draws the cloud deck as ONE SLAB on the same ray** (`deck` in `prepare`, filled by `SpacesimSystemScene.near_deck()`): the band's span clamped to the air's own `[start, end]` and to the deck's base — a ray that reaches the ground crosses the band once, so its chord is half the grazing one (`SpacesimCloudBand.chord`) — steps from `chord * extinction * 6` capped at **28**, one map tap per sample, and the density from **luminance-as-height** so a sample above its column's top is in clear air. `Params` grew 28 → 48 floats: deck top/base, extinction, threshold, column height, radiance, and a **view→model mat3**, because the map is body-fixed and a march that ignored the body's rotation would draw a different cloud from the one the mesh draws. **The composite is an ORDERED WALK, and that is the point of the whole pass** (2026-10-20): `T` and `L` accumulate front to back over `haze → air → deck segment → air → …`, with the boundaries taken from the deck's own radii (`deck_span`, whose law is `SpacesimCloudBand.spans`). So the air below a deck is in front of it and the air above it is behind it — which is the thing a shell composited *before* the pass can never get right, and the reason the deck is a segment here rather than a surface. `march_air()` and `march_deck()` each take `inout T, L` and return their own transmittance and in-scatter. **The deck is marched through the whole band, inside it included** — the cross-section along the ray, which needs no mesh — because the shell is the body's own patch mesh and only covers what the ground's LOD covers, so a cloud near the horizon falls outside it (that hole presented as *"the deck vanishes between 1.5 km and 3 km"*). **The deck the pass reads is a sphere at the deck's BASE radius** (2026-10-21) — *a condensation level is a level*, so every column starts at the same altitude while the tops vary, and that variation is what the map's luminance-as-height encodes. From altitude the 1.6 km move is 0.025% of the radius; from underneath it is the difference between the cloud's real underside and a sheet at the height of the tallest column. **And the air is ONE segment**: `MARCHES_DECK` is false because nothing in this pass occludes the air, and a split that skips the span it does not fill loses the medium in it — which is exactly what it did, un-integrating the air inside the slab and presenting as a haze that swapped at the crossing and as bands on Venus's horizon. The **fog** is separate, and since 2026-10-21 it is a **share of the frame rather than an optical quantity** — Evert: *"We are approximating based on the refined texture, and scaling based on distance between the top and the bottom of the cloud layer."* So `share = clamp(field * fog_gain, 0, 1) * covered * (1 - altitude/full_column)`, composited at the eye as `L += T * radiance * share; T *= 1 - share`: **full at the deck's BASE and zero at its top**, with the strength taken straight from the texture (`field`, gated by `covered = smoothstep(threshold, 1, field)` so clear air stays clear) rather than from a threshold-remapped share of it. No extinction, no optical depth, no exponential, no integration along the ray, and no gate at either end — the ramp's two ends are geometry. `fog_gain` is the one free number (see the settings table); `radiance` is the deck's drawn brightness, which is the fog's COLOUR and never its strength. Its **density comes from the camera's own column and therefore from the camera's own POSITION** — computed on the host as `deck_node.basis.inverse() * (observer - deck_node.position)` and handed over as `eye_model`, because deriving it in the shader from a float32 mat3 sampled somewhere other than where the camera was (*"random fog in clear skies, and no fog"*) The air's step budget is divided between the spans so a deck in the way does not multiply the cost of the sky. **The light is flat for this rung**; the sun taps, powder and phase lobe are next, so a frame rate measured now is a floor. Three things that are load-bearing rather than tidy: the handover to `body_deck.gdshader` is a **blend across the slab's own thickness computed from the same two radii on both sides** (neither side owns a constant, and `near_weight` is 0 until a map has landed so a bake in flight leaves the shell drawing rather than leaving a hole); **a `Texture2D`'s RID is not a `RenderingDevice` texture RID** — `RenderingServer.texture_get_rd_texture` is the bridge, and feeding `get_rid()` into a combined image sampler fails the set with *"Texture (binding: 2, index 0) is not a valid texture"*, which reads as a pass that drew nothing; and the map carries a **mip pyramid** as of 2026-10-21 (it had none at any of three layers: no `generate_mipmaps` when the texture was made, `format.mipmaps = 1` in the GPU bake, and a `filter_linear` sampler hint that means *no mipmaps*) — so the march samples with **`textureLod` at a level from the step's own footprint**, since a marched sample's screen-space derivatives are meaningless and a compute shader has none at all; the map's width travels in `eye_model.w`. Mips are generated **on a copy**, because `threshold_for`, `mean_exceedance` and `mean_opacity` read `image.get_data()`, which returns the whole chain |
| `SpacesimSurfaceField` | `model/surface_field.gd` — **a body's surface height, as a plan and a shape.** `static plan(body_id, radius)` derives every number once — the seed from the id, a plate lattice's turn from the same seed, the frequencies and octave counts, and **the relief amplitude as 0.14 % of the radius** (Earth's real ±9 km, derived rather than authored so no content carries it). **`land is not cloud`, and the mechanisms are not the cloud field's**: no zonal stretch (a jet draws cloud out east-west; land has no jet), no advection, no eddies, no bands — what shapes rock is tectonic, and it acts at plate boundaries. Instead: a **Voronoi plate partition** (14 Fibonacci points, `1 - dot` as the closeness measure, so the boundary distance falls out with no edge distance function) whose per-plate **level** is what makes the elevation histogram bimodal — continents and basins, Earth's own hypsometric signature; **mountain belts where two plates meet** (`belt = 1 - smoothstep(0, BELT_WIDTH, second - nearest)`, squared so it is a chain and not a band); **ridged noise** (`1 - |n|` squared, one octave per rung through `fnl_fbm3` so the R3 rotation is the same lattice) for the crests; a **region term** (`REGION_FREQUENCY` 0.7, slower than a plate) **multiplied into the plate level** so one continent stands higher than another and one basin floods deeper while a plate interior stays flat — added because nothing in the field was slower than a plate, which made every continent the same relief budget; and a **vec3 domain warp** through three swizzles of one position, which is what makes the plate cells irregular without jittering their centres. **The within-plate texture is scaled by how high the plate stands** (`MOTTLE_PLAIN_GAIN`): a sagging plate keeps a fraction of it, so low ground reads as plains and the uplands keep the grain. The proxy is the plate level and deliberately **not** sea level, because sea level is a percentile of this same field — attenuating by it would be circular. **The plate levels are deliberately biased so a minority stands** — as many up as down puts the sea level's percentile in the gap between the modes and drowns every continent to its peaks. The result is the field's own value, about ±1, **not metres and not sea-levelled**: sea level is a percentile of the distribution, measured after the bake. **There is no CPU twin**: a `double` transcription lived here while the shader was designed and was **retired** (Evert, 2026-10-19), so the GLSL in `surface_field.gdshaderinc` is the only implementation of what a surface is — and a bake therefore needs a rendering device. `static source()` is the one assembler of `#version` + noise + field + kernel, `static push_constants(plan, width, height, uv_origin, uv_size)` is the one writer of the 112-byte block, and **the window it takes is how the same field is rasterised over a sub-rectangle of the equirect space** |
| `SpacesimSurfaceTiles` | `model/surface_tiles.gd` — **the map's raster as a quadtree over uv: the near field, refined where the eye is.** The whole-body map answers *how fine should the planet be?* for one raster; past its ceiling the ground under the eye wants more, so the map is split in four, the walk descends **nearest-first**, and each tile is baked through the same pass the rungs use. **The law is the mesh's law one inversion up**: `screen_pixels(tile) = R * extent / (d * pixel_angle) ≤ TILE_TEXELS`, where `extent` is the tile's largest corner chord and **`d` is the distance to its nearest corner, not the body's centre** (the `SpacesimPatches` lesson). **And a tile must beat the map it would sit on** — `TILE_TEXELS * 2^level > base_width` — because a tile that is not finer is a second texture showing what is already there; without that test the walk emits the whole map as one tile from 21,000 km, which is what the first version did until a probe printed it. `static rect_of(level, x, y)` is a tile's uv rectangle and `static direction_of(u, v)` is the shaders' `equirect()` inverted — **the tile centre is the rectangle's uv midpoint, never the sum of its corners**, because a root tile's corners sum to rounding noise that normalises to `(-1, 0, 0)` and culls the entire tree. `static walk_is_due(...)` is the gate, of `walk_is_due`'s shape: distance a tenth (`log`), eye swing past the finest tile, a changed pixel angle, **or a rung landing under the eye** (a change in need with no movement). `TILE_TEXELS`(512) × `MAX_TILES`(32) is 16 MiB of near field for the whole scene, and the budget is that table: a full table stops the walk and the rest falls back to the whole-body map, so a refusal is softness and never a hole. At a 720p render the selection is 32 tiles from level 3 (2,000 km) down to level 12 (10 km) |
| `SpacesimSurfaceGpu` | `model/surface_gpu.gd` — **the height field baked on the GPU**, one `R16F` map per body. **R16F and not R8** because the height is *differentiated* to make normals and 256 levels over a ±10 km range terrace every gentle slope; **and not two 8-bit channels packed into an `RGBA8`** because filtering and mipping a value split across two channels is invalid — mip 1 and beyond average the halves separately. The shape is `SpacesimCloudGpu`'s (a local `RenderingDevice`, render-thread-only calls, `free()`d or the process segfaults at teardown); the arrangement is **not** — there is no CPU fallback to keep in step, so a headless run has no surface maps. **The push constant must be supplied at exactly the block's size (112 bytes)** — the driver rejects both more and less, unlike a uniform block where padding is the caller's. This is the **build-time** bake: it asks for the whole map and reads it back, because the field's *distribution* has to be measured for the sea level and the band edges. The refinement (one rung at a time) is `SpacesimSurfaceBakePass`'s, on the render thread |
| `SpacesimCloudMaps` | `model/cloud_maps.gd` — **the baked maps, one per (body, layer), and the size each deserves.** `static required_width(radius, distance, pixel_angle)` is the law `tests/probe_cloud_maps.gd` measured: a map stops resolving when its texel `2*pi*r/W` projects past a pixel, so the width worth having is `2*pi*r / (pixel_angle * distance)` — **refinement on approach is therefore automatic and nothing is laddered or tuned.** `quantise()` rounds up to a power of two inside `FLOOR_WIDTH`(256)..`MAX_WIDTH`(8192). `map(body_id, layer, radius, coverage, distance, morphology)` **never stalls and never returns null once there is something to see**: a floor map is baked synchronously on first sight (256x128, 26 ms measured) so a body is never cloudless by accident, and everything above it goes to a `WorkerThreadPool` task that lands when it lands, leaving the previous map in place so the picture improves rather than blinking. `poll()` is the **main-thread** step that turns a finished `Image` into an `ImageTexture` — the texture is the `RenderingServer`'s, so it is created there and not in the task. `static mean_opacity(image, threshold, depth)` is **the mean of `R(tau) = tau/(1+tau)` over the covered texels** — the complement of the transmittance the march integrates, so the top's opacity and the base's transmittance are one law from one texel. It replaced a reflectance ramp that saturated at 1, which made a tau-1.5 deck hide everything from above while transmitting a fifth of the sky underneath it — what a tau layer's ramp is fitted to, because its drawn reflectance is `ALBEDO * ALPHA` with ALPHA exponential, and fitting the ramp to the mean *thickness* would over-brighten it. Measured at the local vertical, so the limb is deliberately brighter than the budget. `map(...)` takes the layer's `depth` and stores both means. `static threshold_for(image, coverage)` is the layer's coverage as a **percentile of the map's own field**, so the achieved coverage is the requested one: **25/50/75% asked gives 25.3/50.2/75.0%**. A `FEATURELESS` or `UNKNOWN` body gets no map, not a smaller one — the same skip as the field's, one layer up. Entries are least-recently-used capped at `MAX_ENTRIES`(24), and **that bound is soft**: a map with a refinement in flight cannot be evicted, so a burst of new bodies can exceed it by the pool's thread count. **`gpu_allowed` is TRUE by default** (2026-10-20, `5adfdcc`): *"that's why we bake on the GPU, not the CPU"* — 47 ms against ~230 s at 8192x4096 is the difference between a refinement that arrives while it is still wanted and one that lands below the altitude it was baked for. **The gate existed for one day and its reason was wrong**: the RID-allocator exhaustion it was blamed on turned out to be `SpacesimAtmospherePass`'s per-frame uniform set, in a pass this cache never touches. The CPU path stays as the headless fallback — `create_local_rendering_device()` is null there — and as the reference a test compares against. The dispatch is **main-thread**, because a local device refuses every call from a worker thread; `gpu_available()` is both the availability test and the answer to which thread may bake |
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

**Two named limitations, both in the sky itself.**

1. The adiabat is **dry**, so Earth's tropopause comes out 4 km low. Moist convection is the fix;
   cloud *bases* are unaffected.
2. The sky is **single-scattering only**, which is why **Venus renders nearly black** at an optical
   depth of 16.6. The real surface is a diffuse **3-3.5 klux** orange dome — about **2.5%** of the
   sunlight gets through 92 bar of CO₂, per the Venera landers. One scattering event cannot make that
   dome; multiple scattering is the fix.
A third limitation used to sit here — the exposure exposed for the light at the *top* of the air rather
than at the observer, worth a factor of forty on Venus — and **`SpacesimExposurePass` closed it** by
metering the finished frame instead of the model: the air is in the buffer before the metre reads it. See
`Notes/Projects/Programming/SpaceSim/Lighting and Exposure.md` §3a for the reasoning and §6a for the
meter.

| `SpacesimAtmosphereModel` | `model/atmosphere_model.gd` — the air's scattering and its **condensation levels**: `static rayleigh_coefficient(atmosphere, materials, temperature)` (the per-channel `kRlh` the sky shader takes, summed as each species' cross-section times its number density), `static absorption_coefficient(...)` and `static single_scatter_albedo(...)` (the visible absorbers — ozone so far — and `w = scatter/extinct`), `static condensation_levels(atmosphere, materials, gravity, equilibrium, body)` (**`body` is optional**, and where it carries `overrides.mean_surface_temperature` that pinned temperature IS the surface — ignoring it was the bug that kept the giants from having a deck at all, since `sol.tres` has carried Jupiter's 165 K since it was authored), `static condensation_temperature_at(material, fraction, total_pressure)` (**Clausius-Clapeyron at the species' PARTIAL pressure**, which is worth 80 K on Jupiter's ammonia: 263 Pa condenses it at 159 K, not the 1-atm 240 K) (**where a cloud deck sits**, derived from where a species reaches its `condensation_temperature`; returns per species a `Condensation` with a `Regime` of `LEVEL`, `DEEP` or `NONE` — **`DEEP` means it genuinely condenses but below the depth the model represents** (`MODELLED_PRESSURE_MULTIPLE`, one stated calibration and nothing per body, so a generated system cannot author an impossible depth), `NONE` means the troposphere never gets cold enough. **A level's `height` may be NEGATIVE**: the model's datum is the reference pressure, not a surface, so a gas giant's water cloud is a real deck at −43 km and 7 bar. `temperature_at` extends the adiabat below the datum for the same reason — the clamp at zero height is what made every sub-datum deck inexpressible) — **and it now says HOW each level formed**: `Condensation.formation` is `CONDENSATION` for a gas in the mix, or `REACTION` for a product that is *not* in the mix and exists only where **all** of its `SpacesimSpecies.formed_from` reactants are present (ammonium hydrosulphide is NH3 and H2S meeting at a level, not a gas anyone puts in an atmosphere). **And since 2026-10-20 it says how DEEP the deck is**: `Condensation.thickness` is the **condensate scale height** `(R/L)·T_base²/Γ` — the height over which the saturation mixing ratio falls by e, from Clausius-Clapeyron along the body's own lapse, capped by the tropopause so a cloud cannot rise past it. Derived, so `SpacesimCloudLayer` carries no thickness; zero for a regime that is not `LEVEL`, and zero for a species with no `latent_heat` (this module's *not stated*). Measured: **Earth 1,604 m, Jupiter 3,969 m, Venus 160 m** — Earth and Jupiter are the order of the real decks (Venus's miss is its photochemical H₂SO₄, and its base sits *on* the tropopause so the cap binds rather than the scale). A species that is both an input and a product gets one level, not two, `static pressure_at(height, surface_pressure, scale_height)` (**hydrostatic on ONE scale height, good for about two and no further** — see the note below), `static scale_height(...)` (`kT/(m-bar g)`), `static shell_reach(...)` (**how many scale heights of air to draw** — see **The sky**), `static surface_gravity(body)`, `static reference_temperature(...)` (what content **pinned**, or equilibrium temperature), `static equilibrium_temperature(...)` (§3.6's first row, the placeholder), `static sky_scale(illuminance)`, `static coverage(...)`, and **the air's own reflection**: `static clear_sky_albedo(atmosphere, materials, gravity)` returns the per-channel fraction of starlight a cloudless sky scatters back — `0.5 * omega * (1 - exp(-tau))` with `tau = k(1/m) * H`, the half being the Rayleigh phase function's up/down symmetry and `omega` separating what is scattered from what is absorbed — and `static clear_sky_scalar(...)` weights the three channels (equal weights by default, which is a *stated* simplification: this is an energy question so luminance would be wrong, and the right weights are Planck at the star's effective temperature). **It takes no temperature and that is a result rather than a simplification**: the optical depth is `[sigma p / kT] * [kT / m-bar g] = sigma p / (m-bar g)`, so the temperature cancels exactly — which is also what stops `bond_albedo` depending on itself through the equilibrium temperature computed *from* it. **Aerosols are excluded on purpose:** `MIE_COEFFICIENT` is an Earth-authored volume coefficient applied to every body by the sky shader, and counting it here gave 1.4 Pa Triton an aerosol optical depth of 0.30, pushing its clear-sky albedo past 1.0 and every temperature on it to NaN. Dropping it took Earth's air from 0.123 to **0.055 against a published 0.059**. |
| | **Three conventions the deck derivation rests on, and every one was got wrong once.** The tropopause is the skin temperature of the **equilibrium** temperature (`tropopause_temperature(equilibrium)`), not of the greenhouse-adjusted surface — passing it the surface put the ceiling 28 K too warm, and `temperature_at`, `surface_temperature` and `condensation_levels` now share the one pairing. And the deck check is a **height** against the literature's altitude ranges, because `pressure_at` cannot span more than a couple of scale heights: Earth's cloud base comes to 0.82 bar against a real ~0.9, Venus's to 3.5 against a real ~0.7–1. And **`condensation_levels`' `equilibrium` argument must be `equilibrium_temperature()`, never `reference_temperature()`** — the latter returns what content *pinned*, and passing a pinned 737 K Venus here raises the tropopause to 620 K and returns `NONE` for every species, deleting the planet's deck (measured 2026-10-20) |

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
| `create(parent, luminosity, temperature, radius) -> DirectionalLight3D` | sets `light_temperature` and keeps the star's radius. The `light_angular_distance` is **not** set here — it follows the observer's distance, so `aim_at` sets it |
| `static angular_radius(...)` | see `SpacesimStarModel` |
| `static irradiance(luminosity, distance) -> float` | W/m² — the solar constant, 1361, at 1 au |
| `static illuminance(luminosity, distance) -> float` | lux — 128,000 at 1 au |
| `aim_at(observer_position, star_position) -> void` | aims the light and sets its strength **and its angular size** for that distance — the disk is a fact about the same distance, so 0.533° at one au is where it lands rather than where it is pinned |

### `SpacesimExposure` — `RefCounted`

**The window and the rate live here; the frame is metered.** `SpacesimExposurePass` reads the rendered
pixels and applies one multiplier to them — the `Lighting` section below has the mechanism. What is left
in this class is what the pass cannot own: the two ends of the window, the adaptation rate, the reference
lux the ambient is expressed in, and the camera attributes that must stay attached at identity.

**It is not Godot's auto-exposure**, which averages the frame with **no metering mode** at all — the API
is `enabled`, `scale`, `speed` and an EV clamp, and nothing else — so a frame of empty space with one lit
body drives it the only way it can: white. The pass is the metered replacement for that, not for this.

| Member | |
|---|---|
| `REFERENCE_LUX` | 100,000 — Godot's own default for `light_intensity_lux`, so a multiplier of 1.0 means "the light Godot considers normal" |
| `MIN_MULTIPLIER` | **1/π** — **fully light-adapted**, the floor the exposure may not stop down past. Past a scene luminance of `LIGHT_ADAPTED_LUMINANCE` (100,000 lux/sr, sunlit snow) the eye has nowhere left to go, and that is what being dazzled *is*; a picture that stops down further is modelling a state that does not exist. A sunlit surface filling the view lands at 2.5 and the day sky with the Sun in it at 0.45, both inside it — **the Sun starts to dazzle inside about 0.83 au**, so Venus and Mercury reach the floor and nothing further out does |
| `MAX_MULTIPLIER` | the top of the same range: **32 stops** above the floor, the wide end of what a human eye spans. Not a state of anything on its own — it is the ceiling the pass's metre clamps its gain to. **The ceiling in force is the setting `exposure.range_stops`**, in stops above the floor: 32.0 is this value and 0.0 allows no boost. Derived from the floor rather than written beside anything, so the floor cannot be dragged around by the ceiling |
| `max_multiplier_for_stops(stops)` | `MIN_MULTIPLIER * 2^stops` — the arithmetic behind `exposure.range_stops`, so the setting and the window cannot disagree. Pinned by test against `MAX_MULTIPLIER` at 32.0 |
| `ADAPTATION_RATE` | how fast exposure follows a change, per second |
| `attributes: CameraAttributesPhysical` | **auto-exposure off**; assign to `Camera3D.attributes` |
| `identity() -> void` | put the camera's multiplier at 1.0, because the pass applies it frame-wide |
| `static set_ambient_illuminance(environment, lux)` | the night side's light, from the star field's own summed illuminance |
| `static configure(environment)` | AgX, **both** white points, the ambient, `glow_*` |

**The white point is set twice, and that is not belt-and-braces.** AgX *ignores* `tonemap_white` —
the engine says so in as many words — so the exposure's derivation was being written against a
white of 6.0 while the curve ran at its own default of **16.29**. `tonemap_white` and
`tonemap_agx_white` are both set, and a test asserts the two are equal, so a mode change cannot move
the curve out from under the exposure silently. **The magnitude is small** and worth stating so nobody
expected more: the white parameter shapes the curve's shoulder only, so on our numbers Sirius moves
about 4% and the faint half of the field does not move at all. It is a consistency fix, not a
brightness one — an earlier version of this paragraph claimed 2.72×, taken from the class reference's
description of `tonemap_white`, and that is not what the shader does.

**A luminance, not an irradiance — and that is why the metre meters.** The light falling where the
observer *is* is an irradiance; adaptation follows the **luminance** of what they are looking at. Conflating
the two produced two reports: looking at Sol from Saturn's distance faded the whole sky 122×, and a planet
filling the frame did not stop the exposure down at all, so flying close to Saturn was blown out. The
physics chain that answered it from the scene — the view integrated as each source's radiance weighted by
its share of it — was superseded on 2026-10-21 by metering the rendered frame, which answers the same
question from the picture and needs no policy about which bodies count. `Lighting and Exposure` §3a has the
argument.

> **The dark-adapted multiplier is gone — removed 2026-10-16, and this is why.**
>
> `DARK_ADAPTED_MULTIPLIER` arrived with the sky itself (2026-10-14), as "an exposure that can reach
> it", and was re-anchored 8,000 → 800,000 the same day while hunting a 126× discrepancy. Its *value*
> was a fudge and the history said so, but its *status* was not: it wore the clothes of physics for a
> session and a half, and **two different claims hid behind each other** — that the shader's numbers
> were right, and that the picture was right. The first was true, the second was not, and the second
> borrowed the first's authority.
>
> It was the compensation for a calibrated sky looking too dim, and it went when the pass made it
> unnecessary: `SpacesimExposurePass` meters the finished frame and applies one multiplier to it, so
> the frame's exposure is decided by **what is on the screen**, not by an anchor computed from the
> light at the observer. Nothing replaced it — that is the point.
>
> What the paragraph recorded that still stands: the naked-eye range really is Sirius at V = −1.44
> down to the 6.5th magnitude, **7.94 magnitudes, 1,502:1**, and the scene is rendered in the
> published values with the EV doing the adapting. That is the shape Evert asked for on 2026-10-16:
> *"I want the scene to be rendered scientifically correct, THEN apply the EV pass to make dim things
> visible, or bright things resolvable."*
>
> What remains in `SpacesimExposure` is the light-adapted floor (`MIN_MULTIPLIER`) and the ceiling
> (`MAX_MULTIPLIER`, moved by `exposure.range_stops`) — both states of the eye, neither a compensation.

**The ambient is the star field's own light, summed from the catalogue** — `AMBIENT_SOURCE_COLOR`, with
its energy set each time `sky.star_depth` changes from `SpacesimStarSky.illuminance()`. It is *not*
`AMBIENT_SOURCE_BG`: Godot builds that ambient from a radiance **cubemap**, and a sky of point sources
cannot be represented in one. The sky is still the light source; it is not asked to travel through a
cubemap to say so. Evert, 2026-10-14: *"The sky should be the ambient light source."*

**The ambient is re-applied, not new**, and the Lambert phase function travelled back with it. The
ambient went in with `97d802d` and was rolled back the same day, then put back on its own in `a09ccff`;
the phase function was restored on its own later (phase 1a of the mesh LOD work) — so of the two changes
that travelled with that rollback, **only the stand-down in the star shader's radiance pass is still not
in the tree.** The stand-down was never needed by this in any case: `AMBIENT_SOURCE_COLOR` does not read
the cubemap, which is `update_ubo`'s own `use_ambient_cubemap` flag.

**The energy is in `REFERENCE_LUX`'s units, and both halves of that convention are now measured.**
`tests/probe_ambient.gd` (2026-10-15) found `ambient_light_energy` maps **1:1** to a white Lambertian's
outgoing radiance — energy 1.0 is white — but that the ambient is **not dark-adapted**: exposure ×1,
×1000 and ×80000 give byte-identical pixels, because the shader reads
`ambient_light_color_energy.rgb` with no exposure factor while the sky's cubemap branch is multiplied by
`IBL_exposure_normalization`. `tests/probe_range.gd` then measured the *light's* constant at
**~95,700 lux per unit** (flat within ±3% over four stops), so `REFERENCE_LUX` is about 4.5% high. Both
are consistent everywhere, so nothing looks wrong — and both were inferred before they were measured.
**A 2e-9 starlight ambient renders as exactly byte 0**: the 3D buffer is `RGBA16F`, whose floor is
0.006 lux. See the plan §6a and §11.

**The star is a source, not a reflector**: it cannot be brought into range without making everything
else black, so it is allowed to clip and `glow_*` handles how that reads. Nothing here exposes for it.

### `SpacesimExposurePass` — `CompositorEffect`

`lighting/exposure_pass.gd`. **The frame-wide exposure**: the metre and the multiply in one compute pass at
`POST_TRANSPARENT`, which the class reference documents as running *"before any built-in post-processing
effects"* — so Godot's glow and tonemap both see what it wrote.

| | |
|---|---|
| **sample** | `SAMPLES_X × SAMPLES_Y` (32×18) invocations, each averaging its own block of the frame. **Every texel is capped at `CAP`** before the block mean is taken, then that mean is weighted by `SpacesimExposureMeter`'s radial profile. Writes `(weighted, weight)` per cell. |
| **finalize** | one invocation: the weighted mean, `TARGET_AVERAGE / mean` clamped to `SpacesimExposure`'s window, then the temporal lerp against the previous frame. **A mean of zero pins at the ceiling** rather than dividing. |
| **apply** | the frame × that one number. Alpha is left alone — it is coverage, not light. |
| `frame_delta` | **set by the game each frame.** There is no delta inside `_render_callback`, and a wall clock there would read the render thread's timing rather than the frame's. |
| `status()` | the instrument: whether it built, and how many frames it has dispatched. |

**The reduction is coarse on purpose** — 576 cells of ~60×60 texels at 1080p is ~37k reads against ~2M for
every texel, and the weight profile is smooth at that resolution. Capping per *texel* rather than per block
is what keeps the cap meaning what it means on the CPU.

**Three preconditions, each measured:** the camera attributes must stay **attached** (`attributes = null`
puts the engine's lux convention out of the pipeline and renders ~95× bright); `Environment.tonemap_exposure`
must stay **1.0**, because the glow applies the exposure itself (`copy.glsl:195`) and an exposure in both
places is applied twice; and `SpacesimExposure.identity()` is what puts the camera side at 1.0.

**Verified in the running game**, not only in a probe: `tests/probe_frame_exposure.gd` toggles the effect's
inherited `enabled` flag inside one run and finds the frame's centre luminance moving ×0.86 — the A/B is
within a run because the screenshot rig's noise floor is ~2.24% and would have to be ruled out across two.
**Whether the metre's value is the right one is a judgement about a picture**, and `tests/run.sh` cannot
make it: the suite is `--headless`, where there is no `RenderingDevice` at all.

### `SpacesimExposureMeter` — `RefCounted` (static)

`lighting/exposure_meter.gd`. **The frame metre**: one exposure number read from the rendered pixels,
which is what `SpacesimExposure`'s adaptation targets once Track B3/B4 land. Pure arithmetic — the caller
supplies luminances and gets a multiplier — so its behaviour is checkable headlessly
(`tests/test_meter.gd`, 23 checks, mutation-checked against a uniform weight).

| | |
|---|---|
| `weight(offset) -> float` | `exp(-(r/SIGMA)^2)`, with `r` in **half-diagonal units** — the centre is 1 and a corner 0.0019. Monotonic in the radius, and steep enough that a bright thing at the perimeter "contributes only a little" |
| `weighted_mean(samples, width, height) -> float` | the **capped**, weighted mean of a row-major grid. The centre is the grid's own centre, so the weighting is the same shape at any reduction |
| `target_multiplier(mean) -> float` | `TARGET_AVERAGE / mean`, clamped to `SpacesimExposure.MIN_MULTIPLIER`…`MAX_MULTIPLIER` — the same 32-stop window, so nothing here can run away. A mean of zero **pins at the ceiling** rather than dividing by it |
| `SIGMA` | **0.4.** The one look value here, and the only number that could be tuned without anything becoming wrong: the weights are normalised, so a uniformly lit frame returns its own brightness whatever this is — only the selectivity moves |
| `CAP` | **1.0**, the reference white. Anything brighter **counts as white**, so a source saturates the metre but cannot own it. This is frame control, *not* protection for the star's brightness — a disc at 24× white survives any realistic dim, because 4.5 stops brings 24 down to 1.0 and it is still clipping |
| `TARGET_AVERAGE` | **0.18**, middle grey. Derived as far as it can be: an 18%-grey surface lit at `REFERENCE_LUX` reads about 0.23 in this currency, so the metre is **neutral on an ordinarily-lit scene** and moves only when the light or the composition is unusual |

**The requirement it implements** (Evert, 2026-10-15): a full-screen, **centre-weighted** metre — *"if I
point my camera at a bright object, the entire frame dims, but if that same object is only a small part of
the perimeter, it should only contribute a little"* — and **no location term at all**. `tests/test_meter.gd`
asserts that as a **comparison between two frames that differ only in where the bright block is**, because
a metre with no weighting passes every other check and fails exactly those two — which is the metre Godot
ships, and the reason metered exposure failed here once. Design, measurements and the four acceptance
tests: vault `SpaceSim/Lighting Plan` §6a and §9.

### The star's numbers

Luminosity and effective temperature come from `SpacesimStarModel` — see **Derivation — `model/`**
under Solar system above.

## Render layers

`addons/spacesim/render/` — what a body looks like. Everything these shaders are given comes from **the
derivation**, so a shader cannot quietly disagree with the model.

| | |
|---|---|
| `body_surface.gdshader` | **the surface layer: a height field, a colour ramp and a sea.** **One map, the refining one**: an earlier version took the mask and the bands from a fixed-width coarse map to stop shores shimmering on approach, and that was wrong — the reasoning holds only when the threshold is a *percentile of the map being read*, and the sea level is an absolute **value**, so any map thresholds it to the same coastline at higher resolution. The mistake cost 39 km texels at every distance, which reads as a featureless ball. The coarse bake now exists only to *measure* the distribution, and its numbers arrive as uniforms. `ALBEDO` is the ramp at the coarse height (a `1 x 256` texture built from the derived bands and the measured quantiles, so the colour knows nothing the derivation did not say); `ROUGHNESS`/`SPECULAR` are mixed by the water mask, because a liquid is glossy and that is most of what makes an ocean read as water; and `NORMAL` is **replaced** from four taps of the height map with `eps` = one texel of *that* map, tilted by `relief_exaggeration` (a real planet's slopes are a fraction of a degree, so the honest normal casts no visible shading — the concession is named, uniform, and the silhouette is untouched). It carries its own render modes and none of the deck's: opaque, `cull_back`, lit, `specular_schlick_ggx` |

| `body_deck.gdshader` | **the far regime's cloud: a baked coverage map on a shell, with its thickness as SHADING.** A deck is the body's own patch mesh scaled to `radius + height + thickness` — one mesh, one walk, one triangle count — so it cannot disagree with the ground about where the surface is. **The thickness is not built, it is sampled**: the layer's base and top are both real derived radii, and the shader picks its case from the eye's own distance in top-radii (`eye_local`, divided on the host) — above the top it samples the tops; **below the base it samples where the same eye ray crosses the BASE sphere**, which is genuine parallax of thickness rather than a fudge; inside it everything is cloud. An underside is lit by `exp(-tau / mu_sun)` — the light that got *through* the slab — and its normal is flipped so the light loop does not take it to black, which is what made the previous deck disappear from below. **The alpha law is where the variation lives**: `ALPHA = covered · veil · thickness` (or `1 − exp(−tau·thickness/mu)` when the layer states an optical depth, so a deck thickens at the limb for the physical reason), and one `ALBEDO = cloud_color · ramp_gain` whose mean is the calibrated albedo — a measured 0.419 over the area against 0.746 at the tops. **The detail ladder below the map** is six single octaves of `noise.gdshaderinc`'s own generator, starting at two texels of the map *in hand* (published on every rung) and each faded by `fwidth` of the model-space direction — band-limited by what a pixel can resolve, never by distance, so a distant deck pays nothing. **It writes depth where there is cloud and `discard`s where there is not**, which is what lets the air pass clip its march at the first thing drawn without losing the air above the gaps |
| `cloud_detail.gdshaderinc` | **the cloud field's detail ladder below the map, in one place** — six octaves of `noise.gdshaderinc`'s own generator, each faded by the pixel footprint, zero-mean, so it perturbs the map without moving its percentile or its calibrated mean. **Two consumers need the same field**: the deck, which draws it, and the shadow, which is the image of the same cloud on the ground — a shadow sampling only the map would be blotchy where the cloud is whispy (Evert, 2026-10-20: *"the detail ladder makes the texture — why can't we use the texture, which is the output of the detail ladder?"*). **The footprint must be in sphere-arc units**: `fwidth` is the angle at the eye and every feature size is an arc at the centre, so a caller close to the shell scales by its distance to the shell in radii — `\|1 − eye_radius\|` for the deck, `deck_height / planet_radius` for a shadow. Without that the ladder is silently dead at close range, which is what the deck did until this existed |
| `deck_shadow.gdshaderinc` | **a cloud deck's shadow on the ground and the sea — as the star's transmittance.** The deck's map is a coverage field and its layer states an optical depth, so together they are a *transmittance map*: the lookup is the deck's own map sampled where the **star's** ray crosses the deck's shell rather than where the eye's does, a horizontal offset of `height · tan(zenith)` along the star's azimuth. `exp(-τ · thickness / mu_sun)` with the same percentile the cloud is drawn with, so a shadow cannot disagree with the cloud that casts it; a sunrise shadow is long because the offset is, not because anything was authored. **Written into `AO` and `AO_LIGHT_AFFECT` and not into a `light()`**: the clustered renderer turns ambient occlusion into a *direct-light* occlusion with `ao = mix(1.0, ao, ao_light_affect)` before the light loop (`scene_forward_clustered.glsl`), which is exactly a cloud's shadow and needs no BRDF of its own. **It cannot dim the ambient and the direct light by different amounts** — one `AO` value drives both — so "a shadow keeps the ambient" is said as a **floor**: `AO = mix(deck_shadow_floor, 1.0, transmittance)`, with `SpacesimBodyRenderer.DECK_SHADOW_FLOOR` = **0.45**, i.e. a shadow removes a little over half the light and reads as shade rather than night. The physical reason a shadow keeps light at all is multiple scattering — a cloud's base is a bright diffuse source overhead — which nothing here models, because the ambient is a *constant* and not a sky probe. When the lighting plan gives the ambient an actual sky, the floor goes and the ambient is simply lit by what is above it; the other upgrade path is a `light()` override, which costs the PBR the surface was tuned with. Included by **both** the land and the sea, and the two cannot drift. **The field it thresholds is the same one the cloud draws**: the map plus `cloud_detail.gdshaderinc`'s ladder, with the deck's own seed and first feature published beside the map, so a shadow sharpens when the cloud does and cannot be a different cloud from the one casting it. `τ` comes from the layer's `optical_depth`, or `−ln(1 − opacity)` where it states none, because that is what "how opaque it is where it covers" already means. `deck_tau = 0` is every body with no deck, and it makes the path a uniform branch |
| `star_transmission.gdshaderinc` | **how much of the star reaches a point on a body's surface — twice over: whether the body is in the way, and what the air took.** *Occlusion*: the fraction of the star's own disk above the point's horizon, written into `AO` with `AO_LIGHT_AFFECT = 1.0` — the same direct-light slot `deck_shadow` uses, and the two multiply. A point on a sphere sees the star iff the sphere's *own* normal does, so no tilted shading normal (the surface's relief is a fiction) can light a fragment the geometry says is in shadow, which is what stopped the lit coastlines in the dark half. A **fraction and not a step**, because the star is a disk: the disk-above-a-line area at `t = −elevation/half_width`, `half_width = max(star_angle, pixel_angle/2)` — the physical penumbra where a pixel can resolve it, the filtered step where it cannot. `star_angle` is `asin(R_star/d)` from `SpacesimLod.angular_radius`, the call `light_angular_distance` already makes and 77x across Sol. *Extinction*: `exp(-τ)` along the **star's own ray**, per channel, scaling `ALBEDO` — the air in the light path on the way *in*, not only along the eye ray. τ is the vertical column above the point (`H·exp(-h/H)`) times a **closed-form spherical air mass**, `1/sqrt(μ² + 2H/(πR))`: 1 overhead, 34 at the horizon against Chapman's 38, within ~20 % between, six operations and no loop. The horizon is the point's **own**, offset by `sqrt(1 − (R/(R+h))²)` — 1.2° at 1.4 km — which is why a cloud stays lit after the ground beneath it has gone dark. The law is `SpacesimAtmosphereModel.sun_transmittance`, tested there; this is its transcription. `air_*` are `body.air`'s own numbers, published once at build, so the ground and the march cannot disagree about how thick the air is. **The view transmittance is NOT here** — the pass owns it — and zero coefficients are an airless body, with no branch. Included by the land, the sea and the decks, and it declares `body_sun`, so it must come **before** `deck_shadow.gdshaderinc` |
| `noise.gdshaderinc` | **FastNoiseLite in GLSL**, one copy for the whole engine: `fnl_os2s3`, `fnl_fbm3` and their tables, transcribed from the version Godot *vendors* rather than the project's newer GLSL port. Two ways in — `SpacesimCloudGpu`/`SpacesimSurfaceGpu` concatenate it in front of a compute kernel (a source string gets no preprocessor), and a fragment shader reaches it with `#include`, which it must: it declares **no `shared` memory**, which is what makes it legal outside compute |
| `surface_field.gdshaderinc` | **the surface height field in GLSL — the only implementation.** `surface_plate_centre/level` (the Fibonacci lattice and its biased levels), `surface_plates` (nearest and second-nearest, and the belt between them), `surface_ridged3`, and `surface_height` composing them. `SpacesimSurfaceGpu` compiles it into a kernel; the surface shader will include it for the detail below the map's Nyquist. **Its `SurfacePlan` fields are read from the host's push constants — no constant is typed in here** |
| `body_star.gdshader` | the star's own surface: **unshaded and emissive**, coloured from its temperature. Unshaded because a star is a source — drawn with the ordinary surface material it was lit by *its own* light, and its near face, the one facing the observer, came out black |
| `SpacesimBodyRenderer` | `body_renderer.gd` — builds a body's materials from derived values: the surface, the star's own emissive shader, and the point of light. **`point_quad()` and `point_material()`** are the point of light: one shared unit quad, wearing an unshaded additive `StandardMaterial3D`. **The quad is NOT billboarded by the material** — `BILLBOARD_ENABLED` rewrites `MODELVIEW_MATRIX` with `INV_VIEW_MATRIX`, i.e. world-space axes against a camera-relative translation, which is the transform chain the double-precision emulation cannot follow (the same family as `world_vertex_coords` and `triplanar`). The orientation is set each frame in `_place_point` by copying the camera's basis onto the node, with the size on that same basis. `point_colour(body, radiance)` is what it is coloured with — **by kind, the same distinction `material_for` makes**: a planet's is its radiance in `UNIT_LUX_PER_SR` tinted by the body's own colour **at unit luminance** (so the tint cannot change the brightness while the hue survives), and a star's is `star_color * STAR_INTENSITY`, its own emission. **The planet's value is sRGB-encoded on the way out**, because Godot's default spatial material declares `uniform vec4 albedo : source_color` and therefore *decodes* `albedo_color` — which for a linear radiance is `level^2.2`, silent and non-linear. The star field has no such conversion (it writes `COLOR` in a sky shader), so without this encode a splat is in a different currency from the sky it is seen against. The star's branch is deliberately **not** encoded, because it goes into the same property the star's own disc does and the two must convert alike for their handoff to look free — noting that both clip at 24x, which is the only reason it does. **Running the reflector formula on a star gives zero** — a star has no albedo — which is how a Sun with a sub-pixel disc would vanish from its own sky — an overbright albedo, so a splat can be brighter than white and still be tone-mapped with everything else. `UNIT_LUX_PER_SR` is **the same number as `sky_stars.gdshader`'s**, and `tests/test_render.gd` checks the shader still carries it. **The deck material**, merged to `main` on 2026-10-21 — `deck_material(body, level, palette, seed_layer)`, `apply_cloud_map(material, texture, width, threshold, ramp_gain, veil, tau_full)`, `face_deck(material, eye_offset)` and `cloud_gain(albedo, palette, mean)`; see `body_deck.gdshader` below. **`tau_full` is the deck's OPACITY, not its lighting** — `alpha = covered * veil * (1 - 1/(1 + tau_full*thickness/mu))`, so an unpublished `tau_full` is `alpha = 0` and a completely invisible deck. It is published here, in the one place a deck's numbers reach a material, because the function that used to set it (`apply_deck_light`) was deleted as light plumbing on 2026-10-21 and took the deck with it: **a deletion that claims "nothing reads this" must grep each uniform for its readers, not each function.** `SpacesimSurfaceMaps`' `deck_ramp_gain` became `SpacesimBodyRenderer.cloud_gain` when the deck was rebuilt, and it returns the achieved fraction beside the gain so a clamped deployment reports its shortfall instead of hiding it. **The surface (2026-10-19, branch `surface-derivation`)** is `material_for(body, ramp, has_ocean)` and `ocean_material(body, bands)`, published by `apply_surface_maps(material, texture, width, base_frequency)` — **`base_frequency` is the field's own, passed in rather than read back off the material**, because the ocean has no ladder and reading an absent parameter returned `null` (a crash per map landing, in flight only), and the near field by `apply_surface_tiles(material, array, rects, layers)` — a `Texture2DArrayRD` plus a table of uv rectangles and layer indices, **padded to `MAX_TILES` and looping over `tile_count`**, because a fixed-size uniform array is written whole and a rectangle without its array is an index into nothing. One map reaches a material — never two, because a second fixed-resolution texture is a second resolution to keep in step with the picture — and the sea level is set by the caller beside it, so a body cannot be given one map's heights and another's sea. **The window that used to be a second layered texture is deleted** (`lod/surface-fixes`): one height map, sampled at whatever width the ladder has reached, because a second resolution in the shader is the thing this file has been bitten by twice. **`ocean_material` returns null when `bands()` has no liquid band**, so Mars, Venus, Mercury, Luna, Io, Europa and Triton build no sea layer at all rather than one with zero coverage, and the land's cull is switched off there by a `has_ocean` flag — on an oceanless body the threshold resolves to the field's minimum and would punch a hole in the lowest ground. **The sea's numbers are its own and all of them are look decisions**: `OCEAN_SHALLOW_METRES`/`OCEAN_DEEP_METRES` are **5 m and 3,000 m**, spanning real bathymetry (shelf break ~130-200 m, abyssal plains 4-6 km) because the ramp is the only large-scale structure a sea has and a 40 m ceiling made every pixel of the ocean one colour; `OCEAN_WAVE_OCTAVES` is **eight**, from a 400 m swell down to 3 m of chop, with `OCEAN_WAVE_RELIEF` **0.0015** — a wave's height is about a twentieth of its wavelength, and 0.02 was a 178 m swell; `OCEAN_WAVE_STRETCH` (**3.0**) draws the wave domain out along the east tangent, because an isotropic sea is the land's own noise and reads as ground. **`OCEAN_TONE_*` is the sea's colour structure** (eddies, fronts, slicks) starting at two texels of the map in hand like the land's ladder — and it is the one place in the project that **deliberately breaks the band-limit**, drawing at every distance: it is a static albedo modulation, so sub-pixel detail in it averages to a noisier colour rather than to crawling light. The waves stay band-limited; they shade. **The detail ladder's depth is a CEILING, not a count** (2026-10-19, F6): `static max_rungs_for(content)` is
**`static first_detail_octave(base_frequency, width)`** is where the ladder starts — `log2(width / (4 pi * base_frequency))`, the field's octave whose feature is two texels of the map in hand, so the octaves below it are in the bake and the ones from it up are evaluated per pixel and there is no third case — and **`DETAIL_TAIL_GAIN` (0.574 = `2^-0.8`)** governs only the octaves the map never carried: the field's own 0.5 per octave is `2^-1`, a self-affine surface whose slope never changes, which left the ground flat up close; real terrain's slope grows, so the tail is flatter than the field's head while the map keeps the spectrum it was calibrated on. `DETAIL_MAX_RUNGS` (18) where `static draws_reference_sphere(content)` — the `surface` register, which is
`Levels of Detail` §4's table and which the content already encodes, a gas giant's datum being a pressure and not a
surface — and **0 where it is not**, so a giant is not handed a ladder for a face it does not draw. The shader
derives the rungs that actually run per pixel (`ceil(log2(feature/footprint))`, clamped to the ceiling), so a
distant body runs one and a ground filling the frame runs as many as it can resolve. Eighteen is a count: a 1 km
descent on the 720p default's 512-wide map asks for 17. `static ramp_image(bands, quantiles, fallback)` is the derivation-to-picture link: each band edge's *percentile* becomes a field value through the measured quantiles, and a body with no bands at all (a gas giant, whose visible surface is its deck) is filled with the colour it was already drawn in. `static deck_ramp_gain(body, ramp_mean)` is that fit, `static uniform_white()` is the one-texel field a `FEATURELESS` body gets (a uniform field cannot carry partial *area*, so its coverage goes into the alpha instead), and the gain **clamps at 1.0** — a cloud cannot reflect more than white, so a low-contrast field falls short of the budget and `tests/test_cloud_deck.gd` reports the shortfall rather than hiding it |
| `SpacesimLod` | `lod.gd` — **how much of the view a body takes up**, as pure arithmetic so it can be decided with no GPU and no meshes. `static angular_radius(radius, distance)` = `asin(R/d)` in radians — **derived rather than stated**, because a value fixed at one au is 2.6x too small at Mercury and 30x too large at Neptune, and **two of its consumers want a diameter**: the drawn disc, the penumbra of a body's shadow and total-versus-annular take the radius, while Godot's `light_angular_distance` takes `rad_to_deg(2 * angular_radius(...))`. `static pixel_angle(fov, render_height)` = `2*tan(fov/2)/H`, **the CENTRE pixel** — a pixel further out subtends more, the frame's average is `fov/H`, and at 1080p/70° the two are 0.0743° and 0.0648°. `static screen_radius_pixels(angular_radius, pixel_angle)` = `tan(theta)/p`, **in pixels** — the projection, not its linearisation. `static triangles_at(level)` = `20 * 4^level`, the closed form `tests/test_icosphere.gd` checks the built meshes against, and `TRIANGLES_PER_SCREEN_RADIUS` = 5.836 is a level's sagitta times its triangle count — **measured from the mesh**, and the relation every pixel error budget descends from. **The per-body level law that used these went on 2026-10-25**: it chose one uniform level per body, and `SpacesimPatches` decides per patch instead, so a body is no longer one level. `POINT_TIER_SCREEN_RADIUS` is where one representation gives way to another rather than a quality budget |
| `SpacesimIcosphere` | `icosphere.gd` — a unit sphere as a subdivided icosahedron, one `ArrayMesh` per level, **built on first use and then the same object every time**, so a level change is a pointer assignment where a `SphereMesh` would re-tessellate. Triangles are exact (`20 * 4^level`) and vertices are `10 * 4^k + 2` (Euler), because midpoints are **cached on the edge** — without that the two triangles meeting at a seam would each get their own copy and the surface would be cracked, which is the one error the mesh carries. Vertices are on the unit sphere and the position **is** the normal. Built at unit radius so every body scales the same mesh. **Wound the way `SphereMesh` is, which is Godot's convention and not the standard one**, so a mesh wound the other way renders a planet inside out; `tests/test_icosphere.gd` measures the winding against `SphereMesh` so it cannot regress quietly. `static relative_sagitta(level)` measures the built mesh's worst departure from the sphere, which is what the law's constant is read from |

Roughness and specularity are constants in the renderer because the material table does not carry them
yet — named there rather than buried in the shader, so they can be found when the picture is wrong.

**The surface mapping is designed and built — on branches `surface-derivation` and `lod/surface-fixes`,
neither on `main`**: `SpacesimSurfaceField` (the height, as one GLSL field), `SpacesimSurfaceGpu` (its
build-time bake), `SpacesimSurfaceBakePass` (the ladder's rungs and the tiles, on the render thread), `SpacesimSurfaceMaps`
(the cache), `body_surface.gdshader` (land) and `body_ocean.gdshader` (sea). See
[[SpaceSim/Surface|Surface]] for the design and [[SpaceSim/Surface Plan|Surface Plan]] for the state.
Two things it must not do again, both of which the deleted attempt did: sample a field in **world
metres** (a planet is millions of metres across and the field is tens of voxels, so adjacent pixels land
~64 km apart in it — a field of dots), and put **the air's arithmetic in a material** (air is one
integral in one place; a per-material approximation beside it applies the same air twice).

### The sky

**The background is the real sky** — the stars visible from Sol, drawn from the HYG v4.4 catalogue. It
replaced a flat `BG_COLOR` look value, which the exposure multiplier scaled like everything else, so
empty space rendered bright blue at outer-system distances (measured 0.655, 0.733, 0.890 at Saturn)
and outshone every atmospheric limb.

| | |
|---|---|
| `sky_stars.gdshader` | a `shader_type sky` material on a `Sky` resource, `background_mode = BG_SKY`. One pixel a star, carrying its whole flux |
| `sky/star_catalogue.gd` | `SpacesimStarCatalogue` — loads `sky/hyg_v44.stars` into three textures |
| `sky/star_sky.gd` | `SpacesimStarSky` — owns the `Sky` and hands the shader its host plumbing |
| `sky/PROVENANCE.md` | where the data came from, its licence, its format, and the calibration |
| `sky/hyg_v44.stars` | 119,613 stars, 1.2 MB, CC BY-SA 4.0 (see below). Bucketed into a **cube-face grid of GRID x GRID cells a face**, and **every cell's stars are in ascending magnitude order** — which is what lets the shader's depth filter `break` instead of `continue`, so the per-pixel loop costs the *visible* stars in the cell rather than all of them. The one piece of arithmetic that must agree across the language boundary is `cell_of` (and now that ordering, which is the second); `tests/test_render.gd` checks the shader's `MAX_PER_CELL` covers the asset's worst cell, so a grid change cannot silently start dropping the densest cell's stars |
| `tools/build_star_catalogue.py` | the reduction, and the check that reproduces the calibration |

**A `Sky` and not a sphere mesh.** No mesh to keep centred on the camera, an infinite background cannot
be clipped by the far plane, and `EYEDIR` is already a **world-space direction** — verified by rolling
the camera, not assumed — so the `CAMERA_POSITION_WORLD − centre` subtraction an air shader would need,
against a GLSL float's seven significant digits, cannot arise. **`return` is not allowed in a Godot
`sky()` function**; the body lives inside a guard instead.

**A star is one pixel**, found by a box test in normalized device coordinates. NDC and not a lattice,
because the pixels tile the screen: a star belongs to the pixel whose centre is nearest, so every star
lands in exactly one, none can fall between two, and none can be drawn twice. The pixel's value is its
illuminance over its **own** solid angle — the gnomonic element, so a star near the frame corner is not
over-brightened — which makes the sum of a star's pixels its light. It also means a higher resolution
or a narrower field makes stars brighter, which is what an aperture does to a point source.

**The pixel's size is measured in the shader, not sent from the host.** Godot draws a sky as a
fullscreen triangle whose vertex positions *are* the NDC corners, so NDC is an affine function of the
fragment coordinate and `dFdx`/`dFdy` give exactly one pixel — at whatever resolution the 3D is
actually drawn at. The host alternative was `Viewport.get_visible_rect()`, which is the **canvas** rect:
correct only while `video.render_resolution`'s height equals the canvas resolution's, and wrong by its
**square** at every other setting, which would have made stars too dim *and* put them in the wrong
pixels. `u_tan_half` still comes over, because the field and the aspect are the camera's to state.

**The shader is an INPUT, not an answer.** It reports radiance in the engine's units and nothing in it
knows what the exposure is. Every star field that came before was display referred — an exposure
already baked in — which is why none of them could respond to a varying EV: a fixed picture multiplied
by a variable exposure is a different picture, not the same one seen differently. The conversion into
engine units is `UNIT_LUX_PER_SR = 100,000/pi` — **a unit conversion, not a gain factor**.

**The catalogue is Sol calibration data, not shipped content** ([[SpaceSim/Cosmos and Discovery|Cosmos
and Discovery]] §2). It is licensed **CC BY-SA 4.0**, which is compatible with this repository's GPL-3.0
because the data and the code are separate works; `PROVENANCE.md` carries the attribution. Its depth is
swept by `sky.star_depth`; the catalogue is a *complete* sky to magnitude 8 and a diminishing fraction
beyond (0.99 at 8, 0.69 at 9), so the setting belongs in 6.5 to 8.0 with 9.5 a soft ceiling.

**The light path.** `SpacesimSystemScene.update_sky(camera)` points the sky at the camera once a frame,
sets its depth and gain from settings, and re-sums the ambient from the catalogue when the depth changes.
The **frame's** exposure is the pass's: it reads the rendered pixels, so what the eye is looking at is
whatever the picture ended up containing — an empty frame included, which the metre answers by opening
up toward the top of its window. That is what lets the stars appear at all.

**What metering made unnecessary.** The chain this replaced integrated the view in GDScript — sources in
the frame's cone, each weighted by its share of the view, a point-to-segment occlusion test per body, and
a solid-angle floor at the eye's 0.2° pooling scale so a star could not own the frame. Every one of those
is a policy about what the *scene* contains, and the rendered frame already contains the answer. The
reasoning and the measurements are in `Lighting and Exposure`; nothing about them is in the code any more.

**Two ways for a bright object to hide the stars, and only one is built.** This one is *global and slow*:
the exposure stops down when something extended fills the view. The other is **veiling glare** — the
local lift a bright source puts under everything near it, which is what hides faint stars beside the
Sun without touching the rest of the sky. That is a separate mechanism and is **not built**; the vault
already records the distinction (*filtering, not collecting*).

**No body draws its air today.** The shell that did — one icosphere reaching `radius + sky_top`,
`cull_front`, marching Rayleigh and Mie scattering to `min(the ray's exit, the planet hit)` — is deleted, along
with its shader, its material and its level law. What survives is the **arithmetic**, because it is a fact
about a body rather than about a renderer: `SpacesimAtmosphereModel` still derives the scale height, the
coefficients, the temperatures and the air's own height, and `sky_top` is still on the scene body because the
camera's far plane reads it.

**The air is to be built again as a volumetric march** — one compute pass over the frame, `POST_TRANSPARENT`
and before the exposure pass, with the rejection-first ray test and the view-space parameter block. The
mechanism is written down in the vault (`Atmospheres` §9a) precisely so it can be rebuilt without this code:
it is a specification, not a memory of a shader. **A shell is not coming back**, because a shell cannot shade
the air over the planet's disk, and that is the requirement the change was made for.

**A material never applies air of its own.** The surface shader used to attenuate itself through the air above
it, which was right while the shell was the only air; beside a march it applies the same air twice. One
integral, one place.

**How tall the air is, per body** — derived, `SHELL_SCALE_HEIGHTS` scale heights of the air's own
`kT/(m-bar g)`, floored by `SpacesimFraming.atmosphere_altitude` so the air can never be shorter than the
atmosphere frame the game puts the player in. Printed from the running code and asserted in
`test_render.gd`:

| body | scale height | air height |
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

**Venus is where the placeholder temperature hurts most**, and it is worth knowing: `T_eq` puts its surface
at 229 K against a measured 737 K, so its derived scale height is 5.0 km against a real ~16. Earth is 256 K
against 288; the giants are pinned. The greenhouse stage is what fixes the rest.

**A gas giant's "surface" is the 1-bar level, and that is a convention rather than a boundary.** Hydrogen's
critical point is 33.15 K at 13.2 bar and every giant's 1-bar level is far above it, so the H2/He envelope is
a **supercritical fluid** from the cloud tops down to metallic hydrogen — there is no liquid to land on and no
sharp interface at any depth. 1 bar is the standard level for a giant's radius, which is what `radius`
already is. The giants carry an `atmosphere` block like anything else and are `landable = false`, so they have
air and **no frames**.

**Their temperature is pinned through `overrides`**, at the measured 1-bar value, because a giant radiates
more than it receives: Jupiter's equilibrium temperature is ~101 K against a measured 165 K.

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

**Every setting is the player's.** The file is theirs, it is machine read and written, and it never
travels with the world.

Content that *should* travel — the frame bands, the shell altitudes, the pad size — is authored on the
**content resource** (`systems/*.tres`) instead. `SpacesimFraming` carries those numbers and
`SpacesimSystemScene.build()` reads it, so it is the one source for them.

> **Changed 2026-10-15.** There used to be a second scope. Six `frames.*` keys were declared
> `Scope.WORLD` — meant to be read from the world's own file, travelling with the world as content, and
> never written to the player's — and **nothing read them.** The bands and thresholds come from
> `SpacesimFraming` on the resource, and `frames.system_band`'s default had already drifted from it
> (`1e11` against `1e13`). The keys are gone, and the world-scope machinery went with them: with those
> keys removed the scope had **no members**, so it could not do anything, and a capability that cannot
> be exercised is not a capability. **Two copies of one number was the bug this closed** — the original
> finding is `Source Review/framing.gd.md` in the project notes.

The registry's `scope` field remains, with one value. That is deliberate: it says *whose* a setting is,
so a second scope would be a declaration rather than a refactor.

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
| `camera.ship_distance` | player | 32.0 — how far behind the player's ship its own camera sits, in metres. **It decides whether the hull is drawn at all**: the placeholder hull is only ~23 m in front of the camera and deep space's near plane is 100 m, so it is clipped away there. `_update_camera` brings the near plane inside the hull while the ship is shown, which is a depth-precision cost paid only then. See the ship key in § Bindings |
| `ship.visible` | player | **true** — whether the player's own hull is drawn. **A setting rather than session state since 2026-10-16**, so the key remembers: it used to be a `var` that defaulted to true on every run and made you press the key again each time. The default is unchanged, and true is the deliberate one — the placeholder hull is lit like a plain box and its own pixels move the exposure metre. The first boolean row in the registry, and the settings screen grew a checkbox for it, because every declared setting has to have a control |
| `camera.range_space` / `_orbital` / `_atmosphere` / `_surface` / `_interior` | player | `Vector2(100, 1e11)` and so on — **floors, not ceilings**: `_update_camera` raises the far plane to cover the sky and the system. See **The far plane** |
| `render.atmosphere_volume` | player | **true** — the air as one volumetric march over the frame (`SpacesimAtmospherePass`), and its blend at once: zero leaves the frame exactly as it was drawn |
| `render.cloud_decks` | player | **true** — the far regime's cloud. **One switch for one mechanism, reading no other switch**: `show_decks = render.cloud_decks and not volume` made "turn the decks on" a lie for a whole day. Off hides every deck and bakes nothing |
| `surface.max_base_fraction` | player | 0.5 — the whole-body surface map's ceiling as a fraction of the render resolution, so the texture is half the scene's own width |
| `lod.error_budget` | player | 4.0 — the geometric error a body's mesh may show at its **silhouette**, in pixels on screen. One number decides the whole engine's mesh budget: tessellation follows from it and a body's screen size, and body to body it is the difference between 20 triangles and 20,000. Read by `SpacesimSystemScene.update_lod`, and in flight by the `[` / `]` keys. Small is finer. It is a **trim** meant to be tuned by eye and then frozen into `SpacesimLod`, the same shape as the star field's gain |
| `markers.pool_size` | player | 12 |
| `markers.font_size` | player | 17 — the HUD's own size, so markers read as part of the screen |
| `markers.margin` | player | 24.0 — breathing room; labels are fitted inside it, so it is not the clearance a clamped pointer needed |
| `markers.selected_color` | player | `Color(1.0, 0.9, 0.3)` — the one thing on the overlay that stands out, so it can be made to stand out against what it is seen against |
| `exposure.range_stops` | player | 32.0 — **the ceiling on the metre's gain**, in stops above the light-adapted floor (`SpacesimExposure.MIN_MULTIPLIER`). The metre drives the frame toward middle grey, and a frame of nothing but stars has almost no mean luminance to answer with, so it asks for the top of the window; this is what caps how far it may go. 32.0 reproduces the derived `MAX_MULTIPLIER` exactly and 0.0 allows no boost. Read by `main.gd` and handed to `SpacesimExposurePass` |
| `fog.gain` | player | **2.0** — **how opaque the cloud map's relative reading means**, and the only free number in the deck's fog. The amount is the map's value at the camera, and that value is *relative*: 0 at the coverage threshold, 1 only at the brightest texel the map can hold, so a patch anyone would call thick reads 0.5–0.7 and would fog at 50–70%. `share = clamp(density · gain, 0, 1) · (1 − altitude/full_column)`, so the ramp's two ends are geometry (full at the deck's base, zero at its top) and this scales what the texture says into the opacity it means. Hot, read every frame by `main.gd` into `SpacesimAtmospherePass.fog_gain` |
| `exposure.adaptation_rate` | player | **2.0** — **halvings per second** of the exposure's approach. The adaptation is exponential in STOPS, not linear in the multiplier, because a multiplier gap is a ratio: the remaining gap is multiplied by `1 − exp(−rate·delta)` each frame, so it halves every `ln2/rate` seconds whatever its size. Quick when the difference is large, fine-tuning when it is small, frame-rate independent by construction |

There were six `frames.*` keys here until 2026-10-15. They were **read by nothing** and duplicated
`SpacesimFraming` on the content resource, which is the live source for every one of those numbers —
see § Scope. **This is the current, complete list.**

### Bindings

Input bindings live in the same file, under `[bindings]`, declared in the registry like any other
setting — a string with the `key_binding` validator:

```
[bindings]
settings_screen=Alt+C
throttle_up=Shift+Equal
throttle_stop=Backspace
roll_left=BracketLeft
ship_toggle=O
```

The **ship toggle** (`bindings.ship_toggle`, `O`) draws or hides the player's own hull. It is session
state and not a setting, so a fresh run always shows the ship. It exists because the placeholder hull is
lit like the plain box it is, and its own pixels move the exposure metre — so the first thing to do when
judging the scene's lighting is to take it out of the frame.

The **wireframe toggle** (`bindings.wireframe_toggle`, `L`) draws the body meshes as wireframes and takes
the air and the deck out of the frame. It asks a different question from the picture: what the level
policy actually did. A shaded sphere looks the same at every level, so whether the tessellation is where
the eye is cannot be answered from a render — see `main.gd`'s `set_wireframe()`, and `SHOT_WIREFRAME=1`
for the same view from the screenshot rig.

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
| `config_home()`, `data_home()` | XDG base directories, with fallbacks applied |
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
| `set_value(key, value, save_now := false) -> bool` | the only way to write a setting; false if refused |
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
Player-owned per the world/player boundary; **a save holds it**, in `player/state.json`.

### `SpacesimPlayer` — `RefCounted`

| Member | |
|---|---|
| `DEFAULT_NAME`, `DEFAULT_ATTRIBUTES`, `DEFAULT_ASSETS` | the placeholder starting state, handed out as **copies** on `reset()` |
| `attributes: Dictionary` | named values, starting with `Name`. Currency lives here too, being a quantity rather than a thing |
| `assets: Array` | things held, each `{id, name, type, value, location}` — `id` is generated once and never edited, because a location refers to it and a name can change |
| `location: SpacesimLocation` | where the player is; the player and their ships are separate, and coincide when the player is inside one |
| `deleted: Array` | save tombstones, by hash — recorded in `player/deleted.json`, not in the state file |
| `display_name()`, `reset(name)`, `add_asset(...)`, `asset_by_id(id)` | |
| `to_dictionary()` / `from_dictionary(data)` | unknown keys ignored, so a newer save may carry more than this build knows |

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
| `static state_text(player_data, world_time, saved_realtime)`, `static read_state(text)` | |

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
| `SpacesimWorldTime.format(seconds) -> String` | the world clock as a Terran date and time, e.g. "512-05-02 14:33". **In `save/world_time.gd`, not on the scene class** — a built scene knows about its bodies, and nothing about calendars |
| `describe(location, assets) -> String` | the location chain as prose, innermost first |
| `place_observer(location) -> bool` | puts the observer back where a save says it was; false when the frame had to fall back |
| `start_time: float` | the clock a story begins at, from the system file's `start.world_time` |

**A surface location restores the distance from the surface and the frame, not the tangential
offset** — and that is not a shortfall. A surface frame's placement is *derived*: the locale moves
under you as you land, so its origin is not saved and the saved position says where you were within
your locale, not where on a globe. On a featureless sphere the locale is anonymous. Terrain is what
makes the tangential part mean something, and then a surface will need a placement of its own.

The world clock is a Terran date and time (`SpacesimWorldTime.format()`), carried by **Godot's own proleptic
Gregorian date arithmetic** rather than a table of months and leap-year rules of ours: seconds are
counted from the world's epoch, which reads as year 0, so a story can open in any year it likes. A
world that wants a calendar of its own is a thing to build when a story needs one.

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

`game/main.*` — fly around **Sol** and land on planets. The solar system comes from a
system file; the scene adds input, the camera's render range, the two screens and a readout.
`game/player_ship.gd` builds and places the player's ship, so the headless tests fly the identical
system and ship.

| Key | |
|---|---|
| `+` / `-` | throttle, signed: astern flies as fast as ahead. Ten seconds from zero to full |
| Backspace | throttle to zero at once |
| mouse | pitch and yaw (click to recapture after Esc) |
| `[` `]` | roll |
| `1` `2` `3` `4` `5` `6` | view forward, back, left, right, up, down — camera-local, in the ship's frame, so mouse look still steers and the view stays where it is put |
| T | cycle the selected target |
| P | hide/show the bodies |
| Tab | pause and open the personal data screen |
| Alt+C | pause and open the settings screen |

**The mesh error budget no longer has keys.** `lod.error_budget` is a *setting* and stays in the registry — it sets every body's tessellation — but the step-through was removed on 2026-10-20: the value is flown once and left at its best, so the brackets are better spent rolling. The HUD still reports the triangle count, which is the reading the trim was for.

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
