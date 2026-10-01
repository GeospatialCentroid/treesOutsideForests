# Model testing: where things stand (28 September 2026)

Read this first. It is the short, current account of the trees-outside-forest
model testing programme: what was built, what was learned, which recipe is
the candidate, what is unresolved, and how to pick the work up again.
`TESTING_PLAN.md` is the long version: the original plan (sections 1 to 8)
followed by a dated log of every step and result (sections 9 to 11). This
file is rewritten at each pause; the plan is only appended to.

**Status: paused on 28 September 2026 by decision, with the GPU idle and
nothing queued.** Nothing is broken. The next steps are in section 7.

---

## 1. What exists

| piece | where | state |
|---|---|---|
| Labelled data | `agroforestry_trainingValidation/lrr_F/` | 402 mask / image pairs over 134 scenes, partition `test34` (86 train / 14 validation / 34 test scenes) |
| Scene metadata | `data/model/scene_meta.csv` | one row per pair: MLRA, cover class, actual year, capture month, state, harmonise action |
| Evaluation panel | `data/reference/sampleGrids/evaluationPanel_lrr_F_09_2026.csv` | 1,100 unlabelled sample cells, 100 per MLRA (tranche 1 = 550, tranche 2 = 440, spare 110); imagery for 990 cells on disk, about 2,950 cell-years |
| Evaluation suite | `model/05_evaluate_suite.py`, `src/tofunet/suite/` | one command scores a run on pixels, area, change and slices, with bootstrap intervals; appends to `data/model/runs/registry.csv` |
| Calibration | `model/tools/calibrate_threshold.py` | area-unbiased threshold per run; the suite re-scores with it |
| Panel scoring | `model/06_predict_panel.py`, `tools/run_panel.sh` | predicts the panel, runs the real estimator on the rasters, reports self-consistency |
| Experiment runner | `tools/run_experiments.sh` + `experiments_phase*.txt` | one line per run; trains, scores, calibrates, re-scores; resumable |
| Harmonisation | `harmonize/` | consensus, reference and year modes; a `--harmonized` switch on prediction |
| Runs | `data/model/runs/` | 33 trained runs, every one scored and in the registry; probability rasters kept only for the four runs named in section 4 |
| Estimator hook | `estimates/00_run_estimates.R --cells --model-dir --years-from=rasters` | the real area estimator runs on any run's rasters |

Everything runs on `ubuntu-gpu` (ROCm venv `~/venvs/tof-rocm`, R 4.6.1
installed there too). A training run takes 20 to 45 minutes on that GPU.

## 2. How a model is judged

The deliverable is the share of land covered by trees outside forest, per
MLRA and for the LRR, per NAIP year, and its change between years. So a
model is ranked on area, not on F1:

- **Primary metric:** per-scene share error (MAE, percentage points) plus
  per-scene change error (delta MAE) on the 144 held-out scene-years, after
  calibrating the threshold on the validation scenes. Lower is better.
