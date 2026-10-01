# Model testing plan: finding the best trees-outside-forest model for LRR F

Draft 2026-09-25, for review. Everything in section 1 is measured from the
repository as it stood that night; sections 2 to 8 are the proposal as
written then. **Sections 9 to 11 are the dated log of what was then done and
found; `STATUS.md` beside this file is the short, current summary and the
place to start.** The programme was paused on 28 September 2026 (11.4).

The question the plan answers is not "which run has the best validation F1"
but "which model gives the most trustworthy estimate of trees outside forests,
and of their change between NAIP years, per MLRA and for the LRR". Pixel scores
stay in the suite as guardrails; the ranking metric is the estimate.

---

## 1. Where we stand

### 1.1 The current model

One run exists, `20260924_resnet34_test34` (U-Net, ResNet-34 ImageNet encoder,
256 px patches, BCE + Dice, one-cycle LR, radiometric jitter, partition
`test34`, 29 epochs on the CPU host, best epoch 21, threshold 0.20).

| split | scenes | F1 | precision | recall |
|---|---|---|---|---|
| validation | 42 | 0.815 | 0.787 | 0.844 |
| test | 102 | 0.797 | 0.765 | 0.831 |

Pooled numbers hide the structure that matters for an area estimate:

- **Per-scene F1 is bimodal, driven by tree share.** Of the 102 test
  scene-years, 46 have under 0.1 % tree cover and score a mean F1 of 0.23;
  the 15 scenes with 2 to 5 % cover score 0.86. The median test scene has
  0.8 % tree cover. The test set was built to be hard: 14 of its 34 scenes are
  in the partner's `c1_<0.1%` cover class.
- **Fallback imagery years score far worse than target years.** Mean
  per-scene F1 is 0.53 to 0.58 for 2012 / 2016 / 2020 scenes and 0.22 / 0.35 /
  0.37 for 2011 / 2015 / 2019. In the export tree the fallback years are the
  majority: 598 of 947 exports are 2011, 2015 or 2019, because NAIP does not
  fly every state every target year. Whatever causes this gap (sensor, season,
  fewer training scenes in those years, or just small samples) is the single
  biggest known effect and is untested.
- **Area bias is modest but real.** Predicted tree pixels over true tree
  pixels is 1.086 pooled over the test scenes (median per-scene ratio 1.05).
  The partner's earlier model showed the same direction on its QC set
  (`gt_vs_pred.csv`: mean predicted 2.16 % versus QC 1.60 %).
- **Harmonising imagery before prediction hurts** with this raw-trained model
  (held-out F1 0.80 raw versus 0.65 harmonised, recall 0.79 to 0.53; see
  `harmonize/README.md`). Not a verdict on harmonisation, only on applying it
  at inference alone.

### 1.2 Labelled data on disk

| set | scenes | masks | years | CRS / grid | notes |
|---|---|---|---|---|---|
| LRR F train + validation (`agroforestry_trainingValidation/lrr_F/`) | 134 in the partition (136 with masks) | 402 paired | 2010 to 2020, mostly 3-year stacks | projected, 1 m, about 1038 x 1026 | `test34`: 86 / 14 / 34; `test44`: 78 / 12 / 44. Partner columns per scene: `cover_class`, `transition_class`, `CLUSTER_ID`, `state 0..7` |
| Nebraska Phase 1 (`agroforestry_trainingValidation/nebraska/`) | 82 subgrids | 101 (47 train / 10 validation / 25 test subgrids) | 2010, 2016, 2020 | EPSG:4326, about 8.98e-6 deg (about 1 m), 3227 x 3226 (2 mi) | **no NAIP on disk**, no ID shared across splits, source folder is named `_toBePurged` (confirm canonical) |
| Nebraska validation points | about 33 grids per year | point sets, presence / absence | 2010, 2016, 2020 | `validationPoints/*.gpkg`, `referenceValidation_<year>.csv` | the partner's published accuracy: 0.91 / 0.91 / 0.95, kappa 0.61 / 0.67 / 0.77 |

Nebraska tree cover in the count tables is a median of 2 to 4 % of unmasked
land, with a long tail to 48 %: denser than LRR F, but with shelterbelts,
riparian strips and farmstead clusters that look different from the glaciated
plains, and imagery from a different set of NAIP contracts. That is why it is
the hard set, and why it must stay a *test* domain until section 5 says
otherwise.

### 1.3 Unlabelled imagery and reference layers

- 336 cells exported (947 successful cell-years; 326 with three years). 82 of
  them are ground-truth cells, 45 are on the change-trend list, the rest were
  early pulls.
- The sample frame is 15,395 1 km cells in LRR F, 1,400 per MLRA over 11 MLRAs
  (52, 53A to 53C, 54, 55A to 55D, 56A, 56B).
- `data/naip/aois_showing_change_trends.csv`: 1,081 sample cells the partner
  flagged as afforestation (805) or deforestation (276) trajectories, with
  `max_cover_pct` (median 5.4 %). All 1,081 are in the sample list; only 45
  are exported.
- Every export carries `status.json` with actual year, capture dates, NAIP
  item IDs and states. Capture months (earliest in the mosaic) over the 947
  exports: June 55, July 573, August 148, September 100, October 69; 62
  mosaics span two months. States: MT 602, ND 204, SD 144, NE/MN 9 each.
- Masks stage: annual NLCD forest and Census places for LRR F 2009 to 2021,
  combined and any-year products. Nothing for Nebraska.
- Estimates stage: runs end to end on synthetic output. It expects one raster
  per cell and actual year, `tof_{id}_{year}.tif`, 1 / 0 / NA, in
  `data/tof/predictions`, and produces MLRA and LRR estimates with standard
  errors, plus Monte Carlo replicate machinery. **No model output has ever
  been pushed through it.**
- Harmonise stage: consensus-mode tree for every export; KS drift between
  years is large everywhere (median 0.40 between the two most similar years).

---

## 2. What "best" means: the estimand and the metric hierarchy

The deliverable is, for each MLRA and for the LRR, for each target year, the
share of eligible land (not NLCD forest, not a Census place) covered by trees,
and the change in that share between target years, with a standard error. The
estimator is the stratified ratio estimator in `estimates/functions/estimators.R`
over the systematic sample of 1 km cells.

A model error enters that estimate in three ways, and the suite measures each:

1. **Bias in area.** A model that finds 8 % too many tree pixels shifts every
   estimate by 8 % regardless of how good its F1 is. This is the dominant term
   and F1 does not see it.
2. **Bias that differs by stratum or by imagery year.** A bias that is
   constant cancels in a change estimate; one that differs between 2012 and
   2020 imagery (or between a Montana and a North Dakota mosaic) shows up as
   false change. The fallback-year gap in 1.1 is exactly this risk.
3. **Variance.** Scene-level noise adds to the sampling variance of the
   estimator. With 1,400 cells per MLRA it is the smallest term, but it sets
   the minimum detectable change.

So the suite ranks models on area and change metrics, and keeps pixel metrics
to explain *why* an area metric moved.

### 2.1 Metric tiers

Every run is scored on all tiers with one command (section 4) and the result
is one JSON scorecard plus per-scene tables. Tiers are numbered from the
estimand down.

| tier | what | data | key numbers |
|---|---|---|---|
| **T1 area** | per-scene TOF share, predicted versus mask, on eligible land | held-out LRR F scenes | bias (sum pred / sum true), MAE and RMSE of share in percentage points, calibration slope and intercept (pred on true), the same by cover class, by MLRA, by actual year, by target / fallback year, by capture month, by state |
| **T2 change** | per-scene change in share between the years of a 3-year stack, predicted versus mask | held-out scenes with 2 or more masked years (most of them) | bias and MAE of delta share, sign agreement, false-change rate on `transition_class = 0` scenes (predicted absolute delta above a tolerance where the masks show none), and the split of delta error into "same model, different imagery year" components |
| **T3 estimate** | the estimates stage run on the model's rasters | (a) the 134 labelled cells, model versus mask through the *same* estimator; (b) the evaluation panel (section 3), model only | (a) estimate-level bias per MLRA and LRR; (b) spread of the LRR estimate and of its change across candidate models, against the sampling standard error; minimum detectable change |
| **T4 Nebraska** | zero-shot transfer to the hardest domain | Nebraska `masks_test` (25 subgrids) and the validation-point protocol | T0 and T1 numbers on the masks; accuracy and kappa on the point sets, computed exactly as the partner did so the numbers are comparable with 0.91 to 0.95 / 0.61 to 0.77 |
| **T0 pixel** | the usual scores | held-out LRR F scenes, pooled and per scene | F1, IoU, precision, recall at the stored threshold; best-threshold F1; a boundary-tolerant F1 (1 m and 2 m buffers) so mask alignment noise is separated from real misses; per-scene distributions, not only means |
| **T5 consistency** (unlabelled) | agreement with itself across imagery | the evaluation panel | per cell: distribution of predicted delta between years against the cell's KS drift; share of cells with implausible change (above the 90th percentile of labelled deltas); agreement of predictions on the raw and harmonised version of the same scene; prediction stability under small radiometric perturbations |

### 2.2 Primary metric and guardrails

Proposed ranking rule, to be argued about in review:

- **Primary:** T1 share MAE on the held-out scenes, *after* the model's
  global calibration (section 5, H11), plus T2 delta MAE, combined as their
  sum in percentage points. Both are in the units of the deliverable.
- **Guardrails:** a candidate is not adopted if it (a) worsens T1 bias beyond
  plus or minus 5 % relative, (b) raises the false-change rate on stable
  scenes, (c) drops Nebraska kappa by more than 0.05 against the current best,
  or (d) drops pooled T0 F1 by more than 0.02.
- **Tie-break:** T3 spread; a model whose LRR estimate moves less between seeds
  wins.

Report every metric with a bootstrap interval over scenes (1,000 resamples).
With 34 test scenes, a difference in F1 of 0.02 is inside the noise; the
interval says so and stops us chasing it.

---

## 3. Data foundation

### 3.1 The evaluation panel: about 1,000 AOIs across LRR F

Purpose: a fixed, unlabelled panel on which every candidate model is run
through the estimates stage, so models are compared on the deliverable (T3)
and on self-consistency (T5). It is also the pool from which cheap extra
labels are drawn (3.3) and from which hard cells are picked for future full
masks.

Design:

- **Frame:** the tracked sample list `selectedSample_lrr_F_05_2026.csv`
  (15,395 cells), which is what the estimator will run on.
- **Draw:** a seeded random sample of about 90 cells per MLRA (990 total),
  excluding the 134 partition cells so labelled and unlabelled panels never
  mix, and excluding the change-trend cells so the panel stays representative.
  Keep the draw as a tracked CSV in `data/reference/sampleGrids/` with the
  seed in `config.yml`, the same way the grid draw is tracked.
- **Years:** the three target years with the naip stage's fallback, as for
  every other export, so the panel has the same year mix the final estimate
  will have. Expect about 60 % fallback years.
- **Retention rule:** a cell stays in the panel if all three target years
  export successfully; that keeps T2 and T5 clean. Draw about 10 % extra to
  absorb failures.
- **Imagery:** the standard 1.5 km buffered export; the 1 km core is what the
  estimator reads. About 3,000 cell-years, about 30 GB, about 4 hours at the
  rate of the mask-cell fetch.
- **Attach to every cell-year** (one table, built once, joined everywhere):
  MLRA, state, actual year, target year, fallback flag, capture month, mosaic
  spans two months, NAIP item IDs, KS drift to the cell's other years, whether
  the harmoniser remapped it, NLCD forest share and place share in the cell
  for that year, eligible area.

Also run the existing 202 non-ground-truth exports through the same
pipeline; they cost nothing, but they are not part of the panel statistics
because they were not drawn at random.

### 3.2 The change panel: the 1,081 change-trend cells

The partner's trajectory list is change-rich by construction, so it is the
right place to *look* at change behaviour and the wrong place to *estimate*
it. Export it as a second panel, tagged separately. Uses: T5 on cells where
change is expected; a source for photo-interpreted change labels (3.3); a
stress test for false-change on the deforestation trajectories where the
imagery year changes but the trees should not.

Priority below the evaluation panel; export after it.

### 3.3 Cheap labels: point-based validation on the panel

