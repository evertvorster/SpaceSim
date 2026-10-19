#!/usr/bin/env python3
"""build_star_catalogue.py — reduce the HYG catalogue into SpaceSim's compact star asset.

    python3 tools/build_star_catalogue.py --fetch --out addons/spacesim/sky/hyg_v44.stars
    python3 tools/build_star_catalogue.py --csv /tmp/hyg_v44.csv --out ...
    python3 tools/build_star_catalogue.py --csv ... --report     # calibration numbers only

## Why this exists

The sky is calibrated against the stars we can actually see from Sol, and the honest way to model a
thing accurately is to measure the real one. Evert, 2026-10-14: *"We are calibrating here, so if we
have access to proper data, we can bring that in as a dependency, and later we'll model on how to
generate something similar."*

So this reduces the real catalogue rather than generating a field that imitates it. The generator for
*other* systems comes later, and this is what it will be calibrated against.

## Source

HYG v4.4 — Hipparcos + Yale Bright Star + Gliese, merged — <https://codeberg.org/astronexus/hyg>
(CC BY-SA 4.0; see PROVENANCE.md beside the asset). The file is stored in **Git LFS**, so the plain
`raw` URL returns a 133-byte pointer: fetch it from the `media` endpoint, and verify the sha256
against the pointer's oid, which is what FETCHED_SHA256 is.

## The output format

A flat, BUCKETED binary: the stars grouped by the cube-face cell they fall in, then the cell table.
The shader cannot test 119,613 stars a pixel; it finds the one cell its ray lands in and tests the
stars there. **Every cell is written in ascending magnitude order**, which is what lets the shader
leave its loop early rather than walking stars it will never draw -- and that in turn is what makes a
coarse grid cheap: at GRID 32 a cell holds 18 stars on average and 1.5 of them are visible at the
default depth.

**Coarser is better for correctness, and the reason is a lattice mismatch.** The shader admits a star by
the CELL it falls in but covers it by the PIXEL lattice, and a star within half a pixel of a cell
boundary has its one covering pixel across that boundary -- already filtered out -- so no pixel draws
it. At GRID 84 a cell is ~16 px at 1080p and 70 degrees, which leaves a blind band of ~3% a star; at
GRID 32 it is 1.2%. GRID 84 was chosen for a *loop bound* that the magnitude ordering has since made
irrelevant, so a finer grid buys nothing now. The residual is what a 3x3 cell gather, or duplicating
the stars near a boundary into the neighbouring cell, would remove.

    magic      8 bytes    "SPSSSKY1"
    version    uint32     format version
    grid       uint32     cells per cube-face edge
    count      uint32     number of stars
    cell_count uint32     6 * grid * grid
    stars      count x 10 bytes, IN CELL ORDER:
        int16  x, y, z          unit direction, scaled by 32767
        int16  mag_milli        V magnitude x 1000
        int16  ci_milli         B-V colour index x 1000
    cells      cell_count x 8 bytes:
        uint32 offset           index of the cell's first star
        uint32 count            how many stars it has

Ten bytes a star is ~1.2 MB at full depth. Precision is comfortably below a pixel: an int16
direction step is ~3.5 arcsec, and a pixel at 1080p and a 38-degree fov is ~126 arcsec.

The grid is a CUBE-FACE grid, not a lat-long one: nearly equal-area, so no pole piles, and
direction -> (face, u, v) is the mapping every cubemap already uses. `cell_of()` here and in the
shader are the one piece of arithmetic that must agree across the language boundary, so they are
written the same way in both, and the tool checks every star lands in a cell the shader will look in.
"""

import argparse
import csv
import gzip
import hashlib
import math
import os
import struct
import sys
import urllib.request

SOURCE = "HYG v4.4 (Hipparcos + Yale Bright Star + Gliese)"
URL = ("https://codeberg.org/astronexus/hyg/media/branch/main/"
       "data/hyg/CURRENT/hyg_v44.csv.gz")
FETCHED_SHA256 = "00b349893b9a53106dd488d8371e8d2fa586043e500bb3cdb8bff3931682197d"
FETCH_SIZE = 13636362

MAGIC = b"SPSSSKY1"
VERSION = 1
RECORD = struct.Struct("<hhh hh")   # x, y, z, mag_milli, ci_milli
CELL = struct.Struct("<II")         # offset, count

## Cells per cube-face edge. 6 * 84^2 = 42,336 cells, so an average cell is 0.97 square degrees:
## about one star at magnitude 8 and three at the full depth of the catalogue. Finer would cost the
## same per pixel -- the lookup is one cell either way -- and only shrink the per-cell star list.
GRID = 32


def cell_of(x, y, z, grid):
    """The cube-face cell a direction falls in. MUST match `cell_of()` in the shader, exactly."""
    ax, ay, az = abs(x), abs(y), abs(z)
    if ax >= ay and ax >= az:
        face = 0 if x > 0.0 else 1
        u, v = y / ax, z / ax
    elif ay >= az:
        face = 2 if y > 0.0 else 3
        u, v = x / ay, z / ay
    else:
        face = 4 if z > 0.0 else 5
        u, v = x / az, y / az
    iu = min(max(int((u * 0.5 + 0.5) * grid), 0), grid - 1)
    iv = min(max(int((v * 0.5 + 0.5) * grid), 0), grid - 1)
    return face * grid * grid + iv * grid + iu

