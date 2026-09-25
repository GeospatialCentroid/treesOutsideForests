# ==============================================================================
# Any-Year Combined Mask
# ==============================================================================
# One mask for the whole period: every area that was forest or a Census place
# in *any* year of the run, aggregated from the per-year combined masks that
# src/02_llr_masks.R writes (llr_<LRR>_mask_<year>.gpkg / .tif).
#
#   mask_any <- union over years of (forest_year OR urban_year)
#
# The per-year masks move: NLCD forest flickers at the pixel level from one
# release to the next, and places grow (or are redrawn) between Census vintages.
# A stage that wants one fixed "never eligible" footprint across the period -
# rather than a footprint that changes with the year - takes this layer.
#
# Written in the same two forms as the per-year mask, with the same roles:
#   - GeoPackage: the exact union of the per-year mask polygons, one dissolved
#     multipolygon in the project CRS. The authoritative product.
#   - GeoTIFF on the NLCD grid: the per-pixel maximum over the per-year mask
#     rasters, 1 = forest or place in at least one year, 0 = never, 255 outside
#     the study area. The places are rasterised at 30 m in every year, so its
#     area differs slightly from the polygon's, exactly as for the per-year mask.
#
# Every configured year must have a combined mask. A missing year would
# silently narrow what "any year" means, so the run stops and names the gap
# rather than building a product that claims a period it does not cover.
#
# Runs as the fourth step of 0_run.R or on its own, once 02_llr_masks.R has
# written the per-year products:
#
#     Rscript masks/src/03_llr_mask_any_year.R
# ==============================================================================

pacman::p_load(terra, sf, dplyr, purrr)

source(here::here("shared/R/setup.R"))
terra::terraOptions(progress = 0)

# --- Configuration ------------------------------------------------------------

# Defer to 00_global_init.R when this runs as part of 0_run.R; fall back to the
# same values from config.yml when it is run on its own.
cfg_masks         <- tof_config()$masks
llr_id            <- get0("llr_id", ifnotfound = cfg_masks$llr_id)
llr_target_years  <- get0("target_years", ifnotfound = seq(cfg_masks$years$start, cfg_masks$years$end))
llr_out_dir       <- tof_path(cfg_masks$paths$outputs)
llr_polygon_crs   <- tof_config()$crs
llr_buffer_m      <- get0("llr_buffer_m", ifnotfound = 1000)
llr_forest_classes <- get0("nlcdClasses", ifnotfound = cfg_masks$nlcd_classes)

# Rebuild even when the outputs exist and are newer than every per-year input.
llr_overwrite_any <- get0("llr_overwrite_any", ifnotfound = FALSE)

#' Output Paths of the Any-Year Mask
#'
#' The filename carries the period so the file says what it spans on its own,
#' and it cannot be read as a single year by anything that formats
#' llr_<LRR>_mask_<year>.
#'
#' @param years Integer years the mask aggregates.
#' @param out_dir Output directory.
#' @return Named list: polygons, raster.
llr_mask_any_paths <- function(years = llr_target_years, out_dir = llr_out_dir) {
  stem <- sprintf("llr_%s_mask_any_%d_%d", llr_id, min(years), max(years))
  list(polygons = file.path(out_dir, paste0(stem, ".gpkg")),
       raster   = file.path(out_dir, paste0(stem, ".tif")))
}

