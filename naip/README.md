# naipScrape: High-Performance Parallel Spatial Processing Pipeline

A high-performance, unified R-based spatial pipeline designed for the rapid acquisition, processing, and visual optimization of high-resolution National Agriculture Imagery Program (NAIP) multi-band data, alongside Simple Non-Iterative Clustering (SNIC) superpixel segmentations.

By utilizing cloud-native GeoTIFF reads over GDAL virtual file systems (/vsicurl/) and local-only parallel execution, this pipeline completely avoids the download of multi-gigabyte raw scene files, streaming only the pixels inside target Areas of Interest (AOIs).

---

## The Unified Pipeline (naip/src/run_pipeline.R)

The entire scraping and processing lifecycle is managed by a single entry point: naip/src/run_pipeline.R. All configuration parameters are declared in config.yml.

### How the Pipeline Operates
1. **Unified Target Table**: Loads coordinate/grid tables (AEA 100km subgrids) dynamically based on LLR regions configured in config.yml.
2. **Parallel Combo Expansion**: Expands target unique grid IDs and target years into fully parallelizable Site-Year combinations processed concurrently via the future/furrr multisession engine.
3. **Decentralized State Caching**: Each task checks for a local status.json file inside the AOI's target folder. If the status is already marked successful, it immediately skips the task, providing robust, no-lock checkpointing.
4. **Dynamic Year Fallback**: Queries the Microsoft Planetary Computer STAC API for available years. If a target year is missing, it dynamically searches fallback years in a prioritized order: [target, target - 1, target - 2, target + 1].
5. **GDAL /vsicurl/ Targeted Crop**: Streams only the pixels falling inside the buffered AOI using GDAL virtual files. Crops the raw bands on-the-fly to a specified margin (e.g., 250 meters).
6. **Mosaicking & Resampling**: To eliminate coordinate origin and resolution discrepancies between different NAIP tiles, workers resample each raw cropped tile to a master 1m resolution template grid before mosaicking them using terra::mosaic(fun = "mean").
7. **Buffer Masking**: Applies a circular, rounded-corner mask using the buffered AOI geometry to isolate the exact area of interest.
8. **QGIS Visualization Optimizations**:
   - **Band 4 Alpha Fix**: Overrides GDAL's default behavior (which treats the 4th Near-Infrared band as a transparency mask) by setting band 4's color interpretation to undefined via GDAL translate.
   - **Baked Header Stats**: Computes min-max statistics using GDAL info (-stats) and bakes them directly into the GeoTIFF headers. This enables QGIS to render the imagery instantly with perfect color stretching without scanning the file.
9. **Simple Non-Iterative Clustering (SNIC)**: If enabled, executes Simple Non-Iterative Clustering (SNIC) directly on the exported NAIP raster to generate edge-aligned polygon superpixel clusters representing localized boundaries (e.g., crop, tree, or grassland).

---

## Configuration (config.yml)

The pipeline reads the `naip` section of the root `config.yml`, plus the shared
`reference` paths. All paths are relative to the repository root:

```yaml
reference:
  grid_gpkg: "data/reference/grid100km_aea.gpkg"   # master 100 km equal-area grid
  mlra_gpkg: "data/reference/lower48MLRA.gpkg"     # MLRA boundaries (LRR F/G)

naip:
  target_region: "both"          # "F", "G", or "both"
  target_years: ["2012", "2016", "2020"]
  buffer_dist_m: 250             # 250 m around the 1 km grid = 1.5 km window
  run_snic: false
  export_1km_tight: false
  workers: 4
  paths:
    sample_f_csv: "data/reference/sampleGrids/selectedSample_lrr_F_05_2026.csv"
    sample_g_csv: "data/reference/sampleGrids/selectedSample_lrr_G_draw_1400_05_2026.csv"
    export_dir:   "data/naip/exportData"
```

---

## Expected Directory Structure

```text
data/naip/exportData/
└── aoi_<aoi_id>_<actual_year>/
    ├── naip_1.5km_<aoi_id>_<actual_year>.tif     <- Contextual buffered image (RGB+NIR, QGIS-optimized)
    ├── naip_1km_<aoi_id>_<actual_year>.tif       <- Modeling core image (only if export_1km_tight: true)
    ├── seg_<aoi_id>_s<spacing>_<actual_year>.gpkg <- SNIC superpixel boundaries (only if run_snic: true)
    ├── aoi-<aoi_id>.gpkg                         <- Original 1km boundary geometry vector
    └── status.json                               <- Decentralized run progress & STAC metadata cache
```

---

## Progress Reporting & Utilities (naip/function/getSTATUS.R)

Since the pipeline operates in a decentralized, database-free manner, progress can be monitored and managed using these built-in utilities:

### 1. compileStatus(local_working_dir)
Crawls your export folder, reads all the distributed status.json tracker files, and compiles them into a single, flat R data frame for tracking.
* **Tabular Flattening**: Automatically flattens nested JSON metadata.
* **Analysis-Ready**: Outputs columns such as actual_year, capture_dates (timestamps), item_ids, and naip_states.

### 2. clearStatus(local_working_dir)
Deletes all distributed status.json files on disk. Useful for forcing the pipeline to perform a clean retry across active directories.

---

## Verification & Reproducibility (test/)

To guarantee codebase stability, reproducibility, and output parity across parallel updates, the test/ directory contains complete validation tests:

1. **Seed & Selection Test (test/test_seed.R)**:
   - Confirms that setting seed 125 on selectedSample_lrr_F_05_2026.csv reliably selects the identical 15 target AOIs.
   - Run: `Rscript naip/test/test_seed.R`

2. **Sequential vs Parallel Raster Parity (test/test_raster_comparison.R)**:
   - Generates sequential (1 worker) and parallel (4 workers) products for test AOIs and executes a complete element-by-element verification check.
   - Compares band names, count (4 bands), data types (INT1U), coordinate reference systems, extents, resolutions, spatial dimensions, pixel-level values (absolute maximum cell value difference is verified to be exactly 0), alpha color interpretations (ColorInterp=Undefined), and file sizes.
   - Run: `Rscript naip/test/test_raster_comparison.R`

---

## Getting Started

1. **Install Dependencies**:
   Ensure R is installed with the required packages:
   ```R
   install.packages("pacman")
   pacman::p_load(yaml, dplyr, sf, terra, readr, tidyr, furrr, future, tools, tictoc, rstac, jsonlite)
   ```
2. **Setup config.yml**: Edit the `naip` section of the root config.yml (target region, years, workers).
3. **Execute**: From the repository root:
   ```bash
   Rscript naip/src/run_pipeline.R
   ```
