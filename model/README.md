# model/

Trains the tree / no-tree U-Net on the reference masks in
`agroforestry_trainingValidation/lrr_F/` and applies it to 4-band NAIP
imagery. PyTorch with a pretrained ResNet encoder from
`segmentation_models_pytorch`; runs on the CPU, an NVIDIA GPU (CUDA) or an
AMD GPU (ROCm) from the same code, chosen by `model.device` in `config.yml`.

| Script | What it does |
|--------|--------------|
| `tools/setup_env.sh` | Builds a venv with the PyTorch stack (`requirements.txt`) for one flavour: `cpu` (default, `model/.venv`), `cu<ver>` (`model/.venv-cuda`) or `rocm<ver>` (`model/.venv-rocm`). `TOF_VENV=<dir>` relocates it, which matters for GPU wheels: they are several GB and import slowly over NFS, so put them on a local disk. The system Python has no pip, so pip is bootstrapped from get-pip.py; caches go beside the venv. |
| `00_fetch_naip.R` | Fetches the NAIP 1 km export for every `(cell, year)` a mask names, through the naip stage's own per-cell worker. Skips cells already exported. |
| `01_prepare.py` | Pairs each mask with its imagery (same year, same CRS, pixel-aligned grid), writes the aligned pairs as `.npy`, assigns train / validation / test from the configured sampling partition, computes band statistics. |
| `02_train.py` | Trains, early-stops on validation F1, picks the probability threshold on the validation split, scores the test split. One folder per run. `--seed` overrides `model.seed`; `--set key=value` overrides any other `model.*` key for one run (recorded in `config.json`). |
| `03_evaluate.py` | Re-scores a run on any split at any threshold, with a per-scene table. |
| `04_predict.py` | Tree maps (probability + binary GeoTIFF) for any 4-band NAIP scene, seamless sliding-window inference. `--harmonized` reads the `harmonize/` tree instead of the raw exports. |
| `05_evaluate_suite.py` | The evaluation suite (testing plan section 4): predicts each held-out scene once with `predict_scene`, writes `<run>/suite/predictions/` (probability raster, and `tof_<id>_<year>.tif` / `tof_truth_<id>_<year>.tif` in the estimator's 1 / 0 / 255 format with the masks-stage combined mask burned in), then scores T0 pixel (strict and boundary-tolerant), T1 area on eligible land and T2 change per cell and year pair, with bootstrap intervals and metadata slices, into `scorecard.json`, `t0_scenes.csv`, `t1_scenes.csv`, `t2_changes.csv`; appends a row to `data/model/runs/registry.csv`. Device-agnostic; existing probability rasters are reused unless `--repredict`. |
| `06_predict_panel.py` | Predicts the evaluation panel (unlabelled cells, `sampling.panel.out_csv`) with one run: `<run>/panel/predictions/` holds the probability and estimator-format rasters per cell-year, `panel_cells.csv` the predicted shares with the export's year, month and states, and `panel_summary.json` the T5 self-consistency numbers (change between target years against the run's false-change floor, and the cells the 20 % rule would flag for harmonisation). `--calibration` applies a calibration.json threshold. |
| `tools/run_panel.sh` | For each run: `06_predict_panel.py` calibrated, then the estimator on the panel rasters (`estimates/00_run_estimates.R --cells ... --model-dir ...`) into `<run>/panel/estimates/` (T3b). |
| `src/tofunet/suite/` | The suite's pieces: `rasters.py` (mask window, combined mask on the scene grid, GeoTIFF writers), `metrics.py` (counts, relaxed F1, threshold sweep), `stats.py` (scene and change statistics, bootstrap). |
| `tools/compare_harmonized.py` | Scores a run on the masked scenes the `harmonize/` step remapped, raw against harmonised, pooled for training and held-out scenes (the table in `harmonize/README.md`). |
| `tools/build_scene_meta.py` | One row per prepared pair, joined from the manifest, the partner's partition CSV, the roles CSV, the export's `status.json` and the harmonise log: split, MLRA, cover and transition class, actual year, off-target flag, capture month, states, item ids, harmoniser action. Writes `data/model/scene_meta.csv` (testing plan step 1). |
| `tools/scorecard_v0.py` | Re-slices a run's `validation_scenes.csv` and `test_scenes.csv` by the metadata table with bootstrap intervals over scenes: pooled and per-scene pixel scores, per-scene area bias, MAE and calibration, by cover class, year, state, MLRA, month and more. Writes `<run>/suite/scorecard_v0.json` and `_slices.csv` (testing plan step 2). |
| `tools/calibrate_threshold.py` | H11: bins every scene's probabilities once, then compares thresholds and calibrations (F1-optimal, area-unbiased, scaled, summed probability, isotonic, per MLRA) fitted on validation and scored on test, with T1 and T2 numbers and intervals. Writes `<run>/suite/calibration.json`, which `05_evaluate_suite.py --calibration` applies. |
| `tools/temporal_median.py` | H7c: per-pixel combination of a cell's three years after prediction (full median, median on unsure pixels, majority vote near the threshold) scored for area and change against the single-year baseline. Writes `<run>/suite/temporal_median.json`. |
| `tools/run_b0_seeds.sh` | Testing plan step 6: trains the baseline configuration with several seeds (`02_train.py --seed`), then runs the suite, the calibration and the calibrated suite on each; resumable. |
| `tools/compare_runs.py` | Runs side by side from the registry, held-out scenes: F1, area bias, share and change error at the stored and the calibrated threshold, the spread (mean, sd, range) across a group of runs, and per-MLRA area bias per run. |
| `tools/run_experiments.sh` | Phase 2 driver: one line per experiment (`<run_name>|<02_train.py arguments>`, e.g. `--seed 1 --set encoder=resnet50`), each trained, scored, calibrated and scored again like the seed runs. |
| `tools/run_guarded.sh` | Runs a command under a hard memory ceiling (user cgroup) with a memory log. |
| `tools/memwatch.sh` | The memory logger the guard uses. |

