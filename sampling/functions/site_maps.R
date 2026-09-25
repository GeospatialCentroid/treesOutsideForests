# Static and interactive site-design maps for one area (the LRR or a single MLRA).
# Every layer handed in is first limited to the area: sites and cells by centroid
# location, places by intersection, forest by crop-and-mask, states by bbox.

# Names are the map roles; values are the legend labels. The partition's test
# sites are drawn as validation sites (00_prepare_sites.R merges them), so the
# maps show two site roles.
role_labels <- c(sample = "Sampled 1 km cell", training = "Training site", validation = "Validation site")
role_cols   <- c("#b8b6b0", "#4a3aa7", "#e34948")   # neutral + violet/red: passes CVD, normal-vision and contrast checks
role_shapes <- c(16, 17, 15)
names(role_cols) <- names(role_shapes) <- role_labels

# Subtle MLRA fills: equally spaced pale hues, low chroma, so the saturated
# site marks stay legible on top. Identity is also carried by the bold labels.
mlra_palette <- function(mlra) {
  cols <- grDevices::hcl(h = seq(15, 375, length.out = nrow(mlra) + 1)[seq_len(nrow(mlra))], c = 28, l = 88)
  stats::setNames(cols, mlra$mlra_label)
}

#' Limit every layer to `area` (an sf polygon in the analysis CRS).
clip_layers <- function(area, layers, margin_m) {
  bb <- sf::st_bbox(sf::st_buffer(area, margin_m))
  in_area <- function(x) x[lengths(sf::st_within(suppressWarnings(sf::st_centroid(x)), area)) > 0, ]
  out <- list(bbox = bb)
  out$pts    <- in_area(layers$pts)
  out$cells  <- layers$cells[layers$cells$id %in% out$pts$id, ]
  out$states <- if (is.null(layers$states)) NULL else suppressWarnings(sf::st_crop(layers$states, bb))
  out$places <- if (is.null(layers$places)) NULL else suppressWarnings(sf::st_intersection(layers$places, sf::st_geometry(area)))
  out$forest <- if (is.null(layers$forest)) NULL else
    terra::mask(terra::crop(layers$forest, terra::vect(area), snap = "out"), terra::vect(area))
  out
}

