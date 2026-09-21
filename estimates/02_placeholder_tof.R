# ==============================================================================
# Placeholder trees-outside-forest area per clipped AOI and year, calibrated to
# each MLRA's NLCD forest share, packaged for project partners. Run after
# 01_aoi_areas.R, from the root project:
#   source("estimates/02_placeholder_tof.R")
# This is NOT model output: see functions/placeholder.R for what is imposed.
# Outputs under estimates$placeholder$out_dir (ignored by git):
#   placeholder_tof_lrr_<LRR>.csv          one row per AOI and year (the spreadsheet's main sheet)
#   placeholder_tof_lrr_<LRR>.xlsx         sheets: aoi_tof, mlra_summary, readme
#   placeholder_model_table_lrr_<LRR>.csv  the same in the pixel-count layout read_model_table() takes
#   placeholder_targets_lrr_<LRR>.csv      the per-MLRA-year targets (NLCD forest share)
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(sf, dplyr, tidyr, purrr, readr, tibble, terra, exactextractr, openxlsx)
terra::terraOptions(progress = 0)
source(tof_root("estimates/functions/areas.R"))
source(tof_root("estimates/functions/estimators.R"))
source(tof_root("estimates/functions/placeholder.R"))

cfg     <- tof_config()
cfg_est <- cfg$estimates
cfg_ph  <- cfg_est$placeholder
llr_id  <- cfg_est$llr_id
crs     <- cfg$crs
target_years <- as.integer(cfg_est$target_years)
masks_dir <- tof_path(cfg_est$paths$masks_outputs)
est_dir   <- tof_path(cfg_est$paths$out_dir)
out_dir   <- tof_path(cfg_ph$out_dir)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# --- Inputs -------------------------------------------------------------------
aoi_path <- tof_path(cfg_est$paths$aoi_areas_csv)
if (!file.exists(aoi_path)) stop("Run estimates/01_aoi_areas.R first: no ", aoi_path)
aoi <- readr::read_csv(aoi_path, show_col_types = FALSE,
                       col_types = readr::cols(id = readr::col_character(), .default = readr::col_guess())) |>
  dplyr::filter(target_year %in% target_years)
mlra <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE) |>
  dplyr::filter(LRRSYM == llr_id) |> sf::st_transform(crs)
mlra_names <- sf::st_drop_geometry(mlra)[, c("MLRA_ID", "MLRARSYM", "MLRA_NAME")]

# --- Targets: each MLRA's NLCD forest share, from the stratum areas (cached) ---
cached <- function(path, build) {
  if (file.exists(path)) return(readr::read_csv(path, show_col_types = FALSE))
  x <- build(); readr::write_csv(x, path); x
}
strata <- purrr::map_dfr(target_years, function(y) cached(
  file.path(est_dir, sprintf("strataAreas_lrr_%s_%d.csv", llr_id, y)),
  function() { message("Stratum areas, ", y); stratum_areas(mlra, mask_layers(masks_dir, llr_id, y, crs)) }))
targets <- strata |>
  dplyr::transmute(MLRA_ID, target_year = mask_year, mlra_total_m2 = total_m2, mlra_forest_m2 = forest_m2,
                   target_share = forest_m2 / total_m2)
readr::write_csv(targets, file.path(out_dir, sprintf("placeholder_targets_lrr_%s.csv", llr_id)))

# --- Draw and calibrate --------------------------------------------------------
ph <- placeholder_tof(aoi, targets, seed = cfg_ph$seed, p_zero = cfg_ph$p_zero,
                      sdlog = cfg_ph$sdlog, cap = cfg_ph$cap)

# --- Check: the MLRA ratio-of-sums recovers the target, LRR from the strata ----
mlra_est <- estimate_mlra(dplyr::rename(ph, footprint_m2 = aoi_m2))
chk <- mlra_est |> dplyr::filter(denominator == "total") |>
  dplyr::inner_join(targets, by = c("MLRA_ID", "target_year")) |>
  dplyr::mutate(diff = estimate - target_share)
