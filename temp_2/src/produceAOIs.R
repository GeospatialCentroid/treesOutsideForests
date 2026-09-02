# Workflow to generate the AOIs for the specific areas of interest.

pacman::p_load(
  dplyr,
  sf,
  terra,
  tidyr,
  furrr,
  future,
  tictoc
)
# source files
lapply(list.files(path = "function", pattern = ".R", full.names = TRUE), source)

# establish grid features
g100 <- sf::st_read("data/grid100km_aea.gpkg")

# Load only the specified input data
grids <- readr::read_csv("data/LRR_sampleGrids/selectedSample_lrr_F_05_2026.csv")
unique_grid_ids <- unique(grids$id)

# ---------------------------------------------------------
# DIRECTORY, EXECUTION & PARAMETER SETUP
# ---------------------------------------------------------
aoi_dir <- file.path("data/aoiExports/LLR_F")

# Create main directories if they don't exist
dir.create(aoi_dir, showWarnings = FALSE, recursive = TRUE)

tic("Total Script Runtime") # Overall timer for the whole process

# ---------------------------------------------------------
# EXECUTION BLOCK (PARALLEL VIA FURRR)
# ---------------------------------------------------------

# 1. Set up the parallel backend. 
# "multisession" creates background R sessions (ideal for cross-platform/Windows compatibility).
# availableCores() - 1 leaves one core free for system stability.
plan(multisession, workers = 12)

cat(sprintf("\n--- Starting Parallel Processing (%d tasks) ---\n", length(unique_grid_ids)))

# 2. Use future_walk to process the IDs in parallel.
# Note: Text progress bars (txtProgressBar) don't naturally update inside parallel workers.
# Instead, we rely on furrr's built-in progress argument.
future_walk(unique_grid_ids, function(current_id) {
  
  # Save the AOI geometry as a GeoPackage within the AOI folder
  gpkg_path <- file.path(aoi_dir, paste0("aoi-", current_id, ".gpkg"))
  
  if (!file.exists(gpkg_path)) {
    # Retrieve AOI using the ID from the file
    aoi <- getAOI(grid100 = g100, id = current_id)
    sf::st_write(aoi, dsn = gpkg_path, driver = "GPKG", quiet = TRUE, append = FALSE)
  }
}, .progress = TRUE) # Displays a progress bar in the console

# 3. Explicitly close background workers to free up RAM
plan(sequential)

toc()