# `hyg_v44.stars` — provenance, format and calibration

**This is Sol calibration data, not shipped content.** SpaceSim ships no Sol
([[SpaceSim/Cosmos and Discovery|Cosmos and Discovery]] §2): it exists so the models can be
falsified against measured values before a generator exists. The same applies to this file — it is
the real sky, brought in to calibrate against, and the generator for other systems is written to
match *it*, not the other way round.

Evert, 2026-10-14: *"We are calibrating here, so if we have access to proper data, we can bring that
in as a dependency, and later we'll model on how to generate something similar."*

## Source

| | |
|---|---|
| **Catalogue** | HYG v4.4 — Hipparcos + Yale Bright Star + Gliese, merged |
| **Home** | <https://codeberg.org/astronexus/hyg> |
| **File** | `data/hyg/CURRENT/hyg_v44.csv.gz` |
| **Fetched from** | <https://codeberg.org/astronexus/hyg/media/branch/main/data/hyg/CURRENT/hyg_v44.csv.gz> |
| **sha256** | `00b349893b9a53106dd488d8371e8d2fa586043e500bb3cdb8bff3931682197d` |
| **Size** | 13,636,362 bytes |
| **Version** | HYG v4.4 (the current version at the time of writing) |

**Licence: CC BY-SA 4.0** — attribution and share-alike. This file is a derived work of that data and
**stays under CC BY-SA 4.0**, which is compatible with this repository's GPL-3.0 because the data and
the code are separate works. Attribution: *HYG Database v4.4 by David Nash, built from the Hipparcos
Catalogue (ESA), the Yale Bright Star Catalogue and the Gliese Catalogue of Nearby Stars, licensed
CC BY-SA 4.0.*

**The source is stored in Git LFS.** Its plain `raw` URL returns a 133-byte pointer, not the data —
that mistake produced a "catalogue" of eleven bytes on the first attempt. Fetch it from the `media`
endpoint above, and check the sha256: the tool does, and refuses to continue if it differs.

## How to rebuild

```sh
python3 tools/build_star_catalogue.py --fetch --out addons/spacesim/sky/hyg_v44.stars
python3 tools/build_star_catalogue.py --csv /tmp/hyg_v44.csv --out ...   # from a local copy
python3 tools/build_star_catalogue.py --csv /tmp/hyg_v44.csv --report    # numbers, write nothing
```

The tool prints the calibration below, so a rebuild is also a re-check.

## Format

A flat binary, **bucketed by cube-face cell**: the stars of a cell are contiguous, then a table says
where each cell's run starts and how long it is. That is what lets the shader test one cell's handful
of stars instead of 119,613 of them — at this depth a cell holds **3 stars at the median and 17 at
worst**, and the worst one bounds the shader's loop.

```
magic      8 bytes    "SPSSSKY1"
version    uint32     format version (1)
grid       uint32     cells per cube-face edge (84 -> 42,336 cells, 0.97 deg2 average)
count      uint32     number of stars
cell_count uint32     6 * grid * grid
stars      count x 10 bytes, IN CELL ORDER, little-endian:
    int16  x, y, z       unit direction, scaled by 32767
    int16  mag_milli     V magnitude x 1000
    int16  ci_milli      B-V colour index x 1000
cells      cell_count x 8 bytes:
    uint32 offset        index of the cell's first star
    uint32 count         how many stars it holds
```

Ten bytes a star, 1.5 MB for the whole sky. Precision is well below a pixel: an `int16` direction
step is ~3.5 arcsec, and a pixel at 1080p with a 38° fov is ~126 arcsec.

**The depth tunable is not a prefix of this file.** It is a shader uniform: the file holds the whole
sky and the shader skips anything fainter than the limit. Changing depth therefore costs a uniform
write rather than a rebuild, and going deeper can only ever *add* stars.

### The cell grid

A **cube-face** grid, not a lat-long one: nearly equal-area, so there are no pole piles, and
direction → (face, u, v) is the mapping every cubemap already uses. 94% of the cells are occupied.

`cell_of()` exists in two places — `tools/build_star_catalogue.py` and
`addons/spacesim/render/sky_stars.gdshader` — and they **must agree exactly**. That is the one piece
of arithmetic that crosses the language boundary, so it is written the same way in both.

