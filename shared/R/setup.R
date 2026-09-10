# ==============================================================================
# Shared setup for every stage of treesOutsideForests.
#
# Source this first in any script:
#   source(here::here("shared/R/setup.R"))
#
# here::here() finds the repository root from the working directory, which the
# root treesOutsideForests.Rproj sets. There are deliberately no other .Rproj
# files in the repo, so here() cannot stop early inside a stage folder.
# ==============================================================================
pacman::p_load(here, yaml, sf, dplyr)

#' Absolute path under the repository root.
tof_root <- function(...) here::here(...)

#' The root config.yml as a nested list.
tof_config <- function() yaml::read_yaml(tof_root("config.yml"))

#' Turn a repo-relative path from config.yml into an absolute one.
tof_path <- function(rel) tof_root(rel)

#' Read one Land Resource Region polygon in the analysis CRS.
#'
#' @param id   LRR symbol, e.g. "F".
#' @param crs  CRS to transform to; defaults to the config `crs`.
#' @param path LRR geopackage; defaults to the config reference layer.
read_lrr <- function(id,
                     crs  = tof_config()$crs,
                     path = tof_path(tof_config()$reference$lrr_gpkg)) {
  lrr <- sf::st_read(path, quiet = TRUE) |>
    dplyr::filter(LRRSYM == id) |>
    sf::st_transform(crs)
  if (nrow(lrr) == 0) stop("No LRR polygon found for symbol ", id)
  lrr
}
