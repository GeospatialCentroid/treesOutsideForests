# Agroforestry — training & validation mask datasets

Pulled 2026-09-22 from
`smb://acns.colostate.edu/wcnr-network/Research/Ogle/Agroforestry`
(locally mounted at `/Volumes/wcnr-network/Research/Ogle/Agroforestry`).

**Scope rules applied:** binary single-band masks only. No 4-band NAIP imagery was
copied — every `*_naip.tif`, `*_QC.tif`, `buffered_*.tif`, `*rendered.tif` and
`_blank.tif` was excluded by filter, and the result was audited by band count.

Total on disk: **1.5 GB**, 821 GeoTIFFs.

---

## nebraska/  — Phase 1 (Nebraska statewide)

Source: `phase1_nebraska/shahriar/_toBePurged/final_training_data/{train,validation,test}/`

| folder | files | unique subgrids | size |
|---|---|---|---|
| `masks_train/` | 66 | 47 | 663 MB |
| `masks_validation/` | 10 | 10 | 101 MB |
| `masks_test/` | 25 | 25 | 252 MB |

- Naming: `subgrid_<id>_<year>_mask.tif`, years 2010 / 2016 / 2020.
- Raster spec: 1-band Byte, values `{0,1}`, NoData `255`, ~3279 x 3232 px,
  **geographic CRS** (pixel size 8.98e-06 deg ≈ 1 m).
- No subgrid ID is shared across train / validation / test (verified).

Also included:
- `validationPoints/` — reference (ground-truth) validation point sets per year,
  `.gpkg` + `referenceValidation_<year>.csv` + all-years summary.
  From `phase1_nebraska/data/processed/validationPoints/`.
- `validationCounts/` — `counts<year>.csv` confusion/tally tables.
- `phase1_NB_QAQC_inventory.xlsx` — QA/QC inventory (from `phase1_nebraska/Deidre/`).

> Caveat: the source lives under a directory named `_toBePurged`. It is still the
> only complete Nebraska train/validation/test split on the share, but confirm with
> Shahriar that it is the accepted final version before treating it as canonical.

## lrr_F/  — Phase 2 (Land Resource Region F, 3-year stacks)

Source: `phase2_sampling/data/LRRF3yr/{training_all,validation_all}/`

| folder | files | unique grids | size |
|---|---|---|---|
| `masks_train/` | 210 | 70 | 230 MB |
| `masks_validation/` | 198 | 66 | 216 MB |

- Naming: `<gridId>_<year>_mask.tif`. Train years cluster on 2012/2016/2020
  (68 each, plus a few 2010/2015/2019 substitutions); validation is more mixed
  (2011 and 2015/2019 substitutions where a NAIP year was unavailable).
- Raster spec: 1-band Byte, values `{0,1}`, NoData `255`, ~1038 x 1026 px,
  **projected CRS, 1 m pixels**.
- No grid ID shared between train and validation (verified).

`unetqueue_binary_masks/` — the upstream hand-digitized QC masks these were
derived from, source `phase2_sampling/UNetQueue_20260528/`:
- `Training/` — 80 `*_binary_mask.tif`
- `Validation/` — 60 `*_binary_mask.tif`
- `TrainingBatch2/` — 172 rasters; this batch uses different naming:
  `*_binary.tif` plus successive alignment revisions `*_binary_aligned.tif`,
  `_alignedV2`, `_alignedV3`. **Use `_alignedV3` where present** (latest).
  Note the aligned variants encode trees as `1` with NoData `0`, whereas
  `_binary.tif` and the `_mask.tif` products use `{0,1}` with NoData `255`.

`metadata/`
- `tif_grid_metadata_QC.xlsx` — per-tif grid metadata / QC
- `UniqueGridIDsvalAndSetup.xlsx` — grid IDs and the train/val split setup
- `naipcheck_3yrNAIPS.xlsx` — NAIP year availability per grid
- `qc_check_20260528.xlsx` — QC pass for the UNetQueue batch
- `gt_vs_pred.csv` — ground-truth vs predicted comparison

