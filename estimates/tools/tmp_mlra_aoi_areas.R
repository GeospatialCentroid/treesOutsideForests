# ==============================================================================
# TEMP: total and masked areas for LRR F, two summary tables, one row per MLRA
# and target year plus an LRR total row (the MLRAs partition the LRR).
#   Rscript estimates/tools/tmp_mlra_aoi_areas.R
#
# Sheet 1  mlraAreas_lrr_<LRR>.csv       the full extent of every MLRA polygon
# Sheet 2  aoiAreasByMlra_lrr_<LRR>.csv  the sampled AOIs (1 km cells clipped
#                                         to the MLRA that drew them, from
#                                         estimates/01_aoi_areas.R) summed per MLRA
#
# mask_mode "any" (default): both sheets are measured against the any-year
# combined mask (llr_<LRR>_mask_any_<start>_<end>.gpkg, forest or Census place
# in at least one year of the masks run) by exact vector intersection, the same
# method estimates/01_aoi_areas.R uses. One mask for the whole period, so one
# row per MLRA; the `mask` column names it. Columns (m²): total_m2, masked_m2,
# eligible_m2, masked_pct; sheet 2 adds n_aoi and aoi_pct_of_mlra (sampling
# fraction by area). The sheet-2 masked total is checked to be at least the
# per-year combined-mask figure of aoiAreas_lrr_<LRR>.csv for every year.
#
# mask_mode "year": the earlier per-target-year tables, forest from the 30 m
# NLCD raster (partial edge pixels by covered area), urban from the dissolved
# Census places polygon, masked = forest + urban - overlap, one row per MLRA and
# target year with forest_m2, urban_m2, overlap_m2 as well.
# ==============================================================================
source(here::here("shared/R/setup.R"))
options(width = 200)
pacman::p_load(sf, terra, exactextractr, dplyr, purrr, readr, tibble)
source(tof_root("estimates/functions/areas.R"))

cfg     <- tof_config()
cfg_est <- cfg$estimates
llr_id  <- cfg_est$llr_id
crs     <- cfg$crs
target_years <- as.integer(cfg_est$target_years)
masks_dir <- tof_path(cfg_est$paths$masks_outputs)
out_dir   <- tof_path(cfg_est$paths$out_dir)
aoi_gpkg  <- tof_path(cfg_est$paths$aoi_gpkg)
aoi_csv   <- tof_path(cfg_est$paths$aoi_areas_csv)
if (!file.exists(aoi_gpkg)) stop("Run estimates/01_aoi_areas.R first: ", aoi_gpkg)

mlra <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE) |>
  dplyr::filter(LRRSYM == llr_id) |> sf::st_transform(crs) |> dplyr::arrange(MLRA_ID)
mlra_key <- sf::st_drop_geometry(mlra)[, c("MLRA_ID", "MLRARSYM", "MLRA_NAME")]
layers_for <- function(y) mask_layers(masks_dir, llr_id, y, crs)

# "any": the any-year combined mask, one row per MLRA. "year": per target year.
mask_mode <- get0("mask_mode", ifnotfound = "any")
cfg_masks <- cfg$masks
mask_period <- c(cfg_masks$years$start, cfg_masks$years$end)

area_cols <- if (mask_mode == "any") c("total_m2", "masked_m2", "eligible_m2") else
  c("total_m2", "forest_m2", "urban_m2", "overlap_m2", "masked_m2", "eligible_m2")
key_col <- if (mask_mode == "any") "mask" else "target_year"

