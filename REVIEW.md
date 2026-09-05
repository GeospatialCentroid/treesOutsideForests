# Pipeline Review — 2026-09-05

Review of the `agroforestry_Masks` pipeline as of commit `796c44e`. Everything
below was verified against the real data in this repo, not inferred from
reading. Numbers come from the checks named in each item.

Branch: `review/pipeline-audit-2026-09`

---

## Action required before trusting existing outputs

Three things already affected the 80-grid run in `outputs/forest_masks/`.

### 1. Three years of Census data are not the years they claim to be

`census_places_2009.gpkg`, `_2010.gpkg` and `_2013.gpkg` have attribute tables
**byte-identical to `_2021.gpkg`**. The old fallback wrote 2021 data under the
requested year's filename with nothing recording the swap, and the
`file.exists()` skip meant it was never revisited.

Verified by hashing the sorted attribute table of each cached file: 2009, 2010,
2013 and 2021 share one hash; every other year is distinct. (2020 also has 4,362
features but hashes differently, so it is genuine.)

Every `*_2009_Census.gpkg`, `*_2010_Census.gpkg` and `*_2013_Census.gpkg` in
`outputs/` is built from 2021 place boundaries.

**To fix:**

```sh
Rscript src/99_audit_census_cache.R          # confirms the finding, deletes nothing
rm data/raw/census/census_places_{2009,2010,2013,2021}.gpkg
rm -r outputs/forest_masks/{2009,2010,2013}  # rebuild these years
```

Then re-run. 2009 and 2010 genuinely have no Census Places; they will now fall
back to **2011** (nearest available) instead of 2021, and every file carries a
`census_source_year` column recording where the geometries actually came from.
2013 downloads normally — its substitution was an availability blip, not a
permanent gap.

### 2. A strip along the edge of every mask was blank

`terra::crop(nlcd, ext(grid))` uses `snap = "near"`, which snaps the crop extent
to the nearest 30 m cell boundary — rounding **inward** whenever the grid edge
falls inside a cell. Reprojecting that under-sized crop onto the 1 m template
left NA along the edges of **every** output.

Measured over 40 random grids for 2018: **1.0–2.9 % of each grid, mean 1.64 %**.
With `snap = "out"` plus a 30 m margin it is exactly **0** on every grid tested.

The realised impact on this LRR is small, and I want to be accurate about that:
forest is sparse here, so of those 40 grids only **one** had forest inside the
lost strip — 360 m², 0.10 % of total forest. The masks were geometrically
incomplete on all ~200,000 outputs, but the amount of *forest* actually lost in
LRR "F" is minor. The same bug would matter far more in a forested region.

### 3. The last run processed 80 grids, not 15,380

`src/02_run_pipeline.R:237` was `llr_grids <- llr_grids[1:80, ]`, left over from
testing (`.Rhistory` shows it going `[1:8, ]` → `[1:80, ]`). A full
`source("0_run.R")` would silently have produced 80 grids per year.

Now a `grid_limit` config value, `NULL` by default, which warns on every run
while it is set.

---

## Other correctness issues found and fixed

