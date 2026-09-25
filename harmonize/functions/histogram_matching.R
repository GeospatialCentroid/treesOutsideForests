# Radiometric harmonisation of a cell's NAIP years by histogram specification.
# Ported from neymanSampling/scripts/imageHarmonization.R and
# 34_applyingHistNormalization.R (the "consensus" KS gate and the quantile
# matching), adapted to this repo's one-folder-per-cell-year export layout.

NAIP_BANDS <- c("red", "green", "blue", "nir")

#' Kolmogorov-Smirnov distance between two years on the evaluation bands.
#'
#' The largest D statistic over the bands, from a regular spatial sample of
#' each raster (no-data excluded). Blue tracks haze and path radiance, NIR the
#' sensor and vegetation response, so the two together catch most drift.
ks_distance <- function(r1, r2, bands, sample_size) {
  s1 <- terra::spatSample(r1[[bands]], size = sample_size, method = "regular", na.rm = TRUE)
  s2 <- terra::spatSample(r2[[bands]], size = sample_size, method = "regular", na.rm = TRUE)
  d <- vapply(bands, function(b) unname(suppressWarnings(stats::ks.test(s1[[b]], s2[[b]])$statistic)), numeric(1))
  list(max = max(d), per_band = d)
}

#' Decide which year, if any, is the radiometric outlier of a three-year stack.
#'
#' Pairwise KS distances over the years; the year with the largest summed
#' distance is the candidate, the other two the consensus pair. The candidate
#' is only an outlier when its mean distance to the pair exceeds `threshold`
#' and `relative` times the pair's own distance (both gates from the reference
#' method). Returns the distance matrix, the outlier (or NA), the consensus
#' reference year (the most recent consensus year) and the two distances.
consensus_outlier <- function(rasters, bands, sample_size, threshold, relative) {
  years <- sort(names(rasters))
  d <- matrix(0, length(years), length(years), dimnames = list(years, years))
  for (p in utils::combn(years, 2, simplify = FALSE)) {
    k <- ks_distance(rasters[[p[1]]], rasters[[p[2]]], bands, sample_size)$max
    d[p[1], p[2]] <- k; d[p[2], p[1]] <- k
  }
  candidate <- names(which.max(rowSums(d)))
  consensus <- setdiff(years, candidate)
  consensus_dist <- d[consensus[1], consensus[2]]
  outlier_dist <- mean(d[candidate, consensus])
  is_outlier <- outlier_dist > threshold && outlier_dist > relative * consensus_dist
  list(distances = d, candidate = candidate, outlier = if (is_outlier) candidate else NA_character_,
       reference = max(consensus), consensus_dist = consensus_dist, outlier_dist = outlier_dist)
}

#' Per-band lookup tables that map a target year's 0-255 values onto the
#' reference year's distribution (empirical CDF matching).
#'
#' Quantiles are taken over every valid pixel of each raster rather than a
#' sample: a 1.5 km cell is a few million pixels, cheap to read, and the
#' reference project's timing tests found the sampled and full versions
#' indistinguishable in output. `n_quantiles` = 256 matches the 8-bit range.
build_luts <- function(target, reference, n_quantiles) {
  probs <- seq(0, 1, length.out = n_quantiles)
  lapply(NAIP_BANDS, function(b) {
    tq <- stats::quantile(terra::values(target[[b]], mat = FALSE, na.rm = TRUE), probs = probs, names = FALSE)
    rq <- stats::quantile(terra::values(reference[[b]], mat = FALSE, na.rm = TRUE), probs = probs, names = FALSE)
    keep <- !duplicated(tq)
    lut <- round(stats::approx(x = tq[keep], y = rq[keep], xout = 0:255, rule = 2)$y)
    as.integer(pmin(pmax(lut, 0), 254))   # 255 stays the no-data code
  }) |> stats::setNames(NAIP_BANDS)
}

#' Apply per-band lookup tables to a 4-band raster and write it as 8-bit.
apply_luts <- function(r, luts, out_path) {
  names(r) <- NAIP_BANDS
  layers <- lapply(NAIP_BANDS, function(b) {
    lut <- luts[[b]]
    terra::app(r[[b]], fun = function(x) lut[x + 1L])
  })
  out <- terra::rast(layers); names(out) <- NAIP_BANDS
  terra::writeRaster(out, out_path, overwrite = TRUE, datatype = "INT1U", NAflag = 255,
                     gdal = c("COMPRESS=DEFLATE", "TILED=YES"))
  out_path
}

#' Link (or copy) a cell-year's export into the harmonised tree unchanged.
link_year <- function(src_dir, dst_dir) {
  dir.create(dst_dir, showWarnings = FALSE, recursive = TRUE)
  for (f in list.files(src_dir, full.names = TRUE)) {
    dst <- file.path(dst_dir, basename(f))
    if (file.exists(dst) || nzchar(Sys.readlink(dst))) unlink(dst)
    ok <- suppressWarnings(file.symlink(normalizePath(f), dst))
    if (!isTRUE(ok)) file.copy(f, dst, overwrite = TRUE)
  }
}

