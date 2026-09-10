# ==============================================================================
# UNIFIED NAIP SCRAPE PIPELINE (LOCAL-ONLY PARALLEL EXECUTION ENGINE)
# ==============================================================================
# This script consolidates downloading, cropping, mosaicking, stats-baking,
# and (optional) segmentation into a clean, modern, future/furrr-driven runner.
# It runs entirely locally on the current machine and reads settings from config.yml.
# ==============================================================================

# 0. Shared helpers: repo-root paths and the root config.yml
source(here::here("shared/R/setup.R"))

# 1. Load Essential Orchestration Packages
pacman::p_load(
  yaml, dplyr, sf, terra, readr, tidyr, furrr, future, tools, tictoc, rstac, jsonlite
)
# failed to install dplyr, readr, tidyr, 

# 2. Sourced Pipeline Functions
message("Sourcing pipeline modules from naip/function/...")
lapply(list.files(path = tof_root("naip/function"), pattern = "[.]R$", full.names = TRUE), source)

# 3. Read Configuration (the `naip` section of the root config.yml)
cfg      <- tof_config()
cfg_naip <- cfg$naip

grid_path       <- tof_path(cfg$reference$grid_gpkg)
sample_f_path   <- tof_path(cfg_naip$paths$sample_f_csv)
sample_g_path   <- tof_path(cfg_naip$paths$sample_g_csv)
export_dir      <- tof_path(cfg_naip$paths$export_dir)

target_region    <- cfg_naip$target_region
target_years     <- as.character(cfg_naip$target_years)
buffer_dist_m    <- cfg_naip$buffer_dist_m
run_snic         <- cfg_naip$run_snic
export_1km_tight <- cfg_naip$export_1km_tight

workers          <- cfg_naip$workers

# 4. Input Validation & Directory Creation
if (!file.exists(grid_path)) {
  stop(sprintf("Critical Error: Master grid geopackage missing at '%s'", grid_path))
}
dir.create(export_dir, showWarnings = FALSE, recursive = TRUE)

# 5. Build Unified Target Tasks Table
message("Loading sample grids...")
tasks_list <- list()

if (target_region %in% c("F", "both")) {
  if (file.exists(sample_f_path)) {
    f_tbl <- readr::read_csv(sample_f_path, show_col_types = FALSE) |>
      dplyr::mutate(region = "F")
    tasks_list[[length(tasks_list) + 1]] <- f_tbl
    message(sprintf("  -> Loaded LLR F sample grid list: %d unique sites.", nrow(f_tbl)))
  } else {
    warning(sprintf("LLR F CSV path not found: '%s'", sample_f_path))
  }
}

if (target_region %in% c("G", "both")) {
  if (file.exists(sample_g_path)) {
    g_tbl <- readr::read_csv(sample_g_path, show_col_types = FALSE) |>
      dplyr::mutate(region = "G")
    tasks_list[[length(tasks_list) + 1]] <- g_tbl
    message(sprintf("  -> Loaded LLR G sample grid list: %d unique sites.", nrow(g_tbl)))
  } else {
    warning(sprintf("LLR G CSV path not found: '%s'", sample_g_path))
  }
}

if (length(tasks_list) == 0) {
  stop("No valid input CSV tasks loaded. Check 'config.yml' paths and 'target_region' setting.")
}

# Bind into single master table
sites_table <- dplyr::bind_rows(tasks_list) |>
  dplyr::distinct(id, .keep_all = TRUE)

# Expand each site by target years (fully parallelizable combos)
tasks_table <- sites_table |>
  tidyr::expand_grid(target_year = target_years)

# 6. Load Master Grid in Main Process
message("Reading master 100km grid vector...")
g100 <- sf::st_read(grid_path, quiet = TRUE)

# Print execution banner
cat("\n======================================================================\n")
cat("                  NAIP PIPELINE EXECUTION INITIATED\n")
cat("======================================================================\n")
cat(sprintf("Target Region:      %s\n", target_region))
cat(sprintf("Unique Sites:       %d\n", nrow(sites_table)))
cat(sprintf("Target Years:       %s\n", paste(target_years, collapse = ", ")))
cat(sprintf("Total Task Pairs:   %d (Site-Year combinations)\n", nrow(tasks_table)))
cat(sprintf("Buffer Distance:    %d meters (producing %s width)\n", buffer_dist_m, paste0((1000 + (2 * buffer_dist_m)) / 1000, "km")))
cat(sprintf("SNIC Segmentation:  %s\n", ifelse(run_snic, "ENABLED", "DISABLED")))
cat(sprintf("Tight 1km Export:   %s\n", ifelse(export_1km_tight, "ENABLED", "DISABLED")))
cat(sprintf("Parallel Workers:   %d\n", workers))
cat(sprintf("Output Directory:   %s\n", export_dir))
cat("======================================================================\n\n")

# 7. Establish Parallel Cluster Configuration
if (workers > 1) {
  message(sprintf("Starting parallel multisession cluster with %d workers...", workers))
  future::plan(future::multisession, workers = workers)
} else {
  message("Running sequentially...")
  future::plan(future::sequential)
}

# Ensure garbage collection is triggered on parallel workers
options(future.rng.onMisuse = "ignore")

# 8. Start Pipeline Processing
tictoc::tic("Pipeline Total Time")

results <- furrr::future_map(
  .x = 1:nrow(tasks_table),
  .f = function(row_idx) {
    task_row <- tasks_table[row_idx, ]
    
    # Process the specific (aoi_id, target_year) combination
    process_aoi(
      aoi_id           = task_row$id,
      target_year      = task_row$target_year,
      g100_grid        = g100,
      export_dir       = export_dir,
      buffer_m         = buffer_dist_m,
      run_snic         = run_snic,
      export_1km_tight = export_1km_tight
    )
  },
  .progress = TRUE,
  .options = furrr::furrr_options(seed = TRUE)
)

tictoc::toc()

# 9. Pipeline Diagnostics and Completion Report
results_df <- dplyr::bind_rows(results)
success_count <- sum(results_df$status == "Success")
skipped_count <- sum(grepl("Skipped", results_df$status))
failed_count  <- nrow(results_df) - success_count - skipped_count

cat("\n======================================================================\n")
cat("                  PIPELINE RUN COMPLETION REPORT\n")
cat("======================================================================\n")
cat(sprintf("Total Tasks Processed: %d\n", nrow(results_df)))
cat(sprintf("  -> Successful:        %d\n", success_count))
cat(sprintf("  -> Skipped (Cached):  %d\n", skipped_count))
cat(sprintf("  -> Failed:            %d\n", failed_count))
cat("======================================================================\n")

if (failed_count > 0) {
  cat("\nFailed tasks summary:\n")
  failed_tasks <- results_df |> dplyr::filter(status != "Success", !grepl("Skipped", status))
  for (i in 1:nrow(failed_tasks)) {
    cat(sprintf("  - AOI: %s | Year: %s | Error: %s\n", 
                failed_tasks$aoi_id[i], failed_tasks$target_year[i], failed_tasks$status[i]))
  }
}
cat("\nPipeline process successfully wrapped up!\n")
