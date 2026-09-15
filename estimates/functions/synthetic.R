# Synthetic model output for exercising the estimators -------------------------
# Stands in for the partner's grid-level product until it exists: one row per
# sampled cell and target year in the pixel-count layout read_model_table()
# expects (id, target_year, actual_year, footprint_px, eligible_px, tof_px).
# Every MLRA gets its own generating parameters, so the stratified weighting
# is exercised, and the parameters are returned as a truth table the tests
# compare the estimates against.
#
# What the numbers are meant to look like (LRR F, 2012 to 2020):
#   * Most cells hold no trees outside forest at all (p_zero, 55 to 80 %); the
#     rest are right-skewed (lognormal, sdlog 0.8, capped at 50 %): many small
#     values, a few windbreak or riparian cells at 20 to 50 % of eligible land.
#     A heavier tail (sdlog 1) made some seeds miss the truth by 4 standard
#     errors: a draw that misses the big cells gets a low mean and a low
#     standard error together, so the usual 3 se tolerance is not safe.
#   * A cell's TOF share is nearly constant over the decade: a base value
#     with 3 % relative noise per year, plus a 1 % share of cells losing tree
#     cover from 2016 on and 1 % gaining from 2020 on. Those events are too
#     small to move an MLRA mean by more than a fraction of its standard
#     error, so the base-year truth holds for every year within tolerance.
#   * Masks matter little: NLCD forest is about 3 % of the LRR and Census
#     places well under 1 %, both zero-inflated at the cell level. The masked
#     share is held fixed across years for a cell.

#' Generating parameters per MLRA.
#'
#' @return tibble: MLRA_ID, forest_frac, urban_frac, masked_frac (expected
#'         masked share of a cell), p_zero, tof_frac_eligible (expected TOF
#'         share of eligible land, zeros included), tof_frac_total (of all land).
synthetic_truth <- function(mlra_ids, seed) {
  set.seed(seed)
  n <- length(mlra_ids)
  forest <- stats::runif(n, 0.01, 0.06)
  urban  <- stats::runif(n, 0.002, 0.01)
  tibble::tibble(
    MLRA_ID = mlra_ids,
    forest_frac = forest, urban_frac = urban, masked_frac = forest + urban,
    p_zero = stats::runif(n, 0.55, 0.80),
    tof_frac_eligible = stats::runif(n, 0.005, 0.05)
  ) |>
    dplyr::mutate(tof_frac_total = tof_frac_eligible * (1 - masked_frac))
}

#' One row per sampled cell and target year, pixel counts.
#'
#' @param sample_tbl  sample list (id, MLRA_ID); duplicate ids keep their first MLRA.
#' @param truth       output of synthetic_truth() covering every MLRA_ID in sample_tbl.
#' @param target_years integer vector, e.g. c(2012, 2016, 2020).
#' @param pixel_area_m2 pixel size; the cell is 1 km² so footprint_px = 1e6 / pixel_area_m2.
#' @return tibble: id, MLRA_ID, target_year, actual_year, footprint_px, eligible_px, tof_px.
synthetic_cells <- function(sample_tbl, truth, target_years, seed, pixel_area_m2 = 1,
                            noise_rel = 0.03, sdlog = 0.8, p_loss = 0.01, p_gain = 0.01) {
  cells <- dplyr::distinct(sample_tbl, id, .keep_all = TRUE)[, c("id", "MLRA_ID")]
  miss <- setdiff(unique(cells$MLRA_ID), truth$MLRA_ID)
  if (length(miss)) stop("No truth for MLRA(s) ", paste(miss, collapse = ", "))
  cells <- dplyr::left_join(cells, truth, by = "MLRA_ID")
  set.seed(seed)
  n <- nrow(cells)
  footprint <- round(1e6 / pixel_area_m2)

  # masked share: zero-inflated exponential for each mask, capped, held over years
  forest <- ifelse(stats::runif(n) < 0.35, pmin(stats::rexp(n, rate = 0.35 / cells$forest_frac), 0.9), 0)
  urban  <- ifelse(stats::runif(n) < 0.04, pmin(stats::rexp(n, rate = 0.04 / cells$urban_frac), 0.9), 0)
  eligible <- round(footprint * (1 - pmin(forest + urban, 0.95)))

  # base TOF share of eligible land: zero-inflated lognormal with the MLRA mean
  nonzero <- stats::runif(n) >= cells$p_zero
  m_pos   <- cells$tof_frac_eligible / (1 - cells$p_zero)          # mean of the non-zero part
  base    <- ifelse(nonzero, pmin(stats::rlnorm(n, log(m_pos) - sdlog^2 / 2, sdlog), 0.5), 0)

  # change events: a few cells lose cover from 2016 on, a few gain from 2020 on
  loss_cell <- stats::runif(n) < p_loss
  gain_cell <- stats::runif(n) < p_gain
  loss_mult <- stats::runif(n, 0.2, 0.6)
  gain_add  <- stats::runif(n, 0.005, 0.03)

  purrr::map_dfr(sort(as.integer(target_years)), function(ty) {
    frac <- base * (1 + noise_rel * stats::rnorm(n))
    if (ty >= 2016) frac <- ifelse(loss_cell, frac * loss_mult, frac)
    if (ty >= 2020) frac <- ifelse(gain_cell, frac + gain_add, frac)
    frac <- pmin(pmax(frac, 0), 0.5)
    tibble::tibble(
      id = cells$id, MLRA_ID = cells$MLRA_ID,
      target_year = ty,
      actual_year = if (ty == 2012L) 2011L else ty,   # 2012 imagery over F was flown in 2011
      footprint_px = footprint, eligible_px = eligible,
      tof_px = round(eligible * frac)
    )
  })
}
