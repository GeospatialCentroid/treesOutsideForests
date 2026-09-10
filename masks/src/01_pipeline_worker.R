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
get_nlcd_annual_custom <- function(year, extraction.dir = masks_nlcd_raw_dir) {
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
crop_mask_nlcd <- function(nlcd_path, template, output_dir = masks_nlcd_dir, year = NULL) {
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
reclassify_nlcd_binary <- function(cropped_nlcd_path, classes = get0("nlcdClasses", ifnotfound = c(41, 42, 43)), output_dir = masks_nlcd_dir, year = NULL) {
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
  raw_tif_path <- get_nlcd_annual_custom(year = yr, extraction.dir = masks_nlcd_raw_dir)

  # 2. Crop and Mask (cropped TIFF is saved in data/processed/NLCD)
  cropped_tif_path <- crop_mask_nlcd(nlcd_path = raw_tif_path, template = study_area, output_dir = masks_nlcd_dir, year = yr)

  # 3. Reclassify (binary TIFF is saved in data/processed/NLCD)
  binary_tif_path <- reclassify_nlcd_binary(cropped_nlcd_path = cropped_tif_path, classes = nlcdClasses, output_dir = masks_nlcd_dir, year = yr)

  return(binary_tif_path)
})


# ==============================================================================
# Phase 3: Census Places Download (Temporal)
# ==============================================================================

#' State Boundaries for Choosing Which State Files to Download
#'
#' tigris does not serve states for every vintage either (2009 among them). The
#' state layer is used for one thing - deciding which state place files overlap
#' the LLR - so when the requested year is unavailable the nearest available
#' year is used for that decision. State boundaries do not move between adjacent
#' years at the scale this test operates on, and the place data itself is still
#' the requested year's own: this fallback selects files, it does not supply
#' geometry to any product.
#'
#' @param year Integer year wanted.
#' @param pool Integer vector of years to fall back through, nearest first.
#' @return list(states = sf, year = integer year the boundaries came from).
get_states_for_selection <- function(year, pool = get0("target_years", ifnotfound = 2009:2021)) {
  candidates <- c(year, setdiff(pool, year)[order(abs(setdiff(pool, year) - year))])
  failures <- character(0)
  for (yr in candidates) {
    res <- tryCatch(tigris::states(year = yr, progress_bar = FALSE), error = function(e) e)
    if (inherits(res, "error")) {
      failures <- c(failures, paste0(yr, ": ", conditionMessage(res)))
      next
    }
    return(list(states = res, year = yr))
  }
  stop(paste0("Could not retrieve state boundaries for any year near ", year,
              ".\nAttempts:\n  ", paste(failures, collapse = "\n  ")))
}

#' Normalise Place Column Names Across TIGER/Line Vintages
#'
#' The 2010 decennial files suffix every field with the year (NAME10, ALAND10),
#' and 2009 calls the concatenated state+place code PLCIDFP rather than GEOID.
#' Renaming them here means every year's places layer carries the same field
#' names, so a consumer does not have to special-case the two recovered years.
#'
#' @param x sf places layer.
#' @param year Integer vintage the layer came from.
#' @return The layer with harmonised column names.
normalise_place_fields <- function(x, year) {
  nms <- names(x)
  if (year == 2010) nms <- sub("10$", "", nms)
  nms[nms == "PLCIDFP"] <- "GEOID"
  names(x) <- nms
  x
}

#' Download TIGER/Line Places Directly, for Vintages tigris Declines
#'
#' tigris::places() refuses any year before 2011, but the Census publishes those
#' files - the directory layout simply differs per vintage, which is what tigris
#' has not implemented:
#'
#'   2009  TIGER2009/<FIPS>_<STATE NAME>/tl_2009_<FIPS>_place.zip
#'   2010  TIGER2010/PLACE/2010/tl_2010_<FIPS>_place10.zip
#'
#' These are the same full-detail TIGER/Line releases that tigris returns for
#' 2011-2013 with cb = FALSE, so a year recovered this way is that year's own
#' data and satisfies the no-substitution policy.
#'
#' @param state_fips Character vector of state FIPS codes to fetch.
#' @param year Integer vintage (2009 or 2010).
#' @param state_names Named character vector mapping FIPS to state name, needed
#'   for the 2009 layout's directory names.
#' @param download_dir Directory to cache the downloaded zips and shapefiles.
#' @return sf of places for all requested states, fields normalised.
download_places_direct <- function(state_fips, year, state_names,
                                   download_dir = file.path(masks_census_dir, "tiger_direct")) {
  if (!year %in% c(2009, 2010)) {
    stop(paste("No direct TIGER/Line layout is implemented for year", year))
  }
  if (!dir.exists(download_dir)) dir.create(download_dir, recursive = TRUE)

  place_url <- function(fips) {
    if (year == 2010) {
      sprintf("https://www2.census.gov/geo/tiger/TIGER2010/PLACE/2010/tl_2010_%s_place10.zip", fips)
    } else {
      nm <- state_names[[fips]]
      if (is.null(nm) || is.na(nm)) stop(paste("No state name for FIPS", fips, "- needed for the 2009 directory layout"))
      sprintf("https://www2.census.gov/geo/tiger/TIGER2009/%s_%s/tl_2009_%s_place.zip",
              fips, toupper(gsub(" ", "_", nm)), fips)
    }
  }

  old_timeout <- getOption("timeout")
  options(timeout = max(300, old_timeout))
  on.exit(options(timeout = old_timeout), add = TRUE)

  parts <- lapply(state_fips, function(fips) {
    url <- place_url(fips)
    zip_path <- file.path(download_dir, basename(url))
    shp_dir <- file.path(download_dir, sprintf("tl_%d_%s_place", year, fips))

    if (!file.exists(zip_path)) {
      message(paste("  Direct download:", url))
      # Download to a partial file first so an interrupted transfer is never
      # mistaken for a complete one on the next run.
      part <- paste0(zip_path, ".part")
      if (file.exists(part)) file.remove(part)
      utils::download.file(url, part, mode = "wb", quiet = TRUE)
      if (!file.rename(part, zip_path)) stop(paste("Failed to finalise download:", part))
    } else {
      message(paste("  Direct download cached:", basename(zip_path)))
    }

    utils::unzip(zip_path, exdir = shp_dir, overwrite = TRUE)
    shp <- list.files(shp_dir, pattern = "[.]shp$", full.names = TRUE)
    if (length(shp) != 1) {
      stop(paste("Expected exactly one shapefile in", shp_dir, "- found", length(shp)))
    }
    normalise_place_fields(sf::st_read(shp[1], quiet = TRUE), year)
  })

  do.call(rbind, parts)
}

#' Download and Save Census Places for Study Area by Year
#'
#' Retrieves US Census Places for states overlapping the LLR for a given year and
#' saves them as a GeoPackage.
#' Includes checks to skip downloading if the output geopackage already exists on disk.
#'
#' Not every year is served by the Census API. By default the function does not
#' substitute: a year that cannot be downloaded returns NA and no file is
#' written, so the year simply has no urban source and no urban product. This is
#' deliberate - a mask named for 2009 that holds 2011 boundaries is worse than no
#' 2009 mask, because only one of the two can be caught downstream.
#'
#' Set `allow_substitution = TRUE` (or the global
#' `allow_census_year_substitution`) to restore the nearest-year fallback. Either
#' way the returned data is stamped with a `census_source_year` column recording
#' the year the geometries actually came from, so provenance survives being
#' written, read back, and clipped into per-grid outputs.
#'
#' A cached file whose stamp does not match its filename is left over from a
#' substituting run. With substitution off it is moved aside to a .quarantine
#' name that the pipeline never reads, rather than being served as that year's
#' data or silently deleted.
#'
#' @param llr sf LLR boundary polygon.
#' @param year Integer year of the Census dataset.
#' @param output_dir Directory to save downloaded census files.
#' @param fallback_years Integer vector of years to try, in order, if the
#'   requested year is unavailable and substitution is enabled. Defaults to the
#'   other target years, nearest first.
#' @param max_attempts Maximum number of years to try before giving up.
#' @param allow_substitution Fall back to another year when the requested year is
#'   unavailable. Defaults to the global `allow_census_year_substitution`.
#' @param recheck_unavailable Re-query a year previously recorded as having no
#'   Census release, instead of trusting its .unavailable marker.
#' @param state_select_buffer Distance (map units) to buffer the LLR by when
#'   deciding which states overlap it, covering grids that overhang the edge.
#' @return Path to the output GPKG file, or NA_character_ when the year has no
#'   Census release of its own and substitution is disabled.
get_census_places <- function(llr, year, output_dir = masks_census_dir,
                              fallback_years = NULL, max_attempts = 4,
                              allow_substitution = get0("allow_census_year_substitution", ifnotfound = FALSE),
                              recheck_unavailable = get0("census_recheck_unavailable", ifnotfound = FALSE),
                              state_select_buffer = get0("study_area_margin", ifnotfound = 5000)) {
  output_path <- file.path(output_dir, paste0("census_places_", year, ".gpkg"))
  marker_path <- file.path(output_dir, paste0("census_places_", year, ".unavailable"))

  if (file.exists(output_path)) {
    cached_source <- census_source_year_of(output_path)
    if (allow_substitution || identical(cached_source, as.integer(year))) {
      message(paste("Census places for", year, "already exist at", output_path, "- skipping download."))
      return(output_path)
    }
    # The cache holds another year's boundaries under this year's name. Move it
    # out of the way instead of deleting it: nothing is lost (it is a copy of
    # the source year's file) and nothing downstream can pick it up.
    quarantine_path <- file.path(output_dir, sprintf(
      "census_places_%d.from_%s.gpkg.quarantine", year,
      if (is.na(cached_source)) "unknown" else cached_source))
    file.rename(output_path, quarantine_path)
    warning(paste0(
      "Cached Census places for ", year, " are ",
      if (is.na(cached_source)) "unstamped, so their source year is unknown" else paste("really", cached_source, "boundaries"),
      ".\n  Substitution is disabled, so the file has been moved to ",
      basename(quarantine_path), " and ", year, " is being re-attempted."
    ), call. = FALSE, immediate. = TRUE)
  }

  if (!allow_substitution && file.exists(marker_path) && !recheck_unavailable) {
    message(paste0("Census places for ", year, " were already found to be unavailable (",
                   basename(marker_path), ") - skipping download.\n",
                   "  Delete that marker or set census_recheck_unavailable <- TRUE to try again."))
    return(NA_character_)
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

    # Determine all states genuinely overlapping the LLR. Cropping to the LLR
    # bounding box instead pulls in states that only touch the box corners,
    # downloading places that can never intersect a sample grid.
    #
    # Buffer the LLR before the test: 1km grids are generated from 100km parents
    # and can overhang the LLR edge, so a grid can reach slightly into a state
    # that does not itself intersect the LLR polygon.
    llr_reach <- sf::st_buffer(sf::st_union(llr), state_select_buffer)
    state_src <- get_states_for_selection(yr)
    States <- sf::st_transform(state_src$states, crs = sf::st_crs(llr))
    if (!identical(as.integer(state_src$year), as.integer(yr))) {
      message(paste0("  State boundaries unavailable for ", yr, "; used ", state_src$year,
                     " to decide which state files to download. This selects files only - ",
                     "the places below are ", yr, "'s own."))
    }
    overlaps <- lengths(sf::st_intersects(States, llr_reach)) > 0
    unique_states <- unique(States$STATEFP[overlaps])

    if (length(unique_states) == 0) {
      stop(paste("No states intersect the LLR boundary for census year", yr))
    }
    message(paste("Identified overlapping states (FIPS) for year", yr, ":", paste(unique_states, collapse = ", ")))

    # FIPS -> state name, for the 2009 layout's <FIPS>_<STATE NAME> directories.
    state_names <- stats::setNames(
      as.character(States$NAME[match(unique_states, States$STATEFP)]), unique_states)

    # Download places for each state and transform to match LLR projection.
    #
    # Two published products can serve a year: the generalised cartographic
    # boundary file (cb = TRUE, from 2013 onwards) and the full-detail TIGER/Line
    # file (cb = FALSE, all years). Preference is cb, then TIGER - both are that
    # year's own release, which is what the no-substitution policy cares about,
    # so a broken path to one of them must not be mistaken for the year having
    # no data. tigris 2.2.1 looks for the 2013 cartographic files under
    # GENZ2013/shp/, where they do not exist (they sit directly in GENZ2013/), so
    # without this fallback 2013 looks unavailable when it is not.
    variants <- if (yr >= 2013) c(TRUE, FALSE) else FALSE
    census_places <- NULL
    boundary_type <- NA_character_
    variant_failures <- character(0)

    for (use_cb in variants) {
      attempt <- tryCatch(
        tigris::places(state = unique_states, cb = use_cb, year = yr, progress_bar = FALSE),
        error = function(e) e
      )
      if (inherits(attempt, "error")) {
        variant_failures <- c(variant_failures, paste0(
          if (use_cb) "cartographic (cb)" else "TIGER/Line", ": ", conditionMessage(attempt)))
        next
      }
      census_places <- attempt
      boundary_type <- if (use_cb) "cb" else "tiger"
      break
    }

    # tigris declines every year before 2011, so fetch those straight from the
    # Census. Same publisher, same release, same year - only the path differs.
    if (is.null(census_places) && yr <= 2010) {
      attempt <- tryCatch(
        download_places_direct(unique_states, yr, state_names), error = function(e) e)
      if (inherits(attempt, "error")) {
        variant_failures <- c(variant_failures,
                              paste0("direct TIGER/Line: ", conditionMessage(attempt)))
      } else {
        census_places <- attempt
        boundary_type <- "tiger"
        message(paste0("  tigris does not serve places for ", yr,
                       "; downloaded that year's TIGER/Line release directly."))
      }
    }

    if (is.null(census_places)) {
      stop(paste0("no places file could be retrieved for ", yr, "; tried ",
                  paste(variant_failures, collapse = " | ")))
    }
    if (yr >= 2013 && length(variant_failures) > 0 && identical(boundary_type, "tiger")) {
      message(paste0("  Cartographic boundary file unavailable for ", yr,
                     "; used the full-detail TIGER/Line release instead."))
    }

    census_places <- sf::st_transform(census_places, crs = sf::st_crs(llr))
    # Which of the year's two published products this is. The geometries are
    # generalised differently, so an area computed from a cb year is not exactly
    # comparable with one computed from a TIGER year.
    census_places$census_boundary_type <- boundary_type
    return(census_places)
  }

  # Try the requested year, then - only when substitution is allowed - each
  # fallback year in turn.
  candidates <- if (allow_substitution) {
    c(year, head(fallback_years, max_attempts - 1))
  } else {
    year
  }
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
    if (allow_substitution) {
      stop(paste0("Could not retrieve Census places for year ", year,
                  " or any fallback year.\nAttempts:\n  ",
                  paste(failures, collapse = "\n  ")))
    }
    # No substitution: this year simply has no Census source. Record the
    # verdict so the next run does not re-query for it, and carry on - the
    # forest products for this year are unaffected.
    writeLines(c(
      sprintf("Census Places for %d could not be retrieved on %s.", year, Sys.Date()),
      "Attempts:",
      paste0("  ", failures),
      "",
      "No urban product is built for this year (allow_census_year_substitution = FALSE).",
      "Delete this marker, or set census_recheck_unavailable <- TRUE, to try again."
    ), marker_path)
    warning(paste0(
      "No Census Places release for ", year, "; substitution is disabled, so no ",
      "places or urban layer will be built for that year.\n  Attempts:\n    ",
      paste(failures, collapse = "\n    ")), call. = FALSE, immediate. = TRUE)
    return(NA_character_)
  }

  # A genuine download supersedes any previous "unavailable" verdict.
  if (file.exists(marker_path)) file.remove(marker_path)

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
  get_census_places(llr = llr, year = yr, output_dir = masks_census_dir)
})