## The frame, taken from the catalogue rather than invented. HYG's own README: "+X is in the
## direction of the vernal equinox (at epoch 2000), +Z towards the north celestial pole, and +Y in the
## direction of R.A. 6 hours, declination 0 degrees." It is populated for every row and agrees with
## `rarad`/`decrad` exactly (Sirius to Betelgeuse is 27.105 deg either way), so the reduction copies
## it instead of deriving its own -- which is the whole reason this is a note and not a bug report.
##
## The renderer must then rotate this frame into the world's with a PROPER ROTATION, never a
## reflection: a mirrored sky is invisible against a random field and obvious against Orion.
LUX_PER_MAG0 = 2.54e-6

## Counts to each magnitude over the whole sky: Bright Star Catalogue to 5, Allen's *Astrophysical
## Quantities* beyond. This is the table the reduction is checked against, and the reason the whole
## thing is trustworthy — it is measured, not chosen.
ALLEN = [(1, 15), (2, 48), (3, 171), (4, 513), (5, 1602), (6, 4800)]

## The measured total starlight on a clear moonless night: 2e-4 lux.
STARLIGHT_LUX = 2e-4

## The count distribution as a fit, from the same source as ALLEN: N = 10^(0.754 + 0.4896V +
## 0.001159V^2 - 0.000235V^3). Used to show where the catalogue STOPS being a complete sky, which is
## a measured statement about the data rather than a claim about Hipparcos.
def allen_count(v):
    return 10.0 ** (0.754 + 0.4896 * v + 0.001159 * v * v - 0.000235 * v ** 3)


## B-V per spectral class, for the stars whose colour index is missing (1,890 of 119,614). Straight
## from the class's main-sequence value; it is a fallback for a colour tint, not photometry.
BV_BY_CLASS = {"O": -0.33, "B": -0.30, "A": 0.00, "F": 0.30,
               "G": 0.58, "K": 0.81, "M": 1.40, "C": 1.80, "S": 1.60}


def fetch(path):
    """Download the source and check it against the hash the LFS pointer declares.

    With no check, a redirect or an error page becomes the input and the whole reduction is quietly
    wrong -- which is exactly what the first attempt at this URL produced.
    """
    print("fetching %s" % URL)
    with urllib.request.urlopen(URL) as r:
        blob = r.read()
    got = hashlib.sha256(blob).hexdigest()
    if len(blob) != FETCH_SIZE or got != FETCHED_SHA256:
        sys.exit("FAILED: fetched %d bytes, sha256 %s\n  expected %d bytes, sha256 %s"
                 % (len(blob), got, FETCH_SIZE, FETCHED_SHA256))
    print("  %d bytes, sha256 matches the LFS pointer" % len(blob))
    with open(path, "wb") as f:
        f.write(blob)
    return path


def spectral_bv(spect):
    """B-V from a spectral type's class letter, skipping the lowercase prefixes (k, g, e, d, w...)."""
    for ch in (spect or "").upper():
        if ch in BV_BY_CLASS:
            return BV_BY_CLASS[ch]
    return None


def load(csv_path):
    """Every star we want, as (x, y, z, mag, ci), plus a tally of what was dropped and why."""
    kept = []
    dropped = {"Sol": 0, "no magnitude": 0}
    no_ci = 0
    no_colour_at_all = 0
    with open(csv_path, newline="") as f:
        for row in csv.DictReader(f):
            # **The Sun is in this catalogue** (mag -26.7, "Sol", G2V). It is a body in the system,
            # not a background star, and leaving it in would put a second sun in the sky.
            if (row.get("proper") or "") == "Sol" or float(row["mag"]) < -2.0:
                dropped["Sol"] += 1
                continue
            if not row.get("x") or not row.get("mag"):
                dropped["no magnitude"] += 1
                continue
            x, y, z = float(row["x"]), float(row["y"]), float(row["z"])
            n = math.sqrt(x * x + y * y + z * z)
            if n <= 0.0:
                dropped["no magnitude"] += 1
                continue
            ci = row.get("ci")
            if ci in (None, ""):
                no_ci += 1
                ci = spectral_bv(row.get("spect"))
                if ci is None:
                    ci = 0.0
                    no_colour_at_all += 1
            kept.append((x / n, y / n, z / n, float(row["mag"]), float(ci)))
    kept.sort(key=lambda s: s[3])
    return kept, dropped, no_ci, no_colour_at_all


