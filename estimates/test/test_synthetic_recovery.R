# Generates synthetic model output for the sampled cells of the configured LRR,
# runs it through the table reader and the estimators, and checks that every
# MLRA and LRR estimate recovers the generating truth within 3 standard errors.
# No masks are needed: stratum areas come from the MLRA polygons and the truth
# table's masked share. Run:
#   Rscript estimates/test/test_synthetic_recovery.R
source(here::here("shared/R/setup.R"))
pacman::p_load(sf, dplyr, tidyr, purrr, readr, tibble)
source(tof_root("sampling/functions/grid_cells.R"))
source(tof_root("estimates/functions/areas.R"))
source(tof_root("estimates/functions/model_output.R"))
source(tof_root("estimates/functions/estimators.R"))
source(tof_root("estimates/functions/synthetic.R"))

cfg     <- tof_config()
cfg_est <- cfg$estimates
llr_id  <- cfg_est$llr_id
years   <- as.integer(cfg_est$target_years)
px_m2   <- cfg_est$pixel_area_m2

fails <- 0
check <- function(label, ok, detail = "") {
  cat(sprintf("%-60s %s%s\n", label, if (ok) "ok" else "FAIL", if (nzchar(detail)) paste0("  (", detail, ")") else ""))
  if (!ok) fails <<- fails + 1
}

# --- Inputs -------------------------------------------------------------------
mlra <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE) |>
  dplyr::filter(LRRSYM == llr_id) |> sf::st_transform(cfg$crs)
g100 <- sf::st_read(tof_path(cfg$reference$grid_gpkg), quiet = TRUE)
sample_tbl <- read_sites_csv(tof_path(cfg_est$paths$sample_csv)) |> dplyr::filter(LLR_ID == llr_id)
n_dup <- nrow(sample_tbl) - dplyr::n_distinct(sample_tbl$id)

truth <- synthetic_truth(sort(unique(sample_tbl$MLRA_ID)), seed = cfg_est$synthetic$seed)
tab   <- synthetic_cells(sample_tbl, truth, years, seed = cfg_est$synthetic$seed, pixel_area_m2 = px_m2)

# --- Reader: round-trip through a CSV, with a few cell-years left out ---------
drop_ids <- head(unique(tab$id), 5)
tmp <- tempfile(fileext = ".csv")
readr::write_csv(dplyr::filter(tab, !(id %in% drop_ids & target_year == years[1])), tmp)
read_back <- read_model_table(tmp, pixel_area_m2 = px_m2)
check("reader: rows = written rows", nrow(read_back) == nrow(tab) - 5)
check("reader: tof_m2 = tof_px * pixel area", isTRUE(all.equal(read_back$tof_m2, read_back$tof_px * px_m2)))
check("reader: actual_year kept", all(read_back$actual_year[read_back$target_year == 2012L] == 2011L))
bad <- tab; bad$tof_px[1] <- bad$eligible_px[1] + 1; readr::write_csv(bad, tmp)
check("reader: tof_px > eligible_px is an error",
      inherits(tryCatch(read_model_table(tmp, px_m2), error = function(e) e), "error"))

# --- Cells: first MLRA wins for duplicate ids ---------------------------------
cells <- cell_geometry(sample_tbl, g100, cfg$crs)
first <- dplyr::distinct(sample_tbl, id, .keep_all = TRUE)
check(sprintf("cells: one row per id (%d duplicate ids in the list)", n_dup),
      nrow(cells) == dplyr::n_distinct(sample_tbl$id) && !anyDuplicated(cells$id))
check("cells: duplicate ids sit in the first MLRA that drew them",
      all(cells$MLRA_ID[match(first$id, cells$id)] == first$MLRA_ID))
check("cells: every cell is 1 km2", isTRUE(all.equal(cells$cell_m2, rep(1e6, nrow(cells)), tolerance = 1e-6)))