Full 1 m masks cost days per scene. The partner's Nebraska protocol (about 50
presence and 50 absence points per grid, photo-interpreted) costs under an
hour per cell and gives an unbiased accuracy per stratum. Proposal:

- 10 cells per MLRA from the evaluation panel (110 cells), one year each,
  points drawn with the same rules as the Nebraska sets so the numbers are
  comparable across regions.
- 30 cells from the change panel, two years each, with the question asked
  per point being "tree in year A / tree in year B", which gives a direct
  change-accuracy table.
- Stored as `.gpkg` + CSV under `agroforestry_trainingValidation/lrr_F/validationPoints/`,
  mirroring the Nebraska layout, and scored by the same code path as T4.

This is the only new labelling the plan asks for. It makes T4 a two-region
tier rather than a Nebraska-only one, and gives the first unbiased accuracy
per MLRA.

### 3.4 Nebraska imagery

Nothing can be run on Nebraska until its NAIP is on disk. Needs:

- A fetch that takes an arbitrary AOI polygon rather than a sample-grid id:
  the mask raster's footprint (2 mi square in EPSG:4326) for 2010 / 2016 /
  2020 with the usual fallback. The naip stage's per-cell worker already
  crops by polygon; the wrapper is what is missing (`model/00_fetch_naip.R`
  reads the grid).
- A CRS decision: export in the mask's geographic grid, or export in the
  local UTM zone at 1 m and warp the mask to it with nearest neighbour. The
  second keeps the model's pixel geometry identical to LRR F (1 m projected)
  and is the recommendation; the resampled mask is still binary.
- 82 subgrids x up to 3 years, 2 mi squares: about 250 cell-years, each 10x
  the area of an LRR F scene.
- No forest / place masks exist for Nebraska, so T4 is scored on all land
  the masks cover; the mask's own NoData (255) is the only exclusion.

### 3.5 What stays fixed

- Partition `test34` is the canonical split; `test44` is run on the final
  candidates only, as a robustness check. Neither is changed mid-plan.
- The 25 Nebraska test subgrids and the 10 validation subgrids are never
  trained on. The 47 training subgrids are held back until phase 4.
- The evaluation panel draw is made once and tracked.
- Band statistics for normalisation come from the training split of the run
  in question and are stored with it (already the case).

---

## 4. The standardised evaluation suite

One script, `model/05_evaluate_suite.py`, run once per candidate run,
producing:

```
data/model/runs/<run>/suite/
  scorecard.json           every tier, every slice, with bootstrap intervals
  t0_scenes.csv            per scene-year pixel scores (raw and boundary-tolerant)
  t1_scenes.csv            per scene-year area: true share, predicted share, eligible m2
  t2_changes.csv           per scene and year pair: true delta, predicted delta
  t3_estimates.csv         MLRA and LRR estimates from the estimates stage, labelled cells and panel
  t4_nebraska.csv          per subgrid scores and the point-protocol table
  t5_panel.csv             per panel cell-year: predicted share, delta to other years, KS drift, remap flag
  predictions/             tof_{id}_{year}.tif for every scored cell-year (the estimator's input)
```

Rules the suite enforces:

- The model's stored threshold is used everywhere unless the run declares a
  calibrated threshold (H11); both are reported.
- Masking to eligible land uses the masks stage's combined mask for the
  actual imagery year, never the target year, and the same mask for truth and
  prediction.
- Boundary tolerance is computed by dilating truth by 1 and 2 m for precision,
  and dilating prediction for recall, the standard relaxed-F1.
- Every slice with fewer than 5 scenes is reported but flagged, and never
  used in a decision.
- The suite appends one row to `data/model/runs/registry.csv`
  (run name, git commit, config hash, data hash of the pairs, encoder,
  experiment id, seed, primary metric, guardrails, wall time, host). The
  leaderboard is a view over that file; nothing is compared by hand.

Existing pieces to reuse: `03_evaluate.py` and `evaluate_split.py` (T0),
`tools/compare_harmonized.py` (the raw versus harmonised T5 check and the
scene-window logic), `estimates/00_run_estimates.R` in raster mode with
`model_source: "raster"` (T3), `tofunet/predict.py` (scene inference).

---

## 5. Remote-sensing assumptions and the experiments that test them

Each experiment states the assumption, how it is manipulated, which tier
decides, and what result would change the design. Single-factor runs first,
against a fixed baseline (`B0`, the current configuration retrained on the
GPU with three seeds so the seed spread is known before anything else).
Estimated cost is in GPU runs; a run is a full training to early stopping.

### H1 Radiometry: digital-number differences between years are nuisance, not signal

The KS drift between years is large everywhere; the model reads the same
field as different land cover in different years. Three ways to make the
model indifferent to it, which are not equivalent:

| variant | manipulation | decides | expected |
|---|---|---|---|
| H1a harmonise both sides | train on harmonised pairs (`01_prepare.py --harmonized` into a separate work dir) and predict on harmonised imagery | T1, T2 | delta MAE falls; if T1 also falls it is adopted |
| H1b per-scene standardisation | normalise each scene by its own mean / std (or by its 2nd to 98th percentile) instead of the training-set statistics | T1 by year, T2 | cheap, removes vendor stretch; may lose absolute brightness cues that separate dark conifers |
| H1c stronger radiometric augmentation | gain / bias jitter widened, per-band gamma, and a histogram-matching augmentation that remaps a training patch to a random other scene's CDF | T1 by year, T5 | the model learns invariance without changing inference; the most likely winner |
| H1d illumination-invariant inputs | NDVI, NIR / red, and normalised RGB as extra or replacement channels | T0, T1 | the partner's script has an `add_ndvi` switch; test it here rather than assume |

Cost: about 8 runs. H1a and H1c can be combined afterwards.

### H2 Phenology: capture month changes what a tree looks like

Seven percent of exports are September or October, when deciduous shelterbelts
are turning or bare; 62 mosaics span two months and can contain a seam.

- Slice T0 and T1 by capture month on B0 first; the answer may already be in
  the data.
- If the late-season slice is worse: (a) train with late-season scenes
  up-weighted, (b) train a late-season specialist and route by capture month
  at inference, (c) add capture day-of-year as a scalar input (FiLM on the
  decoder).
- Decides: T1 by month, T2 on pairs that cross seasons.
- Cost: 0 runs for the slice, 3 for the remedies.

### H3 Sensor, contractor and state mosaics are separate domains

NAIP is flown per state per contract; MT, ND and SD imagery differ in sensor
and processing, and 2011 / 2015 / 2019 are different contracts from 2012 /
2016 / 2020.

- Slice B0 by state x actual year. Then a grouped cross-validation where
  whole state-years are held out (leave-one-state-year-out over the training
  scenes) tells us whether performance on an unseen mosaic is what the
  partition reports or worse.
- Decides: T1 by state-year; the gap between grouped-CV and partition scores.
- Result that changes the design: if unseen state-years lose more than 0.1 F1,
  the panel and the final estimate depend on mosaics no training scene comes
  from, and the labelling in 3.3 should target those state-years.
- Cost: 6 to 8 short runs.

### H4 Spatial resolution and resampling

2010 to 2016 NAIP is 1 m native; 2018 onward is 0.6 m resampled to 1 m by the
export (mean of tiles). A tree crown in a 2020 scene is smoother than in a
2012 scene at the same nominal resolution.

- (a) Blur and scale augmentation (random Gaussian blur, random rescale 0.8
  to 1.25 then crop) in training. (b) Evaluate B0 on 2020 imagery degraded to
  the 2012 point-spread and see whether predictions change.
- Decides: T1 by native resolution, T2 on pairs that cross the 2018 boundary.
- Cost: 2 runs.

### H5 Sparse targets: the prior is near zero and the loss must respect it

Median scene has under 1 % trees; half the test scenes under 0.1 %. Every
false positive in an empty scene is area bias.

| variant | manipulation | decides |
|---|---|---|
| H5a loss | Tversky (beta above 0.5 to weight false positives) or focal-Tversky versus BCE + Dice | T1 bias on `c1` scenes |
| H5b patch pool | `min_tree_fraction` 0.0 versus 0.005 versus the partner's 0.015, `background_ratio` 1 versus 3 | T1 on `c1`, T0 recall on `c3` |
| H5c hard-negative mining | after epoch 5, oversample background patches the model currently scores above 0.3 | T1 bias |
| H5d two-stage | a cheap scene-level "any trees here" classifier gates the segmenter; empty scenes get zero | T1 on `c1`, false-change rate |

Cost: about 8 runs. H5d is the one most likely to move the primary metric,
because 46 of 102 test scene-years are in the regime where the segmenter
alone is worst.

### H6 Labels: mask alignment and mask year

Masks come from LiDAR-derived canopy objects with hand QC, and the batch-2
masks went through three alignment revisions. A 1 m shift is a 30 % IoU loss
on a 3 m crown.

- Report boundary-tolerant T0 next to strict T0 on B0; the gap is the
  alignment noise floor, and no experiment should claim a gain smaller than
  it.
- Train with label smoothing on boundaries (erode the mask by 1 px for the
  loss, ignore the 1 px ring) and see if T1 improves without T0 moving.
- Check the mask-year to imagery-year match on every pair: a mask digitised
  on 2016 imagery paired with a 2015 fallback export is a label error for any
  tree planted or removed in between.
- Cost: 2 runs plus one audit script.

### H7 Time as an input: the three-year stack is information

Change is the deliverable, and the model currently never sees two years at
once.

| variant | manipulation | decides |
|---|---|---|
| H7a stacked years | 8 or 12 channels (the other years of the cell concatenated); predict the mask for the target year | T2 |
| H7b Siamese change head | shared encoder, predict per-year masks and the change map jointly; loss on both | T2, false-change rate |
| H7c temporal smoothing at inference | predict each year alone, then per pixel take the median across years for "stable" pixels (a post-process, no training) | T2, T5 |

H7c is free and may already remove most spurious change; do it first.
H7a and H7b need all three years of every training cell, which the 3-year
stacks provide. Cost: 4 runs.

### H8 Context: patch size, encoder and the 1.5 km buffer

- 256 versus 512 px patches; ResNet-34 versus ResNet-50 versus a
  ConvNeXt-tiny or EfficientNet-b3 encoder; and inference on the 1.5 km
  buffered export cropped to 1 km afterwards (so the model sees context past
  the cell edge) versus inference on the 1 km core.
- Decides: T0 and T1 overall, and T1 on cells with trees along the edge.
- Cost: 5 runs.

### H9 Domain: LRR F to Nebraska, and MLRA to MLRA

- Zero-shot T4 on every candidate is automatic.
- Leave-one-MLRA-out on the training scenes (where an MLRA has enough
  scenes) tells us how much the within-region estimate depends on local
  training data.
- Phase 4 only: fine-tune the best model on the 47 Nebraska training
  subgrids; compare with training from scratch on Nebraska alone and with the
  zero-shot model. Decides: T4 on the 25 test subgrids.
- Cost: 6 runs.

### H10 Year mixing: one model or one per year

- Train on target-year scenes only (2012 / 2016 / 2020) and evaluate on
  fallback years; train on all; train one model per year group.
- Decides: T1 by target / fallback year, T2.
- Cost: 4 runs.

### H11 Threshold and calibration: the threshold that maximises F1 is not the one that gives the right area

The stored threshold (0.20) maximises validation F1. For an area estimate the
right choice is the threshold, or the probability calibration, that makes
predicted share unbiased on validation scenes, per stratum if needed.

- Compare: F1-optimal threshold; area-unbiased threshold on validation;
  isotonic calibration of probabilities followed by summing probabilities
  (a soft area estimate, no threshold at all); per-cover-class thresholds
  from the H5d gate.
- Decides: T1 bias and MAE, T3(a) estimate-level bias.
- Cost: 0 runs; a post-processing choice applied to every run, which is why
  the primary metric is scored after calibration.

### H12 Pretraining: ImageNet is not aerial imagery

- ImageNet ResNet-34 (current) versus a self-supervised encoder trained on the
  panel imagery itself (about 3,000 unlabelled scenes is enough for a
  contrastive or masked-autoencoder warm start) versus a public aerial
  pretrained backbone.
