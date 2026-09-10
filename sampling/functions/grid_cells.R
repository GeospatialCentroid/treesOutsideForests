# Geometry from a grid id --------------------------------------------------------
# Ids are "<100km>-<50km>-<10km>-<2km>-<1km>", each level a 1-based hex index
# into the row-major st_make_grid() of its parent cell (x fastest, from the
# south-west corner). This reproduces naip/function/generateAOI.R::getAOI()
# without building four grid levels per id (verified equal on random ids).
cells_from_ids <- function(ids, g100) {
  parts  <- do.call(rbind, strsplit(ids, "-"))
  origin <- t(vapply(sf::st_geometry(g100), function(g) sf::st_bbox(g)[1:2], numeric(2)))
  idx <- match(parts[, 1], g100$id)
  x <- origin[idx, 1]; y <- origin[idx, 2]; w <- 1e5
  sizes <- c(50000, 10000, 2000, 1000)
  for (i in seq_along(sizes)) {
    k <- strtoi(parts[, i + 1], 16L) - 1
    n <- ceiling(w / sizes[i])
    x <- x + (k %% n) * sizes[i]
    y <- y + (k %/% n) * sizes[i]
    w <- sizes[i]
  }
  geom <- sf::st_sfc(lapply(seq_along(ids), function(j) sf::st_polygon(list(matrix(c(
    x[j], y[j], x[j] + w, y[j], x[j] + w, y[j] + w, x[j], y[j] + w, x[j], y[j]),
    ncol = 2, byrow = TRUE)))), crs = sf::st_crs(g100))
  sf::st_sf(id = ids, geometry = geom)
}

# readr (and base R) parse the LRR symbol "F" as logical FALSE unless told not to.
read_sites_csv <- function(path) {
  readr::read_csv(path, show_col_types = FALSE,
                  col_types = readr::cols(LLR_ID = readr::col_character(), .default = readr::col_guess()))
}
