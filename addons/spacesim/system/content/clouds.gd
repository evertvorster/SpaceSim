class_name SpacesimClouds
extends Resource
## A body's cloud deck: how much of it there is, and what it is made of.
##
## **Authored for now, derived later.** The honest derivation is water vapour present *and* the
## temperature below that species' `condensation_temperature` — which the material table already
## carries — but that needs the atmosphere and temperature stages, and the shader layers want
## something to draw in the meantime. So the fraction is authored, and the derivation replaces it
## without changing this shape.
##
## Clouds belong on the **body** rather than inside [SpacesimAtmosphere] on purpose: **a gas giant's
## visible surface *is* its cloud deck**, so the deck is part of what a body *looks like* rather than a
## property of the air above it. Where a deck is *derived* — from the condensation level, as the cloud
## plan does it — the derivation reads the atmosphere, and the resource still belongs here.
##
## **Corrected 2026-10-16.** This used to say *"the giants here carry no atmosphere block"*, which is
## false: `systems/sol.tres` gives all four giants a 101,325 Pa atmosphere. It was the stated reason for
## the placement, it contradicted `docs/API.md`'s own gas-giant note in the same file, and by the time it
## was caught it had spread to five files in this repository and two in the vault. The placement stands;
## the sentence that justified it did not.
##
## Why this exists at all: **clouds dominate a planet's reflection**, and without them the albedo
## derivation is wrong by a factor of two to six on any body with air — Earth derives 0.081 against a
## measured 0.306. See [[SpaceSim/Solar Systems and the Physics Model]].

## Fraction of the disc the deck covers, 0 to 1.
@export_range(0.0, 1.0) var fraction: float = 0.0
## Bond albedo of the deck itself. Water cloud is a little under 0.5 as a planetary average once
## absorption and geometry are counted; thick Venusian sulfuric-acid cloud is nearer 0.76. The
## surface underneath does not show through, so this is what the body reflects.
@export var albedo: float = 0.0
## How the deck looks. Separate from [member albedo] the same way a material's colour is separate
## from its reflectance: one is what it reflects, the other is what colour it is.
@export var color: Color = Color.WHITE
## How opaque the deck is where it covers — the shader's knob for thin haze versus a solid deck.
@export_range(0.0, 1.0) var opacity: float = 1.0
