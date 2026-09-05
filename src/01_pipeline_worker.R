# ==============================================================================
# Phase 2: Data Download, Processing, and Reclassification (LLR Scale)
# ==============================================================================

#' Download and Extract NLCD Data
#'
#' Downloads the national NLCD zip bundle for a given year and extracts the GeoTIFF raster.
#' Once the extraction is confirmed, the zip file is removed to conserve storage space.
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

  # Check if TIFF already exists
  if (file.exists(dest_tif)) {
    message(paste("TIFF for", year, "already exists at", dest_tif, "- skipping download."))
    return(dest_tif)
  }

  # Raise the timeout for the ~1.3GB download, then restore the session default.
  old_timeout <- getOption("timeout")
  options(timeout = max(1000, old_timeout))
  on.exit(options(timeout = old_timeout), add = TRUE)

  # Download ZIP if not present. Download to a partial file first so that an
  # interrupted transfer is never mistaken for a complete one on the next run.
  if (!file.exists(dest_zip)) {
    message(paste("\n--- Downloading NLCD ZIP for year", year, "---"))
    part_zip <- paste0(dest_zip, ".part")
    if (file.exists(part_zip)) file.remove(part_zip)
    download.file(url, part_zip, mode = "wb")
    if (!file.rename(part_zip, dest_zip)) {
      stop(paste("Failed to finalise downloaded ZIP:", part_zip))
    }
  }

  # Extract GeoTIFF
  message(paste("Extracting TIFF for", year, "from ZIP..."))
  unzip(dest_zip, files = tif_name, exdir = extraction.dir)

  # Only discard the ZIP once the extraction is confirmed. Removing it first
  # means a failed unzip costs the whole download again.
  if (!file.exists(dest_tif)) {
    stop(paste("Extraction failed: TIFF file not found after unzipping:", dest_tif,
               "\nThe downloaded ZIP has been kept at:", dest_zip))
  }

  message(paste("Removing downloaded ZIP file:", dest_zip))
  file.remove(dest_zip)

  return(dest_tif)
}

#' Crop and Mask NLCD Raster to Study Area
#'
#' Crops and masks the raw NLCD raster to the provided study area template.
#' Includes checks to skip execution if the output file already exists.
#'
#' @param nlcd_path Path to the raw NLCD GeoTIFF file.
#' @param template sf/sfc study area polygon.
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

  # Crop and mask. snap = "out" guarantees the retained extent fully contains
  # the study area; the default ("near") can snap inward and drop a partial
  # cell of data along each edge.
  message(paste("Cropping and masking NLCD for", year, "..."))
  r_cropped <- terra::crop(r, terra::vect(template_proj), snap = "out")
  r_masked <- terra::mask(r_cropped, terra::vect(template_proj))

  # Save to disk
  message(paste("Saving cropped & masked raster to:", dest_cropped))
  terra::writeRaster(
    r_masked, dest_cropped, overwrite = TRUE,
    gdal = c("TILED=YES", "COMPRESS=DEFLATE", "BIGTIFF=IF_SAFER")
  )

  # Clean up memory
  rm(r, r_cropped, r_masked)
  gc()

  return(dest_cropped)
}

