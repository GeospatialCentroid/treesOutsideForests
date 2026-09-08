# ==============================================================================
# NAIP-Aligned Mask Products
# ==============================================================================
# Produces forest masks on the exact raster grid of the naipScrape
# naip_1.5km_*.tif imagery, so that a U-Net classification of that imagery can be
# laid over the mask pixel for pixel with no resampling.
#
# The grid comes from src/03_naip_reference.R: given the EPSG code of the NAIP
# tile used at a site, naip_template() reproduces naipScrape's output grid
# exactly (verified against all 46 exports in naipScrape/data/exportData).
#
# Differences from process_grid() in 02_run_pipeline.R:
#   - output CRS is the site's NAD83 UTM zone, not EPSG:5070
#   - output extent is the 250m-buffered AOI, not the bare 1km cell
#   - a raster mask is written alongside the vector, because pixel alignment is
#     the point and a polygon layer cannot express it
#   - the year processed is the NAIP actual_year, not the requested year
#
# See NAIP_ALIGNMENT.md.
# ==============================================================================

pacman::p_load(terra, sf, jsonlite, dplyr, purrr)

source("src/03_naip_reference.R")   # naip_template(), grid_record()

#' Build NAIP-Aligned Mask Products for One Site-Year
#'
#' @param grid_row Single-row sf 1km grid feature.
#' @param epsg Integer EPSG of the site's NAIP grid (from the reference JSON).
#' @param nlcd_path Path to the binary NLCD GeoTIFF for `year`.
#' @param census_llr sf Census Places dataset in its native CRS.
#' @param out_dir Directory to write outputs to.
#' @param year NAIP actual_year being produced.
#' @param buffer_m Buffer matching naipScrape (250).
#' @param crop_margin Extra margin (m) on the NLCD crop, on top of the buffer.
#'   30m is one NLCD cell, which absorbs the datum shift between the NLCD grid
#'   (Albers on WGS84) and the analysis CRS (Albers on NAD83).
#' @param write_vector Also write the dissolved forest polygons.
#' @return List describing what was written, or a list with `status = "failed"`.
process_grid_naip <- function(grid_row, epsg, nlcd_path, census_llr, out_dir, year,
                              buffer_m = 250, crop_margin = 30,
                              write_vector = TRUE, log_dir = "outputs/logs") {
  grid_id <- grid_row$id[1]
  tryCatch({
    if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

    tif_out    <- file.path(out_dir, sprintf("mask_1.5km_%s_%s.tif", grid_id, year))
    gpkg_out   <- file.path(out_dir, sprintf("mask_1.5km_%s_%s_NLCD_Forest.gpkg", grid_id, year))
    census_out <- file.path(out_dir, sprintf("mask_1.5km_%s_%s_Census.gpkg", grid_id, year))

    # The grid naipScrape produced for this site.
    tmpl    <- naip_template(grid_row, epsg, buffer_m = buffer_m, which = "buffered")
    crs_str <- terra::crs(tmpl)

    # Buffer first, then crop: the NLCD window has to cover the whole buffered
    # footprint, not just the 1km cell. Buffering in the grid's own CRS (5070)
    # and then projecting matches what mergeAndExportNAIP() does, so the mask
    # footprint and the NAIP footprint are the same polygon.
    aoi_buf      <- sf::st_buffer(grid_row, dist = buffer_m)
    aoi_buf_proj <- terra::project(terra::vect(sf::st_geometry(aoi_buf)), crs_str)

    nlcd_llr  <- terra::rast(nlcd_path)
    aoi_nlcd  <- sf::st_transform(aoi_buf, terra::crs(nlcd_llr))
    crop_ext  <- terra::ext(aoi_nlcd)
    if (crop_margin > 0) crop_ext <- terra::extend(crop_ext, crop_margin)
    # snap = "out" keeps the retained extent a superset of the request; the
    # default rounds inward and leaves an NA strip along the edges.
    nlcd_crop <- terra::crop(nlcd_llr, crop_ext, snap = "out")

    # One reprojection of the 30m source straight onto the NAIP grid.
    nlcd_proj <- terra::project(nlcd_crop, tmpl, method = "near")

    # Match the NAIP footprint: mergeAndExportNAIP() masks to the same
    # round-joined buffer polygon, so "outside the AOI" agrees on both sides.
    mask_r <- terra::mask(nlcd_proj, aoi_buf_proj)
    names(mask_r) <- "forest"

    terra::writeRaster(
      mask_r, tif_out, overwrite = TRUE,
      datatype = "INT1U", NAflag = 255,
      gdal = c("TILED=YES", "COMPRESS=DEFLATE")
    )

    if (write_vector) {
      forest_only <- terra::ifel(mask_r == 1, 1, NA)
      terra::writeVector(terra::as.polygons(forest_only, dissolve = TRUE),
                         gpkg_out, overwrite = TRUE)
    }

    # Census clipped to the buffered footprint, not the 1km cell, or the outer
    # ring of every product is undefined.
    aoi_buf_native <- sf::st_transform(aoi_buf, sf::st_crs(census_llr))
    census_crop <- suppressWarnings(
      sf::st_intersection(census_llr, sf::st_geometry(aoi_buf_native))
    )
    if (nrow(census_crop) > 0) {
      census_crop <- suppressWarnings(sf::st_collection_extract(census_crop, "POLYGON"))
    }
    if (nrow(census_crop) > 0) {
      census_crop <- sf::st_cast(census_crop, "MULTIPOLYGON", warn = FALSE)
    }
    sf::st_write(sf::st_transform(census_crop, crs_str), census_out,
                 delete_dsn = TRUE, quiet = TRUE)

    list(status = "ok", id = grid_id, year = year, epsg = epsg,
         tif = tif_out, ncol = terra::ncol(mask_r), nrow = terra::nrow(mask_r))
  }, error = function(e) {
    tryCatch({
      if (!dir.exists(log_dir)) dir.create(log_dir, recursive = TRUE)
      writeLines(
        c(paste("grid_id:", grid_id), paste("year:", year), paste("epsg:", epsg),
          paste("time:", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
          paste("error:", conditionMessage(e))),
        file.path(log_dir, sprintf("fail_naip_%s_%s.txt", grid_id, year))
      )
    }, error = function(e2) NULL)
    list(status = "failed", id = grid_id, year = year,
         message = conditionMessage(e))
  })
}

#' Verify a Mask Against the NAIP Image It Is Meant to Overlay
#'
#' Geometry agreement is the pass/fail criterion. The NoData comparison is
#' diagnostic: it reports whether the two products also agree on which pixels
#' fall outside the AOI, which geometry alone does not guarantee.
#'
#' @param mask_path Path to the written mask GeoTIFF.
#' @param naip_path Path to the corresponding naip_1.5km_*.tif.
#' @return One-row data.frame of comparison results.
verify_against_naip <- function(mask_path, naip_path) {
  m <- terra::rast(mask_path)
  n <- terra::rast(naip_path)

  geom_ok <- isTRUE(terra::compareGeom(m, n, crs = TRUE, ext = TRUE, rowcol = TRUE,
                                       res = TRUE, stopOnError = FALSE))

  na_agree <- NA_real_
  if (geom_ok) {
    # NAIP carries NAflag 255 on band 1; the mask carries it too. Where both are
    # NA, or neither is, the two footprints agree.
    mn <- is.na(terra::values(m[[1]]))
    nn <- is.na(terra::values(n[[1]]))
    na_agree <- mean(mn == nn) * 100
  }

  data.frame(
    mask = basename(mask_path),
    naip = basename(naip_path),
    geom_match = geom_ok,
    mask_dim = paste(dim(m)[2], dim(m)[1], sep = "x"),
    naip_dim = paste(dim(n)[2], dim(n)[1], sep = "x"),
    nodata_agreement_pct = round(na_agree, 3),
    forest_pct = round(mean(terra::values(m[[1]]) == 1, na.rm = TRUE) * 100, 2),
    stringsAsFactors = FALSE
  )
}