if (any(abs(chk$diff) > 1e-9)) stop("Calibration failed for MLRA-years: ",
                                    paste(sprintf("%s/%d", chk$MLRA_ID[abs(chk$diff) > 1e-9], chk$target_year[abs(chk$diff) > 1e-9]), collapse = ", "))
message("Calibration check: every MLRA-year's area-weighted TOF share equals its NLCD forest share.")
lrr_est <- estimate_lrr(mlra_est, strata |> dplyr::rename(target_year = mask_year))

# --- Tables ---------------------------------------------------------------------
aoi_tbl <- ph |>
  dplyr::inner_join(mlra_names, by = "MLRA_ID") |>
  dplyr::arrange(MLRA_ID, id, target_year) |>
  dplyr::transmute(
    aoi_id = id, mlra_id = MLRA_ID, mlra_symbol = MLRARSYM, mlra_name = MLRA_NAME,
    year = target_year,
    tof_area_m2      = round(tof_m2),
    mask_area_m2     = round(mask_m2),
    aoi_area_m2      = round(aoi_m2),
    eligible_area_m2 = round(eligible_m2),
    tof_pct_of_eligible = round(100 * tof_share_eligible, 3),
    whole_cell = abs(aoi_m2 - cell_m2) < 1)
mlra_tbl <- ph |>
  dplyr::group_by(MLRA_ID, target_year) |>
  dplyr::summarise(n_aoi = dplyr::n(), n_aoi_with_tof = sum(tof_m2 > 0),
                   aoi_area_m2 = sum(aoi_m2), mask_area_m2 = sum(mask_m2), eligible_area_m2 = sum(eligible_m2),
                   tof_area_m2 = sum(tof_m2), max_tof_pct_of_eligible = 100 * max(tof_share_eligible), .groups = "drop") |>
  dplyr::inner_join(targets, by = c("MLRA_ID", "target_year")) |>
  dplyr::inner_join(mlra_names, by = "MLRA_ID") |>
  dplyr::transmute(mlra_id = MLRA_ID, mlra_symbol = MLRARSYM, mlra_name = MLRA_NAME, year = target_year,
                   n_aoi, n_aoi_with_tof,
                   aoi_area_m2 = round(aoi_area_m2), mask_area_m2 = round(mask_area_m2),
                   eligible_area_m2 = round(eligible_area_m2), tof_area_m2 = round(tof_area_m2),
                   tof_pct_of_aoi_area = round(100 * tof_area_m2 / aoi_area_m2, 4),
                   nlcd_forest_pct_of_mlra = round(100 * target_share, 4),
                   mlra_area_m2 = round(mlra_total_m2), mlra_nlcd_forest_m2 = round(mlra_forest_m2),
                   max_tof_pct_of_eligible = round(max_tof_pct_of_eligible, 2))

