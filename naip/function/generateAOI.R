# generate the a grid object  --------------------------------------------------
## currently duplicated from the preprocessingFunction.R
buildGrids <- function(extent_object, cell_size) {
  # transform to equal area
    ea <- sf::st_transform(extent_object, 5070)
  # generate grid
  grid <- sf::st_make_grid(
    x = ea,
    cellsize = cell_size
  )
  if ("id" %in% names(ea)) {
    ids <- paste0(ea$id[1], "-", as.hexmode(1:length(grid)))
  } else {
    ids = as.hexmode(1:length(grid))
  }
  # generate ID
  gridID <- sf::st_sf(
    id = ids,
    geomentry = grid
  )
  # export
  return(gridID)
}

# generate subgrids objects
buildSubGrids <- function(grids, cell_size, aoi) {
  # generate sub grids
  subGrids <- grids |>
    dplyr::group_split(id) |>
    purrr::map(.f = buildGrids, cell_size = cell_size) |>
    dplyr::bind_rows()
  # apply the filter again --
  subGrids <- subGrids[aoi, ]

  return(subGrids)
}

getAOI <- function(grid100, point = FALSE, id = FALSE) {
  # condition for setting input type to test
  if (!isFALSE(point)) {
    # message("Grabing aoi based on lat lon value ")
    # generate a point object and convert to albert equal area
    pointFeature <- sf::st_point(point) |>
      sf::st_sfc(crs = "EPSG:4326") |>
      st_transform(crs = "EPSG:5070")

    # intersect with 100km grid
    gid <- grid100[pointFeature, ] |>
      as.data.frame() |>
      dplyr::pull("id")

    # 100k grid
    g1 <- grid100[grid100$id == gid, ]

    ### it be worth building this into a specific function.
    # to get the specific id for the grids I need to generate the full set ( 50,10,2,1)
    # filter and generate to new area 50k
    t1 <- buildSubGrids(grids = g1, cell_size = 50000, aoi = g1)[pointFeature, ]
    # filter and generate to new area 10k
    t2 <- buildSubGrids(grids = t1, cell_size = 10000, aoi = t1)[pointFeature, ]
    # filter and generate to new area 2k
    t3 <- buildSubGrids(grids = t2, cell_size = 2000, aoi = t2)[pointFeature, ]
    # generate 1km grids
    t4 <- buildSubGrids(grids = t3, cell_size = 1000, aoi = t3)[pointFeature, ]
    # export the 1km grid feature
    return(t4)
  }

  if (!isFALSE(id)) {
    # message("Grabing aoi based on ID")
    # parse out the id to the specific geographies
    feat_names <- c("id100", "id50", "id10", "id2", "id1")
    # parse out string and apply names
    ids <- id |>
      stringr::str_split(pattern = "-") |>
      unlist()
    # construct the ids for specific selection
    id100 <- ids[1]
    id50 <- paste(id100, ids[2], sep = "-")
    id10 <- paste(id50, ids[3], sep = "-")
    id2 <- paste(id10, ids[4], sep = "-")
    id1 <- paste(id2, ids[5], sep = "-")

    # select 100k grid
    g1 <- grid100 |>
      dplyr::filter(id == id100)
    # build the 50k grids
    t1 <- buildSubGrids(grids = g1, cell_size = 50000, aoi = g1) |>
      dplyr::filter(id == id50)
    # build the 10k grids
    t2 <- buildSubGrids(grids = t1, cell_size = 10000, aoi = t1) |>
      dplyr::filter(id == id10)
    # build the 50k grids
    t3 <- buildSubGrids(grids = t2, cell_size = 2000, aoi = t2) |>
      dplyr::filter(id == id2)
    # build the 50k grids
    t4 <- buildSubGrids(grids = t3, cell_size = 1000, aoi = t3) |>
      dplyr::filter(id == id1)
    #export feature
    return(t4)
  }
  # error test if nothing was added to the function
  if (isFALSE(point) | isFALSE(id)) {
    message(
      "No input provided. Please provide a value for either the point or id object"
    )
  }
}
