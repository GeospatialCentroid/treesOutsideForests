# Stratified ratio estimators --------------------------------------------------
# MLRAs are strata; within an MLRA every sampled cell had the same inclusion
# probability, so the stratum estimate is a ratio of sample totals,
#   R_h = sum(t_hi) / sum(d_hi),
# and the LRR estimate combines the strata with wall-to-wall areas as weights.
# Two denominators are always produced, told apart by a `denominator` column:
#   "eligible": d = eligible_m2 (not forest, not a Census place); weights E_h
#   "total":    d = footprint_m2 (the cell inside its MLRA);       weights A_h
# Standard errors are the linearised ratio-estimator form treating each
# stratum as a simple random sample, which is conservative for a systematic
# lattice. No finite population correction: 1400 cells is a small fraction of
# any MLRA.

DENOMINATORS <- c(eligible = "eligible_m2", total = "footprint_m2")

#' Per-MLRA estimates for every year and denominator.
#'
#' @param cells data frame with MLRA_ID, target_year, footprint_m2,
#'              eligible_m2 and tof_m2 (m²). Rows with NA tof_m2 are dropped
#'              and counted in n_missing.
#' @return tibble: MLRA_ID, target_year, denominator, n, n_missing, sum_tof_m2,
#'         sum_denom_m2, estimate (fraction), se, pct, pct_se.
estimate_mlra <- function(cells) {
  needed <- c("MLRA_ID", "target_year", "footprint_m2", "eligible_m2", "tof_m2")
  miss <- setdiff(needed, names(cells))
  if (length(miss)) stop("cells is missing: ", paste(miss, collapse = ", "))
  purrr::map_dfr(names(DENOMINATORS), function(den) {
    cc <- cells
    cc$.d <- cc[[DENOMINATORS[[den]]]]
    cc |>
      dplyr::group_by(MLRA_ID, target_year) |>
      dplyr::group_modify(~ ratio_estimate(.x$tof_m2, .x$.d)) |>
      dplyr::ungroup() |>
      dplyr::mutate(denominator = den, .after = target_year)
  }) |>
    dplyr::mutate(pct = 100 * estimate, pct_se = 100 * se)
}

#' Ratio of totals with its linearised standard error.
ratio_estimate <- function(t, d) {
  ok <- !is.na(t) & !is.na(d)
  t <- t[ok]; d <- d[ok]
  n <- length(t)
  if (n == 0 || sum(d) <= 0) {
    return(tibble::tibble(n = n, n_missing = sum(!ok), sum_tof_m2 = sum(t), sum_denom_m2 = sum(d),
                          estimate = NA_real_, se = NA_real_))
  }
  R <- sum(t) / sum(d)
  e <- t - R * d
  v <- if (n > 1) sum(e^2) / ((n - 1) * n * mean(d)^2) else NA_real_
  tibble::tibble(n = n, n_missing = sum(!ok), sum_tof_m2 = sum(t), sum_denom_m2 = sum(d),
                 estimate = R, se = sqrt(v))
}

#' LRR estimates: the MLRA estimates combined with the stratum areas.
#'
#' @param mlra_est output of estimate_mlra().
#' @param strata   data frame with MLRA_ID, target_year, total_m2, eligible_m2
#'                 for the whole MLRA polygon (from stratum_areas()).
#' @return tibble per (target_year, denominator): n_mlra, n_cells, area_m2 (the
#'         LRR denominator), tof_area_m2, estimate, se, pct, pct_se.
estimate_lrr <- function(mlra_est, strata) {
  weights <- strata |>
    dplyr::select(MLRA_ID, target_year, eligible = eligible_m2, total = total_m2) |>
    tidyr::pivot_longer(c(eligible, total), names_to = "denominator", values_to = "area_m2")
  joined <- dplyr::inner_join(mlra_est, weights, by = c("MLRA_ID", "target_year", "denominator"))
  lost <- dplyr::anti_join(mlra_est, weights, by = c("MLRA_ID", "target_year", "denominator"))
  if (nrow(lost) > 0) stop("No stratum areas for MLRA(s) ", paste(unique(lost$MLRA_ID), collapse = ", "))
  # Output names must not shadow inputs used later in the same summarise():
  # summarise() lets a later expression see an earlier result under its name.
  joined |>
    dplyr::filter(!is.na(estimate)) |>
    dplyr::group_by(target_year, denominator) |>
    dplyr::mutate(w = area_m2 / sum(area_m2)) |>
    dplyr::summarise(
      n_mlra      = dplyr::n(),
      n_cells     = sum(n),
      tof_area_m2 = sum(estimate * area_m2),
      lrr_area_m2 = sum(area_m2),
      lrr_se      = sqrt(sum(w^2 * se^2)),
      .groups = "drop"
    ) |>
    dplyr::transmute(target_year, denominator, n_mlra, n_cells, area_m2 = lrr_area_m2, tof_area_m2,
                     estimate = tof_area_m2 / lrr_area_m2, se = lrr_se,
                     pct = 100 * estimate, pct_se = 100 * se)
}
