# Model output per cell-year ------------------------------------------------------
# The model stage writes, per AOI and NAIP year, a raster over the 1 km cell with
#   1 = trees outside forest, 0 = not, NA = masked out (Census place / NLCD forest).
# The NoData value must be declared in the file; an undeclared NoData makes every
# pixel eligible.

#' Which NAIP year was actually captured for each sampled cell and target year.
#'
#' @param export_dir the naip stage export folder (holds the status.json files).
#' @return tibble(id, target_year, actual_year) for successful AOI-years only.
naip_year_table <- function(export_dir) {
  st <- compileStatus(export_dir)
  if (is.null(st)) stop("No naip status.json files under ", export_dir)
  st |>
    dplyr::filter(status == "Success") |>
    dplyr::transmute(id = aoi_id, target_year = as.integer(target_year),
                     actual_year = as.integer(actual_year)) |>
    dplyr::distinct(id, target_year, .keep_all = TRUE) |>
    tibble::as_tibble()
}

#' Path of the model raster for one cell and (actual) NAIP year.
#'
#' `pattern` uses {id} and {year}, e.g. "tof_{id}_{year}.tif".
model_path <- function(id, year, model_dir, pattern) {
  year <- rep_len(as.character(year), length(id))
  p <- vapply(seq_along(id), function(i) {
    q <- gsub("{id}", id[i], pattern, fixed = TRUE)
    gsub("{year}", year[i], q, fixed = TRUE)
  }, character(1))
  file.path(model_dir, p)
}

#' Trees-outside-forest area and model-eligible area inside one polygon, in m².
#'
#' @return c(tof_m2, model_eligible_m2): covered area of pixels equal to 1, and
#'         covered area of all non-NA pixels.
read_model_cell <- function(path, poly) {
  r <- terra::rast(path)
  if (sf::st_crs(poly) != sf::st_crs(r)) poly <- sf::st_transform(poly, sf::st_crs(r))
  v <- exactextractr::exact_extract(r, poly, fun = c("sum", "count"), coverage_area = TRUE, progress = FALSE)
  c(tof_m2 = as.numeric(v$sum), model_eligible_m2 = as.numeric(v$count))
}

#' Add tof_m2 and model_eligible_m2 to a cell table.
#'
#' @param cells   sf keyed on (id, MLRA_ID) with actual_year and the clipped cell geometry.
#' @param eligible_from "mask": the estimators use eligible_m2 from the mask
#'        layers (default); "model": they use the non-NA area of the model
#'        raster instead. Both columns are kept either way.
#' @return tibble without geometry; tof_m2 is NA where no model raster exists.
join_model_output <- function(cells, model_dir, pattern, eligible_from = c("mask", "model")) {
  eligible_from <- match.arg(eligible_from)
  paths <- model_path(cells$id, cells$actual_year, model_dir, pattern)
  have  <- file.exists(paths)
  vals  <- matrix(NA_real_, nrow(cells), 2, dimnames = list(NULL, c("tof_m2", "model_eligible_m2")))
  for (i in which(have)) {
    if (sf::st_is_empty(sf::st_geometry(cells)[i])) { vals[i, ] <- c(0, 0); next }
    vals[i, ] <- read_model_cell(paths[i], cells[i, ])
  }
  out <- dplyr::bind_cols(sf::st_drop_geometry(cells), tibble::as_tibble(vals))
  out$model_path <- ifelse(have, paths, NA_character_)
  if (eligible_from == "model") {
    out$mask_eligible_m2 <- out$eligible_m2
    out$eligible_m2 <- out$model_eligible_m2
  }
  if (any(!have)) message(sprintf("%d of %d cell-years have no model raster (tof_m2 = NA).", sum(!have), nrow(cells)))
  tibble::as_tibble(out)
}
