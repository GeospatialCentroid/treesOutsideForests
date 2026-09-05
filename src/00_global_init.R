# ==============================================================================
# Phase 1: Configuration
# ==============================================================================
pacman::p_load(terra, sf, tigris, dplyr, purrr, readr, stringr, future, furrr)

# Source external grid generation functions
source("src/generateAOI.R")


# Define core parameters
target_years <- c(2009:2021)
nlcdClasses <- c(41, 42, 43) # Forest classes
output_dir <- "outputs"
temp_dir <- "temp"
llr_id <- "F"

# Analysis CRS: NAD83 / Conus Albers. All grids and outputs live here.
analysis_crs <- "EPSG:5070"
# Target resolution (metres) of the per-grid output template raster.
template_res <- 1

# Margin (metres) added around the LLR bounding box when clipping the national
# NLCD rasters. The 1km sample grids are generated from 100km parent grids, so
# grids on the edge of the LLR can overhang its bounding box; without a margin
# those grids are partially masked to NA. 5km covers the worst observed overhang.
study_area_margin <- 5000

# Extra margin (metres) added when cropping the LLR raster to a single 1km grid.
# One NLCD cell of slack absorbs the datum shift between the NLCD grid
# (Albers on WGS84) and the analysis CRS (Albers on NAD83).
grid_crop_margin <- 30

# Number of grids to process per year. Set to a small integer for a smoke test;
# NULL processes the full sample.
grid_limit <- NULL

if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
if (!dir.exists(temp_dir)) dir.create(temp_dir, recursive = TRUE)

# read in required data
## LLR areas, kept in the analysis CRS so that all downstream extents are
## computed in projected space rather than in degrees.
llr <- sf::st_read("data/lower48LRR.gpkg", quiet = TRUE) |>
  dplyr::filter(LRRSYM == llr_id) |>
  sf::st_transform(analysis_crs)

## Study area: the LLR bounding box, buffered, built in the analysis CRS.
## Building this in EPSG:4326 and reprojecting produces a four-vertex polygon
## whose straight edges cut inside the true extent, silently masking data along
## the north and south margins of the study area.
bbox_llr <- sf::st_bbox(llr)
bbox_llr[c("xmin", "ymin")] <- bbox_llr[c("xmin", "ymin")] - study_area_margin
bbox_llr[c("xmax", "ymax")] <- bbox_llr[c("xmax", "ymax")] + study_area_margin
study_area <- sf::st_as_sfc(bbox_llr)


## 100kgrid
grid100km <- sf::st_read("data/grid100km_aea.gpkg", quiet = TRUE)
## sample ids
sampleIDs <- readr::read_csv(
  "data/selectedSample_lrr_F_05_2026.csv",
  col_types = readr::cols(LLR_ID = readr::col_character())
)
