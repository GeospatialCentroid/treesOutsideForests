# Placeholder trees-outside-forest area per clipped AOI ----------------------------
# Stands in for the model output so partners can build their MLRA-level
# aggregation on realistically shaped data. It is NOT a measurement.
#
# Two properties are imposed:
#   1. Calibration. Within every MLRA and year, the area-weighted TOF share of
#      the AOIs, sum(tof) / sum(aoi area), equals a target: the MLRA's own NLCD
#      forest share (forest area / MLRA area from the masks). So an MLRA-level
#      aggregation of the placeholder returns the NLCD forest share exactly.
#   2. Shape. Most AOIs have no TOF at all; the rest follow a lognormal with a
#      long right tail, capped at a share of the AOI's eligible land. TOF can
#      only sit on eligible (unmasked) land, so an AOI's TOF area is a share of
#      its eligible area, never of its masked area. A fully masked AOI gets 0.
#
# Longitudinal behaviour follows functions/synthetic.R: an AOI's relative level
# is drawn once and carried across years with small noise, a few AOIs losing
# cover from 2016 and a few gaining from 2020. Every draw is seeded.

#' Assign placeholder TOF areas to the clipped AOIs.
#'
#' @param aoi     data frame with id, MLRA_ID, target_year, aoi_m2, eligible_m2.
#' @param targets data frame with MLRA_ID, target_year, target_share: the share
#'                of the MLRA's whole area the AOIs' TOF must average to.
#' @param seed    integer.
#' @param p_zero  share of AOIs with no TOF in any year.
#' @param sdlog   lognormal spread of the non-zero AOIs' relative level.
#' @param cap     an AOI's TOF is at most this share of its eligible land.
#' @return `aoi` with tof_m2, tof_share_eligible and the draw's relative level
#'         (rel_level, 0 for the zero AOIs) added.
placeholder_tof <- function(aoi, targets, seed, p_zero = 0.65, sdlog = 1, cap = 0.5,
                            noise_rel = 0.03, p_loss = 0.01, p_gain = 0.01) {
  needed <- c("id", "MLRA_ID", "target_year", "aoi_m2", "eligible_m2")
  miss <- setdiff(needed, names(aoi))
  if (length(miss)) stop("aoi is missing: ", paste(miss, collapse = ", "))
  key <- dplyr::distinct(aoi, id, MLRA_ID)
  set.seed(seed)
  n <- nrow(key)
  key$rel_level <- ifelse(stats::runif(n) < p_zero, 0, stats::rlnorm(n, 0, sdlog))
  key$loss_mult <- ifelse(stats::runif(n) < p_loss, stats::runif(n, 0.2, 0.6), 1)
  key$gain_add  <- ifelse(stats::runif(n) < p_gain, stats::runif(n, 0.3, 1.5), 0)
  out <- dplyr::inner_join(aoi, key, by = c("id", "MLRA_ID"))
  out$noise <- 1 + noise_rel * stats::rnorm(nrow(out))
  out <- out |>
    dplyr::mutate(level = rel_level * noise,
                  level = ifelse(target_year >= 2016, level * loss_mult, level),
                  level = ifelse(target_year >= 2020, level + gain_add, level),
                  level = pmax(level, 0)) |>
    dplyr::select(-noise, -loss_mult, -gain_add)
  out <- dplyr::left_join(out, targets, by = c("MLRA_ID", "target_year"))
  if (anyNA(out$target_share)) stop("No target share for some MLRA-years.")
  out |>
    dplyr::group_by(MLRA_ID, target_year) |>
    dplyr::group_modify(~ calibrate_group(.x, cap = cap)) |>
    dplyr::ungroup() |>
    dplyr::select(-level, -target_share)
}

#' Scale one MLRA-year's levels so sum(tof) / sum(aoi_m2) hits the target,
#' with no AOI above `cap` of its eligible land. AOIs that hit the cap are
#' fixed there and the rest rescaled, until the target is met.
calibrate_group <- function(g, cap) {
  target_area <- g$target_share[1] * sum(g$aoi_m2)
  w <- g$level * g$eligible_m2          # unscaled TOF area
  limit <- cap * g$eligible_m2
  tof <- numeric(nrow(g))
  free <- w > 0
  for (i in seq_len(50)) {
    remaining <- target_area - sum(tof[!free])
    if (sum(w[free]) <= 0) break
    k <- remaining / sum(w[free])
    tof[free] <- k * w[free]
    over <- free & tof > limit
    if (!any(over)) break
    tof[over] <- limit[over]; free[over] <- FALSE
  }
  if (abs(sum(tof) - target_area) > 1e-6 * max(target_area, 1)) {
    warning(sprintf("MLRA %s %d: calibration short of target (%.1f of %.1f m2), cap too tight for this draw.",
                    g$MLRA_ID[1], g$target_year[1], sum(tof), target_area), call. = FALSE)
  }
  g$tof_m2 <- tof
  g$tof_share_eligible <- ifelse(g$eligible_m2 > 0, tof / g$eligible_m2, 0)
  g
}