#' Reclassify NLCD Raster to Binary (Forest/Non-Forest)
#'
#' Binarizes the NLCD raster where the defined forest classes become 1 and all other
#' classes become 0. Cells that are NA in the input (outside the study area mask)
#' stay NA, so "outside the study area" remains distinguishable from "not forest".
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

  # terra::subst() with `others` also rewrites NA cells, which would erase the
  # study area mask. Reclassify by comparison instead and restore the NA mask.
  r_bin <- terra::ifel(r %in% classes, 1, 0)
  r_bin <- terra::mask(r_bin, r)

  # Save to disk as a single unsigned byte with an explicit NoData value. A 0/1
  # mask has no business being Float32: INT1U plus DEFLATE cuts each year's
  # raster from ~53MB to ~16MB and makes "no data" explicit rather than relying
  # on a NaN. (Tiling was measured to make no difference to windowed read speed
  # at this file size - it is set for correctness of layout, not for speed.)
  message(paste("Saving binary reclassified raster to:", dest_binary))
  terra::writeRaster(
    r_bin, dest_binary, overwrite = TRUE,
    datatype = "INT1U", NAflag = 255,
    gdal = c("TILED=YES", "COMPRESS=DEFLATE", "BIGTIFF=IF_SAFER")
  )

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
#' Retrieves US Census Places for states overlapping the LLR for a given year and
#' saves them as a GeoPackage.
#' Includes checks to skip downloading if the output geopackage already exists on disk.
#'
#' Not every year is served by the Census API. When the requested year is
#' unavailable the function falls back to the nearest available year, but the
#' returned data is stamped with a `census_source_year` column recording the year
#' the geometries actually came from, and the fallback is reported through a
#' warning. Without that stamp a fallback is indistinguishable from a real
#' download: the file is named for the requested year, so substituted data
#' silently propagates into every downstream product.
#'
#' @param llr sf LLR boundary polygon.
#' @param year Integer year of the Census dataset.
#' @param output_dir Directory to save downloaded census files.
#' @param fallback_years Integer vector of years to try, in order, if the
#'   requested year is unavailable. Defaults to the other target years, nearest
#'   first.
#' @param max_attempts Maximum number of years to try before giving up.
#' @return Path to the output GPKG file.
get_census_places <- function(llr, year, output_dir = "data/raw/census",
                              fallback_years = NULL, max_attempts = 4) {
  output_path <- file.path(output_dir, paste0("census_places_", year, ".gpkg"))

  if (file.exists(output_path)) {
    message(paste("Census places for", year, "already exist at", output_path, "- skipping download."))
    return(output_path)
  }

  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  # Default fallback order: the other target years, nearest to the requested
  # year first, so a substitution is as close in time as possible.
  if (is.null(fallback_years)) {
    pool <- setdiff(get0("target_years", ifnotfound = 2009:2021), year)
    fallback_years <- pool[order(abs(pool - year))]
  }

  # Helper function to perform the actual download/processing for a specific year
  attempt_download <- function(yr) {
    message(paste("Downloading Census states and places for year", yr, "overlapping the LLR study area..."))

    # Determine all states genuinely overlapping the LLR polygon. Cropping to
    # the LLR bounding box instead pulls in states that only touch the box
    # corners, downloading places that can never intersect a sample grid.
    States <- tigris::states(year = yr, progress_bar = FALSE) |>
      sf::st_transform(crs = sf::st_crs(llr))
    overlaps <- lengths(sf::st_intersects(States, llr)) > 0
    unique_states <- unique(States$STATEFP[overlaps])

    if (length(unique_states) == 0) {
      stop(paste("No states intersect the LLR boundary for census year", yr))
    }
    message(paste("Identified overlapping states (FIPS) for year", yr, ":", paste(unique_states, collapse = ", ")))

    # Download places for each state and transform to match LLR projection
    # Note: cartographic boundary files (cb = TRUE) are only available from 2013 onwards.
    use_cb <- (yr >= 2013)

    census_places <- tigris::places(
      state = unique_states,
      cb = use_cb,
      year = yr,
      progress_bar = FALSE
    ) |> sf::st_transform(crs = sf::st_crs(llr))

    return(census_places)
  }

  # Try the requested year, then each fallback year in turn.
  candidates <- c(year, head(fallback_years, max_attempts - 1))
  census_places <- NULL
  source_year <- NA_integer_
  failures <- character(0)

  for (yr in candidates) {
    result <- tryCatch(attempt_download(yr), error = function(e) e)
    if (inherits(result, "error")) {
      failures <- c(failures, paste0(yr, ": ", conditionMessage(result)))
      next
    }
    census_places <- result
    source_year <- yr
    break
  }

  if (is.null(census_places)) {
    stop(paste0("Could not retrieve Census places for year ", year,
                " or any fallback year.\nAttempts:\n  ",
                paste(failures, collapse = "\n  ")))
  }

  # Stamp the provenance onto the data itself so a substitution stays visible
  # after the file is written, read back, and clipped into per-grid outputs.
  census_places$census_source_year <- source_year
  census_places$census_requested_year <- as.integer(year)

  if (!identical(as.integer(source_year), as.integer(year))) {
    warning(paste0(
      "Census places for ", year, " are UNAVAILABLE; substituted year ",
      source_year, ".\n  The file is named census_places_", year,
      ".gpkg for pipeline lookup, but the geometries are from ", source_year,
      ".\n  Downstream products for ", year, " do not reflect ", year,
      " place boundaries. See the census_source_year column."
    ), call. = FALSE, immediate. = TRUE)
  }

  message(paste("Saving census places (source year", source_year, ") for year", year, "to:", output_path))
  sf::st_write(census_places, output_path, delete_dsn = TRUE, quiet = TRUE)

  return(output_path)
}

# Download Census Places for all target years defined in 00_global_init.R
message("\n--- Downloading Census Places for target years ---")
census_places_paths <- lapply(target_years, function(yr) {
  get_census_places(llr = llr, year = yr, output_dir = "data/raw/census")
})

# Report any year whose places were substituted from another year, so that a
# fallback is visible in the run log rather than only in the file contents.
census_provenance <- purrr::map_dfr(target_years, function(yr) {
  p <- file.path("data/raw/census", paste0("census_places_", yr, ".gpkg"))
  if (!file.exists(p)) return(NULL)
  cols <- names(sf::st_read(p, quiet = TRUE, query = paste0(
    "SELECT * FROM \"census_places_", yr, "\" LIMIT 1"
  )))
  src <- if ("census_source_year" %in% cols) {
    sf::st_read(p, quiet = TRUE, query = paste0(
      "SELECT census_source_year FROM \"census_places_", yr, "\" LIMIT 1"
    ))$census_source_year[1]
  } else {
    NA_integer_
  }
  data.frame(requested_year = yr, source_year = src)
})

message("\n--- Census places provenance ---")
print(census_provenance)
unstamped <- census_provenance$requested_year[is.na(census_provenance$source_year)]
if (length(unstamped) > 0) {
  warning(paste0(
    "Census files for year(s) ", paste(unstamped, collapse = ", "),
    " predate provenance stamping and their true source year is unknown.\n",
    "  Run src/99_audit_census_cache.R to check them for silent fallbacks."
  ), call. = FALSE, immediate. = TRUE)
}
substituted <- census_provenance[
  !is.na(census_provenance$source_year) &
    census_provenance$source_year != census_provenance$requested_year, ]
if (nrow(substituted) > 0) {
  warning(paste0(
    "Census places were substituted from another year for: ",
    paste(sprintf("%d<-%d", substituted$requested_year, substituted$source_year), collapse = ", ")
  ), call. = FALSE, immediate. = TRUE)
}
