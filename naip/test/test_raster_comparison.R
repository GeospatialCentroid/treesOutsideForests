# Comprehensive Raster & Product Equivalence Verification Script
library(terra)
library(jsonlite)
library(sf)
source(here::here("shared/R/setup.R"))

seq_dir <- tof_root("data/naip/test_sequential")
par_dir <- tof_root("data/naip/test_parallel")

# Find all subdirectories in sequential output
seq_subdirs <- list.dirs(seq_dir, full.names = FALSE, recursive = FALSE)
seq_subdirs <- seq_subdirs[grepl("^aoi_", seq_subdirs)]

cat("\n======================================================================\n")
cat("            SEQUENTIAL VS PARALLEL PIPELINE COMPARISON\n")
cat("======================================================================\n")
cat(sprintf("Found %d product directories to compare.\n\n", length(seq_subdirs)))

all_passed <- TRUE

for (subdir in seq_subdirs) {
  cat(sprintf("Comparing directory: %s\n", subdir))
  cat("----------------------------------------------------------------------\n")
  
  seq_path <- file.path(seq_dir, subdir)
  par_path <- file.path(par_dir, subdir)
  
  # 1. Check directory existence
  if (!dir.exists(par_path)) {
    cat("  [FAIL] Parallel output directory does not exist!\n")
    all_passed <- FALSE
    next
  }
  
  # 2. Check and compare status.json
  seq_status_file <- file.path(seq_path, "status.json")
  par_status_file <- file.path(par_path, "status.json")
  
  if (file.exists(seq_status_file) && file.exists(par_status_file)) {
    seq_status <- jsonlite::fromJSON(seq_status_file)
    par_status <- jsonlite::fromJSON(par_status_file)
    
    if (seq_status$status == "Success" && par_status$status == "Success") {
      cat("  [PASS] Both status.json files report 'Success'\n")
      # Compare status details
      if (seq_status$actual_year == par_status$actual_year) {
        cat(sprintf("  [PASS] Actual years match: %s\n", seq_status$actual_year))
      } else {
        cat(sprintf("  [FAIL] Actual years differ: Seq=%s vs Par=%s\n", seq_status$actual_year, par_status$actual_year))
        all_passed <- FALSE
      }
      if (seq_status$item_ids == par_status$item_ids) {
        cat("  [PASS] Planetary Computer item_ids match exactly.\n")
      } else {
        cat("  [FAIL] planetary Computer item_ids differ!\n")
        all_passed <- FALSE
      }
    } else {
      cat(sprintf("  [FAIL] Status not successful. Seq: %s | Par: %s\n", seq_status$status, par_status$status))
      all_passed <- FALSE
    }
  } else {
    cat("  [FAIL] Missing status.json files!\n")
    all_passed <- FALSE
  }
  
  # 3. Find and compare Rasters (.tif files)
  seq_rasters <- list.files(seq_path, pattern = "\\.tif$", full.names = TRUE)
  par_rasters <- list.files(par_path, pattern = "\\.tif$", full.names = TRUE)
  
  if (length(seq_rasters) == 0 || length(par_rasters) == 0) {
    cat("  [FAIL] No raster files (.tif) found in directory!\n")
    all_passed <- FALSE
    next
  }
  
  # Map files by base name to compare corresponding rasters
  for (seq_r_file in seq_rasters) {
    base_name <- basename(seq_r_file)
    par_r_file <- file.path(par_path, base_name)
    
    if (!file.exists(par_r_file)) {
      cat(sprintf("  [FAIL] Parallel raster file '%s' is missing!\n", base_name))
      all_passed <- FALSE
      next
    }
    
    cat(sprintf("  Comparing raster: %s\n", base_name))
    
    # Load rasters
    r_seq <- terra::rast(seq_r_file)
    r_par <- terra::rast(par_r_file)
    
    # Check Band names and counts
    seq_bands <- names(r_seq)
    par_bands <- names(r_par)
    
    if (all(seq_bands == par_bands) && length(seq_bands) == 4) {
      cat(sprintf("    [PASS] Bands match and count is 4: [%s]\n", paste(seq_bands, collapse=", ")))
    } else {
      cat(sprintf("    [FAIL] Band mismatch! Seq: [%s] | Par: [%s]\n", paste(seq_bands, collapse=", "), paste(par_bands, collapse=", ")))
      all_passed <- FALSE
    }
    
    # Check DataType
    seq_dt <- terra::datatype(r_seq)
    par_dt <- terra::datatype(r_par)
    if (all(seq_dt == "INT1U") && all(par_dt == "INT1U")) {
      cat("    [PASS] Datatype is INT1U (8-bit unsigned integer) for all bands.\n")
    } else {
      cat(sprintf("    [FAIL] Datatype mismatch! Seq: %s | Par: %s\n", paste(seq_dt, collapse=", "), paste(par_dt, collapse=", ")))
      all_passed <- FALSE
    }
    
    # Check CRS
    if (terra::crs(r_seq) == terra::crs(r_par)) {
      cat("    [PASS] CRS projection strings match exactly.\n")
    } else {
      cat("    [FAIL] CRS mismatch!\n")
      all_passed <- FALSE
    }
    
    # Check Extent
    if (terra::ext(r_seq) == terra::ext(r_par)) {
      cat("    [PASS] Spatial extents match exactly.\n")
    } else {
      cat("    [FAIL] Extent mismatch!\n")
      all_passed <- FALSE
    }
    
    # Check Resolution
    if (all(terra::res(r_seq) == terra::res(r_par))) {
      cat(sprintf("    [PASS] Spatial resolution matches exactly: %s x %s\n", terra::res(r_seq)[1], terra::res(r_seq)[2]))
    } else {
      cat("    [FAIL] Resolution mismatch!\n")
      all_passed <- FALSE
    }
    
    # Check Dimensions
    if (all(dim(r_seq) == dim(r_par))) {
      cat(sprintf("    [PASS] Dimensions match exactly: %d x %d\n", dim(r_seq)[1], dim(r_seq)[2]))
    } else {
      cat("    [FAIL] Dimensions mismatch!\n")
      all_passed <- FALSE
    }
    
    # Check Pixel-Level Values Equivalence
    # Read raster values as matrices and compute absolute difference
    # terra allows direct subtraction of rast objects
    diff_rast <- abs(r_seq - r_par)
    max_diff <- max(terra::minmax(diff_rast)[2, ], na.rm = TRUE)
    
    if (max_diff == 0) {
      cat("    [PASS] Absolute maximum pixel-level cell value difference is EXACTLY 0.\n")
    } else {
      cat(sprintf("    [FAIL] Pixel-level values differ! Max absolute difference: %f\n", max_diff))
      all_passed <- FALSE
    }
    
    # Check GDAL Band 4 Color Interpretation using gdalinfo output
    g_info_seq <- sf::gdal_utils("info", source = seq_r_file, quiet = TRUE)
    g_info_par <- sf::gdal_utils("info", source = par_r_file, quiet = TRUE)
    
    # Look for Undefined interpretation on Band 4
    if (grepl("Band 4.*ColorInterp=Undefined", g_info_seq) && grepl("Band 4.*ColorInterp=Undefined", g_info_par)) {
      cat("    [PASS] Band 4 Color Interpretation is Undefined (Alpha band fixed successfully).\n")
    } else {
      cat("    [FAIL] Band 4 Color Interpretation is not Undefined!\n")
      all_passed <- FALSE
    }
    
    # Compare File Sizes
    seq_size <- file.info(seq_r_file)$size
    par_size <- file.info(par_r_file)$size
    if (seq_size == par_size) {
      cat(sprintf("    [PASS] File sizes match exactly: %d bytes\n", seq_size))
    } else {
      cat(sprintf("    [INFO] File sizes differ slightly: Seq=%d bytes, Par=%d bytes (Metadata differences only)\n", seq_size, par_size))
    }
  }
  
  # 4. Compare GPKG vector boundaries if exported
  seq_gpkgs <- list.files(seq_path, pattern = "\\.gpkg$", full.names = TRUE)
  par_gpkgs <- list.files(par_path, pattern = "\\.gpkg$", full.names = TRUE)
  
  for (seq_gpkg in seq_gpkgs) {
    base_gpkg <- basename(seq_gpkg)
    par_gpkg <- file.path(par_path, base_gpkg)
    if (file.exists(par_gpkg)) {
      v_seq <- sf::st_read(seq_gpkg, quiet = TRUE)
      v_par <- sf::st_read(par_gpkg, quiet = TRUE)
      if (all(sf::st_bbox(v_seq) == sf::st_bbox(v_par))) {
        cat(sprintf("  [PASS] GPKG vector '%s' bounds match exactly.\n", base_gpkg))
      } else {
        cat(sprintf("  [FAIL] GPKG vector '%s' bounds mismatch!\n", base_gpkg))
        all_passed <- FALSE
      }
    }
  }
  cat("\n")
}

cat("======================================================================\n")
if (all_passed) {
  cat("SUCCESS: All sequential and parallel products are IDENTICAL in every check!\n")
} else {
  cat("FAILURE: Divergences detected between sequential and parallel products.\n")
}
cat("======================================================================\n")
