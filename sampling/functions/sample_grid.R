# ==============================================================================
# Systematic sample grid: about n 1 km cells per MLRA on a regular lattice.
#
# This is a port of the draw that produced the May 2026 sample lists in
# data/reference/sampleGrids/ (neymanSampling repo, scripts/Establish_
# stratifiedGrid.R, later renamed 30_Establish_stratifiedGrid.R, with the 1 km
# grid from the 13 March 2026 version of scripts/00a_generate_1kmGrids.R).
# Every step that touches geometry or the random number generator is kept
# exactly as it was, because the replication test in sampling/test/ compares
# the result byte-for-byte with those reference files:
#
#   1. mlra_1km_cells():    whole (unclipped) 1 km cells that intersect the MLRA,
#                           cut straight from the 100 km cells that intersect it.
#   2. draw_mlra_sample_grid(): union those cells, set.seed(seed), then
#                           sf::st_sample(type = "regular") asking for n points.
#                           sf scales n by bbox area / union area, so the count
#                           that lands inside the MLRA is only approximately n.
#   3. ids_from_points():   name the 1 km cell under each point by descending
#                           the 100 km > 50 km > 10 km > 2 km > 1 km hierarchy
#                           with the same st_make_grid() construction that the
#                           naip stage uses to rebuild a cell from its id.
#
# The three grid builders at the top are verbatim copies of
# neymanSampling/src/sampleGridsFunctions.R (buildGrids, buildSubGrids,
# select100km); only the names changed.
# ==============================================================================

# --- Grid builders (verbatim from neymanSampling) -----------------------------

#' Regular grid of `cell_size` squares over one parent cell, ids "<parent>-<hex>".
build_grids <- function(extent_object, cell_size) {
  ea <- sf::st_transform(extent_object, 5070)
  grid <- sf::st_make_grid(x = ea, cellsize = cell_size)
  if ("id" %in% names(ea)) {
    ids <- paste0(ea$id[1], "-", as.hexmode(1:length(grid)))
  } else {
    ids <- as.hexmode(1:length(grid))
  }
  sf::st_sf(id = ids, geomentry = grid)   # sic: column name as in the original
}

#' Sub-grids of every parent in `grids`, keeping only those that intersect `aoi`.
build_sub_grids <- function(grids, cell_size, aoi) {
  sub <- grids |>
    dplyr::group_split(id) |>
    purrr::map(.f = build_grids, cell_size = cell_size) |>
    dplyr::bind_rows()
  sub[aoi, ]
}

#' The 100 km cells that intersect a feature.
select_100km <- function(original_100km, aoi_feature) {
  sf::st_filter(original_100km, aoi_feature)
}

# --- Step 1: 1 km cells of one MLRA ------------------------------------------

#' Whole 1 km cells intersecting one MLRA polygon (ids "<100km>-<hex 1..2710>").
#'
#' @param mlra_poly   one-row sf, the MLRA polygon, in EPSG:5070.
#' @param g100        the 100 km grid (sf, EPSG:5070, integer `id`).
#' @param corrections optional data frame (MLRA_ID, id, in_march_build): the
#'   tracked list of boundary-marginal cells and whether the March 2026 grid,
#'   which the reference draws used, contained them. The intersects test is
#'   not stable for cells the boundary crosses by less than a metre or so
#'   (PROJ and GEOS versions move it by that much), and the draw depends on
#'   the exact cell count, so those cells are added or dropped to match.
mlra_1km_cells <- function(mlra_poly, g100, corrections = NULL) {
  parents <- select_100km(g100, mlra_poly)
  if (nrow(parents) == 0) return(NULL)
  cells <- build_sub_grids(grids = parents, cell_size = 1000, aoi = mlra_poly)
  if (is.null(corrections)) return(cells)
  corr <- corrections[corrections$MLRA_ID == mlra_poly$MLRA_ID[1], ]
  drop <- corr$id[!corr$in_march_build]
  add  <- corr$id[corr$in_march_build & !corr$id %in% cells$id]
  dropped <- drop[drop %in% cells$id]
  cells <- cells[!cells$id %in% drop, ]
  if (length(add) > 0) {
    extra <- lapply(unique(sub("-.*$", "", add)), function(p) {
      g <- build_grids(g100[g100$id == as.integer(p), ], 1000)
      g[g$id %in% add, ]
    })
    cells <- rbind(cells, do.call(rbind, extra))
  }
  attr(cells, "frame_added")   <- add
  attr(cells, "frame_dropped") <- dropped
  cells
}

