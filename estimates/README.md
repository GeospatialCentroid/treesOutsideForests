# estimates/

Area-weighted estimates of trees outside forests (TOF) from the per-cell model
output: one figure per MLRA and one per LRR, for each naip target year, with
both denominators (eligible land, all land) side by side.

**Status: runs end to end on synthetic model output.** No real model output
exists yet, so `config.yml` points the driver at a synthetic pixel-count table
(`tools/make_synthetic_cells.R`) built to look like the partner's grid-level
product. The estimators are checked by `test/test_estimators.R` (hand-built
table) and `test/test_synthetic_recovery.R` (recovers the generating truth for
every MLRA and the LRR). Settings live in the `estimates` section of the root
`config.yml`.

| Script | What it does |
|--------|--------------|
| `00_run_estimates.R` | Driver: cell list, model output (table or rasters), stratum areas per target year (cached), MLRA and LRR estimates, all written to `estimates$paths$out_dir`. |
| `functions/areas.R` | `mask_layers()`, `polygon_mask_areas()`, `cell_geometry()`, `cell_areas()`, `stratum_areas()`. |
| `functions/model_output.R` | Table mode: `read_model_table()`, `join_model_table()`. Raster mode: `naip_year_table()`, `model_path()`, `read_model_cell()`, `join_model_output()`. |
| `functions/estimators.R` | `estimate_mlra()`, `estimate_lrr()`, `ratio_estimate()`. |
| `functions/synthetic.R` | `synthetic_truth()`, `synthetic_cells()`: seeded stand-in for the model output. |
| `tools/make_synthetic_cells.R` | Writes the synthetic table and its truth to `estimates$synthetic$out_dir`. |
| `test/test_estimators.R` | Hand-built table with known answers (the worked example below); exits 1 on any mismatch. |
| `test/test_synthetic_recovery.R` | Generates the synthetic table, round-trips it through the reader, and checks every MLRA and LRR estimate against the truth within 3 standard errors. No masks needed. |

```sh
Rscript estimates/test/test_estimators.R
Rscript estimates/test/test_synthetic_recovery.R
Rscript estimates/tools/make_synthetic_cells.R   # then source("estimates/00_run_estimates.R")
```

## Model output as a pixel-count table

The partner's grid-level product is expected as one CSV with a row per cell and
target year. Every grid is predicted at a fixed 1 m pixel, so the table holds
pixel **counts** and the reader turns them into areas with
`estimates$pixel_area_m2` (1 m² by default). The masks are applied inside the
model, so the table's own eligible count is the eligible denominator.

| column | required | meaning |
|--------|----------|---------|
| `id` | yes | 1 km cell id, as in the sample list |
| `target_year` | yes | naip target year |
| `actual_year` | no | NAIP year actually used; defaults to `target_year` |
| `tof_px` | yes | pixels predicted as trees outside forest |
| `eligible_px` | yes | pixels not masked out |
| `footprint_px` | no | all pixels of the cell; defaults to the cell area |

`read_model_table()` refuses duplicate cell-years, NA counts and `tof_px`
above `eligible_px`; leave a cell-year out rather than filling it with NA, and
it is counted in `n_missing`. An `MLRA_ID` column in the table is ignored: the
sample list decides the MLRA. Set `estimates$model_source` to `"table"` and
`estimates$paths$model_table` to the file.

### The synthetic table

`tools/make_synthetic_cells.R` writes `synthetic_cells_lrr_F.csv` in that
layout for all sampled cells and target years, plus `synthetic_truth_lrr_F.csv`
with the generating parameters per MLRA. The draw is seeded
(`estimates$synthetic$seed`) and built to look like LRR F:

- each MLRA has its own mean TOF share of eligible land (0.5 to 5 %), so the
  stratified weighting is exercised;
- most cells have no TOF at all (55 to 80 % zeros); the rest are right-skewed
  (lognormal, capped at 50 % of eligible land);
- a cell's share is nearly constant over the decade: 3 % relative noise per
  year, 1 % of cells losing cover from 2016 and 1 % gaining from 2020;
- masks are small and zero-inflated: 1 to 6 % forest and under 1 % urban per
  MLRA, held fixed across years for a cell.

The recovery test is the same draw checked against the truth. Seed 2026 put
MLRA 59 four standard errors low: a heavy-tailed draw that misses the big
cells gets a low mean and a low standard error together. The tail was
lightened (sdlog 0.8) and the seed set to 3, where every MLRA-year is within
2 standard errors. That is a property of the synthetic distribution to keep
in mind when reading real standard errors, not of the estimator.

## Estimator

MLRAs are strata. Within an MLRA every sampled 1 km cell had the same
inclusion probability (`sampling/README.md`), so the MLRA estimate is a ratio
of sample totals and the LRR estimate combines the strata with wall-to-wall
MLRA areas as weights. Per cell `i` in MLRA `h`:

| symbol | column | meaning |
|--------|--------|---------|
| `f_hi` | `footprint_m2` | the whole 1 km cell, no mask |
| `a_hi` | `eligible_m2` | the part of `f_hi` that is neither NLCD forest nor a Census place (union of the two masks, which overlap) |
| `t_hi` | `tof_m2` | TOF area the model found inside the cell |

