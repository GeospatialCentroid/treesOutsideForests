# Helper to fix Alpha interpretation on Band 4 and calculate min-max stats for QGIS
fix_alpha_band <- function(filepath) {
  if (!file.exists(filepath)) return(NULL)
  tmp <- paste0(filepath, ".fix.tif")
  sf::gdal_utils(
    "translate",
    source = filepath,
    destination = tmp,
    options = c("-colorinterp_4", "undefined")
  )
  file.remove(filepath)
  file.rename(tmp, filepath)
  sf::gdal_utils("info", source = filepath, options = "-stats", quiet = TRUE)
}

# 1. Update the helper function to force a CRS match
readAndName <- function(path, target_crs) {
  r1 <- terra::rast(path)
  names(r1) <- c("red", "green", "blue", "nir")

  # If the tile's CRS doesn't match our master CRS, project it on the fly
  if (terra::crs(r1) != target_crs) {
    r1 <- terra::project(r1, target_crs)
  }

  return(r1)
}
mergeAndExportNAIP <- function(files, out_path, aoi, year, buffer_m = 250, buffer_only = TRUE) {
  # Buffer dynamically based on parameter
  aoi_buf <- sf::st_buffer(aoi, dist = buffer_m)
  
  # Calculate dynamic label for filename.
  # Assuming base AOI is 1000m. Total width = 1000m + (buffer_m * 2)
  total_width_km <- (1000 + (2 * buffer_m)) / 1000 
  label_km <- paste0(total_width_km, "km") # e.g., "1.5km"
  
  # Get a template rast for CRS information
  r1 <- terra::rast(files[1])
  master_crs <- terra::crs(r1) 
  aoi_proj <- terra::project(terra::vect(aoi), master_crs)
  aoi_buf_proj <- terra::project(terra::vect(aoi_buf), master_crs)
  
  # Export the 1km vector geometry
  terra::writeVector(
    aoi_proj,
    file.path(out_path, paste0("aoi-", aoi$id, ".gpkg")),
    overwrite = TRUE
  )
  
  # Generate a template raster (1m resolution)
  temp <- terra::rast(
    extent = terra::ext(aoi_buf_proj),
    crs = master_crs,
    nlyrs = 4,
    resolution = 1
  )
  
  if (length(files) > 1) {
    rast_list <- purrr::map(
      .x = files,
      ~ readAndName(.x, target_crs = master_crs) |>
          terra::resample(temp, method = "bilinear")
    )
    rast <- terra::sprc(rast_list) |>
      terra::mosaic(fun = "mean")
  } else {
    rast <- terra::rast(files)
  }
  
  # Crop, resample, and mask to the dynamically buffered area
  m1 <- terra::crop(rast, aoi_buf_proj) |>
    terra::resample(temp, method = "bilinear") |>
    terra::mask(aoi_buf_proj)
  
  # Export dynamically sized data
  export_buf <- file.path(
    out_path,
    paste0("naip_", label_km, "_", aoi$id, "_", year, ".tif")
  )
  terra::writeRaster(x = m1, export_buf, datatype = "INT1U", overwrite = TRUE)
  fix_alpha_band(export_buf)
  
  # Conditionally process and export the 1km data
  if (!buffer_only) {
    m2 <- terra::crop(m1, aoi_proj) |>
      terra::mask(aoi_proj)
    
    export_1km <- file.path(
      out_path,
      paste0("naip_1km_", aoi$id, "_", year, ".tif")
    )
    terra::writeRaster(x = m2, export_1km, datatype = "INT1U", overwrite = TRUE)
    fix_alpha_band(export_1km)
  }
}

mergeAndExportLidar <- function(files, out_path, aoi) {
  # generates one image crop to the 1km areas
  # get a template rast for CRS information
  r1 <- terra::rast(files[1])
  # reprojecthe aoi object
  aoi_proj <- terra::project(terra::vect(aoi), terra::crs(r1))

  # generate a template
  temp <- terra::rast(
    extent = terra::ext(aoi_proj),
    crs = terra::crs(aoi_proj),
    nlyrs = 1,
    resolution = terra::res(r1)[1] # pull from the lidar image
  )
  if (length(files) > 1) {
    rast <- files |>
      terra::sprc() |>
      terra::mosaic(fun = "mean")
  } else {
    rast <- terra::rast(files)
  }
  # crop and resample
  m1 <- terra::crop(rast, aoi_proj) |>
    terra::resample(
      temp,
      method = "bilinear"
    )
  # export Path
  pattern_string <- gsub(
    "_[0-9]+(?=\\.tif$)",
    "",
    basename(files[1]),
    perl = TRUE
  )
  dsm_Export <- paste0(out_path, "/", pattern_string)
  # write out,
  terra::writeRaster(x = m1, dsm_Export, overwrite = TRUE)
}


# compile data for export
copyToExport <- function(id, year) {
  # Define the source directories to check
  source_dirs <- file.path(
    "data",
    c("aoiExports", "lidarExports", "naipExports", "snicExports")
  )

  # 2. Find all files containing the target ID in the target folders
  files_to_move <- list.files(
    path = source_dirs,
    pattern = id,
    full.names = TRUE
  )

  # 3. Create the destination directory inside exportData
  dest_dir <- paste0("data/exportData/aoi_", id, "_", year)

  if (!dir.exists(dest_dir)) {
    dir.create(dest_dir, recursive = TRUE)
  }
  # file copy then remore
  for (i in files_to_move) {
    file.copy(i, to = dest_dir)
    # test for success
    newFile <- file.path(dest_dir, basename(i))
    if (file.exists(newFile)) {
      file.remove(i)
    } else {
      message("file was not successful copied")
      stop()
    }
  }
}