- Decides: T0 and T1 on `c1` and `c2` scenes, and Nebraska T4.
- Cost: 1 pretraining job (hours on this GPU) plus 3 runs. Later phase.

---

## 6. Run protocol

- **Baseline first.** `B0` x 3 seeds on the GPU before any experiment; the
  seed spread on the primary metric is the smallest difference the plan will
  ever call real.
- **One factor per run** in phase 2; combinations only among winners in
  phase 3, again with 3 seeds.
- **Naming:** `<date>_<experiment>_<variant>_s<seed>`, for example
  `20261002_H5a_tversky07_s1`; the experiment id links to the ledger above
  and to the registry row.
- **Config discipline:** every run stores its resolved config (already done)
  and the suite records the config hash; a run whose config hash matches an
  earlier one is refused unless the seed differs.
- **Leakage rules:** no training on anything from the test split, the
  Nebraska test and validation subgrids, or the panel; band statistics and
  thresholds come from training and validation only; the panel is scored,
  never fitted to.
- **Compute:** the CPU run took 11 hours for 29 epochs. On the ROCm GPU with
  mixed precision the same run should take well under an hour; the suite
  adds minutes for the labelled sets and about 20 to 30 minutes for the
  3,000-scene panel. Budget about 60 runs for phases 1 to 3.
- **Hosts:** training and the Python suite on `ubuntu-gpu` with
  `~/venvs/tof-rocm`; the R side (estimates, masks, harmonise, fetch) on the
  RStudio host. The suite calls the estimates stage through `Rscript`, so
  either it runs where R exists or T3 becomes a separate step. Decide before
  writing it.

---

## 7. Phases

| phase | what | done when |
|---|---|---|
| **0 Freeze** (first) | `05_evaluate_suite.py` for T0, T1, T2 and T5; registry; scorecard on the existing run; `B0` x 3 seeds on the GPU | the current model has a scorecard with intervals, and the seed spread is known |
| **1 Data** | panel draw and export (3.1); Nebraska fetch and CRS decision (3.4); metadata table per cell-year; change-panel export (3.2); T3 wired to the estimates stage; T4 on B0 | B0 has numbers on every tier, including an LRR estimate and its change with standard errors |
| **2 Single factors** | H11 (free), H7c (free), then H1, H5, H2, H3 slices, H10, H4, H6, H8 in that order | every hypothesis has a ledger entry with a measured effect and an interval |
| **3 Combine** | winners combined, 3 seeds, `test44` robustness, panel T3 spread | one candidate beats B0 on the primary metric outside the seed spread, without breaking a guardrail |
| **4 Nebraska** | H9 fine-tuning; point-label campaign scored (3.3); H12 if time | T4 at or above the partner's published accuracy and kappa, and an LRR F accuracy per MLRA from points |
| **5 Deliver** | the chosen model's rasters through the estimates stage for every panel and sample cell fetched; Monte Carlo replicates driven by the model's measured error structure instead of the placeholder parameters | MLRA and LRR TOF share and change with standard errors, with the model-error term in the uncertainty |

Phase 0 and the free items in phase 2 need nothing new pulled and can start
tomorrow. Phase 1's fetches are the long pole and should be started early and
left running.

---

## 8. Code to build, and open questions

New or changed pieces, smallest first:

1. `model/05_evaluate_suite.py` and `model/src/tofunet/suite/` (T0 relaxed
   F1, T1, T2, T5, scorecard, registry).
2. `01_prepare.py --harmonized --work-dir` (H1a) and a `--mask-year-audit`
   report (H6).
3. `02_train.py` options: loss choice, augmentation set, patch size, encoder,
   scene-standardisation flag, stacked-year input; all as config keys with the
   defaults equal to B0, so old runs stay reproducible.
4. Sampling: `sampling/04_draw_evaluation_panel.R`, seeded, tracked output.
5. Fetch: a polygon-AOI wrapper for the Nebraska subgrids; a panel fetch that
   is the mask-cell fetch pointed at a different list.
6. Estimates: a `model_source: "raster"` run on `data/tof/predictions` per
   run directory (a `--model-dir` argument on `00_run_estimates.R`).
7. Calibration: `tools/calibrate_threshold.py` (H11).
8. Nebraska point protocol scorer, shared with the LRR F point campaign.

Open questions for review:

- Is the primary metric right, or should T3(a) estimate-level bias be primary
  once it exists? It is closest to the deliverable but has only 134 cells
  behind it.
- Panel size: 90 per MLRA is a round number. 50 per MLRA would halve the
  fetch and still give T3 spread and T5; 90 gives the point campaign room.
- The Nebraska source folder is `_toBePurged`; confirm with the partner that
  it is the accepted split before any T4 number is quoted outside.
- `transition_class` and `state 0..7` in the partition file are the partner's
  change labels; their exact definition is needed before T2 uses
  `transition_class = 0` as "stable".
- Whether the harmonise consensus gate (0.15 and 2x) should be revisited for
  H1a, given that it fires on 30 % of cells and that reference mode is the
  alternative.

---

## 9. Review notes and first steps (2026-09-26)

### 9.1 What the review changed

Measured from the repository, not from the draft above:

- **T3(a) as written reaches 17 held-out cells, not 134.** The estimator
  builds its cell list from the sample CSV, and only 66 of the 134 partition
  cells are in it (49 training, 9 validation, 8 test; `siteRoles_..._test34`
  column `in_sample_list`). It also keeps only exports whose `status.json`
  `target_year` is 2012 / 2016 / 2020, and the labelled cells were fetched
  with the mask year *as* the target year (a 2011 mask cell has
  `target_year = "2011"`), so every off-target labelled scene drops out as
  well. T3(a) therefore needs two things on `00_run_estimates.R`: a
  `--cells <csv>` argument that builds the cell geometry from an id list
  (`cells_from_ids()` already exists) and a `--years-from` switch that takes
  the actual year from the raster names instead of filtering on target year.
  Item 6 in section 8 is amended accordingly.
- **"Fallback year" means two different things.** On the panel it is the
  naip stage substituting 2011 for 2012. On the labelled set it is the
  partner's mask having been drawn on 2011 imagery. The metadata table must
  carry the flag as `year not in {2012, 2016, 2020}` for labelled scenes and
  as `actual_year != target_year` for panel cells, and the suite must not
  read it from `status.json` for the labelled set.
- **The fallback-year gap rests on 6 to 8 test scenes per year** (2011: 6,
  2015: 7, 2019: 8; the training split has 5 / 7 / 8). It stays the leading
  hypothesis, but it is not "the single biggest known effect" until the
  bootstrap interval in step 2 says the gap is outside the noise. The larger
  structural fact is the imbalance itself: off-target years are 5 % of the
  training pairs and 63 % of the export tree. That is the H10 question and
  it should move up the phase-2 order, ahead of H2 and H3.
- **Guardrail (d) contradicts section 2.2.** A fixed 0.02 F1 tolerance on 34
  test scenes is inside the noise the same section warns about. Replace it
  with "pooled T0 F1 not below the B0 seed spread's lower bound".
- **The suite should be one inference pass per scene, not the patch loader.**
  Relaxed F1, per-scene area, calibration (H11), temporal median (H7c) and
  the estimator's rasters all need the whole-scene probability map.
  `tofunet.predict.predict_scene` already does this (it is what
  `compare_harmonized.py` uses). The suite predicts each held-out scene once,
  writes the probability raster, and every tier is post-processing over it.
  `evaluate_split.py` stays for the trainer's per-epoch validation only.
- **Hosts, decided:** the suite runs wherever the model runs (CPU here or
  `ubuntu-gpu`) and writes rasters to the share; T3 is a separate `Rscript`
  step on this host. 144 held-out scenes at 1 km are about an hour of CPU
  inference with `predict_scene`, so phase 0 does not wait for the GPU.
  Only the `B0` reruns and phase 2 need it.
- **Panel size:** draw 90 per MLRA as proposed but export in two tranches,
  the first 50 per MLRA, so T3 and T5 numbers exist before the second
  tranche finishes.

### 9.2 First steps, in order

Steps 1 to 3 need no new imagery, no training and no GPU. Steps 6 and 7 are
the long poles and start in parallel with step 1.

| # | step | builds | done when |
|---|---|---|---|
| 1 | **Scene metadata table.** `model/tools/build_scene_meta.py` joins, for every manifest pair: `split`, `cover_class`, `transition_class`, `CLUSTER_ID`, `tree_percentage`, `state 0..7` (partition CSV), `MLRA_ID`, `in_sample_list` (roles CSV), actual year, off-target flag, capture month, two-month mosaic, NAIP states and item ids (`status.json`), and the harmoniser's action for the cell-year. | `data/model/scene_meta.csv` | 402 rows, one per pair, no missing MLRA or cover class |
| 2 | **Scorecard v0 from what exists.** Re-slice the existing run's `validation_scenes.csv` and `test_scenes.csv` by the step-1 table with 1,000-resample bootstrap intervals: T0 pooled and per scene, and a first T1 (bias, MAE, calibration slope) from `tree_pixels` / `predicted_tree_pixels`. Not on eligible land yet, so labelled as such. | `runs/<run>/suite/scorecard_v0.json` | every claim in section 1.1 has an interval; the year, month, state and cover-class slices are either confirmed or demoted |
| 3 | **Suite skeleton.** `model/05_evaluate_suite.py` and `src/tofunet/suite/`: predict each held-out scene once with `predict_scene`, write `predictions/<key>_prob.tif` and the estimator-format `tof_{id}_{year}.tif` with the masks-stage combined mask for the actual year burned in as NA; then T0 strict and relaxed (1 m, 2 m), T1 on eligible land, T2 per year pair, `scorecard.json`, `t0/t1/t2_scenes.csv`, one row in `registry.csv`. Run on the existing run. | the section 4 layout minus T3 to T5 | the existing run has a scorecard with intervals on T0, T1 and T2 |
| 4 | **Truth through the estimator.** Write the masks as `tof_truth_{id}_{year}.tif` in the same format; add `--cells` and `--years-from` and a `--model-dir` to `00_run_estimates.R` (9.1). Run model and truth through it on the 134 partition cells. | T3(a) | per-MLRA and LRR estimate-level bias of the existing run, model versus mask, with the estimator's own standard errors |
| 5 | **Free experiments on the step-3 rasters.** H11: F1-optimal versus area-unbiased threshold on validation, per cover class, and the soft (summed-probability) estimate; H7c: per-pixel median across a cell's three years. Both are post-processing; the suite gains a `--calibration` option and records both thresholds. | `tools/calibrate_threshold.py`, H11 and H7c ledger entries | the primary metric is defined after calibration and has a number for the existing run |
| 6 | **B0 x 3 seeds.** `02_train.py --seed` (today the seed is only a config key) and run `20260927_B0_base_s{1,2,3}` on `ubuntu-gpu`; if the GPU host is not ready, one seed on this host under `run_guarded.sh` (11 hours). Score each with step 3. | seed spread on every tier | the smallest difference the plan will call real is known |
| 7 | **Panel draw and first tranche.** `sampling/04_draw_evaluation_panel.R`: seeded, 90 per MLRA plus 10 % spare, excluding the 136 mask cells and the 1,081 change-trend cells, tracked in `data/reference/sampleGrids/`. Start the export of the first 50 per MLRA with the mask-cell fetch pointed at the new list. | `evaluationPanel_lrr_F_09_2026.csv`, about 1,650 cell-years on disk | the panel exists and the first tranche has status files |
| 8 | **Two questions to the partner**, sent now because they gate T2 and T4: the definition of `transition_class` and `state 0..7`, and whether `nebraska/_toBePurged` is the accepted split. | | answers filed in this document |

Order of execution: 1, 2 and 8 on day one; 3 through the week with 6 and 7
started as soon as 1 is in; 4 and 5 once 3 produces rasters. Phase 0 is
closed when steps 1 to 6 are done.

---

## 10. Decisions and first results (2026-09-26, evening)

### 10.1 Decisions from the review conversation

- **The product is the model trained in this repo.** The research group's
  production classifier is not available; an earlier classifier may serve as a
  comparison baseline only.
- **Change is an AOI-level quantity**: total tree area in a cell in one year
  against the next. T2 stays as written (per-scene delta share). The Siamese
  change head (H7b) is dropped; H7a and H7c stay.
