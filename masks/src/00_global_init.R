# ==============================================================================
# Phase 1: Configuration
# ==============================================================================
# The parameters for this stage live in the `masks` section of the root
# config.yml. This script reads them and derives the objects later steps need.
source(here::here("shared/R/setup.R"))
pacman::p_load(terra, sf, tigris, dplyr, purrr)

# How the pipeline decides whether a cached Census file is genuinely its year.
source(tof_root("masks/src/00_census_provenance.R"))

cfg_masks <- tof_config()$masks

# Define core parameters
target_years <- seq(cfg_masks$years$start, cfg_masks$years$end)
nlcdClasses  <- cfg_masks$nlcd_classes # Forest classes
llr_id       <- cfg_masks$llr_id

# Census Places are only used for the year they were actually published for. A
# year the Census does not serve gets no urban product at all, rather than one
# built from a neighbouring year's boundaries under that year's filename. Set
# this TRUE in config.yml to restore the old nearest-year fallback (every
# substituted layer is still stamped with census_source_year either way).
allow_census_year_substitution <- cfg_masks$allow_census_year_substitution

# A year found to have no Census release is recorded with a .unavailable marker
# so the next run does not re-query the API for it. Set this TRUE to re-check -
# a year can become available later.
census_recheck_unavailable <- cfg_masks$census_recheck_unavailable

# CRS the LRR boundary is held in. Rasters stay on their source grid; only
# vector geometry is transformed, and that is exact.
analysis_crs <- tof_config()$crs

# Margin (metres) added around the LLR bounding box when clipping the national
# NLCD rasters, and when deciding which states overlap the LLR for the Census
# download. The final products are clipped to a tighter buffer of the LLR
# polygon itself (see masks/src/02_llr_masks.R); this margin only governs how
# much surrounding data the intermediates retain.
study_area_margin <- cfg_masks$study_area_margin_m

# Where this stage reads and writes. All under data/masks/ (see config.yml).
masks_nlcd_raw_dir <- tof_path(cfg_masks$paths$nlcd_raw)
masks_nlcd_dir     <- tof_path(cfg_masks$paths$nlcd_processed)
masks_census_dir   <- tof_path(cfg_masks$paths$census_raw)
masks_out_dir      <- tof_path(cfg_masks$paths$outputs)

# read in required data
## LLR areas, kept in the analysis CRS so that all downstream extents are
## computed in projected space rather than in degrees.
llr <- read_lrr(llr_id, crs = analysis_crs)

## Study area for the intermediates: the LLR bounding box, buffered, built in
## the analysis CRS. Building this in EPSG:4326 and reprojecting produces a
## four-vertex polygon whose straight edges cut inside the true extent, silently
## masking data along the north and south margins.
bbox_llr <- sf::st_bbox(llr)
bbox_llr[c("xmin", "ymin")] <- bbox_llr[c("xmin", "ymin")] - study_area_margin
bbox_llr[c("xmax", "ymax")] <- bbox_llr[c("xmax", "ymax")] + study_area_margin
study_area <- sf::st_as_sfc(bbox_llr)
