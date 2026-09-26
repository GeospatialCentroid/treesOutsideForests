# ==============================================================================
# Fetch the NAIP exports for a list of cells: the naip stage's per-cell worker
# (naip/function/process_aoi.R) run for every (cell, target year), with the
# tight 1 km export switched on, as model/00_fetch_naip.R does for the mask
# cells. Used for the evaluation panel (model/TESTING_PLAN.md 3.1 and step 7).
#
#   Rscript naip/src/fetch_cells.R --cells=<csv> [--tranche=1] [--years=2012,2016,2020] [--workers=6] [--report=<csv>]
#
# The CSV needs an `id` column; with --tranche only rows whose `tranche` column
# matches are fetched. Target years default to config naip$target_years; the
# worker falls back to a neighbouring year when the requested one is not served,
# and the export folder is named by the actual year. Cells already exported are
# skipped. A report with one row per (cell, year) is written to --report
# (default data/naip/fetch_report_<csv stem>[_t<tranche>].csv).
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(dplyr, sf, terra, furrr, future, jsonlite, rstac, tictoc, readr, tibble)
invisible(lapply(list.files(tof_root("naip/function"), pattern = "[.]R$", full.names = TRUE), source))

cli <- grep("^--", commandArgs(trailingOnly = TRUE), value = TRUE)
arg_or <- function(key, default = NULL) {
  hit <- grep(paste0("^--", key, "="), cli, value = TRUE)
  if (length(hit) == 0) return(default)
  sub(paste0("^--", key, "="), "", hit[length(hit)])
}
cfg <- tof_config()
cells_csv <- arg_or("cells"); if (is.null(cells_csv)) stop("--cells=<csv> is required")
tranche   <- arg_or("tranche")
years     <- strsplit(arg_or("years", paste(cfg$naip$target_years, collapse = ",")), ",")[[1]]
workers   <- as.integer(arg_or("workers", cfg$model$fetch_workers))
export_dir <- tof_path(cfg$naip$paths$export_dir)
buffer_m   <- cfg$naip$buffer_dist_m
stem <- tools::file_path_sans_ext(basename(cells_csv))
report <- tof_path(arg_or("report", file.path(dirname(cfg$naip$paths$export_dir),
                                              sprintf("fetch_report_%s%s.csv", stem, if (is.null(tranche)) "" else paste0("_t", tranche)))))

cells <- readr::read_csv(tof_path(cells_csv), show_col_types = FALSE,
                         col_types = readr::cols(id = readr::col_character(), .default = readr::col_guess()))
if (!is.null(tranche)) cells <- cells[as.character(cells$tranche) == tranche, ]
ids <- unique(cells$id)
tasks <- tidyr::expand_grid(id = ids, target_year = years)
# The worker skips a cell-year whose status.json says Success, but an export can
# sit under a fallback year's folder, so "done" is judged from the status files
# of every folder of that cell that names this target year.
status_done <- function(id, ty) {
  fs <- Sys.glob(file.path(export_dir, sprintf("aoi_%s_*", id), "status.json"))
  for (f in fs) {
    s <- tryCatch(jsonlite::fromJSON(f), error = function(e) NULL)
    if (!is.null(s) && identical(as.character(s$target_year), ty) && identical(s$status, "Success")) return(TRUE)
  }
  FALSE
}
tasks$done <- mapply(status_done, tasks$id, tasks$target_year)
message(sprintf("%d cells%s x %d years = %d (cell, year) tasks; %d already exported, %d to fetch, %d workers.",
                length(ids), if (is.null(tranche)) "" else sprintf(" (tranche %s)", tranche), length(years), nrow(tasks),
                sum(tasks$done), sum(!tasks$done), workers))
todo <- tasks[!tasks$done, ]
if (nrow(todo) == 0) { message("Nothing to fetch."); quit(save = "no") }

g100 <- sf::st_read(tof_path(cfg$reference$grid_gpkg), quiet = TRUE)
future::plan(future::multisession, workers = workers)
options(future.rng.onMisuse = "ignore")
tictoc::tic("NAIP fetch")
results <- furrr::future_map(seq_len(nrow(todo)), function(i) {
  tryCatch(process_aoi(aoi_id = todo$id[i], target_year = todo$target_year[i], g100_grid = g100,
                       export_dir = export_dir, buffer_m = buffer_m, run_snic = FALSE, export_1km_tight = TRUE),
           error = function(e) list(aoi_id = todo$id[i], target_year = todo$target_year[i], actual_year = NULL,
                                    status = paste("Error:", conditionMessage(e))))
}, .progress = TRUE, .options = furrr::furrr_options(seed = TRUE, chunk_size = 5))
tictoc::toc()

res <- dplyr::bind_rows(lapply(results, function(r) tibble::tibble(
  aoi_id = r$aoi_id, target_year = as.character(r$target_year),
  actual_year = if (is.null(r$actual_year)) NA_character_ else as.character(r$actual_year),
  status = as.character(r$status))))
res$year_matches <- !is.na(res$actual_year) & res$actual_year == res$target_year
dir.create(dirname(report), showWarnings = FALSE, recursive = TRUE)
readr::write_csv(res, report)
message(sprintf("Fetched: %d success (%d with the requested year, %d fallback), %d failed. Report: %s",
                sum(res$status == "Success"), sum(res$status == "Success" & res$year_matches),
                sum(res$status == "Success" & !res$year_matches), sum(res$status != "Success"), report))
if (any(res$status != "Success")) print(dplyr::count(res[res$status != "Success", ], status), n = 20)