### The frame — taken from the catalogue, not invented

HYG's own README: *"+X is in the direction of the vernal equinox (at epoch 2000), +Z towards the north
celestial pole, and +Y in the direction of R.A. 6 hours, declination 0 degrees."*

It is populated for every row and agrees with `rarad`/`decrad` exactly — Sirius to Betelgeuse is
27.105° computed either way — so the reduction copies that frame rather than deriving its own.

**The renderer must rotate this frame into the world's with a proper rotation, never a reflection.**
A mirrored sky is invisible against a random field and unmistakable against Orion, so the check is
worth stating: the transform's determinant must be +1.

## Calibration

This is what "accurate" means, and the reason the data was worth bringing in. Measured values are from
P. Schlyter, *Radiometry and photometry in astronomy* — the same source the vault already uses for the
night illuminances.

### Amount — counts to each magnitude, against the table

| mag ≤ | the catalogue | the table | ratio |
|---|---|---|---|
| 1 | 16 | 15 | 1.067 |
| 2 | 50 | 48 | 1.042 |
| 3 | 179 | 171 | 1.047 |
| 4 | 523 | 513 | 1.019 |
| 5 | 1637 | 1602 | 1.022 |
| 6 | 5070 | 4800 | 1.056 |

Within 2–7% at every magnitude. (The table is Bright Star Catalogue to magnitude 5 and Allen's
*Astrophysical Quantities* beyond.)

### Brightness — the light the stars deliver

A magnitude-0 star delivers **2.54e-6 lux**, so a V star delivers `2.54e-6 × 10^(−0.4V)`. Summed over
the catalogue:

| mag ≤ | illuminance | vs the measured 2e-4 lux |
|---|---|---|
| 5.0 | 1.6280e-04 | 0.814 × |
| **6.0** | **2.1497e-04** | **1.075 ×** |
| 6.5 | 2.4525e-04 | 1.226 × |
| 8.0 | 3.4214e-04 | 1.711 × |
| 9.0 | 3.8547e-04 | 1.927 × |

**The measured starlight figure lands on the naked-eye set**: stars to magnitude 6 come to 2.15e-4 lux
against a measured 2.0e-4 — within 8%. Two independent tables (counts, and photometry) and the real
catalogue all agree, which is why this target can be built on.

It also quantifies something that matters for the light floor: **the sky's total light grows with
depth** — 2.1e-4 at magnitude 6 and 3.9e-4 at 9, nearly double. So if the sky is the ambient source,
the floor moves with the depth tunable. That is physical, but it is worth knowing it is nearly 2×.

### Where the catalogue stops being a complete sky

Measured, against the fitted count distribution `N = 10^(0.754 + 0.4896V + 0.001159V² − 0.000235V³)`:

| mag ≤ | the catalogue | the fit | ratio |
|---|---|---|---|
| 6.0 | 5070 | 4815 | 1.053 |
| 7.0 | 15597 | 14368 | 1.086 |
| **8.0** | **41486** | **42136** | **0.985** |
| 8.5 | 61814 | 71617 | 0.863 |
| 9.0 | 83476 | 121050 | 0.690 |
| 9.5 | 99045 | 203384 | 0.487 |
| 10.0 | 108067 | 339547 | 0.318 |

**Complete to magnitude 8.0; a diminishing fraction beyond.** So the depth tunable honestly belongs in
**6.5 to 8.0**, with 9.0 as a soft ceiling at 69% — past that the field is not a uniform sample of the
sky, it is whatever Hipparcos happened to record.

## What was dropped, and why

- **The Sun is in this catalogue** — `Sol`, magnitude −26.7, G2V. It is a body in the system, not a
  background star, and leaving it in would put a second sun in the sky. Excluded by name *and* by
  magnitude `< −2.0`, so a future catalogue cannot reintroduce it silently.
- 1,890 stars have no B−V colour index. 1,191 of those recovered one from their spectral type;
  **699 have neither and are stored grey** (B−V = 0). All are faint.

## See also

- [[SpaceSim/Sky and Backgrounds|Sky and Backgrounds]] — the plan this data serves
- `tools/build_star_catalogue.py` — the reduction, and its comments carry the reasoning
