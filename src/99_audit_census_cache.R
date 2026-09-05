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

# Identical content across years is only a problem when nothing explains it.
# A stamped fallback legitimately produces duplicates: if 2009 and 2010 both
# fell back to 2011, all three files share content and all three say so. That
# is the system working, not corruption. Only flag a group when the stamps do
# not account for it.
explained <- list()
suspect   <- list()
for (h in dupe_hashes) {
  grp <- info[info$content_hash == h, ]
  stamps <- grp$stamped_source_year
  if (anyNA(stamps)) {
    grp$reason <- "one or more files carry no provenance stamp, so the true source year is unknown"
    suspect[[h]] <- grp
  } else if (length(unique(stamps)) > 1) {
    grp$reason <- paste0("files share identical content but disagree on their source year (",
                         paste(unique(stamps), collapse = ", "), ")")
    suspect[[h]] <- grp
  } else {
    explained[[h]] <- grp
  }
}

if (length(explained) > 0) {
  message("\n--- Duplicate content, explained by provenance (no action needed) ---")
  for (grp in explained) {
    message("  ", paste(grp$year, collapse = ", "),
            "  all sourced from ", unique(grp$stamped_source_year),
            ifelse(unique(grp$stamped_source_year) %in% grp$year,
                   "  (that year downloaded normally; the others fell back to it)",
                   ""))
  }
  message("  These years have no Census Places of their own. The substitution is")
  message("  recorded in each file's census_source_year column.")
}

if (length(suspect) == 0) {
  message("\nOK: no unexplained duplication. Every cached file is either unique or")
  message("    a fallback that says so.")
  quit(save = "no")
}

message("\n!!! Unexplained identical content across different years !!!")
suspect_paths <- character(0)
for (grp in suspect) {
  message("\n  Years: ", paste(grp$year, collapse = ", "))
  message("    ", grp$reason[1])
  suspect_paths <- c(suspect_paths, grp$path)
}

message("\n--- Suggested remediation ---")
message("Remove the affected files so the corrected pipeline re-downloads them and")
message("stamps each with its real source year:\n")
message("  rm ", paste(suspect_paths, collapse = " \\\n     "))
message("\nThen re-run:  Rscript 0_run.R")
