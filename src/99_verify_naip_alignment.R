# ==============================================================================
# Verify NAIP Alignment Against Real Imagery
# ==============================================================================
# Builds NAIP-aligned masks for every site-year that has real naipScrape imagery
# on disk, then checks each one against the image it is meant to overlay.
#
# This is the pilot / regression harness for the alignment work. It needs a
# local naipScrape checkout with populated data/exportData; set naip_export_dir
# below if yours is elsewhere.
#
#     Rscript src/99_verify_naip_alignment.R
# ==============================================================================

pacman::p_load(terra, sf, jsonlite, dplyr, purrr)

source("src/04_naip_aligned_masks.R")   # brings in 03_naip_reference.R

naip_export_dir <- "/home/dune/trueNAS/work/naipScrape/data/exportData"
pilot_ref_json  <- "data/naip_reference_pilot.json"
pilot_ref_cache <- "data/naip_reference_pilot_cache.jsonl"
pilot_out_base  <- "outputs/pilot_naip_aligned"

if (!dir.exists(naip_export_dir)) {
  stop(paste("naipScrape export directory not found:", naip_export_dir))
}

# --- 1. Which site-years have real imagery? -----------------------------------
naip_files <- list.files(naip_export_dir, pattern = "^naip_1\\.5km_.*\\.tif$",
                         recursive = TRUE, full.names = TRUE)
pairs <- data.frame(
  path = naip_files,
  id   = sub("^naip_1\\.5km_(.+)_(\\d{4})\\.tif$", "\\1", basename(naip_files)),
  year = as.integer(sub("^naip_1\\.5km_(.+)_(\\d{4})\\.tif$", "\\2", basename(naip_files))),
  stringsAsFactors = FALSE
)
message(sprintf("Found %d NAIP images covering %d site(s), years %s",
                nrow(pairs), length(unique(pairs$id)),
                paste(sort(unique(pairs$year)), collapse = ", ")))

# --- 2. Grid geometries -------------------------------------------------------
grids <- sf::st_read("data/processed/llr_grids_sample.gpkg", quiet = TRUE)
pilot_grids <- grids[grids$id %in% unique(pairs$id), ]
missing <- setdiff(unique(pairs$id), pilot_grids$id)
if (length(missing) > 0) {
  warning(paste("No sample geometry for:", paste(missing, collapse = ", ")),
          call. = FALSE, immediate. = TRUE)
}

# --- 3. Reference JSON for just these sites -----------------------------------
if (!file.exists(pilot_ref_json)) {
  message("\n--- Building pilot NAIP reference ---")
  build_naip_reference(pilot_grids, out_path = pilot_ref_json,
                       cache_path = pilot_ref_cache, workers = 3, limit = NULL)
}
ref <- jsonlite::fromJSON(pilot_ref_json, simplifyVector = FALSE)

# --- 4. Build masks -----------------------------------------------------------
message("\n--- Building NAIP-aligned masks ---")
pairs <- pairs[pairs$id %in% pilot_grids$id, ]
pairs <- pairs[order(pairs$year, pairs$id), ]

results <- list()
for (yr in sort(unique(pairs$year))) {
  nlcd_path   <- file.path("data/processed/NLCD", sprintf("Annual_NLCD_LndCov_%d_binary.tif", yr))
  census_path <- file.path("data/raw/census", sprintf("census_places_%d.gpkg", yr))
  if (!file.exists(nlcd_path))   { warning(paste("missing NLCD for", yr));   next }
  if (!file.exists(census_path)) { warning(paste("missing census for", yr)); next }

  census_llr <- sf::st_read(census_path, quiet = TRUE)
  out_dir <- file.path(pilot_out_base, as.character(yr))
  sub <- pairs[pairs$year == yr, ]

  for (i in seq_len(nrow(sub))) {
    site <- ref$sites[[sub$id[i]]]
    if (is.null(site) || !identical(site$status, "ok")) {
      warning(paste("no usable reference entry for", sub$id[i]), call. = FALSE)
      next
    }
    r <- process_grid_naip(
      grid_row   = pilot_grids[pilot_grids$id == sub$id[i], ],
      epsg       = as.integer(site$epsg),
      nlcd_path  = nlcd_path,
      census_llr = census_llr,
      out_dir    = out_dir,
      year       = yr
    )
    if (identical(r$status, "ok")) {
      results[[length(results) + 1]] <- verify_against_naip(r$tif, sub$path[i])
    } else {
      message(sprintf("  FAILED %s %d: %s", sub$id[i], yr, r$message))
    }
  }
  message(sprintf("  year %d: %d image(s) processed", yr, nrow(sub)))
}

# --- 5. Report ----------------------------------------------------------------
res <- dplyr::bind_rows(results)
message("\n=========================================================")
message("NAIP alignment verification")
message("=========================================================")
print(res, row.names = FALSE)

message(sprintf("\ngeometry match      : %d / %d", sum(res$geom_match), nrow(res)))
message(sprintf("nodata agreement    : min %.3f%%  mean %.3f%%",
                min(res$nodata_agreement_pct, na.rm = TRUE),
                mean(res$nodata_agreement_pct, na.rm = TRUE)))
if (!all(res$geom_match)) {
  warning(sprintf("%d mask(s) do NOT align with their NAIP image.",
                  sum(!res$geom_match)), call. = FALSE, immediate. = TRUE)
}
readr_ok <- tryCatch({ utils::write.csv(res, file.path(pilot_out_base, "verification.csv"),
                                        row.names = FALSE); TRUE }, error = function(e) FALSE)
if (readr_ok) message(sprintf("\nWrote %s/verification.csv", pilot_out_base))