#' Static map. `mlra` is the MLRA layer to fill (all of them for the LRR map,
#' one for an MLRA map); `cells_as` controls whether the 1 km sample cells are
#' drawn as points (whole-LRR scale) or as outlines (MLRA scale).
static_site_map <- function(area, clipped, lrr, mlra, mlra_cols, title, subtitle, caption, out_png,
                            cells_as = c("points", "outlines"), mlra_legend = TRUE, width = 14, height = 9) {
  cells_as <- match.arg(cells_as)
  bb <- clipped$bbox
  states <- clipped$states; pts <- clipped$pts
  mlra_lab <- suppressWarnings(sf::st_point_on_surface(mlra))
  p <- ggplot2::ggplot() +
    { if (!is.null(states)) ggplot2::geom_sf(data = states, fill = "#f7f6f3", colour = "#d9d7d0", linewidth = 0.3) } +
    ggplot2::geom_sf(data = mlra, ggplot2::aes(fill = mlra_label), colour = "#8a8880", linewidth = 0.35) +
    ggplot2::geom_sf(data = lrr, fill = NA, colour = "#0b0b0b", linewidth = 0.8) +
    { if (cells_as == "points")
        ggplot2::geom_sf(data = pts[pts$role == role_labels[1], ], ggplot2::aes(colour = role, shape = role), size = 0.5, alpha = 0.6)
      else
        ggplot2::geom_sf(data = clipped$cells, fill = NA, colour = "#7a7870", linewidth = 0.2) } +
    ggplot2::geom_sf(data = pts[pts$role != role_labels[1], ], ggplot2::aes(colour = role, shape = role), size = if (cells_as == "points") 1.6 else 2.2) +
    ggplot2::geom_sf_text(data = mlra_lab, ggplot2::aes(label = MLRARSYM), size = 3.2, colour = "#0b0b0b", fontface = "bold") +
    { if (!is.null(states)) ggplot2::geom_sf_text(data = suppressWarnings(sf::st_point_on_surface(states)), ggplot2::aes(label = STUSPS), size = 3, colour = "#9a9890") } +
    ggplot2::scale_fill_manual(values = mlra_cols, name = "MLRA", guide = if (mlra_legend) "legend" else "none") +
    ggplot2::scale_colour_manual(values = role_cols, name = NULL, drop = FALSE) +
    ggplot2::scale_shape_manual(values = role_shapes, name = NULL, drop = FALSE) +
    ggplot2::guides(fill   = if (mlra_legend) ggplot2::guide_legend(position = "right", ncol = 1, override.aes = list(colour = "#8a8880")) else "none",
                    colour = ggplot2::guide_legend(position = "bottom", override.aes = list(size = 3, alpha = 1)),
                    shape  = ggplot2::guide_legend(position = "bottom")) +
    ggplot2::coord_sf(xlim = bb[c("xmin", "xmax")], ylim = bb[c("ymin", "ymax")], expand = FALSE) +
    ggplot2::labs(title = title, subtitle = subtitle, caption = caption) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(panel.grid = ggplot2::element_blank(), axis.text = ggplot2::element_blank(), axis.title = ggplot2::element_blank(),
                   plot.background = ggplot2::element_rect(fill = "#fcfcfb", colour = NA),
                   legend.key.size = grid::unit(0.45, "cm"), legend.key.spacing.y = grid::unit(4, "pt"),
                   legend.text = ggplot2::element_text(size = 8.5),
                   plot.title = ggplot2::element_text(face = "bold"), plot.caption = ggplot2::element_text(colour = "#52514e", hjust = 0))
  ragg::agg_png(out_png, width = width, height = height, units = "in", res = 200)
  print(p); invisible(grDevices::dev.off())
  message("Wrote ", out_png)
  invisible(p)
}

