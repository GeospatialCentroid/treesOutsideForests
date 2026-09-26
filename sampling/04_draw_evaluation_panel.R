# ==============================================================================
# Draw the evaluation panel: a seeded random sample of the sampled 1 km cells,
# about n_per_mlra per MLRA plus a spare fraction, excluding the labelled
# (mask) cells and the partner's change-trend cells, so every candidate model
# can be run through the estimator on a fixed, representative, unlabelled set
# (model/TESTING_PLAN.md section 3.1). Run from the root project:
#   Rscript sampling/04_draw_evaluation_panel.R
# Output (tracked, small): config.yml sampling$panel$out_csv with
#   id, MLRA_ID, MLRARSYM, LLR_ID, draw_order (1 = first drawn in its MLRA),
#   tranche ("1": the first `tranche1` per MLRA, "2": the rest of n_per_mlra,
#   "spare": the extra spare_frac, used only to replace cells whose export fails)
# An existing output is not overwritten; delete it to redraw.
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(sf, dplyr, purrr, readr, tibble)
source(tof_root("sampling/functions/grid_cells.R"))   # read_sites_csv()

cfg   <- tof_config()
cs    <- cfg$sampling
panel <- cs$panel
llr_id <- cs$llr_id
out <- tof_path(panel$out_csv)
if (file.exists(out)) { message("Exists, not redrawn: ", out); quit(save = "no") }

# --- the frame: the tracked sample list, one row per cell (first MLRA wins) ----
sample_tbl <- read_sites_csv(tof_path(cs$paths$sample_csv)) |>
  dplyr::filter(LLR_ID == llr_id) |>
  dplyr::distinct(id, .keep_all = TRUE)
mlra <- sf::st_drop_geometry(sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE)) |>
  dplyr::filter(LRRSYM == llr_id) |> dplyr::distinct(MLRA_ID, MLRARSYM)
sample_tbl <- dplyr::left_join(sample_tbl, dplyr::mutate(mlra, MLRA_ID = as.integer(MLRA_ID)), by = "MLRA_ID")

# --- exclusions: labelled cells and change-trend cells --------------------------
mask_ids <- unique(sub("_(\\d{4})_mask[.]tif$", "",
                       unlist(lapply(vapply(cfg$model$paths$mask_dirs, tof_path, character(1)),
                                     list.files, pattern = "_mask[.]tif$"))))
trend_ids <- if (!is.null(panel$exclude_change_trends) && file.exists(tof_path(panel$exclude_change_trends))) {
  readr::read_csv(tof_path(panel$exclude_change_trends), show_col_types = FALSE)$aoi_id
} else character(0)
frame <- sample_tbl |> dplyr::filter(!id %in% mask_ids, !id %in% trend_ids)
message(sprintf("LRR %s: %d sampled cells; %d labelled and %d change-trend cells excluded (%d in both); frame %d cells in %d MLRAs.",
                llr_id, nrow(sample_tbl), sum(sample_tbl$id %in% mask_ids), sum(sample_tbl$id %in% trend_ids),
                sum(sample_tbl$id %in% mask_ids & sample_tbl$id %in% trend_ids), nrow(frame), dplyr::n_distinct(frame$MLRA_ID)))

# --- the draw: one seeded permutation per MLRA, in MLRA_ID order ------------------
n_draw <- ceiling(panel$n_per_mlra * (1 + panel$spare_frac))
set.seed(panel$seed)
drawn <- frame |>
  dplyr::arrange(MLRA_ID, id) |>
  dplyr::group_by(MLRA_ID) |>
  dplyr::group_modify(function(d, key) {
    take <- min(n_draw, nrow(d))
    d[sample.int(nrow(d), take), ] |> dplyr::mutate(draw_order = seq_len(take))
  }) |>
  dplyr::ungroup() |>
  dplyr::mutate(tranche = dplyr::case_when(draw_order <= panel$tranche1 ~ "1",
                                           draw_order <= panel$n_per_mlra ~ "2",
                                           TRUE ~ "spare")) |>
  dplyr::select(id, MLRA_ID, MLRARSYM, LLR_ID, draw_order, tranche) |>
  dplyr::arrange(MLRA_ID, draw_order)

readr::write_csv(drawn, out)
message(sprintf("Panel: %d cells (%d in tranche 1, %d in tranche 2, %d spare) -> %s",
                nrow(drawn), sum(drawn$tranche == "1"), sum(drawn$tranche == "2"), sum(drawn$tranche == "spare"), out))
print(dplyr::count(drawn, MLRARSYM, tranche) |> tidyr::pivot_wider(names_from = tranche, values_from = n), n = Inf)
