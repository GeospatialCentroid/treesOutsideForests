# Seed Reproducibility Test
library(dplyr)
source(here::here("shared/R/setup.R"))

# 1. Load sample CSV
csv_path <- tof_path(tof_config()$naip$paths$sample_f_csv)
if (!file.exists(csv_path)) {
  stop("Missing input CSV file.")
}
table <- readr::read_csv(csv_path, show_col_types = FALSE)

# 2. Draw 15 random samples using seed 125
set.seed(125)
sampled_table <- table %>%
  dplyr::sample_n(size = 15, replace = FALSE)

sampled_ids <- sort(unique(sampled_table$id))
cat("\n--- Sampled IDs using seed 125 ---\n")
print(sampled_ids)

# 3. Check against actual directories in data/exportData
export_dirs <- list.dirs(tof_path(tof_config()$naip$paths$export_dir), full.names = FALSE, recursive = FALSE)
export_aoi_folders <- export_dirs[grepl("^aoi_", export_dirs)]

# Extract unique AOI IDs from folder names (format: aoi_<id>_<year>)
folder_ids <- unique(sub("^aoi_(.*)_[0-9]{4}$", "\\1", export_aoi_folders))
folder_ids <- folder_ids[folder_ids != ""]
folder_ids <- sort(folder_ids)

cat("\n--- Existing Folder IDs in exportData ---\n")
print(folder_ids)

# 4. Compare
all_match <- all(sampled_ids %in% folder_ids)
cat("\n--- Match Results ---\n")
if (all_match) {
  cat("SUCCESS: All 15 sampled IDs are present in the exportData directory!\n")
} else {
  missing <- setdiff(sampled_ids, folder_ids)
  cat("FAILURE: The following sampled IDs are missing from exportData:\n")
  print(missing)
}
