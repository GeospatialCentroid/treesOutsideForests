# ==============================================================================
# Shared preparation for the sample-design maps: reads the LRR, MLRAs, sample
# list and ground-truth ids; keeps only cells inside the LRR (spatial test);
# assigns training / validation roles; builds site geometry and the context
# layers (Census places, NLCD forest) from the masks/ stage products.
#
# Roles come from the partner's train / validation / test partitions listed in
# config.yml `sampling$partitions` (one assignment per partition, written to
# data/reference/sampleGrids/ so later stages can read the same roles). With no
# partition configured they are drawn at random instead (seeded), and that CSV
# is only written when it does not already exist, so a rerun never silently
# changes a draw; delete it to redraw.
#
# Sourced by 01_map_lrr_sites.R and 02_map_mlra_sites.R; not run on its own.
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(sf, dplyr, purrr, readr, ggplot2, ragg, leaflet, htmlwidgets, htmltools, tigris, terra)
options(tigris_use_cache = TRUE)
terra::terraOptions(progress = 0)
source(tof_root("sampling/functions/grid_cells.R"))
source(tof_root("sampling/functions/site_maps.R"))

cfg     <- tof_config()
cfg_smp <- cfg$sampling
llr_id  <- cfg_smp$llr_id
crs     <- cfg$crs
map_dir <- tof_path(cfg_smp$paths$map_dir)
derived <- tof_path(cfg_smp$paths$derived_dir)
for (d in c(map_dir, derived)) dir.create(d, showWarnings = FALSE, recursive = TRUE)

# --- Inputs -------------------------------------------------------------------
lrr  <- read_lrr(llr_id, crs = crs)
mlra <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE) |>
  dplyr::filter(LRRSYM == llr_id) |> sf::st_transform(crs) |>
  dplyr::arrange(MLRARSYM) |>
  dplyr::mutate(mlra_label = paste(MLRARSYM, MLRA_NAME))
mlra_cols <- mlra_palette(mlra)
g100 <- sf::st_read(tof_path(cfg$reference$grid_gpkg), quiet = TRUE)

# The sample list carries a handful of duplicate ids; keep the first of each.
sample_tbl <- read_sites_csv(tof_path(cfg_smp$paths$sample_csv)) |> dplyr::distinct(id, .keep_all = TRUE)
gt_tbl <- readr::read_csv(tof_path(cfg_smp$paths$groundtruth_csv), show_col_types = FALSE) |> dplyr::distinct(id, .keep_all = TRUE)

# The partitions: Type per scene_id. With none configured, one random draw.
partitions <- cfg_smp$partitions
if (length(partitions) == 0) partitions <- list(random = list(csv = NULL, label = sprintf("random split, seed %d", cfg_smp$seed)))
partition_tbl <- purrr::imap(partitions, function(part, key) {
  if (is.null(part$csv)) return(NULL)
  p <- readr::read_csv(tof_path(part$csv), show_col_types = FALSE)
  if (!all(c("scene_id", "Type") %in% names(p))) stop("Partition ", key, " needs scene_id and Type columns: ", part$csv)
  p <- p |> dplyr::distinct(scene_id, .keep_all = TRUE) |>
    dplyr::transmute(id = scene_id, role = unname(c(Train = "training", Validation = "validation", Test = "test")[Type]))
  if (anyNA(p$role)) stop("Partition ", key, " has a Type other than Train / Validation / Test: ", part$csv)
  p
})

# --- Spatial test: keep only cells whose centroid lies inside the LRR ---------
all_ids <- Reduce(union, c(list(sample_tbl$id, gt_tbl$id), lapply(purrr::compact(partition_tbl), `[[`, "id")))
cells   <- cells_from_ids(all_ids, g100) |> sf::st_transform(crs)
ctr     <- suppressWarnings(sf::st_centroid(cells))
inside  <- lengths(sf::st_within(ctr, lrr)) > 0
ctr     <- suppressWarnings(sf::st_join(ctr, mlra[, c("MLRA_ID", "MLRARSYM", "MLRA_NAME")], join = sf::st_within))
dropped <- all_ids[!inside]
message(sprintf("Spatial test against LRR %s: %d of %d cells inside; dropped %d (%d from the sample list, %d ground-truth).",
                llr_id, sum(inside), length(all_ids), length(dropped),
                sum(dropped %in% sample_tbl$id), sum(dropped %in% gt_tbl$id)))
cells <- cells[inside, ]; ctr <- ctr[inside, ]
sample_tbl <- sample_tbl |> dplyr::filter(id %in% cells$id)
gt_tbl     <- gt_tbl     |> dplyr::filter(id %in% cells$id)

# --- Role assignment, one per partition ---------------------------------------
# A scene in the partition takes its Type; every other cell inside the LRR is a
# plain sampled cell if the sample list holds it, otherwise unassigned (a
# ground-truth cell the partition does not use). The partition assignment is
# deterministic and is rewritten on every run.
roles_path_for <- function(key) tof_path(sub("{partition}", key, cfg_smp$paths$roles_csv, fixed = TRUE))
base_roles <- sf::st_drop_geometry(ctr) |>
  dplyr::mutate(LLR_ID = llr_id, in_sample_list = id %in% sample_tbl$id)
