# ==============================================================================
# The sampled 1 km cells clipped to the MLRA that drew them, with their total,
# masked and eligible areas for every naip target year. Run from the root project:
#   source("estimates/01_aoi_areas.R")
# One feature per (id, MLRA_ID) pair in the sample list: a cell drawn by two
# MLRAs becomes two non-overlapping pieces, one per MLRA. The masked area is
# measured against the masks/ combined mask (llr_<LRR>_mask_<year>.gpkg) by
# exact vector intersection; eligible = total - masked.
# Outputs (ignored by git):
#   estimates$paths$aoi_areas_csv   long table: id, MLRA_ID, target_year, cell_m2,
#                                   aoi_m2, mask_m2, eligible_m2 (m²)
#   estimates$paths$aoi_gpkg        the clipped AOIs, one layer per target year
#                                   ("aoi_<year>") carrying the same columns
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(sf, dplyr, purrr, readr, tibble)
source(tof_root("sampling/functions/grid_cells.R"))   # cells_from_ids(), read_sites_csv()
source(tof_root("estimates/functions/areas.R"))

cfg     <- tof_config()
cfg_est <- cfg$estimates
llr_id  <- cfg_est$llr_id
crs     <- cfg$crs
target_years <- as.integer(cfg_est$target_years)
masks_dir <- tof_path(cfg_est$paths$masks_outputs)
csv_out   <- tof_path(cfg_est$paths$aoi_areas_csv)
gpkg_out  <- tof_path(cfg_est$paths$aoi_gpkg)
dir.create(dirname(csv_out), showWarnings = FALSE, recursive = TRUE)

mlra <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE) |>
  dplyr::filter(LRRSYM == llr_id) |> sf::st_transform(crs)
g100 <- sf::st_read(tof_path(cfg$reference$grid_gpkg), quiet = TRUE)
sample_tbl <- read_sites_csv(tof_path(cfg_est$paths$sample_csv)) |> dplyr::filter(LLR_ID == llr_id)

aoi <- clip_cells_to_mlra(sample_tbl, mlra, g100, crs)
message(sprintf("LRR %s: %d AOIs in %d MLRAs from %d sample rows; %d ids split between two MLRAs; %d whole cells, %d clipped.",
                llr_id, nrow(aoi), dplyr::n_distinct(aoi$MLRA_ID), nrow(sample_tbl), sum(duplicated(aoi$id)),
                sum(abs(aoi$aoi_m2 - aoi$cell_m2) < 1), sum(abs(aoi$aoi_m2 - aoi$cell_m2) >= 1)))

if (file.exists(gpkg_out)) file.remove(gpkg_out)
areas <- purrr::map_dfr(target_years, function(y) {
  message("Masked area against the ", y, " combined mask...")
  mk <- combined_mask(masks_dir, llr_id, y, crs)
  a  <- aoi
  a$target_year <- y
  a$mask_m2     <- mask_area_m2(a, mk)
  a$eligible_m2 <- pmax(a$aoi_m2 - a$mask_m2, 0)
  a <- a[, c("id", "MLRA_ID", "target_year", "cell_m2", "aoi_m2", "mask_m2", "eligible_m2", attr(a, "sf_column"))]
  sf::st_write(a, gpkg_out, layer = sprintf("aoi_%d", y), quiet = TRUE)
  tibble::as_tibble(sf::st_drop_geometry(a))
})
readr::write_csv(areas, csv_out)

print(areas |> dplyr::group_by(target_year) |>
        dplyr::summarise(n_aoi = dplyr::n(), aoi_km2 = sum(aoi_m2) / 1e6, mask_km2 = sum(mask_m2) / 1e6,
                         masked_pct = 100 * sum(mask_m2) / sum(aoi_m2), n_masked = sum(mask_m2 > 0)))
message("Wrote ", csv_out, " and ", gpkg_out)