# --- Step 3: hierarchical id under each point --------------------------------

#' 1 km hierarchical id(s) of the cell under each point.
#'
#' Returns a data frame with one row per (point, cell) pair in point order:
#' `pt` (index into `pts`) and `id`. A point exactly on a shared edge yields one
#' row per touching cell, which is what the original per-point subsetting did.
#' Points outside the 100 km grid yield no row.
ids_from_points <- function(pts, g100) {
  pt_sf <- sf::st_sf(pt = seq_along(pts), geometry = sf::st_geometry(pts))
  hit   <- sf::st_intersects(pt_sf, g100)
  cur   <- sf::st_sf(pt  = rep(pt_sf$pt, lengths(hit)),
                     id  = g100$id[unlist(hit)],
                     geometry = sf::st_geometry(g100)[unlist(hit)])
  for (size in c(50000, 10000, 2000, 1000)) {
    if (nrow(cur) == 0) break
    groups <- split(seq_len(nrow(cur)), cur$id)
    pieces <- lapply(groups, function(rows) {
      sub  <- build_grids(cur[rows[1], ], size)
      h    <- sf::st_intersects(pt_sf[cur$pt[rows], ], sub)
      m    <- data.frame(pt = rep(cur$pt[rows], lengths(h)), sub_row = unlist(h))
      sf::st_sf(pt = m$pt, id = sub$id[m$sub_row], sub_row = m$sub_row,
                geometry = sf::st_geometry(sub)[m$sub_row])
    })
    cur <- do.call(rbind, unname(pieces))
    cur <- cur[order(cur$pt, cur$sub_row, method = "radix"), ]
    cur$sub_row <- NULL
  }
  data.frame(pt = cur$pt, id = as.character(cur$id), stringsAsFactors = FALSE)
}

#' Read the tracked frame-corrections table (see mlra_1km_cells()).
read_frame_corrections <- function(path) {
  readr::read_csv(path, show_col_types = FALSE,
                  col_types = readr::cols(id = "c", LLR_ID = "c", MLRA_ID = "d",
                                          in_march_build = "l", in_today_build = "l", .default = "d"))
}

# --- Step 2: the draw ---------------------------------------------------------