- **Model-error term: analytic, not Monte Carlo.** The replicate machinery in
  `estimates/` was a placeholder for a partner. The model-side uncertainty
  will come from the confusion-matrix area adjustment and its standard error
  (Olofsson et al. 2014), computed per stratum from the held-out scenes, and
  combined with the ratio estimator's sampling error. Phase 5 is amended
  accordingly; feeding the partner's carbon step directly is not a goal.
- **LRR G is out of scope.** `naip.target_region` is now `"F"`; no G imagery.
- **Nebraska is parked.** No NAIP on disk and a different domain; T4, section
  3.4 and H9's fine-tuning wait until LRR F training data proves insufficient.
  The Nebraska point-protocol scorer is still the model for the LRR F point
  campaign (3.3).
- **Harmonisation is targeted, not blanket.** All model testing runs on raw
  imagery. Afterwards, cells whose predicted TOF area differs by more than
  20 % between years (the rule in `neymanSampling/scripts/33_evaluatingHistogramNormalization.R`;
  34 to 36 apply, evaluate on model outputs and visualise) are candidates for
  harmonisation. That is a T5 filter, produced by the suite for free.
- **Deferred:** whether the delivered standard error includes the model term.
  Working assumption: yes, sampling plus the analytic model term.

### 10.2 Step 1 done: scene metadata table

`model/tools/build_scene_meta.py` writes `data/model/scene_meta.csv`: 402
rows, 134 scenes, every row with MLRA, cover class, partition type and actual
year. Ten early-pull cells (30 pairs) have no `status.json`; their actual year
is the export folder's year and their capture and item fields are empty
(`status_json = FALSE`). Counts over the 402 pairs: 49 off-target years
(2010: 5, 2011: 12, 2015: 15, 2019: 17); capture month June 43, July 185,
August 101, September 34, October 7, May 2; 28 two-month mosaics; states ND
186, SD 123, MT 33, MN 9, mixed 21; 33 pairs the harmoniser remapped.

### 10.3 Step 2 done: scorecard v0 with intervals

`model/tools/scorecard_v0.py --run data/model/runs/20260924_resnet34_test34`
writes `suite/scorecard_v0.json`, `_slices.csv` and `_scenes.csv`. Per-scene
TP / FP / FN recovered from the scene tables reproduce the pooled F1 in
`results.json` to four decimals. 1,000 bootstrap resamples over scenes, 95 %
percentile intervals. T1 here is over the pixels the patch tiling scored, not
over eligible land.

| population | scenes | F1 pooled | F1 per-scene mean | area bias (pred / true) | share MAE, pp | calibration slope |
|---|---|---|---|---|---|---|
| validation | 42 | 0.815 [0.786, 0.843] | 0.739 [0.671, 0.800] | 1.072 [1.012, 1.139] | 0.25 [0.17, 0.36] | 1.04 [0.96, 1.17] |
| test | 102 | 0.797 [0.759, 0.830] | 0.502 [0.434, 0.567] | 1.086 [1.033, 1.149] | 0.12 [0.08, 0.16] | 1.05 [0.98, 1.12] |
| held out (both) | 144 | 0.805 [0.781, 0.827] | 0.571 [0.516, 0.623] | 1.079 [1.039, 1.125] | 0.16 [0.12, 0.20] | 1.04 [0.99, 1.11] |

What the intervals do to the claims in section 1.1:

- **Area over-prediction is confirmed.** Bias 1.086 on test with an interval
  that excludes 1; the same sign in every population and in 7 of 11 MLRAs.
  MLRA 54, the largest stratum, is the worst at 1.22 [1.10, 1.35]. Calibration
  slope is 1.05, so the excess is mostly proportional, which is what a
  threshold or scale calibration (H11) can remove.
- **Cover class drives per-scene F1, confirmed.** `c3` minus `c1` per-scene
  F1 is +0.62 [+0.53, +0.70]. `c1` scenes score F1 0.21 but their share MAE is
  0.007 pp: the model is nearly right about area on empty scenes even when F1
  says it is wrong, because both truth and prediction are almost zero.
- **The fallback-year gap is confirmed on F1 and not shown on area.**
  Target minus off-target per-scene F1 is +0.21 [+0.06, +0.37] on test, but
  the area-bias difference is +0.10 [-0.04, +0.27] and covers zero. Off-target
  scenes are also the emptier ones (12 of 23 are `c1`, median true share
  0.006 % against 0.37 %), so part of the F1 gap is cover, not year; within
  each cover class off-target still scores lower (0.12 v 0.25, 0.38 v 0.66,
  0.75 v 0.85) on 5 to 12 scenes each. Demoted from "the single biggest known
  effect" to "real on F1, unresolved on area"; H10 stays early in phase 2.
- **Capture month and state show nothing decidable.** July (47 scenes) has the
  lowest mean F1 (0.43) but its interval overlaps June and August; October has
  2 scenes; Montana (18 scenes) is low on F1 (0.29) with area bias 1.11, and
  Montana scenes are mostly `c1`. H2 and H3 stay as slices to re-check on B0
  with more seeds rather than as remedies to build now.
- **A first look at change**, on the 34 test cells with two or more scored
  years, first to last year: delta MAE 0.095 pp, delta bias +0.02 pp. Only 3
  cells have a true change above 0.05 pp, so the test set is effectively a
  stable-scene set for T2; on those stable cells the 90th percentile of the
  predicted absolute delta is 0.24 pp. That is the current false-change noise
  floor and the number H7c and H11 have to beat.

### 10.4 Step 8: the two questions for the partner (draft)

1. In `34_test_set_partition.csv`, what do `transition_class` (values 0 and
   1) and `state 0` to `state 7` encode? We read `transition_class = 0` as
   "no tree-cover change across the scene's years" and want to use it to
   measure false change; and are the `state` columns pixel counts of a
   transition typology, and if so which states are gain, loss and stable?

   **Answered by the user, 2026-09-26.** The change-over-time raster codes a
   tree in 2012 as 1, in 2016 as 3 and in 2020 as 5 and sums the three
   years, so a pixel takes one of eight values: 0 (never), 1 (2012 only),
   3 (2016 only), 4 (2012 and 2016), 5 (2020 only), 6 (2012 and 2020),
   8 (2016 and 2020) or 9 (all three years). The `state 0` to `state 7`
   columns are those eight values in ascending order, as pixel counts per
   scene; they sum to the scene's pixel count. `tree_percentage` is closest
   to the mean of years tree share (max difference 0.005 pp on `test44`; the
   any-year share differs by up to 1.9714 pp), so it is a per-year
   figure, not the union. So:

   | column | code | years with a tree | reading | share of all pixels |
   |---|---|---|---|---|
   | state 0 | 0 | none | stable, no tree | 97.61 % |
   | state 1 | 1 | 2012 | lost by 2016 | 0.043 % |
   | state 2 | 3 | 2016 | present in the middle year only (noise) | 0.003 % |
   | state 3 | 4 | 2012, 2016 | lost by 2020 | 0.017 % |
   | state 4 | 5 | 2020 | gained after 2016 | 0.103 % |
   | state 5 | 6 | 2012, 2020 | absent in the middle year only (noise) | 0.003 % |
   | state 6 | 8 | 2016, 2020 | gained by 2016 | 0.053 % |
   | state 7 | 9 | all three | stable tree | 2.169 % |

   The two implausible combinations (states 2 and 5) are 0.006 % of pixels
   together, which is the label-noise floor of the masks in change terms.
   Gains (states 4 and 6) outnumber losses (1 and 3) by 2.6 to 1 on the
   labelled cells. `transition_class` is exact: 0 where a scene has no
   pixel at all in the four change states (53 scenes), 1 where it has any
   (81 scenes, median 0.09 % of pixels); T2's stable-scene set
   (`transition_class = 0`) stands and is strict. Nothing in the suite
   reads the raw codes, so no code changes.
2. The Nebraska Phase 1 train / validation / test masks were copied from
   `phase1_nebraska/shahriar/_toBePurged/final_training_data/`. Is that the
   accepted final split, or does a later version exist? (Parked for now, but
   the answer is cheap to get while the data is still on the share.)

### 10.5 Step 3 done: the suite, run on the GPU

`model/05_evaluate_suite.py` (with `src/tofunet/suite/`) predicts each held-out
scene once, writes `suite/predictions/<key>_prob.tif`, `tof_<id>_<year>.tif`
and `tof_truth_<id>_<year>.tif` (1 / 0 / 255; the combined mask for the mask
year is burned in as 255 on both, because that pair is the estimator's input
and the estimator wants trees outside forest), scores T0, T1 and T2, and
appends to `data/model/runs/registry.csv`. It is device-agnostic and reuses
probability rasters that already exist. On `ubuntu-gpu` (ROCm venv
`~/venvs/tof-rocm`; this session runs on that host) the 144 held-out scenes
predicted in 44 s, about 0.2 s per scene; the bootstrap brought the run to
about 140 s. A CPU scene takes about 2.8 s.

**Scoring decision (user, 2026-09-26): the model is a model of every tree.**
The forest / place mask is an administrative step for the carbon accounting
and is applied downstream by the estimator; nothing in training or scoring
should limit the model to trees outside the mask. So T1 and T2 are scored
over all valid pixels, with the eligible-land versions kept alongside as
`*_elig`. On these scenes the two hardly differ: the mask touches 45 of 144
scenes and at most 1.2 % of a scene, although about one labelled tree pixel
in ten falls inside it (`truth_in_combined_px`), which is what the estimator
removes and the model should not.

| population | scenes | F1 pooled | F1 relaxed 1 m, scene mean | area bias | soft area bias | share MAE, pp | calibration slope |
|---|---|---|---|---|---|---|---|
| validation | 42 | 0.821 [0.789, 0.851] | 0.791 [0.708, 0.855] | 1.042 [0.985, 1.109] | 0.980 [0.928, 1.040] | 0.24 [0.16, 0.35] | 1.05 [0.96, 1.17] |
| test | 102 | 0.795 [0.755, 0.827] | 0.569 [0.498, 0.631] | 1.031 [0.985, 1.084] | 0.964 [0.920, 1.012] | 0.11 [0.08, 0.15] | 1.00 [0.95, 1.07] |
| held out | 144 | 0.807 [0.783, 0.829] | 0.633 [0.577, 0.688] | 1.036 [0.998, 1.076] | 0.972 [0.936, 1.008] | 0.15 [0.11, 0.19] | 1.03 [0.98, 1.09] |

| population | year pairs | cells | delta MAE, pp | delta bias, pp | stable pairs | false change p90, pp |
|---|---|---|---|---|---|---|
| test | 102 | 34 | 0.123 [0.067, 0.184] | 0.001 [-0.044, 0.052] | 96 | 0.31 [0.18, 0.63] |
| held out | 144 | 48 | 0.160 [0.106, 0.224] | 0.023 [-0.024, 0.071] | 127 | 0.39 [0.23, 0.68] |

What changed against the step 2 scorecard:

- **The area over-prediction is demoted.** Whole-scene inference over every
  valid pixel gives a test bias of 1.031 with an interval that covers 1, not
  the 1.086 of step 2. The step 2 number came from the trainer's patch
  tiling, which scored 3 % more pixels yet 8 % fewer true tree pixels than
  the whole scene (windows dropped and edges handled differently), so it
  overstated the excess. Per-scene F1 agrees between the two (correlation
  0.987). The summed-probability estimate runs the other way, 0.96 to 0.98,
  so a soft area estimate would under-count; H11 has both sides to work
  with. Section 10.3's first bullet is superseded by this one.
- **The boundary-tolerance floor is 0.05 to 0.09 F1.** Test per-scene mean F1
  is 0.50 strict, 0.57 at 1 m and 0.61 at 2 m; on the `c3` scenes 0.82, 0.87
  and 0.91. No experiment should claim a gain inside that gap on strict F1
  without showing it on the relaxed score too.
- **Change.** 96 of the 102 test year pairs have a true change under 0.05 pp,
  so the test set measures false change, not change detection. The 90th
  percentile of predicted absolute change on stable pairs is 0.31 pp on
  test, with a wide interval [0.18, 0.63] because a few cells carry it. That
  is the number for H7c and H11 to beat. The fallback-year and cover-class
  F1 gaps reproduce (section 10.3); the area-bias gaps still cover zero.
