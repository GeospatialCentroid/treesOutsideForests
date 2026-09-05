# ==============================================================================
# Phase 2: Data Download, Processing, and Reclassification (LLR Scale)
# ==============================================================================

#' Download and Extract NLCD Data
#'
#' Downloads the national NLCD zip bundle for a given year and extracts the GeoTIFF raster.
#' Once extracted, the zip file is removed to conserve storage space.
#' Includes checks to skip downloading if the extracted TIFF already exists.
#'
#' @param year Integer year of the dataset.
#' @param extraction.dir Directory to save raw downloads.
#' @return Path to the extracted GeoTIFF file.
get_nlcd_annual_custom <- function(year, extraction.dir = "data/raw/NLCD") {
  if (!dir.exists(extraction.dir)) dir.create(extraction.dir, recursive = TRUE)
  
  file_base <- paste0("Annual_NLCD_LndCov_", year, "_CU_C1V2")
  zip_name <- paste0(file_base, ".zip")
  tif_name <- paste0(file_base, ".tif")
  
  url <- paste0("https://www.mrlc.gov/downloads/sciweb1/shared/mrlc/data-bundles/", zip_name)
  dest_zip <- file.path(extraction.dir, zip_name)
  dest_tif <- file.path(extraction.dir, tif_name)
  
  # Increase timeout for large downloads (1.3GB+)
  options(timeout = max(1000, getOption("timeout")))
  
  # Check if TIFF already exists
  if (file.exists(dest_tif)) {
    message(paste("TIFF for", year, "already exists at", dest_tif, "- skipping download."))
    return(dest_tif)
  }
  
  # Download ZIP if not present
  if (!file.exists(dest_zip)) {
    message(paste("\n--- Downloading NLCD ZIP for year", year, "---"))
    download.file(url, dest_zip, mode = "wb")
  }
  
  # Extract GeoTIFF
  message(paste("Extracting TIFF for", year, "from ZIP..."))
  unzip(dest_zip, files = tif_name, exdir = extraction.dir)
  
  # Remove ZIP file once extracted to save space
  if (file.exists(dest_zip)) {
    message(paste("Removing downloaded ZIP file:", dest_zip))
    file.remove(dest_zip)
  }
  
  if (file.exists(dest_tif)) {
    return(dest_tif)
  } else {
    stop(paste("Extraction failed: TIFF file not found after unzipping:", dest_tif))
  }
}

#' Crop and Mask NLCD Raster to Study Area
#'
#' Crops and masks the raw NLCD raster to the provided study area template.
#' Includes checks to skip execution if the output file already exists.
#'
#' @param nlcd_path Path to the raw NLCD GeoTIFF file.
#' @param template sf study area polygon.
#' @param output_dir Directory to save processed intermediate rasters.
#' @param year Optional integer/character year for naming output file.
#' @return Path to the cropped and masked GeoTIFF file.
crop_mask_nlcd <- function(nlcd_path, template, output_dir = "data/processed/NLCD", year = NULL) {
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  
  if (is.null(year)) {
    # Attempt to extract year from the file path
    year_match <- regmatches(nlcd_path, regexpr("\\d{4}", nlcd_path))
    year <- if (length(year_match) > 0) year_match else "unknown"
  }
  
  dest_cropped <- file.path(output_dir, paste0("Annual_NLCD_LndCov_", year, "_cropped.tif"))
  
  # Check if output already exists
  if (file.exists(dest_cropped)) {
    message(paste("Cropped & masked NLCD for", year, "already exists at", dest_cropped, "- skipping crop/mask."))
    return(dest_cropped)
  }
  
  if (!file.exists(nlcd_path)) {
    stop(paste("NLCD path not found:", nlcd_path))
  }
  
  message(paste("Loading raw NLCD raster:", nlcd_path))
  r <- terra::rast(nlcd_path)
  
  # Ensure template is in NLCD projection
  message("Transforming study area template to raster projection...")
  template_proj <- sf::st_transform(template, terra::crs(r))
  
  # Crop and mask
  message(paste("Cropping and masking NLCD for", year, "..."))
  r_cropped <- terra::crop(r, template_proj, snap = "out")
  r_masked <- terra::mask(r_cropped, terra::vect(template_proj))
  
  # Save to disk
  message(paste("Saving cropped & masked raster to:", dest_cropped))
  terra::writeRaster(r_masked, dest_cropped, overwrite = TRUE)
  
  # Clean up memory
  rm(r, r_cropped, r_masked)
  gc()
  
  return(dest_cropped)
}

#' Reclassify NLCD Raster to Binary (Forest/Non-Forest)
#'
#' Binarizes the NLCD raster where the defined forest classes become 1 and all other
#' non-NA classes become 0. NA background values are preserved.
#' Includes checks to skip execution if the output file already exists.
#'
#' @param cropped_nlcd_path Path to the cropped NLCD GeoTIFF file.
#' @param classes Integer vector of classes to reclassify as 1 (defaults to nlcdClasses).
#' @param output_dir Directory to save processed binary rasters.
#' @param year Optional integer/character year for naming output file.
#' @return Path to the binary GeoTIFF file.
reclassify_nlcd_binary <- function(cropped_nlcd_path, classes = get0("nlcdClasses", ifnotfound = c(41, 42, 43)), output_dir = "data/processed/NLCD", year = NULL) {
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  
  if (is.null(year)) {
    # Attempt to extract year from the file path
    year_match <- regmatches(cropped_nlcd_path, regexpr("\\d{4}", cropped_nlcd_path))
    year <- if (length(year_match) > 0) year_match else "unknown"
  }
  
  dest_binary <- file.path(output_dir, paste0("Annual_NLCD_LndCov_", year, "_binary.tif"))
  
  # Check if output already exists
  if (file.exists(dest_binary)) {
    message(paste("Binary reclassified NLCD for", year, "already exists at", dest_binary, "- skipping reclassification."))
    return(dest_binary)
  }
  
  if (!file.exists(cropped_nlcd_path)) {
    stop(paste("Cropped NLCD path not found:", cropped_nlcd_path))
  }
  
  message(paste("Loading cropped NLCD raster:", cropped_nlcd_path))
  r <- terra::rast(cropped_nlcd_path)
  
  message(paste("Reclassifying NLCD for", year, "to binary (target classes become 1, others become 0)..."))
  
  # terra::subst naturally preserves NAs while mapping from -> to and others -> other_val
  r_bin <- terra::subst(r, from = classes, to = 1, others = 0)
  
  # Save to disk
  message(paste("Saving binary reclassified raster to:", dest_binary))
  terra::writeRaster(r_bin, dest_binary, overwrite = TRUE)
  
  # Clean up memory
  rm(r, r_bin)
  gc()
  
  return(dest_binary)
}

