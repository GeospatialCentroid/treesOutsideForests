# ==============================================================================
# Phase 1: Configuration
# ==============================================================================
pacman::p_load(terra, sf, tigris, dplyr, purrr)

# Define core parameters
target_years <- c(2009:2021)
nlcdClasses <- c(41, 42, 43) # Forest classes
llr_id <- "F"

# CRS the LRR boundary is held in. Rasters stay on their source grid; only
# vector geometry is transformed, and that is exact.
analysis_crs <- "EPSG:5070"

# Margin (metres) added around the LLR bounding box when clipping the national
# NLCD rasters, and when deciding which states overlap the LLR for the Census
# download. The final products are clipped to a tighter buffer of the LLR
# polygon itself (see src/02_llr_masks.R); this margin only governs how much
# surrounding data the intermediates retain.
study_area_margin <- 5000

# read in required data
## LLR areas, kept in the analysis CRS so that all downstream extents are
## computed in projected space rather than in degrees.
llr <- sf::st_read("data/lower48LRR.gpkg", quiet = TRUE) |>
  dplyr::filter(LRRSYM == llr_id) |>
  sf::st_transform(analysis_crs)

## Study area for the intermediates: the LLR bounding box, buffered, built in
## the analysis CRS. Building this in EPSG:4326 and reprojecting produces a
## four-vertex polygon whose straight edges cut inside the true extent, silently
## masking data along the north and south margins.
bbox_llr <- sf::st_bbox(llr)
bbox_llr[c("xmin", "ymin")] <- bbox_llr[c("xmin", "ymin")] - study_area_margin
bbox_llr[c("xmax", "ymax")] <- bbox_llr[c("xmax", "ymax")] + study_area_margin
study_area <- sf::st_as_sfc(bbox_llr)