- **Thresholds per scene.** The median best-F1 threshold and the median
  area-unbiased threshold on the validation scenes are both 0.10, against
  the run's stored 0.20, which was chosen on pooled validation F1. Step 5
  starts from `t1_scenes.csv` (`area_unbiased_threshold` per scene) and the
  probability rasters.

### 10.6 Step 4 done: truth and model through the estimator (T3a)

`estimates/00_run_estimates.R` takes `--cells`, `--model-dir`, `--pattern`,
`--years-from=rasters`, `--eligible-from` and `--out`, so a run's rasters can
be pushed through the real estimator on any cell list. With
`--years-from=rasters` each raster year is assigned to the nearest naip target
year (2010 and 2011 to 2012, 2015 to 2016, 2019 to 2020), which is how the
production run will treat fallback imagery; stratum areas come from the
target year's cached tables. `estimates/tools/compare_model_truth.R` lays the
model's estimates beside the truth's. Both were run with `--eligible-from=model`
so model and truth share exactly the pixels the suite left unmasked. R 4.6.1
now runs on `ubuntu-gpu`, so nothing left the host. Outputs are in
`suite/t3/` (four estimator runs) and `suite/t3_estimates_{partition,heldout}.csv`.

LRR F, total-land denominator, percent of land that is tree:

| cells | target year | truth | model | difference, pp | ratio | truth sampling SE, pp |
|---|---|---|---|---|---|---|
| 134 partition | 2012 | 1.73 | 1.76 | +0.03 | 1.02 | 0.55 |
| 134 partition | 2016 | 1.63 | 1.70 | +0.07 | 1.04 | 0.53 |
| 134 partition | 2020 | 1.63 | 1.70 | +0.07 | 1.04 | 0.55 |
| 48 held out | 2012 | 0.92 | 0.92 | 0.00 | 1.00 | NA (one MLRA has 1 cell) |
| 48 held out | 2016 | 0.87 | 0.92 | +0.06 | 1.06 | NA |
| 48 held out | 2020 | 0.86 | 0.89 | +0.03 | 1.04 | NA |

- **Estimate-level bias is +2 to +6 % relative, and inside the sampling
  error everywhere.** None of the 33 MLRA-year estimates on the partition
  cells, and none of the 30 on the held-out cells, differ from the truth by
  more than two truth standard errors. That is the expected outcome at these
  sample sizes (3 to 27 cells per MLRA against 1,400 in production): the
  sampling SE of the truth itself is 0.5 pp on 134 cells, ten times the model
  bias. The bias is what will matter at 1,400 cells per MLRA, where the
  sampling SE falls to about 0.04 pp; the T1 area bias of 1.03 to 1.04 is
  the number to calibrate away (H11), not something the estimator hides.
- **The largest stratum carries the largest bias.** MLRA 54 (Rolling Soft
  Shale Plain, 21 % of the LRR) runs 1.12, 1.16 and 1.03 on the partition
  cells and 1.10, 1.23 and 1.02 held out; the 2016 held-out figure is on 12
  cells. MLRA 55A and 55D also run high; 52, 53B and 55C run at or below 1.
  H11 should be tried per stratum as well as globally.
- **Change is understated.** Truth falls by 0.10 pp from 2012 to 2020 on the
  partition cells and 0.065 pp held out; the model shows 0.06 and 0.03. The
  model's 2012 estimate is closest to truth (ratio 1.00 to 1.02) and its
  2016 the furthest (1.04 to 1.06), so the year-to-year bias is not constant
  and a change estimate would inherit about 0.03 pp of false trend. That is
  the H10 question in estimate units.
- **A note on 56B.** Its three partition cells give 17 % tree cover with a
  truth SE of 16 pp: one aspen-parkland cell dominates. The synthetic
  generator assumed 0.5 to 5 % everywhere; the real distribution has a much
  longer tail in the north-east, and the LRR SE on the held-out set is NA
  because that MLRA has a single held-out cell. The evaluation panel (step 7)
  is what fixes both.

### 10.7 Step 5 done: H11 calibration and H7c temporal median

Both are post-processing over the step 3 probability rasters; no inference.
`model/tools/calibrate_threshold.py` bins every scene's probabilities once
(`suite/calibration_hist.npz`) and scores every method from the histograms;
`model/tools/temporal_median.py` combines a cell's three years pixel by pixel.
All trees on all valid pixels; fits on the 42 validation scenes, scores on the
102 test scenes and the 144 held-out scenes.

**H11, ledger entry.** Held-out scenes, 1,000-resample intervals:

| method | fitted on validation | area bias | share MAE, pp | delta MAE, pp | primary (sum), pp |
|---|---|---|---|---|---|
| stored threshold 0.20 | trainer's pooled-F1 choice | 1.036 [1.000, 1.074] | 0.147 | 0.160 | 0.307 |
| F1-best threshold | 0.13 | 1.065 [1.027, 1.111] | 0.156 | 0.162 | 0.317 |
| area-unbiased threshold | 0.37 | 0.993 [0.961, 1.035] | 0.143 | 0.157 | 0.300 |
| scaled (0.20, area x 0.960) | scale 0.960 | 0.995 [0.959, 1.033] | 0.146 | 0.155 | 0.302 |
| per-MLRA thresholds | 0.03 to 0.67, train + validation | 0.995 [0.960, 1.035] | 0.147 | 0.158 | 0.305 |
| soft (summed probability) | none | 0.972 [0.936, 1.012] | 0.144 | 0.155 | 0.299 |
| soft, scaled x 1.021 | scale 1.021 | 0.992 [0.956, 1.029] | 0.141 | 0.158 | 0.299 |
| soft, isotonic bins | 100-bin PAV | 1.038 [1.000, 1.089] | 0.192 | 0.148 | 0.340 |

- **The 3 to 4 % over-prediction is removable at no cost.** An area-unbiased
  threshold of 0.37, or the stored threshold with predicted area scaled by
  0.96, brings held-out bias to 0.99 with the interval centred on 1, while
  pooled F1 stays at 0.79 to 0.81 and share MAE does not move. Fitted on
  validation, it holds on test (0.986 and 0.990).
- **Calibration does not move the primary metric.** Every sensible method
  lands at 0.30 pp of share MAE plus delta MAE; the spread across methods is
  0.008 pp against intervals ten times wider. Per-scene error is not a
  threshold problem; it is where the scene-level experiments (H1, H5, H10)
  have to earn their keep.
- **The probabilities are not calibrated.** On validation pixels, the
  empirical tree rate is 0.40 in the 0.10 to 0.11 probability bin and only
  0.61 in the 0.90 to 0.91 bin: a nearly flat reliability curve. That is why
  the F1-optimal threshold is so low (0.13), why the isotonic sum is the
  worst method, and why "summed probability" is not a free area estimate.
  A calibration-aware loss or a post-hoc temperature is a phase 2 candidate.
- **Per-MLRA thresholds are not supported by the data.** They swing from
  0.03 (MLRA 52) to 0.67 (55A, 56A) when fitted on train + validation, and
  give MLRA 52 a test bias of 1.56. Too few cells per stratum; a global
  threshold or scale is the choice until the panel exists.
- **Recommendation:** threshold 0.37 (`suite/calibration.json`,
  `recommended`). `05_evaluate_suite.py --calibration <json>` applies it and
  records the calibration and scale in the scorecard and registry, so every
  future run is scored both at its stored threshold and calibrated.

**H7c, ledger entry.** 48 held-out cells, 144 year pairs, 17 with a true
change above 0.05 pp:

| variant | area bias | share MAE, pp | F1 pooled | false change p90, pp | mean false change, pp | delta MAE on moving pairs, pp |
|---|---|---|---|---|---|---|
| single year (baseline) | 1.036 | 0.147 | 0.807 | 0.39 [0.25, 0.69] | 0.150 | 0.237 |
| median of all pixels | 1.013 | 0.153 | 0.826 | 0.00 | 0.000 | 0.505 |
| median where unsure (0.05 to 0.60) | 1.030 | 0.139 | 0.818 | 0.31 [0.17, 0.52] | 0.119 | 0.234 |
| majority vote within 0.15 of threshold | 1.047 | 0.145 | 0.816 | 0.34 [0.18, 0.58] | 0.127 | 0.228 |

- **A full median is a ceiling, not a method.** It zeroes false change by
  construction and doubles the error on the 17 pairs with real change
  (0.51 pp), because it removes that too.
- **The median on unsure pixels is a free gain.** Mean false change falls by
  a fifth (0.150 to 0.119 pp), pooled F1 rises 0.011, share MAE falls, and
  the error on real-change pairs is unchanged (0.234 against 0.237) with sign
  agreement kept at 16 of 17. The intervals overlap, so on 48 cells this is
  a direction, not a proof; it costs nothing and should be carried as an
  option into the panel (T5), where 1,000 cells will decide it.
- **Vote** helps false change a little less and worsens bias; dropped.

### 10.8 Step 6 done: B0 x 3 seeds on the GPU. Phase 0 is closed.

`model/tools/run_b0_seeds.sh` trained `20260926_B0_base_s{1,2,3}` (`02_train.py
--seed`), each 23 to 30 minutes on the GPU (25 to 30 epochs, 55 s per epoch),
and scored each with the suite, its own calibration and the calibrated suite.
`model/tools/compare_runs.py` reads the registry and gives the spread.
Held-out scenes (144), stored threshold:

| run | seed | best epoch | stored threshold | F1 pooled | area bias | share MAE, pp | delta MAE, pp | false change p90, pp |
|---|---|---|---|---|---|---|---|---|
| 20260924 (CPU) | 2026 | 21 | 0.20 | 0.807 | 1.036 | 0.147 | 0.160 | 0.39 |
| B0 s1 | 1 | 17 | 0.65 | 0.807 | 1.029 | 0.156 | 0.175 | 0.36 |
| B0 s2 | 2 | 17 | 0.05 | 0.805 | 1.017 | 0.147 | 0.175 | 0.50 |
| B0 s3 | 3 | 22 | 0.45 | 0.806 | 1.004 | 0.148 | 0.158 | 0.36 |

**The seed spread (2 sd over the three GPU seeds), the smallest difference the
plan will call real from now on:**

| metric | mean | 2 sd (stored) | 2 sd (calibrated) |
|---|---|---|---|
| F1 pooled | 0.806 | 0.002 | 0.001 |
| F1 relaxed 1 m, scene mean | 0.615 | 0.017 | 0.026 |
| area bias | 1.017 (0.987 calibrated) | 0.025 | 0.016 |
| share MAE, pp | 0.150 | 0.011 | 0.007 |
| delta MAE, pp | 0.169 | 0.020 | 0.016 |
| false change p90, pp | 0.41 | 0.16 | 0.15 |

- **The model is remarkably stable on the aggregate metrics.** Pooled F1
  moves by 0.002 across seeds, share MAE by 0.01 pp. Guardrail (d) in 2.2 is
  therefore "pooled F1 not below 0.803" (the B0 lower bound).
- **The F1-optimal threshold is not stable at all: 0.05, 0.45, 0.65 and 0.20
  across four seeds.** This is the flat reliability curve of 10.7 in another
  form: with the tree rate near 0.4 to 0.6 across most of the probability
  range, pooled F1 barely changes with the threshold and the argmax lands
  anywhere. Consequences: (i) a run's stored threshold is not a property of
  the model worth reporting; (ii) calibration (H11) is not optional, it is
  what makes runs comparable; after it, area bias sits at 0.98 to 1.00 for
  every seed; (iii) a calibration-aware objective moves up the phase 2 list.
- **False change is the noisiest metric** (2 sd of 0.16 pp on a mean of
  0.41) because a handful of cells carry the 90th percentile; the panel's
  1,000 cells will tighten it. Seed 2's 0.50 comes with its threshold of
  0.05, which lets background wobble through.
- **Per-MLRA bias is consistent across seeds** where there are enough cells
  (54 at 1.03 +/- 0.04, 55A to 56A within 0.02 to 0.06) and unstable where
  there are not (52: 0.6 to 1.1 on 4 cells).
- The GPU seeds reproduce the CPU run's numbers, so the earlier run stands
  as a fourth B0 point, not a different model.

