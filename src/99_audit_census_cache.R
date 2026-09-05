# ==============================================================================
# Utility: Audit the cached Census Places files for silent year substitutions
# ==============================================================================
#
# Older runs of get_census_places() fell back to a fixed reference year when the
# requested year was unavailable, but wrote the substituted data under the
# requested year's filename with nothing to record the swap. Those files are
# indistinguishable from genuine downloads by name, size, or schema.
#
# This script fingerprints each cached file by its attribute table and flags any
# group of years whose contents are identical - a group larger than one means at
# least one of those years is not really that year's data.
#
# It is read-only. It prints the shell command to remove the suspect files so
# that the corrected pipeline re-downloads them; it does not delete anything.
#
# Usage:  Rscript src/99_audit_census_cache.R [census_dir]

suppressPackageStartupMessages(library(sf))

args <- commandArgs(trailingOnly = TRUE)
census_dir <- if (length(args) > 0) args[1] else "data/raw/census"

files <- list.files(census_dir, pattern = "^census_places_\\d{4}\\.gpkg$", full.names = TRUE)
if (length(files) == 0) {
  message("No census_places_<year>.gpkg files found in ", census_dir)
  quit(save = "no")
}

# Content fingerprint: the sorted attribute table written to a temp CSV and
# hashed. Uses tools::md5sum so the script needs no extra packages.
fingerprint <- function(path) {
  d <- sf::st_read(path, quiet = TRUE)
  atts <- sf::st_drop_geometry(d)
  stamped <- if ("census_source_year" %in% names(atts)) {
    as.integer(atts$census_source_year[1])
  } else {
    NA_integer_
  }

  # Provenance columns are what distinguish a stamped file; exclude them from
  # the content fingerprint so a stamped and an unstamped copy still match.
  atts <- atts[, !names(atts) %in% c("census_source_year", "census_requested_year"), drop = FALSE]
  key_cols <- intersect(c("GEOID", "NAME", "ALAND", "AWATER"), names(atts))
  if (length(key_cols) == 0) key_cols <- names(atts)
  atts <- atts[do.call(order, atts[key_cols]), key_cols, drop = FALSE]

  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp), add = TRUE)
  utils::write.csv(atts, tmp, row.names = FALSE)

  list(n = nrow(d), hash = unname(tools::md5sum(tmp)), stamped_source = stamped)
}

message("Fingerprinting ", length(files), " cached census file(s) in ", census_dir, " ...")
info <- lapply(files, function(f) {
  yr <- as.integer(sub(".*census_places_(\\d{4})\\.gpkg$", "\\1", f))
  fp <- fingerprint(f)
  data.frame(
    year = yr, path = f, features = fp$n,
    stamped_source_year = fp$stamped_source,
    content_hash = fp$hash, stringsAsFactors = FALSE
  )
})
info <- do.call(rbind, info)
info <- info[order(info$year), ]

message("\n--- Cached census files ---")
print(info[, c("year", "features", "stamped_source_year")], row.names = FALSE)

dupe_hashes <- names(which(table(info$content_hash) > 1))
if (length(dupe_hashes) == 0) {
  message("\nOK: every cached census year has distinct content.")
  quit(save = "no")
}

message("\n!!! Identical content found across different years !!!")
suspect_paths <- character(0)
for (h in dupe_hashes) {
  grp <- info[info$content_hash == h, ]
  years <- grp$year
  message("\n  Years with identical place geometries: ", paste(years, collapse = ", "))
  # The genuine file is the one the data actually came from. Without a stamp we
  # cannot know which, so report the whole group and suggest keeping none.
  stamped <- grp$stamped_source_year[!is.na(grp$stamped_source_year)]
  if (length(stamped) > 0) {
    message("    Provenance stamp says the source year is: ", paste(unique(stamped), collapse = ", "))
  } else {
    message("    None of these files carry a provenance stamp, so the true source year is unknown.")
  }
  suspect_paths <- c(suspect_paths, grp$path)
}

message("\n--- Suggested remediation ---")
message("Remove the affected files so the corrected pipeline re-downloads them and")
message("stamps each with its real source year:\n")
message("  rm ", paste(suspect_paths, collapse = " \\\n     "))
message("\nThen re-run:  Rscript 0_run.R")
message("\nAny year that genuinely has no Census data will be re-fetched from the")
message("nearest available year and clearly marked via the census_source_year column.")
