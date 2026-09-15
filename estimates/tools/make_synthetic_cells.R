# ==============================================================================
# Writes a synthetic pixel-count table for the sampled cells of the target LRR,
# in the layout the estimates driver reads when `estimates$model_source` is
# "table", plus the per-MLRA truth it was generated from. Settings come from
# config.yml `estimates$synthetic`. Run from the root project:
#   source("estimates/tools/make_synthetic_cells.R")
# Outputs (ignored by git), under estimates$synthetic$out_dir:
#   synthetic_cells_lrr_<LRR>.csv   id, MLRA_ID, target_year, actual_year, footprint_px, eligible_px, tof_px
#   synthetic_truth_lrr_<LRR>.csv   generating parameters per MLRA
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(dplyr, purrr, readr, tibble)
source(tof_root("sampling/functions/grid_cells.R"))   # read_sites_csv()
source(tof_root("estimates/functions/synthetic.R"))

cfg_est <- tof_config()$estimates
llr_id  <- cfg_est$llr_id
syn     <- cfg_est$synthetic
out_dir <- tof_path(syn$out_dir)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

sample_tbl <- read_sites_csv(tof_path(cfg_est$paths$sample_csv)) |> dplyr::filter(LLR_ID == llr_id)
truth <- synthetic_truth(sort(unique(sample_tbl$MLRA_ID)), seed = syn$seed)
tab   <- synthetic_cells(sample_tbl, truth, as.integer(cfg_est$target_years),
                         seed = syn$seed, pixel_area_m2 = cfg_est$pixel_area_m2)

cells_path <- file.path(out_dir, sprintf("synthetic_cells_lrr_%s.csv", llr_id))
truth_path <- file.path(out_dir, sprintf("synthetic_truth_lrr_%s.csv", llr_id))
readr::write_csv(tab, cells_path)
readr::write_csv(truth, truth_path)

message(sprintf("LRR %s: %d rows for %d cells in %d MLRAs and %d years (%d duplicate ids kept in their first MLRA).",
                llr_id, nrow(tab), dplyr::n_distinct(tab$id), dplyr::n_distinct(tab$MLRA_ID),
                dplyr::n_distinct(tab$target_year), nrow(sample_tbl) - dplyr::n_distinct(sample_tbl$id)))
print(tab |>
        dplyr::group_by(MLRA_ID, target_year) |>
        dplyr::summarise(n = dplyr::n(), share_zero = mean(tof_px == 0),
                         masked_pct = 100 * (1 - sum(eligible_px) / sum(footprint_px)),
                         tof_pct_eligible = 100 * sum(tof_px) / sum(eligible_px), .groups = "drop") |>
        dplyr::left_join(dplyr::transmute(truth, MLRA_ID, truth_pct = 100 * tof_frac_eligible), by = "MLRA_ID"),
      n = Inf)
message("Wrote ", cells_path, "\n  and ", truth_path)
