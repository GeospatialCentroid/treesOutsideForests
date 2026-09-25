# ==============================================================================
# Optional radiometric harmonisation of the NAIP exports across years.
# ==============================================================================
# NAIP is delivered as uncalibrated digital numbers, and the same ground can
# shift its whole histogram between flight years (haze, sensor, vendor
# stretch). A fixed model reads that shift as land-cover change. This step
# builds a second export tree, data/naip/harmonized/, laid out exactly like
# data/naip/exportData/ so any downstream reader can point at either:
#
#   - "consensus" mode (default): for a cell with three years, pairwise KS
#     distances on the blue and NIR bands pick the year that stands apart; it
#     is remapped by quantile matching to the most recent of the other two,
#     but only when its drift passes both gates (absolute and relative to the
#     pair's own difference). Stable stacks are left untouched.
#   - "reference" mode: every year is remapped to the reference year.
#
# Untouched years are symlinked into the harmonised tree, so it is complete.
# Every cell-year gets a harmonization.json saying what was done and why, and
# the run compiles them into data/naip/harmonized/harmonization_log.csv.
#
# Method ported from neymanSampling/scripts/imageHarmonization.R and
# docs/histNormalization.Rmd; settings live in config.yml `harmonize`.
#
#   Rscript harmonize/0_run.R              # every cell in the export tree
#   Rscript harmonize/0_run.R <id> [<id>]  # only these cells
#   Rscript harmonize/0_run.R --mode=reference --reference=2020 --out=data/naip/harmonized_ref2020 [<id> ...]
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(terra, furrr, future, jsonlite, readr, dplyr)
source(tof_root("harmonize/functions/histogram_matching.R"))
terra::terraOptions(progress = 0)

cfg <- tof_config()
ch  <- cfg$harmonize
export_dir <- tof_path(ch$paths$export_dir)
overwrite  <- isTRUE(ch$overwrite)

# Optional overrides: --mode=reference --reference=2020 --out=<dir>, then cell ids.
args <- commandArgs(trailingOnly = TRUE)
opts <- args[grepl("^--", args)]; args <- args[!grepl("^--", args)]
opt <- function(name, default) { v <- sub(paste0("^--", name, "="), "", opts[grepl(paste0("^--", name, "="), opts)]); if (length(v)) v[1] else default }
ch$mode <- opt("mode", ch$mode); ch$reference_year <- opt("reference", ch$reference_year)
out_dir <- tof_path(opt("out", ch$paths$out_dir)); dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
ids <- if (length(args) > 0) args else {
  unique(sub("^aoi_(.+)_\\d{4}$", "\\1", list.files(export_dir, pattern = "^aoi_.+_\\d{4}$")))
}
if (!is.null(ch$cells) && length(args) == 0) ids <- intersect(ids, as.character(ch$cells))

message(sprintf("Harmonising %d cells (%s mode, reference %s, KS on %s, threshold %.2f and %.1fx the consensus distance, %d quantiles) -> %s",
                length(ids), ch$mode, ch$reference_year, paste(ch$eval_bands, collapse = "+"),
                ch$ks_threshold, ch$ks_relative, ch$n_quantiles, out_dir))

future::plan(future::multisession, workers = ch$workers)
options(future.rng.onMisuse = "ignore")
t0 <- Sys.time()
rows <- furrr::future_map(ids, function(id) {
  tryCatch(
    harmonize_cell(id, export_dir, out_dir, mode = ch$mode, reference_year = ch$reference_year,
                   bands = ch$eval_bands, sample_size = ch$ks_sample, threshold = ch$ks_threshold,
                   relative = ch$ks_relative, n_quantiles = ch$n_quantiles, overwrite = overwrite),
    error = function(e) data.frame(id = id, year = NA_character_, action = "error", reference_year = NA_character_,
                                   ks_to_reference = NA_real_, mode = ch$mode, note = conditionMessage(e),
                                   timestamp = format(Sys.time(), "%Y-%m-%d %H:%M:%S"), stringsAsFactors = FALSE))
}, .progress = TRUE, .options = furrr::furrr_options(seed = TRUE, chunk_size = 4))
log <- dplyr::bind_rows(rows)
message(sprintf("Done in %.1f min.", as.numeric(difftime(Sys.time(), t0, units = "mins"))))

# Compile the log from every harmonization.json so reruns on subsets still
# yield the whole picture.
jsons <- list.files(out_dir, pattern = "^harmonization\\.json$", recursive = TRUE, full.names = TRUE)
nz <- function(v, as = as.character) if (is.null(v) || length(v) == 0) as(NA) else as(v)   # JSON null -> NA
full <- dplyr::bind_rows(lapply(jsons, function(f) {
  j <- jsonlite::fromJSON(f)
  data.frame(id = j$id, year = nz(j$year), action = j$action, reference_year = nz(j$reference_year),
             ks_to_reference = round(nz(j$ks_to_reference, as.numeric), 4), mode = j$mode, note = nz(j$note),
             timestamp = j$timestamp, stringsAsFactors = FALSE)
})) |> dplyr::arrange(id, year)
readr::write_csv(full, file.path(out_dir, "harmonization_log.csv"))

message("\n--- Harmonisation summary (whole tree) ---")
print(as.data.frame(dplyr::count(full, action)), row.names = FALSE)
norm <- full[full$action == "normalized", ]
if (nrow(norm) > 0) {
  message("Normalised years by imagery year:")
  print(as.data.frame(dplyr::count(norm, year, reference_year)), row.names = FALSE)
  message(sprintf("KS to reference over normalised years: median %.3f, max %.3f", median(norm$ks_to_reference), max(norm$ks_to_reference)))
}
errs <- log[log$action == "error", ]
if (nrow(errs) > 0) { message("\nErrors:"); print(errs[, c("id", "note")], row.names = FALSE) }
message("\nLog: ", file.path(out_dir, "harmonization_log.csv"))
