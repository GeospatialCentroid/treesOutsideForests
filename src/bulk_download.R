# =========================================================
# NAIP BULK DOWNLOAD & PROCESSING PIPELINE (T7 LOCAL ADAPTATION)
# =========================================================
pacman::p_load(
  dplyr, sf, terra, readr, tidyr, furrr, future, tools, tictoc, rstac, jsonlite
)

# ---------------------------------------------------------
# 1. SETUP & DIRECTORIES
# ---------------------------------------------------------
# Source functions first so get_env_config() is available
lapply(list.files(path = "function", pattern = ".R", full.names = TRUE), source)

# Define T7 Drive path directly for local processing
local_working_dir <- "/run/media/dan/T7/llr_F_threeYearImagery"
dir.create(local_working_dir, showWarnings = FALSE, recursive = TRUE)

message(sprintf("Initializing in local mode... Output directed to: %s", local_working_dir))

# select a full area
aoi_table <- read.csv("data/LRR_sampleGrids/selectedSample_lrr_G_draw_1400_05_2026.csv")


# establish grid features
g100 <- sf::st_read("data/grid100km_aea.gpkg")

# ---------------------------------------------------------
# 3. EXECUTION: BATCHING & FURRR
# ---------------------------------------------------------
# Manually setting workers to 10 to leave headroom for other tasks
local_workers <- 2
plan(multisession, workers = local_workers)
message(sprintf("Parallel workers set to: %s", local_workers))

batch_size <- 50
aoi_table <- aoi_table |>
  mutate(batch_id = ceiling(row_number() / batch_size))

# testing 
# aoi_table <- aoi_table[1:10, ]

# --- GEOSPATIAL PARAMETERS ---
target_years <- c("2012", "2016", "2020")
target_buffer_m <- 250 # 250m buffer results in a 1.5km total width

unique_batches <- unique(aoi_table$batch_id)

for (current_batch in unique_batches) {
  # START OVERALL BATCH TIMER
  tic(paste("Total Time for Batch", current_batch))
  
  batch_folder_name <- paste0("naip_batch_", current_batch)
  batch_folder <- file.path(local_working_dir, batch_folder_name)
  dir.create(batch_folder, showWarnings = FALSE)
  
  batch_data <- aoi_table |> 
    filter(batch_id == current_batch) |>
    mutate(
      local_path = file.path(batch_folder, id),
      is_processed = dir.exists(local_path)
    )
  
  to_process <- batch_data |> filter(!is_processed)
  
  cat("\n==========================================\n")
  cat("Starting Batch", current_batch, "\n")
  cat("Total AOIs:", nrow(batch_data), "| Skipping:", nrow(batch_data) - nrow(to_process), "| Processing:", nrow(to_process), "\n")
  
  if (nrow(to_process) > 0) {
    tic("Image Processing (Furrr)")
    
    results <- future_map(
      to_process$id,
      ~ process_aoi(
        aoi_id = .x,
        target_years = target_years,
        local_dir = batch_folder, # Pointing directly to T7
        g100_grid = g100,
        batch_id = current_batch,
        network_dir = batch_folder, # Bypassing network distinction for this run
        buffer_m = target_buffer_m
      ),
      .progress = TRUE,
      .options = furrr_options(seed = TRUE)
    )
    
    toc()
  } else {
    cat("  [v] All AOIs in this batch already exist locally on the T7.\n")
  }
  
  toc()
  cat("==========================================\n")
}

# =========================================================
# ARCHIVED NETWORK TRANSFER & MOUNTING LOGIC
# =========================================================
# Retained for future reference when reverting to the TrueNAS workflow.
#
# # TOGGLE ENVIRONMENT HERE (TRUE = MacBook via Tailscale | FALSE = Ubuntu/Omarchy VM via 10G)
# env_config <- get_env_config(MAC = FALSE) 
#
# --- Drive Mounting Check ---
# Check if the mount point appears in the list of currently mounted drives
# is_mounted <- any(grepl(env_config$mount_point, system("mount", intern = TRUE)))
# 
# if (!is_mounted) {
#   message("Connecting to TrueNAS network drive...")
#   exit_status <- system(env_config$mount_cmd)
#   
#   if (exit_status != 0) {
#     stop("Failed to mount the network drive. Check your permissions, VPN connection, and paths.")
#   }
#   message("Drive mounted successfully.")
# } else {
#   message("TrueNAS drive is already mounted. Proceeding...")
# }
# 
# dir.create(env_config$network_storage_dir, showWarnings = FALSE, recursive = TRUE)
#
# --- Rsync Transfer & Cleanup (Originally Section 4) ---
# if (length(list.files(batch_folder)) > 0) {
#   tic("Network Transfer (Raw Directory)")
#   cat(sprintf("\n  [->] Transferring via rsync (Bandwidth limit: %s)...\n", env_config$bwlimit))
#   
#   transfer_status <- system2(
#     "rsync",
#     args = c(
#       "-avW",
#       sprintf("--bwlimit=%s", env_config$bwlimit), 
#       batch_folder,
#       env_config$network_storage_dir
#     )
#   )
#   
#   if (transfer_status == 0) {
#     cat("  [v] Batch", current_batch, "successfully transferred to network.\n")
#     cat("  [->] Removing local batch directory...\n")
#     unlink(batch_folder, recursive = TRUE)
#   } else {
#     warning("Transfer failed for Batch ", current_batch, ". Local files retained.")
#   }
#   toc()
# } else {
#   unlink(batch_folder, recursive = TRUE)
# }
