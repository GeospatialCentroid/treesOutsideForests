# Areas of polygons against the masks/ products ---------------------------------
# Every function here works in the analysis CRS (EPSG:5070, metres) and returns
# areas in m². "Eligible" is the part of a polygon that is neither NLCD forest
# nor a Census place; the two masks overlap, so the union is
#   masked = forest + urban - (forest within urban).
# Forest comes from the 30 m binary raster through exactextractr, so partial
# pixels along a polygon edge count by their covered area. Urban comes from the
# dissolved places polygon by exact vector intersection. Water is not masked and
# so stays eligible.

#' Load the mask layers for one LRR and year.
#'
#' @return list(year, forest = SpatRaster (0/1, NA outside the study area),
#'              urban = sfc of one (multi)polygon, or NULL when that year has no
#'              urban product).
mask_layers <- function(masks_dir, llr_id, year, crs = "EPSG:5070") {
  forest_path <- file.path(masks_dir, sprintf("llr_%s_forest_%d.tif", llr_id, as.integer(year)))
  urban_path  <- file.path(masks_dir, sprintf("llr_%s_urban_%d.gpkg", llr_id, as.integer(year)))
  if (!file.exists(forest_path)) stop("No forest mask for ", llr_id, " ", year, ": ", forest_path)
  forest <- terra::rast(forest_path)
  if (!file.exists(urban_path)) {
    warning("No urban mask for ", llr_id, " ", year, "; urban area taken as 0.")
    urban <- NULL
  } else {
    urban <- sf::st_read(urban_path, quiet = TRUE) |> sf::st_transform(crs) |> sf::st_geometry() |> sf::st_union()
  }
  list(year = as.integer(year), forest = forest, urban = urban)
}

#' Area covered by forest pixels inside each polygon, in m².
forest_area_m2 <- function(polys, forest) {
  if (nrow(polys) == 0) return(numeric(0))
  v <- exactextractr::exact_extract(forest, polys, fun = "sum", coverage_area = TRUE, progress = FALSE)
  v[is.na(v)] <- 0
  v
}

#' Footprint, forest, urban, overlap, masked and eligible area of each polygon.
#'
#' @param polys  sf with polygon geometry in the mask CRS. Attribute columns are
#'               carried through unchanged.
#' @param layers output of mask_layers().
#' @return tibble: the attributes of `polys`, then mask_year, footprint_m2,
#'         forest_m2, urban_m2, overlap_m2, masked_m2, eligible_m2.
polygon_mask_areas <- function(polys, layers) {
  stopifnot(inherits(polys, "sf"))
  n <- nrow(polys)
  footprint <- as.numeric(sf::st_area(polys))
  forest    <- forest_area_m2(polys, layers$forest)
  urban     <- numeric(n)
  overlap   <- numeric(n)
  if (!is.null(layers$urban) && n > 0) {
    hit <- which(lengths(sf::st_intersects(polys, layers$urban)) > 0)
    if (length(hit) > 0) {
      pieces <- suppressWarnings(sf::st_intersection(sf::st_geometry(polys)[hit], layers$urban))
      pieces <- polygons_only(pieces)
      keep   <- !sf::st_is_empty(pieces)
      hit    <- hit[keep]; pieces <- pieces[keep]
      urban[hit]   <- as.numeric(sf::st_area(pieces))
      overlap[hit] <- forest_area_m2(sf::st_sf(geometry = pieces), layers$forest)
    }
  }
  masked <- forest + urban - overlap
  tibble::as_tibble(dplyr::bind_cols(
    sf::st_drop_geometry(polys),
    tibble::tibble(mask_year = layers$year, footprint_m2 = footprint, forest_m2 = forest,
                   urban_m2 = urban, overlap_m2 = overlap, masked_m2 = masked,
                   eligible_m2 = pmax(footprint - masked, 0))
  ))
}

# st_intersection can return points and lines where boundaries touch; keep the
# polygonal part of each geometry (an empty polygon where there is none).
polygons_only <- function(geom) {
  is_coll <- sf::st_is(geom, "GEOMETRYCOLLECTION")
  if (any(is_coll)) {
    geom[is_coll] <- lapply(geom[is_coll], function(g) {
      parts <- Filter(function(p) inherits(p, c("POLYGON", "MULTIPOLYGON")), g)
      if (length(parts) == 0) sf::st_polygon() else sf::st_union(sf::st_sfc(parts))[[1]]
    }) |> sf::st_sfc(crs = sf::st_crs(geom))
  }
  not_poly <- !sf::st_is(geom, c("POLYGON", "MULTIPOLYGON"))
  if (any(not_poly)) geom[not_poly] <- sf::st_sfc(sf::st_polygon(), crs = sf::st_crs(geom))
  geom
}

#' The sampled 1 km cells, each clipped to the MLRA that drew it.
#'
#' A cell drawn by two MLRAs appears twice, once per MLRA, each row holding only
#' the part inside that MLRA. A cell whose overlap with its MLRA is empty gets
#' an empty geometry so it still counts as a sampled cell (footprint 0).
#'
#' @param sample_tbl data frame with id and MLRA_ID (duplicates on both are dropped).
#' @param g100       the 100 km reference grid (sf).
#' @param mlra       MLRA polygons (sf) with MLRA_ID, already in `crs`.
#' @return sf keyed on (id, MLRA_ID) with cell_m2 (the uncut cell) and geometry.
cell_geometry <- function(sample_tbl, g100, mlra, crs = "EPSG:5070") {
  key   <- dplyr::distinct(sample_tbl, id, MLRA_ID)
  cells <- cells_from_ids(unique(key$id), g100) |> sf::st_transform(crs)
  cells$cell_m2 <- as.numeric(sf::st_area(cells))
  cells <- dplyr::inner_join(cells, key, by = "id")
  out <- lapply(split(cells, cells$MLRA_ID), function(cc) {
    poly <- sf::st_geometry(mlra)[match(cc$MLRA_ID[1], mlra$MLRA_ID)]
    if (length(poly) == 0 || sf::st_is_empty(poly)) stop("MLRA ", cc$MLRA_ID[1], " not in the MLRA layer.")
    g <- suppressWarnings(sf::st_intersection(sf::st_geometry(cc), poly))
    # st_intersection drops rows with an empty result; rebuild a full-length sfc.
    full <- rep(sf::st_sfc(sf::st_polygon(), crs = crs), nrow(cc))
    idx  <- attr(g, "idx")
    if (is.null(idx)) idx <- cbind(seq_len(nrow(cc)), 1L)  # older sf: no drops happened
    full[idx[, 1]] <- polygons_only(g)
    sf::st_set_geometry(cc, full)
  })
  out <- do.call(rbind, out)
  rownames(out) <- NULL
  out[, c("id", "MLRA_ID", "cell_m2", attr(out, "sf_column"))]
}

#' Mask areas of every sampled cell (already clipped by cell_geometry()).
cell_areas <- function(cells, layers) polygon_mask_areas(cells, layers)

#' Mask areas of every MLRA polygon: the stratum totals A_h and E_h.
stratum_areas <- function(mlra, layers) {
  polygon_mask_areas(mlra[, c("MLRA_ID", "MLRARSYM", "MLRA_NAME")], layers) |>
    dplyr::rename(total_m2 = footprint_m2)
}
