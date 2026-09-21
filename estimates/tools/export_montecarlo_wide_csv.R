# Wide CSV of the Monte Carlo replicates for one MLRA, to hand to a partner:
# one row per AOI, aoi_id first, then one column per replicate (rep_1 ..
# rep_<n_rep>), values in m² rounded to one decimal. Reads the Parquet
# partition written by estimates/03_montecarlo_replicates.R. Run:
#   Rscript estimates/tools/export_montecarlo_wide_csv.R [MLRA_ID]
# The MLRA defaults to the one below.
source(here::here("shared/R/setup.R"))
pacman::p_load(dplyr, arrow, data.table)

mlra_id <- as.integer(commandArgs(trailingOnly = TRUE)[1])
if (is.na(mlra_id)) mlra_id <- 60L                     # 54, Rolling Soft Shale Plain

cfg_est <- tof_config()$estimates
cfg_mc  <- cfg_est$montecarlo
mc_dir  <- tof_path(cfg_mc$out_dir)
n_rep   <- as.integer(cfg_mc$n_rep)
part    <- file.path(mc_dir, "replicates", sprintf("mlra_id=%d", mlra_id), "part-0.parquet")
if (!file.exists(part)) stop("No replicate partition for MLRA ", mlra_id, ": ", part)
sym <- readr::read_csv(file.path(mc_dir, sprintf("montecarlo_summary_lrr_%s_%d.csv", cfg_est$llr_id, cfg_mc$year)),
                       show_col_types = FALSE, col_types = readr::cols(aoi_id = "c")) |>
  dplyr::filter(mlra_id == !!mlra_id) |> dplyr::pull(mlra_symbol) |> unique()
out <- file.path(mc_dir, sprintf("montecarlo_wide_lrr_%s_%d_mlra_%s.csv", cfg_est$llr_id, cfg_mc$year, sym))

message(sprintf("MLRA %d (%s): reading %s", mlra_id, sym, basename(part)))
long <- arrow::read_parquet(part, as_data_frame = FALSE)
ids  <- long$aoi_id$as_vector(); reps <- long$replicate$as_vector(); v <- long$tof_area_m2$as_vector()
rm(long)
aoi_ids <- sort(unique(ids))
n_aoi   <- length(aoi_ids)
stopifnot(length(v) == n_aoi * n_rep)

# one row per AOI, one column per replicate: fill by (AOI index, replicate)
wide <- matrix(NA_real_, nrow = n_aoi, ncol = n_rep)
wide[cbind(match(ids, aoi_ids), reps)] <- round(v, 1)
stopifnot(!anyNA(wide))
rm(ids, reps, v)

dt <- data.table::as.data.table(wide)
data.table::setnames(dt, sprintf("rep_%d", seq_len(n_rep)))
dt[, aoi_id := aoi_ids]
data.table::setcolorder(dt, "aoi_id")
message(sprintf("Writing %d AOIs x %d replicates to %s", n_aoi, n_rep, out))
data.table::fwrite(dt, out)
message(sprintf("Wrote %s (%.0f MB)", out, file.size(out) / 1e6))