#' Harmonise every year of one cell. Returns one row per year.
#'
#' @param id Cell id. Its years are the export folders aoi_<id>_<year> that
#'   hold a naip_1.5km GeoTIFF.
#' @param mode "consensus": only a KS-flagged outlier year is remapped, to the
#'   most recent consensus year. "reference": every year but the reference is
#'   remapped to it.
#' @param reference_year "latest" or a year; in consensus mode the reference is
#'   always the consensus pair's most recent year and this is ignored.
harmonize_cell <- function(id, export_dir, out_dir, mode, reference_year, bands, sample_size,
                           threshold, relative, n_quantiles, overwrite = FALSE) {
  dirs <- list.files(export_dir, pattern = paste0("^aoi_", id, "_\\d{4}$"), full.names = TRUE)
  years <- sub(".*_(\\d{4})$", "\\1", dirs)
  files <- file.path(dirs, sprintf("naip_1.5km_%s_%s.tif", id, years))
  has <- file.exists(files)
  dirs <- dirs[has]; years <- years[has]; files <- files[has]
  if (length(years) == 0) return(NULL)
  o <- order(years); dirs <- dirs[o]; years <- years[o]; files <- files[o]
  out_dirs <- file.path(out_dir, basename(dirs))
  stamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  row <- function(year, action, reference = NA_character_, ks = NA_real_, note = "") {
    data.frame(id = id, year = year, action = action, reference_year = reference,
               ks_to_reference = round(ks, 4), mode = mode, note = note, timestamp = stamp, stringsAsFactors = FALSE)
  }
  done <- file.exists(file.path(out_dirs, "harmonization.json"))
  if (all(done) && !overwrite) {
    return(do.call(rbind, lapply(out_dirs, function(d) {
      j <- jsonlite::fromJSON(file.path(d, "harmonization.json"))
      nz <- function(v) if (is.null(v) || length(v) == 0) NA else v
      row(nz(j$year), paste0(j$action, " (existing)"), nz(j$reference_year), as.numeric(nz(j$ks_to_reference)), "")
    })))
  }

  rasters <- lapply(files, function(f) { r <- terra::rast(f); names(r) <- NAIP_BANDS; r })
  names(rasters) <- years

  # Which years get remapped, and to what.
  plan <- data.frame(year = years, action = "linked", reference = NA_character_, ks = NA_real_, note = "", stringsAsFactors = FALSE)
  if (mode == "consensus") {
    if (length(years) < 3) {
      plan$note <- sprintf("%d year(s) only; the consensus test needs three", length(years))
    } else {
      c3 <- consensus_outlier(rasters, bands, sample_size, threshold, relative)
      for (i in seq_along(years)) plan$ks[i] <- if (years[i] == c3$reference) 0 else c3$distances[years[i], c3$reference]
      plan$reference <- c3$reference
      plan$note <- sprintf("candidate %s: mean KS to consensus %.3f, consensus pair KS %.3f", c3$candidate, c3$outlier_dist, c3$consensus_dist)
      if (!is.na(c3$outlier)) plan$action[plan$year == c3$outlier] <- "normalized"
    }
  } else if (mode == "reference") {
    ref <- if (identical(as.character(reference_year), "latest") || !(as.character(reference_year) %in% years)) max(years) else as.character(reference_year)
    if (!identical(as.character(reference_year), "latest") && ref != as.character(reference_year))
      plan$note <- sprintf("requested reference %s not exported; using %s", reference_year, ref)
    plan$reference <- ref
    for (i in seq_along(years)) {
      if (years[i] == ref) { plan$ks[i] <- 0; next }
      plan$ks[i] <- ks_distance(rasters[[years[i]]], rasters[[ref]], bands, sample_size)$max
      plan$action[i] <- "normalized"
    }
  } else stop("harmonize mode must be 'consensus' or 'reference', not ", mode)

  # Write: remapped years get new GeoTIFFs (the LUT from the 1.5 km image is
  # applied to the 1 km crop too, so both stay consistent); other years are
  # linked to the raw export so the harmonised tree is complete either way.
  for (i in seq_along(years)) {
    dst <- out_dirs[i]
    if (plan$action[i] == "normalized") {
      dir.create(dst, showWarnings = FALSE, recursive = TRUE)
      luts <- build_luts(rasters[[years[i]]], rasters[[plan$reference[i]]], n_quantiles)
      for (f in list.files(dirs[i], pattern = sprintf("^naip_.*_%s_%s\\.tif$", id, years[i]), full.names = TRUE)) {
        apply_luts(terra::rast(f), luts, file.path(dst, basename(f)))
      }
      for (f in list.files(dirs[i], pattern = "\\.(json|gpkg)$", full.names = TRUE)) file.copy(f, file.path(dst, basename(f)), overwrite = TRUE)
      jsonlite::write_json(luts, file.path(dst, "harmonization_luts.json"))
    } else {
      link_year(dirs[i], dst)
    }
    jsonlite::write_json(list(id = id, year = years[i], action = plan$action[i], reference_year = plan$reference[i],
                              ks_to_reference = plan$ks[i], mode = mode, eval_bands = bands, ks_threshold = threshold,
                              ks_relative = relative, n_quantiles = n_quantiles, note = plan$note[i],
                              source = dirs[i], timestamp = stamp),
                         file.path(dst, "harmonization.json"), auto_unbox = TRUE, pretty = TRUE)
  }
  terra::tmpFiles(remove = TRUE)
  do.call(rbind, lapply(seq_along(years), function(i) row(years[i], plan$action[i], plan$reference[i], plan$ks[i], plan$note[i])))
}
