# treesOutsideForests

Pipeline for estimating trees outside forests (TOF) by USDA Land Resource Region
(LRR) from NAIP imagery. Merged from GeospatialCentroid repos with full history.

| Folder    | Stage                                                | Former repo        |
|-----------|------------------------------------------------------|--------------------|
| `masks/`  | Annual forest and urban masks per LRR (NLCD, Census) | agroforestry_Masks |
| `naip/`   | NAIP acquisition and SNIC segmentation over AOIs     | naipScrape         |
| `sampling/` | Systematic sample grid draw, sample design maps and site-role assignment | new; grid draw ported from neymanSampling; agroforestrySampling to follow |
| `estimates/` | Area-weighted TOF estimates per MLRA and LRR from the per-cell model output | new |
| `harmonize/` | Optional radiometric harmonisation of the NAIP exports across years (KS-gated quantile matching), a second export tree the model can read | ported from neymanSampling |
| `model/` | U-Net tree / no-tree model: NAIP fetch for the reference masks, training, evaluation, prediction (CPU PyTorch) | new; reference scripts in `U-Net/` and `agroforestry_trainingValidation/scripts/` |

Each stage keeps its own README. This file covers what is shared.

## Layout

```text
treesOutsideForests/
├── treesOutsideForests.Rproj   # the only RStudio project: open this
├── config.yml                  # all settings, one section per stage
├── shared/R/setup.R            # tof_root(), tof_config(), tof_path(), read_lrr()
├── data/
│   ├── reference/              # small tracked inputs: LRR, MLRA, 100 km grid, sample grids
│   ├── masks/                  # large working data for masks/    (ignored)
│   ├── naip/                   # large working data for naip/     (ignored)
│   ├── naip/harmonized/        # harmonised NAIP tree from harmonize/ (ignored)
│   ├── sampling/               # redrawn grids, maps, cached layers (ignored)
│   └── model/                  # aligned pairs, band stats, training runs (ignored)
├── harmonize/
├── masks/
├── model/
├── naip/
└── sampling/
```

## Conventions

- **One project, one working directory.** Open `treesOutsideForests.Rproj`; the
  working directory is the repo root. There are deliberately no other `.Rproj`
  files, so `here::here()` always resolves to the root.
- **Every script starts with** `source(here::here("shared/R/setup.R"))`.
  After that, build paths with `tof_root("naip/function")` or
  `tof_path(cfg$masks$paths$outputs)`, never with a bare relative string.
- **Settings live in `config.yml`.** Shared keys (`crs`, `reference`) sit at the
  top; each stage reads its own section through `tof_config()$<stage>`.
- **Data policy.** `data/reference/` is tracked because it is small and every
  stage needs it. Everything else under `data/` is ignored. On the shared NAS
  `data/masks/*` and `data/naip` are symlinks to where those files already live.

## Running

```r
source("masks/0_run.R")             # build the LRR masks
source("naip/src/run_pipeline.R")   # pull and process NAIP for the sampled grids
source("sampling/00_draw_sample_grid.R")  # redraw the systematic sample grid (about 1400 cells per MLRA)
source("sampling/01_map_lrr_sites.R")  # whole-LRR sample design map and site-role assignment
source("sampling/02_map_mlra_sites.R") # one map pair per MLRA, layers clipped to each MLRA
source("estimates/tools/make_synthetic_cells.R")  # synthetic model output while none exists
source("estimates/00_run_estimates.R")  # area-weighted TOF estimates per MLRA and LRR
source("estimates/01_aoi_areas.R")      # sampled cells clipped to their MLRA, areas against the combined mask
source("estimates/02_placeholder_tof.R") # NLCD-calibrated placeholder TOF per AOI, the partner spreadsheet
source("estimates/03_montecarlo_replicates.R") # 50,000 replicates per AOI for 2020, Parquet dataset
source("estimates/04_replicate_estimates.R")   # area-weighted estimates for every replicate, and their summaries
```

The tracked sample lists in `data/reference/sampleGrids/` are the May 2026
draws; `Rscript sampling/test/test_sample_grid_replication.R` shows that the
draw script reproduces them byte-for-byte (see `sampling/README.md`).

or from a shell at the repo root: `Rscript naip/src/run_pipeline.R`.
