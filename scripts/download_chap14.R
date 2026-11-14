# Download public source files without storing temporary signed URLs.
library(jsonlite)
options(timeout = 600)

sources <- data.frame(
  name = c("hdb_resale", "hdb_buildings", "kindergartens", "hawker_centres", "schools",
           "parks", "childcare", "eldercare"),
  id = c("d_8b84c4ee58e3cfc0ece0d773c8ca6abc", "d_16b157c52ed637edd6ba1232e026258d",
         "d_7fe9a72b1afff18e48111772c8d0fd39", "d_4a086da0a5553be1d89383cd90d07ecd",
         "d_688b934f82c1059ed0a6993d2a829089", "d_0542d48f0991541706b58059381a6eca",
         "d_5d668e3f544335f8028f546827b773b4", "d_f0fd1b3643ed8bd34bd403dedd7c1533"),
  format = c("csv", "geojson", "geojson", "geojson", "csv", "geojson", "geojson", "geojson")
)
directory <- "data/chap14/rawdata"
dir.create(directory, recursive = TRUE, showWarnings = FALSE)
for (i in seq_len(nrow(sources))) {
  destination <- file.path(directory, paste0(sources$name[i], ".", sources$format[i]))
  if (file.exists(destination) && file.info(destination)$size > 0) next
  base <- paste0("https://api-open.data.gov.sg/v1/public/api/datasets/", sources$id[i])
  if (sources$format[i] == "csv") {
    result <- fromJSON(paste0(base, "/initiate-download"))
    stopifnot(result$code == 0)
    Sys.sleep(13)
  }
  result <- fromJSON(paste0(base, "/poll-download"))
  stopifnot(result$code == 0, !is.null(result$data$url))
  temporary <- paste0(destination, ".partial")
  download.file(result$data$url, temporary, mode = "wb", quiet = TRUE)
  if (sources$format[i] == "csv") {
    stopifnot(ncol(read.csv(temporary, nrows = 1)) > 1)
  } else {
    stopifnot(fromJSON(temporary, simplifyVector = FALSE)$type == "FeatureCollection")
  }
  stopifnot(file.rename(temporary, destination))
  message("Downloaded ", destination, " (", file.info(destination)$size, " bytes)")
  Sys.sleep(13)
}
sources$page <- paste0("https://data.gov.sg/datasets/", sources$id, "/view")
sources$file <- paste0(sources$name, ".", sources$format)
sources$download_date <- as.character(as.Date(
  file.info(file.path(directory, sources$file))$mtime, tz = "Asia/Singapore"))
sources$md5 <- unname(tools::md5sum(file.path(directory, sources$file)))
write.csv(sources, file.path(directory, "download_manifest.csv"), row.names = FALSE)

lta <- data.frame(
  name = c("bus_stops", "train_stations"),
  url = paste0("https://datamall.lta.gov.sg/content/dam/datamall/datasets/Geospatial/",
               c("BusStopLocation_Sep2026.zip", "TrainStation_Sep2026.zip")),
  file = c("bus_stops.zip", "train_stations.zip")
)
for (i in seq_len(nrow(lta))) {
  destination <- file.path(directory, lta$file[i])
  if (!file.exists(destination)) {
    download.file(lta$url[i], destination, mode = "wb", quiet = TRUE)
  }
  contents <- unzip(destination, list = TRUE)$Name
  stopifnot(any(grepl("\\.shp$", contents)), !any(grepl("(^/|(^|/)\\.\\.(/|$))", contents)))
  unzip(destination, exdir = file.path(directory, lta$name[i]))
  message("Downloaded and extracted ", destination)
}
lta$page <- "https://datamall.lta.gov.sg/content/datamall/en/static-data.html"
lta$download_date <- as.character(as.Date(
  file.info(file.path(directory, lta$file))$mtime, tz = "Asia/Singapore"))
lta$md5 <- unname(tools::md5sum(file.path(directory, lta$file)))
write.csv(lta, file.path(directory, "lta_download_manifest.csv"), row.names = FALSE)
