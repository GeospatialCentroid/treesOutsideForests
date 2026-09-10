#' Compile all JSON status trackers into a master data frame
#'
#' @param local_working_dir Character. Path to the local processing/export directory.
#' @return A data frame containing all completed/partial/failed status records.
compileStatus <- function(local_working_dir = "data/exportData") {
  status_files <- list.files(
    path = local_working_dir,
    pattern = "^status\\.json$",
    recursive = TRUE,
    full.names = TRUE
  )
  
  if (length(status_files) == 0) {
    message("No status.json files found on disk.")
    return(NULL)
  }
  
  results_list <- lapply(status_files, function(f) {
    tryCatch({
      js <- jsonlite::fromJSON(f)
      
      # Flatten list fields into comma-separated strings for spreadsheet compatibility
      flat_res <- list(
        aoi_id   = js$aoi_id,
        batch_id = js$batch_id,
        status   = js$status,
        year_1   = js$year_1,
        year_2   = js$year_2,
        year_3   = js$year_3
      )
      
      # Helper to extract and paste metadata values
      extract_meta <- function(meta, key) {
        if (is.null(meta) || is.null(meta[[key]])) return(NA)
        paste(meta[[key]], collapse = "; ")
      }
      
      if (!is.null(js$year_1_meta)) {
        flat_res$y1_actual_year   <- extract_meta(js$year_1_meta, "actual_year")
        flat_res$y1_capture_dates <- extract_meta(js$year_1_meta, "capture_dates")
        flat_res$y1_item_ids      <- extract_meta(js$year_1_meta, "item_ids")
        flat_res$y1_naip_states   <- extract_meta(js$year_1_meta, "naip_states")
      }
      
      if (!is.null(js$year_2_meta)) {
        flat_res$y2_actual_year   <- extract_meta(js$year_2_meta, "actual_year")
        flat_res$y2_capture_dates <- extract_meta(js$year_2_meta, "capture_dates")
        flat_res$y2_item_ids      <- extract_meta(js$year_2_meta, "item_ids")
        flat_res$y2_naip_states   <- extract_meta(js$year_2_meta, "naip_states")
      }
      
      if (!is.null(js$year_3_meta)) {
        flat_res$y3_actual_year   <- extract_meta(js$year_3_meta, "actual_year")
        flat_res$y3_capture_dates <- extract_meta(js$year_3_meta, "capture_dates")
        flat_res$y3_item_ids      <- extract_meta(js$year_3_meta, "item_ids")
        flat_res$y3_naip_states   <- extract_meta(js$year_3_meta, "naip_states")
      }
      
      return(flat_res)
    }, error = function(e) NULL)
  })
  
  results_list <- results_list[!sapply(results_list, is.null)]
  
  if (length(results_list) > 0) {
    master_df <- dplyr::bind_rows(results_list)
    return(master_df)
  } else {
    return(NULL)
  }
}

#' Clear all JSON status trackers on disk
#'
#' @param local_working_dir Character. Path to the local processing/export directory.
clearStatus <- function(local_working_dir = "data/exportData") {
  status_files <- list.files(
    path = local_working_dir,
    pattern = "^status\\.json$",
    recursive = TRUE,
    full.names = TRUE
  )
  
  if (length(status_files) == 0) {
    message("No status.json files found to clear.")
    return(invisible(FALSE))
  }
  
  file.remove(status_files)
  message(sprintf("Successfully removed %d status.json files.", length(status_files)))
  return(invisible(TRUE))
}
