# ==============================================================================
# NAIP Grid Reference
# ==============================================================================
# Standalone step. Queries the Planetary Computer STAC catalogue once per sample
# site and records, per requested year, the NAIP imagery that naipScrape would
# have used - most importantly the UTM zone of the tile whose CRS became the
# output grid.
#
# WHY THIS EXISTS
# ---------------
# naipScrape's mergeAndExportNAIP() builds its output grid from the CRS of the
# FIRST downloaded tile:
#
#     master_crs   <- terra::crs(terra::rast(files[1]))
#     aoi_buf_proj <- terra::project(terra::vect(sf::st_buffer(aoi, 250)), master_crs)
#     temp         <- terra::rast(extent = terra::ext(aoi_buf_proj),
#                                 crs = master_crs, nlyrs = 4, resolution = 1)
#
# That CRS is a NAD83 UTM zone, and it varies across the LLR (zones 12-15 are
# all present in the LRR F sample). Everything else about the grid - origin,
# dimensions - follows deterministically from the AOI geometry once the zone is
# known; this was verified to reproduce all 16 reference exports in
# naipScrape/data/exportData exactly. So the only fact worth recording is the
# EPSG code. See NAIP_ALIGNMENT.md.
#
# This script does not depend on, and is not depended on by, 00-02. Run it on
# its own:
#
#     Rscript src/03_naip_reference.R
#
# It is resumable: progress is appended to a JSONL cache after every site, so an
# interrupted run continues where it stopped rather than re-querying the API.
# ==============================================================================

pacman::p_load(terra, sf, rstac, jsonlite, dplyr, purrr, furrr, future)

# --- Configuration ------------------------------------------------------------

# Years naipScrape was actually asked for. Both bulk_download.R and
# produce_groundTruthSites.R use these three; they are NOT the mask pipeline's
# target_years (2009:2021), which is a superset.
naip_target_years <- c(2012, 2016, 2020)

# Must match naipScrape. buff_dist_m in produce_groundTruthSites.R and
# target_buffer_m in bulk_download.R are both 250; resolution is hard-coded to 1
# in mergeAndExportNAIP().
naip_buffer_m <- 250
naip_res      <- 1

stac_endpoint     <- "https://planetarycomputer.microsoft.com/api/stac/v1"
naip_ref_json     <- "data/naip_reference.json"
naip_ref_cache    <- "data/naip_reference_cache.jsonl"
naip_ref_workers  <- 4      # kept low: the STAC API rate-limits aggressively
naip_ref_limit    <- NULL   # set to an integer for a smoke test

#' Reproduce naipScrape's Output Grid for One AOI
#'
#' Rebuilds the raster template that mergeAndExportNAIP() would have produced,
#' given the AOI geometry and the EPSG code of the tile that supplied master_crs.
#'
#' The call sequence deliberately mirrors mergeAndExportNAIP() rather than
#' reimplementing its arithmetic. terra::rast(extent = , resolution = ) anchors
#' the grid at (xmin, ymin) and sets the cell counts by rounding - not by
#' ceiling - so the resulting extent can be very slightly smaller than the input
#' extent. Calling terra the same way naipScrape does means we inherit that
#' behaviour instead of having to restate it correctly.
#'
#' @param aoi Single-row sf 1km grid feature (any CRS).
#' @param epsg Integer EPSG code of the NAIP tile CRS (e.g. 26914).
#' @param buffer_m Buffer applied to the AOI before projection, in the AOI's own
#'   CRS. naipScrape buffers in EPSG:5070 and then projects, so the ring is not
#'   exactly buffer_m metres wide in UTM.
#' @param res Output resolution in metres.
#' @param which "buffered" for the naip_1.5km_* grid, "aoi" for the naip_1km_*
#'   grid (the buffered grid cropped to the unbuffered AOI extent).
#' @return SpatRaster template with no values.
naip_template <- function(aoi, epsg, buffer_m = naip_buffer_m, res = naip_res,
                          which = c("buffered", "aoi")) {
  which <- match.arg(which)
  crs_str <- paste0("EPSG:", epsg)

  aoi_v    <- terra::vect(sf::st_geometry(aoi))
  aoi_buf  <- terra::vect(sf::st_geometry(sf::st_buffer(aoi, dist = buffer_m)))
  buf_proj <- terra::project(aoi_buf, crs_str)

  tmpl <- terra::rast(extent = terra::ext(buf_proj), crs = crs_str, resolution = res)

  if (which == "aoi") {
    tmpl <- terra::crop(tmpl, terra::ext(terra::project(aoi_v, crs_str)))
  }
  tmpl
}

