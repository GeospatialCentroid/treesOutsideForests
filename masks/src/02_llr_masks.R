# ==============================================================================
# LLR-Scale Mask Products
# ==============================================================================
# The deliverable: one forest mask and one urban mask per year, covering the
# whole LRR.
#
#   forest  <- NLCD classes 41/42/43, as 0 = not forest, 1 = forest
#   urban   <- US Census places (NOT an NLCD class), to stay consistent with the
#              other teams' carbon-storage metrics for forest and urban areas
#   mask    <- the union of the two (they overlap), dissolved: the single mask
#              layer downstream stages take as "the masked area"
#
# A mask is only built for a year that has its own independent source layer. The
# Census does not serve every year; those years get forest products and no urban
# products, rather than an urban mask carrying a neighbouring year's boundaries
# under this year's filename. Forest is unaffected - Annual NLCD covers every
# year in the range.
#
# Both are masked to the LRR polygon buffered by 1km, so that 30m NLCD pixels
# and the irregular LRR boundary cannot interact to clip real data at the edge.
#
# Each product is written twice:
#   - GeoTIFF on the native NLCD grid, for storage and for any pixel-level work
#   - GeoPackage polygons, which is what carries the mask across a resolution
#     change: a polygon boundary can be intersected against any grid, whereas a
#     30m raster can only be resampled onto one.
#
# Reads the per-year rasters and Census layers that src/01_pipeline_worker.R
# caches. Runs either as the third step of 0_run.R or on its own:
#
#     Rscript src/02_llr_masks.R
# ==============================================================================

pacman::p_load(terra, sf, dplyr, purrr)

# How this script decides whether a cached Census file is genuinely its year.
# Sourced again here so that the script still runs on its own.
source(here::here("shared/R/setup.R"))
source(tof_root("masks/src/00_census_provenance.R"))

# Progress bars are written for every block of a 1.1-billion-cell raster and
# swamp the run log without saying anything useful.
terra::terraOptions(progress = 0)

# --- Configuration ------------------------------------------------------------

# Defer to 00_global_init.R when this runs as part of 0_run.R; fall back to the
# same values from config.yml when it is run on its own.
cfg_masks        <- tof_config()$masks
llr_id           <- get0("llr_id", ifnotfound = cfg_masks$llr_id)
llr_target_years <- get0("target_years", ifnotfound = seq(cfg_masks$years$start, cfg_masks$years$end))

# FALSE means a year without its own Census Places release gets no urban
# products at all. See allow_census_year_substitution in 00_global_init.R.
llr_allow_substitution <- get0("allow_census_year_substitution", ifnotfound = cfg_masks$allow_census_year_substitution)

# Buffer applied to the LRR polygon before masking. 1km is comfortably more than
# one 30m NLCD pixel, so no real data is lost where the boundary cuts a pixel.
llr_buffer_m <- 1000

llr_out_dir  <- tof_path(cfg_masks$paths$outputs)
nlcd_dir     <- tof_path(cfg_masks$paths$nlcd_processed)
census_dir   <- tof_path(cfg_masks$paths$census_raw)

# Rasters stay on the native NLCD grid: reprojecting a categorical layer
# resamples it for no gain, and the polygons are the product intended for
# cross-resolution work. Vector reprojection is exact, so the polygons are
# written in the project frame. Set llr_raster_crs to reproject the rasters too.
llr_polygon_crs <- tof_config()$crs
llr_raster_crs  <- NULL

# Annual NLCD is published with the CRS string "AEA        WGS84" - the same
# Albers parameters as EPSG:5070 but a WGS84 datum label and no EPSG code, so
# software reads the rasters and the polygons as two different CRSs even though
# the coordinates are identical. Relabelling (not reprojecting) puts both halves
# of the delivery in one declared frame. Only ever applied when the projection
# parameters already match; see relabel_raster_crs(). Set to NULL to keep the
# source label.
llr_raster_crs_label <- "EPSG:5070"

# Rebuild the GeoPackage products while leaving the rasters alone - what a
# change to the vector schema needs, since polygonising is the expensive step
# and the rasters are unaffected by it.
llr_overwrite_vectors <- get0("llr_overwrite_vectors", ifnotfound = FALSE)

# NLCD classes the forest mask is built from, recorded in the outputs so a file
# that travels on its own still says what it contains.
llr_forest_classes <- get0("nlcdClasses", ifnotfound = c(41, 42, 43))

