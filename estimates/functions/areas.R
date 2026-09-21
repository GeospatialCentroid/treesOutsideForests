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

#' The sampled 1 km cells, one row per cell.
#'
#' A cell drawn by two MLRAs (15 in F) is counted once, in the first MLRA that
#' drew it in sample-list order, the same rule sampling/00_prepare_sites.R uses.
#' The model is the same raster whichever MLRA drew the cell, so the cell is not
#' split or clipped: its footprint is the whole 1 km square even where it hangs
#' over the MLRA boundary (the sampling frame is a blocky outline of the MLRA).
#'
#' @param sample_tbl data frame with id and MLRA_ID.
#' @param g100       the 100 km reference grid (sf).
#' @return sf keyed on id with MLRA_ID, cell_m2 and the cell geometry.
cell_geometry <- function(sample_tbl, g100, crs = "EPSG:5070") {
  key   <- dplyr::distinct(sample_tbl, id, .keep_all = TRUE)[, c("id", "MLRA_ID")]
  cells <- cells_from_ids(key$id, g100) |> sf::st_transform(crs)
  cells$cell_m2 <- as.numeric(sf::st_area(cells))
  cells <- dplyr::inner_join(cells, key, by = "id")
  cells[, c("id", "MLRA_ID", "cell_m2", attr(cells, "sf_column"))]
}

#' Mask areas of every sampled cell (from cell_geometry()).
cell_areas <- function(cells, layers) polygon_mask_areas(cells, layers)

#' Mask areas of every MLRA polygon: the stratum totals A_h and E_h.
stratum_areas <- function(mlra, layers) {
  polygon_mask_areas(mlra[, c("MLRA_ID", "MLRARSYM", "MLRA_NAME")], layers) |>
    dplyr::rename(total_m2 = footprint_m2)
}

# Against the combined mask (masks/ product llr_<LRR>_mask_<year>.gpkg) -----------
# The masks stage writes the union of forest and urban as one dissolved
# multipolygon per year. Measuring against it directly gives the masked area
# without the forest + urban - overlap bookkeeping above, and the number is
# exactly the area of the delivered mask inside the polygon.

#' Load one year's combined mask, split into its patches for fast intersection.
#'
#' @return sf of POLYGON parts with the mask attributes repeated; attribute
#'         `year` is the mask year.
combined_mask <- function(masks_dir, llr_id, year, crs = "EPSG:5070") {
  path <- file.path(masks_dir, sprintf("llr_%s_mask_%d.gpkg", llr_id, as.integer(year)))
  if (!file.exists(path)) stop("No combined mask for ", llr_id, " ", year, ": ", path, " (run masks/src/02_llr_masks.R)")
  m <- sf::st_read(path, quiet = TRUE) |> sf::st_transform(crs)
  suppressWarnings(sf::st_cast(m, "POLYGON"))
}

#' Area of the combined mask inside each polygon, in m².
#'
#' Exact vector intersection against the mask patches; sf builds a spatial
#' index over the patches, so this is a few seconds per thousand polygons.
mask_area_m2 <- function(polys, mask_parts) {
  n <- nrow(polys)
  if (n == 0) return(numeric(0))
  x <- sf::st_sf(.row = seq_len(n), geometry = sf::st_geometry(polys))
  pieces <- suppressWarnings(sf::st_intersection(x, sf::st_geometry(mask_parts)))
  if (nrow(pieces) == 0) return(numeric(n))
  sf::st_geometry(pieces) <- polygons_only(sf::st_geometry(pieces))
  a <- as.numeric(sf::st_area(pieces))
  out <- numeric(n)
  s <- tapply(a, pieces$.row, sum)
  out[as.integer(names(s))] <- as.numeric(s)
  out
}

#' The sampled cells clipped to the MLRA that drew them.
#'
#' One feature per (id, MLRA_ID) pair in the sample list. A cell drawn by two
#' MLRAs becomes two features, one per MLRA, each holding the part of the cell
#' inside that MLRA; the MLRA polygons do not overlap, so the pieces do not
#' either and every square metre of the sample is counted once. A pair whose
#' intersection is empty is dropped with a message.
#'
#' @param sample_tbl data frame with id and MLRA_ID.
#' @param mlra       sf of the LRR's MLRA polygons with MLRA_ID, in `crs`.
#' @param g100       the 100 km reference grid (sf).
#' @return sf keyed on (id, MLRA_ID): cell_m2 (the whole 1 km cell), aoi_m2
#'         (the clipped piece) and the clipped geometry.
clip_cells_to_mlra <- function(sample_tbl, mlra, g100, crs = "EPSG:5070") {
  key   <- dplyr::distinct(sample_tbl, id, MLRA_ID)
  cells <- cells_from_ids(unique(key$id), g100) |> sf::st_transform(crs)
  geom  <- sf::st_geometry(cells)[match(key$id, cells$id)]
  out <- purrr::map_dfr(split(seq_len(nrow(key)), key$MLRA_ID), function(idx) {
    h <- key$MLRA_ID[idx[1]]
    poly <- sf::st_geometry(mlra)[mlra$MLRA_ID == h]
    if (length(poly) != 1) stop("MLRA ", h, " is not in the MLRA layer exactly once.")
    clipped <- suppressWarnings(sf::st_intersection(geom[idx], poly))
    # st_intersection drops empty results; st_intersects says which rows survive
    keep <- which(lengths(sf::st_intersects(geom[idx], poly)) > 0)
    if (length(clipped) != length(keep)) stop("Clipped pieces do not line up with the intersecting cells for MLRA ", h)
    clipped <- polygons_only(clipped)
    sf::st_sf(id = key$id[idx][keep], MLRA_ID = h,
              cell_m2 = as.numeric(sf::st_area(geom[idx][keep])),
              geometry = clipped)
  })
  out <- out[!sf::st_is_empty(out), ]
  out$aoi_m2 <- as.numeric(sf::st_area(out))
  out <- out[out$aoi_m2 > 0, ]
  dropped <- nrow(key) - nrow(out)
  if (dropped > 0) message(sprintf("%d of %d (id, MLRA) pairs have no area inside their MLRA; dropped.", dropped, nrow(key)))
  out[, c("id", "MLRA_ID", "cell_m2", "aoi_m2", attr(out, "sf_column"))]
}