Settings live in the `model` section of the root `config.yml`. `TESTING_PLAN.md`
is the draft plan for the model testing programme: the evaluation panel, the
metric tiers built around the area and change estimates, and the experiment
ledger of remote-sensing assumptions to test.

## Running

```sh
model/tools/setup_env.sh                                   # once (CPU); see below for a GPU
Rscript model/00_fetch_naip.R                              # imagery for the mask cells (about 30 min)
model/.venv/bin/python model/01_prepare.py                 # pairs, splits, band stats (about a minute)
model/tools/run_guarded.sh model/.venv/bin/python model/02_train.py
model/.venv/bin/python model/04_predict.py --run data/model/runs/<run> --out <dir> <naip.tif ...>
model/.venv/bin/python model/05_evaluate_suite.py --run data/model/runs/<run>   # or the GPU venv's python; about a minute on the GPU
```

### On the AMD GPU (ubuntu-gpu)

The host `ubuntu-gpu` has an RDNA4 card (gfx1201, 32 GB) passed through to
the VM. Nothing beyond the in-tree `amdgpu` kernel driver is needed on the
system: the ROCm PyTorch wheels bundle the HIP runtime, and ROCm shows up
through the `torch.cuda` API, so `device: auto` picks it and `mixed_precision`
runs in bfloat16. The venv lives on the local disk because the repo is on NFS:

```sh
TOF_VENV=~/venvs/tof-rocm model/tools/setup_env.sh rocm7.2   # once; prints the GPU it sees
py=~/venvs/tof-rocm/bin/python
model/tools/run_guarded.sh $py model/02_train.py --run-name <name>
$py model/04_predict.py --run data/model/runs/<run> --out <dir> <naip.tif ...>
```

Measured on this card: about 0.10 s per training step at batch 16 (about 70 s
per epoch of 645 steps, against about 23 minutes on the 16-thread CPU host),
1.1 GB of GPU memory, and about 0.2 s per 1 km scene at inference.

If `torch.cuda.is_available()` is false although `/dev/kfd` exists and the
user is in the `render` group, `HSA_OVERRIDE_GFX_VERSION=12.0.1` is the usual
fix for a card the wheel does not list; gfx1201 should not need it. Memory
settings in `config.yml` (`threads`, `min_available_gb`, `cgroup_max_gb`) are
sized for this 12-core, 23 GB VM; the first CPU run used 16 / 12 / 40 on a
larger host.

