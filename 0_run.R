# Primary location for running the entire workflow

message("\n=========================================================")
message("Starting Agroforestry Masks Pipeline")
message("=========================================================")

# Surface warnings as they happen rather than batching them to the end, so a
# Census fallback or a partial-run warning is visible next to the step that
# raised it rather than 200,000 grids later.
old_warn <- getOption("warn")
options(warn = 1)

# Step 1: Initialize global configurations, packages, and datasets
source("src/00_global_init.R")

# Step 2: Download and process LLR-scale raw data (NLCD + Census) for all years
source("src/01_pipeline_worker.R")

# Step 3: Run parallel grid-scale processing for all target years
source("src/02_run_pipeline.R")

options(warn = old_warn)

message("\n=========================================================")
message("Agroforestry Masks Pipeline Completed")
message("=========================================================")

# Report anything that needs a human look before the outputs are used.
n_failures <- length(list.files("outputs/logs", pattern = "^fail_"))
if (n_failures > 0) {
  message(sprintf("  %d grid failure(s) logged in outputs/logs/", n_failures))
}
if (!is.null(get0("grid_limit", ifnotfound = NULL))) {
  message("  NOTE: grid_limit was set - this was a PARTIAL run, not a full one.")
}
message("  Check census_source_year in the Census outputs before treating a")
message("  year's places as that year's data (see README).")
