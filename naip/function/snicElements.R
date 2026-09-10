
prepRastForSNIC <- function(r) {
  # Pre-clean raster for the segmentation process
  r_calc <- r / 255
  r_calc <- terra::subst(r_calc, NA, 0)
  return(r_calc)
}


#' Generate Scaled Seeds
#' Takes a raster and generates 5 independent seed objects set distances
#'
#' @param r A terra raster object.
#' @return A list containing 5 seed objects (s10, s20, s40, s100, s200).
generate_scaled_seeds <- function(r) {
  # normalize rast
  r_clean <- prepRastForSNIC(r)

  # Define the desired spacing steps in meteres
  spacings <- c(s5 = 5L, s10 = 10L, s20 = 20L, s40 = 40L, s100 = 100L)

  # Generate a grid for each spacing
  seeds_list <- lapply(spacings, function(d) {
    snic::snic_grid(r_clean, type = "hexagonal", spacing = d)
  })

  return(seeds_list)
}

#' Run segemetation and export
#'
#' Iterates through a list of seeds, performs SNIC segmentation,
#' converts to polygons, and writes the results to GPKG files.
#'
#' @param r The input terra raster object
#' @param seed_list A named list of seed objects
#' @param output_dir Directory string where files should be saved.
#' @param file_id grid id for the 1km area that naip was generated
#' @param compactness SNIC compactness parameter. Something we might need to test
process_segmentations <- function(
    r,
    seed_list,
    output_dir,
    file_id,
    year,
    aoi, 
    compactness = 0.2
) {
  # Ensure output directory exists
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }
  # normalize the raster
  r_clean <- prepRastForSNIC(r)
  
  # Iterate through the seeds list
  # Using seq_along to easily access names for file labeling
  for (i in seq_along(seed_list)) {
    current_seed <- seed_list[[i]]
    label <- names(seed_list)[i] # e.g., "s10", "s20"
    
    message(paste("Processing segmentation for:", label))
    
    # Run SNIC
    segmentation <- snic::snic(
      r_clean,
      seeds = current_seed,
      compactness = compactness
    )
    # reproject the aoi to rasters projection 
    aoi2 <- terra::vect(aoi) |> 
      terra::project(r_clean)

    seg_rast <- snic::snic_get_seg(x = segmentation) |> terra::mask(aoi2)
      
    
    # convert to polygon and intersect strictly with aoi geometry
    seg_poly <- terra::as.polygons(seg_rast, dissolve = TRUE)
    
    
    # export
    out_name <- file.path(
      output_dir,
      paste0("seg_", file_id, "_", label, "_", year, ".gpkg")
    )
    
    if (!file.exists(out_name)) {
      terra::writeVector(x = seg_poly, filename = out_name)
      message(paste("Saved:", out_name))
    } else {
      message(paste("Skipping: File already exists -", out_name))
    }
  }
}
#' Plot Seed Density (Terra Vector Method)
#'
#' Converts seeds to a terra SpatVector and overlays them on the raster.
#'
#' @param r The terra raster object.
#' @param seed_list The list of seeds output from generate_scaled_seeds().
#' @param seed_name String. The name of the specific list element to plot.
#' @param pt_col Color of the points. Default is "red".
#' @param pt_cex Size of the points. Default is 0.8.
inspect_seed_density <- function(
  r,
  seed_list,
  seed_name,
  pt_col = "red",
  pt_cex = 0.6
) {
  if (!seed_name %in% names(seed_list)) {
    stop(paste("Error:", seed_name, "not found."))
  }

  # 1. Get the raw seeds
  current_seeds <- seed_list[[seed_name]]

  # 2. Convert to Terra SpatVector
  # We use a tryCatch to handle both SF objects and raw matrices/data.frames
  seed_vect <- tryCatch(
    {
      # Attempt direct conversion (works for sf objects)
      v <- terra::vect(current_seeds)
      # Ensure it has a CRS; if lost, borrow from raster
      if (terra::crs(v) == "") {
        terra::crs(v) <- terra::crs(r)
      }
      v
    },
    error = function(e) {
      # Fallback: assume it is a matrix/df of coordinates (x, y)
      # create vector points and assign the raster's CRS
      terra::vect(
        as.matrix(current_seeds),
        type = "points",
        crs = terra::crs(r)
      )
    }
  )

  # 3. Plot Base Raster
  if (terra::nlyr(r) >= 3) {
    terra::plotRGB(
      r,
      r = 1,
      g = 2,
      b = 3,
      stretch = "lin",
      main = paste0("Density Check: ", seed_name)
    )
  } else {
    terra::plot(r, main = paste0("Density Check: ", seed_name))
  }

  # 4. Overlay using terra::plot
  terra::plot(seed_vect, col = pt_col, cex = pt_cex, pch = 20, add = TRUE)

  message(paste(seed_name, "vector count:", length(seed_vect)))
}