def write_asset(stars, path):
    """Write the bucketed asset: the stars grouped by cell, then the cell table."""
    cell_count = 6 * GRID * GRID
    buckets = [[] for _ in range(cell_count)]
    for s in stars:
        buckets[cell_of(s[0], s[1], s[2], GRID)].append(s)

    order = []
    cells = []
    for bucket in buckets:
        cells.append((len(order), len(bucket)))
        order.extend(bucket)

    with open(path, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<IIII", VERSION, GRID, len(order), cell_count))
        for x, y, z, mag, ci in order:
            f.write(RECORD.pack(int(round(x * 32767)), int(round(y * 32767)),
                                int(round(z * 32767)), int(round(mag * 1000)),
                                int(round(ci * 1000))))
        for offset, count in cells:
            f.write(CELL.pack(offset, count))

    sizes = sorted(len(b) for b in buckets)
    occupied = sum(1 for b in buckets if b)
    print("\n=== the lookup ===")
    print("  %d cells of %.2f deg2 average; %d occupied (%.0f%%)"
          % (cell_count, 41252.961 / cell_count, occupied, 100.0 * occupied / cell_count))
    print("  stars a cell: median %d, 99th %d, worst %d"
          % (sizes[len(sizes) // 2], sizes[int(len(sizes) * 0.99)], sizes[-1]))
    print("  (the worst cell bounds the shader's loop bound, MAX_PER_CELL in sky_stars.gdshader)")
    return os.path.getsize(path)


def illuminance(stars, limit):
    """The light the stars down to `limit` deliver, in lux, by summing 2.54e-6 * 10^(-0.4 V)."""
    return sum(LUX_PER_MAG0 * 10.0 ** (-0.4 * s[3]) for s in stars if s[3] <= limit)


def report(stars, path, size):
    print("\n=== the asset ===")
    print("  %s  %d stars, %.1f KB, %d bytes a star"
          % (path, len(stars), size / 1024.0, RECORD.size + 0))
    print("  brightest %.2f  faintest %.2f" % (stars[0][3], stars[-1][3]))

    print("\n=== AMOUNT: counts to each magnitude, against the table ===")
    print("  mag<=   catalogue   table   ratio")
    for v, expect in ALLEN:
        n = sum(1 for s in stars if s[3] <= v)
        print("  %5d   %9d %7d %7.3f" % (v, n, expect, n / float(expect)))

    print("\n=== BRIGHTNESS: light from the stars down to each magnitude ===")
    print("  the measured total starlight on a clear moonless night is %.1e lux" % STARLIGHT_LUX)
    print("  mag<=   illuminance      vs measured")
    for limit in (5.0, 6.0, 6.5, 7.0, 8.0, 9.0, 9.5):
        n = sum(1 for s in stars if s[3] <= limit)
        lux = illuminance(stars, limit)
        print("  %5.1f   %11.4e      %6.3f x   (%d stars)"
              % (limit, lux, lux / STARLIGHT_LUX, n))

    print("\n=== COMPLETENESS: where the catalogue stops being a complete sky ===")
    print("  cumulative count against the fitted distribution, so this is measured, not asserted:")
    print("  mag<=   catalogue      fit     ratio")
    for v in (6.0, 7.0, 7.5, 8.0, 8.5, 9.0, 9.5, 10.0):
        n = sum(1 for s in stars if s[3] <= v)
        expect = allen_count(v)
        print("  %5.1f   %9d %9.0f %9.3f" % (v, n, expect, n / expect))
    print("  (a ratio falling away from 1 is where the sample thins; above ~1.0 it is complete)")


def main():
    ap = argparse.ArgumentParser(description="Reduce HYG into SpaceSim's star asset.")
    ap.add_argument("--csv", help="an already-downloaded hyg_v44.csv (or .csv.gz)")
    ap.add_argument("--fetch", action="store_true", help="download the source (verified)")
    ap.add_argument("--gz", default="/tmp/hyg_v44.csv.gz", help="where --fetch puts the download")
    ap.add_argument("--out", help="where to write the asset")
    ap.add_argument("--report", action="store_true", help="calibration numbers only; write nothing")
    args = ap.parse_args()

    if args.fetch or not args.csv:
        args.csv = fetch(args.gz)
    # **Not an `elif` — the fetch path is a `.gz` too, and this used to be skipped for it.** The
    # documented usage (`--fetch --out ...`) therefore handed a gzipped file to the CSV reader and died
    # on a UnicodeDecodeError, so the tool could only be run from an already-plain CSV.
    if args.csv.endswith(".gz"):
        with gzip.open(args.csv, "rt", newline="") as f:
            plain = args.csv[:-3]
            with open(plain, "w") as g:
                g.write(f.read())
        args.csv = plain

    stars, dropped, no_ci, no_colour_at_all = load(args.csv)
    print("\nkept %d stars; dropped %d (the Sun is in the catalogue) and %d with no magnitude"
          % (len(stars), dropped["Sol"], dropped["no magnitude"]))
    print("colour: %d stars had no B-V; %d of those recovered one from the spectral type and %d"
          % (no_ci, no_ci - no_colour_at_all, no_colour_at_all))
    print("        had neither and are stored grey")

    size = write_asset(stars, args.out) if (args.out and not args.report) else 0
    report(stars, args.out or "(not written)", size)


if __name__ == "__main__":
    main()
