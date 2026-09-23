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
| `01_aoi_areas.R` | The sampled cells clipped to the MLRA that drew them, with total, masked and eligible area per target year against the combined mask. See [Clipped AOIs](#clipped-aois). |
| `02_placeholder_tof.R` | Placeholder TOF per clipped AOI and year, calibrated to each MLRA's NLCD forest share, packaged as the partner spreadsheet. See [Placeholder for partners](#placeholder-for-partners). |
| `functions/areas.R` | `mask_layers()`, `polygon_mask_areas()`, `cell_geometry()`, `cell_areas()`, `stratum_areas()`; against the combined mask: `combined_mask()`, `mask_area_m2()`, `clip_cells_to_mlra()`. |
| `03_montecarlo_replicates.R` | Monte Carlo replicates of the placeholder for one year: 50,000 clipped-normal draws per AOI as a Parquet dataset. See [Monte Carlo replicates](#monte-carlo-replicates). |
| `functions/placeholder.R` | `placeholder_tof()`, `calibrate_group()`: the seeded, calibrated stand-in. |
| `functions/montecarlo.R` | `mc_params()`, `mc_draw()`, `mc_summary()`: per-AOI normal parameters, the draws, their summary. |
| `04_replicate_estimates.R` | Area-weighted estimates for every replicate, per MLRA and for the LRR, and their summary statistics. See [Estimates over the replicates](#estimates-over-the-replicates). |
| `functions/replicate_estimators.R` | `replicate_matrix()`, `read_wide_csv_matrix()`, `replicate_ratio()`, `replicate_mlra()`, `replicate_lrr()`, `summarise_replicates()`, `summarise_lrr()`: the estimators of `estimators.R` applied to a replicate matrix. |
| `test/test_replicate_estimators.R` | Hand-built matrix; every replicate must equal `estimate_mlra()` / `estimate_lrr()` run on it alone. |
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
Rscript estimates/01_aoi_areas.R                 # clipped AOIs and their areas (needs the combined masks)
Rscript estimates/02_placeholder_tof.R           # the partner spreadsheet
Rscript estimates/03_montecarlo_replicates.R     # 50,000 replicates per AOI for 2020, Parquet (about 4 minutes)
Rscript estimates/test/test_replicate_estimators.R
Rscript estimates/04_replicate_estimates.R       # estimates for every replicate and their summaries (about 2 minutes)
```

## Clipped AOIs

`01_aoi_areas.R` builds one feature per `(id, MLRA_ID)` pair in the sample
list: the 1 km cell clipped to the MLRA polygon that drew it. A cell drawn by
two neighbouring MLRAs (15 in F) becomes two pieces, one per MLRA; the MLRA
polygons do not overlap, so neither do the pieces, and every square metre of
the sample is counted once. In F that is 15,395 AOIs, 14,599 whole cells and
796 clipped ones, the smallest a sliver of about 1 m².

For each target year the masked area is the exact vector intersection with
the masks stage's combined mask (`llr_F_mask_<year>.gpkg`, forest and places
unioned), and eligible is total minus masked. On a random 300 cells this
agrees with the forest-raster-plus-urban-polygon method above to 0.01 m².

Outputs: `aoiAreas_lrr_F.csv` (long: id, MLRA_ID, target_year, cell_m2,
aoi_m2, mask_m2, eligible_m2) and `aoi_lrr_F_clipped.gpkg` with one layer per
year (`aoi_2012`, ...). The whole run takes well under a minute.

Note that `00_run_estimates.R` still uses the unclipped cells of
`cell_geometry()` with first-MLRA-wins for shared ids; moving the driver and
`read_model_table()` onto the `(id, MLRA_ID)` key is the open step.

## Placeholder for partners

No model output exists yet, so `02_placeholder_tof.R` writes a stand-in with
the right shape for partners to build their MLRA-level aggregation on. It is
**not** a measurement and the workbook's `readme` sheet says so. Two things
are imposed (`functions/placeholder.R`, settings under `estimates$placeholder`):

- **Calibration.** Within every MLRA and year the area-weighted TOF share of
  the AOIs, `sum(tof) / sum(aoi_m2)`, equals that MLRA's NLCD forest share
  (forest / total area from `stratum_areas()`). The script checks this with
  `estimate_mlra()` and stops if it fails. Aggregating the table by MLRA
  therefore returns the NLCD forest share exactly; the LRR figure from
  `estimate_lrr()` comes to about 0.92 % of all land.
- **Shape.** Zero-inflated with a long right tail: `p_zero` (0.65) of AOIs
  have no TOF in any year, the rest a lognormal relative level (`sdlog` 1)
  scaled per MLRA-year, capped at `cap` (0.5) of the AOI's eligible land with
  the excess redistributed. TOF sits on eligible land only. An AOI's level is
  drawn once and carried across years with 3 % noise, 1 % of AOIs losing
  cover from 2016 and 1 % gaining from 2020, as in the synthetic generator.
  Seeded, so the workbook is reproducible.

Outputs under `estimates$placeholder$out_dir`:

| file | contents |
|------|----------|
| `placeholder_tof_lrr_F.xlsx` | sheets `readme`, `aoi_tof` (aoi_id, mlra_id / symbol / name, year, tof_area_m2, mask_area_m2, aoi_area_m2, eligible_area_m2, tof_pct_of_eligible, whole_cell), `mlra_summary` (sums per MLRA-year and the calibration target) |
| `placeholder_tof_lrr_F.csv` | the `aoi_tof` sheet |
| `placeholder_model_table_lrr_F.csv` | the same values in the pixel-count layout `read_model_table()` reads, keyed on id, MLRA_ID, target_year |
| `placeholder_targets_lrr_F.csv` | the per-MLRA-year targets |

## Monte Carlo replicates

The model's real product will carry Monte Carlo replicates per AOI, so
`03_montecarlo_replicates.R` writes a full-volume stand-in for one year:
`estimates$montecarlo$n_rep` (50,000) draws for every 2020 AOI of the
placeholder, about 770 million values. Each AOI gets a normal distribution
clipped to `[0, eligible]` with

```text
mean = tof * (1 + bias_rel) + fp_frac * eligible
sd   = sqrt((cv * tof)^2 + (sd_floor_frac * eligible)^2)
```

which encodes what is known about the model: it is very good at identifying
land without trees, so a zero-TOF AOI is drawn tightly around a small
false-positive floor with a share of its draws clipped to exactly 0; and it
over-predicts trees across the LRR, so an AOI with TOF is drawn around a mean
above its placeholder value with a spread that grows with the amount. The
draws are seeded once and generated MLRA by MLRA in `MLRA_ID` order.

Output is a hive-partitioned Parquet dataset in `replicates/` under
`estimates$montecarlo$out_dir`, one folder per MLRA (`mlra_id=<id>/part-0.parquet`,
zstd, about 4 bytes per row) with columns `aoi_id`, `replicate`,
`tof_area_m2` (float32); read that folder as one table with
`arrow::open_dataset()`, DuckDB or pyarrow. Beside it, `README.txt` for the
partner and `montecarlo_summary_lrr_F_2020.csv` with, per AOI, the parameters
used and the draws' mean, sd, 2.5 / 50 / 97.5 percentiles and share at zero.
`bias_rel`, `fp_frac`, `cv` and `sd_floor_frac` are the knobs to retune.

`tools/export_montecarlo_wide_csv.R <MLRA_ID>` writes one MLRA's replicates
as a wide CSV for a partner: `aoi_id`, then `rep_1` .. `rep_50000`, values
rounded to 0.1 m² (about 430 MB, more columns than Excel allows).

## Estimates over the replicates

`04_replicate_estimates.R` applies the estimator to every replicate. Nothing
changes in the formula: per MLRA the TOF area of AOI `i` in replicate `r` is
`X[i, r]` and the denominator `d[i]` (the clipped AOI's total or eligible
area) is the same in every replicate, so the 50,000 estimates are column sums,
`R_r = sum_i X[i, r] / sum_i d[i]`, and the linearised standard error is a
column sum of squared residuals (`functions/replicate_estimators.R`). The LRR
combines the MLRAs replicate by replicate with the stratum areas, exactly as
`estimate_lrr()` does; `test/test_replicate_estimators.R` checks that every
replicate equals the single-replicate estimators run on it alone.

Over the replicates, per MLRA and for the LRR and for both denominators,
`summarise_replicates()` gives the mean, the standard deviation (the
model-side uncertainty), median, 2.5 and 97.5 percentiles and range, the root
mean sampling variance across replicates (the design-side part) and the
combined standard error, `sqrt(sd^2 + mean(se^2))`. That is the V1 + V2
combination listed under open points below.

Outputs under `estimates$replicates$out_dir`:

| file | contents |
|------|----------|
| `replicateEstimates_mlra_lrr_F_2020.csv` | per MLRA, denominator and replicate: n, sums, estimate, se, pct, pct_se (1.1 million rows) |
| `replicateEstimates_lrr_F_2020.csv` | per denominator and replicate: the LRR estimate and se |
| `replicateSummary_mlra_lrr_F_2020.csv` | per MLRA and denominator: the summary above, as fractions and percent |
| `replicateSummary_lrr_F_2020.csv` | the same for the LRR, plus the LRR area and mean TOF area |
| `replicateContributions_lrr_F_2020.csv` | per MLRA and denominator: stratum area, weight, mean estimate and sd over replicates, mean TOF area and share of the LRR's TOF |

`summarise_lrr()` produces the LRR level in one call from the per-MLRA
replicate estimates and the stratum areas: the per-replicate LRR estimates,
their summary, and each MLRA's weight and contribution.

`estimates$replicates$wide_csv_check` names a partner-format wide CSV; when it
exists the driver runs it through `read_wide_csv_matrix()` and checks that its
MLRA estimates match the Parquet result.

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