## scripts/

`monteCarlo/`
- `MonteCarlo_test_v03.R` — from `phase1_nebraska/Monte Carlo approach/` (2025-10-24)
- `MonteCarlo_test_v03_shahriarCopy.R` — copy from `phase1_nebraska/shahriar/`;
  differs from the above by **one comment line only**, kept for provenance.
- `MonteCarlo_w_ageClass.py` — age-class MC variant (2025-10-16). The two copies
  on the share are byte-identical.
- `2010_stats.csv`, `2016_stats.csv`, `2020_stats.csv` — the only inputs the R
  script reads (`read_stats()`).
- `final_population_tables/` — `age_population.csv`, `age_population_shuffled.csv`,
  `growth_rate_population.csv`, `plant_harvest_year_4_COT_states.csv`.
- `MonteCarlo_workflow_diagram_V10.pptx` — latest workflow diagram (V5/V9 also exist).

`modelTraining/`
- `09.train_test_unet_for_hpc_V2_1.py` — U-Net train/test driver for HPC
- `06.predict_and_stich_for_hpc_folder.py` — inference + tile stitching
- `merge_and_split_naip.py` — how NAIP/mask pairs were tiled and split

`maskAndDataPrep/`
- `createCOTandMask.py`, `make_COT_from_yearly_files.py` — COT + mask construction
- `mask_lidar_points_by_COTs.py`, `mask_lidar_points_by_COTs_LRR-F.py`
- `cot_area_extraction.R` — COT area extraction
- `downloadNAIP.py`, `download_NAIP_MPC_single.py` — NAIP acquisition (Planetary Computer)

---

## Deliberately NOT copied

- **All 4-band NAIP** (`*_naip.tif`, `*_QC.tif`, `buffered_*.tif`) — per instruction.
- `phase2_sampling/data/LRRF3yr/validation_all - Copy/` — 195 masks, a strict
  subset of `validation_all` (198). Redundant.
- `phase2_sampling/data/LRRF_masks/*.gpkg` — ~1.9 GB of **vector** NLCD-derived
  forest/urban exclusion masks (`llr_F_forest_<year>.gpkg`, `llr_F_urban_<year>.gpkg`,
  `full_mask.gpkg`). These are pipeline exclusion layers, not validation labels,
  and are regenerable from NLCD. Say the word and I'll pull them.
- `phase1_nebraska/Monte Carlo approach/run*/` — 19,164 tif realizations and
  53,058 csv outputs from MC runs (V6–V11, 1K/5K/50K reps). Outputs, not inputs.
- `phase2_sampling/data/LRRF_maps/`, `LRRF_heightDistribution/` — model prediction
  products and CHM/height work, outside the training/validation ask.

## Open items for you

1. **Destination.** You mentioned making a folder for this, but I could not find one
   (Desktop is empty; no `*agrofor*` / `*LRR*` / `*nebraska*` directory in your home
   tree besides `Documents/naipScrape` and some `Downloads/gatherAOIs*`). I used
   `~/Documents/agroforestry_trainingValidation/`. Move it wherever you intended.
2. **The production Monte Carlo code is not on the share.** The whole
   `Monte Carlo approach/` tree contains exactly one `.R` and one `.py` file, and
   `MonteCarlo_test_v03.R` is self-described as "fully operational, but incomplete —
   it simulates the process, but the real classification maps, age distribution and
   factors need to be added." Yet there are V9/V10/V11 and 50K-rep run outputs. Whatever
   generated those lives elsewhere (Shahriar's machine or HPC) and is the thing you
   actually want in the repo.
3. **CRS mismatch between regions.** Nebraska masks are in a geographic CRS,
   LRR F masks are projected 1 m. Any shared training loader needs to handle both.
4. `nebraska/masks_*` comes from a `_toBePurged` path — see caveat above.

## Reproducing this pull

Nothing was moved or modified on the share; all operations were reads/copies.
Filters used: `rsync -a --include='*_mask.tif' --include='*_mask.tif.aux.xml' --exclude='*'`.