readme <- c(
  sprintf("Placeholder trees-outside-forest (TOF) areas per sampled AOI, LRR %s, years %s. Generated %s by treesOutsideForests/estimates/02_placeholder_tof.R.",
          llr_id, paste(target_years, collapse = ", "), format(Sys.Date())),
  "",
  "THE TOF VALUES ARE A PLACEHOLDER, NOT MODEL OUTPUT. They exist so the MLRA-level aggregation can be built and tested on data of the right shape before the real per-AOI predictions exist. Do not report them as findings.",
  "",
  "How the placeholder was built:",
  " - Within every MLRA and year the area-weighted mean TOF share of the AOIs, sum(tof_area) / sum(aoi_area), equals that MLRA's NLCD forest share (classes 41, 42, 43) for the year. An MLRA aggregation of this table returns the NLCD forest share exactly (sheet mlra_summary, columns tof_pct_of_aoi_area and nlcd_forest_pct_of_mlra).",
  sprintf(" - Across AOIs the values are zero-inflated with a long right tail: about %d%% of AOIs have no TOF in any year, the rest follow a lognormal (sdlog %.1f) and no AOI exceeds %d%% of its eligible land. TOF sits only on eligible land.", round(100 * cfg_ph$p_zero), cfg_ph$sdlog, round(100 * cfg_ph$cap)),
  " - An AOI's level is drawn once and carried across years with small noise; a few AOIs lose cover from 2016 and a few gain from 2020.",
  sprintf(" - Seeded (seed %d), so the file is reproducible from the repository.", cfg_ph$seed),
  "",
  "Geometry: each AOI is a 1 km cell of the systematic sample, clipped to the MLRA that drew it. A cell drawn by two neighbouring MLRAs appears twice with different mlra_id and non-overlapping pieces. whole_cell is TRUE where the clip did not touch the cell.",
  "Mask: the union of the NLCD forest classes (41, 42, 43) and the US Census places for the year, from the masks stage (llr_F_mask_<year>.gpkg). Water is not masked.",
  "All areas are in square metres, in EPSG:5070 (CONUS Albers equal area). Divide by 10,000 for hectares.",
  "",
  "Sheet aoi_tof, one row per AOI and year:",
  " aoi_id               cell id <100km>-<50km>-<10km>-<2km>-<1km>, as in the sample list and the NAIP exports",
  " mlra_id / mlra_symbol / mlra_name   the MLRA the piece lies in (aggregate on mlra_id)",
  " year                 NAIP target year",
  " tof_area_m2          placeholder trees-outside-forest area inside the AOI",
  " mask_area_m2         area of the AOI covered by the forest-or-place mask for the year",
  " aoi_area_m2          total area of the clipped AOI",
  " eligible_area_m2     aoi_area_m2 - mask_area_m2: land the model may call TOF",
  " tof_pct_of_eligible  100 * tof_area_m2 / eligible_area_m2",
  " whole_cell           TRUE when the AOI is the whole 1 km cell",
  "",
  "Sheet mlra_summary, one row per MLRA and year: sums of the above, the share of AOIs with any TOF, the largest per-AOI share, and the calibration target (nlcd_forest_pct_of_mlra with the MLRA's total and forest areas).")

# --- Write ------------------------------------------------------------------------
stem <- file.path(out_dir, sprintf("placeholder_tof_lrr_%s", llr_id))
readr::write_csv(aoi_tbl, paste0(stem, ".csv"))
wb <- openxlsx::createWorkbook()
openxlsx::addWorksheet(wb, "readme");       openxlsx::writeData(wb, "readme", data.frame(x = readme), colNames = FALSE)
openxlsx::setColWidths(wb, "readme", 1, 140)
openxlsx::addWorksheet(wb, "aoi_tof");      openxlsx::writeData(wb, "aoi_tof", aoi_tbl)
openxlsx::freezePane(wb, "aoi_tof", firstRow = TRUE); openxlsx::setColWidths(wb, "aoi_tof", seq_along(aoi_tbl), "auto")
openxlsx::addWorksheet(wb, "mlra_summary"); openxlsx::writeData(wb, "mlra_summary", mlra_tbl)
openxlsx::freezePane(wb, "mlra_summary", firstRow = TRUE); openxlsx::setColWidths(wb, "mlra_summary", seq_along(mlra_tbl), "auto")
openxlsx::saveWorkbook(wb, paste0(stem, ".xlsx"), overwrite = TRUE)

# The same values in the pixel-count layout the estimates driver reads (1 px = 1 m²).
model_tab <- ph |>
  dplyr::transmute(id, MLRA_ID, target_year, actual_year = ifelse(target_year == 2012L, 2011L, target_year),
                   footprint_px = round(aoi_m2), eligible_px = round(eligible_m2), tof_px = round(tof_m2))
readr::write_csv(model_tab, file.path(out_dir, sprintf("placeholder_model_table_lrr_%s.csv", llr_id)))

print(mlra_tbl |> dplyr::select(mlra_symbol, year, n_aoi, n_aoi_with_tof, tof_pct_of_aoi_area, nlcd_forest_pct_of_mlra, max_tof_pct_of_eligible), n = Inf)
print(lrr_est |> dplyr::select(target_year, denominator, pct, pct_se))
message("Wrote ", stem, ".xlsx / .csv and the model table.")
