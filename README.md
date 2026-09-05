# Agroforestry Masks Pipeline

Parallelised R spatial workflow that builds 1 m forest masks for a sample of
1 km grids within a USDA Land Resource Region (LRR), for each year of Annual
NLCD.

For the current configuration (LRR "F", 2009–2021) that is 15,380 grids × 13
years ≈ 200,000 output layers.

## Repository Structure

```text
agroforestry_Masks/
├── 0_run.R                          # Runs the three phases in order
├── data/
│   ├── lower48LRR.gpkg              # LRR boundaries (input)
│   ├── grid100km_aea.gpkg           # 100km parent grid (input)
│   ├── selectedSample_lrr_F_05_2026.csv  # Sample 1km grid ids (input)
│   ├── raw/NLCD/                    # Downloaded national NLCD GeoTIFFs
│   ├── raw/census/                  # Census Places per year
│   └── processed/
│       ├── NLCD/                    # LRR-scale cropped + binary rasters
│       └── llr_grids_sample.gpkg    # Cached 1km grid geometries
├── outputs/
│   ├── forest_masks/<year>/         # [id]_[year]_NLCD_Forest.gpkg
│   │                                # [id]_[year]_Census.gpkg
│   └── logs/                        # One file per failed grid
└── src/
    ├── 00_global_init.R             # Config, packages, input data
    ├── 01_pipeline_worker.R         # LRR-scale NLCD + Census preparation
    ├── 02_run_pipeline.R            # Grid-scale parallel processing
    ├── generateAOI.R                # Hierarchical grid generation helpers
    └── 99_audit_census_cache.R      # Read-only check for census cache issues
```

## Running the Pipeline

```r
source("0_run.R")
```

This runs three phases in order:

1. **`00_global_init.R`** — loads packages, sets configuration, reads the LRR
   boundary, the 100 km parent grid, and the sample id table.
2. **`01_pipeline_worker.R`** — for each target year: downloads the national
   Annual NLCD bundle from MRLC, crops and masks it to the study area, and
   reclassifies it to a binary forest mask. Then downloads Census Places for
   the states overlapping the LRR.
3. **`02_run_pipeline.R`** — generates the 1 km grid geometries (cached), then
   for each year clips, reprojects to 1 m, and vectorises the forest mask and
   the Census Places for every grid in parallel.

Phases are re-runnable: each step skips work whose output already exists on
disk. Delete the relevant file to force a step to redo itself.

## Configuration

All knobs live at the top of `src/00_global_init.R`:

| Setting | Meaning |
| --- | --- |
| `target_years` | Years to process (default `2009:2021`). |
| `nlcdClasses` | NLCD classes counted as forest (default `41, 42, 43`). |
| `llr_id` | Which LRR to process (default `"F"`). |
| `analysis_crs` | CRS for all grids and outputs (default `EPSG:5070`). |
| `template_res` | Output resolution in metres (default `1`). |
| `study_area_margin` | Margin around the LRR bbox when clipping NLCD (default `5000`). |
| `grid_crop_margin` | Margin on each per-grid NLCD crop (default `30`). |
| `grid_limit` | `NULL` for a full run, or an integer for a smoke test. |

### Running a smoke test

Set `grid_limit <- 25` in `src/00_global_init.R`. The run warns on every
execution while it is set, so a partial run cannot be mistaken for a full one.
Set it back to `NULL` for production.

## Parallel Logging Strategy

The grid pipeline runs 8 `future` multisession workers. `message()` output from
a worker is discarded, so failures are recorded on disk instead:

- The worker wraps its work in `tryCatch`.
- On error it writes `outputs/logs/fail_[id]_[year].txt` containing the grid id,
  year, timestamp, and error message.
- One file per failure means no shared handle, so no lock and no race.
- The failure count is just the number of files in `outputs/logs/`.

`run_pipeline_year()` also reports the success count and the first few failed
grid ids at the end of each year.

## Data Provenance Caveats

**Census Places are not available for every year.** When a year cannot be
downloaded, the pipeline falls back to the nearest available year. The
substituted data is written under the requested year's filename (the grid
pipeline looks it up by year), so provenance is recorded *inside* the data:

- `census_source_year` — the year the geometries actually came from.
- `census_requested_year` — the year that was asked for.

A fallback also raises a warning at download time and is listed in the
provenance table printed at the end of phase 2. **Check `census_source_year`
before treating a Census output as belonging to its filename's year.**

Files written before provenance stamping was added carry no such column. Run:

```sh
Rscript src/99_audit_census_cache.R
```

to fingerprint the cached files and report any years sharing identical content
— a sign that one of them is a silent substitution. The script is read-only; it
prints the removal command but deletes nothing.

## Notes on Geometry

- Grid ids are hierarchical: `100km-50km-10km-2km-1km`, each level a hex index
  within its parent (e.g. `1548-1-19-a-4`).
- The NLCD rasters are Albers on WGS84; the analysis CRS is Albers on NAD83
  (EPSG:5070). Grids are transformed into the raster's CRS before cropping, and
  the crop carries a one-cell margin to absorb the datum shift.
- Per-grid crops use `snap = "out"`. The default (`"near"`) rounds the crop
  extent inward and leaves a NA strip along the grid edges.
