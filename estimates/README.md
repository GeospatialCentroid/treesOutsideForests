# estimates/

Area-weighted estimates of trees outside forests (TOF) from the per-cell model
output: one figure per MLRA and one per LRR, for each naip target year, with
both denominators (eligible land, all land) side by side.

**Status: drafted, under review.** The estimators are checked by
`test/test_estimators.R`; the geometry functions have been smoke-tested on a
handful of cells against the 2012 masks but the driver has not yet been run
end to end, because no model output exists yet. Settings live in the
`estimates` section of the root `config.yml`.

| Script | What it does |
|--------|--------------|
| `00_run_estimates.R` | Driver: cell geometry, mask areas per mask year (cached), model output join, MLRA and LRR estimates, all written to `estimates$paths$out_dir`. |
| `functions/areas.R` | `mask_layers()`, `polygon_mask_areas()`, `cell_geometry()`, `cell_areas()`, `stratum_areas()`. |
| `functions/model_output.R` | `naip_year_table()`, `model_path()`, `read_model_cell()`, `join_model_output()`. |
| `functions/estimators.R` | `estimate_mlra()`, `estimate_lrr()`, `ratio_estimate()`. |
| `test/test_estimators.R` | Hand-built table with known answers (the worked example below); exits 1 on any mismatch. |

```sh
Rscript estimates/test/test_estimators.R
```

## Estimator

MLRAs are strata. Within an MLRA every sampled 1 km cell had the same
inclusion probability (`sampling/README.md`), so the MLRA estimate is a ratio
of sample totals and the LRR estimate combines the strata with wall-to-wall
MLRA areas as weights. Per cell `i` in MLRA `h`:

| symbol | column | meaning |
|--------|--------|---------|
| `f_hi` | `footprint_m2` | the part of the cell inside the MLRA, no mask |
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

1. **Cell geometry.** `cell_geometry()` rebuilds each sampled cell from its id
   (`sampling/functions/grid_cells.R`) and clips it to the MLRA that drew it.
   A cell drawn by two MLRAs (15 in F) appears once per MLRA, each row holding
   only the part inside that MLRA. Tables are keyed on (`id`, `MLRA_ID`),
   never on `id` alone.
2. **Mask year.** `naip_year_table()` reads the naip `status.json` files. The
   mask year for a cell is the year NAIP was **actually captured**
   (`actual_year`); for target 2012 every cell so far is 2011 imagery. The
   stratum areas use the target year's masks.
3. **Mask areas.** `cell_areas()` and `stratum_areas()` measure footprint,
   forest, urban, their overlap and the eligible remainder. Forest comes from
   the 30 m binary raster through `exactextractr` (partial edge pixels count by
   covered area); urban from the dissolved places polygon by exact vector
   intersection. Cached per mask year in `out_dir` because they do not depend
   on the model.
4. **Model output.** `join_model_output()` reads, per cell and actual year, the
   raster named by `estimates$model_pattern` (1 = TOF, 0 = not, NA = masked)
   and records `tof_m2` (covered area of 1-pixels) and `model_eligible_m2`
   (covered area of non-NA pixels). The NoData value must be declared in the
   file. `eligible_from: "model"` makes the estimators use the raster's
   non-NA area as the eligible denominator instead of the mask-derived one;
   both columns are kept either way. A cell-year with no raster gets
   `tof_m2 = NA`, is dropped from the estimate and counted in `n_missing`.
5. **Estimates.** `estimate_mlra()` then `estimate_lrr()`.

### Outputs (ignored by git)

| file | contents |
|------|----------|
| `cellAreas_lrr_F_mask_<year>.csv` | mask areas per (id, MLRA_ID) for one mask year |
| `strataAreas_lrr_F_<year>.csv` | total and eligible area per MLRA for one mask year |
| `cells_lrr_F_<target>.csv` | the cell-year table with the model output joined |
| `estimates_mlra_lrr_F.csv` | per MLRA, year and denominator: n, sums, estimate, se, pct, pct_se |
| `estimates_lrr_F.csv` | per year and denominator: area, TOF area, estimate, se, pct, pct_se |

## Open points

- **Model raster format.** The pattern and the 1 / 0 / NA convention are
  assumptions until the model stage exists; `read_model_cell()` is the only
  place that reads them.
- **Mask year for strata.** Cells use their actual capture year, strata the
  target year, so a target year mixing 2011 and 2012 imagery weights with the
  2012 MLRA areas. The year-to-year difference in eligible area is small, but
  it is a choice.
- Cells with zero eligible area stay in the table (`a = 0`, `t = 0`).
- Only LRR F is in scope; G has no masks.
