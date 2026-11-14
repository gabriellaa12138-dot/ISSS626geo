# Public inputs specified in the Take-home 3 brief, plus HDB residential attributes.
download_takehome3_public <- function(
    root = "data/takehome3",
    station_revision = "9f5972c71db8a529801eee9c527946a45a78e409") {
  options(timeout = 300)
  dir.create(file.path(root, "raw", "spatial"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(root, "raw", "stations"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(root, "raw", "housing"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(root, "archives"), recursive = TRUE, showWarnings = FALSE)
  records <- list()
  save_record <- function(file, dataset, source, version, retrieved_at = NULL) {
    if (is.null(retrieved_at)) retrieved_at <- format(Sys.time(), tz = "Asia/Singapore", usetz = TRUE)
    records[[length(records) + 1L]] <<- data.frame(
      dataset = dataset, file = file, bytes = file.info(file.path(root, file))$size,
      md5 = unname(tools::md5sum(file.path(root, file))),
      source = source, version = version, retrieved_at = retrieved_at
    )
  }
  fetch <- function(url, file) {
    destination <- file.path(root, file)
    temporary <- paste0(destination, ".partial")
    result <- tryCatch(
      httr2::request(url) |> httr2::req_timeout(300) |>
        httr2::req_perform(path = temporary), error = function(e) NULL
    )
    if (is.null(result)) {
      unlink(temporary)
      stop("Public download failed for ", file, ". No temporary URL was logged.")
    }
    stopifnot(file.info(temporary)$size > 0, file.rename(temporary, destination))
    invisible(destination)
  }
  extract <- function(file, folder) {
    path <- file.path(root, file)
    members <- unzip(path, list = TRUE)$Name
    stopifnot(!any(grepl("(^[/\\\\]|(^|[/\\\\])\\.\\.([/\\\\]|$))", members)))
    unzip(path, exdir = file.path(root, folder))
    invisible(members)
  }

  # Pin the coordinate repository to one commit, rather than a moving branch.
  sha <- station_revision
  stopifnot(grepl("^[0-9a-f]{40}$", sha))
  base <- paste0("https://raw.githubusercontent.com/elliotwutingfeng/singapore_train_station_coordinates/", sha, "/")
  for (name in c("operational_stations.csv", "future_stations.csv", "LICENSE-DATASET.md")) {
    file <- file.path("raw", "stations", name)
    fetch(paste0(base, name), file)
    if (grepl("csv$", name)) {
      x <- read.csv(file.path(root, file))
      stopifnot(all(c("station_code", "station_name", "lat", "lon") %in% names(x)),
                nrow(x) > 0, all(is.finite(x$lat)), all(is.finite(x$lon)))
    }
    save_record(file, name, paste0(base, name), sha)
  }

  lta_base <- "https://datamall.lta.gov.sg/content/dam/datamall/datasets/Geospatial/"
  lta <- data.frame(
    dataset = c("train_stations", "bus_stops", "station_codes", "station_exits"),
    remote = c("TrainStation_Sep2026.zip", "BusStopLocation_Sep2026.zip",
               "Train%20Station%20Codes%20and%20Chinese%20Names.zip", "TrainStationExit.zip"),
    version = c("September 2026", "September 2026", "Current published archive", "Current published archive")
  )
  for (i in seq_len(nrow(lta))) {
    file <- file.path("archives", paste0(lta$dataset[i], ".zip"))
    fetch(paste0(lta_base, lta$remote[i]), file)
    folder <- file.path("raw", "spatial", lta$dataset[i])
    members <- extract(file, folder)
    members <- members[!grepl("/$", members)]
    for (member in members) {
      save_record(file.path(folder, member), lta$dataset[i],
                  paste0(lta_base, lta$remote[i]), lta$version[i])
    }
  }

  building_file <- file.path("raw", "housing", "hdb_existing_buildings.geojson")
  previous <- "data/chap14/rawdata/hdb_buildings.geojson"
  if (file.exists(previous)) {
    stopifnot(file.copy(previous, file.path(root, building_file), overwrite = TRUE),
              tools::md5sum(previous) == tools::md5sum(file.path(root, building_file)))
    retrieved <- "2026-11-07 (verified local official download reused)"
  } else {
    poll <- httr2::request(paste0("https://api-open.data.gov.sg/v1/public/api/datasets/",
                                 "d_16b157c52ed637edd6ba1232e026258d/poll-download")) |>
      httr2::req_perform() |> httr2::resp_body_json()
    stopifnot(poll$code == 0, nzchar(poll$data$url))
    fetch(poll$data$url, building_file)
    retrieved <- format(Sys.time(), tz = "Asia/Singapore", usetz = TRUE)
  }
  save_record(building_file, "HDB Existing Building",
              "https://data.gov.sg/datasets/d_16b157c52ed637edd6ba1232e026258d/view",
              "Official GeoJSON", retrieved)

  dataset <- "d_17f5382f26140b1fdae0ba2ef6239d2f"
  metadata <- httr2::request(paste0("https://api-production.data.gov.sg/v2/public/api/datasets/",
                                    dataset, "/metadata")) |>
    httr2::req_perform() |> httr2::resp_body_json()
  stopifnot(metadata$code == 0)
  base <- paste0("https://api-open.data.gov.sg/v1/public/api/datasets/", dataset)
  initial <- httr2::request(paste0(base, "/initiate-download")) |>
    httr2::req_perform() |> httr2::resp_body_json()
  stopifnot(initial$code == 0)
  poll <- NULL
  for (attempt in seq_len(5)) {
    Sys.sleep(13)
    poll <- httr2::request(paste0(base, "/poll-download")) |>
      httr2::req_perform() |> httr2::resp_body_json()
    if (!is.null(poll$data$url) && nzchar(poll$data$url)) break
  }
  stopifnot(poll$code == 0, !is.null(poll$data$url), nzchar(poll$data$url))
  file <- file.path("raw", "housing", "hdb_property_information.csv")
  fetch(poll$data$url, file)
  x <- data.table::fread(file.path(root, file), showProgress = FALSE)
  stopifnot(nrow(x) > 0, all(c("blk_no", "street", "residential", "total_dwelling_units") %in% names(x)))
  save_record(file, "HDB Property Information",
              paste0("https://data.gov.sg/datasets/", dataset, "/view"),
              paste("Coverage through", metadata$data$coverageEnd,
                    "; metadata updated", metadata$data$lastUpdatedAt))

  manifest <- do.call(rbind, records)
  write.csv(manifest, file.path(root, "public_download_manifest.csv"), row.names = FALSE)
  message("Verified and recorded ", nrow(manifest), " public data files.")
  invisible(manifest)
}

if (sys.nframe() == 0L) download_takehome3_public()
