# ==============================================================================
# One-off: derive the sampling-frame corrections table from the March 2026
# 1 km grid (neymanSampling data/derived/grids/GreatPlains_1km_mlra.gpkg), the
# grid the reference sample lists were drawn on.
#
# Why: the frame of an MLRA is "whole 1 km cells that intersect the MLRA
# polygon". For cells the MLRA boundary crosses by a metre or less that test
# is not stable across PROJ / GEOS versions (the WGS84 -> NAD83 Albers
# transform alone moves the boundary by a fraction of a metre), and sf's
# lattice size is sensitive to the cell count. This script lists every cell
# near an MLRA boundary whose overlap is small, together with whether the
# March build included it. mlra_1km_cells() applies that membership, so the
# frame, and hence the draw, is the same on any library version.
#
# Needs the old grid, so it is not part of the pipeline. Run from the root
# project only to regenerate data/reference/sampleGrids/sampleFrame_marginalCells_03_2026.csv.
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(sf, dplyr, purrr, readr)
source(tof_root("sampling/functions/sample_grid.R"))

MARCH_GRID <- "/home/dune/trueNAS/work/neymanSampling/data/derived/grids/GreatPlains_1km_mlra.gpkg"
NEAR_M     <- 10      # cells within this distance of the boundary are examined
SMALL_M2   <- 5000    # overlap below this counts as marginal (a 1000 m edge x 5 m)

cfg  <- tof_config()
g100 <- sf::st_read(tof_path(cfg$reference$grid_gpkg), quiet = TRUE)
mlra <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE) |> sf::st_transform(5070)
march <- sf::st_read(MARCH_GRID, quiet = TRUE) |> sf::st_drop_geometry()
cat("March grid:", nrow(march), "cells,", length(unique(march$MLRA_ID)), "MLRAs\n")

rows <- list()
for (lrr_id in cfg$sampling$grid$lrr_ids) {
  for (m_id in mlra$MLRA_ID[mlra$LRRSYM == lrr_id]) {
    poly  <- mlra[mlra$MLRA_ID == m_id, ]
    today <- mlra_1km_cells(poly, g100, corrections = NULL)
    march_ids <- march$id[march$MLRA_ID == m_id]
    parents <- select_100km(g100, sf::st_buffer(poly, NEAR_M))
    all_cells <- build_sub_grids(parents, 1000, aoi = parents)
    band  <- sf::st_buffer(sf::st_boundary(sf::st_geometry(poly)), NEAR_M)
    near  <- all_cells[band, ]
    inter <- suppressWarnings(sf::st_intersection(near, sf::st_geometry(poly)))
    area  <- setNames(rep(0, nrow(near)), near$id)
    if (nrow(inter) > 0) area[inter$id] <- as.numeric(sf::st_area(inter))
    near$intersection_m2 <- area[near$id]
    near$distance_m <- as.numeric(sf::st_distance(near, sf::st_geometry(poly))[, 1])
    marg <- sf::st_drop_geometry(near) |>
      dplyr::filter(intersection_m2 < SMALL_M2) |>
      dplyr::mutate(LLR_ID = lrr_id, MLRA_ID = m_id,
                    in_march_build = id %in% march_ids,
                    in_today_build = id %in% today$id) |>
      dplyr::select(LLR_ID, MLRA_ID, id, distance_m, intersection_m2, in_march_build, in_today_build) |>
      dplyr::arrange(id)
    diff_ids <- union(setdiff(march_ids, today$id), setdiff(today$id, march_ids))
    cat(sprintf("MLRA %s: today %d, March %d, differ on %d cell(s) [%s]; %d marginal cells listed; all differing cells listed: %s\n",
                m_id, nrow(today), length(march_ids), length(diff_ids), paste(diff_ids, collapse = " "),
                nrow(marg), all(diff_ids %in% marg$id)))
    rows[[length(rows) + 1]] <- marg
  }
}
out <- dplyr::bind_rows(rows)
path <- tof_root("data/reference/sampleGrids/sampleFrame_marginalCells_03_2026.csv")
readr::write_csv(out, path)
cat("\nWrote", nrow(out), "rows to", path, "\n")
cat("Cells that differ between builds and their stats:\n")
print(as.data.frame(out |> dplyr::filter(in_march_build != in_today_build)), row.names = FALSE)
