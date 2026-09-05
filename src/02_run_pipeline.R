# ==============================================================================
# Phase 3: Data Processing (Grid Scale)
# ==============================================================================

# Ensure global configurations and functions are loaded
if (!exists("study_area") || !exists("target_years") || !exists("nlcdClasses")) {
  source("src/00_global_init.R")
}
if (!exists("get_census_places") || !exists("crop_mask_nlcd")) {
  source("src/01_pipeline_worker.R")
}

#' Batch Generate 1km Grid Geometries
#'
#' Leverages the fact that all 15,000+ sample IDs belong to only a few unique 
#' 100km parent grids. Generates subgrids down to 1km in batches for those 
#' parents, then filters to our target sample IDs. This is orders of magnitude 
#' faster than running getAOI sequentially for every ID.
#' Caches results to disk for instant loading on subsequent runs.
#'
#' @param sample_ids Character vector of 1km grid IDs.
#' @param grid100km sf 100km grid collection.
#' @param cache_path Path to the GPKG cache file.
#' @return sf object of 1km grid geometries.
get_sample_grids <- function(sample_ids, grid100km, cache_path = "data/processed/llr_grids_sample.gpkg") {
  if (file.exists(cache_path)) {
    cached_grids <- sf::st_read(cache_path, quiet = TRUE)
    # Ensure all requested sample_ids are present in the cached geometries
    if (all(sample_ids %in% cached_grids$id)) {
      message(paste("\n--- Loading pre-generated sample 1km grid geometries from cache:", cache_path, "---"))
      return(cached_grids)
    } else {
      message("\n--- Cache exists but does not contain all requested sample IDs. Regenerating... ---")
    }
  }
  
  message(paste("\n--- Hierarchically generating 1km grid geometries for", length(sample_ids), "sample IDs ---"))
  
  # Parse hierarchy levels from sample_ids to drastically reduce generated subgrid search space
  id_parts <- strsplit(sample_ids, "-")
  
  id100_all <- unique(sapply(id_parts, function(x) x[1]))
  id50_all  <- unique(sapply(id_parts, function(x) paste(x[1], x[2], sep="-")))
  id10_all  <- unique(sapply(id_parts, function(x) paste(x[1], x[2], x[3], sep="-")))
  id2_all   <- unique(sapply(id_parts, function(x) paste(x[1], x[2], x[3], x[4], sep="-")))
  
  # Step 1: Filter 100km parent grids
  g100 <- grid100km |> dplyr::filter(id %in% id100_all)
  if (nrow(g100) == 0) {
    stop("No matching 100km parent grids found in grid100km!")
  }
  
  # Step 2: Build 50km subgrids and filter to relevant ones
  message("Generating 50km subgrids...")
  g50 <- buildSubGrids(grids = g100, cell_size = 50000, aoi = g100) |>
    dplyr::filter(id %in% id50_all)
  
  # Step 3: Build 10km subgrids and filter to relevant ones
  message("Generating 10km subgrids...")
  g10 <- buildSubGrids(grids = g50, cell_size = 10000, aoi = g50) |>
    dplyr::filter(id %in% id10_all)
    
  # Step 4: Build 2km subgrids and filter to relevant ones
  message("Generating 2km subgrids...")
  g2 <- buildSubGrids(grids = g10, cell_size = 2000, aoi = g10) |>
    dplyr::filter(id %in% id2_all)
    
  # Step 5: Build 1km subgrids and filter to target sample_ids
  message("Generating 1km subgrids...")
  sample_grids <- buildSubGrids(grids = g2, cell_size = 1000, aoi = g2) |>
    dplyr::filter(id %in% sample_ids)
  
  message(paste("Successfully generated geometries for", nrow(sample_grids), "out of", length(sample_ids), "sample grids."))
  
  # Save to cache geopackage
  out_dir <- dirname(cache_path)
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  message(paste("Saving generated grid geometries to cache:", cache_path))
  sf::st_write(sample_grids, cache_path, delete_dsn = TRUE, quiet = TRUE)
  
  return(sample_grids)
}