# Add the LRR total row (sum over MLRAs) and masked_pct; order the columns.
finish <- function(tbl, extra = character(0)) {
  tbl <- tbl |> dplyr::mutate(level = "MLRA", MLRA_ID = as.character(MLRA_ID))
  lrr <- tbl |> dplyr::group_by(dplyr::across(dplyr::all_of(key_col))) |>
    dplyr::summarise(dplyr::across(dplyr::all_of(c(extra, area_cols)), sum), .groups = "drop") |>
    dplyr::mutate(level = "LRR", MLRA_ID = llr_id, MLRARSYM = llr_id, MLRA_NAME = paste("LRR", llr_id))
  dplyr::bind_rows(lrr, tbl) |>
    dplyr::mutate(masked_pct = 100 * masked_m2 / total_m2) |>
    dplyr::select(level, MLRA_ID, MLRARSYM, MLRA_NAME, dplyr::all_of(key_col), dplyr::all_of(extra),
                  dplyr::all_of(area_cols), masked_pct) |>
    dplyr::arrange(dplyr::across(dplyr::all_of(key_col)), level != "LRR", MLRA_ID)
}

if (mask_mode == "any") {
  # --- Any-year mask: one measurement for the whole period -----------------------
  mask_name <- sprintf("any_%d_%d", mask_period[1], mask_period[2])
  message("Loading the any-year combined mask ", mask_name, "...")
  mk <- any_year_mask(masks_dir, llr_id, mask_period[1], mask_period[2], crs)
  measure <- function(polys, total) {
    masked <- mask_area_m2(polys, mk)
    tibble::tibble(mask = mask_name, total_m2 = total, masked_m2 = masked,
                   eligible_m2 = pmax(total - masked, 0))
  }

  # Sheet 1: full MLRA extents
  message("MLRA extents against the any-year mask...")
  mlra_tbl <- dplyr::bind_cols(mlra_key, measure(mlra, as.numeric(sf::st_area(mlra)))) |> finish()

  # Sheet 2: the clipped AOIs, summed per MLRA. The AOIs are identical in every
  # layer of the GeoPackage (only the per-year mask columns differ), so one is read.
  message("AOIs against the any-year mask...")
  aoi <- sf::st_read(aoi_gpkg, layer = sprintf("aoi_%d", target_years[1]), quiet = TRUE) |> sf::st_transform(crs)
  aoi_tbl <- dplyr::bind_cols(sf::st_drop_geometry(aoi)[, c("id", "MLRA_ID")], measure(aoi, aoi$aoi_m2)) |>
    dplyr::group_by(MLRA_ID, mask) |>
    dplyr::summarise(n_aoi = dplyr::n(), dplyr::across(dplyr::all_of(area_cols), sum), .groups = "drop") |>
    dplyr::left_join(mlra_key, by = "MLRA_ID") |> finish(extra = "n_aoi")

  # The any-year mask contains every per-year mask, so its masked area can only
  # be at or above the per-year figure of 01_aoi_areas.R, AOI by AOI.
  if (file.exists(aoi_csv)) {
    per_year <- readr::read_csv(aoi_csv, show_col_types = FALSE)
    any_by_aoi <- dplyr::bind_cols(sf::st_drop_geometry(aoi)[, c("id", "MLRA_ID")],
                                   any_m2 = mask_area_m2(aoi, mk))
    chk <- per_year |> dplyr::inner_join(any_by_aoi, by = c("id", "MLRA_ID"))
    below <- chk |> dplyr::filter(mask_m2 > any_m2 + 1)   # 1 m² of floating-point slack
    tot <- chk |> dplyr::group_by(target_year) |>
      dplyr::summarise(year_km2 = sum(mask_m2) / 1e6, any_km2 = sum(any_m2) / 1e6, .groups = "drop")
    message("Check vs per-year combined masks (AOI totals, km²): ",
            paste(sprintf("%d: %.2f -> any %.2f", tot$target_year, tot$year_km2, tot$any_km2), collapse = "; "))
    if (nrow(below) > 0) {
      warning(nrow(below), " AOI-years have more per-year mask than any-year mask (max excess ",
              round(max(below$mask_m2 - below$any_m2)), " m²); the any-year mask should contain every year.")
    } else message("  Every AOI has at least as much any-year mask as per-year mask.")
  }
} else {
  # --- Per target year: forest + urban - overlap ---------------------------------
  # Sheet 1: full MLRA extents
  mlra_tbl <- purrr::map_dfr(target_years, function(y) {
    message("MLRA extents against the ", y, " masks...")
    stratum_areas(mlra, layers_for(y)) |> dplyr::rename(target_year = mask_year)
  }) |> finish()

  # Sheet 2: the clipped AOIs, summed per MLRA
  aoi_tbl <- purrr::map_dfr(target_years, function(y) {
    message("AOIs against the ", y, " masks...")
    aoi <- sf::st_read(aoi_gpkg, layer = sprintf("aoi_%d", y), quiet = TRUE) |> sf::st_transform(crs)
    polygon_mask_areas(aoi[, c("id", "MLRA_ID")], layers_for(y)) |>
      dplyr::group_by(MLRA_ID) |>
      dplyr::summarise(target_year = y, n_aoi = dplyr::n(),
                       dplyr::across(dplyr::all_of(c("footprint_m2", area_cols[-1])), sum), .groups = "drop") |>
      dplyr::rename(total_m2 = footprint_m2) |>
      dplyr::left_join(mlra_key, by = "MLRA_ID")
  }) |> finish(extra = "n_aoi")

  # Check against the combined-mask measurement of 01_aoi_areas.R
  if (file.exists(aoi_csv)) {
    chk <- readr::read_csv(aoi_csv, show_col_types = FALSE) |>
      dplyr::group_by(target_year) |>
      dplyr::summarise(aoi_m2 = sum(aoi_m2), mask_m2 = sum(mask_m2), .groups = "drop") |>
      dplyr::inner_join(dplyr::filter(aoi_tbl, level == "LRR")[, c("target_year", "total_m2", "masked_m2")], by = "target_year")
    message("Check vs combined mask (LRR totals, km²): ",
            paste(sprintf("%d: aoi %.2f/%.2f, masked %.2f/%.2f", chk$target_year, chk$aoi_m2 / 1e6, chk$total_m2 / 1e6,
                          chk$mask_m2 / 1e6, chk$masked_m2 / 1e6), collapse = "; "))
  }
}
aoi_tbl <- aoi_tbl |>
  dplyr::left_join(dplyr::select(mlra_tbl, MLRA_ID, dplyr::all_of(key_col), mlra_total_m2 = total_m2),
                   by = c("MLRA_ID", key_col)) |>
  dplyr::mutate(aoi_pct_of_mlra = 100 * total_m2 / mlra_total_m2, mlra_total_m2 = NULL)

