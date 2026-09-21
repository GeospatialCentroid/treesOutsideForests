# Monte Carlo replicates of the placeholder TOF per AOI ---------------------------
# Stands in for the model's replicate output: for every AOI of one year, n_rep
# draws of the TOF area the model might report. Like the placeholder itself it
# is NOT a measurement; it gives partners the volume and shape of the real
# product so the replicate-level aggregation can be built ahead of it.
#
# Each AOI gets its own normal distribution, clipped to [0, eligible area]:
#   mean = tof * (1 + bias_rel) + fp_frac * eligible
#   sd   = sqrt((cv * tof)^2 + (sd_floor_frac * eligible)^2)
# which encodes what is known about the model so far:
#   * it is very good at identifying land without trees, so an AOI whose
#     placeholder TOF is zero gets a tight distribution near zero: the mean is
#     only the false-positive floor (fp_frac of eligible land) and the spread
#     the sd floor, and clipping at zero puts a share of the draws at exactly 0;
#   * it over-predicts trees across the LRR, so an AOI with TOF is drawn
#     around a mean above its placeholder value (bias_rel), with a spread that
#     grows with the amount of TOF (cv).
# Draws are seeded once and generated MLRA by MLRA in MLRA_ID order, so the
# dataset is reproducible from the repository.

#' Per-AOI normal parameters from the placeholder table.
#'
#' @param aoi data frame with id, MLRA_ID, tof_m2, eligible_m2 (one year).
#' @return `aoi` with mc_mean, mc_sd added.
mc_params <- function(aoi, bias_rel, fp_frac, cv, sd_floor_frac) {
  aoi |>
    dplyr::mutate(
      mc_mean = pmin(tof_m2 * (1 + bias_rel) + fp_frac * eligible_m2, eligible_m2),
      mc_sd   = sqrt((cv * tof_m2)^2 + (sd_floor_frac * eligible_m2)^2))
}

#' n_rep clipped-normal draws for every row of `params`: a matrix, one row per AOI.
mc_draw <- function(params, n_rep) {
  n <- nrow(params)
  x <- matrix(stats::rnorm(n * n_rep, mean = params$mc_mean, sd = params$mc_sd), nrow = n)
  x[x < 0] <- 0
  over <- x > params$eligible_m2
  x[over] <- rep(params$eligible_m2, times = n_rep)[over]
  x
}

#' Summary of a replicate matrix per AOI: mean, sd, quantiles, share at zero.
mc_summary <- function(x, probs = c(0.025, 0.5, 0.975)) {
  q <- t(apply(x, 1, stats::quantile, probs = probs, names = FALSE))
  colnames(q) <- sprintf("q%s", sub("^0\\.", "", formatC(probs, format = "f", digits = 3)))
  tibble::as_tibble(cbind(
    tibble::tibble(rep_mean = rowMeans(x), rep_sd = apply(x, 1, stats::sd),
                   share_zero = rowMeans(x == 0)),
    tibble::as_tibble(q)))
}