finish_roles <- function(r, key) {
  r |> dplyr::left_join(gt_tbl |> dplyr::select(id, groundtruth_year = year), by = "id") |>
    dplyr::mutate(partition = key) |>
    dplyr::select(id, MLRA_ID, MLRARSYM, LLR_ID, partition, role, in_sample_list, groundtruth_year)
}
assign_roles <- function(key) {
  roles_path <- roles_path_for(key)
  p <- partition_tbl[[key]]
  if (!is.null(p)) {
    outside <- setdiff(p$id, base_roles$id)
    if (length(outside) > 0)
      warning(sprintf("Partition %s: %d scene(s) are not 1 km cells inside LRR %s and are dropped: %s",
                      key, length(outside), llr_id, paste(utils::head(outside, 5), collapse = ", ")), call. = FALSE)
    roles <- base_roles |> dplyr::left_join(p, by = "id") |>
      dplyr::mutate(role = dplyr::case_when(!is.na(role) ~ role, in_sample_list ~ "sample", TRUE ~ "unassigned")) |>
      finish_roles(key)
    readr::write_csv(roles, roles_path)
    message(sprintf("Partition %s (%s): roles from %s -> %s", key, partitions[[key]]$label,
                    basename(partitions[[key]]$csv), basename(roles_path)))
  } else if (file.exists(roles_path)) {
    message("Using existing random role assignment: ", roles_path)
    roles <- read_sites_csv(roles_path)
  } else {
    set.seed(cfg_smp$seed)
    gt_ids  <- sample(gt_tbl$id)                       # shuffled once, seeded
    n_train <- min(cfg_smp$n_training, length(gt_ids))
    n_valid <- min(cfg_smp$n_validation, length(gt_ids) - n_train)
    train <- gt_ids[seq_len(n_train)]
    valid <- gt_ids[n_train + seq_len(n_valid)]
    if (n_train + n_valid < length(gt_ids))
      warning(sprintf("%d ground-truth sites left unassigned (config asks for %d + %d, %d available).",
                      length(gt_ids) - n_train - n_valid, cfg_smp$n_training, cfg_smp$n_validation, length(gt_ids)), call. = FALSE)
    roles <- base_roles |>
      dplyr::mutate(role = dplyr::case_when(id %in% train ~ "training",
                                            id %in% valid ~ "validation",
                                            in_sample_list ~ "sample",
                                            TRUE ~ "unassigned")) |>
      finish_roles(key)
    readr::write_csv(roles, roles_path)
    message("Wrote random role assignment (seed ", cfg_smp$seed, "): ", roles_path)
  }
  print(table(roles$role))
  roles
}
roles_by <- purrr::imap(partitions, function(part, key) assign_roles(key))

# One sentence for captions and footers saying where the roles came from.
role_source_text <- function(key) {
  part <- partitions[[key]]
  if (is.null(part$csv)) sprintf("Training and validation are the June 2026 ground-truth sites inside LRR %s, split at random with seed %d.", llr_id, cfg_smp$seed)
  else sprintf("Training and validation sites follow the %s partition (%s); validation includes the partition's test sites.", part$label, basename(part$csv))
}

# Roles as the maps draw them: the partition's test sites count as validation
# sites. The roles CSV keeps the three-way assignment.
map_role <- function(role) ifelse(role == "test", "validation", role)
n_validation <- function(roles) sum(roles$role %in% c("validation", "test"))

# --- Site geometry, one point set per partition ------------------------------
site_points <- function(roles) {
  sites <- cells |> dplyr::inner_join(roles, by = "id")
  suppressWarnings(sf::st_centroid(sites)) |>
    dplyr::mutate(role = map_role(role)) |>
    dplyr::filter(role %in% names(role_labels)) |>
    dplyr::mutate(role = factor(role, levels = names(role_labels), labels = unname(role_labels)))
}
pts_by <- lapply(roles_by, site_points)

# --- Context: states, Census places, NLCD forest -----------------------------
states <- tryCatch(
  tigris::states(cb = TRUE, resolution = "20m", progress_bar = FALSE) |> sf::st_transform(crs),
  error = function(e) { message("State boundaries unavailable (", conditionMessage(e), "); continuing without."); NULL })

ctx_year  <- cfg_smp$context_year
masks_out <- tof_path(cfg_smp$paths$masks_outputs)

places_path <- file.path(masks_out, sprintf("llr_%s_places_%d.gpkg", llr_id, ctx_year))
places <- if (file.exists(places_path)) {
  sf::st_read(places_path, quiet = TRUE) |> sf::st_transform(crs) |>
    sf::st_simplify(dTolerance = 50) |> dplyr::select(NAME, NAMELSAD, STUSPS)
} else { message("No Census places product for ", ctx_year, " at ", places_path); NULL }

# The 30 m forest binary is 1.1 billion cells; the web maps get a cached,
# coarsened forest-fraction version (block mean), built once per block size.
forest_fraction <- function(block) {
  src   <- file.path(masks_out, sprintf("llr_%s_forest_%d.tif", llr_id, ctx_year))
  cache <- file.path(derived, sprintf("llr_%s_forest_%d_%dm.tif", llr_id, ctx_year, block * 30))
  if (file.exists(cache)) return(terra::rast(cache))
  if (!file.exists(src)) { message("No NLCD forest product for ", ctx_year, " at ", src); return(NULL) }
  message("Aggregating ", basename(src), " to ", block * 30, " m (one-off, cached)...")
  a <- terra::aggregate(terra::rast(src), fact = block, fun = "mean", na.rm = TRUE)
  names(a) <- "forest_fraction"
  terra::writeRaster(a, cache, overwrite = TRUE, datatype = "FLT4S", gdal = "COMPRESS=DEFLATE")
  a
}
# Transparent where less than 2 % of the block is forest.
forest_layer <- function(block) { f <- forest_fraction(block); if (is.null(f)) NULL else terra::classify(f, cbind(-Inf, 0.02, NA)) }

# `pts` is filled per partition by the map scripts (pts_by[[key]]).
layers <- list(pts = NULL, cells = cells, states = states, places = places, forest = NULL)