# TRUE splits the dissolved mask into one feature per forest patch. The default
# writes a single multipolygon, which is what a mask normally wants.
llr_disaggregate <- FALSE

#' Relabel a Raster CRS, but Only When the Projection Really Does Match
#'
#' Assigning a CRS is not reprojecting: it changes what the file claims to be
#' without moving a single coordinate. That is the right operation for Annual
#' NLCD, whose grid is Albers on exactly EPSG:5070's parameters but carries a
#' WGS84 datum label and no EPSG code - the NAD83/WGS84 difference measures 0 m
#' here. It is the wrong operation for anything else, so the projection
#' parameters are compared first and a mismatch leaves the raster untouched.
#'
#' @param r SpatRaster.
#' @param target CRS to assign, or NULL to leave the raster alone.
#' @return The raster, relabelled or not.
relabel_raster_crs <- function(r, target = llr_raster_crs_label) {
  if (is.null(target)) return(r)

  # Compare the projection parameters, ignoring the datum and ellipsoid, which
  # are exactly what is being corrected.
  params <- function(crs_text) {
    p4 <- try(terra::crs(crs_text, proj = TRUE), silent = TRUE)
    if (inherits(p4, "try-error") || is.na(p4) || !nzchar(p4)) return(NULL)
    keep <- c("proj", "lat_0", "lon_0", "lat_1", "lat_2", "x_0", "y_0", "units")
    kv <- strsplit(sub("^\\+", "", trimws(p4)), "\\s+\\+")[[1]]
    kv <- strsplit(kv, "=")
    out <- stats::setNames(
      vapply(kv, function(x) if (length(x) > 1) x[2] else "", character(1)),
      vapply(kv, `[`, character(1), 1))
    out[intersect(keep, names(out))]
  }

  from <- params(terra::crs(r))
  to   <- params(target)
  if (is.null(from) || is.null(to) || !identical(from, to)) {
    warning(paste0("Raster CRS does not match ", target,
                   " on projection parameters; leaving its own CRS in place."),
            call. = FALSE, immediate. = TRUE)
    return(r)
  }

  terra::crs(r) <- target
  r
}

