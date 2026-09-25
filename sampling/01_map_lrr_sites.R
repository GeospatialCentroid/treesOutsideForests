# ==============================================================================
# Whole-LRR sample-design maps: every sampled 1 km cell, the MLRAs, and the
# training / validation sites, one map pair per partition in config.yml
# `sampling$partitions`. Run from the root project:
#   source("sampling/01_map_lrr_sites.R")
# Outputs: data/sampling/maps/lrr_<id>_sample_design_<partition>.{png,html}
# ==============================================================================
source(here::here("sampling/00_prepare_sites.R"))

layers$forest <- forest_layer(cfg_smp$forest_block_lrr)

for (key in names(partitions)) {
  label <- partitions[[key]]$label
  message(sprintf("\n=== LRR %s, partition %s (%s)", llr_id, key, label))
  layers$pts <- pts_by[[key]]
  roles <- roles_by[[key]]
  clipped <- clip_layers(lrr, layers, margin_m = 60000)
  stub <- file.path(map_dir, sprintf("lrr_%s_sample_design_%s", llr_id, key))

  title    <- sprintf("LRR %s sample design: %s", llr_id, label)
  subtitle <- sprintf("%s sampled 1 km cells across %d MLRAs; %d training and %d validation sites",
                      format(sum(roles$role == "sample"), big.mark = ","), nrow(mlra),
                      sum(roles$role == "training"), n_validation(roles))
  static_site_map(
    area = lrr, clipped = clipped, lrr = lrr, mlra = mlra, mlra_cols = mlra_cols,
    title = title, subtitle = subtitle,
    caption  = paste(role_source_text(key), "Bold labels are MLRA symbols; grey labels are states.", sep = "\n"),
    out_png = paste0(stub, ".png"), cells_as = "points", mlra_legend = TRUE)

  web_site_map(clipped, lrr = lrr, mlra = mlra, mlra_cols = mlra_cols, out_html = paste0(stub, ".html"),
               grid_zoom = cfg_smp$interactive_grid_min_zoom, ctx_year = ctx_year,
               title = title, subtitle = subtitle, mlra_legend = TRUE, libdir = "libs")
}
