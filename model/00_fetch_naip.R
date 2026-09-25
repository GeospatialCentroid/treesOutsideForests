# ==============================================================================
# Fetch the NAIP imagery that pairs with the reference tree masks.
# ==============================================================================
# The masks in agroforestry_trainingValidation/lrr_F/ were digitised on this
# repo's own 1 km NAIP exports (naip_1km_<id>_<year>.tif: same CRS, grid and
# origin), but those exports were made for the sample grid, not for the
# ground-truth cells, so most mask cells have no imagery on disk. This step
# runs the naip stage's per-cell worker (naip/function/process_aoi.R) for every
# (cell, year) a mask names, with the tight 1 km export switched on. A cell
# that already has a successful export is skipped by the worker itself.
#
# The mask year is requested as the target year. The worker may fall back to a
# neighbouring year when the requested one is not served; model/01_prepare.py
# only pairs a mask with imagery of the same year and reports the rest.
#
#   Rscript model/00_fetch_naip.R
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(dplyr, sf, terra, furrr, future, jsonlite, rstac, tictoc)
invisible(lapply(list.files(tof_root("naip/function"), pattern = "[.]R$", full.names = TRUE), source))

cfg       <- tof_config()
cfg_model <- cfg$model
mask_dirs <- vapply(cfg_model$paths$mask_dirs, tof_path, character(1))
export_dir <- tof_path(cfg$naip$paths$export_dir)
workers    <- cfg_model$fetch_workers
buffer_m   <- cfg$naip$buffer_dist_m

# One task per (cell, year) named by a mask file: <id>_<year>_mask.tif
mask_files <- unlist(lapply(mask_dirs, list.files, pattern = "_mask[.]tif$", full.names = FALSE))
tasks <- tibble::tibble(file = mask_files) |>
  dplyr::mutate(id = sub("_(\\d{4})_mask[.]tif$", "", file),
                target_year = sub(".*_(\\d{4})_mask[.]tif$", "\\1", file)) |>
  dplyr::distinct(id, target_year)

# Tasks whose exact export already exists are done; the worker would skip them
# anyway, but listing them first makes the run report honest about the work.
tasks$done <- file.exists(file.path(export_dir, sprintf("aoi_%s_%s", tasks$id, tasks$target_year),
                                    sprintf("naip_1km_%s_%s.tif", tasks$id, tasks$target_year)))
message(sprintf("%d (cell, year) pairs named by %d masks in %d folders; %d already exported, %d to fetch.",
                nrow(tasks), length(mask_files), length(mask_dirs), sum(tasks$done), sum(!tasks$done)))
todo <- tasks[!tasks$done, ]
if (nrow(todo) == 0) { message("Nothing to fetch."); quit(save = "no") }

g100 <- sf::st_read(tof_path(cfg$reference$grid_gpkg), quiet = TRUE)
future::plan(future::multisession, workers = workers)
options(future.rng.onMisuse = "ignore")

tictoc::tic("NAIP fetch for mask cells")
results <- furrr::future_map(seq_len(nrow(todo)), function(i) {
  process_aoi(aoi_id = todo$id[i], target_year = todo$target_year[i], g100_grid = g100,
              export_dir = export_dir, buffer_m = buffer_m, run_snic = FALSE, export_1km_tight = TRUE)
}, .progress = TRUE, .options = furrr::furrr_options(seed = TRUE, chunk_size = 5))
tictoc::toc()

res <- dplyr::bind_rows(lapply(results, function(r) tibble::tibble(
  aoi_id = r$aoi_id, target_year = as.character(r$target_year),
  actual_year = if (is.null(r$actual_year)) NA_character_ else as.character(r$actual_year),
  status = r$status)))
res$year_matches <- !is.na(res$actual_year) & res$actual_year == res$target_year
out_dir <- tof_path(cfg_model$paths$work_dir); dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
readr::write_csv(res, file.path(out_dir, "fetch_naip_report.csv"))
message(sprintf("\nFetched: %d success (%d with the requested year), %d failed. Report: %s",
                sum(res$status == "Success"), sum(res$status == "Success" & res$year_matches),
                sum(res$status != "Success"), file.path(out_dir, "fetch_naip_report.csv")))
if (any(res$status != "Success")) print(res[res$status != "Success", ], n = 50)
if (any(res$status == "Success" & !res$year_matches)) {
  message("Requested year not served; imagery from another year was exported instead (not paired with the mask):")
  print(res[res$status == "Success" & !res$year_matches, ], n = 50)
}