#' Buffered LRR Study Polygon
#'
#' @param llr_path Path to the LRR GeoPackage.
#' @param id LRR symbol to select.
#' @param buffer_m Buffer distance in metres.
#' @param crs CRS to build the polygon in.
#' @return sf single-feature polygon.
llr_study_polygon <- function(llr_path = tof_path(tof_config()$reference$lrr_gpkg), id = llr_id,
                              buffer_m = llr_buffer_m, crs = llr_polygon_crs) {
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
  m <- relabel_raster_crs(m)

  names(m) <- "forest"
  # Stamp the provenance into the file's own metadata. A GeoTIFF cannot carry an
  # attribute table, so this is the only place a raster that has been separated
  # from the summary CSV can say what it is.
  terra::metags(m) <- c(
    mask_type    = "forest",
    year         = as.character(year),
    lrr          = llr_id,
    source       = sprintf("Annual NLCD Land Cover %d", year),
    nlcd_classes = paste(llr_forest_classes, collapse = ","),
    values       = "0 = not forest, 1 = forest, 255 = outside study area",
    study_area   = sprintf("LRR %s buffered by %dm", llr_id, llr_buffer_m)
  )
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
  # Same provenance the raster carries in its metadata, as attributes: a layer
  # that reaches someone without the summary CSV still says what it is.
  s$year         <- as.integer(year)
  s$lrr          <- llr_id
  s$source       <- sprintf("Annual NLCD Land Cover %d", year)
  s$nlcd_classes <- paste(llr_forest_classes, collapse = ",")
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
#' that parallels the forest polygons - but only for a year whose cached Census
#' file is genuinely that year's release. A year the Census does not serve gets
#' nothing, and anything an earlier substituting run left on disk for that year
#' is removed, so the output directory cannot keep asserting a mask the policy
#' no longer allows.
#'
#' @param year Integer year.
#' @param study sf buffered LRR polygon.
#' @param out_dir Output directory.
#' @param crs CRS to write the polygons in.
#' @param overwrite Rebuild even if the outputs exist.
#' @param allow_substitution Accept a Census file stamped with another year.
#' @return Named list of written paths, or NULL when the year has no usable
#'   Census source.
build_llr_urban <- function(year, study, out_dir = llr_out_dir,
                            crs = llr_polygon_crs, overwrite = FALSE,
                            allow_substitution = llr_allow_substitution) {
  src <- file.path(census_dir, sprintf("census_places_%d.gpkg", year))
  places_dest <- file.path(out_dir, sprintf("llr_%s_places_%d.gpkg", llr_id, year))
  urban_dest  <- file.path(out_dir, sprintf("llr_%s_urban_%d.gpkg", llr_id, year))

  # The source gate. A year only gets urban products when it has an independent
  # Census release of its own; the check runs before the exists-and-skip branch
  # so that outputs from a previous, substituting run are cleared rather than
  # reported as up to date.
  if (!allow_substitution) {
    cached_source <- census_source_year_of(src)
    if (!identical(cached_source, as.integer(year))) {
      stale <- c(places_dest, urban_dest)[file.exists(c(places_dest, urban_dest))]
      if (length(stale) > 0) file.remove(stale)
      message(sprintf(
        "  %d has no Census Places release of its own (%s) - no urban products.%s",
        year,
        if (!file.exists(src)) "nothing cached"
        else if (is.na(cached_source)) "cached file is unstamped"
        else paste("cached file holds", cached_source, "boundaries"),
        if (length(stale) > 0) paste0("\n    Removed stale output(s): ",
                                      paste(basename(stale), collapse = ", ")) else ""
      ))
      return(NULL)
    }
  } else if (!file.exists(src)) {
    warning(paste("Missing Census places for", year, "at", src, "- skipping."),
            call. = FALSE, immediate. = TRUE)
    return(NULL)
  }

  # An existing output is only up to date if it was built from this year's own
  # data. Outputs written before the policy change carry a source year of their
  # own, and a stale one has to be rebuilt rather than skipped over.
  outputs_current <- file.exists(places_dest) && file.exists(urban_dest) &&
    (allow_substitution || census_is_independent(places_dest, year))

  if (outputs_current && !overwrite) {
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
      } else NA_integer_,
      census_boundary_type = census_boundary_type_of(existing)
    ))
  }
  if (file.exists(places_dest) && !outputs_current) {
    message(sprintf("  %d urban outputs were built from other data - rebuilding.", year))
  }
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

  places <- sf::st_read(src, quiet = TRUE)
  study_p <- sf::st_transform(study, sf::st_crs(places))

  # Carried through the intersection so each surviving place can be compared
  # against its own uncut geometry. Measuring against ALAND instead would mix
  # the clip with cartographic generalisation - a generalised place differs from
  # its published area by a percent or two, which is the same order as a light
  # clip and would flag dozens of untouched places in the cb years.
  places$.uncut_area <- as.numeric(sf::st_area(places))

  clipped <- suppressWarnings(
    sf::st_intersection(places, sf::st_geometry(study_p))
  )
  if (nrow(clipped) > 0) {
    clipped <- suppressWarnings(sf::st_collection_extract(clipped, "POLYGON"))
  }
  if (nrow(clipped) > 0) {
    clipped <- sf::st_cast(clipped, "MULTIPOLYGON", warn = FALSE)
  }

  # Computed before the reprojection, while both areas are in the same frame.
  # ALAND and AWATER still describe the whole place as the Census published it,
  # so this is the only field that says how much of it is actually here.
  if (nrow(clipped) > 0) {
    retained <- as.numeric(sf::st_area(clipped)) / clipped$.uncut_area
    clipped$area_retained <- ifelse(is.finite(retained), round(pmin(retained, 1), 4), NA_real_)
  }
  clipped$.uncut_area <- NULL

  clipped <- sf::st_transform(clipped, crs)

  # Carry the provenance stamp forward. With substitution disabled this always
  # equals `year` - the gate above guarantees it - but the column stays in the
  # output so a consumer can verify provenance from the data itself rather than
  # from the filename, and so the layer is still self-describing if someone
  # re-enables substitution.
  src_year <- if ("census_source_year" %in% names(clipped) && nrow(clipped) > 0) {
    clipped$census_source_year[1]
  } else NA_integer_
  if (!is.na(src_year) && !identical(as.integer(src_year), as.integer(year))) {
    warning(sprintf(
      "Census places for %d are substituted from %d; the urban mask for %d does not reflect %d boundaries.",
      year, src_year, year, year), call. = FALSE, immediate. = TRUE)
  }

  # Which of the year's two published products this came from. Layers cached
  # before the download step stamped it are identified from their schema, so
  # every delivered layer carries the field regardless of when it was fetched.
  boundary_type <- census_boundary_type_of(clipped)
  clipped$census_boundary_type <- boundary_type

  sf::st_write(clipped, places_dest, delete_dsn = TRUE, quiet = TRUE)

  urban <- if (nrow(clipped) > 0) {
    sf::st_sf(
      urban = 1L, year = as.integer(year), lrr = llr_id,
      n_places = nrow(clipped),
      census_source_year = src_year,
      census_boundary_type = boundary_type,
      geometry = sf::st_union(clipped)
    )
  } else {
    sf::st_sf(urban = integer(0), year = integer(0), lrr = character(0),
              n_places = integer(0), census_source_year = integer(0),
              census_boundary_type = character(0),
              geometry = sf::st_sfc(crs = sf::st_crs(clipped)))
  }
  sf::st_write(urban, urban_dest, delete_dsn = TRUE, quiet = TRUE)

  list(places = places_dest, urban = urban_dest, n_places = nrow(clipped),
       census_source_year = src_year, census_boundary_type = boundary_type)
}

