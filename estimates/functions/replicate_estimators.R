# Area-weighted estimates for every Monte Carlo replicate ------------------------
# The same estimator as functions/estimators.R, applied to a matrix of
# replicates at once. Per MLRA the TOF area of AOI i in replicate r is X[i, r]
# and the denominator d[i] (the clipped AOI's total or eligible area) is the
# same in every replicate, so
#   R_r = sum_i X[i, r] / sum_i d[i]
# is a column sum, and the linearised standard error of ratio_estimate(),
#   Var(R_r) = sum_i (X[i, r] - R_r d[i])^2 / ((n - 1) n mean(d)^2),
# is a column sum of squared residuals. The LRR combines the MLRAs replicate by
# replicate with the stratum areas as weights, as estimate_lrr() does.
# Across replicates the spread of R_r is the model-side uncertainty; the mean
# sampling variance across replicates is the design-side part; the combined
# standard error is the square root of their sum.

#' AOI x replicate matrix from the long replicate table of one MLRA.
#'
#' @param long data frame with aoi_id, replicate, tof_area_m2 (one MLRA).
#' @param aoi_ids the row order wanted; defaults to sorted unique ids.
#' @return numeric matrix with rownames aoi_ids and one column per replicate.
replicate_matrix <- function(long, aoi_ids = sort(unique(long$aoi_id))) {
  n_rep <- max(long$replicate)
  if (nrow(long) != length(aoi_ids) * n_rep) stop("long table is not a full AOI x replicate grid")
  x <- matrix(NA_real_, nrow = length(aoi_ids), ncol = n_rep, dimnames = list(aoi_ids, NULL))
  x[cbind(match(long$aoi_id, aoi_ids), long$replicate)] <- long$tof_area_m2
  if (anyNA(x)) stop("replicate matrix has gaps")
  x
}

#' The same matrix from the partner's wide CSV (aoi_id, rep_1 .. rep_n).
read_wide_csv_matrix <- function(path) {
  dt <- data.table::fread(path)
  ids <- as.character(dt[[1]])
  x <- as.matrix(dt[, -1])
  dimnames(x) <- list(ids, NULL)
  x
}

#' Ratio-of-sums estimate and standard error for every column of X.
#'
#' @param X AOI x replicate matrix of TOF areas (m²).
#' @param d denominator area per AOI (m²), same order as the rows of X.
#' @return tibble: replicate, n, sum_tof_m2, sum_denom_m2, estimate, se.
replicate_ratio <- function(X, d) {
  stopifnot(nrow(X) == length(d), !anyNA(d))
  n <- nrow(X)
  sum_d <- sum(d)
  sum_t <- colSums(X)
  if (sum_d <= 0) {
    return(tibble::tibble(replicate = seq_len(ncol(X)), n = n, sum_tof_m2 = sum_t, sum_denom_m2 = sum_d,
                          estimate = NA_real_, se = NA_real_))
  }
  R <- sum_t / sum_d
  ss <- colSums((X - outer(d, R))^2)
  v  <- if (n > 1) ss / ((n - 1) * n * mean(d)^2) else rep(NA_real_, ncol(X))
  tibble::tibble(replicate = seq_len(ncol(X)), n = n, sum_tof_m2 = sum_t, sum_denom_m2 = sum_d,
                 estimate = R, se = sqrt(v))
}

#' Per-MLRA estimates for every replicate and both denominators.
#'
#' @param X     AOI x replicate matrix for one MLRA.
#' @param areas data frame with id, footprint_m2 (total) and eligible_m2 for the
#'              same AOIs; matched to the rows of X by id.
#' @return tibble: MLRA_ID, denominator, replicate, n, sums, estimate, se, pct, pct_se.
replicate_mlra <- function(X, areas, mlra_id) {
  m <- match(rownames(X), areas$id)
  if (anyNA(m)) stop("AOIs in the replicate matrix are missing from the area table: ", sum(is.na(m)))
  purrr::map_dfr(names(DENOMINATORS), function(den) {
    replicate_ratio(X, areas[[DENOMINATORS[[den]]]][m]) |>
      dplyr::mutate(MLRA_ID = mlra_id, denominator = den, .before = 1)
  }) |>
    dplyr::mutate(pct = 100 * estimate, pct_se = 100 * se)
}

#' LRR estimate for every replicate: MLRAs combined with the stratum areas.
#'
#' @param mlra_rep output of replicate_mlra() stacked over MLRAs.
#' @param strata   data frame with MLRA_ID, total_m2, eligible_m2 (whole MLRA).
#' @return tibble per (denominator, replicate): n_mlra, n_cells, area_m2,
#'         tof_area_m2, estimate, se, pct, pct_se.
replicate_lrr <- function(mlra_rep, strata) {
  weights <- strata |>
    dplyr::select(MLRA_ID, eligible = eligible_m2, total = total_m2) |>
    tidyr::pivot_longer(c(eligible, total), names_to = "denominator", values_to = "area_m2")
  joined <- dplyr::inner_join(mlra_rep, weights, by = c("MLRA_ID", "denominator"))
  lost <- dplyr::anti_join(mlra_rep, weights, by = c("MLRA_ID", "denominator"))
  if (nrow(lost) > 0) stop("No stratum areas for MLRA(s) ", paste(unique(lost$MLRA_ID), collapse = ", "))
  joined |>
    dplyr::filter(!is.na(estimate)) |>
    dplyr::group_by(denominator, replicate) |>
    dplyr::mutate(w = area_m2 / sum(area_m2)) |>
    dplyr::summarise(n_mlra = dplyr::n(), n_cells = sum(n),
                     tof_area_m2 = sum(estimate * area_m2), lrr_area_m2 = sum(area_m2),
                     lrr_se = sqrt(sum(w^2 * se^2)), .groups = "drop") |>
    dplyr::transmute(denominator, replicate, n_mlra, n_cells, area_m2 = lrr_area_m2, tof_area_m2,
                     estimate = tof_area_m2 / lrr_area_m2, se = lrr_se, pct = 100 * estimate, pct_se = 100 * se)
}

#' Summary of the replicate estimates, per group.
#'
#' @param est tibble with estimate and se (fractions) and the grouping columns.
#' @param by  grouping column names.
#' @return one row per group: n_rep, mean, sd (model-side), median, q025,
#'         q975, min, max, se_sampling (root mean sampling variance),
#'         se_combined (sqrt(sd^2 + se_sampling^2)), all as fractions, and the
#'         same in percent (pct_ columns).
summarise_replicates <- function(est, by) {
  est |>
    dplyr::group_by(dplyr::across(dplyr::all_of(by))) |>
    dplyr::summarise(
      n_rep  = dplyr::n(),
      mean   = mean(estimate), sd = stats::sd(estimate), median = stats::median(estimate),
      q025   = stats::quantile(estimate, 0.025, names = FALSE),
      q975   = stats::quantile(estimate, 0.975, names = FALSE),
      min    = min(estimate), max = max(estimate),
      se_sampling = sqrt(mean(se^2)),
      .groups = "drop") |>
    dplyr::mutate(se_combined = sqrt(sd^2 + se_sampling^2),
                  dplyr::across(c(mean, sd, median, q025, q975, min, max, se_sampling, se_combined),
                                ~ 100 * .x, .names = "pct_{.col}"))
}