### 10.9 Step 7 started: the evaluation panel

`sampling/04_draw_evaluation_panel.R` (settings `sampling$panel`, seed 909)
drew 1,100 cells from the 14,277 sampled cells that are neither labelled (66
in the sample list) nor on the change-trend list (1,081; 44 are both): 100
per MLRA, of which 50 are tranche 1, 40 tranche 2 and 10 spare. Tracked as
`data/reference/sampleGrids/evaluationPanel_lrr_F_09_2026.csv`.
`naip/src/fetch_cells.R --cells=<that csv> --tranche=1` started the export of
the 550 tranche 1 cells for 2012, 2016 and 2020 (about 1,650 cell-years) on
the evening of 26 September; log in `data/naip/fetch_panel_t1.log`, report in
`data/naip/fetch_report_evaluationPanel_lrr_F_09_2026_t1.csv`. Tranche 1
finished in 83 minutes with no failures (1,635 cell-years); tranche 2 (440
cells) followed and finished the same evening with 1,298 of 1,299 cell-years
(one crop failure on a boundary cell). The whole panel, 990 cells and about
2,950 cell-years, is on disk; the export tree is now 3,931 folders and 47 GB.

### 10.10 Phase 2, started overnight: single-factor runs against B0

`02_train.py --set key=value` overrides any `model.*` key for one run and
records it in `config.json`; `train_years` (H10) is a new key. Experiments
that need only config keys run first, one seed each, through
`model/tools/run_experiments.sh` (train, suite on all splits, calibrate,
calibrated suite), and are judged against the seed spread above.

Queue 2a (`model/experiments_phase2a.txt`): H10 target-year-only training,
H5b minimum tree fraction 0.015, H5b background ratio 3, H8 ResNet-50, H8
512 px patches. Queue 2b (`model/experiments_phase2b.txt`), chained after 2a:
H5a Tversky (beta 0.7) and focal Tversky, H1c strong radiometric augmentation
(gain 0.7 to 1.3, bias +/- 0.12, per-band gamma 0.7 to 1.4), H4 blur and
rescale augmentation. New config keys `loss`, `tversky_beta`, `focal_gamma`,
`augment` default to B0. Still to code: histogram-matching augmentation, NDVI
channels (H1d), stacked years (H7a), a calibration-aware loss, and a
scene-standardisation flag (H1b).

### 10.11 Phase 2 ledger

One seed (1) per experiment against `20260926_B0_base_s1` and the seed spread
of 10.8 (2 sd: F1 0.002, area bias 0.025, share MAE 0.011 pp, delta MAE
0.020 pp, false change 0.16 pp). Held-out scenes, stored threshold unless
marked; primary = share MAE + delta MAE in pp (B0 s1: 0.331). Verdicts:
**adopt to phase 3** (3 seeds, combinations), **neutral**, **reject**.

| id | run | change | F1 pooled | area bias | share MAE, pp | delta MAE, pp | false change p90, pp | primary | verdict |
|---|---|---|---|---|---|---|---|---|---|
| B0 | 20260926_B0_base_s1 | baseline | 0.807 | 1.029 | 0.156 | 0.175 | 0.36 | 0.331 | |
| H10 | 20260926_H10_target_only_s1 | train on 2012 / 2016 / 2020 scenes only (235 of 258 pairs) | 0.798 | 1.006 | 0.164 | 0.186 | 0.35 | 0.350 | **reject** |
| H5b | 20260926_H5b_min015_s1 | training windows count as tree windows only above 1.5 % trees (the partner's rule) | 0.806 | 1.032 | 0.147 | 0.150 | 0.33 | 0.297 | **adopt** |
| H5b | 20260926_H5b_bg3_s1 | three background windows per tree window each epoch instead of one | 0.807 | 1.051 | 0.153 | 0.150 | 0.37 | 0.303 | **adopt** |
| H8 | 20260926_H8_resnet50_s1 | ResNet-50 encoder (32.5 M parameters against 24.4 M) | 0.809 | 1.016 | 0.137 | 0.146 | 0.31 | 0.283 | **adopt** |
| H8 | 20260926_H8_patch512_s1 | 512 px patches, strides 256 / 512 | 0.790 | 1.008 | 0.193 | 0.235 | 0.67 | 0.428 | **reject** |
| H5a | 20260926_H5a_tversky07_s1 | half BCE, half Tversky with beta 0.7 instead of Dice | 0.805 | 1.033 | 0.141 | 0.134 | 0.28 | 0.275 | **adopt** |
| H5a | 20260926_H5a_focaltversky_s1 | focal Tversky, beta 0.7, gamma 1.33 | 0.804 | 1.014 | 0.149 | 0.157 | 0.36 | 0.306 | **neutral** |
| H1c | 20260926_H1c_strongaug_s1 | wide gain and bias jitter plus per-band gamma | 0.807 | 1.001 | 0.148 | 0.150 | 0.32 | 0.298 | **adopt** |
| H4 | 20260926_H4_blurscale_s1 | 3x3 blur and 0.8 to 1.25 rescale on half the patches | 0.811 | 1.001 | 0.137 | 0.148 | 0.31 | 0.285 | **adopt** |

- **H10.** Removing the 23 off-target training pairs costs 0.009 pooled F1
  (four times the seed spread) and worsens share and change error, while the
  off-target test scenes score no worse (per-scene F1 0.34 against 0.28,
  calibrated). So the fallback-year gap is not caused by the model having
  seen few off-target years; it is a property of those scenes (cover and
  mosaic), and the imbalance in the export tree is not a training problem.
  H10's other arms (one model per year group) are dropped.
- **H5b, 1.5 % rule.** Same pooled F1, share MAE down 0.009 pp (at the
  spread), delta MAE down 0.025 pp (beyond it), false change down 0.04 pp
  (inside the noise). The `c1` (under 0.1 %) test scenes are where it acts:
  area bias there 0.75 against 0.47. Windows with a handful of tree pixels
  were teaching the model to hedge. Carried to phase 3.
- **H5b, background ratio 3.** Same pooled F1 and recall, delta MAE down
  0.025 pp (beyond the spread), share MAE down 0.003 (inside it), `c1` area
  bias 0.75 against 0.47, but the uncalibrated area bias rises to 1.05
  (calibration removes it: 0.987). More background per epoch teaches the
  same lesson as the 1.5 % rule by a different route; the two are natural
  partners for a phase 3 combination and should not both be credited.
- **H8, ResNet-50.** The clearest single gain so far: pooled F1 +0.002 (at
  the spread), share MAE down 0.019 pp and delta MAE down 0.029 pp (both
  beyond it), false change down 0.05 pp, `c3` per-scene F1 up 0.006 and the
  2 m relaxed F1 up 0.027. Costs 45 minutes against 25 on the GPU and 33 %
  more parameters; inference stays under a second per scene. Carried to
  phase 3 as the encoder for the combination runs.
- **H8, 512 px patches.** Worse on everything: F1 down 0.017, share MAE up
  0.037 pp, delta MAE up 0.06 pp, false change doubled. With 512 px windows
  the epoch has a quarter of the steps and the tree / background balance
  shifts (a window with any tree is a "tree window", so nearly every window
  qualifies), so the model sees far less background per epoch. Larger
  context is not the constraint; dropped, and the 1.5 km buffered-inference
  arm of H8 stays open as a cheap post-process test instead.
- **H5a, Tversky beta 0.7.** Pooled F1 down 0.002 (at the spread), share
  MAE down 0.015 pp and delta MAE down 0.041 pp (both well beyond it), false
  change p90 down 0.08 pp to 0.28, the lowest of any run so far. Precision
  and recall barely move, so the gain is in scene-level consistency, not in
  the pixel score. Best primary metric so far (0.275). Carried to phase 3.
- **H5a, focal Tversky.** Share MAE down 0.007 and delta MAE down 0.018, both
  inside or at the spread, false change unchanged. The focal exponent gives
  back most of what plain Tversky gained; not carried.
- **H1c, strong radiometric augmentation.** Delta MAE down 0.025 pp (beyond
  the spread), share MAE down 0.008 (at it), and the uncalibrated area bias
  is 1.00: the model stops keying on absolute brightness, which is what the
  hypothesis said. Off-target scenes gain little (per-scene F1 0.29 against
  0.28), so radiometry is not what makes the 2015 imagery hard. Carried.
- **H4, blur and rescale.** The best pooled F1 of any run (0.811, +0.004,
  twice the spread), share MAE down 0.019 and delta MAE down 0.027 pp (both
  beyond), uncalibrated bias 1.00, and the first arm to move the off-target
  scenes: per-scene F1 0.34 against 0.28, share MAE 0.108 against 0.131, and
  area bias on 2015 imagery 0.98 against 0.80. That is the resolution and
  sharpness story of H4 confirmed: the fallback-year imagery differs in
  point-spread as much as in season, and a model that has seen blurred and
  rescaled crowns reads it correctly. Carried, and the first candidate to
  test against the panel's 2016 dip.

### 10.12 First panel results (T3b, T5): tranche 1, four B0 runs

Tranche 1 exported cleanly: 1,635 cell-years for 550 cells, no failures,
1,145 with the requested year and 490 fallback (30 %, not the 60 % assumed
in 3.1; 2010 / 2011 for 68 / 97 cells, 2015 for 160, 2019 for 165). Every
cell has all three target years. `model/tools/run_panel.sh --tranche 1`
predicted the panel with each run's calibrated threshold (about 6 minutes per
run on the GPU) and ran the estimator on the rasters.

LRR F, percent of all land, 545 panel cells, sampling SE about 0.13 pp:

| run | 2012 | 2016 | 2020 |
|---|---|---|---|
| 20260924 (CPU baseline) | 1.25 | 1.07 | 1.25 |
| B0 s1 | 1.27 | 1.14 | 1.29 |

**The 2016 dip is an imagery-year effect in one stratum, and it is exactly
what T5 exists to catch.** Broken down:

- Cells whose "2016" imagery is really 2015 (160 cells) predict 2.1 pp less
  tree cover in 2016 than the mean of their own 2012 and 2020; cells with
  true 2016 imagery (385) show no dip at all (+0.02 pp).
- The 2015 imagery is Minnesota and Montana, captured in September and
  October (158 of 160 cells); the true 2016 imagery is June to September.
  Minnesota is MLRA 56B, the aspen parklands, which predicts 10.5 % in 2012
  and 2020 and 5.1 % in 2016; Montana (MLRA 52) drops from 0.39 to 0.22 %.
  North and South Dakota, flown in their target years, are flat to 0.05 pp.
- 56B is 3 % of the LRR's land but a tenth of its trees, so its halving
  moves the LRR estimate by 0.17 pp, more than the sampling SE.
- On the labelled scenes the same signature is faint (2015 mask scenes: true
  0.45 %, predicted 0.36 %), because only 15 labelled pairs are 2015 and
  most are on the plains; the panel has 160 and they include the parklands.

So the fallback-year question (H10, rejected as a training-mix problem) comes
back as a phenology and sensor question (H2, H3): late-season 2015 imagery
of deciduous parkland reads as far fewer trees to a model trained mostly on
mid-summer scenes. This is a false change of about 50 % in the stratum that
matters most for change, and it is the first concrete target for targeted
harmonisation (the 20 % rule flags 89 to 99 of 545 panel cells, 16 to 18 %,
most of them these) or for a late-season training arm (H2b/c). Until one of
those lands, a 2016 estimate for 56B and 52 should not be quoted.

Other T5 numbers, baseline run: median absolute change between target years
0.05 pp, 90th percentile 0.78 pp; 18 % of year pairs exceed the labelled
false-change floor (0.38 pp), 14 % among pairs with target-year imagery on
both sides and 29 % where either side is a fallback year.

**T3(b), all four B0 runs on the panel** (LRR F, percent of all land, 545
cells, sampling SE 0.13 to 0.15 pp):

| run | 2012 | 2016 | 2020 | 2012 to 2020 change, pp |
|---|---|---|---|---|
| 20260924 (CPU) | 1.25 | 1.07 | 1.25 | +0.005 |
| B0 s1 | 1.27 | 1.14 | 1.29 | +0.016 |
| B0 s2 | 1.36 | 1.22 | 1.35 | -0.003 |
| B0 s3 | 1.35 | 1.26 | 1.34 | -0.013 |
| sd across runs | 0.055 | 0.083 | 0.046 | 0.013 |

