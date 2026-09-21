# ==============================================================================
# Area-weighted TOF estimates for every Monte Carlo replicate: per MLRA and for
# the LRR, both denominators, then summary statistics over the replicates.
# Reads the Parquet dataset of 03_montecarlo_replicates.R and the clipped AOI
# areas of 01_aoi_areas.R. Run from the root project:
#   source("estimates/04_replicate_estimates.R")
# Outputs under estimates$replicates$out_dir (ignored by git):
#   replicateEstimates_mlra_lrr_<LRR>_<year>.csv  per MLRA, denominator and replicate: estimate, se
#   replicateEstimates_lrr_<LRR>_<year>.csv       per denominator and replicate: the LRR estimate, se
#   replicateSummary_mlra_lrr_<LRR>_<year>.csv    per MLRA and denominator: mean, sd, quantiles, combined se
#   replicateSummary_lrr_<LRR>_<year>.csv         the same for the LRR
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(sf, dplyr, tidyr, purrr, readr, tibble, arrow, data.table, terra, exactextractr)
terra::terraOptions(progress = 0)
source(tof_root("estimates/functions/areas.R"))
source(tof_root("estimates/functions/estimators.R"))
source(tof_root("estimates/functions/replicate_estimators.R"))

cfg     <- tof_config()
cfg_est <- cfg$estimates
llr_id  <- cfg_est$llr_id
crs     <- cfg$crs
year    <- as.integer(cfg_est$montecarlo$year)
n_rep   <- as.integer(cfg_est$montecarlo$n_rep)
mc_dir  <- tof_path(cfg_est$montecarlo$out_dir)
est_dir <- tof_path(cfg_est$paths$out_dir)
out_dir <- tof_path(cfg_est$replicates$out_dir)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# --- Inputs -------------------------------------------------------------------
areas <- readr::read_csv(tof_path(cfg_est$paths$aoi_areas_csv), show_col_types = FALSE,
                         col_types = readr::cols(id = readr::col_character(), .default = readr::col_guess())) |>
  dplyr::filter(target_year == year) |>
  dplyr::transmute(id, MLRA_ID, footprint_m2 = aoi_m2, eligible_m2)
if (nrow(areas) == 0) stop("No AOI areas for ", year, "; run estimates/01_aoi_areas.R")
mlra <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE) |>
  dplyr::filter(LRRSYM == llr_id) |> sf::st_transform(crs)
mlra_names <- sf::st_drop_geometry(mlra)[, c("MLRA_ID", "MLRARSYM", "MLRA_NAME")]
strata_path <- file.path(est_dir, sprintf("strataAreas_lrr_%s_%d.csv", llr_id, year))
strata <- if (file.exists(strata_path)) readr::read_csv(strata_path, show_col_types = FALSE) else {
  message("Stratum areas, ", year)
  x <- stratum_areas(mlra, mask_layers(tof_path(cfg_est$paths$masks_outputs), llr_id, year, crs))
  readr::write_csv(x, strata_path); x
}

parts <- list.files(file.path(mc_dir, "replicates"), pattern = "^mlra_id=\\d+$", full.names = TRUE)
if (length(parts) == 0) stop("No replicate partitions under ", mc_dir, "; run estimates/03_montecarlo_replicates.R")
mlra_ids <- sort(as.integer(sub("^mlra_id=", "", basename(parts))))
message(sprintf("LRR %s, %d: %d MLRAs, %s replicates each.", llr_id, year, length(mlra_ids), format(n_rep, big.mark = ",")))

# --- Per MLRA, every replicate --------------------------------------------------
mlra_rep <- purrr::map_dfr(mlra_ids, function(h) {
  t0 <- Sys.time()
  long <- arrow::read_parquet(file.path(mc_dir, "replicates", sprintf("mlra_id=%d", h), "part-0.parquet"))
  X <- replicate_matrix(long); rm(long)
  a <- areas[areas$MLRA_ID == h, ]
  out <- replicate_mlra(X, a, mlra_id = h)
  message(sprintf("  MLRA %d: %d AOIs x %d replicates, %s", h, nrow(X), ncol(X), format(round(Sys.time() - t0, 1))))
  rm(X); gc(verbose = FALSE)
  out
})
mlra_rep <- mlra_rep |> dplyr::mutate(target_year = year, .after = MLRA_ID)
readr::write_csv(mlra_rep, file.path(out_dir, sprintf("replicateEstimates_mlra_lrr_%s_%d.csv", llr_id, year)))

# --- LRR, every replicate ----------------------------------------------------------
lrr_rep <- replicate_lrr(mlra_rep, strata) |> dplyr::mutate(LLR_ID = llr_id, target_year = year, .before = 1)
readr::write_csv(lrr_rep, file.path(out_dir, sprintf("replicateEstimates_lrr_%s_%d.csv", llr_id, year)))

# --- Summaries over the replicates ---------------------------------------------------
mlra_sum <- summarise_replicates(mlra_rep, by = c("MLRA_ID", "target_year", "denominator")) |>
  dplyr::left_join(mlra_names, by = "MLRA_ID") |>
  dplyr::relocate(MLRARSYM, MLRA_NAME, .after = MLRA_ID)
lrr_sum <- summarise_replicates(lrr_rep, by = c("LLR_ID", "target_year", "denominator"))
readr::write_csv(mlra_sum, file.path(out_dir, sprintf("replicateSummary_mlra_lrr_%s_%d.csv", llr_id, year)))
readr::write_csv(lrr_sum,  file.path(out_dir, sprintf("replicateSummary_lrr_%s_%d.csv", llr_id, year)))

# --- Optional: the partner's wide CSV gives the same numbers -----------------------------
wide_path <- cfg_est$replicates$wide_csv_check
if (!is.null(wide_path) && file.exists(tof_path(wide_path))) {
  Xw <- read_wide_csv_matrix(tof_path(wide_path))
  # the MLRA whose AOI set the file holds (an id shared by two MLRAs sits in both)
  h <- mlra_ids[vapply(mlra_ids, function(k) setequal(rownames(Xw), areas$id[areas$MLRA_ID == k]), logical(1))]
  if (length(h) != 1) stop("The wide CSV's AOIs do not match exactly one MLRA's AOI set.")
  w  <- replicate_mlra(Xw, areas[areas$MLRA_ID == h, ], mlra_id = h)
  p  <- mlra_rep |> dplyr::filter(MLRA_ID == h)
  d  <- max(abs(w$estimate - p$estimate))
  message(sprintf("Wide CSV check, MLRA %d: max |estimate difference| = %.2e (CSV values are rounded to 0.1 m2).", h, d))
  if (d > 1e-6) warning("Wide CSV and Parquet results differ by more than 1e-6 for MLRA ", h)
}

print(mlra_sum |> dplyr::filter(denominator == "total") |>
        dplyr::select(MLRARSYM, pct_mean, pct_sd, pct_q025, pct_q975, pct_se_sampling, pct_se_combined), n = Inf)
print(lrr_sum |> dplyr::select(denominator, pct_mean, pct_sd, pct_q025, pct_q975, pct_se_sampling, pct_se_combined))
message("Wrote ", out_dir)