# Download, crop, mask, and reclassify NLCD datasets for all target years defined in 00_global_init.R
message("\n--- Downloading and processing NLCD datasets for target years ---")
nlcd_paths <- lapply(target_years, function(yr) {
  # 1. Download and Extract (raw TIFF is saved in data/raw/NLCD)
  raw_tif_path <- get_nlcd_annual_custom(year = yr, extraction.dir = "data/raw/NLCD")
  
  # 2. Crop and Mask (cropped TIFF is saved in data/processed/NLCD)
  cropped_tif_path <- crop_mask_nlcd(nlcd_path = raw_tif_path, template = study_area, output_dir = "data/processed/NLCD", year = yr)
  
  # 3. Reclassify (binary TIFF is saved in data/processed/NLCD)
  binary_tif_path <- reclassify_nlcd_binary(cropped_nlcd_path = cropped_tif_path, classes = nlcdClasses, output_dir = "data/processed/NLCD", year = yr)
  
  return(binary_tif_path)
})


# ==============================================================================
# Phase 3: Census Places Download (Temporal)
# ==============================================================================

#' Download and Save Census Places for Study Area by Year
#'
#' Retrieves US Census Places for states overlapping the study area for a given year and saves them as a GeoPackage.
#' Includes checks to skip downloading if the output geopackage already exists on disk.
#' Incorporates a robust fail-safe fallback to a specified reference year if the requested year is unavailable/unsupported.
#'
#' @param study_area sf study area polygon.
#' @param llr sf LLR boundary polygon.
#' @param year Integer year of the Census dataset.
#' @param output_dir Directory to save downloaded census files.
#' @param fallback_year Integer year to fall back on if requested year download fails.
#' @return Path to the output GPKG file.
get_census_places <- function(study_area, llr, year, output_dir = "data/raw/census", fallback_year = 2021) {
  output_path <- file.path(output_dir, paste0("census_places_", year, ".gpkg"))
  
  if (file.exists(output_path)) {
    message(paste("Census places for", year, "already exist at", output_path, "- skipping download."))
    return(output_path)
  }
  
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  
  # Helper function to perform the actual download/processing for a specific year
  attempt_download <- function(yr) {
    message(paste("Downloading Census states and places for year", yr, "overlapping the LLR study area..."))
    
    # Determine all states in study area for the specified year
    States <- tigris::states(year = yr) 
    states <- States |> 
      sf::st_transform(crs = sf::st_crs(llr)) |>
      sf::st_crop(llr) 
    
    unique_states <- unique(states$STATEFP)
    message(paste("Identified overlapping states (FIPS) for year", yr, ":", paste(unique_states, collapse = ", ")))
    
    # Download places for each state and transform to match LLR projection
    # Note: cartographic boundary files (cb = TRUE) are only available from 2013 onwards.
    use_cb <- (yr >= 2013)
    
    census_places <- tigris::places(
      state = unique_states, 
      cb = use_cb,
      year = yr
    ) |> sf::st_transform(crs = sf::st_crs(llr))
    
    return(census_places)
  }
  
  # Try to download the requested year, fallback if it errors/fails
  census_places <- tryCatch({
    attempt_download(year)
  }, error = function(e) {
    warning(paste("Download failed for Census year", year, "with error:", e$message, 
                  "\nFalling back to Census year", fallback_year))
    
    # Check if the fallback file already exists to avoid re-downloading
    fallback_path <- file.path(output_dir, paste0("census_places_", fallback_year, ".gpkg"))
    if (file.exists(fallback_path)) {
      message(paste("Fallback census places for", fallback_year, "already exist on disk. Loading fallback."))
      return(sf::st_read(fallback_path, quiet = TRUE))
    } else {
      # Attempt to download the fallback year
      return(attempt_download(fallback_year))
    }
  })
  
  message(paste("Saving downloaded census places for year", year, "to:", output_path))
  sf::st_write(census_places, output_path, delete_dsn = TRUE, quiet = TRUE)
  
  return(output_path)
}

# Download Census Places for all target years defined in 00_global_init.R
message("\n--- Downloading Census Places for target years ---")
census_places_paths <- lapply(target_years, function(yr) {
  get_census_places(study_area = study_area, llr = llr, year = yr, output_dir = "data/raw/census", fallback_year = 2021)
})

# Demonstrate and verify the fail-safe by requesting an unsupported census year (e.g. 2009)
message("\n--- Testing Census Places Fail-Safe with year 2009 ---")
census_places_2009_path <- get_census_places(study_area = study_area, llr = llr, year = 2009, output_dir = "data/raw/census", fallback_year = 2021)
