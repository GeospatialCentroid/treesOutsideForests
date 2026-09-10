getNAIPYear <- function(aoi) {
  # prep aoi object
  bbox <- aoi |>
    sf::st_transform(crs = "EPSG:4326") |>
    sf::st_bbox()
  
  # Connect to STAC API
  stac_endpoint <- "https://planetarycomputer.microsoft.com/api/stac/v1"
  con <- rstac::stac(stac_endpoint)
  
  # --- EXPONENTIAL BACKOFF RETRY LOGIC ---
  max_retries <- 10
  retry_count <- 0
  request_success <- FALSE
  search_results <- NULL
  
  while (!request_success && retry_count < max_retries) {
    tryCatch(
      {
        search_results <- con |>
          rstac::stac_search(
            collections = "naip",
            bbox = bbox,
            datetime = "2008-01-01T00:00:00Z/2026-12-31T23:59:59Z", # Added broad temporal bound
            limit = 100 # Reduced from 200 to standard max
          ) |>
          rstac::get_request() # Execute the search
        
        request_success <- TRUE # If we get here without an error, it worked!
      },
      error = function(e) {
        retry_count <<- retry_count + 1
        if (retry_count < max_retries) {
          # Progressive wait: 10s, 20s, 30s, 40s... with jitter
          wait_time <- 10 * retry_count + runif(1, 1, 5)
          message(sprintf(
            "STAC API Server Overloaded. Waiting %.1f seconds to retry (Attempt %d of %d)...",
            wait_time,
            retry_count,
            max_retries
          ))
          Sys.sleep(wait_time)
        } else {
          stop(sprintf(
            "STAC API failed after %d attempts. Original error: %s",
            max_retries,
            e$message
          ))
        }
      }
    )
  }
  # -------------------------------
  
  if (length(search_results$features) == 0) {
    stop("No NAIP imagery found for the specified AOI.")
  }
  
  # pull dates
  all_datetimes <- rstac::items_datetime(search_results)
  # pull specific year
  all_years_str <- substr(all_datetimes, 1, 4)
  # return only unique values
  available_years <- sort(unique(all_years_str))
  
  return(available_years)
}
downloadNAIP_vsi <- function(aoi, year, exportFolder, buffer_m = 0) {
  Sys.setenv(GDAL_HTTP_RETRY = "YES")
  Sys.setenv(GDAL_HTTP_MAX_RETRIES = "4")
  Sys.setenv(GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR")
  Sys.setenv(VSI_CACHE = "TRUE")
  Sys.setenv(VSI_CACHE_SIZE = "10000000")
  
  # --- DYNAMIC BUFFER LOGIC ---
  if (buffer_m > 0) {
    target_aoi <- aoi |>
      sf::st_buffer(dist = buffer_m)
  } else {
    target_aoi <- aoi
  }
  
  # Create the Lat/Lon bbox for the STAC search using the target geometry
  bbox_4326 <- target_aoi |>
    sf::st_transform(crs = 4326) |>
    sf::st_bbox()
  
  # 2. Search Planetary Computer
  stac_endpoint <- "https://planetarycomputer.microsoft.com/api/stac/v1"
  
  # --- EXPONENTIAL BACKOFF RETRY LOGIC ---
  max_retries <- 10
  retry_count <- 0
  request_success <- FALSE
  search_results <- NULL
  
  while (!request_success && retry_count < max_retries) {
    tryCatch(
      {
        search_results <- rstac::stac(stac_endpoint) |>
          rstac::stac_search(
            collections = "naip",
            bbox = bbox_4326,
            datetime = paste0(year, "-01-01T00:00:00Z/", year, "-12-31T23:59:59Z"),
            limit = 100
          ) |>
          rstac::get_request() |>
          rstac::items_sign(rstac::sign_planetary_computer())
        
        request_success <- TRUE 
      },
      error = function(e) {
        retry_count <<- retry_count + 1
        if (retry_count < max_retries) {
          wait_time <- 10 * retry_count + runif(1, 1, 5) # Added jitter
          message(sprintf(
            "STAC API (Download) Overloaded. Waiting %.1f seconds to retry (Attempt %d of %d)...",
            wait_time,
            retry_count,
            max_retries
          ))
          Sys.sleep(wait_time)
        } else {
          stop(sprintf(
            "STAC API (Download) failed after %d attempts. Original error: %s",
            max_retries,
            e$message
          ))
        }
      }
    )
  }
  
  if (length(search_results$features) == 0) {
    stop("No NAIP imagery found for this area/year.")
  }
  
  # 3. Extract Signed URLs (VSI compatible)
  image_urls <- rstac::assets_url(search_results, asset_names = "image")
  
  if (!dir.exists(exportFolder)) {
    dir.create(exportFolder, recursive = TRUE)
  }
  
  # 4. Process each intersecting tile
  for (i in seq_along(image_urls)) {
    vsi_path <- paste0("/vsicurl/", image_urls[i])
    remote_rast <- terra::rast(vsi_path)
    
    aoi_proj <- sf::st_transform(target_aoi, crs = terra::crs(remote_rast))
    
    out_file <- file.path(
      exportFolder,
      paste0("naip_", year, "_id_", aoi$id[1], "_", i, ".tif")
    )
    
    tryCatch(
      {
        terra::crop(
          x = remote_rast, 
          y = aoi_proj, 
          filename = out_file, 
          datatype = "INT1U", 
          overwrite = TRUE
        )
      },
      error = function(e) {
        if (grepl("extents do not overlap", e$message, ignore.case = TRUE)) {
          message(sprintf("  [-] Tile %d does not overlap AOI geometry. Skipping.", i))
        } else {
          stop(e)
        }
      }
    )
  }
  
  # Build and return the metadata dataframe
  meta_df <- data.frame(
    aoi_id          = aoi$id[1],
    target_year     = year,
    tile_index      = seq_along(search_results$features),
    item_id         = sapply(search_results$features, function(f) f$id),
    collection_date = sapply(search_results$features, function(f) f$properties$datetime),
    naip_state      = sapply(search_results$features, function(f) f$properties[["naip:state"]])
  )
  return(meta_df)
}



getNAIPCaptureDates <- function(aois, id_col = "id") {
  # Initialize an empty list to store the results for each AOI
  results_list <- list()
  
  # Connect to STAC API
  stac_endpoint <- "https://planetarycomputer.microsoft.com/api/stac/v1"
  con <- rstac::stac(stac_endpoint)
  
  # Loop through each AOI in the provided sf object
  for (i in seq_len(nrow(aois))) {
    single_aoi <- aois[i, ]
    current_id <- single_aoi[[id_col]]
    
    # prep aoi object
    bbox <- single_aoi |>
      sf::st_transform(crs = "EPSG:4326") |>
      sf::st_bbox()
    
    # --- EXPONENTIAL BACKOFF RETRY LOGIC ---
    max_retries <- 10
    retry_count <- 0
    request_success <- FALSE
    search_results <- NULL
    
    while (!request_success && retry_count < max_retries) {
      tryCatch(
        {
          search_results <- con |>
            rstac::stac_search(
              collections = "naip",
              bbox = bbox,
              limit = 500 # Slightly higher limit in case of heavy overlap
            ) |>
            rstac::get_request() # Execute the search
          
          request_success <- TRUE 
        },
        error = function(e) {
          retry_count <<- retry_count + 1
          if (retry_count < max_retries) {
            wait_time <- 10 * retry_count
            message(sprintf(
              "STAC API Server Overloaded for AOI %s. Waiting %d seconds to retry (Attempt %d of %d)...",
              as.character(current_id), wait_time, retry_count, max_retries
            ))
            Sys.sleep(wait_time)
          } else {
            warning(sprintf(
              "STAC API failed for AOI %s after %d attempts. Original error: %s",
              as.character(current_id), max_retries, e$message
            ))
          }
        }
      )
    }
    # -------------------------------
    
    # Process results if the request was successful and features exist
    if (request_success && length(search_results$features) > 0) {
      # pull datetimes (e.g., "2019-08-11T00:00:00Z")
      all_datetimes <- rstac::items_datetime(search_results)
      
      # Extract just the date component (YYYY-MM-DD)
      all_dates <- as.Date(substr(all_datetimes, 1, 10))
      
      # Return only unique capture dates for this specific area
      unique_dates <- sort(unique(all_dates))
      
      # Create a data frame mapping the ID to each unique capture date
      results_list[[i]] <- data.frame(
        aoi_id = current_id,
        capture_date = unique_dates,
        stringsAsFactors = FALSE
      )
    } else {
      # If no imagery is found or the API failed entirely, record as NA
      results_list[[i]] <- data.frame(
        aoi_id = current_id,
        capture_date = NA,
        stringsAsFactors = FALSE
      )
    }
  }
  
  # Combine all individual AOI data frames into one master data frame
  final_df <- do.call(rbind, results_list)
  
  # Optional: Drop row names for cleaner output
  rownames(final_df) <- NULL
  
  return(final_df)
}