# ==============================================================================
# Whole-LRR static map of the full systematic sample, for the report: every
# sampled 1 km cell drawn as a visible dot, the training / validation sites on
# top, and a zoom inset that shows the lattice at the scale of the 1 km cells
# (at LRR scale the ~15,000 cells read as a texture, not as individual plots).
# One map per partition in config.yml `sampling$partitions`. Run from the root project:
#   source("sampling/05_map_lrr_full_sample.R")
# Outputs: data/sampling/maps/lrr_<id>_full_sample_<partition>.{png,pdf}; the PDF
# is vector, so zooming in resolves every sampled cell.
# ==============================================================================
source(here::here("sampling/00_prepare_sites.R"))
pacman::p_load(patchwork)
sample_tbl_all <- read_sites_csv(tof_path(cfg_smp$paths$sample_csv))   # before the spatial test

inset_km   <- 60     # side of the zoom window
inset_mlra <- "55B"  # the window is centred on the sampled cell nearest this MLRA's centre

sample_col  <- "#3d3b37"   # dark neutral so each cell reads as its own mark, not a tint
sample_size <- 0.55        # mm, for the MLRA with the median lattice spacing (~5 km, ~10 px at 300 dpi)
full_cols  <- role_cols; full_cols[1] <- sample_col

# Zoom window: a square around the sampled cell nearest the MLRA's point on surface.
win_centre <- function(pts) {
  m  <- mlra[mlra$MLRARSYM == inset_mlra, ]
  c0 <- suppressWarnings(sf::st_point_on_surface(sf::st_geometry(m)))
  cand <- pts[pts$MLRARSYM == inset_mlra, ]
  sf::st_coordinates(cand[sf::st_nearest_feature(c0, cand), ])[1, ]
}

