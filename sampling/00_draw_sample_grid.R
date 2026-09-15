# ==============================================================================
# Draw the systematic sample grid: about n 1 km cells per MLRA, one seeded
# regular-lattice draw per MLRA, for every LRR listed in config.yml
# `sampling$grid`. Run from the root project:
#   source("sampling/00_draw_sample_grid.R")
# Outputs (ignored by git):
#   data/sampling/sampleGrids/selectedSample_lrr_<LRR>_draw_<n>.csv
#   data/sampling/sampleGrids/selectedSample_lrr_<LRR>_draw_<n>_diagnostics.csv
# The tracked lists in data/reference/sampleGrids/ are the May 2026 draws;
# sampling/test/test_sample_grid_replication.R shows this script reproduces
# them exactly. An existing output is not overwritten; delete it to redraw.
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(sf, dplyr, purrr, readr)
source(tof_root("sampling/functions/sample_grid.R"))

cfg  <- tof_config()
grid <- cfg$sampling$grid
out_dir <- tof_path(grid$out_dir)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

mlra <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE)
g100 <- sf::st_read(tof_path(cfg$reference$grid_gpkg), quiet = TRUE)
corrections <- read_frame_corrections(tof_path(grid$frame_corrections))

for (lrr_id in grid$lrr_ids) {
  stub <- file.path(out_dir, sprintf("selectedSample_lrr_%s_draw_%d", lrr_id, grid$n_per_mlra))
  out  <- paste0(stub, ".csv")
  if (file.exists(out)) {
    message("Exists, not redrawn: ", out)
    next
  }
  res <- draw_lrr_sample_grid(lrr_id, mlra, g100, n = grid$n_per_mlra, seed = grid$seed, corrections = corrections)
  readr::write_csv(res$sample, out)
  readr::write_csv(res$diag, paste0(stub, "_diagnostics.csv"))
  message(sprintf("LRR %s: %d cells sampled across %d MLRAs -> %s",
                  lrr_id, nrow(res$sample), nrow(res$diag), out))
}
