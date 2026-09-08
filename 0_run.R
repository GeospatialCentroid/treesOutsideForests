# Primary location for running the entire workflow

message("\n=========================================================")
message("Starting Agroforestry LLR Masks Pipeline")
message("=========================================================")

# Surface warnings as they happen rather than batching them to the end, so a
# Census fallback is visible next to the step that raised it.
old_warn <- getOption("warn")
options(warn = 1)

# Step 1: Initialize global configuration, packages, and the LLR boundary
source("src/00_global_init.R")

# Step 2: Download and process LLR-scale source data (NLCD + Census), all years
source("src/01_pipeline_worker.R")

# Step 3: Build the LLR-scale forest and urban mask products
source("src/02_llr_masks.R")

options(warn = old_warn)

message("\n=========================================================")
message("Agroforestry LLR Masks Pipeline Completed")
message("=========================================================")
message("  Products are in outputs/llr_masks/ - see llr_mask_summary.csv.")
message("  Check census_source_year before treating a year's places as that")
message("  year's data (see README).")