#' Interactive map with Esri base maps, the LRR outline, the MLRA fill(s),
#' 1 km cell outlines from `grid_zoom`, the sites, and Census places and NLCD
#' forest context layers that start hidden.
web_site_map <- function(clipped, lrr, mlra, mlra_cols, out_html, grid_zoom, ctx_year, title, subtitle = NULL, mlra_legend = TRUE, libdir = NULL) {
  to_ll <- function(x) sf::st_transform(x, 4326)
  pts_ll <- to_ll(clipped$pts); cells_ll <- to_ll(clipped$cells[clipped$cells$id %in% clipped$pts$id[clipped$pts$role == role_labels[1]], ])
  cells_ll <- dplyr::left_join(cells_ll, sf::st_drop_geometry(clipped$pts)[, c("id", "MLRARSYM")], by = "id")
  site_pal <- leaflet::colorFactor(unname(role_cols), levels = role_labels)
  mlra_pal <- leaflet::colorFactor(unname(mlra_cols), levels = names(mlra_cols))
  forest_pal <- leaflet::colorNumeric(c("#b7e4c7", "#2d6a4f", "#081c15"), domain = c(0, 1), na.color = "#00000000")
  grid_group   <- sprintf("Sampled 1 km cells (zoom %d+)", grid_zoom)
  places_group <- sprintf("Census places %d", ctx_year)
  forest_group <- sprintf("NLCD forest %d (fraction per %d m)", ctx_year, if (is.null(clipped$forest)) 0 else round(terra::res(clipped$forest)[1]))

  m <- leaflet::leaflet() |>
    leaflet::addProviderTiles(leaflet::providers$Esri.WorldGrayCanvas, group = "Esri grey") |>
    leaflet::addProviderTiles(leaflet::providers$Esri.WorldImagery,    group = "Esri satellite") |>
    leaflet::addPolygons(data = to_ll(mlra), fillColor = ~mlra_pal(mlra_label), fillOpacity = 0.55,
                         color = "#8a8880", weight = 1.2, label = ~mlra_label,
                         highlightOptions = leaflet::highlightOptions(weight = 3, color = "#0b0b0b", bringToFront = FALSE),
                         group = "MLRA") |>
    leaflet::addPolygons(data = to_ll(lrr), fill = FALSE, color = "#0b0b0b", weight = 2, group = "LRR")
  if (!is.null(clipped$forest)) m <- m |>
    leaflet::addRasterImage(clipped$forest, colors = forest_pal, opacity = 0.75, project = TRUE,
                            maxBytes = 30 * 1024^2, group = forest_group) |>
    leaflet::addLegend(position = "bottomright", pal = forest_pal, values = c(0, 1),
                       title = forest_group, opacity = 0.75, group = forest_group)
  if (!is.null(clipped$places) && nrow(clipped$places) > 0) m <- m |>
    leaflet::addPolygons(data = to_ll(clipped$places), fillColor = "#eda100", fillOpacity = 0.35,
                         color = "#7a5200", weight = 1, label = ~sprintf("%s, %s", NAMELSAD, STUSPS), group = places_group)
  m <- m |>
    leaflet::addPolygons(data = cells_ll, fill = FALSE, color = "#4a4843", weight = 1,
                         label = ~sprintf("%s | MLRA %s", id, MLRARSYM), group = grid_group) |>
    leaflet::addCircleMarkers(data = pts_ll[pts_ll$role != role_labels[1], ],
                              radius = 4, weight = 1.5, color = "#ffffff", fillColor = ~site_pal(role), fillOpacity = 1,
                              label = ~sprintf("%s | %s | MLRA %s", role, id, MLRARSYM), group = "Training / validation sites") |>
    leaflet::addLegend(position = "bottomright", pal = site_pal, values = role_labels[-1], title = "Sites")
  if (mlra_legend) m <- m |>
    leaflet::addLegend(position = "bottomleft", pal = mlra_pal, values = names(mlra_cols), title = "MLRA", opacity = 0.7)
  m <- m |>
    leaflet::addLayersControl(
      baseGroups    = c("Esri grey", "Esri satellite"),
      overlayGroups = c("MLRA", "LRR", grid_group, "Training / validation sites", places_group, forest_group),
      options = leaflet::layersControlOptions(collapsed = FALSE)) |>
    leaflet::hideGroup(c(places_group, forest_group)) |>
    leaflet::groupOptions(grid_group, zoomLevels = grid_zoom:18)
  bb <- sf::st_bbox(to_ll(sf::st_as_sfc(clipped$bbox)))
  m <- leaflet::fitBounds(m, bb[["xmin"]], bb[["ymin"]], bb[["xmax"]], bb[["ymax"]])
  # Title panel, top left under the zoom buttons.
  m <- leaflet::addControl(m, position = "topleft", className = "map-title", html = htmltools::doRenderTags(
    htmltools::tags$div(htmltools::tags$h1(title), if (!is.null(subtitle)) htmltools::tags$p(subtitle))))
  # Breathing room between legend swatches; title styling.
  m <- htmlwidgets::prependContent(m, htmltools::tags$style(paste(
    ".info.legend { line-height: 22px; } .info.legend i { margin-top: 2px; margin-bottom: 2px; }",
    ".map-title { background: rgba(252,252,251,0.92); padding: 8px 12px; border-radius: 4px;",
    "  box-shadow: 0 1px 4px rgba(0,0,0,0.25); max-width: 420px; font-family: system-ui, sans-serif; }",
    ".map-title h1 { margin: 0; font-size: 16px; font-weight: 700; color: #0b0b0b; }",
    ".map-title p  { margin: 4px 0 0; font-size: 12px; color: #52514e; }")))
  # Self-contained needs pandoc; without it the JS/CSS libraries go to `libdir`
  # (relative to the page), shared by every map, instead of a sidecar per page.
  htmlwidgets::saveWidget(m, out_html, selfcontained = rmarkdown::pandoc_available(), title = title, libdir = libdir)
  message("Wrote ", out_html)
  invisible(m)
}
