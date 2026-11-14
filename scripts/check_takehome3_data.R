library(data.table)
library(sf)
source("scripts/takehome3_io.R")

root <- "data/takehome3"
th3_restore_inputs(root)
dir.create(file.path(root, "checks"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(root, "prepared"), recursive = TRUE, showWarnings = FALSE)
public <- read.csv(file.path(root, "public_download_manifest.csv"))
passengers <- read.csv(file.path(root, "ridership_manifest.csv"))
for (manifest in list(public, passengers)) {
  paths <- file.path(root, manifest$file)
  stopifnot(all(file.exists(paths)), all(unname(tools::md5sum(paths)) == manifest$md5))
}

volumes <- list()
audits <- list()
reconciliation <- list()
for (month in sort(unique(passengers$month))) {
  node_file <- passengers$file[passengers$month == month & passengers$dataset == "station_volume"]
  od_file <- passengers$file[passengers$month == month & passengers$dataset == "origin_destination"]
  stopifnot(length(node_file) == 1L, length(od_file) == 1L)
  node <- fread(file.path(root, node_file), showProgress = FALSE)
  od <- fread(file.path(root, od_file), showProgress = FALSE)
  node_keys <- c("YEAR_MONTH", "DAY_TYPE", "TIME_PER_HOUR", "PT_TYPE", "PT_CODE")
  od_keys <- c("YEAR_MONTH", "DAY_TYPE", "TIME_PER_HOUR", "PT_TYPE", "ORIGIN_PT_CODE", "DESTINATION_PT_CODE")
  stopifnot(!anyNA(node), !anyNA(od), !anyDuplicated(node[, ..node_keys]),
            !anyDuplicated(od[, ..od_keys]), all(node$TIME_PER_HOUR %in% 0:23),
            all(od$TIME_PER_HOUR %in% 0:23), all(node$TOTAL_TAP_IN_VOLUME >= 0),
            all(node$TOTAL_TAP_OUT_VOLUME >= 0), all(od$TOTAL_TRIPS >= 0))
  audits[[month]] <- data.table(
    month = month, station_rows = nrow(node), od_rows = nrow(od),
    station_codes = uniqueN(node$PT_CODE), od_origins = uniqueN(od$ORIGIN_PT_CODE),
    od_destinations = uniqueN(od$DESTINATION_PT_CODE),
    missing_cells = sum(is.na(node)) + sum(is.na(od)), duplicate_keys = 0L,
    negative_volumes = 0L
  )
  totals <- node[, .(tap_in = sum(TOTAL_TAP_IN_VOLUME), tap_out = sum(TOTAL_TAP_OUT_VOLUME)),
                 by = .(YEAR_MONTH, DAY_TYPE, PT_CODE)]
  volumes[[month]] <- totals
  outgoing <- od[, .(od_origin_total = sum(TOTAL_TRIPS)), by = .(YEAR_MONTH, DAY_TYPE, ORIGIN_PT_CODE)]
  setnames(outgoing, "ORIGIN_PT_CODE", "PT_CODE")
  incoming <- od[, .(od_destination_total = sum(TOTAL_TRIPS)), by = .(YEAR_MONTH, DAY_TYPE, DESTINATION_PT_CODE)]
  setnames(incoming, "DESTINATION_PT_CODE", "PT_CODE")
  compare <- merge(merge(totals, outgoing, by = c("YEAR_MONTH", "DAY_TYPE", "PT_CODE"), all = TRUE),
                   incoming, by = c("YEAR_MONTH", "DAY_TYPE", "PT_CODE"), all = TRUE)
  compare[, `:=`(tap_in_minus_od = tap_in - od_origin_total,
                tap_out_minus_od = tap_out - od_destination_total)]
  reconciliation[[month]] <- compare
}
fwrite(rbindlist(audits), file.path(root, "checks/ridership_quality.csv"))
fwrite(rbindlist(reconciliation), file.path(root, "checks/od_station_reconciliation.csv"))
totals <- rbindlist(volumes)
fwrite(totals, file.path(root, "prepared/station_month_daytype_totals.csv"))

operational <- fread(file.path(root, "raw/stations/operational_stations.csv"))
future <- fread(file.path(root, "raw/stations/future_stations.csv"))
coordinates <- rbindlist(list(
  copy(operational)[, coordinate_source_list := "operational"],
  copy(future)[, coordinate_source_list := "future"]
))
stopifnot(!anyDuplicated(coordinates$station_code))
points <- st_as_sf(coordinates, coords = c("lon", "lat"), crs = 4326, remove = FALSE) |>
  st_transform(3414)
coordinates[, `:=`(x = st_coordinates(points)[, 1], y = st_coordinates(points)[, 2])]
station_checks <- lapply(sort(unique(totals$PT_CODE)), function(id) {
  parts <- strsplit(id, "[/+-]")[[1]]
  found <- coordinates[station_code %in% parts]
  names_found <- unique(toupper(trimws(found$station_name)))
  stopifnot(nrow(found) > 0L, length(names_found) == 1L)
  span <- if (nrow(found) > 1L) max(as.matrix(dist(as.matrix(found[, .(x, y)])))) else 0
  data.table(
    station_id = id, station_name = found$station_name[1],
    longitude = mean(found$lon), latitude = mean(found$lat),
    matched_component_codes = paste(found$station_code, collapse = ";"),
    unmatched_component_codes = paste(setdiff(parts, found$station_code), collapse = ";"),
    coordinate_source_list = paste(unique(found$coordinate_source_list), collapse = ";"),
    within_group_coordinate_span_m = span,
    status_evidence = "Observed in LTA ridership; not inferred from the coordinate list label"
  )
})
station_checks <- rbindlist(station_checks)
fwrite(station_checks, file.path(root, "prepared/observed_station_coordinate_lookup.csv"))
fwrite(station_checks[nzchar(unmatched_component_codes) | coordinate_source_list != "operational"],
       file.path(root, "checks/station_code_exceptions.csv"))

# Keep the brief's original 24 JRL and 12 CRL Phase 1 line stations as an explicit scope.
planned_codes <- c(paste0("JS", 1:12), paste0("JE", 1:7), paste0("JW", 1:5), paste0("CR", 2:13))
planned <- copy(future)[match(planned_codes, station_code)]
stopifnot(nrow(planned) == 36L, !anyNA(planned$station_code), !anyDuplicated(planned$station_code))
planned[, line := ifelse(grepl("^CR", station_code), "CRL Phase 1", "JRL original 24")]
planned[, existing_station_name_match := toupper(station_name) %in% toupper(station_checks$station_name)]
fwrite(planned, file.path(root, "prepared/planned_jrl_crl_brief_scope.csv"))

spatial_files <- list(
  train_stations = list.files(file.path(root, "raw/spatial/train_stations"), "\\.shp$", recursive = TRUE, full.names = TRUE),
  bus_stops = list.files(file.path(root, "raw/spatial/bus_stops"), "\\.shp$", recursive = TRUE, full.names = TRUE),
  station_exits = list.files(file.path(root, "raw/spatial/station_exits"), "\\.shp$", recursive = TRUE, full.names = TRUE),
  hdb_buildings = file.path(root, "raw/housing/hdb_existing_buildings.geojson")
)
spatial_audit <- lapply(names(spatial_files), function(name) {
  stopifnot(length(spatial_files[[name]]) == 1L)
  x <- st_read(spatial_files[[name]], quiet = TRUE)
  stopifnot(!is.na(st_crs(x)))
  projected <- st_transform(x, 3414)
  repaired <- st_make_valid(projected)
  stopifnot(all(st_is_valid(repaired)), !any(st_is_empty(repaired)))
  if (name == "hdb_buildings") {
    st_write(repaired, file.path(root, "prepared/hdb_buildings_valid_3414.gpkg"),
             layer = "hdb_buildings", delete_layer = TRUE, quiet = TRUE)
  }
  data.table(layer = name, features = nrow(x), empty = sum(st_is_empty(x)),
             invalid = sum(!st_is_valid(x)), source_crs = st_crs(x)$input,
             transformed_epsg = st_crs(projected)$epsg,
             invalid_after_repair = sum(!st_is_valid(repaired)),
             geometry_types = paste(unique(as.character(st_geometry_type(x))), collapse = ";"))
})
fwrite(rbindlist(spatial_audit), file.path(root, "checks/spatial_quality.csv"))

housing <- fread(file.path(root, "raw/housing/hdb_property_information.csv"))
housing_audit <- data.table(
  records = nrow(housing), residential_records = sum(housing$residential == "Y"),
  nonresidential_records = sum(housing$residential == "N"),
  duplicate_block_street_keys = sum(duplicated(housing[, .(blk_no, street)])),
  missing_dwelling_units = sum(is.na(housing$total_dwelling_units)),
  total_dwelling_units = sum(housing$total_dwelling_units, na.rm = TRUE)
)
fwrite(housing_audit, file.path(root, "checks/housing_quality.csv"))
writeLines(capture.output(sessionInfo()), file.path(root, "checks/R-session-info.txt"))
print(rbindlist(audits))
print(rbindlist(spatial_audit))
cat("Matched observed station IDs:", nrow(station_checks), "\n")
cat("Planned line stations:", nrow(planned), "; existing name matches:",
    sum(planned$existing_station_name_match), "\n")
cat("Largest absolute node/OD total discrepancy:",
    max(abs(rbindlist(reconciliation)$tap_in_minus_od), na.rm = TRUE), "\n")
