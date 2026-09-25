## Extracting COT metrics from U-net maps
# =========================================================
# Summarize COT rasters in WGS84:
# - pixel count per COT
# - area per COT in sqkm
# - total grid size in sqkm
# Output: one row per grid
# =========================================================

library(terra)
library(dplyr)
library(stringr)
library(purrr)
library(tidyr)

# -------------------------------
# 1. User inputs
# -------------------------------


cot_folder <- "N:/Research/Ogle/Agroforestry/phase1_nebraska/Unet_maps/Masked/COT"
output_csv  <- file.path(cot_folder, "cot_summary_by_grid.csv")

# file names: # X12-1_changeOverTime_Unet.tif
file_pattern <- "^X12-[0-9]+_changeOverTime_Unet\\.tif$"

# -------------------------------
# 2. List files
# -------------------------------

cot_files <- list.files(
  cot_folder,
  pattern = file_pattern,
  full.names = TRUE
)

if (length(cot_files) == 0) {
  stop("No matching .tif files were found in: ", cot_folder)
}

cat("Found", length(cot_files), "raster files.\n")

# -------------------------------
# 3. Function to summarize one raster
# -------------------------------

summarize_one_grid <- function(f, index, total) {
  
  start_time <- Sys.time()
  file_name  <- basename(f)
  grid_id    <- stringr::str_extract(file_name, "X12-[0-9]+")
  
  cat("\n----------------------------------------\n")
  cat("Starting", index, "of", total, ":", grid_id, "\n")
  cat("File:", file_name, "\n")
  
  r <- terra::rast(f)
  
  # freq() returns: layer, value, count
  freq_tbl <- as.data.frame(terra::freq(r))
  freq_tbl <- freq_tbl[, c("value", "count"), drop = FALSE]
  names(freq_tbl) <- c("COT", "pixel_count")
  
  # area by class in sq km
  area_rast_sqkm <- terra::cellSize(r, unit = "km")
  area_tbl <- as.data.frame(terra::zonal(area_rast_sqkm, r, "sum", na.rm = TRUE))
  
  # rename first column safely
  names(area_tbl) <- c("COT", "area_sqkm")
  
  # join count + area
  long_tbl <- dplyr::left_join(freq_tbl, area_tbl, by = "COT") %>%
    dplyr::mutate(grid_ID = grid_id)
  
  # total grid size
  total_grid_sqkm <- terra::global(area_rast_sqkm, "sum", na.rm = TRUE)[1, 1]
  
  # wide counts
  counts_wide <- long_tbl %>%
    dplyr::select(grid_ID, COT, pixel_count) %>%
    dplyr::mutate(col_name = paste0("COT_", COT, "_count")) %>%
    dplyr::select(-COT) %>%
    tidyr::pivot_wider(
      names_from = col_name,
      values_from = pixel_count,
      values_fill = 0
    )
  
  # wide areas
  areas_wide <- long_tbl %>%
    dplyr::select(grid_ID, COT, area_sqkm) %>%
    dplyr::mutate(col_name = paste0("COT_", COT, "_sqkm")) %>%
    dplyr::select(-COT) %>%
    tidyr::pivot_wider(
      names_from = col_name,
      values_from = area_sqkm,
      values_fill = 0
    )
  
  out <- counts_wide %>%
    dplyr::left_join(areas_wide, by = "grid_ID") %>%
    dplyr::mutate(total_grid_sqkm = total_grid_sqkm)
  
  elapsed_sec <- round(as.numeric(difftime(Sys.time(), start_time, units = "secs")), 1)
  cat("Completed", grid_id, "- elapsed time:", elapsed_sec, "seconds\n")
  
  out
}

# -------------------------------
# 4. Run all rasters
# -------------------------------

grid_results <- purrr::map2(
  cot_files,
  seq_along(cot_files),
  ~ summarize_one_grid(.x, .y, length(cot_files))
)

