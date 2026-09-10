# ==============================================================================
# Whole-LRR sample-design maps: every sampled 1 km cell, the MLRAs, and the
# training / validation sites. Run from the root project:
#   source("sampling/01_map_lrr_sites.R")
# Outputs: data/sampling/maps/lrr_<id>_sample_design.{png,html}
# ==============================================================================
source(here::here("sampling/00_prepare_sites.R"))

layers$forest <- forest_layer(cfg_smp$forest_block_lrr)
clipped <- clip_layers(lrr, layers, margin_m = 60000)
stub <- file.path(map_dir, sprintf("lrr_%s_sample_design", llr_id))

title    <- sprintf("LRR %s sample design", llr_id)
subtitle <- sprintf("%s sampled 1 km cells across %d MLRAs; %d training and %d validation sites",
                    format(sum(roles$role == "sample"), big.mark = ","), nrow(mlra),
                    sum(roles$role == "training"), sum(roles$role == "validation"))
static_site_map(
  area = lrr, clipped = clipped, lrr = lrr, mlra = mlra, mlra_cols = mlra_cols,
  title = title, subtitle = subtitle,
  caption  = sprintf("Training and validation are the June 2026 ground-truth sites inside LRR %s, split at random with seed %d. Bold labels are MLRA symbols; grey labels are states.",
                     llr_id, cfg_smp$seed),
  out_png = paste0(stub, ".png"), cells_as = "points", mlra_legend = TRUE)

web_site_map(clipped, lrr = lrr, mlra = mlra, mlra_cols = mlra_cols, out_html = paste0(stub, ".html"),
             grid_zoom = cfg_smp$interactive_grid_min_zoom, ctx_year = ctx_year,
             title = title, subtitle = subtitle, mlra_legend = TRUE, libdir = "libs")