- The model-to-model spread of the LRR estimate (0.05 pp in the target
  years) is 40 % of the sampling SE on 545 cells. At 1,400 cells per MLRA
  the sampling SE falls to about 0.04 pp and the model spread becomes the
  larger term, so the delivered uncertainty must carry it (this is the V1
  term the estimates stage's open point asks for, measured rather than
  assumed), and calibration alone does not remove it: all four runs are
  calibrated here, and they still sit 0.1 pp apart.
- The 2012 to 2020 change agrees across runs to +/- 0.015 pp: that is the
  minimum detectable change from model noise alone, before any real change
  and before the 2016 problem. The 2016 dip is in every run (0.08 to 0.17 pp).

**Panel, six runs** (tranche 1, calibrated thresholds; LRR percent of all
land and MLRA 56B percent; share of year pairs whose predicted change exceeds
the run's labelled false-change floor; cells the 20 % rule flags):

| run | LRR 2012 | 2016 | 2020 | 56B 2012 | 2016 | 2020 | pairs above floor | fallback pairs | target pairs | 20 % rule |
|---|---|---|---|---|---|---|---|---|---|---|
| 20260924 (CPU) | 1.25 | 1.07 | 1.25 | 10.5 | 5.1 | 10.4 | 18 % | 29 % | 14 % | 16 % |
| B0 s1 | 1.27 | 1.14 | 1.29 | 11.7 | 6.9 | 12.0 | 20 % | 30 % | 16 % | 18 % |
| B0 s2 | 1.36 | 1.22 | 1.35 | 11.9 | 8.2 | 12.8 | 17 % | 28 % | 12 % | 16 % |
| B0 s3 | 1.35 | 1.26 | 1.34 | 13.4 | 11.0 | 13.2 | 21 % | 30 % | 17 % | 19 % |
| H5b 1.5 % rule s1 | 1.27 | 1.06 | 1.24 | 10.5 | 5.4 | 11.0 | 21 % | 31 % | 17 % | 19 % |
| H5b background 3 s1 | 1.32 | 1.18 | 1.27 | 12.7 | 8.7 | 12.4 | 19 % | 29 % | 15 % | 17 % |

- **The 2016 parkland figure is where the seeds disagree most**: 5.1 to
  11.0 % for the same cells and the same imagery, against 10.5 to 13.4 % in
  2012. Late-season 2015 imagery is out of distribution for every run, and
  each run extrapolates differently. That variance is invisible on the
  labelled set (15 pairs of 2015 imagery, all on the plains) and is the
  single strongest reason the panel exists.
- **The H5b gains on the labelled set do not show up as panel consistency.**
  Both adopted arms cut labelled change error by 0.025 pp, but their share of
  panel pairs above the false-change floor (19 to 21 %) is no better than
  the baselines (17 to 21 %), and their 2016 dip is as deep. The labelled
  test set is nearly all stable plains cells; panel consistency is a
  different, harder target, and T5 should weigh at least as much as T2 when
  phase 3 picks a model.
- **Fallback-year pairs exceed the floor about twice as often as target-year
  pairs in every run** (28 to 31 % against 12 to 17 %). The estimator's
  nearest-target-year rule is fine for area; for change, pairs that mix a
  fallback year with a target year should be flagged or excluded.

### 10.13 Restart after a dropped session, and the phase 3 queue (2026-09-26, 23:00)

The phase 2c queue (`experiments_phase2c.txt`) and the tranche 1 panel
prediction for `20260926_H4_blurscale_s1`, both started at 22:12 from an ssh
session, died with that session at about 22:17 (`H5b_min015_s2` at epoch 7,
the panel at 1,643 of 3,270 rasters). Both were relaunched at 22:59 under
`setsid nohup`, so they no longer belong to any terminal:

- `data/model/runs/chain_2c_3.out`: phase 2c, then phase 3
  (`model/experiments_phase3.txt`, written now that every single-factor arm
  is scored): `P3_full` = ResNet-50 + Tversky 0.7 + `strong_blur_scale` +
  1.5 % rule + background ratio 3, seeds 1 to 3; ablations on seed 1 without
  ResNet-50, without background ratio 3, and the two augmentation arms
  alone on the B0 recipe. About 8 hours of GPU in total.
- `data/model/runs/panel_adopted.out`: tranche 1 panel (T3b, T5) for the four
  adopted arms that had none yet: H4 blur/scale (resumed), H8 ResNet-50, H5a
  Tversky, H1c strong augmentation.

Storage at the restart: the work share has 219 GB free; the export tree is
47 GB (3,931 cell-years, whole panel included) and `data/model/runs` 58 GB,
about 1.4 GB per run for the suite's probability rasters and 5.7 GB per run
for a tranche 1 panel. Phases 2c and 3 plus the four panels add about 40 GB.
Nothing has been pruned; the rejected runs' panel and suite rasters
(`H8_patch512`, `H10_target_only`) are the first candidates when that is
needed.

Anything launched from a terminal on `ubuntu-gpu` must be started with
`setsid nohup ... < /dev/null &`; the two runner scripts skip finished runs
and reuse rasters, so a rerun after an interruption resumes rather than
repeats.

### 10.14 Queued behind the chain (2026-09-26, 23:30)

Three more pieces run unattended tonight, all detached:

- **Targeted harmonisation of the 2015 imagery** (the remedy the 20 % rule
  points at in 10.12). `harmonize/0_run.R` gained `--mode=year --years=2015`:
  only the named imagery year is remapped, to the cell's most recent other
  year, with no KS gate. It ran on the 165 tranche 1 cells that carry 2015
  imagery (MLRA 53A 50, 56B 50, 52 45, 56A 18, 53B 1, 54 1; their stacks are
  2010 or 2011, 2015, 2019, so the reference is the 2019 image) into
  `data/naip/harmonized_y2015`. `06_predict_panel.py --export-dir --out-name`
  then re-predicts those cells for `H4_blurscale_s1` and `B0_base_s1` from
  the harmonised tree into `<run>/panel_h2015/`, and
  `tools/compare_panel_variants.py` sets the 2016 dip (2016 share minus the
  mean of 2012 and 2020) raw against harmonised, per MLRA. Driver:
  `tools/harmonize_year_test.sh`; log `runs/harmonize_year_test.log`.
  Decision rule: if the parkland (56B) 2016 share recovers to within the
  seed spread of its 2012 / 2020 mean without the other MLRAs moving,
  targeted harmonisation of fallback-year imagery becomes a production
  step and the late-season training arm (H2) is deferred; if not, H2 runs.
- **`tools/after_chain.sh`** waits for the phase 2c / 3 chain and the panel
  runs, then writes `compare_P3_full.csv` and `compare_P3_ablations.csv`
  through `compare_runs.py` and predicts the **whole panel** (both
  tranches, 990 cells) for the three `P3_full` seeds and `B0_base_s1` into
  `<run>/panel_full/` (`run_panel.sh --out-name`), leaving the tranche 1
  results untouched. About 10 GB per run.
- The tranche 1 panel for the four adopted single-factor arms
  (`panel_adopted.out`, 10.13).

**Result of the 2015 harmonisation test (23:30).** 165 cells remapped
(2015 to each cell's 2019 image), 330 years linked. Mean predicted tree
share (pp) on the 160 cells with all three target years, raw against
harmonised, same model and threshold:

| model | MLRA | cells | 2012 | 2016 raw | 2016 harmonised | 2020 | dip raw | dip harmonised |
|---|---|---|---|---|---|---|---|---|
| H4 blur/scale s1 | all | 160 | 5.29 | 3.45 | 4.41 | 5.83 | -2.11 | -1.15 |
| H4 blur/scale s1 | 56B parkland | 50 | 13.94 | 8.39 | 11.32 | 15.50 | -6.34 | -3.40 |
| H4 blur/scale s1 | 53A | 50 | 0.68 | 0.38 | 0.64 | 0.71 | -0.32 | -0.05 |
| H4 blur/scale s1 | 52 | 40 | 0.12 | 0.04 | 0.15 | 0.10 | -0.07 | +0.04 |
| H4 blur/scale s1 | 56A | 18 | 6.11 | 6.26 | 5.58 | 6.55 | -0.07 | -0.75 |
| B0 s1 | all | 160 | 5.53 | 3.69 | 3.69 | 5.64 | -1.90 | -1.90 |
| B0 s1 | 56B parkland | 50 | 14.78 | 9.10 | 9.44 | 15.01 | -5.79 | -5.46 |
| B0 s1 | 56A | 18 | 6.13 | 6.31 | 5.18 | 6.14 | +0.17 | -0.96 |

- **The decision rule says H2 runs.** For the blur/scale model, harmonising
  halves the parkland dip (-6.3 to -3.4 pp, still a quarter of the level)
  and removes it in 53A and 52; for the B0 model it does nothing (56B 9.1
  to 9.4). In both models it *creates* a dip in 56A (-0.75 and -0.96 pp),
  and the count of cells more than 20 % below their own 2012 / 2020 mean
  rises (47 to 59, and 48 to 76). Histogram matching moves the 2015 image
  toward a July look, but the trees in it are still leaf-off, and what the
  model does with that depends on the recipe. Not a production step on its
  own; a partial remedy for a robust model at best.
- **Why: the 2015 imagery is all September and October** (capture months
  of the 165 cells: 2015 is 9 or 10 for 159; the 2011 and 2019 images are
  June to August for nearly all). This is phenology, not sensor stretch.
  The labelled set has 25 September / October training pairs of 258, 5
  validation, 11 test.
- **H2 as queued** (`model/experiments_phase2d.txt`, after phase 3,
  through `tools/after_phase3.sh`): `late_season_weight` (new `model.*`
  key; patches from scenes captured in `late_season_months` [9, 10] are
  counted that many times in the epoch pool) at 3 and 6 on the B0 recipe,
  and at 3 on the phase 3 recipe. Each gets the suite, the tranche 1 panel
  and the 2015-harmonisation test, so the parkland 2016 share is read with
  and without harmonisation. Judged on the panel dip first, the labelled
  metrics second.
- **If up-weighting is not enough** (25 scenes may simply be too few
  leaf-off examples), the next arm is temporal pseudo-labelling on the
  panel: the model's own July-imagery prediction of a cell, where its two
  other years agree, becomes the label for that cell's September image.
  That turns the 165 unlabelled late-season cells into training data
  without a single new mask, and is the H7/H12 territory the plan already
  allows. Not started.

Storage after the test: the harmonised 2015 tree is 1.2 GB; the share has
204 GB free with phase 3 and the whole-panel runs still to land.

## 11. Phase 3 results and what runs next (2026-09-27)

### 11.1 The chain finished; the waiter did not

Phase 2c and phase 3 trained and scored overnight without error (11 runs,
last one done at 05:56). `tools/after_chain.sh` and `tools/after_phase3.sh`
never fired: their `pgrep -f` pattern matched the shells that had launched
the jobs, whose command lines quote the runner names, so they waited all day.
Both were killed at 15:50 and replaced by `tools/post_chain_20260927.sh`
(whole panel for the `P3_full` seeds and B0 s1, then phase 2d, then its
panels and harmonisation test) and `tools/post_chain_20260927b.sh` (phase 3b
after it; its wait is anchored to a command line that *starts* with the
runner's name). Rule for any future waiter: anchor the pattern with `^` or
wait on a PID file, never on a substring.

### 11.2 Phase 3: the combination is no better than its best parts

Held-out scenes, calibrated threshold, primary = share MAE + delta MAE in pp.
`P3_full` = ResNet-50 + Tversky 0.7 + `strong_blur_scale` + 1.5 % rule +
background ratio 3. Seed spread of `P3_full` (2 sd, calibrated): F1 0.006,
area bias 0.006, share MAE 0.012, delta MAE 0.011, false change 0.037.

| run | seeds | F1 pooled | area bias | share MAE, pp | delta MAE, pp | false change p90, pp | primary |
|---|---|---|---|---|---|---|---|
| B0 s1 | 1 | 0.804 | 0.980 | 0.154 | 0.172 | 0.35 | 0.326 |
| P3_full | 3 (mean) | 0.809 | 0.989 | 0.146 | 0.151 | 0.30 | 0.297 |
| P3_no_bg3 (full minus background 3) | 1 | **0.814** | 1.020 | **0.133** | 0.143 | 0.32 | **0.276** |
| P3_no_r50 (full minus ResNet-50) | 1 | 0.808 | 0.994 | 0.147 | 0.156 | 0.32 | 0.303 |
| P3_aug_both (both augmentations on B0) | 1 | 0.806 | 0.984 | 0.154 | 0.167 | 0.40 | 0.321 |
| P3_min015_bg3 (the two H5b arms) | 3 (mean) | 0.798 | 0.989 | 0.150 | 0.152 | 0.37 | 0.302 |
| H5a Tversky alone | 1 | 0.803 | 0.988 | 0.139 | **0.132** | **0.27** | **0.271** |
| H8 ResNet-50 alone | 1 | 0.807 | 0.977 | 0.137 | 0.143 | 0.31 | 0.280 |
| H4 blur/scale alone | 1 | 0.811 | 1.001 | 0.137 | 0.148 | 0.31 | 0.285 |

- **`P3_full` beats B0** on every metric, beyond the B0 seed spread on delta
  MAE (0.021 better) and false change (0.05), at the spread on share MAE. It
  is the first three-seed result that does, and its own seed spread is
  tight (share MAE sd 0.006). But it does **not** beat Tversky alone,
  ResNet-50 alone or blur/scale alone (primary 0.271 to 0.285 against
  0.297). The arms do not add.
- **Background ratio 3 hurts in combination.** Removing it (`P3_no_bg3`)
  gives the best pooled F1 of any run (0.814) and the best share MAE
  (0.133), beyond `P3_full`'s spread on both; only its uncalibrated bias is
  worse (1.02, and the recommended calibration is the stored threshold). The
  1.5 % rule and background 3 were both adopted from one seed each and were
  flagged in 10.11 as teaching the same lesson; together with the Tversky
  loss, which already penalises false positives, the extra background is too
  much.
- **The two augmentations together are no gain** on the B0 recipe (0.321
  against 0.326), although each alone was (0.298, 0.285). Strong radiometric
  jitter and blur/rescale on the same patch is more distortion than the
  model benefits from. `P3_full` and `P3_no_bg3` both carry
  `strong_blur_scale`; the lean recipe with `blur_scale` alone is untested.
- **ResNet-50 earns its 45 minutes**: dropping it costs 0.027 on the primary
  metric, beyond the spread.
- **Stored thresholds saturate at 0.90 for every Tversky run** (the trainer's
  grid ends there): the Tversky term pushes probabilities toward 1. The
  calibrated pass is the one to read, as 10.8 already said.

**Phase 3b queued** (`experiments_phase3b.txt`, after phase 2d): two more
seeds of `P3_no_bg3`, and `P3b_lean` = ResNet-50 + Tversky 0.7 + `blur_scale`
+ 1.5 % rule, three seeds. Each then gets the tranche 1 panel. The
candidate is whichever of the two beats Tversky-alone's 0.271 with three
seeds; if neither does, Tversky alone with ResNet-50 is the fallback
(`P3_no_bg3` minus the augmentation, not yet run).

### 11.3 Tranche 1 panel across ten runs: the parkland dip is everywhere

Mean predicted tree share over the 545 tranche 1 cells (pp of the cell), the
parkland (56B) share, its 2016 dip against the cell's own 2012 / 2020 mean,
and self-consistency **at one fixed floor of 0.3 pp** (the per-run floor the
summary uses is the run's own false-change p90, which makes the summary's
percentages incomparable across runs; T5 should report a fixed floor too):

| run | LRR 2012 / 2016 / 2020 | 56B 2012 / 2016 / 2020 | 56B dip | pairs above 0.3 pp | target-only | fallback | mean 2012 to 2016 delta | 2012 to 2020 |
|---|---|---|---|---|---|---|---|---|
| CPU baseline | 2.61 / 2.00 / 2.60 | 13.5 / 7.1 / 13.3 | -6.3 | 21.3 % | 17.0 | 31.1 | -0.61 | -0.01 |
| B0 s1 | 2.71 / 2.20 / 2.75 | 14.8 / 9.1 / 15.0 | -5.8 | 22.2 % | 18.2 | 31.3 | -0.52 | +0.04 |
| B0 s2 | 2.82 / 2.37 / 2.87 | 14.9 / 10.4 / 15.9 | -5.0 | 23.4 % | 19.7 | 31.9 | -0.45 | +0.05 |
| B0 s3 | 2.93 / 2.59 / 2.90 | 16.7 / 13.5 / 16.3 | -3.0 | 22.4 % | 18.5 | 31.3 | -0.34 | -0.02 |
| H1c strong aug | 2.69 / 2.37 / 2.76 | 14.4 / 11.2 / 14.9 | -3.5 | 21.2 % | 17.4 | 30.1 | -0.33 | +0.06 |
| H4 blur/scale | 2.69 / 2.12 / 2.81 | 13.9 / 8.4 / 15.5 | -6.3 | 21.1 % | 17.3 | 29.9 | -0.57 | +0.12 |
| H5a Tversky | 2.74 / 2.39 / 2.83 | 15.1 / 11.5 / 15.7 | -4.0 | 22.4 % | 18.2 | 32.3 | -0.35 | +0.08 |
| H5b background 3 | 2.83 / 2.37 / 2.78 | 15.8 / 11.0 / 15.5 | -4.7 | 21.3 % | 17.0 | 31.1 | -0.47 | -0.05 |
| H5b 1.5 % rule | 2.63 / 2.01 / 2.64 | 13.4 / 7.5 / 14.0 | -6.2 | 21.4 % | 17.3 | 30.9 | -0.61 | +0.01 |
| H8 ResNet-50 | 2.74 / 2.49 / 2.83 | 15.4 / 12.6 / 16.0 | -3.1 | 22.5 % | 18.7 | 31.3 | -0.25 | +0.09 |

- **No recipe removes the dip**; it runs from -3.0 pp (B0 s3, ResNet-50) to
  -6.3 (CPU baseline, blur/scale, 1.5 % rule) on a 14 to 16 pp level. The
  seed-to-seed range inside B0 (-3.0 to -5.8) is as wide as the range across
  recipes, so a single-seed panel dip is not a recipe property.
- **The labelled set and the panel disagree about H4.** Blur/scale was the
  arm that most improved the labelled 2015 scenes (10.11), and it has the
  deepest panel dip. The 15 labelled 2015 pairs are plains cells; the panel's
  2015 cells are parkland and Montana. The labelled set cannot judge the
  leaf-off problem; the panel can, and 11.2's candidate choice should weigh
  the panel dip of the three-seed runs (coming with phase 3b) as much as the
  labelled primary metric.
- **Consistency at a fixed floor is flat across recipes**: 21 to 23 % of
  year pairs move more than 0.3 pp, 17 to 20 % of target-year pairs, 30 to
  32 % of pairs with a fallback year. Every recipe inherits the same
  imagery problem; this is what H2 (phase 2d, queued) and, failing that,
  temporal pseudo-labelling are for.
- **The 2012 to 2020 change is within +/- 0.12 pp of zero for every run**, so
  the target-year estimate is stable in the mean; the 2016 figure is the
  one that cannot be quoted yet.

Storage at 16:00: work share 176 GB free, `data/model/runs` 98 GB over 31
runs (about 1.4 GB suite plus 5.7 GB tranche 1 panel each). The whole-panel
passes add about 10 GB per run for four runs; phases 2d and 3b about 8 runs
more. Expect about 100 GB free by tomorrow; pruning the rejected runs'
rasters (`H8_patch512`, `H10_target_only`, the CPU baseline's panel) would
recover about 20 GB when wanted.

### 11.4 Phases 2d and 3b done: the lean recipe is the candidate (2026-09-28)

Every queue finished at 07:07 on 28 September (the workflow was frozen for
six hours on the evening of the 27th with `tools/pause_gpu_work.sh` while the
GPU served a language model, and resumed without loss). Held-out scenes,
calibrated threshold, three seeds each unless marked; primary = share MAE +
delta MAE in pp.

| recipe | seeds | F1 pooled | area bias | share MAE, pp | delta MAE, pp | false change p90, pp | primary |
|---|---|---|---|---|---|---|---|
| B0 | 3 | 0.805 | 0.987 | 0.150 | 0.169 | 0.41 | 0.319 |
| P3_full (all six arms) | 3 | 0.809 | 0.989 | 0.146 | 0.151 | 0.30 | 0.297 |
| P3_no_bg3 (full minus background 3) | 3 | 0.810 | 0.998 | 0.143 | 0.153 | 0.30 | 0.296 |
| **P3b_lean** (ResNet-50 + Tversky 0.7 + `blur_scale` + 1.5 % rule) | 3 | **0.812** | 1.005 | **0.136** | **0.142** | 0.32 | **0.278** |
| H2a late-season weight 3 (B0 recipe) | 1 | 0.797 | 0.999 | 0.155 | 0.141 | 0.38 | 0.296 |
| H2a late-season weight 6 (B0 recipe) | 1 | 0.797 | 0.985 | 0.171 | 0.162 | 0.50 | 0.333 |
| H2a weight 3 on P3_full | 1 | 0.800 | 0.976 | 0.167 | 0.181 | 0.40 | 0.348 |

- **`P3b_lean` is the candidate.** It beats `P3_full` by 0.019 on the
  primary metric with three seeds on each side, against a seed spread of
  about 0.012, and has the best pooled F1 of any three-seed recipe. The
  single-seed `P3_no_bg3` result of 11.2 (0.276) was a good seed: its
  three-seed mean is 0.296, the same as `P3_full`. Dropping the strong
  radiometric jitter and keeping blur / rescale is what the two extra
  seeds confirmed. Tversky alone (0.271, one seed) has not been given three
  seeds and remains the only single-arm result that is nominally better;
  worth three seeds before the choice is final, but it lacks the encoder
  and augmentation that carry the panel numbers below.
- **Late-season up-weighting fails the guardrail.** Both weights drop
  pooled F1 to 0.797, below the B0 lower bound of 0.803, and weight 6 is
  worse on everything. Weight 3 does cut delta MAE (0.141), but on the
  panel its parkland dip (-3.0 pp) is inside the B0 seed range (-3.0 to
  -5.8), and applying the 2015 harmonisation on top changes nothing
  (-3.0 to -3.0). Twenty-five leaf-off scenes counted three or six times
  is not more leaf-off information. H2a is **rejected**; the temporal
  pseudo-labelling arm of 10.14 is the next thing to try for the
  phenology problem, and the only untried one.
- **The lean recipe also has the smallest panel dip of any three-seed
  recipe.** Tranche 1 estimator, LRR percent of all land, 2012 / 2016 /
  2020: `P3b_lean` 1.25 / 1.21 / 1.28, 1.27 / 1.25 / 1.30 and 1.23 / 1.14 /
  1.25 (2016 dip 0.04 to 0.10 pp); B0 seeds 0.09 to 0.17 pp; `P3_no_bg3`
  0.10 to 0.15 pp. Not zero, and inside the seed spread, but consistently
  the shallowest.
- **The whole panel (978 cells with exports) lowers the LRR level.**
  `P3_full` seeds and B0 s1 on all 978 cells: 2012 1.05 to 1.13 %, 2016
  0.98 to 1.07 %, 2020 1.14 to 1.19 % of all land, sampling SE 0.085 to
  0.095 pp, against 1.25 to 1.35 % on tranche 1 alone. Tranche 2 drew
  emptier cells; the tranche 1 figures in 10.12 and 11.3 are for comparing
  recipes, not for quoting a level. The 2012 to 2020 change on the whole
  panel is +0.03 to +0.10 pp in every run, about one sampling SE.

**Next, in order:** (1) whole panel and the 2015 harmonisation test for the
three `P3b_lean` seeds; (2) Tversky-alone with three seeds, as the
control the choice still lacks; (3) `test44` robustness on the chosen
recipe, which needs `01_prepare.py` to take a partition and work directory
so the `test34` pairs are not overwritten; (4) temporal pseudo-labelling for
the leaf-off imagery. Storage: about 75 GB free on the share after phase 3b;
pruning is now due before (1) adds 33 GB.