#' Process a Single 1km Grid
#'
#' Processes a single grid row by cropping, projecting, and vectorizing the pre-classified NLCD
#' and the Census Places for a given year.
#'
#' @param grid_row Single-row sf grid feature with geometry column `geom`.
#' @param nlcd_path Path to the binary NLCD GeoTIFF.
#' @param census_llr sf Census Places dataset in its native CRS.
#' @param out_dir Directory to save processed files.
#' @param year Integer/character processing year.
#' @param template_res Numeric vector representing the resolution of template_rast.
#' @param template_crs Character representation of the projection CRS of template_rast.
#' @return Logical indicating success.
process_grid <- function(grid_row, nlcd_path, census_llr, out_dir, year, template_res, template_crs) {
  tryCatch({
    grid_id <- grid_row$id
    geom_5070 <- sf::st_geometry(grid_row)
    
    # Output file paths
    nlcd_gpkg_out <- file.path(out_dir, sprintf("%s_%s_NLCD_Forest.gpkg", grid_id, year))
    census_gpkg_out <- file.path(out_dir, sprintf("%s_%s_Census.gpkg", grid_id, year))
    
    # Check if GPKG outputs already exist to skip
    if (file.exists(nlcd_gpkg_out) && file.exists(census_gpkg_out)) {
      return(TRUE)
    }
    
    # Dynamically generate template raster using characteristics from global template_rast passed from master session
    grid_template <- terra::rast(terra::ext(grid_row), resolution = template_res, crs = template_crs)
    
    # 1. Process NLCD
    # Load LLR-scale binary NLCD
    nlcd_llr <- terra::rast(nlcd_path)
    
    # Crop NLCD using grid boundary in NLCD CRS (do not reproject NLCD before crop!)
    grid_nlcd <- sf::st_transform(grid_row, terra::crs(nlcd_llr))
    nlcd_crop <- terra::crop(nlcd_llr, terra::ext(grid_nlcd))
    
    # Project cropped NLCD to the template raster (resample 30m to 1m)
    nlcd_proj <- terra::project(nlcd_crop, grid_template, method = "near")
    
    # Isolate forest cells (value 1) and make others NA for vectorization
    forest_only <- terra::ifel(nlcd_proj == 1, 1, NA)
    nlcd_vec <- terra::as.polygons(forest_only, dissolve = TRUE)
    
    # Export vector forest polygon (can write 0 rows if no forest exists)
    terra::writeVector(nlcd_vec, nlcd_gpkg_out, overwrite = TRUE)
    
    # 2. Process Census (clip to grid geometry)
    # Reproject 1km grid to native CRS of the census vector (do not reproject census before crop!)
    grid_native <- sf::st_transform(grid_row, sf::st_crs(census_llr))
    census_crop <- sf::st_intersection(census_llr, sf::st_geometry(grid_native))
    
    # Reproject cropped census features back to template CRS
    census_aea <- sf::st_transform(census_crop, template_crs)
    
    # Save cropped Census vector (writes an empty spatial layer if no intersection exists)
    sf::st_write(census_aea, census_gpkg_out, delete_dsn = TRUE, quiet = TRUE)
    
    return(TRUE)
  }, error = function(e) {
    message(sprintf("Failed processing grid %s for year %s: %s", grid_row$id, year, e$message))
    return(FALSE)
  })
}

#' Run Parallel Processing Pipeline for a Specific Year
#'
#' Orchestrates the grid-scale processing for a given target year across all sample grids.
#'
#' @param year Integer year to process.
#' @param sample_grids sf collection of 1km sample grids.
#' @param output_base Directory to save final products.
run_pipeline_year <- function(year, sample_grids, output_base = "outputs/forest_masks") {
  message(paste("\n========================================================="))
  message(paste("Starting Grid-Scale Pipeline for Year:", year))
  message(paste("========================================================="))
  
  # Ensure output directory exists
  year_out_dir <- file.path(output_base, as.character(year))
  if (!dir.exists(year_out_dir)) dir.create(year_out_dir, recursive = TRUE)
  
  # 1. Verify inputs exist
  nlcd_path <- file.path("data/processed/NLCD", paste0("Annual_NLCD_LndCov_", year, "_binary.tif"))
  census_path <- file.path("data/raw/census", paste0("census_places_", year, ".gpkg"))
  
  if (!file.exists(nlcd_path)) {
    warning(paste("NLCD binary raster missing for year", year, "at:", nlcd_path, "- Skipping year."))
    return(FALSE)
  }
  if (!file.exists(census_path)) {
    warning(paste("Census places file missing for year", year, "at:", census_path, "- Skipping year."))
    return(FALSE)
  }
  
  # 2. Load Census Places globally (once per year) in its native CRS
  message("Loading Census dataset...")
  census_llr <- sf::st_read(census_path, quiet = TRUE)
  
  # Extract characteristics from global template_rast (on master session)
  template_res <- terra::res(template_rast)
  template_crs <- terra::crs(template_rast)
  
  # 3. Setup Parallel Execution Plan
  num_cores <- min(parallel::detectCores() - 2, 8) # Cap workers at 8 to prevent memory exhaustion
  if (num_cores < 1) num_cores <- 1
  message(paste("Setting up parallel cluster with", num_cores, "workers..."))
  future::plan(future::multisession, workers = num_cores)
  
  # 4. Split grids into list for furrr mapping
  grid_list <- split(sample_grids, seq(nrow(sample_grids)))
  
  message(paste("Processing", length(grid_list), "grids in parallel..."))
  
  # Track execution time
  start_time <- Sys.time()
  
  results <- furrr::future_map_lgl(
    .x = grid_list,
    .f = function(grid_row) {
      process_grid(
        grid_row = grid_row,
        nlcd_path = nlcd_path,
        census_llr = census_llr,
        out_dir = year_out_dir,
        year = year,
        template_res = template_res,
        template_crs = template_crs
      )
    },
    .options = furrr_options(seed = TRUE)
  )
  
  end_time <- Sys.time()
  duration <- difftime(end_time, start_time, units = "mins")
  
  success_count <- sum(results)
  message(sprintf("Completed Year %s: %d / %d grids processed successfully in %.2f minutes.", 
                  year, success_count, length(results), duration))
  
  # Reset future plan
  future::plan(future::sequential)
  
  return(TRUE)
}

# ==============================================================================
# Pipeline Execution Entry Point
# ==============================================================================

# 1. Generate the grid geometries for our target sample IDs
sample_ids <- sampleIDs$id
llr_grids <- get_sample_grids(sample_ids = sample_ids, grid100km = grid100km)
llr_grids <- llr_grids[1:80, ]
# 2. Run the pipeline for each target year defined in 00_global_init.R
# For safety, let's process the years sequentially, while grids within each year run in parallel.
message("\n--- Starting processing for all target years ---")
purrr::walk(target_years, function(yr) {
  run_pipeline_year(year = yr, sample_grids = llr_grids, output_base = "outputs/forest_masks")
})
