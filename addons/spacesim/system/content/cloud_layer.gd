class_name SpacesimCloudLayer
extends Resource
## **One deck in a body's cloud stack.**
##
## A gas giant's face is three decks — ammonia above, ammonium hydrosulphide below it, water deeper —
## and what you see is the sum of them, not any one. So the reflectance, the coverage and the *colour*
## belong per layer, because a belt is a thin ammonia deck over a browner one rather than a painted
## latitude. See [[SpaceSim/Cloud Layers]] §6.
##
## **The stack is ordered highest first**, the same order as
## `SpacesimAtmosphereModel.condensation_levels()`, so a layer's index is its depth from space.
##
## **Authored, not derived — and deliberately narrow.** What a layer *is* (its height, its temperature,
## the pressure it sits at) is derived from the air and the species. What content states is how much of
## the disc it covers and how much light it sends back, neither of which this model can predict yet.
## Because systems will be generated procedurally, the fields here are the *only* per-layer numbers
## permitted to be invented, and they are all bounded 0..1 except the colour.

## Which condensable this layer is made of — a `SpacesimSpecies.species_name`.
##
## **Empty means "not attributed"**, which is what a body authored before the stack existed gets: one
## unnamed deck. It is also the hook the per-species scattering colour will come through, since water is
## white because water is white rather than because a palette said so.
@export var species: String = ""
## Fraction of the disc this layer covers, 0 to 1.
@export_range(0.0, 1.0) var coverage: float = 0.0
## Bond albedo of this layer alone. The surface underneath does not show through where it covers.
@export var albedo: float = 0.0
## What colour it is, as distinct from how much it reflects.
##
## **`Color(0, 0, 0, 0)` means "not stated", and then the MATERIAL's colour is used** — the species' own
## `SpacesimSpecies.color`, so water is white because water is white. A layer that states a colour
## overrides it, which is what the giants need: their tint is a **chromophore**, complex organics and
## phosphorus compounds mixed into the cloud, and no species carries that yet. Explicit-wins is the rule
## because an authored chromophore is a deliberate statement, while a species colour is a fallback.
@export var color: Color = Color(0, 0, 0, 0)
## How opaque it is where it covers — the shader's knob for thin haze against a solid deck.
@export_range(0.0, 1.0) var opacity: float = 1.0

## **The layer's optical depth at full thickness**, measured along the local vertical.
##
## This is the quantity the shader actually needs: a slab attenuates by `1 - exp(-tau/mu)`, so thickness and
## opacity are the *same fact* and tau is the honest way to say it. With tau the deck **thickens at the
## limb** because the slant path through it grows as `mu -> 0`, and a thin high layer is transparent for the
## physical reason rather than because a supplied alpha said so.
##
## **Zero means "not stated", and the deck falls back to the reflectance-ramp path** — which is what every
## layer does until it is given a tau, so this arrives without disturbing anything already calibrated.
##
## **Authored, and it should say so:** the column of condensate per unit area divided by the particle's
## extinction cross-section is not derivable from a condensation temperature. Order of reference: a thin
## cirrus sheet is ~0.1, a thick convective deck several.
@export var optical_depth: float = 0.0
