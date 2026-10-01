# ==============================================================================
# TEMP: plot-level companion to aoiAreasByMlra_lrr_<LRR>.csv. One row per
# sampled AOI (the 1 km cell clipped to the MLRA that drew it) with its total,
# masked and eligible area against the any-year combined mask, the same mask
# and method as estimates/tools/tmp_mlra_aoi_areas.R. Summing this table by
# MLRA reproduces aoiAreasByMlra_lrr_<LRR>.csv; the script checks that.
#   Rscript estimates/tools/tmp_aoi_plot_areas.R
# Needs estimates/01_aoi_areas.R (the clipped AOI GeoPackage) and
# tmp_mlra_aoi_areas.R (the MLRA sums, for the check).
#
# Columns: id, MLRA_ID, MLRARSYM, mask, cell_m2 (full 1 km cell), total_m2 (AOI
# area inside the MLRA), masked_m2, eligible_m2 (m²), masked_pct, clipped (AOI
# smaller than its cell), shared_id (the id was also drawn by a neighbouring
# MLRA and appears there as a second, non-overlapping AOI).
# Output: data/estimates/aoiPlotAreas_lrr_<LRR>.csv
# ==============================================================================
source(here::here("shared/R/setup.R"))
options(width = 200)
pacman::p_load(sf, dplyr, readr, tibble)
source(tof_root("estimates/functions/areas.R"))

cfg     <- tof_config()
cfg_est <- cfg$estimates
llr_id  <- cfg_est$llr_id
crs     <- cfg$crs
masks_dir <- tof_path(cfg_est$paths$masks_outputs)
out_dir   <- tof_path(cfg_est$paths$out_dir)
aoi_gpkg  <- tof_path(cfg_est$paths$aoi_gpkg)
by_mlra   <- file.path(out_dir, sprintf("aoiAreasByMlra_lrr_%s.csv", llr_id))
if (!file.exists(aoi_gpkg)) stop("Run estimates/01_aoi_areas.R first: ", aoi_gpkg)

mlra_key <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE) |>
  dplyr::filter(LRRSYM == llr_id) |> sf::st_drop_geometry() |> dplyr::distinct(MLRA_ID, MLRARSYM)
mask_period <- c(cfg$masks$years$start, cfg$masks$years$end)
mask_name   <- sprintf("any_%d_%d", mask_period[1], mask_period[2])

message("Loading the any-year combined mask ", mask_name, "...")
mk  <- any_year_mask(masks_dir, llr_id, mask_period[1], mask_period[2], crs)
# The AOIs are identical in every layer of the GeoPackage; one is read.
aoi <- sf::st_read(aoi_gpkg, layer = sf::st_layers(aoi_gpkg)$name[1], quiet = TRUE) |> sf::st_transform(crs)

message("Measuring ", nrow(aoi), " AOIs against the any-year mask...")
plots <- sf::st_drop_geometry(aoi)[, c("id", "MLRA_ID", "cell_m2", "aoi_m2")] |>
  tibble::as_tibble() |>
  dplyr::mutate(masked_m2 = mask_area_m2(aoi, mk)) |>
  dplyr::left_join(mlra_key, by = "MLRA_ID") |>
  dplyr::transmute(id, MLRA_ID, MLRARSYM, mask = mask_name, cell_m2, total_m2 = aoi_m2, masked_m2,
                   eligible_m2 = pmax(total_m2 - masked_m2, 0), masked_pct = 100 * masked_m2 / total_m2,
                   clipped = abs(total_m2 - cell_m2) >= 1, shared_id = id %in% id[duplicated(id)]) |>
  dplyr::arrange(MLRA_ID, id)

out <- file.path(out_dir, sprintf("aoiPlotAreas_lrr_%s.csv", llr_id))
readr::write_csv(plots, out)

# --- Check: MLRA sums against the table already shared ------------------------
if (file.exists(by_mlra)) {
  ref <- readr::read_csv(by_mlra, show_col_types = FALSE, col_types = readr::cols(MLRA_ID = "c")) |>
    dplyr::filter(level == "MLRA")
  chk <- plots |> dplyr::group_by(MLRA_ID = as.character(MLRA_ID)) |>
    dplyr::summarise(n = dplyr::n(), total = sum(total_m2), masked = sum(masked_m2), .groups = "drop") |>
    dplyr::inner_join(ref, by = "MLRA_ID") |>
    dplyr::mutate(d_n = n - n_aoi, d_total = total - total_m2, d_masked = masked - masked_m2)
  print(as.data.frame(chk[, c("MLRA_ID", "MLRARSYM", "n", "d_n", "d_total", "d_masked")]), row.names = FALSE)
  if (nrow(chk) != nrow(ref) || any(chk$d_n != 0) || any(abs(chk$d_total) > 1) || any(abs(chk$d_masked) > 1))
    warning("Plot sums do not reproduce ", basename(by_mlra))
  else message("Plot sums reproduce ", basename(by_mlra), " (every MLRA within 1 m²).")
}
message(sprintf("%d plots, %d clipped, %d with a shared id, %d with any mask. Wrote %s",
                nrow(plots), sum(plots$clipped), sum(plots$shared_id), sum(plots$masked_m2 > 0), out))
