# treesOutsideForests

Pipeline for estimating trees outside forests (TOF) by USDA Land Resource Region
(LRR) from NAIP imagery. Merged from GeospatialCentroid repos with full history.

| Folder    | Stage                                                | Former repo        |
|-----------|------------------------------------------------------|--------------------|
| `masks/`  | Annual forest and urban masks per LRR (NLCD, Census) | agroforestry_Masks |
| `naip/`   | NAIP acquisition and SNIC segmentation over AOIs     | naipScrape         |
| `sampling/` | Sample design maps and site-role assignment | new; agroforestrySampling to follow |

Each stage keeps its own README. This file covers what is shared.

## Layout

```text
treesOutsideForests/
├── treesOutsideForests.Rproj   # the only RStudio project: open this
├── config.yml                  # all settings, one section per stage
├── shared/R/setup.R            # tof_root(), tof_config(), tof_path(), read_lrr()
├── data/
│   ├── reference/              # small tracked inputs: LRR, MLRA, 100 km grid, sample grids
│   ├── masks/                  # large working data for masks/  (ignored)
│   └── naip/                   # large working data for naip/   (ignored)
├── masks/
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
source("sampling/01_map_lrr_sites.R")  # whole-LRR sample design map and site-role assignment
source("sampling/02_map_mlra_sites.R") # one map pair per MLRA, layers clipped to each MLRA
```

or from a shell at the repo root: `Rscript naip/src/run_pipeline.R`.
