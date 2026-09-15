# ==============================================================================
# Replication test for the systematic sample grid.
#
# Redraws the sample grid for every LRR in config.yml `sampling$grid$reference`
# and compares it with the tracked May 2026 list from the neymanSampling repo:
#   - same number of rows, same ids in the same order, same MLRA_ID / LLR_ID
#   - per-MLRA counts
#   - the CSV written by readr::write_csv() is byte-identical (md5) to the
#     reference file
#   - if 00_draw_sample_grid.R has already written its output, that file too
# It also prints, per MLRA, how the draw depended on the 1 km cell count: the
# lattice size sf used and the range of cell counts that give the same draw.
# Boundary cells that touch an MLRA over a few square millimetres can flip with
# GEOS / PROJ versions, so a wide range means the draw is robust to that.
#
# Run from the root project:  source("sampling/test/test_sample_grid_replication.R")
# or from a shell:            Rscript sampling/test/test_sample_grid_replication.R
# Exits with status 1 on any failure when run non-interactively.
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(sf, dplyr, purrr, readr, tools)
source(tof_root("sampling/functions/sample_grid.R"))

cfg  <- tof_config()
grid <- cfg$sampling$grid

cat("R ", R.version$major, ".", R.version$minor, "; sf ", as.character(packageVersion("sf")),
    "; GEOS ", sf::sf_extSoftVersion()[["GEOS"]], "; GDAL ", sf::sf_extSoftVersion()[["GDAL"]],
    "; PROJ ", sf::sf_extSoftVersion()[["PROJ"]], "\n", sep = "")

mlra <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE)
g100 <- sf::st_read(tof_path(cfg$reference$grid_gpkg), quiet = TRUE)
corrections <- read_frame_corrections(tof_path(grid$frame_corrections))

read_ref <- function(path) {
  readr::read_csv(path, show_col_types = FALSE,
                  col_types = readr::cols(id = "c", MLRA_ID = "d", LLR_ID = "c"))
}
check <- function(ok, what) {
  cat(sprintf("  [%s] %s\n", if (ok) "PASS" else "FAIL", what))
  ok
}

all_ok <- TRUE
for (lrr_id in names(grid$reference)) {
  ref_path <- tof_path(grid$reference[[lrr_id]])
  cat("\n=== LRR ", lrr_id, " vs ", basename(ref_path), " ===\n", sep = "")
  ref <- read_ref(ref_path)

  t0  <- Sys.time()
  res <- draw_lrr_sample_grid(lrr_id, mlra, g100, n = grid$n_per_mlra, seed = grid$seed, corrections = corrections)
  new <- res$sample
  cat(sprintf("Redraw took %.1f min\n", as.numeric(Sys.time() - t0, units = "mins")))

  ok <- TRUE
  ok <- check(nrow(new) == nrow(ref), sprintf("row count: %d drawn, %d in reference", nrow(new), nrow(ref))) && ok
  ok <- check(identical(new$id, ref$id), "ids identical and in the same order") && ok
  ok <- check(setequal(new$id, ref$id), "same set of ids") && ok
  ok <- check(identical(as.numeric(new$MLRA_ID), as.numeric(ref$MLRA_ID)), "MLRA_ID column identical") && ok
  ok <- check(identical(new$LLR_ID, ref$LLR_ID), "LLR_ID column identical") && ok

  tmp <- tempfile(fileext = ".csv")
  readr::write_csv(new, tmp)
  same_bytes <- identical(readBin(tmp, "raw", file.size(tmp)), readBin(ref_path, "raw", file.size(ref_path)))
  ok <- check(same_bytes, sprintf("written CSV byte-identical to reference (md5 %s)", tools::md5sum(ref_path)[[1]])) && ok

  drawn_path <- tof_path(file.path(grid$out_dir, sprintf("selectedSample_lrr_%s_draw_%d.csv", lrr_id, grid$n_per_mlra)))
  if (file.exists(drawn_path)) {
    ok <- check(tools::md5sum(drawn_path)[[1]] == tools::md5sum(ref_path)[[1]],
                paste("00_draw_sample_grid.R output byte-identical:", basename(drawn_path))) && ok
  } else {
    cat("  [SKIP] no output from 00_draw_sample_grid.R at", drawn_path, "\n")
  }

  per_mlra <- dplyr::full_join(
    ref |> dplyr::count(MLRA_ID, name = "n_reference"),
    new |> dplyr::count(MLRA_ID, name = "n_drawn"), by = "MLRA_ID") |>
    dplyr::left_join(res$diag |> dplyr::select(MLRA_ID, n_cells, cells_added, cells_dropped, lattice_size, cells_lo, cells_hi), by = "MLRA_ID") |>
    dplyr::mutate(match = n_reference == n_drawn)
  cat("\n  Per MLRA (cells_added / cells_dropped: frame-table corrections; cells_lo..cells_hi: cell counts giving this same draw):\n")
  print(as.data.frame(per_mlra), row.names = FALSE)
  ok <- check(all(per_mlra$match), "per-MLRA counts match") && ok

  dup_ref <- sum(duplicated(ref$id)); dup_new <- sum(duplicated(new$id))
  cat(sprintf("  Duplicate ids across MLRAs (cells straddling an MLRA boundary): %d in reference, %d drawn\n", dup_ref, dup_new))

  cat(sprintf("  LRR %s: %s\n", lrr_id, if (ok) "REPLICATED EXACTLY" else "MISMATCH"))
  all_ok <- all_ok && ok
}

cat("\n", if (all_ok) "ALL SAMPLE GRIDS REPLICATED EXACTLY" else "REPLICATION FAILED", "\n", sep = "")
if (!interactive() && !all_ok) quit(status = 1)