#' Describe a Template as Plain Numbers
#'
#' @param r SpatRaster.
#' @return Named list of extent/dimension fields, suitable for JSON.
grid_record <- function(r) {
  e <- as.vector(terra::ext(r))
  list(
    xmin = unname(e["xmin"]), xmax = unname(e["xmax"]),
    ymin = unname(e["ymin"]), ymax = unname(e["ymax"]),
    ncol = terra::ncol(r),    nrow = terra::nrow(r),
    res  = terra::res(r)[1]
  )
}

#' Run a STAC Search With Exponential Backoff
#'
#' Mirrors the retry behaviour in naipScrape's downloadNAIP_vsi(); the Planetary
#' Computer returns transient 5xx errors under load often enough that a single
#' attempt is not usable at this scale.
#'
#' @param bbox Numeric bbox in EPSG:4326.
#' @param datetime STAC datetime range string.
#' @param max_retries Attempts before giving up.
#' @return rstac doc_items, or NULL on persistent failure.
stac_search_retry <- function(bbox, datetime, max_retries = 8) {
  for (attempt in seq_len(max_retries)) {
    res <- tryCatch({
      items <- rstac::stac(stac_endpoint) |>
        rstac::stac_search(
          collections = "naip",
          bbox        = bbox,
          datetime    = datetime,
          limit       = 100
        ) |>
        rstac::get_request()
      # getNAIPYear() does not page, so an AOI with many campaigns could be
      # truncated at 100 items. Fetch the remaining pages explicitly.
      rstac::items_fetch(items)
    }, error = function(e) e)

    if (!inherits(res, "error")) return(res)
    if (attempt == max_retries) return(NULL)
    Sys.sleep(min(60, 5 * attempt) + stats::runif(1, 1, 5))
  }
  NULL
}

#' Extract the EPSG Code From a STAC Feature
#'
#' The projection extension is spelled `proj:epsg` in the version the NAIP
#' collection currently publishes, but newer STAC uses `proj:code` ("EPSG:26914").
#' Accept either so this does not break on a catalogue update.
#'
#' @param f One STAC feature.
#' @return Integer EPSG code, or NA.
feature_epsg <- function(f) {
  p <- f$properties
  if (!is.null(p[["proj:epsg"]])) return(as.integer(p[["proj:epsg"]]))
  if (!is.null(p[["proj:code"]])) return(as.integer(sub("^EPSG:", "", p[["proj:code"]])))
  NA_integer_
}

#' Resolve naipScrape's Year Fallback
#'
#' Both process_aoi.R and produce_groundTruthSites.R try the requested year,
#' then one year back, then two back, then one forward, and use the first that
#' the catalogue offers.
#'
#' @param year Requested year.
#' @param available Character vector of years present for this AOI.
#' @return Integer year actually used, or NA if none of the four are available.
resolve_actual_year <- function(year, available) {
  for (y in c(year, year - 1, year - 2, year + 1)) {
    if (as.character(y) %in% available) return(as.integer(y))
  }
  NA_integer_
}

