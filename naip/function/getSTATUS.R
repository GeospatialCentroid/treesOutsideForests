#' Compile all JSON status trackers into a master data frame
#'
#' Reads every status.json written by process_aoi() (one per AOI-year folder)
#' and returns one row per file: aoi_id, target_year, actual_year, status,
#' capture_dates, item_ids, naip_states, plus the folder and the file's
#' modification time. Fields missing from a file (a failed task has no tile
#' metadata) come back NA.
#'
#' @param local_working_dir Character. Path to the local processing/export directory.
#' @return A data frame containing all completed/partial/failed status records.
compileStatus <- function(local_working_dir = tof_path(tof_config()$naip$paths$export_dir)) {
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

  fields <- c("aoi_id", "target_year", "actual_year", "status",
              "capture_dates", "item_ids", "naip_states")
  pick <- function(js, key) {
    v <- js[[key]]
    if (is.null(v) || length(v) == 0) NA_character_ else paste(as.character(v), collapse = "; ")
  }

  results_list <- lapply(status_files, function(f) {
    tryCatch({
      js  <- jsonlite::fromJSON(f)
      row <- lapply(fields, function(k) pick(js, k))
      names(row) <- fields
      row$folder   <- basename(dirname(f))
      row$modified <- file.mtime(f)
      as.data.frame(row, stringsAsFactors = FALSE)
    }, error = function(e) NULL)
  })

  results_list <- results_list[!sapply(results_list, is.null)]

  if (length(results_list) > 0) {
    dplyr::bind_rows(results_list)
  } else {
    NULL
  }
}

#' Clear all JSON status trackers on disk
#'
#' @param local_working_dir Character. Path to the local processing/export directory.
clearStatus <- function(local_working_dir = tof_path(tof_config()$naip$paths$export_dir)) {
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