- **Guardrails:** pooled F1 not below 0.803 (the baseline's seed floor),
  area bias within about 5 %, false change not worse.
- **Seed spread:** every recipe that matters is trained with three seeds.
  Two standard deviations across seeds (about 0.012 on the primary metric)
  is the smallest difference the programme calls real.
- **The panel decides what the labelled set cannot:** 990 unlabelled cells
  across the LRR, predicted by every candidate, pushed through the
  estimator, and checked for self-consistency between years.

Pixel scores (F1, IoU, boundary-tolerant F1) are reported alongside to
explain *why* an area metric moved.

## 3. What was learned, in order of importance

1. **The starting model was already stable and nearly unbiased at the
   aggregate level.** Pooled F1 0.80 to 0.81 with a seed spread of 0.002;
   estimate-level bias +2 to +6 % relative, inside the sampling error of
   the labelled cells. Per-scene error is where the differences between
   recipes live, and it is dominated by the near-empty scenes: 46 of 102
   test scene-years have under 0.1 % tree cover.

2. **Calibration is not optional.** The threshold that maximises F1 lands
   anywhere between 0.05 and 0.90 across seeds because the probability map
   is nearly flat (tree rate 0.4 in the 0.10 bin, 0.6 in the 0.90 bin). An
   area-unbiased threshold fitted on the validation scenes brings every
   run's area bias to 0.98 to 1.01 at no cost in F1, and is what makes runs
   comparable. Every run is scored both ways; read the calibrated numbers.

3. **Four training changes helped, each beyond the seed spread, and they
   do not simply add.** Held-out, calibrated, primary metric (lower is
   better); the baseline `B0` is 0.319 over three seeds:

   | change | one seed | why it helps |
   |---|---|---|
   | Tversky loss (beta 0.7) instead of BCE + Dice | 0.271 | penalises false positives, which is area bias on empty scenes; the lowest false-change figure of any single arm |
   | ResNet-50 encoder instead of ResNet-34 | 0.280 | better on the 2 m boundary-tolerant score and on scene consistency; costs 20 minutes more per run |
   | blur and rescale augmentation | 0.285 | 2018-onward NAIP is 0.6 m resampled to 1 m; the model had learned sharpness as a cue |
   | the partner's 1.5 % patch rule (training windows count as tree windows only above 1.5 % trees) | 0.297 | windows with a handful of tree pixels taught the model to hedge |

   Combining everything adopted (`P3_full`, six arms, three seeds) gave
   0.297: better than the baseline, no better than the best single arm.
   Two ablations explained it: background ratio 3 hurts once the Tversky
   loss is present, and the strong radiometric jitter combined with
   blur/rescale is too much distortion. The lean combination without those
   two is the candidate (section 4).

4. **Things that did not help, and are settled:** training on target-year
   imagery only (worse; the off-target scenes are hard because of cover and
   mosaic, not because the model saw few of them), 512 px patches (worse on
   everything), focal Tversky (no gain over plain Tversky), stronger
   radiometric jitter on its own (a small gain that vanishes in
   combination), background ratio 3 (a small gain that reverses in
   combination), per-MLRA thresholds (too few cells; unstable), the summed
   probability as an area estimate (the probabilities are not calibrated),
   a full temporal median (removes real change along with false change),
   and up-weighting the 25 late-season training scenes (fails the F1
   guardrail, does not move the panel).

5. **The one unresolved problem is phenology, and it only shows on the
   panel.** In Minnesota and Montana the "2016" NAIP is really 2015, flown in
   September and October when deciduous trees are turning or bare. Every
   recipe predicts a third to a half fewer trees in those cells than in the
   same cells' July 2011 and 2019 imagery. In the aspen parkland (MLRA 56B,
   3 % of the LRR's land but a tenth of its trees) that is a 3 to 6 pp dip
   on a 15 pp level, and it moves the LRR 2016 estimate by more than its
   sampling error. The 15 labelled scenes with 2015 imagery are all on the
   plains and cannot show it. What was tried: histogram-matching the 2015
   image to the cell's own 2019 image (halves the dip for one recipe, does
   nothing for another, creates a dip elsewhere; not a production step),
   and up-weighting late-season training scenes (no effect). What is left:
   temporal pseudo-labelling, in which the model's own July prediction of a
   cell becomes the training label for that cell's September image, which
   would turn the 165 leaf-off panel cells into training data without a
   single new mask. Until something works, **a 2016 estimate for MLRAs 56B
   and 52 should not be quoted**; 2012 and 2020 are fine.

6. **Model-to-model spread will be the dominant uncertainty term in
   production.** On 545 panel cells four baseline seeds put the LRR estimate
   0.05 pp apart, 40 % of the sampling error at that size; at 1,400 cells per
   MLRA the sampling error falls to about 0.04 pp and the model term becomes
   the larger. The delivered standard error has to carry it (the analytic
   route decided in the plan, 10.1). The 2012 to 2020 change agrees across
   seeds to about 0.015 pp, which is the minimum detectable change from
   model noise alone.

## 4. The candidate recipe

`P3b_lean`: ResNet-50 encoder, Tversky loss with beta 0.7, blur and rescale
augmentation, 1.5 % patch rule, everything else as the baseline. Three
seeds, held-out scenes, calibrated:

| | F1 pooled | area bias | share MAE, pp | delta MAE, pp | primary |
|---|---|---|---|---|---|
| baseline B0 (3 seeds) | 0.805 | 0.987 | 0.150 | 0.169 | 0.319 |
| **P3b_lean (3 seeds)** | **0.812** | 1.005 | **0.136** | **0.142** | **0.278** |

It also has the shallowest 2016 dip of any three-seed recipe on the panel
(0.04 to 0.10 pp at the LRR level, against 0.09 to 0.17 for the baseline),
though still a dip. As a `02_train.py` call:

```sh
model/tools/run_guarded.sh ~/venvs/tof-rocm/bin/python model/02_train.py --run-name <name> --seed 1 \
  --set encoder=resnet50 --set loss=tversky --set tversky_beta=0.7 --set augment=blur_scale --set min_tree_fraction=0.015
```

The runs are `20260927_P3b_lean_s{1,2,3}`; with `20260926_B0_base_s1` they
are the only runs whose probability rasters were kept in the 28 September
prune. Every other run keeps its scorecard, tables, checkpoint and binary
maps, and its rasters regenerate in about a minute (suite) or six to twelve
minutes (panel) on the GPU.

One control is still missing before the choice is final: Tversky alone with
three seeds (its single seed, 0.271, is the only arm nominally better than
the candidate).

## 5. Where the numbers live