# Report what each target year actually ended up with, so a missing year is
# visible in the run log rather than only as an absent file.
census_provenance <- purrr::map_dfr(target_years, function(yr) {
  p <- file.path(masks_census_dir, paste0("census_places_", yr, ".gpkg"))
  src <- census_source_year_of(p)
  status <- if (!file.exists(p)) {
    "no Census release - no urban product"
  } else if (is.na(src)) {
    "unstamped - provenance unknown"
  } else if (identical(src, as.integer(yr))) {
    "ok"
  } else {
    "substituted"
  }
  data.frame(requested_year = yr, source_year = src, status = status)
})

message("\n--- Census places provenance ---")
print(census_provenance, row.names = FALSE)

missing <- census_provenance$requested_year[
  census_provenance$status == "no Census release - no urban product"]
if (length(missing) > 0) {
  warning(paste0(
    "No Census Places for year(s) ", paste(missing, collapse = ", "),
    ".\n  Those years get forest products only; no places or urban layer is built,\n",
    "  because substitution is disabled (allow_census_year_substitution = FALSE)."
  ), call. = FALSE, immediate. = TRUE)
}

unstamped <- census_provenance$requested_year[
  census_provenance$status == "unstamped - provenance unknown"]
if (length(unstamped) > 0) {
  warning(paste0(
    "Census files for year(s) ", paste(unstamped, collapse = ", "),
    " predate provenance stamping and their true source year is unknown.\n",
    "  Run src/99_audit_census_cache.R to check them for silent fallbacks."
  ), call. = FALSE, immediate. = TRUE)
}

substituted <- census_provenance$requested_year[census_provenance$status == "substituted"]
if (length(substituted) > 0) {
  warning(paste0(
    "Census places were substituted from another year for: ",
    paste(sprintf("%d<-%d", substituted,
                  census_provenance$source_year[match(substituted, census_provenance$requested_year)]),
          collapse = ", "),
    "\n  allow_census_year_substitution is TRUE; these years' urban products do not\n",
    "  reflect their own boundaries."
  ), call. = FALSE, immediate. = TRUE)
}