#' Draw the systematic sample grid for one MLRA.
#'
#' @param mlra_poly one-row sf (EPSG:5070) with `MLRA_ID`.
#' @param g100      100 km grid (sf, EPSG:5070).
#' @param n         points requested from st_sample (about n cells result).
#' @param seed      set immediately before st_sample, as in the original.
#' @param lrr_id    written into the LLR_ID column.
#' @param corrections see mlra_1km_cells().
#' @return list(sample = data.frame(id, MLRA_ID, LLR_ID), diag = one-row data
#'   frame of what the draw depended on: cell count, bbox, areas, the lattice
#'   size sf actually used and how far the size scaling sat from a rounding
#'   boundary, expressed as the range of cell counts that give the same draw).
draw_mlra_sample_grid <- function(mlra_poly, g100, n, seed, lrr_id, corrections = NULL) {
  mlra_id <- mlra_poly$MLRA_ID[1]
  cells <- mlra_1km_cells(mlra_poly, g100, corrections)
  empty <- data.frame(id = character(0), MLRA_ID = mlra_id[0], LLR_ID = character(0))
  if (is.null(cells) || nrow(cells) == 0) {
    message("   No 1 km cells for MLRA ", mlra_id, "; skipping.")
    return(list(sample = empty, diag = NULL))
  }
  u <- sf::st_union(sf::st_geometry(cells))

  set.seed(seed)
  pts <- sf::st_sample(x = u, size = n, type = "regular")

  found  <- ids_from_points(pts, g100)
  sample <- data.frame(id = found$id, MLRA_ID = mlra_id, LLR_ID = lrr_id,
                       stringsAsFactors = FALSE)
  sample <- unique(sample)

  # Diagnostics: sf draws round(n * a0 / a1) lattice points over the bbox
  # (a0 = bbox area, a1 = union area). a1 is the cell count times 1 km^2, so
  # the draw is unchanged for any cell count in [cells_lo, cells_hi].
  bb <- sf::st_bbox(u)
  a0 <- as.numeric(sf::st_area(sf::st_as_sfc(bb)))
  a1 <- as.numeric(sf::st_area(u))
  r  <- n * a0 / a1
  k  <- round(r)
  diag <- data.frame(
    MLRA_ID = mlra_id, n_requested = n, n_cells = nrow(cells),
    cells_added = length(attr(cells, "frame_added")), cells_dropped = length(attr(cells, "frame_dropped")),
    xmin = bb[["xmin"]], ymin = bb[["ymin"]], xmax = bb[["xmax"]], ymax = bb[["ymax"]],
    bbox_area_km2 = a0 / 1e6, union_area_km2 = a1 / 1e6,
    lattice_size = k, size_scaling = r,
    cells_lo = ceiling(n * a0 / ((k + 0.5) * 1e6)),
    cells_hi = floor(n * a0 / ((k - 0.5) * 1e6)),
    n_points_inside = length(pts), n_ids = nrow(sample))
  list(sample = sample, diag = diag)
}

#' Draw the sample grid for every MLRA of one LRR, in MLRA file order.
#'
#' @param lrr_id  LRR symbol, e.g. "F".
#' @param mlra    the full MLRA layer (sf) with LRRSYM and MLRA_ID; any CRS.
#' @param g100    100 km grid (sf); any CRS.
#' @param n, seed as for draw_mlra_sample_grid (seed is reset for every MLRA).
#' @param corrections see mlra_1km_cells(); NULL uses today's intersects test only.
#' @return list(sample = data.frame(id, MLRA_ID, LLR_ID), diag = data.frame).
draw_lrr_sample_grid <- function(lrr_id, mlra, g100, n = 1400, seed = 1234, corrections = NULL) {
  crs  <- sf::st_crs(5070)
  if (sf::st_crs(mlra) != crs) mlra <- sf::st_transform(mlra, crs)
  if (sf::st_crs(g100) != crs) g100 <- sf::st_transform(g100, crs)
  if (!"id" %in% names(g100)) g100$id <- seq_len(nrow(g100))
  targets <- mlra$MLRA_ID[mlra$LRRSYM == lrr_id]
  if (length(targets) == 0) stop("No MLRAs found for LRR ", lrr_id)
  message(sprintf("LRR %s: %d MLRAs, %d points requested per MLRA, seed %d",
                  lrr_id, length(targets), n, seed))
  out <- lapply(targets, function(m_id) {
    t0 <- Sys.time()
    res <- draw_mlra_sample_grid(mlra[mlra$MLRA_ID == m_id, ], g100, n, seed, lrr_id, corrections)
    d <- res$diag
    message(sprintf("   MLRA %s: %d cells (%d added, %d dropped by the frame table), %d ids drawn (%.1f s)", m_id,
                    if (is.null(d)) 0L else d$n_cells, if (is.null(d)) 0L else d$cells_added,
                    if (is.null(d)) 0L else d$cells_dropped,
                    nrow(res$sample), as.numeric(Sys.time() - t0, units = "secs")))
    res
  })
  list(sample = dplyr::bind_rows(lapply(out, `[[`, "sample")),
       diag   = dplyr::bind_rows(lapply(out, `[[`, "diag")))
}
