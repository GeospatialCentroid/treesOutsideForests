# Primary location for running the entire workflow

message("\n=========================================================")
message("Starting Agroforestry LLR Masks Pipeline")
message("=========================================================")

# Surface warnings as they happen rather than batching them to the end, so a
# Census fallback is visible next to the step that raised it.
old_warn <- getOption("warn")
options(warn = 1)

# Shared helpers: repo-root paths and the root config.yml
source(here::here("shared/R/setup.R"))

# Step 1: Initialize global configuration, packages, and the LLR boundary
source(tof_root("masks/src/00_global_init.R"))

# Step 2: Download and process LLR-scale source data (NLCD + Census), all years
source(tof_root("masks/src/01_pipeline_worker.R"))

# Step 3: Build the LLR-scale forest and urban mask products
source(tof_root("masks/src/02_llr_masks.R"))

# Step 4: Aggregate the per-year combined masks into one any-year mask
source(tof_root("masks/src/03_llr_mask_any_year.R"))

options(warn = old_warn)

message("\n=========================================================")
message("Agroforestry LLR Masks Pipeline Completed")
message("=========================================================")
message("  Products are in ", masks_out_dir, " - see llr_mask_summary.csv.")
message("  Urban products exist only for years with an independent Census release;")
message("  census_status in the summary says which years those are (see README).")