Outputs (ignored by git) land under `data/model/`: `manifest.csv` (every mask,
its imagery, split and status), `scene_meta.csv`, `band_stats.json`, `pairs/`, `fetch_naip_report.csv`,
`memwatch_*.log`, and one folder per training run in `data/model/runs/` with
`config.json`, `history.csv`, `best.pt`, `last.pt`, `curves.png`,
`validation_scenes.csv`, `test_scenes.csv` and `results.json`.

## The data

The masks are 1 m binary rasters, `<id>_<year>_mask.tif`, one per 1 km cell
and NAIP year (0 no tree, 1 tree, 255 no data). They were digitised on this
repo's own 1 km NAIP exports and share their CRS, grid and origin exactly, so
the imagery for a mask is the naip stage export `aoi_<id>_<year>/naip_1km_<id>_<year>.tif`.
Those exports were made for the sample grid rather than the ground-truth cells,
which is why `00_fetch_naip.R` exists. A mask is only paired with imagery of
its own year: when the Planetary Computer does not serve the requested year the
worker falls back to a neighbour, and `01_prepare.py` reports such cells
instead of pairing them.

The split does not come from the `masks_train` / `masks_validation` folder
names. It follows the partner's scene partition chosen in `config.yml`
(`model.partition`, a key of `sampling.partitions`), so every year of a scene
sits in the same split and the test scenes are the ones the partner holds out.
Scenes absent from the partition are excluded. With `test34` that is 86 train,
14 validation and 34 test scenes.

## How training works, and why

- **Patches.** 256 x 256 windows. Training windows overlap by half; validation
  and test windows tile the scene. A window with any no-data pixel is dropped.
- **Balance.** Trees cover a few percent of these landscapes, so every epoch
  takes all windows holding trees plus an equal number of tree-free windows,
  redrawn each epoch so the background rotates through the whole pool. The
  reference script dropped windows with under 1.5 % trees; this one keeps
  them, because a lone shelterbelt or farmstead is exactly what a
  trees-outside-forests model has to learn.
- **Network.** U-Net with a ResNet-34 encoder initialised from ImageNet; the
  first convolution is widened to 4 bands (the RGB filters are reused and
  rescaled). The reference trained from scratch with frozen batch-norm; a
  pretrained encoder converges faster and generalises better on a few hundred
  scenes.
- **Inputs.** Bands scaled to 0-1 then standardised with the training set's
  per-band mean and standard deviation (`band_stats.json`, stored in every
  checkpoint so prediction uses the same numbers).
- **Augmentation.** Flips, quarter-turn rotations, and a per-band gain and
  offset jitter, because NAIP exposure differs between flights and years.
- **Loss and optimiser.** Half binary cross-entropy, half soft Dice, on
  logits. AdamW with a one-cycle learning-rate schedule (10 % warm-up, cosine
  decay) and gradient clipping at 1.
- **Model selection.** After every epoch the validation split is scored at
  19 thresholds from 0.05 to 0.95; the best F1 and its threshold are logged.
  Early stopping watches that F1 (`patience` epochs, after `min_epochs`), and
  the best epoch's weights and threshold are what `best.pt` holds. The test
  split is scored once, at the end, with that fixed threshold.
- **Prediction.** 512-pixel windows with half overlap, blended with a cosine
  weight, so scene-sized maps have no tile seams. All-zero pixels are no data.

## Memory on a shared machine

Another memory-hungry service runs on this host, so the stage never assumes
the RAM is free:

- the pairs are memory-mapped, not loaded, and patches are cut on demand;
- `02_train.py` checks the memory available before loading and before every
  epoch, waits while it is below `model.min_available_gb`, and stops cleanly
  if it stays there;
- `tools/run_guarded.sh` runs the process in a transient user cgroup with
  `MemoryMax = model.cgroup_max_gb` and no swap, so if it ever grew past the
  ceiling the kernel would kill the trainer alone, not the other service; it
  also logs available memory every 30 s to `data/model/memwatch_*.log` and
  flags any OOM-killer event;
- `model.threads` caps the CPU threads so the other service keeps cores.

Swap on the root disk was not an option: it has under 7 GB free, and the
data share is network storage.