#' Combine One Year's Forest and Urban Masks into a Single Mask
#'
#' The forest and urban masks come from different definitions and overlap (a
#' wooded park inside a city is in both), so anything that needs "the masked
#' area" has to union them. This writes that union once, as the primary mask
#' product for the years downstream, in the same two forms as the forest mask:
#'
#'   - GeoPackage: one dissolved multipolygon, the exact union of the forest
#'     polygons and the dissolved places. The urban side keeps its vector
#'     precision, so this is the authoritative product.
#'   - GeoTIFF on the NLCD grid: 1 = forest or place, 0 = neither, for pixel
#'     work and maps. The places are rasterised at 30 m (a pixel is in when its
#'     centre is), so its area differs slightly from the polygon's.
#'
#' A year without an urban product gets a mask that is the forest alone, and
#' the layer's attributes say so (n_places NA, census fields NA).
#'
#' The mask is rebuilt whenever it is older than either input, so a rebuilt
#' urban layer cannot leave a stale union behind.
#'
#' @param year Integer year.
#' @param forest_gpkg Path to the year's forest polygons.
#' @param forest_tif Path to the year's forest raster.
#' @param urban_gpkg Path to the year's dissolved urban mask, or NULL.
#' @param out_dir Output directory.
#' @param crs CRS to write the polygons in.
#' @param overwrite Rebuild even if the outputs exist and are current.
#' @return Named list: polygons, raster, forest_m2, urban_m2, overlap_m2,
#'   mask_m2, mask_pct; or NULL when there is no forest product.
build_llr_mask <- function(year, forest_gpkg, forest_tif, urban_gpkg = NULL,
                           out_dir = llr_out_dir, crs = llr_polygon_crs,
                           overwrite = FALSE) {
  if (is.null(forest_gpkg) || is.null(forest_tif)) return(NULL)
  poly_dest <- file.path(out_dir, sprintf("llr_%s_mask_%d.gpkg", llr_id, year))
  tif_dest  <- file.path(out_dir, sprintf("llr_%s_mask_%d.tif",  llr_id, year))

  inputs  <- c(forest_gpkg, forest_tif, urban_gpkg)
  current <- file.exists(poly_dest) && file.exists(tif_dest) &&
    all(file.mtime(poly_dest) >= file.mtime(inputs)) &&
    all(file.mtime(tif_dest)  >= file.mtime(inputs))
  if (current && !overwrite) {
    message(sprintf("  %d combined mask exists - skipping.", year))
    existing <- sf::st_drop_geometry(sf::st_read(poly_dest, quiet = TRUE))
    return(list(polygons = poly_dest, raster = tif_dest,
                forest_m2 = existing$forest_m2[1], urban_m2 = existing$urban_m2[1],
                overlap_m2 = existing$overlap_m2[1], mask_m2 = existing$mask_m2[1],
                mask_pct = existing$mask_pct[1]))
  }
  if (file.exists(poly_dest) && !current) {
    message(sprintf("  %d combined mask is older than its inputs - rebuilding.", year))
  }

  forest <- sf::st_read(forest_gpkg, quiet = TRUE) |> sf::st_transform(crs)
  urban  <- if (!is.null(urban_gpkg) && file.exists(urban_gpkg)) {
    u <- sf::st_read(urban_gpkg, quiet = TRUE)
    if (nrow(u) > 0) sf::st_transform(u, crs) else NULL
  } else NULL

  forest_geom <- sf::st_union(sf::st_geometry(forest))
  forest_m2   <- as.numeric(sf::st_area(forest_geom))
  if (!is.null(urban)) {
    message(sprintf("  %d combined mask: union of forest and urban polygons...", year))
    urban_geom <- sf::st_union(sf::st_geometry(urban))
    mask_geom  <- sf::st_union(forest_geom, urban_geom)
    urban_m2   <- as.numeric(sf::st_area(urban_geom))
  } else {
    message(sprintf("  %d combined mask: no urban product, mask is the forest alone.", year))
    mask_geom <- forest_geom
    urban_m2  <- 0
  }
  mask_geom <- sf::st_cast(mask_geom, "MULTIPOLYGON")
  mask_m2   <- as.numeric(sf::st_area(mask_geom))
  # The masks are not exclusive: the overlap is what the sum over-counts.
  overlap_m2 <- forest_m2 + urban_m2 - mask_m2

  one <- function(x, default) if (is.null(x) || length(x) == 0 || all(is.na(x))) default else x[[1]]
  mask <- sf::st_sf(
    mask       = 1L,
    year       = as.integer(year),
    lrr        = llr_id,
    forest_source = one(forest$source, sprintf("Annual NLCD Land Cover %d", year)),
    nlcd_classes  = one(forest$nlcd_classes, paste(llr_forest_classes, collapse = ",")),
    urban_source  = if (is.null(urban)) NA_character_ else sprintf("US Census places %d", year),
    n_places             = if (is.null(urban)) NA_integer_ else one(urban$n_places, NA_integer_),
    census_source_year   = if (is.null(urban)) NA_integer_ else one(urban$census_source_year, NA_integer_),
    census_boundary_type = if (is.null(urban)) NA_character_ else one(urban$census_boundary_type, NA_character_),
    forest_m2  = forest_m2,
    urban_m2   = urban_m2,
    overlap_m2 = overlap_m2,
    mask_m2    = mask_m2,
    mask_pct   = NA_real_,          # filled from the raster below
    geometry   = mask_geom
  )

  # Raster: the forest binary OR the places burnt onto the same grid.
  r <- terra::rast(forest_tif)
  m <- if (!is.null(urban)) {
    u_v <- terra::project(terra::vect(urban), terra::crs(r))
    u_r <- terra::rasterize(u_v, r, field = 1, background = 0)
    terra::mask(max(r, u_r), r)
  } else r
  names(m) <- "mask"
  mask$mask_pct <- round(100 * terra::global(m, "mean", na.rm = TRUE)[[1]], 3)
  terra::metags(m) <- c(
    mask_type    = "forest_or_urban",
    year         = as.character(year),
    lrr          = llr_id,
    source       = paste(c(mask$forest_source, mask$urban_source[!is.na(mask$urban_source)]), collapse = "; "),
    nlcd_classes = mask$nlcd_classes,
    # No "=" inside a tag value and no tag called "values": terra 1.9 drops the
    # whole tag set silently on either (the forest raster's tags predate that).
    legend       = "0 neither forest nor place, 1 forest or place, 255 outside study area",
    study_area   = sprintf("LRR %s buffered by %dm", llr_id, llr_buffer_m),
    note         = "Places rasterised at 30 m; the GeoPackage of the same name is the exact union"
  )
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  terra::writeRaster(
    m, tif_dest, overwrite = TRUE,
    datatype = "INT1U", NAflag = 255,
    gdal = c("TILED=YES", "COMPRESS=DEFLATE", "BIGTIFF=IF_SAFER")
  )
  sf::st_write(mask, poly_dest, delete_dsn = TRUE, quiet = TRUE)

  list(polygons = poly_dest, raster = tif_dest,
       forest_m2 = forest_m2, urban_m2 = urban_m2, overlap_m2 = overlap_m2,
       mask_m2 = mask_m2, mask_pct = mask$mask_pct)
}

