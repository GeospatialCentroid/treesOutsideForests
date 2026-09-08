# ==============================================================================
# LLR-Scale Mask Products
# ==============================================================================
# One forest mask and one urban mask per year for the whole of LRR F, rather
# than per 1km sample grid.
#
#   forest  <- NLCD classes 41/42/43, as 0 = not forest, 1 = forest
#   urban   <- US Census places (NOT an NLCD class), to stay consistent with the
#              other teams' carbon-storage metrics for forest and urban areas
#
# Both are masked to the LRR F polygon buffered by 1km, so that 30m NLCD pixels
# and the irregular LRR boundary cannot interact to clip real data at the edge.
#
# Each product is written twice:
#   - GeoTIFF on the native NLCD grid, for storage and for any pixel-level work
#   - GeoPackage polygons, which is what bridges the 30m NLCD / 1m NAIP
#     resolution gap: a polygon boundary can be intersected against any grid,
#     whereas a 30m raster can only be resampled onto one.
#
# Independent of 00-04. It reads the per-year binaries that 01_pipeline_worker.R
# already cached, so nothing is re-downloaded and no existing step changes.
#
#     Rscript src/05_llr_masks.R
# ==============================================================================

pacman::p_load(terra, sf, dplyr, purrr)

# Progress bars are written for every block of a 1.1-billion-cell raster and
# swamp the run log without saying anything useful.
terra::terraOptions(progress = 0)

# --- Configuration ------------------------------------------------------------

llr_id           <- "F"
llr_target_years <- 2009:2021

# Buffer applied to the LRR polygon before masking. 1km is comfortably more than
# one 30m NLCD pixel, so no real data is lost where the boundary cuts a pixel.
llr_buffer_m <- 1000

llr_out_dir  <- "outputs/llr_masks"
nlcd_dir     <- "data/processed/NLCD"
census_dir   <- "data/raw/census"

# Rasters stay on the native NLCD grid: reprojecting a categorical layer
# resamples it for no gain, and the polygons are the product intended for
# cross-resolution work. Vector reprojection is exact, so the polygons are
# written in the project frame. Set llr_raster_crs to reproject the rasters too.
llr_polygon_crs <- "EPSG:5070"
llr_raster_crs  <- NULL

# TRUE splits the dissolved mask into one feature per forest patch. The default
# writes a single multipolygon, which is what a mask normally wants.
llr_disaggregate <- FALSE

#' Buffered LRR Study Polygon
#'
#' @param llr_path Path to the LRR GeoPackage.
#' @param id LRR symbol to select.
#' @param buffer_m Buffer distance in metres.
#' @param crs CRS to build the polygon in.
#' @return sf single-feature polygon.
llr_study_polygon <- function(llr_path = "data/lower48LRR.gpkg", id = llr_id,
                              buffer_m = llr_buffer_m, crs = "EPSG:5070") {
  llr <- sf::st_read(llr_path, quiet = TRUE) |>
    dplyr::filter(LRRSYM == id) |>
    sf::st_transform(crs)
  if (nrow(llr) == 0) stop(paste("No LRR polygon found for symbol", id))

  # Union before buffering: buffering the parts separately and unioning after
  # leaves hairline slivers along shared internal edges.
  sf::st_sf(
    lrr = id,
    buffer_m = buffer_m,
    geometry = sf::st_buffer(sf::st_union(llr), dist = buffer_m)
  )
}

#' Clip One Year's Forest Binary to the Buffered LRR
#'
#' Reads the binary produced by reclassify_nlcd_binary(), which is already
#' 0 = not forest / 1 = forest but masked to the LRR *bounding box*. Crops and
#' masks it to the buffered LRR polygon instead.
#'
#' @param year Integer year.
#' @param study sf buffered LRR polygon.
#' @param out_dir Output directory.
#' @param overwrite Rebuild even if the output exists.
#' @return Path to the written GeoTIFF, or NULL if the input is missing.
build_llr_forest_raster <- function(year, study, out_dir = llr_out_dir,
                                    overwrite = FALSE) {
  src <- file.path(nlcd_dir, sprintf("Annual_NLCD_LndCov_%d_binary.tif", year))
  if (!file.exists(src)) {
    warning(paste("Missing NLCD binary for", year, "at", src, "- skipping."),
            call. = FALSE, immediate. = TRUE)
    return(NULL)
  }
  dest <- file.path(out_dir, sprintf("llr_%s_forest_%d.tif", llr_id, year))
  if (file.exists(dest) && !overwrite) {
    message(sprintf("  %d forest raster exists - skipping.", year))
    return(dest)
  }
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

  r <- terra::rast(src)
  study_r <- terra::project(terra::vect(study), terra::crs(r))

  # snap = "out" keeps the retained extent a superset of the study polygon; the
  # default rounds inward and can drop a partial pixel along each edge.
  tmp <- terra::crop(r, study_r, snap = "out")
  m   <- terra::mask(tmp, study_r)

  if (!is.null(llr_raster_crs)) m <- terra::project(m, llr_raster_crs, method = "near")

  names(m) <- "forest"
  terra::writeRaster(
    m, dest, overwrite = TRUE,
    datatype = "INT1U", NAflag = 255,
    gdal = c("TILED=YES", "COMPRESS=DEFLATE", "BIGTIFF=IF_SAFER")
  )
  dest
}