final_tbl <- dplyr::bind_rows(grid_results)

# -------------------------------
# 5. Replace missing COT columns with 0
# -------------------------------

final_tbl[is.na(final_tbl)] <- 0

# -------------------------------
# 6. Order columns nicely
# -------------------------------

count_cols <- names(final_tbl)[grepl("^COT_[0-9]+_count$", names(final_tbl))]
area_cols  <- names(final_tbl)[grepl("^COT_[0-9]+_sqkm$", names(final_tbl))]

# sort numerically by COT number
get_cot_num <- function(x) as.integer(str_extract(x, "(?<=COT_)[0-9]+"))

count_cols <- count_cols[order(get_cot_num(count_cols))]
area_cols  <- area_cols[order(get_cot_num(area_cols))]

ordered_cols <- c("grid_ID", as.vector(rbind(count_cols, area_cols)), "total_grid_sqkm")
ordered_cols <- ordered_cols[ordered_cols %in% names(final_tbl)]

final_tbl <- final_tbl %>%
  select(all_of(ordered_cols)) %>%
  arrange(grid_ID)

# -------------------------------
# 7. Save output
# -------------------------------

write.csv(final_tbl, output_csv, row.names = FALSE)

cat("\n========================================\n")
cat("Finished processing all files.\n")
cat("Output saved to:\n", output_csv, "\n")
cat("========================================\n")

# Comparing RF vs Unet
rf_file <- "C:/Users/gwdiasf/OneDrive - Colostate/CSU~GABRIEL/CSU/Agroforestry/Activity Data - Segmentation and shape id/Nebraska analysis - 2024"
cot_rf <- read.csv(file.path(rf_file, "cot_rf.csv"), header = TRUE)

new_area <- final_tbl %>%
  select(grid_ID, matches("_sqkm$"))

names(new_area)
names(cot_rf)


cot_rf2 <- cot_rf %>%
  rename(
    grid_ID = layer,
    COT_0_sqkm = cot_0,
    COT_1_sqkm = cot_1,
    COT_3_sqkm = cot_3,
    COT_4_sqkm = cot_4,
    COT_5_sqkm = cot_5,
    COT_6_sqkm = cot_6,
    COT_8_sqkm = cot_8,
    COT_9_sqkm = cot_9,
    total_grid_sqkm = total_area
  )


compare_tbl <- new_area %>%
  inner_join(cot_rf2, by = "grid_ID", suffix = c("_new", "_rf"))

area_cols <- names(new_area)[names(new_area) != "grid_ID"]

for (col in area_cols) {
  compare_tbl[[paste0(col, "_diff")]] <-
    compare_tbl[[paste0(col, "_new")]] -
    compare_tbl[[paste0(col, "_rf")]]
}


summary_by_cot <- compare_tbl %>%
  summarise(across(ends_with("_diff"), mean, na.rm = TRUE))

summary_by_cot


library(terra)
## debugging
f <- cot_files[1]
f
r <- rast(f)
r
crs(r)
res(r)
ext(r)
ncell(r)

freq(r)


a <- cellSize(r, unit = "km")
a
global(a, "sum", na.rm = TRUE)
zonal(a, r, "sum", na.rm = TRUE)
nlyr(r)
datatype(r)

library(terra)

r <- rast(cot_files[1])

# Method 1: your current approach
a <- cellSize(r, unit = "km")
total_cellsize <- global(a, "sum", na.rm = TRUE)[1, 1]
byvalue_cellsize <- as.data.frame(zonal(a, r, "sum", na.rm = TRUE))
names(byvalue_cellsize) <- c("COT", "area_sqkm_cellsize")

# Method 2: terra's built-in area summary
total_expanse <- expanse(r, unit = "km")
byvalue_expanse <- expanse(r, unit = "km", byValue = TRUE, wide = FALSE)

total_cellsize
total_expanse
byvalue_cellsize
byvalue_expanse
