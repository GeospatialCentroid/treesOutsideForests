# ==============================================================================
# T3(a): the estimator run on a model's rasters against the same estimator run
# on the reference masks, over the same cells (TESTING_PLAN.md step 4).
#   Rscript estimates/tools/compare_model_truth.R <model_out_dir> <truth_out_dir> <out_csv>
# Both folders are outputs of 00_run_estimates.R (estimates_mlra_lrr_F.csv and
# estimates_lrr_F.csv). Writes one table with, per level (MLRA or LRR), target
# year and denominator: the truth and model estimates in percent, their standard
# errors, the difference in percentage points and its ratio, and whether the
# difference exceeds two truth standard errors.
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(dplyr, readr, tibble)

a <- commandArgs(trailingOnly = TRUE)
if (length(a) < 3) stop("usage: compare_model_truth.R <model_out_dir> <truth_out_dir> <out_csv>")
model_dir <- a[1]; truth_dir <- a[2]; out_csv <- a[3]
llr_id <- tof_config()$estimates$llr_id

read_both <- function(file, keys) {
  m <- readr::read_csv(file.path(model_dir, file), show_col_types = FALSE)
  t <- readr::read_csv(file.path(truth_dir, file), show_col_types = FALSE)
  dplyr::inner_join(
    dplyr::select(t, dplyr::all_of(keys), n_truth = dplyr::any_of("n"), truth_pct = pct, truth_pct_se = pct_se,
                  truth_tof_m2 = dplyr::any_of(c("sum_tof_m2", "tof_area_m2"))),
    dplyr::select(m, dplyr::all_of(keys), n_model = dplyr::any_of("n"), model_pct = pct, model_pct_se = pct_se,
                  model_tof_m2 = dplyr::any_of(c("sum_tof_m2", "tof_area_m2"))),
    by = keys)
}

mlra <- read_both(sprintf("estimates_mlra_lrr_%s.csv", llr_id), c("MLRA_ID", "target_year", "denominator")) |>
  dplyr::left_join(readr::read_csv(file.path(truth_dir, sprintf("estimates_mlra_lrr_%s.csv", llr_id)), show_col_types = FALSE) |>
                     dplyr::distinct(MLRA_ID, MLRARSYM, MLRA_NAME), by = "MLRA_ID") |>
  dplyr::mutate(MLRA_ID = as.character(MLRA_ID), level = "MLRA", label = MLRARSYM, .before = 1)
lrr <- read_both(sprintf("estimates_lrr_%s.csv", llr_id), c("target_year", "denominator")) |>
  dplyr::mutate(level = "LRR", label = llr_id, MLRA_ID = NA_character_, MLRARSYM = NA_character_, MLRA_NAME = NA_character_, .before = 1)

out <- dplyr::bind_rows(mlra, lrr) |>
  dplyr::mutate(diff_pp = model_pct - truth_pct,
                ratio = model_tof_m2 / truth_tof_m2,
                diff_in_truth_se = diff_pp / truth_pct_se,
                beyond_2se = abs(diff_in_truth_se) > 2) |>
  dplyr::arrange(level != "LRR", target_year, denominator, label)
readr::write_csv(out, out_csv)

show <- out |> dplyr::filter(denominator == "total") |>
  dplyr::transmute(level, label, target_year, n = n_truth, truth_pct = round(truth_pct, 3), model_pct = round(model_pct, 3),
                   diff_pp = round(diff_pp, 3), ratio = round(ratio, 3), truth_se = round(truth_pct_se, 3),
                   z = round(diff_in_truth_se, 2))
print(show, n = Inf)
cat(sprintf("\n%d of %d MLRA-year estimates (total denominator) differ from the truth by more than two truth standard errors.\n",
            sum(out$beyond_2se[out$level == "MLRA" & out$denominator == "total"], na.rm = TRUE),
            sum(out$level == "MLRA" & out$denominator == "total")))
cat("Wrote", out_csv, "\n")