for (key in names(partitions)) {
  label <- partitions[[key]]$label
  message(sprintf("\n=== LRR %s full sample, partition %s (%s)", llr_id, key, label))
  roles <- roles_by[[key]]
  pts   <- pts_by[[key]]
  pts   <- pts[lengths(sf::st_within(pts, lrr)) > 0, ]
  n_cells <- sum(roles$in_sample_list)
  n_train <- sum(roles$role == "training"); n_val <- n_validation(roles)

  xy <- win_centre(pts)
  h  <- inset_km * 500
  win_bb <- sf::st_bbox(c(xmin = xy[[1]] - h, ymin = xy[[2]] - h, xmax = xy[[1]] + h, ymax = xy[[2]] + h), crs = sf::st_crs(crs))
  win <- sf::st_as_sfc(win_bb)
  bb  <- sf::st_bbox(sf::st_buffer(lrr, 60000))
  states <- suppressWarnings(sf::st_crop(layers$states, bb))
  mlra_lab <- suppressWarnings(sf::st_point_on_surface(mlra))
  samp  <- pts[pts$role == role_labels[1], ]
  # Every MLRA gets ~1,400 cells, so small MLRAs have a tighter lattice; scale
  # the dot with each MLRA's spacing (sqrt(area / cells)) so dots never merge.
  spacing <- sqrt(as.numeric(sf::st_area(mlra)) / as.numeric(table(factor(pts$MLRARSYM, levels = mlra$MLRARSYM))))
  names(spacing) <- mlra$MLRARSYM
  samp$dot <- pmin(sample_size, sample_size * spacing[samp$MLRARSYM] / stats::median(spacing))
  message("Lattice spacing per MLRA (km): ", paste(sprintf("%s %.1f", names(spacing), spacing / 1000), collapse = ", "))
  sites <- pts[pts$role != role_labels[1], ]

  base_theme <- ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(panel.grid = ggplot2::element_blank(), axis.text = ggplot2::element_blank(),
                   axis.title = ggplot2::element_blank())

  main <- ggplot2::ggplot() +
    ggplot2::geom_sf(data = states, fill = "#f7f6f3", colour = "#d9d7d0", linewidth = 0.3) +
    ggplot2::geom_sf(data = mlra, ggplot2::aes(fill = mlra_label), colour = "#8a8880", linewidth = 0.35) +
    ggplot2::geom_sf(data = lrr, fill = NA, colour = "#0b0b0b", linewidth = 0.8) +
    ggplot2::geom_sf(data = samp, ggplot2::aes(colour = role, shape = role, size = dot), stroke = 0) +
    ggplot2::scale_size_identity() +
    ggplot2::geom_sf(data = sites, ggplot2::aes(colour = role, shape = role), size = 1.8) +
    ggplot2::geom_sf(data = win, fill = NA, colour = "#0b0b0b", linewidth = 0.6) +
    ggplot2::geom_sf_text(data = mlra_lab, ggplot2::aes(label = MLRARSYM), size = 3.2, colour = "#0b0b0b", fontface = "bold") +
    ggplot2::geom_sf_text(data = suppressWarnings(sf::st_point_on_surface(states)), ggplot2::aes(label = STUSPS), size = 3, colour = "#9a9890") +
    ggplot2::scale_fill_manual(values = mlra_cols, name = "MLRA") +
    ggplot2::scale_colour_manual(values = full_cols, name = NULL, drop = FALSE) +
    ggplot2::scale_shape_manual(values = role_shapes, name = NULL, drop = FALSE) +
    ggplot2::guides(fill   = ggplot2::guide_legend(position = "right", ncol = 1, override.aes = list(colour = "#8a8880")),
                    colour = ggplot2::guide_legend(position = "bottom", override.aes = list(size = 3)),
                    shape  = ggplot2::guide_legend(position = "bottom")) +
    ggplot2::coord_sf(xlim = bb[c("xmin", "xmax")], ylim = bb[c("ymin", "ymax")], expand = FALSE) +
    base_theme +
    ggplot2::theme(legend.key.size = grid::unit(0.45, "cm"), legend.key.spacing.y = grid::unit(4, "pt"),
                   legend.text = ggplot2::element_text(size = 8.5))

  # Inset: the same window at 1 km-cell scale, cells as outlines.
  cells_win <- layers$cells[layers$cells$id %in% pts$id, ]
  cells_win <- cells_win[lengths(sf::st_intersects(cells_win, win)) > 0, ]
  cells_win <- dplyr::left_join(cells_win, sf::st_drop_geometry(pts)[, c("id", "role")], by = "id")
  inset <- ggplot2::ggplot() +
    ggplot2::geom_sf(data = suppressWarnings(sf::st_crop(mlra, win_bb)), ggplot2::aes(fill = mlra_label), colour = "#8a8880", linewidth = 0.4, show.legend = FALSE) +
    ggplot2::geom_sf(data = cells_win[cells_win$role == role_labels[1], ], fill = NA, colour = sample_col, linewidth = 0.3) +
    ggplot2::geom_sf(data = cells_win[cells_win$role != role_labels[1], ], ggplot2::aes(colour = role), fill = NA, linewidth = 0.9, show.legend = FALSE) +
    ggplot2::scale_fill_manual(values = mlra_cols) +
    ggplot2::scale_colour_manual(values = full_cols) +
    ggplot2::coord_sf(xlim = win_bb[c("xmin", "xmax")], ylim = win_bb[c("ymin", "ymax")], expand = FALSE, datum = NA) +
    ggplot2::labs(subtitle = sprintf("Inset: %d x %d km in MLRA %s, cells to scale", inset_km, inset_km, inset_mlra)) +
    base_theme +
    ggplot2::theme(panel.border = ggplot2::element_rect(fill = NA, colour = "#0b0b0b", linewidth = 0.8),
                   plot.background = ggplot2::element_rect(fill = "#fcfcfb", colour = NA),
                   plot.subtitle = ggplot2::element_text(size = 8.5, colour = "#52514e"))

  p <- main +
    patchwork::inset_element(inset, left = 0.0, bottom = 0.0, right = 0.26, top = 0.42, align_to = "panel") +
    patchwork::plot_annotation(
      title = sprintf("LRR %s systematic sample: %s", llr_id, label),
      subtitle = sprintf("%s sampled 1 km cells across %d MLRAs (about 1,400 per MLRA, regular lattice); %d training and %d validation sites",
                         format(n_cells, big.mark = ","), nrow(mlra), n_train, n_val),
      caption = paste("Each small dark dot is one sampled 1 km cell (dot size follows each MLRA's grid spacing); the boxed window is enlarged in the inset, where cells are drawn to scale.",
                      sprintf("Cells are counted by centre point; the estimation plot table also keeps the %d border cells whose centre lies outside the LRR, clipped to it.",
                              sum(dropped %in% sample_tbl_all$id)),
                      role_source_text(key), "Bold labels are MLRA symbols; grey labels are states.", sep = "\n"),
      theme = ggplot2::theme(plot.title = ggplot2::element_text(face = "bold"),
                             plot.caption = ggplot2::element_text(colour = "#52514e", hjust = 0),
                             plot.background = ggplot2::element_rect(fill = "#fcfcfb", colour = NA)))

  out_png <- file.path(map_dir, sprintf("lrr_%s_full_sample_%s.png", llr_id, key))
  ragg::agg_png(out_png, width = 14, height = 9, units = "in", res = 300)
  print(p); invisible(grDevices::dev.off())
  out_pdf <- sub("\\.png$", ".pdf", out_png)
  grDevices::cairo_pdf(out_pdf, width = 14, height = 9)
  print(p); invisible(grDevices::dev.off())
  message("Wrote ", out_png, " and ", basename(out_pdf))
}