#' Polygonise a Forest Mask Raster
#'
#' The polygon product exists so the 30m mask can be intersected against the 1m
#' NAIP grid without being resampled onto it.
#'
#' @param tif_path Path to a forest mask GeoTIFF.
#' @param year Integer year (for naming).
#' @param out_dir Output directory.
#' @param crs CRS to write the polygons in.
#' @param disaggregate Split the dissolved mask into one feature per patch.
#' @param overwrite Rebuild even if the output exists.
#' @return Path to the written GeoPackage.
build_llr_forest_polygons <- function(tif_path, year, out_dir = llr_out_dir,
                                      crs = llr_polygon_crs,
                                      disaggregate = llr_disaggregate,
                                      overwrite = FALSE) {
  dest <- file.path(out_dir, sprintf("llr_%s_forest_%d.gpkg", llr_id, year))
  if (file.exists(dest) && !overwrite) {
    message(sprintf("  %d forest polygons exist - skipping.", year))
    return(dest)
  }

  r <- terra::rast(tif_path)
  # Only the forest cells become polygons; 0 and NA are both dropped, so the
  # layer is the mask itself rather than the mask plus its complement.
  p <- terra::as.polygons(terra::ifel(r == 1, 1L, NA), dissolve = TRUE)
  if (terra::nrow(p) == 0) {
    warning(paste("No forest cells for", year, "- writing an empty layer."),
            call. = FALSE, immediate. = TRUE)
  }
  if (disaggregate && terra::nrow(p) > 0) p <- terra::disagg(p)

  s <- sf::st_as_sf(p)
  names(s)[names(s) != attr(s, "sf_column")] <- "forest"
  s$year <- as.integer(year)
  if (!is.null(crs)) s <- sf::st_transform(s, crs)

  sf::st_write(s, dest, delete_dsn = TRUE, quiet = TRUE)
  dest
}

#' Clip One Year's Census Places to the Buffered LRR
#'
#' Census places are the urban definition for this project - NLCD developed
#' classes are deliberately not used, so that the forest and urban products line
#' up with the other teams' carbon-storage metrics.
#'
#' Writes the attributed places layer and a dissolved single-geometry urban mask
#' that parallels the forest polygons.
#'
#' @param year Integer year.
#' @param study sf buffered LRR polygon.
#' @param out_dir Output directory.
#' @param overwrite Rebuild even if the outputs exist.
#' @return Named list of written paths, or NULL if the input is missing.
build_llr_urban <- function(year, study, out_dir = llr_out_dir,
                            crs = llr_polygon_crs, overwrite = FALSE) {
  src <- file.path(census_dir, sprintf("census_places_%d.gpkg", year))
  if (!file.exists(src)) {
    warning(paste("Missing Census places for", year, "at", src, "- skipping."),
            call. = FALSE, immediate. = TRUE)
    return(NULL)
  }
  places_dest <- file.path(out_dir, sprintf("llr_%s_places_%d.gpkg", llr_id, year))
  urban_dest  <- file.path(out_dir, sprintf("llr_%s_urban_%d.gpkg", llr_id, year))
  if (file.exists(places_dest) && file.exists(urban_dest) && !overwrite) {
    message(sprintf("  %d urban outputs exist - skipping.", year))
    # Read the summary fields back off the existing layer rather than returning a
    # short list. A skip has to return the same shape as a build, or the caller's
    # data.frame() gets a zero-length column and the whole run dies partway
    # through - which is exactly when skipping matters.
    existing <- sf::st_read(places_dest, quiet = TRUE)
    return(list(
      places = places_dest, urban = urban_dest,
      n_places = nrow(existing),
      census_source_year = if ("census_source_year" %in% names(existing) &&
                               nrow(existing) > 0) {
        existing$census_source_year[1]
      } else NA_integer_
    ))
  }
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

  places <- sf::st_read(src, quiet = TRUE)
  study_p <- sf::st_transform(study, sf::st_crs(places))

  clipped <- suppressWarnings(
    sf::st_intersection(places, sf::st_geometry(study_p))
  )
  if (nrow(clipped) > 0) {
    clipped <- suppressWarnings(sf::st_collection_extract(clipped, "POLYGON"))
  }
  if (nrow(clipped) > 0) {
    clipped <- sf::st_cast(clipped, "MULTIPOLYGON", warn = FALSE)
  }
  clipped <- sf::st_transform(clipped, crs)

  # Carry the provenance stamp forward. Three cached years are substitutions
  # (2009<-2011, 2010<-2011, 2013<-2012); without this the output would claim
  # to be that year's boundaries.
  src_year <- if ("census_source_year" %in% names(clipped) && nrow(clipped) > 0) {
    clipped$census_source_year[1]
  } else NA_integer_
  if (!is.na(src_year) && !identical(as.integer(src_year), as.integer(year))) {
    warning(sprintf(
      "Census places for %d are substituted from %d; the urban mask for %d does not reflect %d boundaries.",
      year, src_year, year, year), call. = FALSE, immediate. = TRUE)
  }

  sf::st_write(clipped, places_dest, delete_dsn = TRUE, quiet = TRUE)

  urban <- if (nrow(clipped) > 0) {
    sf::st_sf(
      urban = 1L, year = as.integer(year),
      census_source_year = src_year,
      geometry = sf::st_union(clipped)
    )
  } else {
    sf::st_sf(urban = integer(0), year = integer(0),
              census_source_year = integer(0),
              geometry = sf::st_sfc(crs = sf::st_crs(clipped)))
  }
  sf::st_write(urban, urban_dest, delete_dsn = TRUE, quiet = TRUE)

  list(places = places_dest, urban = urban_dest, n_places = nrow(clipped),
       census_source_year = src_year)
}