| what | file |
|---|---|
| every suite pass, one row each | `data/model/runs/registry.csv` |
| side-by-side runs and seed spread | `model/tools/compare_runs.py --runs ... --baseline ...`; `data/model/runs/compare_*.csv` |
| a run's scorecard with intervals and slices | `<run>/suite/scorecard.json`, `scorecard_slices.csv`, `t0_scenes.csv`, `t1_scenes.csv`, `t2_changes.csv` |
| a run's calibration | `<run>/suite/calibration.json`, `calibration_methods.csv` |
| a run's panel | `<run>/panel/panel_cells.csv`, `panel_changes.csv`, `panel_summary.json`, `estimates/` (tranche 1); `<run>/panel_full/` (all 990 cells, four runs) |
| the 2015 harmonisation test | `<run>/panel_h2015/compare_with_panel.csv`; `data/model/runs/harmonize_year_test.log` |
| chronological logs | `data/model/runs/experiments.log`, `panel.log`, `b0_seeds.log` |
| the reasoning behind every decision | `model/TESTING_PLAN.md`, sections 9 to 11 |

## 6. Housekeeping before continuing

- **Storage.** The work share is at 69 GB free. The 28 September prune
  deleted 184 GB of regenerable rasters, but the dataset's ZFS snapshots
  (hourly, daily and weekly, 47 of them) still reference those blocks, so
  nothing came back. Destroying the snapshots from 26 to 28 September on
  `sddPool/work` in TrueNAS, or shortening that task's retention, releases
  the space. Until then, one whole-panel pass (11 GB) is affordable, not
  much more.
- **Git.** The last commit is `7d466fb`. Uncommitted since: the year mode in
  `harmonize/`, `late_season_weight` in the trainer and config, the
  `--export-dir` / `--out-name` options on the panel predictor and runner,
  the phase 2d and 3b experiment files, the pause / resume and post-chain
  scripts, this file and the plan's sections 10.13 to 11.4.
- **Two one-off scripts were removed** (`tools/after_chain.sh`,
  `tools/after_phase3.sh`): their wait condition matched the shells that
  launched them and never fired. `tools/post_chain_20260927*.sh` are the
  working pattern for chaining steps (run them in sequence; do not wait on
  process names). Any long job on `ubuntu-gpu` is started with
  `setsid nohup <cmd> > <log> 2>&1 < /dev/null &`, because ssh sessions
  drop; `tools/pause_gpu_work.sh` / `resume_gpu_work.sh` freeze and thaw
  the whole job tree when the GPU is wanted for something else.
- **Open questions for the partner** (plan 10.4): the Nebraska
  `_toBePurged` split is unconfirmed (parked anyway); the state encoding
  was answered by the user (plan 10.4, bit table).
- **Not started, by decision:** Nebraska (no imagery, different domain),
  the LRR F photo-interpretation points as a validation set (location not
  yet found), LRR G.

## 7. How to continue

Each of these is one command or one short script, in the order they are
worth doing:

1. **Whole panel and harmonisation test for the candidate seeds** (about
   45 minutes of GPU, 33 GB):
   ```sh
   R=data/model/runs
   setsid nohup bash -c "model/tools/run_panel.sh --out-name panel_full $R/20260927_P3b_lean_s1 $R/20260927_P3b_lean_s2 $R/20260927_P3b_lean_s3; \
     model/tools/harmonize_year_test.sh $R/20260927_P3b_lean_s1 $R/20260927_P3b_lean_s2 $R/20260927_P3b_lean_s3" > $R/next1.out 2>&1 < /dev/null &
   ```
2. **Tversky alone, three seeds** (the missing control): three lines in a
   new `experiments_phase3c.txt` with `--set loss=tversky --set tversky_beta=0.7`
   and seeds 1 to 3, then `tools/run_experiments.sh` and `tools/run_panel.sh --tranche 1`.
3. **`test44` robustness on the chosen recipe.** Needs `01_prepare.py` to
   take `--partition` and `--work-dir` so the `test34` pairs are not
   overwritten, then train the candidate with `--set partition=test44` and
   the work directory pointed at the new pairs. `test44`'s test set is the
   published paper's validation set, so this is the comparison the partner
   will ask for.
4. **Temporal pseudo-labelling for the leaf-off imagery** (plan 10.14):
   predict the 165 tranche 1 cells with 2015 imagery from their 2011 and
   2019 images with the candidate, keep pixels where both agree, write those
   as masks for the 2015 image, add them to the training pairs, retrain,
   and read the parkland 2016 figure on the panel. The only untried remedy
   for section 3, item 5.
5. **Then choose**, on three seeds of each finalist: primary metric on the
   labelled set, and the panel's 2016 dip and consistency, weighted equally.
   Record the choice in the plan and set the winning keys as the defaults in
   `config.yml`, so the plain `02_train.py` call reproduces it.

Everything in this section reuses scripts that exist; the only code to
write is the two `01_prepare.py` options in step 3 and the pseudo-label
mask writer in step 4.
