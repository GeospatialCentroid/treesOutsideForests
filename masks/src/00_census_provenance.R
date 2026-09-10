# ==============================================================================
# Census Places Provenance Helpers
# ==============================================================================
# Shared by src/01_pipeline_worker.R, which writes the Census cache, and
# src/02_llr_masks.R, which consumes it, so that both answer "is this really
# that year's data?" the same way. Sourced by both; safe to source twice.
#
# Every Census layer the pipeline writes carries a census_source_year column
# recording the year the geometries actually came from. A file whose stamp does
# not match its filename is a substitution from another year, and under the
# project's policy (allow_census_year_substitution = FALSE) is not a usable
# source for that year's urban products.

#' Source Year Stamped on a Census Layer
#'
#' Reads the census_source_year column off the first layer of a GeoPackage
#' without loading its geometry.
#'
#' @param path Path to a GeoPackage written by the pipeline.
#' @return Integer year, or NA when the file is missing, empty, or unstamped.
census_source_year_of <- function(path) {
  if (!file.exists(path)) return(NA_integer_)

  layers <- try(sf::st_layers(path)$name, silent = TRUE)
  if (inherits(layers, "try-error") || length(layers) == 0) return(NA_integer_)

  # Fails when the column is absent, which is exactly the unstamped case.
  res <- try(suppressWarnings(sf::st_read(
    path, quiet = TRUE,
    query = sprintf('SELECT census_source_year FROM "%s" LIMIT 1', layers[1])
  )), silent = TRUE)
  if (inherits(res, "try-error") || nrow(res) == 0) return(NA_integer_)

  as.integer(res$census_source_year[1])
}

#' Is a Census Layer Genuinely the Year It Is Named For?
#'
#' An unstamped file answers FALSE: its provenance is unknown, and unknown is
#' not the same as verified. Run src/99_audit_census_cache.R on those.
#'
#' @param path Path to a Census Places GeoPackage.
#' @param year Year the file claims to represent.
#' @return TRUE only when the file exists and its stamp matches `year`.
census_is_independent <- function(path, year) {
  src <- census_source_year_of(path)
  !is.na(src) && identical(as.integer(src), as.integer(year))
}

#' Which of a Year's Two Published Place Products a Layer Came From
#'
#' The Census publishes places twice: a generalised cartographic boundary file
#' (cb, 2013 onwards) and the full-detail TIGER/Line file. Both are that year's
#' own data, so either satisfies the no-substitution policy, but their
#' geometries are generalised differently and an area is not exactly comparable
#' across the two.
#'
#' Layers downloaded before this column existed are identified from their
#' schema: AFFGEOID is unique to the cartographic files, MTFCC and NAMELSAD to
#' TIGER/Line.
#'
#' @param x A places layer (sf or data.frame).
#' @return "cb", "tiger", or NA when neither can be established.
census_boundary_type_of <- function(x) {
  nms <- names(x)
  if ("census_boundary_type" %in% nms && nrow(x) > 0) {
    return(as.character(x$census_boundary_type[1]))
  }
  if ("AFFGEOID" %in% nms) return("cb")
  if (any(c("MTFCC", "NAMELSAD") %in% nms)) return("tiger")
  NA_character_
}