#' Build Every LLR-Scale Product for One Year
#'
#' @param year Integer year.
#' @param study sf buffered LRR polygon.
#' @param overwrite Rebuild existing outputs, rasters included.
#' @param overwrite_vectors Rebuild only the GeoPackage products, which is what
#'   a change to the vector schema needs - the rasters are unaffected and
#'   re-cropping them is the expensive half of a run. The combined mask (both
#'   forms) is rebuilt too, since it is derived from the vectors.
#' @return One-row data.frame summarising what was written.
build_llr_year <- function(year, study, overwrite = FALSE,
                           overwrite_vectors = llr_overwrite_vectors) {
  message(sprintf("\n--- LRR %s, %d ---", llr_id, year))

  vectors <- overwrite || overwrite_vectors
  tif <- build_llr_forest_raster(year, study, overwrite = overwrite)
  gpkg <- if (!is.null(tif)) {
    build_llr_forest_polygons(tif, year, overwrite = vectors)
  } else NULL
  urb <- build_llr_urban(year, study, overwrite = vectors)
  msk <- build_llr_mask(year, forest_gpkg = gpkg, forest_tif = tif,
                        urban_gpkg = if (is.null(urb)) NULL else urb$urban,
                        overwrite = vectors)

  forest_pct <- if (!is.null(tif)) {
    r <- terra::rast(tif)
    round(100 * terra::global(r, "mean", na.rm = TRUE)[[1]], 3)
  } else NA_real_

  # Any of these can be absent or zero-length; data.frame() turns a zero-length
  # column into an error rather than an NA, so coerce first.
  one <- function(x, default) if (is.null(x) || length(x) == 0) default else x[[1]]

  # A year with no Census release of its own is reported as such rather than as
  # a blank row: "no independent Census release" and "the step failed" are
  # different facts and the summary is what gets passed on with the data.
  census_status <- if (!is.null(urb)) {
    if (identical(as.integer(one(urb$census_source_year, NA_integer_)), as.integer(year))) {
      "ok"
    } else {
      sprintf("substituted from %s", one(urb$census_source_year, NA_integer_))
    }
  } else {
    "no independent Census release - no urban product"
  }

  data.frame(
    year               = year,
    forest_raster      = one(if (is.null(tif)) NULL else basename(tif), NA_character_),
    forest_polygons    = one(if (is.null(gpkg)) NULL else basename(gpkg), NA_character_),
    forest_pct         = one(forest_pct, NA_real_),
    places_polygons    = one(if (is.null(urb)) NULL else basename(urb$places), NA_character_),
    urban_polygons     = one(if (is.null(urb)) NULL else basename(urb$urban), NA_character_),
    n_places           = one(urb$n_places, NA_integer_),
    census_source_year = one(urb$census_source_year, NA_integer_),
    census_boundary_type = one(urb$census_boundary_type, NA_character_),
    census_status      = census_status,
    mask_polygons      = one(if (is.null(msk)) NULL else basename(msk$polygons), NA_character_),
    mask_raster        = one(if (is.null(msk)) NULL else basename(msk$raster), NA_character_),
    mask_pct           = one(msk$mask_pct, NA_real_),
    forest_km2         = round(one(msk$forest_m2, NA_real_) / 1e6, 2),
    urban_km2          = round(one(msk$urban_m2, NA_real_) / 1e6, 2),
    overlap_km2        = round(one(msk$overlap_m2, NA_real_) / 1e6, 2),
    mask_km2           = round(one(msk$mask_m2, NA_real_) / 1e6, 2),
    stringsAsFactors   = FALSE
  )
}

# ==============================================================================
# Entry point
# ==============================================================================
# Runs both as `Rscript src/02_llr_masks.R` and as the third step of 0_run.R.
# sys.nframe() == 0 is only true of the first: source() adds a frame, so under
# 0_run.R this file defined its functions and built nothing. Testing the
# evaluation environment instead is true for both, and false only when the file
# is sourced with local = TRUE to borrow its functions.
if (identical(environment(), globalenv())) {
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

  # Years the Census does not serve are a property of the deliverable, not an
  # error: say so once, plainly, at the end of the run.
  no_urban <- summary_df$year[is.na(summary_df$urban_polygons)]
  if (length(no_urban) > 0) {
    message("\n--- Years with forest products only ---")
    message("  ", paste(no_urban, collapse = ", "),
            " have no independent Census Places release, so no places or urban")
    message("  layer was built for them. The forest products for those years are")
    message("  unaffected. Set allow_census_year_substitution <- TRUE to build them")
    message("  from a neighbouring year instead.")
  }

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
