# =========================================================
# Streamlined AOI Image Processing Worker Core
# =========================================================

process_aoi <- function(
    aoi_id,
    target_year,
    g100_grid,
    export_dir = "data/exportData",
    buffer_m = 250,
    run_snic = FALSE,
    export_1km_tight = FALSE,
    p = NULL
) {
  # --- 1. JITTER FOR RATE LIMITING ---
  # Staggers parallel Planetary Computer API requests to avoid overloading/rate-limiting
  Sys.sleep(runif(1, min = 0.5, max = 3.0))
  
  # --- 2. ISOLATED WORKER SCRATCH DIRECTORY ---
  worker_temp <- file.path(tempdir(), paste0("terra_worker_", Sys.getpid(), "_", sample(100000:999999, 1)))
  dir.create(worker_temp, showWarnings = FALSE, recursive = TRUE)
  terra::terraOptions(tempdir = worker_temp)
  
  on.exit(
    {
      unlink(worker_temp, recursive = TRUE)
    },
    add = TRUE
  )
  
  # --- 3. DYNAMIC AOI FETCHING ---
  aoi <- tryCatch({
    getAOI(grid100 = g100_grid, id = aoi_id)
  }, error = function(e) NULL)
  
  if (is.null(aoi)) {
    if (!is.null(p)) p(step = 1, message = sprintf("Failed Geom %s", aoi_id))
    return(list(
      aoi_id = aoi_id,
      target_year = target_year,
      status = "Failed: Missing/Timeout AOI Geometry"
    ))
  }
  
  id <- aoi$id
  
  # --- 4. API YEAR CHECK & FALLBACK HANDLING ---
  years_available <- tryCatch({
    getNAIPYear(aoi)
  }, error = function(e) NULL)
  
  if (is.null(years_available)) {
    if (!is.null(p)) p(step = 1, message = sprintf("Failed STAC API %s", aoi_id))
    return(list(
      aoi_id = aoi_id,
      target_year = target_year,
      status = "Failed: STAC API Metadata Error"
    ))
  }
  
  target_num <- as.numeric(target_year)
  preferred_years <- as.character(c(
    target_num,      # Preference 1: Target Year
    target_num - 1,  # Preference 2: Target Year - 1
    target_num - 2,  # Preference 3: Target Year - 2
    target_num + 1   # Preference 4: Target Year + 1
  ))
  
  actual_year <- NULL
  for (test_year in preferred_years) {
    if (test_year %in% years_available) {
      actual_year <- test_year
      break 
    }
  }
  
  if (is.null(actual_year)) {
    if (!is.null(p)) p(step = 1, message = sprintf("Failed Year Search %s", aoi_id))
    return(list(
      aoi_id = aoi_id,
      target_year = target_year,
      status = "Failed: No NAIP imagery found within fallback range"
    ))
  }
  
  # --- 5. DEFINE YEAR-SPECIFIC AOI EXPORT FOLDER ---
  aoi_folder <- file.path(export_dir, paste0("aoi_", id, "_", actual_year))
  status_file <- file.path(aoi_folder, "status.json")
  
  # Check for existing completed status.json
  if (file.exists(status_file)) {
    check <- tryCatch({
      jsonlite::fromJSON(status_file)
    }, error = function(e) NULL)
    
    if (!is.null(check) && check$status == "Success") {
      if (!is.null(p)) p(step = 1, message = sprintf("Skipped %s (%s)", aoi_id, actual_year))
      return(check)
    }
  }
  
  dir.create(aoi_folder, showWarnings = FALSE, recursive = TRUE)
  
  # --- 6. EXECUTION ---
  process_status <- tryCatch({
    # Download raw intersecting tiles cropped on-the-fly via Planetary Computer vsicurl
    tile_meta <- downloadNAIP_vsi(
      aoi = aoi,
      year = actual_year,
      exportFolder = worker_temp,
      buffer_m = buffer_m
    )
    
    # Regex matching downloaded raw tiles in thread temp dir
    naip_string <- paste0("^naip_", actual_year, "_id_", id, "_[0-9]+\\.tif$")
    naip_files <- list.files(path = worker_temp, pattern = naip_string, full.names = TRUE)
    
    if (length(naip_files) == 0) {
      stop("Download succeeded, but no raw files matched the search regex pattern on disk.")
    }
    
    # Crop, resample, mosaic, mask, and export directly to year-specific output folder
    mergeAndExportNAIP(
      files = naip_files,
      out_path = aoi_folder,
      aoi = aoi,
      year = actual_year,
      buffer_m = buffer_m,
      buffer_only = !export_1km_tight
    )
    
    # Force strict 8-bit unsigned integer (INT1U) alignment and pre-calculate stats for QGIS zero-lag
    r1_pattern <- paste0("naip_.*", id, "_", actual_year, "\\.tif$")
    r1_paths <- list.files(path = aoi_folder, pattern = r1_pattern, full.names = TRUE)
    
    for (r1_path in r1_paths) {
      r1_align <- terra::rast(r1_path)
      r1_max <- max(terra::minmax(r1_align)[2, ], na.rm = TRUE)
      
      if (any(terra::datatype(r1_align) != "INT1U") || r1_max > 255) {
        if (r1_max > 255) {
          r1_align <- terra::stretch(r1_align, minv = 0, maxv = 255)
        }
        terra::writeRaster(r1_align, filename = r1_path, datatype = "INT1U", overwrite = TRUE)
        fix_alpha_band(r1_path)
      }
    }
    
    # Optionally generate and write SNIC segmentations
    if (run_snic) {
      # Use the primary exported raster (usually the 1.5km buffered output)
      source_raster_path <- r1_paths[1]
      r1 <- terra::rast(source_raster_path)
      seeds <- generate_scaled_seeds(r = r1)
      process_segmentations(
        r = r1,
        seed_list = seeds,
        output_dir = aoi_folder,
        file_id = id,
        aoi = aoi,
        year = actual_year
      )
    }
    
    # Success footprint
    res <- list(
      aoi_id = aoi_id,
      target_year = target_year,
      actual_year = actual_year,
      status = "Success",
      capture_dates = paste(tile_meta$collection_date, collapse = "; "),
      item_ids = paste(tile_meta$item_id, collapse = "; "),
      naip_states = paste(tile_meta$naip_state, collapse = "; ")
    )
    
    writeLines(jsonlite::toJSON(res, auto_unbox = TRUE, pretty = TRUE), status_file)
    if (!is.null(p)) p(step = 1, message = sprintf("Finished %s (%s)", aoi_id, actual_year))
    return(res)
    
  }, error = function(e) {
    # Failure footprint
    res <- list(
      aoi_id = aoi_id,
      target_year = target_year,
      actual_year = ifelse(exists("actual_year") && !is.null(actual_year), actual_year, "Unknown"),
      status = paste("Failed:", e$message)
    )
    writeLines(jsonlite::toJSON(res, auto_unbox = TRUE, pretty = TRUE), status_file)
    if (!is.null(p)) p(step = 1, message = sprintf("Failed %s (%s)", aoi_id, target_year))
    return(res)
  })
  
  return(process_status)
}
