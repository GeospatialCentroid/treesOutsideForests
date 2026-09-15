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

# Model output as a table of pixel counts ---------------------------------------
# The alternative to per-cell rasters: one CSV with, per cell and target year,
# the number of pixels the model called trees outside forest and the number of
# pixels it was allowed to call (not masked). Every grid is predicted at a fixed
# pixel size (1 m), so counts are areas once multiplied by `pixel_area_m2`.
# This is the layout the project partner's grid-level output is expected in.
#
#   column        required  meaning
#   id            yes       1 km cell id (as in the sample list)
#   target_year   yes       naip target year
#   actual_year   no        NAIP year actually used; defaults to target_year
#   tof_px        yes       pixels predicted as trees outside forest
#   eligible_px   yes       pixels not masked out (the model's eligible area)
#   footprint_px  no        all pixels of the cell; defaults to the cell area
# Other columns are carried through. MLRA_ID, if present, is ignored: the sample
# list decides which MLRA a cell belongs to.

#' Read and validate a pixel-count table, converting counts to m².
#'
#' @return tibble with id, target_year, actual_year, tof_m2, eligible_m2 and,
#'         when footprint_px is present, footprint_m2; the *_px columns are kept.
read_model_table <- function(path, pixel_area_m2 = 1) {
  tab <- readr::read_csv(path, show_col_types = FALSE,
                         col_types = readr::cols(id = readr::col_character(), .default = readr::col_guess()))
  needed <- c("id", "target_year", "tof_px", "eligible_px")
  miss <- setdiff(needed, names(tab))
  if (length(miss)) stop("Model table ", path, " is missing: ", paste(miss, collapse = ", "))
  if (!"actual_year" %in% names(tab)) tab$actual_year <- tab$target_year
  tab <- dplyr::mutate(tab, target_year = as.integer(target_year), actual_year = as.integer(actual_year))
  dup <- tab |> dplyr::count(id, target_year) |> dplyr::filter(n > 1)
  if (nrow(dup)) stop(nrow(dup), " duplicate (id, target_year) rows in ", path)
  bad <- is.na(tab$tof_px) | is.na(tab$eligible_px)
  if (any(bad)) stop(sum(bad), " rows with NA tof_px or eligible_px in ", path, "; leave the row out instead.")
  if (any(tab$tof_px > tab$eligible_px)) stop("tof_px exceeds eligible_px in ", sum(tab$tof_px > tab$eligible_px), " rows.")
  if ("footprint_px" %in% names(tab) && any(tab$eligible_px > tab$footprint_px, na.rm = TRUE)) {
    stop("eligible_px exceeds footprint_px in ", sum(tab$eligible_px > tab$footprint_px, na.rm = TRUE), " rows.")
  }
  tab$tof_m2      <- tab$tof_px * pixel_area_m2
  tab$eligible_m2 <- tab$eligible_px * pixel_area_m2
  if ("footprint_px" %in% names(tab)) tab$footprint_m2 <- tab$footprint_px * pixel_area_m2
  tibble::as_tibble(tab)
}

#' Cell-year table from the sampled cells and a pixel-count table.
#'
#' Every sampled cell gets one row per target year in `tab`; a cell-year the
#' table does not cover gets tof_m2 = NA (dropped by the estimators and counted
#' in n_missing). Rows of `tab` for ids outside the sample list are dropped
#' with a message. Where the table has no footprint, the cell area is used.
#'
#' @param cells output of cell_geometry() (sf or data frame with id, MLRA_ID, cell_m2).
#' @param tab   output of read_model_table().
join_model_table <- function(cells, tab) {
  cells <- tibble::as_tibble(sf::st_drop_geometry(cells))[, c("id", "MLRA_ID", "cell_m2")]
  extra <- setdiff(unique(tab$id), cells$id)
  if (length(extra)) {
    message(sprintf("%d ids in the model table are not sampled cells; dropped.", length(extra)))
    tab <- dplyr::filter(tab, !id %in% extra)
  }
  clash <- setdiff(intersect(names(tab), names(cells)), "id")   # MLRA_ID, cell_m2: the sample list wins
  if (length(clash)) tab <- tab[, setdiff(names(tab), clash)]
  frame <- tidyr::expand_grid(cells, target_year = sort(unique(tab$target_year)))
  out <- dplyr::left_join(frame, tab, by = c("id", "target_year"))
  if (!"footprint_m2" %in% names(out)) out$footprint_m2 <- out$cell_m2
  out$footprint_m2 <- dplyr::coalesce(out$footprint_m2, out$cell_m2)
  n_na <- sum(is.na(out$tof_m2))
  if (n_na) message(sprintf("%d of %d cell-years are not in the model table (tof_m2 = NA).", n_na, nrow(out)))
  out
}
