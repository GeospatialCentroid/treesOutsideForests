# harmonize/

Optional radiometric harmonisation of the NAIP exports across years, applied
before the model is run. NAIP is delivered as uncalibrated digital numbers, and
the same ground shifts its whole histogram between flight years (haze, sensor,
vendor stretch); a fixed model reads that shift as land-cover change. The
method is ported from `neymanSampling/scripts/imageHarmonization.R` and
`docs/histNormalization.Rmd` on the work drive.

| Script | What it does |
|--------|--------------|
| `0_run.R` | Builds `data/naip/harmonized/`, a second export tree with exactly the layout of `data/naip/exportData/`, and compiles `harmonization_log.csv`. |
| `functions/histogram_matching.R` | The KS drift test, the consensus gate, the quantile-matching lookup tables and the per-cell driver. |

Settings live in the `harmonize` section of the root `config.yml`.

## Running

```sh
Rscript harmonize/0_run.R                                  # every cell in the export tree (about three minutes for 336 cells, 6 workers)
Rscript harmonize/0_run.R 1549-3-5-13-2 1613-4-15-13-3     # only these cells
Rscript harmonize/0_run.R --mode=reference --reference=2020 --out=data/naip/harmonized_ref2020
```

Then point the model at the harmonised tree instead of the raw one:

```sh
model/.venv/bin/python model/04_predict.py --harmonized --run data/model/runs/<run> --out <dir> data/naip/exportData/aoi_<id>_<year>/
```

`--harmonized` swaps the export root for the harmonised root and keeps the
rest of the path; a cell-year with no harmonised counterpart is read raw, with
a warning.

## What it does

For every cell, the years are the export folders `aoi_<id>_<year>` holding a
`naip_1.5km` GeoTIFF. Two modes:

- **consensus** (default): pairwise Kolmogorov-Smirnov distances on the blue
  and NIR bands (blue tracks haze, NIR the sensor and vegetation response)
  pick the year that stands apart from the other two. It is remapped only if
  its mean distance to the pair exceeds `ks_threshold` (0.15) *and*
  `ks_relative` (2) times the pair's own distance. Stable stacks, and stacks
  where all three years differ alike, are left untouched. The reference is the
  most recent of the two consensus years. Needs three years; a cell with fewer
  is linked as is.
- **reference**: every year but the reference (`reference_year`, `latest` or a
  year) is remapped to it.

Remapping is empirical CDF matching: 256 quantiles of every valid pixel in the
target and reference images give a per-band lookup table over 0 to 255, applied
to all four bands so the inter-band relations are kept. The table from the
1.5 km image is applied to the 1 km crop too. No-data (255) is preserved.
Years that are not remapped are symlinked into the harmonised tree, so the
tree is complete either way. Every cell-year gets a `harmonization.json`
(action, reference year, KS distance, gate values), a remapped one also its
`harmonization_luts.json`.

## What the September 2026 run found

Over the 336 cells in the export tree (335 with imagery, 992 cell-years, 326
cells with three years), the years differ far more than the reference project's gate expects:
the median KS distance between the two *consensus* years is 0.40, and between
the candidate outlier and the pair 0.72. The absolute gate (0.15) passes for
every cell; the relative gate is what decides, and it fired for 98 of the 326
cells (30 %). Most remapped years are 2015 to 2019 (60) and 2012 to 2020 (25).
After remapping, a year's KS distance to its reference drops to about 0.01 to
0.02 on every band.

The size of the raw differences means a decision, not a default, is called
for: in consensus mode 70 % of cells keep three histograms that differ by a KS
distance of 0.4 or more, while reference mode makes every year look like the
reference year, including where the difference is real. On the first cell-year
checked against its reference mask (1549-1-10-16-2, 2012, remapped to 2020;
mask tree share 0.025), the raw image scored F1 0.80 and the harmonised one
0.56, with recall falling from 0.72 to 0.40: the model was trained on raw
imagery of every year, so pushing a 2012 image towards the 2020 look moved it
away from what the model learned.

Pooled over every masked cell-year the consensus run remapped (33: 19
training, 14 validation or test scenes), with the September 2026 model
`20260924_resnet34_test34` and its stored threshold. The table comes from
`model/tools/compare_harmonized.py --run data/model/runs/20260924_resnet34_test34`,
which predicts each mask window from the raw and the harmonised GeoTIFF and
writes the per-scene scores to `harmonized_compare_thr0.20.csv` in the run
folder:

| scenes | raw F1 | harmonised F1 | raw recall | harmonised recall |
|---|---|---|---|---|
| 14 held out (validation + test) | 0.804 | 0.650 | 0.790 | 0.532 |
| 19 training | 0.906 | 0.894 | 0.915 | 0.872 |

Harmonised imagery beat raw on 2 of the 14 held-out scenes. Precision rises a
little and recall falls a lot: the remapped images look like their reference
year, and the model, trained on raw imagery of every year, under-detects trees
in them. So with the current model, harmonising before prediction is not a
gain; it would be if the model were trained on harmonised pairs as well
(01_prepare.py would read the harmonised tree), which keeps the option worth
having. The step is off by default: nothing reads the harmonised tree unless
`--harmonized` is passed.