#' Build the NAIP Reference Record for a Single AOI
#'
#' Issues ONE catalogue query covering every year, then derives the per-year
#' answer from that single response. A per-year query is only re-issued for the
#' rare AOI whose tiles for a given year span more than one UTM zone, where the
#' order of the response decides which CRS naipScrape would have adopted.
#'
#' @param aoi Single-row sf 1km grid feature.
#' @param years Integer vector of requested years.
#' @return Named list for this AOI, or a list with `status` describing failure.
naip_reference_for_aoi <- function(aoi, years = naip_target_years) {
  aoi_id <- aoi$id[1]

  # Stagger workers so the API sees a spread of requests rather than a burst.
  Sys.sleep(stats::runif(1, 0.2, 1.5))

  bbox <- sf::st_bbox(sf::st_transform(aoi, 4326))
  items <- stac_search_retry(bbox, "2008-01-01T00:00:00Z/2026-12-31T23:59:59Z")

  if (is.null(items) || length(items$features) == 0) {
    return(list(id = aoi_id, status = if (is.null(items)) "api_failed" else "no_imagery"))
  }

  feats     <- items$features
  feat_year <- substr(vapply(feats, function(f) f$properties$datetime, character(1)), 1, 4)
  feat_epsg <- vapply(feats, feature_epsg, integer(1))
  available <- sort(unique(feat_year))

  year_records <- list()
  epsg_all     <- integer(0)
  ambiguous    <- FALSE

  for (yr in years) {
    actual <- resolve_actual_year(yr, available)
    if (is.na(actual)) {
      year_records[[as.character(yr)]] <- list(
        requested_year = yr, actual_year = NULL, status = "no_imagery_in_fallback_range"
      )
      next
    }

    keep <- which(feat_year == as.character(actual))
    yr_epsg <- feat_epsg[keep]
    candidates <- sort(unique(yr_epsg[!is.na(yr_epsg)]))

    # naipScrape takes the CRS of files[1] - the first tile in the order the
    # catalogue returned it. When every tile for the year sits in one zone that
    # order is irrelevant. When it does not, re-query for just this year so the
    # response ordering matches what downloadNAIP_vsi() would have seen.
    if (length(candidates) > 1) {
      ambiguous <- TRUE
      yr_items <- stac_search_retry(
        bbox,
        paste0(actual, "-01-01T00:00:00Z/", actual, "-12-31T23:59:59Z")
      )
      if (!is.null(yr_items) && length(yr_items$features) > 0) {
        keep_f  <- yr_items$features
        yr_epsg <- vapply(keep_f, feature_epsg, integer(1))
        keep    <- seq_along(keep_f)
        feats_y <- keep_f
      } else {
        feats_y <- feats[keep]
      }
    } else {
      feats_y <- feats[keep]
    }

    first_epsg <- yr_epsg[!is.na(yr_epsg)][1]
    epsg_all   <- c(epsg_all, candidates)

    year_records[[as.character(yr)]] <- list(
      requested_year = yr,
      actual_year    = actual,
      epsg           = unname(first_epsg),
      epsg_candidates = as.list(candidates),
      crs_ambiguous  = length(candidates) > 1,
      n_tiles        = length(feats_y),
      item_ids       = as.list(vapply(feats_y, function(f) f$id, character(1))),
      capture_dates  = as.list(unique(substr(
        vapply(feats_y, function(f) f$properties$datetime, character(1)), 1, 10
      ))),
      gsd            = as.list(sort(unique(unlist(
        lapply(feats_y, function(f) f$properties$gsd)
      )))),
      status         = "ok"
    )
  }

  ok_years <- Filter(function(x) identical(x$status, "ok"), year_records)
  if (length(ok_years) == 0) {
    return(list(id = aoi_id, status = "no_imagery_in_fallback_range",
                years = year_records, available_years = as.list(available)))
  }

  # The site-level CRS. Verified stable across years for every AOI in
  # naipScrape/data/exportData, which is why one grid per site is enough; if a
  # site ever disagrees between years, site_crs_varies_by_year flags it and the
  # per-year epsg above remains authoritative.
  year_epsgs <- unique(unlist(lapply(ok_years, function(x) x$epsg)))
  site_epsg  <- ok_years[[1]]$epsg

  tmpl_buf <- naip_template(aoi, site_epsg, which = "buffered")
  tmpl_aoi <- naip_template(aoi, site_epsg, which = "aoi")

  list(
    id                       = aoi_id,
    status                   = "ok",
    epsg                     = unname(site_epsg),
    epsg_candidates          = as.list(sort(unique(epsg_all))),
    crs_ambiguous            = ambiguous,
    site_crs_varies_by_year  = length(year_epsgs) > 1,
    available_years          = as.list(available),
    grid_buffered            = grid_record(tmpl_buf),
    grid_aoi                 = grid_record(tmpl_aoi),
    years                    = year_records
  )
}