| # | Issue | Consequence |
| --- | --- | --- |
| 4 | `study_area` bbox was taken in EPSG:4326 and reprojected. `st_as_sfc()` gives a 4-vertex polygon, so reprojection draws straight edges across the curved lat/lon box. | 36 of 15,380 grids were partially masked to NA before the grid pipeline saw them (2 of them in the 80 processed). Rebuilt in EPSG:5070 with a 5 km margin → 0 grids clipped. |
| 5 | `terra::subst(..., others = 0)` rewrites NA cells too. | The study-area mask was erased at reclassification: "outside the study area" became 0, indistinguishable from "not forest" — the opposite of what the function's own docstring claimed. Verified: `subst` turned `c(41,21,NA,43)` into `1,0,0,1`. |
| 6 | Worker errors called `message()`. | `message()` output is discarded in multisession workers, so failures vanished. The README described `outputs/logs/fail_[id].txt` — that logging **was never implemented**. It is now. |
| 7 | `st_intersection` can return points/lines where a place only touches a grid boundary, and a mixed-type layer cannot be written to GeoPackage. | Latent write failure. Now extracts polygonal parts and casts to MULTIPOLYGON. |
| 8 | `buildGrids()` assigned `as.hexmode()` directly in the no-parent branch — an integer that only *prints* as hex. | Through a GeoPackage round-trip, id `a` becomes `10` and `10` becomes `16`. Not hit by the current pipeline, but this function builds the 100 km parent grid, so regenerating it would break id matching. |
| 9 | ZIP deleted before extraction was verified; no partial-download guard. | A failed unzip or interrupted transfer cost the whole 1.3 GB download again. |
| 10 | `options(timeout = ...)` raised and never restored. | Leaked into the rest of the session. |
| 11 | `parallel::detectCores()` can return NA. | `if (num_cores < 1)` would error on NA. |
| 12 | State selection used `st_crop(States, llr)` — the LRR **bounding box**. | Downloaded 8 states / 4,079 places for 2018 where 5 states / 2,641 suffice. Verified none of the 1,438 dropped places touch any sample grid, and the same 319 grids intersect a place either way. |

### One latent bug I introduced and caught

Mapping over row indices instead of a pre-split list exposed something the
original code was only avoiding by accident. Workers are fresh R sessions where
`sf` and `terra` are **not attached**, so `sample_grids[i, ]` fell through to
`[.data.frame`, which drops the `sf_column` attribute. The result still claimed
class `"sf"` but had no usable geometry, and `terra::ext()` failed on a NULL —
all 12 test grids failed. Fixed by declaring
`furrr_options(packages = c("sf", "terra"))`, which makes the worker environment
explicit rather than dependent on how `.x` happens to be shaped.

---

## Efficiency changes

- **`split()` on the 15,380-row sf** cost 6.5 s and inflated 12 MB of geometry
  into **111 MB** of single-row data frames — once per year, all serialised to
  the workers. Now maps over row indices.
- **The future plan was rebuilt inside the year loop**, tearing down and
  respawning the worker pool 13 times. Now set up once.
- **Binary masks were written as Float32.** A 0/1 mask as INT1U + DEFLATE goes
  from ~53 MB to ~16 MB per year (3.3×).
  *Correction to my own first assumption:* I expected tiling to speed up the
  windowed reads substantially. I benchmarked it — **60 windowed crops took
  0.63 s striped vs 0.62 s tiled, i.e. no difference.** At 53 MB the file sits
  in page cache. The change is worth keeping for size and for typing "no data"
  explicitly, not for speed.

---

## Things I did not change

- **`geomentry` typo** (`src/generateAOI.R:24`) — the geometry column is
  literally spelled `geomentry`. Everything uses `sf::st_geometry()` so it is
  harmless, and the file is marked *"currently duplicated from the
  preprocessingFunction.R"*. Renaming it here would diverge from that source of
  truth for no functional gain. Your call.
- **`plan.md`** — left as the original design document. Note it describes a STAC
  / Planetary Computer approach that the code does not use; the implementation
  downloads bundles directly from MRLC.
- **`lower48MLRA.gpkg`, `naip_1km_..._2019.tif`** — present in `data/` but unused
  by the pipeline. `templateImage` (which read the NAIP file) was removed from
  the config since nothing consumed it.
- **Existing outputs** — nothing in `outputs/` or `data/` was deleted or
  modified. All remediation is a command for you to run.

---

## How the fixes were verified

- 12 grids end-to-end through the real parallel pipeline: 24/24 files, 0
  failures, 0 NA cells, CRS 5070.
- Edge fix: 0 NA cells across every grid tested, vs a mean 16,402 before.
- Reclassification: identical forest counts on real NLCD (2,146 = 2,146) with NA
  now preserved; INT1U round-trip checked.
- Grid generation: all 386 grids under parent `1548` regenerate with ids,
  geometries and bbox identical to the cache.
- Census: 2018 downloads normally and stamps `census_source_year = 2018`; 2009
  correctly fails, falls back to 2011, warns, and records the substitution.
- Census state selection: 0 of 1,438 dropped places intersect any sample grid.
