# ==============================================================================
# TEMP: AOI counts for LRR F and each of its MLRAs, before and after the clip
# of the sampled 1 km cells to their MLRA (estimates/01_aoi_areas.R).
#   Rscript estimates/tools/tmp_aoi_counts.R
# Reads the sample list (for the MLRA list) and aoiAreas_lrr_F.csv (one row per
# (id, MLRA_ID, target_year), the AOIs are identical across years so one year
# is taken). Writes data/estimates/aoiCounts_lrr_F.csv.
#
# Columns:
#   aoi_total       AOIs after clipping: one per surviving (id, MLRA) pair
#   aoi_unique_ids  distinct cell ids among those AOIs
#   ids_shared      ids drawn by two MLRAs (they become two AOIs, one per MLRA);
#                   per MLRA: AOIs of this MLRA whose id is also an AOI elsewhere
#   ids_only_here   per MLRA: AOIs whose id belongs to this MLRA alone
#   aoi_whole       AOIs that are the whole 1 km cell (aoi_m2 == cell_m2)
#   aoi_clipped     AOIs smaller than their cell
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(dplyr, readr, tibble)
source(tof_root("sampling/functions/grid_cells.R"))   # read_sites_csv()

cfg_est <- tof_config()$estimates
llr_id  <- cfg_est$llr_id

sample_tbl <- read_sites_csv(tof_path(cfg_est$paths$sample_csv)) |>
  dplyr::filter(LLR_ID == llr_id) |> dplyr::distinct(id, MLRA_ID)
areas <- readr::read_csv(tof_path(cfg_est$paths$aoi_areas_csv), show_col_types = FALSE)
aoi <- areas |> dplyr::filter(target_year == min(target_year)) |>
  dplyr::distinct(id, MLRA_ID, cell_m2, aoi_m2)
stopifnot(!anyDuplicated(aoi[, c("id", "MLRA_ID")]))

shared_ids <- aoi$id[duplicated(aoi$id)]
aoi <- aoi |> dplyr::mutate(shared = id %in% shared_ids, whole = abs(aoi_m2 - cell_m2) < 1)

count_block <- function(s, a) {
  tibble::tibble(
    aoi_total      = nrow(a),
    aoi_unique_ids = dplyr::n_distinct(a$id),
    ids_shared     = sum(a$shared),
    ids_only_here  = sum(!a$shared),
    aoi_whole      = sum(a$whole),
    aoi_clipped    = sum(!a$whole)
  )
}

lrr_row <- dplyr::bind_cols(tibble::tibble(level = "LRR", MLRA_ID = llr_id), count_block(sample_tbl, aoi)) |>
  dplyr::mutate(ids_shared = length(unique(shared_ids)))   # at LRR level: count ids, not AOIs
mlra_rows <- purrr::map_dfr(sort(unique(c(sample_tbl$MLRA_ID, aoi$MLRA_ID))), function(h) {
  dplyr::bind_cols(tibble::tibble(level = "MLRA", MLRA_ID = as.character(h)),
                   count_block(sample_tbl[sample_tbl$MLRA_ID == h, ], aoi[aoi$MLRA_ID == h, ]))
})
out <- dplyr::bind_rows(lrr_row, mlra_rows)

csv_out <- tof_path(file.path(cfg_est$paths$out_dir, sprintf("aoiCounts_lrr_%s.csv", llr_id)))
readr::write_csv(out, csv_out)
print(as.data.frame(out), row.names = FALSE)
message("Wrote ", csv_out)