#' Union the Per-Year Combined Masks into One Any-Year Mask
#'
#' @param years Integer years to aggregate; every one must have a combined mask.
#' @param out_dir Directory holding the per-year masks; the outputs go there too.
#' @param crs CRS to write the polygons in.
#' @param overwrite Rebuild even if the outputs exist and are current.
#' @return Named list: polygons, raster, mask_m2, mask_pct, n_years,
#'   max_year_mask_m2, max_year.
build_llr_mask_any_year <- function(years = llr_target_years, out_dir = llr_out_dir,
                                    crs = llr_polygon_crs,
                                    overwrite = llr_overwrite_any) {
  years <- sort(as.integer(years))
  gpkgs <- file.path(out_dir, sprintf("llr_%s_mask_%d.gpkg", llr_id, years))
  tifs  <- file.path(out_dir, sprintf("llr_%s_mask_%d.tif",  llr_id, years))

  missing <- years[!(file.exists(gpkgs) & file.exists(tifs))]
  if (length(missing) > 0) {
    stop(sprintf(
      "No combined mask for %s in %s. Every year in %d-%d needs one before they can be aggregated; run masks/src/02_llr_masks.R first.",
      paste(missing, collapse = ", "), out_dir, min(years), max(years)), call. = FALSE)
  }

  dest <- llr_mask_any_paths(years, out_dir)
  inputs  <- c(gpkgs, tifs)
  current <- file.exists(dest$polygons) && file.exists(dest$raster) &&
    all(file.mtime(dest$polygons) >= file.mtime(inputs)) &&
    all(file.mtime(dest$raster)   >= file.mtime(inputs))
  if (current && !overwrite) {
    message(sprintf("  Any-year mask %d-%d exists and is current - skipping.", min(years), max(years)))
    existing <- sf::st_drop_geometry(sf::st_read(dest$polygons, quiet = TRUE))
    return(list(polygons = dest$polygons, raster = dest$raster,
                mask_m2 = existing$mask_m2[1], mask_pct = existing$mask_pct[1],
                n_years = existing$n_years[1],
                max_year_mask_m2 = existing$max_year_mask_m2[1],
                max_year = existing$max_year[1]))
  }
  if (file.exists(dest$polygons) && !current) {
    message("  Any-year mask is older than a per-year mask - rebuilding.")
  }

  # --- Polygons: the exact union ---------------------------------------------
  message(sprintf("  Reading %d per-year combined masks...", length(years)))
  per_year <- purrr::map(gpkgs, function(p) sf::st_read(p, quiet = TRUE) |> sf::st_transform(crs))
  attrs    <- purrr::map_dfr(per_year, sf::st_drop_geometry)

  # The years each mask half actually came from, read off the layers rather
  # than assumed: with Census substitution enabled a mask can carry another
  # year's places, and the aggregate should say so.
  census_years <- sort(unique(attrs$census_source_year[!is.na(attrs$census_source_year)]))
  years_no_urban <- attrs$year[is.na(attrs$urban_source)]

  geoms <- do.call(c, purrr::map(per_year, sf::st_geometry))
  message(sprintf("  Union of %d multipolygons (%s vertices)...",
                  length(geoms),
                  format(sum(vapply(geoms, function(g) sum(vapply(g, function(p) sum(vapply(p, nrow, 1L)), 1L)), 1L)),
                         big.mark = ",")))
  t0 <- Sys.time()
  # One unary (cascaded) union of the whole set: far cheaper than folding the
  # years in one at a time, where the accumulator grows with every step.
  any_geom <- sf::st_union(geoms)
  any_geom <- sf::st_cast(any_geom, "MULTIPOLYGON")
  if (!all(sf::st_is_valid(any_geom))) any_geom <- sf::st_make_valid(any_geom)
  message(sprintf("  Union done in %.1f min.", as.numeric(difftime(Sys.time(), t0, units = "mins"))))

  mask_m2 <- as.numeric(sf::st_area(any_geom))
  max_i   <- which.max(attrs$mask_m2)

  mask <- sf::st_sf(
    mask        = 1L,
    lrr         = llr_id,
    period      = sprintf("%d-%d", min(years), max(years)),
    year_start  = min(years),
    year_end    = max(years),
    n_years     = length(years),
    years       = paste(years, collapse = ","),
    definition  = "forest or Census place in at least one year",
    forest_source = sprintf("Annual NLCD Land Cover %d-%d", min(years), max(years)),
    nlcd_classes  = paste(llr_forest_classes, collapse = ","),
    urban_source  = if (length(census_years) > 0) {
      sprintf("US Census places %s", paste(census_years, collapse = ","))
    } else NA_character_,
    years_without_urban = if (length(years_no_urban) > 0) paste(years_no_urban, collapse = ",") else NA_character_,
    mask_m2     = mask_m2,
    max_year_mask_m2 = attrs$mask_m2[max_i],   # largest single-year mask, for scale
    max_year    = attrs$year[max_i],
    mask_pct    = NA_real_,                     # filled from the raster below
    geometry    = any_geom
  )

  # --- Raster: per-pixel maximum over the years ------------------------------
  message("  Per-pixel maximum over the per-year mask rasters...")
  s <- terra::rast(tifs)
  # Written straight to a scratch file beside the outputs rather than through
  # terra's temp directory: a 1.1-billion-cell result does not fit in a small
  # /tmp, and a temp file that runs out of space came back with garbage in a
  # few hundred cells instead of an error. The final write below adds the tags.
  scratch <- sub("\\.tif$", ".building.tif", dest$raster)
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  terra::app(s, fun = "max", filename = scratch, overwrite = TRUE,
             wopt = list(datatype = "INT1U", NAflag = 255,
                         gdal = c("TILED=YES", "COMPRESS=DEFLATE", "BIGTIFF=IF_SAFER")))
  m <- terra::rast(scratch)
  names(m) <- "mask"
  # The maximum of 0/1 layers can only be 0 or 1: anything else is a corrupt
  # write, and the product must not go out carrying it.
  found <- terra::freq(m)
  bad   <- found[!(found$value %in% c(0, 1)), ]
  if (nrow(bad) > 0) {
    stop(sprintf("Any-year raster holds values other than 0/1 (%s); the write was corrupt.",
                 paste(sprintf("%s x%d", bad$value, bad$count), collapse = ", ")), call. = FALSE)
  }
  mask$mask_pct <- round(100 * terra::global(m, "mean", na.rm = TRUE)[[1]], 3)
  terra::metags(m) <- c(
    mask_type    = "forest_or_urban_any_year",
    period       = mask$period,
    years        = mask$years,
    lrr          = llr_id,
    source       = paste(c(mask$forest_source, mask$urban_source[!is.na(mask$urban_source)]), collapse = "; "),
    nlcd_classes = mask$nlcd_classes,
    # No "=" inside a tag value and no tag called "values": terra 1.9 drops the
    # whole tag set silently on either.
    legend       = "0 never forest nor place, 1 forest or place in at least one year, 255 outside study area",
    study_area   = sprintf("LRR %s buffered by %dm", llr_id, llr_buffer_m),
    note         = "Maximum over the per-year mask rasters; the GeoPackage of the same name is the exact union"
  )
  terra::writeRaster(
    m, dest$raster, overwrite = TRUE,
    datatype = "INT1U", NAflag = 255,
    gdal = c("TILED=YES", "COMPRESS=DEFLATE", "BIGTIFF=IF_SAFER")
  )
  rm(m); file.remove(scratch)
  sf::st_write(mask, dest$polygons, delete_dsn = TRUE, quiet = TRUE)

  list(polygons = dest$polygons, raster = dest$raster,
       mask_m2 = mask_m2, mask_pct = mask$mask_pct, n_years = length(years),
       max_year_mask_m2 = mask$max_year_mask_m2, max_year = mask$max_year)
}

# ==============================================================================
# Entry point
# ==============================================================================
# True both under Rscript and when sourced from 0_run.R; false only when the
# file is sourced with local = TRUE to borrow its functions (see 02_llr_masks.R).
if (identical(environment(), globalenv())) {
  message("=========================================================")
  message(sprintf("Any-year combined mask: LRR %s, %d-%d",
                  llr_id, min(llr_target_years), max(llr_target_years)))
  message("=========================================================")

  res <- build_llr_mask_any_year()

  message("\n--- Any-year mask ---")
  message(sprintf("  %s\n  %s", res$polygons, res$raster))
  message(sprintf("  Union over %d years: %s km2 (%.3f%% of the study area, from the raster)",
                  res$n_years, format(round(res$mask_m2 / 1e6, 2), big.mark = ","), res$mask_pct))
  message(sprintf("  Largest single year (%d): %s km2; the union adds %s km2 (%.1f%%) over it",
                  res$max_year, format(round(res$max_year_mask_m2 / 1e6, 2), big.mark = ","),
                  format(round((res$mask_m2 - res$max_year_mask_m2) / 1e6, 2), big.mark = ","),
                  100 * (res$mask_m2 - res$max_year_mask_m2) / res$max_year_mask_m2))
}