# --- Write and print ----------------------------------------------------------
mlra_out <- file.path(out_dir, sprintf("mlraAreas_lrr_%s.csv", llr_id))
aoi_out  <- file.path(out_dir, sprintf("aoiAreasByMlra_lrr_%s.csv", llr_id))
readr::write_csv(mlra_tbl, mlra_out)
readr::write_csv(aoi_tbl, aoi_out)

quick <- function(tbl, extra = character(0)) {
  tbl |> dplyr::transmute(level, MLRA_ID, MLRARSYM, dplyr::across(dplyr::all_of(key_col)), dplyr::across(dplyr::all_of(extra)),
                          total_km2 = round(total_m2 / 1e6, 1),
                          dplyr::across(dplyr::any_of(c("forest_m2", "urban_m2")), \(x) round(x / 1e6, 1), .names = "{sub('_m2', '_km2', .col)}"),
                          masked_km2 = round(masked_m2 / 1e6, 1),
                          eligible_km2 = round(eligible_m2 / 1e6, 1), masked_pct = round(masked_pct, 2),
                          dplyr::across(dplyr::any_of("aoi_pct_of_mlra"), \(x) round(x, 3)))
}
cat("\n== Sheet 1: full MLRA extents (km²) ==\n")
print(as.data.frame(quick(mlra_tbl)), row.names = FALSE)
cat("\n== Sheet 2: sampled AOIs inside each MLRA (km²) ==\n")
print(as.data.frame(quick(aoi_tbl, "n_aoi")), row.names = FALSE)
message("\nWrote ", mlra_out, "\n  and ", aoi_out)
