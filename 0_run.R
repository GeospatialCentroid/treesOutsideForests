# Primary location for running the entire workflow

message("\n=========================================================")
message("Starting Agroforestry Masks Pipeline")
message("=========================================================")

# Step 1: Initialize global configurations, packages, and datasets
source("src/00_global_init.R")

# Step 2: Download and process LLR-scale raw data (NLCD + Census) for all years
source("src/01_pipeline_worker.R")

# Step 3: Run parallel grid-scale processing for all target years
source("src/02_run_pipeline.R")

message("\n=========================================================")
message("Agroforestry Masks Pipeline Completed Successfully!")
message("=========================================================")
