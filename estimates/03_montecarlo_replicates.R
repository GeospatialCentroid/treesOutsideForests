# ==============================================================================
# Monte Carlo replicates of the placeholder TOF for every AOI of one year:
# n_rep draws per AOI from a clipped normal (functions/montecarlo.R), written
# as a hive-partitioned Parquet dataset partners can read as one table with
# arrow, DuckDB, pandas or Spark. Run after 02_placeholder_tof.R:
#   source("estimates/03_montecarlo_replicates.R")
# Settings: estimates$montecarlo in config.yml. NOT model output.
# Outputs under estimates$montecarlo$out_dir (ignored by git):
#   replicates/mlra_id=<id>/part-0.parquet   long table: aoi_id, replicate, tof_area_m2
#                                            (the Parquet dataset sits in its own folder so a
#                                            directory reader does not trip over the files below)
#   montecarlo_summary_lrr_<LRR>_<year>.csv   per-AOI mean, sd, quantiles, share at zero,
#                                             next to the placeholder value and the parameters
#   README.txt
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(dplyr, purrr, readr, tibble, arrow)
source(tof_root("estimates/functions/montecarlo.R"))

cfg     <- tof_config()
cfg_est <- cfg$estimates
cfg_mc  <- cfg_est$montecarlo
llr_id  <- cfg_est$llr_id
year    <- as.integer(cfg_mc$year)
n_rep   <- as.integer(cfg_mc$n_rep)
out_dir <- tof_path(cfg_mc$out_dir)
ph_path <- file.path(tof_path(cfg_est$placeholder$out_dir), sprintf("placeholder_tof_lrr_%s.csv", llr_id))
if (!file.exists(ph_path)) stop("Run estimates/02_placeholder_tof.R first: no ", ph_path)

aoi <- readr::read_csv(ph_path, show_col_types = FALSE,
                       col_types = readr::cols(aoi_id = readr::col_character(), .default = readr::col_guess())) |>
  dplyr::filter(year == !!year) |>
  dplyr::transmute(id = aoi_id, MLRA_ID = mlra_id, mlra_symbol, tof_m2 = tof_area_m2, eligible_m2 = eligible_area_m2) |>
  dplyr::arrange(MLRA_ID, id)
if (nrow(aoi) == 0) stop("No placeholder rows for year ", year)
params <- mc_params(aoi, bias_rel = cfg_mc$bias_rel, fp_frac = cfg_mc$fp_frac,
                    cv = cfg_mc$cv, sd_floor_frac = cfg_mc$sd_floor_frac)
message(sprintf("LRR %s, %d: %d AOIs x %s replicates = %s values.", llr_id, year, nrow(params),
                format(n_rep, big.mark = ","), format(nrow(params) * n_rep, big.mark = ",")))

if (dir.exists(out_dir)) unlink(out_dir, recursive = TRUE)
dir.create(out_dir, recursive = TRUE)
set.seed(cfg_mc$seed)
summary_tbl <- purrr::map_dfr(sort(unique(params$MLRA_ID)), function(h) {
  p <- params[params$MLRA_ID == h, ]
  t0 <- Sys.time()
  x <- mc_draw(p, n_rep)
  part_dir <- file.path(out_dir, "replicates", sprintf("mlra_id=%d", h))
  dir.create(part_dir, recursive = TRUE)
  tbl <- arrow::arrow_table(
    # plain strings, not an Arrow dictionary: per-file dictionaries cannot be
    # unified across partitions by a dataset reader (n_distinct fails), and
    # Parquet dictionary-encodes the column internally anyway
    aoi_id      = arrow::Array$create(rep(p$id, times = n_rep), type = arrow::utf8()),
    replicate   = arrow::Array$create(rep(seq_len(n_rep), each = nrow(p)), type = arrow::int32()),
    tof_area_m2 = arrow::Array$create(as.vector(x), type = arrow::float32()))
  arrow::write_parquet(tbl, file.path(part_dir, "part-0.parquet"), compression = "zstd")
  s <- dplyr::bind_cols(p, mc_summary(x))
  message(sprintf("  MLRA %d (%s): %d AOIs, %s, %.0f MB", h, p$mlra_symbol[1], nrow(p),
                  format(round(Sys.time() - t0, 1)), file.size(file.path(part_dir, "part-0.parquet")) / 1e6))
  rm(x, tbl); gc(verbose = FALSE)
  s
})

