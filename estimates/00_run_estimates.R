# ==============================================================================
# Area-weighted trees-outside-forest estimates per MLRA and per LRR, for every
# naip target year in config.yml `estimates`. Run from the root project:
#   source("estimates/00_run_estimates.R")
# The per-cell model output comes from one of two sources (`model_source`):
#   "table":  one CSV of pixel counts per cell and target year (paths$model_table,
#             layout in functions/model_output.R); the table's eligible_px is the
#             eligible denominator and no cell-level mask areas are measured.
#   "raster": one raster per cell and actual NAIP year (model_pattern under
#             paths$model_dir); the mask year for a cell is the year NAIP was
#             actually captured (status.json actual_year).
# The stratum areas always use the target year's masks.
# Outputs (ignored by git), under estimates$paths$out_dir:
#   cellAreas_lrr_<LRR>_mask_<year>.csv   raster mode: mask areas per sampled cell, per mask year (cached)
#   strataAreas_lrr_<LRR>_<year>.csv      MLRA total and eligible areas per mask year (cached)
#   cells_lrr_<LRR>_<target>.csv          cell-year table with the model output joined
#   estimates_mlra_lrr_<LRR>.csv          per-MLRA estimates, both denominators
#   estimates_lrr_<LRR>.csv               per-LRR estimates, both denominators
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(sf, dplyr, tidyr, purrr, readr, tibble, terra, exactextractr, jsonlite)
terra::terraOptions(progress = 0)
source(tof_root("sampling/functions/grid_cells.R"))   # cells_from_ids(), read_sites_csv()
source(tof_root("naip/function/getSTATUS.R"))         # compileStatus()
source(tof_root("estimates/functions/areas.R"))
source(tof_root("estimates/functions/model_output.R"))
source(tof_root("estimates/functions/estimators.R"))

cfg     <- tof_config()
cfg_est <- cfg$estimates
llr_id  <- cfg_est$llr_id
crs     <- cfg$crs
target_years <- as.integer(cfg_est$target_years)
model_source <- match.arg(cfg_est$model_source, c("table", "raster"))
masks_dir <- tof_path(cfg_est$paths$masks_outputs)
out_dir   <- tof_path(cfg_est$paths$out_dir)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# --- Inputs -------------------------------------------------------------------
mlra <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE) |>
  dplyr::filter(LRRSYM == llr_id) |> sf::st_transform(crs)
g100 <- sf::st_read(tof_path(cfg$reference$grid_gpkg), quiet = TRUE)
sample_tbl <- read_sites_csv(tof_path(cfg_est$paths$sample_csv)) |> dplyr::filter(LLR_ID == llr_id)

cells <- cell_geometry(sample_tbl, g100, crs)
message(sprintf("LRR %s: %d cells in %d MLRAs (%d duplicate ids kept in their first MLRA).",
                llr_id, nrow(cells), dplyr::n_distinct(cells$MLRA_ID), nrow(sample_tbl) - nrow(cells)))

cached <- function(path, build) {
  if (file.exists(path)) return(readr::read_csv(path, show_col_types = FALSE))
  x <- build(); readr::write_csv(x, path); x
}
layers_for <- function(y) mask_layers(masks_dir, llr_id, y, crs)

# --- Cell-year table with the model output -----------------------------------
if (model_source == "table") {
  tab <- read_model_table(tof_path(cfg_est$paths$model_table), pixel_area_m2 = cfg_est$pixel_area_m2) |>
    dplyr::filter(target_year %in% target_years)
  if (nrow(tab) == 0) stop("The model table has no rows for target years ", paste(target_years, collapse = ", "))
  message(sprintf("Model table: %d rows, years %s.", nrow(tab), paste(sort(unique(tab$target_year)), collapse = ", ")))
  cell_year <- join_model_table(cells, tab)
  mask_years <- sort(unique(cell_year$target_year))
} else {
  model_dir <- tof_path(cfg_est$paths$model_dir)
  years <- naip_year_table(tof_path(cfg_est$paths$naip_export_dir)) |>
    dplyr::filter(target_year %in% target_years)
  mask_years <- sort(unique(c(years$actual_year, years$target_year)))
  cell_area_tbl <- purrr::map_dfr(mask_years, function(y) cached(
    file.path(out_dir, sprintf("cellAreas_lrr_%s_mask_%d.csv", llr_id, y)),
    function() { message("Cell mask areas, ", y); cell_areas(cells, layers_for(y)) }))
  cell_year <- purrr::map_dfr(target_years, function(ty) {
    yy <- dplyr::filter(years, target_year == ty)
    cy <- dplyr::inner_join(cells, yy, by = "id")
    cy <- dplyr::inner_join(cy, dplyr::select(cell_area_tbl, -cell_m2),
                            by = c("id", "MLRA_ID", "actual_year" = "mask_year"))
    message(sprintf("Target %d: %d cells with imagery (%d without).", ty, nrow(cy), nrow(cells) - nrow(cy)))
    join_model_output(cy, model_dir, cfg_est$model_pattern, eligible_from = cfg_est$eligible_from)
  })
}
for (ty in sort(unique(cell_year$target_year))) {
  readr::write_csv(dplyr::filter(cell_year, target_year == ty),
                   file.path(out_dir, sprintf("cells_lrr_%s_%d.csv", llr_id, ty)))
}

# --- Stratum areas from the target-year masks, cached -------------------------
strata_tbl <- purrr::map_dfr(mask_years, function(y) cached(
  file.path(out_dir, sprintf("strataAreas_lrr_%s_%d.csv", llr_id, y)),
  function() { message("Stratum areas, ", y); stratum_areas(mlra, layers_for(y)) }))

# --- Estimates ----------------------------------------------------------------
mlra_est <- estimate_mlra(cell_year) |>
  dplyr::left_join(sf::st_drop_geometry(mlra)[, c("MLRA_ID", "MLRARSYM", "MLRA_NAME")], by = "MLRA_ID")
strata_by_target <- strata_tbl |> dplyr::rename(target_year = mask_year)
lrr_est <- estimate_lrr(mlra_est, strata_by_target) |> dplyr::mutate(LLR_ID = llr_id, .before = 1)
readr::write_csv(mlra_est, file.path(out_dir, sprintf("estimates_mlra_lrr_%s.csv", llr_id)))
readr::write_csv(lrr_est,  file.path(out_dir, sprintf("estimates_lrr_%s.csv", llr_id)))
print(lrr_est |> dplyr::select(LLR_ID, target_year, denominator, n_mlra, n_cells, pct, pct_se), n = Inf)
