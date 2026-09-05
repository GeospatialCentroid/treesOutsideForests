# Agroforestry Masks Pipeline

High-performance, parallelized R spatial analysis workflow to construct agroforestry masks across 15,000 grids.

## Repository Structure

```text
agroforestry_Masks/
├── data/
│   ├── grids.gpkg               # Output of 00_global_init.R (1km sub-grids)
│   └── global_census_places.gpkg # Cached US Census Places (EPSG:5070)
├── outputs/
│   ├── forest_masks/            # Final vector forest masks [id]_[year]_NLCD_Forest.gpkg
│   └── logs/                    # Parallel-safe error logs for individual failures
├── src/
│   ├── 00_global_init.R         # Phase 1: Build grids, download Tigris, auth STAC
│   ├── 01_pipeline_worker.R     # Phase 2: Single-grid pipeline function with tryCatch
│   └── 02_run_pipeline.R        # Phase 3: Multisession future/furrr orchestration
└── README.md
```

## Running the Pipeline

1. **Initialize Global Data & Authentication:**
   Open and edit `src/00_global_init.R` to construct your target grid and cache US Census Places.
   
2. **Execute Parallel Process:**
   Run `src/02_run_pipeline.R` to run the parallel job. 
   It configures local multisession cores using `future` and iterates locklessly using `furrr::future_walk()`.

## Parallel Logging Strategy
To handle 15,000 asynchronous workers without write conflicts or race conditions:
- The worker wraps execution in a `tryCatch` block.
- On error, it writes a unique failure text file directly to `outputs/logs/fail_[id].txt`.
- No global log file lock is needed. Failure rate can be monitored at runtime by counting the files in `outputs/logs/`.