summary_out <- summary_tbl |>
  dplyr::transmute(aoi_id = id, mlra_id = MLRA_ID, mlra_symbol, year = year, n_rep = n_rep,
                   placeholder_tof_m2 = tof_m2, eligible_area_m2 = eligible_m2,
                   mc_mean_param = round(mc_mean, 1), mc_sd_param = round(mc_sd, 1),
                   rep_mean = round(rep_mean, 1), rep_sd = round(rep_sd, 1),
                   rep_q025 = round(q025, 1), rep_q500 = round(q500, 1), rep_q975 = round(q975, 1),
                   share_zero = round(share_zero, 4))
readr::write_csv(summary_out, file.path(out_dir, sprintf("montecarlo_summary_lrr_%s_%d.csv", llr_id, year)))

writeLines(c(
  sprintf("Monte Carlo replicates of the placeholder trees-outside-forest (TOF) area, LRR %s, year %d.", llr_id, year),
  sprintf("Generated %s by treesOutsideForests/estimates/03_montecarlo_replicates.R (seed %d).", format(Sys.Date()), cfg_mc$seed),
  "",
  "NOT MODEL OUTPUT. These are synthetic draws around the placeholder TOF of placeholder_tof_lrr_F.xlsx, made so the replicate-level aggregation can be built and tested at full volume before the real replicates exist.",
  "",
  "Layout: replicates/ is a hive-partitioned Parquet dataset, one folder per MLRA (replicates/mlra_id=<id>/part-0.parquet). Read the replicates folder as one table, e.g.",
  "  R:      arrow::open_dataset('replicates') |> dplyr::filter(mlra_id == 60) |> dplyr::collect()",
  "  Python: pyarrow.parquet.read_table('replicates')  or  duckdb: SELECT * FROM read_parquet('replicates/*/*.parquet', hive_partitioning=true)",
  "Columns:",
  "  aoi_id        cell id, as in placeholder_tof_lrr_F.xlsx sheet aoi_tof (join on aoi_id + mlra_id)",
  "  mlra_id       from the folder name; an AOI split between two MLRAs appears under both with its own draws",
  "  replicate     1 .. n_rep",
  "  tof_area_m2   the replicate's TOF area in square metres (float32), between 0 and the AOI's eligible area",
  sprintf("%s AOIs x %s replicates = %s rows.", format(nrow(params), big.mark = ","), format(n_rep, big.mark = ","), format(nrow(params) * n_rep, big.mark = ",")),
  "",
  "How each AOI's draws were made: a normal distribution clipped to [0, eligible area] with",
  sprintf("  mean = placeholder_tof * (1 + %.2f) + %.4f * eligible_area", cfg_mc$bias_rel, cfg_mc$fp_frac),
  sprintf("  sd   = sqrt((%.2f * placeholder_tof)^2 + (%.4f * eligible_area)^2)", cfg_mc$cv, cfg_mc$sd_floor_frac),
  "so an AOI with no TOF is drawn tightly around a small false-positive floor (the model is very good at identifying land without trees; clipping puts a share of its draws at exactly 0), and an AOI with TOF is drawn around a mean above its placeholder value (the model over-predicts trees across the LRR) with a spread that grows with the amount of TOF.",
  "",
  sprintf("montecarlo_summary_lrr_%s_%d.csv has, per AOI, the parameters used and the draws' mean, sd, 2.5 / 50 / 97.5 percentiles and share at zero.", llr_id, year)
), file.path(out_dir, "README.txt"))

print(summary_out |> dplyr::group_by(mlra_symbol, has_tof = placeholder_tof_m2 > 0) |>
        dplyr::summarise(n = dplyr::n(), placeholder = mean(placeholder_tof_m2), rep_mean = mean(rep_mean),
                         rep_sd = mean(rep_sd), share_zero = mean(share_zero), .groups = "drop"), n = Inf)
message("Wrote ", out_dir)
