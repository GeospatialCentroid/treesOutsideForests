# ==============================================================================
# One sample-design map pair per MLRA in the LRR and per partition in config.yml
# `sampling$partitions`. Only that MLRA is drawn (plus the LRR outline for
# context); every other layer is limited to the MLRA before it is added. Run
# from the root project:
#   source("sampling/02_map_mlra_sites.R")
# Outputs: data/sampling/maps/mlra/lrr_<id>_mlra_<sym>_sample_design_<partition>.{png,html}
# ==============================================================================
source(here::here("sampling/00_prepare_sites.R"))

layers$forest <- forest_layer(cfg_smp$forest_block_mlra)
mlra_dir <- file.path(map_dir, "mlra")
dir.create(mlra_dir, showWarnings = FALSE, recursive = TRUE)

for (i in seq_len(nrow(mlra))) {
  this <- mlra[i, ]
  for (key in names(partitions)) {
    label <- partitions[[key]]$label
    message(sprintf("\n=== MLRA %s: %s, partition %s (%s)", this$MLRARSYM, this$MLRA_NAME, key, label))
    layers$pts <- pts_by[[key]]
    clipped <- clip_layers(this, layers, margin_m = cfg_smp$mlra_margin_m)
    r <- sf::st_drop_geometry(clipped$pts)
    stub <- file.path(mlra_dir, sprintf("lrr_%s_mlra_%s_sample_design_%s", llr_id, this$MLRARSYM, key))
    # Fit the page to the MLRA's shape rather than forcing every map into 14 x 9.
    bb <- clipped$bbox; aspect <- as.numeric((bb["ymax"] - bb["ymin"]) / (bb["xmax"] - bb["xmin"]))
    title    <- sprintf("MLRA %s %s (LRR %s): %s", this$MLRARSYM, this$MLRA_NAME, llr_id, label)
    subtitle <- sprintf("%s sampled 1 km cells; %d training and %d validation sites",
                        format(sum(r$role == role_labels[["sample"]]), big.mark = ","),
                        sum(r$role == role_labels[["training"]]), sum(r$role == role_labels[["validation"]]))
    static_site_map(
      area = this, clipped = clipped, lrr = lrr, mlra = this, mlra_cols = mlra_cols[this$mlra_label],
      title = title, subtitle = subtitle,
      caption  = paste(sprintf("Sampled cells drawn as 1 km outlines. Heavy line is the LRR %s boundary; grey labels are states.", llr_id),
                       role_source_text(key), sep = "\n"),
      out_png = paste0(stub, ".png"), cells_as = "outlines", mlra_legend = FALSE,
      width  = if (aspect > 1) max(7, 12 / aspect + 1) else 12,
      height = if (aspect > 1) 12 else max(6, 12 * aspect + 1.5))
    web_site_map(clipped, lrr = lrr, mlra = this, mlra_cols = mlra_cols[this$mlra_label], out_html = paste0(stub, ".html"),
                 grid_zoom = cfg_smp$interactive_grid_min_zoom, ctx_year = ctx_year,
                 title = title, subtitle = subtitle, mlra_legend = FALSE, libdir = "libs")
  }
}
message("\nAll MLRA maps written to ", mlra_dir)
