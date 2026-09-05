# ==============================================================================
# Phase 1: Configuration
# ==============================================================================
pacman::p_load(terra, sf, rstac, tigris, dplyr, purrr, future, furrr, FedData)

# Source external grid generation functions
source("src/generateAOI.R")


# Define core parameters
target_years <- c(2009:2021)
nlcdClasses <- c(41, 42, 43) # Forest classes
output_dir <- "outputs"
temp_dir <- "temp"
llr_id <- "F"

if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
if (!dir.exists(temp_dir)) dir.create(temp_dir, recursive = TRUE)

# read in required data 
## LLR areas 
llr <- sf::st_read("data/lower48LRR.gpkg")|>
  dplyr::filter(LRRSYM == llr_id) |>
  sf::st_transform(4326)
# llr bbox 
bbox_llr <- sf::st_bbox(llr)
study_area <- st_as_sfc(st_bbox(c(bbox_llr["xmin"], bbox_llr["ymin"], bbox_llr["xmax"], bbox_llr["ymax"]), crs = 4326))
# 


## 100kgrid 
grid100km <- sf::st_read("data/grid100km_aea.gpkg")
## sample ids 
sampleIDs <- readr::read_csv("data/selectedSample_lrr_F_05_2026.csv", col_types = readr::cols(LLR_ID = readr::col_character()))
## template image 
templateImage <- terra::rast("data/naip_1km_2003-2-1-c-2_2019.tif")
## global template raster (Albers Equal Area EPSG:5070, 1m resolution)
template_rast <- terra::rast(resolution = 1, crs = "EPSG:5070")