cell_year <- join_model_table(cells, read_back)
check("join: one row per cell and year", nrow(cell_year) == nrow(cells) * length(years))
check("join: 5 missing cell-years have NA tof", sum(is.na(cell_year$tof_m2)) == 5)
has <- !is.na(cell_year$footprint_px)
check("join: footprint from the table, cell area where missing",
      isTRUE(all.equal(cell_year$footprint_m2[has], cell_year$footprint_px[has] * px_m2)) &&
        isTRUE(all.equal(cell_year$footprint_m2[!has], cell_year$cell_m2[!has])))
check("join: MLRA_ID comes from the sample list, once", sum(names(cell_year) == "MLRA_ID") == 1)

# --- Estimates against the truth ----------------------------------------------
strata <- sf::st_drop_geometry(mlra) |>
  dplyr::transmute(MLRA_ID, total_m2 = as.numeric(sf::st_area(mlra))) |>
  dplyr::inner_join(truth, by = "MLRA_ID") |>
  dplyr::transmute(MLRA_ID, total_m2, eligible_m2 = total_m2 * (1 - masked_frac)) |>
  tidyr::expand_grid(target_year = years)

m <- estimate_mlra(cell_year)
l <- estimate_lrr(m, strata)

truth_long <- truth |>
  dplyr::select(MLRA_ID, eligible = tof_frac_eligible, total = tof_frac_total) |>
  tidyr::pivot_longer(c(eligible, total), names_to = "denominator", values_to = "truth")
mm <- dplyr::inner_join(m, truth_long, by = c("MLRA_ID", "denominator")) |>
  dplyr::mutate(z = (estimate - truth) / se)
check("mlra: 11 MLRAs x 3 years x 2 denominators", nrow(mm) == dplyr::n_distinct(sample_tbl$MLRA_ID) * length(years) * 2)
check("mlra: every se > 0", all(mm$se > 0))
check("mlra: n_missing sums to 5 per denominator", all(tapply(mm$n_missing, mm$denominator, sum) == 5))
check("mlra: every estimate within 3 se of the truth", all(abs(mm$z) <= 3),
      sprintf("max |z| = %.2f", max(abs(mm$z))))
check("mlra: |z| not all tiny (se is not inflated)", stats::median(abs(mm$z)) > 0.2,
      sprintf("median |z| = %.2f", stats::median(abs(mm$z))))

lrr_truth <- strata |>
  dplyr::select(MLRA_ID, target_year, eligible = eligible_m2, total = total_m2) |>
  tidyr::pivot_longer(c(eligible, total), names_to = "denominator", values_to = "area_m2") |>
  dplyr::inner_join(truth_long, by = c("MLRA_ID", "denominator")) |>
  dplyr::group_by(target_year, denominator) |>
  dplyr::summarise(truth = sum(truth * area_m2) / sum(area_m2), .groups = "drop")
ll <- dplyr::inner_join(l, lrr_truth, by = c("target_year", "denominator")) |>
  dplyr::mutate(z = (estimate - truth) / se)
check("lrr: 3 years x 2 denominators", nrow(ll) == length(years) * 2)
check("lrr: every estimate within 3 se of the truth", all(abs(ll$z) <= 3),
      sprintf("max |z| = %.2f", max(abs(ll$z))))
check("lrr: tof area = estimate x area", isTRUE(all.equal(ll$tof_area_m2, ll$estimate * ll$area_m2)))
check("lrr: n_cells = cells with output", all(ll$n_cells == nrow(cells) * 1L - ifelse(ll$target_year == years[1], 5L, 0L)))

cat("\nMLRA estimates vs truth, eligible denominator, per cent of eligible land:\n")
print(mm |> dplyr::filter(denominator == "eligible") |>
        dplyr::transmute(MLRA_ID, target_year, n, truth = round(100 * truth, 2), est = round(pct, 2),
                         se = round(pct_se, 2), z = round(z, 2)), n = Inf)
cat("\nLRR estimates vs truth:\n")
print(ll |> dplyr::transmute(target_year, denominator, n_cells, truth = round(100 * truth, 3),
                             est = round(pct, 3), se = round(pct_se, 3), z = round(z, 2)), n = Inf)

cat(if (fails == 0) "\nAll checks passed.\n" else sprintf("\n%d check(s) FAILED.\n", fails))
quit(status = if (fails == 0) 0 else 1)