#' Build Every LLR-Scale Product for One Year
#'
#' @param year Integer year.
#' @param study sf buffered LRR polygon.
#' @param overwrite Rebuild existing outputs.
#' @return One-row data.frame summarising what was written.
build_llr_year <- function(year, study, overwrite = FALSE) {
  message(sprintf("\n--- LRR %s, %d ---", llr_id, year))

  tif <- build_llr_forest_raster(year, study, overwrite = overwrite)
  gpkg <- if (!is.null(tif)) {
    build_llr_forest_polygons(tif, year, overwrite = overwrite)
  } else NULL
  urb <- build_llr_urban(year, study, overwrite = overwrite)

  forest_pct <- if (!is.null(tif)) {
    r <- terra::rast(tif)
    round(100 * terra::global(r, "mean", na.rm = TRUE)[[1]], 3)
  } else NA_real_

  # Any of these can be absent or zero-length; data.frame() turns a zero-length
  # column into an error rather than an NA, so coerce first.
  one <- function(x, default) if (is.null(x) || length(x) == 0) default else x[[1]]

  data.frame(
    year               = year,
    forest_raster      = one(if (is.null(tif)) NULL else basename(tif), NA_character_),
    forest_polygons    = one(if (is.null(gpkg)) NULL else basename(gpkg), NA_character_),
    forest_pct         = one(forest_pct, NA_real_),
    n_places           = one(urb$n_places, NA_integer_),
    census_source_year = one(urb$census_source_year, NA_integer_),
    stringsAsFactors   = FALSE
  )
}

# ==============================================================================
# Entry point
# ==============================================================================
if (sys.nframe() == 0) {
  message("=========================================================")
  message(sprintf("LLR-scale masks: LRR %s, %d-%d, %dm boundary buffer",
                  llr_id, min(llr_target_years), max(llr_target_years), llr_buffer_m))
  message("=========================================================")

  study <- llr_study_polygon()
  message(sprintf("Study polygon: %s km2 (LRR %s buffered by %dm)",
                  format(round(as.numeric(sum(sf::st_area(study))) / 1e6), big.mark = ","),
                  llr_id, llr_buffer_m))

  if (!dir.exists(llr_out_dir)) dir.create(llr_out_dir, recursive = TRUE)
  sf::st_write(study, file.path(llr_out_dir, sprintf("llr_%s_study_area.gpkg", llr_id)),
               delete_dsn = TRUE, quiet = TRUE)

  summary_df <- purrr::map_dfr(llr_target_years, build_llr_year, study = study)

  message("\n=========================================================")
  message("LLR-scale mask summary")
  message("=========================================================")
  print(summary_df, row.names = FALSE)
  utils::write.csv(summary_df, file.path(llr_out_dir, "llr_mask_summary.csv"),
                   row.names = FALSE)

  subs <- summary_df[!is.na(summary_df$census_source_year) &
                       summary_df$census_source_year != summary_df$year, ]
  if (nrow(subs) > 0) {
    warning(paste0(
      "Urban masks built from substituted Census years: ",
      paste(sprintf("%d<-%d", subs$year, subs$census_source_year), collapse = ", "),
      "\n  Pass this on with the data."), call. = FALSE, immediate. = TRUE)
  }
  message(sprintf("\nWrote %s/", llr_out_dir))
}