#' Build the NAIP Reference File for Every Sample Site
#'
#' Appends one JSON object per site to a JSONL cache as it goes, then assembles
#' the cache into the final document. Re-running skips sites already cached, so
#' an interrupted multi-hour run resumes rather than restarting.
#'
#' @param grids sf collection of 1km sample grids (needs an `id` column).
#' @param years Integer vector of requested years.
#' @param out_path Path of the final JSON document.
#' @param cache_path Path of the resumable JSONL cache.
#' @param workers Parallel workers for the API queries.
#' @param limit Optional integer; process only the first N sites (smoke test).
#' @return Path to the written JSON document.
build_naip_reference <- function(grids, years = naip_target_years,
                                 out_path = naip_ref_json,
                                 cache_path = naip_ref_cache,
                                 workers = naip_ref_workers,
                                 limit = naip_ref_limit) {
  if (!dir.exists(dirname(out_path))) dir.create(dirname(out_path), recursive = TRUE)

  if (!is.null(limit)) {
    grids <- grids[seq_len(min(as.integer(limit), nrow(grids))), ]
    warning(paste0("naip_ref_limit is set: querying only ", nrow(grids),
                   " site(s). This is a partial reference file."),
            call. = FALSE, immediate. = TRUE)
  }

  done <- character(0)
  if (file.exists(cache_path)) {
    cached <- purrr::map(readLines(cache_path, warn = FALSE), function(l) {
      tryCatch(jsonlite::fromJSON(l, simplifyVector = FALSE), error = function(e) NULL)
    })
    cached <- Filter(Negate(is.null), cached)
    done <- vapply(cached, function(x) x$id, character(1))
    message(sprintf("Resuming: %d site(s) already in %s", length(done), cache_path))
  }

  todo <- grids[!(grids$id %in% done), ]
  message(sprintf("Querying Planetary Computer for %d site(s) with %d worker(s)...",
                  nrow(todo), workers))

  if (nrow(todo) > 0) {
    future::plan(future::multisession, workers = workers)
    on.exit(future::plan(future::sequential), add = TRUE)

    # Chunked so that results reach the cache steadily; a single future_map over
    # 15,000 sites would hold everything in memory and lose it all on an
    # interrupt.
    chunks <- split(seq_len(nrow(todo)), ceiling(seq_len(nrow(todo)) / 200))
    con <- file(cache_path, open = "a")
    on.exit(close(con), add = TRUE)

    for (ci in seq_along(chunks)) {
      idx <- chunks[[ci]]
      recs <- furrr::future_map(idx, function(i) {
        tryCatch(
          naip_reference_for_aoi(todo[i, ], years = years),
          error = function(e) list(id = todo$id[i], status = "error",
                                   message = conditionMessage(e))
        )
      }, .options = furrr::furrr_options(seed = TRUE, packages = c("sf", "terra", "rstac")))

      for (r in recs) {
        writeLines(jsonlite::toJSON(r, auto_unbox = TRUE, null = "null", digits = NA), con)
      }
      flush(con)
      message(sprintf("  chunk %d/%d complete (%d sites)", ci, length(chunks), length(idx)))
    }
  }

  # Assemble the cache into the final document.
  recs <- purrr::map(readLines(cache_path, warn = FALSE), function(l) {
    tryCatch(jsonlite::fromJSON(l, simplifyVector = FALSE), error = function(e) NULL)
  })
  recs <- Filter(Negate(is.null), recs)
  # A resumed run can append a site twice if it was interrupted mid-flush; keep
  # the last record for each id.
  recs <- recs[!duplicated(vapply(recs, function(x) x$id, character(1)), fromLast = TRUE)]
  names(recs) <- vapply(recs, function(x) x$id, character(1))

  doc <- list(
    schema_version = 1L,
    generated      = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    source         = stac_endpoint,
    collection     = "naip",
    requested_years = as.list(years),
    buffer_m       = naip_buffer_m,
    resolution     = naip_res,
    note = paste(
      "epsg is the CRS of the first STAC tile for the year, matching",
      "naipScrape mergeAndExportNAIP()'s master_crs <- crs(rast(files[1])).",
      "grid_buffered/grid_aoi reproduce the naip_1.5km_* and naip_1km_* grids.",
      "Where crs_ambiguous is true the AOI's tiles span more than one UTM zone",
      "and the recorded epsg depends on catalogue ordering - verify against the",
      "imagery before relying on it."
    ),
    n_sites        = length(recs),
    sites          = recs
  )

  jsonlite::write_json(doc, out_path, auto_unbox = TRUE, null = "null",
                       digits = NA, pretty = TRUE)
  message(sprintf("\nWrote %s (%d sites)", out_path, length(recs)))

  status <- vapply(recs, function(x) x$status, character(1))
  message("Status summary:")
  print(table(status))
  amb <- sum(vapply(recs, function(x) isTRUE(x$crs_ambiguous), logical(1)))
  if (amb > 0) {
    warning(sprintf(paste0(
      "%d site(s) have tiles spanning more than one UTM zone; their recorded ",
      "epsg depends on catalogue ordering and may differ from the zone the ",
      "original download used. See crs_ambiguous in %s."), amb, out_path),
      call. = FALSE, immediate. = TRUE)
  }

  invisible(out_path)
}

# ==============================================================================
# Entry point
# ==============================================================================
if (sys.nframe() == 0) {
  grid_cache <- "data/processed/llr_grids_sample.gpkg"
  if (!file.exists(grid_cache)) {
    stop(paste0("Sample grid cache not found at ", grid_cache,
                ".\n  Run src/02_run_pipeline.R first, or generate it with ",
                "get_sample_grids()."))
  }
  message(paste("Loading sample grids from", grid_cache))
  sample_grids <- sf::st_read(grid_cache, quiet = TRUE)
  message(sprintf("  %d sites", nrow(sample_grids)))

  build_naip_reference(sample_grids)
}
