# ==============================================================================
# One sample-design map pair per MLRA in the LRR. Only that MLRA is drawn (plus
# the LRR outline for context); every other layer is limited to the MLRA before
# it is added. Run from the root project:
#   source("sampling/02_map_mlra_sites.R")
# Outputs: data/sampling/maps/mlra/lrr_<id>_mlra_<sym>_sample_design.{png,html}
# ==============================================================================
source(here::here("sampling/00_prepare_sites.R"))

layers$forest <- forest_layer(cfg_smp$forest_block_mlra)
mlra_dir <- file.path(map_dir, "mlra")
dir.create(mlra_dir, showWarnings = FALSE, recursive = TRUE)

for (i in seq_len(nrow(mlra))) {
  this <- mlra[i, ]
  message(sprintf("\n=== MLRA %s: %s", this$MLRARSYM, this$MLRA_NAME))
  clipped <- clip_layers(this, layers, margin_m = cfg_smp$mlra_margin_m)
  r <- sf::st_drop_geometry(clipped$pts)
  stub <- file.path(mlra_dir, sprintf("lrr_%s_mlra_%s_sample_design", llr_id, this$MLRARSYM))
  # Fit the page to the MLRA's shape rather than forcing every map into 14 x 9.
  bb <- clipped$bbox; aspect <- as.numeric((bb["ymax"] - bb["ymin"]) / (bb["xmax"] - bb["xmin"]))
  title    <- sprintf("MLRA %s %s (LRR %s)", this$MLRARSYM, this$MLRA_NAME, llr_id)
  subtitle <- sprintf("%s sampled 1 km cells; %d training and %d validation sites",
                      format(sum(r$role == role_labels[1]), big.mark = ","),
                      sum(r$role == role_labels[2]), sum(r$role == role_labels[3]))
  static_site_map(
    area = this, clipped = clipped, lrr = lrr, mlra = this, mlra_cols = mlra_cols[this$mlra_label],
    title = title, subtitle = subtitle,
    caption  = sprintf("Sampled cells drawn as 1 km outlines. Heavy line is the LRR %s boundary; grey labels are states. Roles from siteRoles_lrr_%s (seed %d).",
                       llr_id, llr_id, cfg_smp$seed),
    out_png = paste0(stub, ".png"), cells_as = "outlines", mlra_legend = FALSE,
    width  = if (aspect > 1) max(7, 12 / aspect + 1) else 12,
    height = if (aspect > 1) 12 else max(6, 12 * aspect + 1.5))
  web_site_map(clipped, lrr = lrr, mlra = this, mlra_cols = mlra_cols[this$mlra_label], out_html = paste0(stub, ".html"),
               grid_zoom = cfg_smp$interactive_grid_min_zoom, ctx_year = ctx_year,
               title = title, subtitle = subtitle, mlra_legend = FALSE, libdir = "libs")
}
message("\nAll MLRA maps written to ", mlra_dir)