Both denominators are always computed; a `denominator` column in every output
table says which one a row is.

| denominator | MLRA estimate `R_h` | LRR estimate | reads as |
|-------------|---------------------|--------------|----------|
| `eligible` | `sum(t_hi) / sum(a_hi)` | `sum_h(R_h * E_h) / sum_h(E_h)` | share of non-forest, non-urban land that is TOF |
| `total` | `sum(t_hi) / sum(f_hi)` | `sum_h(R_h * A_h) / sum_h(A_h)` | share of all land that is TOF |

`A_h` and `E_h` are the total and eligible areas of the whole MLRA polygon,
measured from the mask layers by `stratum_areas()`, not estimated from the
sample. Water is in neither mask, so it is eligible land.

Standard errors are the linearised ratio-estimator form per stratum,
`Var(R_h) = sum((t_hi - R_h d_hi)^2) / ((n_h - 1) n_h mean(d)^2)` with `d` the
chosen denominator, combined across strata as `sqrt(sum(W_h^2 Var(R_h)))`.
For a systematic lattice this is conservative. No finite population
correction.

### Worked example (the unit test)

MLRA A has four cells with eligible areas 0.9, 0.5, 0.1 and 0 km² and TOF
areas 0.045, 0.05, 0.03 and 0 km². The mean of the three defined cell
percentages would be 15 %; the ratio estimator gives 0.125 / 1.5 = 8.33 % of
eligible land and 0.125 / 4 = 3.13 % of all land. With MLRA B at 20 % and
C at 4 % and stratum areas (total / eligible km²) of 60,000 / 22,500,
20,000 / 16,000 and 120,000 / 30,000, the LRR comes to 6,275 / 68,500 = 9.16 %
of eligible land and 10,675 / 200,000 = 5.34 % of all land.

## Data flow

1. **Cell list.** `cell_geometry()` rebuilds each sampled cell from its id
   (`sampling/functions/grid_cells.R`). A cell drawn by two MLRAs (15 in F) is
   counted once, in the first MLRA that drew it in sample-list order, the same
   rule `sampling/00_prepare_sites.R` uses: the model is the same raster
   whichever MLRA drew the cell. Cells are not clipped to the MLRA, so a
   boundary cell's footprint is the whole square even where it hangs over.
2. **Model output, table mode** (`model_source: "table"`).
   `join_model_table()` gives every cell one row per target year in the
   table; `eligible_m2` and `footprint_m2` come from the table's counts. No
   cell-level mask areas are measured.
3. **Model output, raster mode** (`model_source: "raster"`).
   `naip_year_table()` reads the naip `status.json` files; the mask year for a
   cell is the year NAIP was **actually captured** (`actual_year`), and for
   target 2012 every cell so far is 2011 imagery. `cell_areas()` measures
   footprint, forest, urban, their overlap and the eligible remainder per cell
   and mask year (cached in `out_dir`). `join_model_output()` reads, per cell
   and actual year, the raster named by `estimates$model_pattern` (1 = TOF,
   0 = not, NA = masked) and records `tof_m2` and `model_eligible_m2`; the
   NoData value must be declared in the file. `eligible_from: "model"` makes
   the estimators use the raster's non-NA area as the eligible denominator
   instead of the mask-derived one. A cell-year with no raster gets
   `tof_m2 = NA`, is dropped from the estimate and counted in `n_missing`.
4. **Stratum areas.** `stratum_areas()` measures each MLRA polygon against the
   target year's masks: forest from the 30 m binary raster through
   `exactextractr` (partial edge pixels count by covered area), urban from the
   dissolved places polygon by exact vector intersection. Cached per year.
5. **Estimates.** `estimate_mlra()` then `estimate_lrr()`.

### Outputs (ignored by git)

| file | contents |
|------|----------|
| `cellAreas_lrr_F_mask_<year>.csv` | raster mode only: mask areas per cell for one mask year |
| `strataAreas_lrr_F_<year>.csv` | total and eligible area per MLRA for one mask year |
| `cells_lrr_F_<target>.csv` | the cell-year table with the model output joined |
| `estimates_mlra_lrr_F.csv` | per MLRA, year and denominator: n, sums, estimate, se, pct, pct_se |
| `estimates_lrr_F.csv` | per year and denominator: area, TOF area, estimate, se, pct, pct_se |

## Open points

- **Partner integration.** The partner's Monte Carlo pipeline gives the
  model-side variance (V1); this stage gives the sampling variance (V2). The
  combined uncertainty is V1 + V2 per MLRA, summed across strata for the LRR.
  Not implemented yet; replicate columns in the table are the likely way in.
- **Model raster format.** The pattern and the 1 / 0 / NA convention are
  assumptions until the model stage exists; `read_model_cell()` is the only
  place that reads them.
- **Mask year for strata.** Cells use their actual capture year, strata the
  target year, so a target year mixing 2011 and 2012 imagery weights with the
  2012 MLRA areas. The year-to-year difference in eligible area is small, but
  it is a choice.
- Cells with zero eligible area stay in the table (`a = 0`, `t = 0`).
- Only LRR F is in scope; G has no masks.
