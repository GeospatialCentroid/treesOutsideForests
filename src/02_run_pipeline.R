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
  # The sample table can repeat an id; compare and report against the distinct
  # set so that "generated N of M" is not misread as N - M missing grids.
  sample_ids <- unique(sample_ids)

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
  
  message(paste("\n--- Hierarchically generating 1km grid geometries for", length(sample_ids), "unique sample IDs ---"))
  
  # Parse hierarchy levels from sample_ids to drastically reduce generated subgrid search space
  id_parts <- strsplit(sample_ids, "-")

  # Every id must resolve to five levels (100km-50km-10km-2km-1km); a short id
  # would otherwise produce an "NA" parent and be dropped without explanation.
  bad_ids <- sample_ids[lengths(id_parts) != 5]
  if (length(bad_ids) > 0) {
    stop(paste0("Malformed sample id(s) - expected 5 hyphen-separated levels: ",
                paste(head(bad_ids, 10), collapse = ", ")))
  }

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
  
  message(paste("Successfully generated geometries for", nrow(sample_grids), "out of", length(sample_ids), "unique sample grids."))

  # Missing geometries mean the sample silently shrinks. Surface them rather
  # than letting the run continue against an incomplete grid set.
  missing_ids <- setdiff(sample_ids, sample_grids$id)
  if (length(missing_ids) > 0) {
    warning(paste0(
      "No geometry generated for ", length(missing_ids), " sample id(s); they will be excluded. First few: ",
      paste(head(missing_ids, 10), collapse = ", ")
    ), call. = FALSE, immediate. = TRUE)
  }
  
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
#' @param grid_row Single-row sf grid feature.
#' @param nlcd_path Path to the binary NLCD GeoTIFF.
#' @param census_llr sf Census Places dataset in its native CRS.
#' @param out_dir Directory to save processed files.
#' @param year Integer/character processing year.
#' @param template_res Numeric resolution of the output template raster.
#' @param template_crs Character CRS of the output template raster.
#' @param crop_margin Numeric margin (map units) added to the crop extent.
#' @param log_dir Directory for per-grid failure logs.
#' @return Logical indicating success.
process_grid <- function(grid_row, nlcd_path, census_llr, out_dir, year,
                         template_res, template_crs, crop_margin = 30,
                         log_dir = "outputs/logs") {
  grid_id <- grid_row$id
  tryCatch({
    # Output file paths
    nlcd_gpkg_out <- file.path(out_dir, sprintf("%s_%s_NLCD_Forest.gpkg", grid_id, year))
    census_gpkg_out <- file.path(out_dir, sprintf("%s_%s_Census.gpkg", grid_id, year))
    
    # Check if GPKG outputs already exist to skip
    if (file.exists(nlcd_gpkg_out) && file.exists(census_gpkg_out)) {
      return(TRUE)
    }
    
    # Dynamically generate template raster covering exactly the grid extent
    grid_template <- terra::rast(terra::ext(grid_row), resolution = template_res, crs = template_crs)
    
    # 1. Process NLCD
    # Load LLR-scale binary NLCD
    nlcd_llr <- terra::rast(nlcd_path)
    
    # Crop NLCD using grid boundary in NLCD CRS (do not reproject NLCD before crop!)
    #
    # snap = "out" is required: the default ("near") snaps the crop extent to the
    # nearest cell boundary, which rounds *inward* whenever the grid edge falls
    # inside a source cell. Reprojecting that under-sized crop onto the 1m
    # template leaves a NA strip up to one source cell wide along the grid
    # edges - measured at 1-3% of every output mask - so forest inside the strip
    # is silently dropped. The extra margin absorbs the datum shift between the
    # NLCD grid (Albers on WGS84) and the analysis CRS (Albers on NAD83).
    grid_nlcd <- sf::st_transform(grid_row, terra::crs(nlcd_llr))
    crop_ext <- terra::ext(grid_nlcd)
    if (crop_margin > 0) crop_ext <- terra::extend(crop_ext, crop_margin)
    nlcd_crop <- terra::crop(nlcd_llr, crop_ext, snap = "out")
    
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
    census_crop <- suppressWarnings(
      sf::st_intersection(census_llr, sf::st_geometry(grid_native))
    )

    # An intersection that only touches a boundary yields points or lines, and a
    # mixed-type layer cannot be written to GeoPackage. Keep polygonal parts
    # only and cast to a single type so every output has a stable schema.
    if (nrow(census_crop) > 0) {
      census_crop <- suppressWarnings(sf::st_collection_extract(census_crop, "POLYGON"))
    }
    if (nrow(census_crop) > 0) {
      census_crop <- sf::st_cast(census_crop, "MULTIPOLYGON", warn = FALSE)
    }
    
    # Reproject cropped census features back to template CRS
    census_aea <- sf::st_transform(census_crop, template_crs)
    
    # Save cropped Census vector (writes an empty spatial layer if no intersection exists)
    sf::st_write(census_aea, census_gpkg_out, delete_dsn = TRUE, quiet = TRUE)
    
    return(TRUE)
  }, error = function(e) {
    # Workers run in separate sessions, where message() output is discarded.
    # Write one file per failure instead: no shared handle, so no lock or race,
    # and the failure count is just the number of files in log_dir.
    tryCatch({
      if (!dir.exists(log_dir)) dir.create(log_dir, recursive = TRUE)
      writeLines(
        c(
          paste("grid_id:", grid_id),
          paste("year:", year),
          paste("time:", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
          paste("error:", conditionMessage(e))
        ),
        file.path(log_dir, sprintf("fail_%s_%s.txt", grid_id, year))
      )
    }, error = function(e2) NULL)
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
#' @param template_res Numeric resolution of the output template raster.
#' @param template_crs Character CRS of the output template raster.
#' @param crop_margin Numeric margin (map units) added to each per-grid crop.
#' @param log_dir Directory for per-grid failure logs.
#' @return Logical indicating whether the year was processed.
run_pipeline_year <- function(year, sample_grids, output_base = "outputs/forest_masks",
                              template_res = 1, template_crs = "EPSG:5070",
                              crop_margin = 30, log_dir = "outputs/logs") {
  message(paste("\n========================================================="))
  message(paste("Starting Grid-Scale Pipeline for Year:", year))
  message(paste("========================================================="))
  
  # Ensure output directory exists
  year_out_dir <- file.path(output_base, as.character(year))
  if (!dir.exists(year_out_dir)) dir.create(year_out_dir, recursive = TRUE)
  if (!dir.exists(log_dir)) dir.create(log_dir, recursive = TRUE)
  
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
  
  # 3. Map over row indices rather than a pre-split list. split() on a
  # 15k-row sf object costs several seconds and inflates 12MB of geometry into
  # ~110MB of single-row data frames, all of which is then serialised out to
  # the workers.
  n_grids <- nrow(sample_grids)
  message(paste("Processing", n_grids, "grids in parallel..."))
  
  # Track execution time
  start_time <- Sys.time()
  
  results <- furrr::future_map_lgl(
    .x = seq_len(n_grids),
    .f = function(i) {
      process_grid(
        grid_row = sample_grids[i, ],
        nlcd_path = nlcd_path,
        census_llr = census_llr,
        out_dir = year_out_dir,
        year = year,
        template_res = template_res,
        template_crs = template_crs,
        crop_margin = crop_margin,
        log_dir = log_dir
      )
    },
    # Workers are fresh R sessions where sf/terra are not attached. Without
    # them, `sample_grids[i, ]` falls back to `[.data.frame`, which drops the
    # sf_column attribute; the result still claims class "sf" but terra's
    # coercion sees no geometry and fails on a NULL. Declaring the packages
    # makes the worker environment explicit instead of relying on that.
    .options = furrr::furrr_options(seed = TRUE, packages = c("sf", "terra"))
  )
  
  end_time <- Sys.time()
  duration <- difftime(end_time, start_time, units = "mins")
  
  success_count <- sum(results)
  message(sprintf("Completed Year %s: %d / %d grids processed successfully in %.2f minutes.", 
                  year, success_count, length(results), duration))

  failed_ids <- sample_grids$id[!results]
  if (length(failed_ids) > 0) {
    message(sprintf("  %d grid(s) failed; see %s (first few: %s)",
                    length(failed_ids), log_dir,
                    paste(head(failed_ids, 5), collapse = ", ")))
  }
  
  return(TRUE)
}

# ==============================================================================
# Pipeline Execution Entry Point
# ==============================================================================

# 1. Generate the grid geometries for our target sample IDs
sample_ids <- sampleIDs$id
llr_grids <- get_sample_grids(sample_ids = sample_ids, grid100km = grid100km)

# Optional smoke-test subset. grid_limit is NULL for a full run; set it in
# 00_global_init.R to process only the first N grids. Previously this was a
# hard-coded `llr_grids[1:80, ]`, which silently reduced a 15,380-grid run to 80.
grid_limit <- get0("grid_limit", ifnotfound = NULL)
if (!is.null(grid_limit)) {
  n_keep <- min(as.integer(grid_limit), nrow(llr_grids))
  warning(paste0("grid_limit is set: processing only the first ", n_keep,
                 " of ", nrow(llr_grids), " grids. This is a partial run."),
          call. = FALSE, immediate. = TRUE)
  llr_grids <- llr_grids[seq_len(n_keep), ]
}

# 2. Set up the parallel plan once for the whole run. Re-planning inside the
# year loop tears down and respawns the worker sessions for every year.
num_cores <- parallel::detectCores()
if (is.na(num_cores)) num_cores <- 1L
num_cores <- max(1L, min(num_cores - 2L, 8L)) # Cap workers to limit memory use
message(paste("Setting up parallel cluster with", num_cores, "workers..."))
future::plan(future::multisession, workers = num_cores)

# 3. Run the pipeline for each target year defined in 00_global_init.R
# For safety, let's process the years sequentially, while grids within each year run in parallel.
message("\n--- Starting processing for all target years ---")
year_status <- purrr::map_lgl(target_years, function(yr) {
  run_pipeline_year(
    year = yr,
    sample_grids = llr_grids,
    output_base = "outputs/forest_masks",
    template_res = template_res,
    template_crs = analysis_crs,
    crop_margin = grid_crop_margin
  )
})

future::plan(future::sequential)

skipped_years <- target_years[!year_status]
if (length(skipped_years) > 0) {
  warning(paste("Years skipped for missing inputs:", paste(skipped_years, collapse = ", ")),
          call. = FALSE, immediate. = TRUE)
}
