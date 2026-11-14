# Take-home 3: data preparation and conditional station choice models.
library(sf)
library(data.table)
library(ggplot2)
source("scripts/takehome3_io.R")

th3_root <- "data/takehome3"
th3_lines <- function(codes) {
  parts <- unique(unlist(strsplit(codes, "[/;+\\-]")))
  prefixes <- gsub("[0-9]", "", parts)
  prefixes[prefixes == "CG"] <- "EW"
  prefixes[prefixes %in% c("SE", "SW", "STC")] <- "SKLRT"
  prefixes[prefixes %in% c("PE", "PW", "PTC")] <- "PGLRT"
  prefixes[prefixes %in% c("JS", "JE", "JW")] <- "JRL"
  length(unique(prefixes))
}

th3_prepare <- function() {
  th3_restore_inputs()
  raw_lookup <- fread(file.path(th3_root, "prepared/observed_station_coordinate_lookup.csv"))
  raw_lookup[, name_key := toupper(trimws(station_name))]
  stations <- raw_lookup[, .(
    station_id = paste(sort(unique(unlist(strsplit(station_id, "[/+-]")))), collapse = "/"),
    station_name = station_name[1], longitude = mean(longitude), latitude = mean(latitude)
  ), by = name_key]
  setorder(stations, station_id)
  crosswalk <- merge(raw_lookup[, .(raw_code = station_id, name_key)],
                     stations[, .(name_key, station_id)], by = "name_key")
  stations[, `:=`(n_lines = vapply(station_id, th3_lines, integer(1)),
                  is_lrt = as.integer(grepl("^(BP|SE|SW|PE|PW|STC|PTC)", station_id) &
                                        !grepl("(NS|EW|NE|DT|TE|CC)", station_id)),
                  scenario_group = "Existing", new_site = FALSE)]
  future <- fread(file.path(th3_root, "prepared/planned_jrl_crl_brief_scope.csv"))
  future[, name_key := toupper(trimws(station_name))]
  future[, existing_id := stations$station_id[match(name_key, stations$name_key)]]
  future[, destination_id := ifelse(is.na(existing_id), paste0("NEW_", station_code), existing_id)]
  additions <- future[is.na(existing_id), .(
    name_key, station_id = destination_id, station_name, longitude = lon, latitude = lat,
    n_lines = 1L, is_lrt = 0L, scenario_group = line, new_site = TRUE)]
  expanded <- rbindlist(list(copy(stations), additions), use.names = TRUE)
  upgraded <- future[!is.na(existing_id), unique(existing_id)]
  expanded[station_id %in% upgraded, n_lines := n_lines + 1L]
  expanded[station_id %in% upgraded, scenario_group := "Existing interchange upgraded"]
  stopifnot(nrow(stations) == 184L, nrow(additions) == 29L, nrow(expanded) == 213L,
            !anyDuplicated(expanded$station_id))
  sites <- st_as_sf(expanded, coords = c("longitude", "latitude"), crs = 4326, remove = FALSE) |>
    st_transform(3414)
  bus_file <- list.files(file.path(th3_root, "raw/spatial/bus_stops"), "\\.shp$", recursive = TRUE, full.names = TRUE)
  bus <- st_read(bus_file, quiet = TRUE) |> st_transform(3414)
  hdb <- st_read(file.path(th3_root, "raw/housing/hdb_existing_buildings.geojson"), quiet = TRUE) |>
    st_transform(3414) |> st_make_valid()
  hdb_points <- suppressWarnings(st_point_on_surface(hdb))
  area <- as.numeric(st_area(hdb))
  hdb_near <- st_is_within_distance(sites, hdb_points, dist = 800)
  expanded[, `:=`(
    bus_800 = lengths(st_is_within_distance(sites, bus, dist = 800)),
    hdb_800 = lengths(hdb_near),
    hdb_footprint_km2 = vapply(hdb_near, function(idx) sum(area[idx]) / 1e6, numeric(1)))]
  expanded[, `:=`(bus_attraction = 1 + bus_800,
                  log_bus = log1p(bus_800), log_lines = log(n_lines),
                  log_hdb = log1p(hdb_footprint_km2 * 100),
                  x = st_coordinates(sites)[, 1], y = st_coordinates(sites)[, 2])]
  baseline <- copy(expanded[new_site == FALSE])
  baseline[match(stations$station_id, station_id), `:=`(
    n_lines = stations$n_lines, log_lines = log(stations$n_lines), scenario_group = "Existing")]
  origins <- copy(baseline)
  origin_sf <- sites[match(origins$station_id, sites$station_id), ]
  distance <- units::drop_units(st_distance(origin_sf, sites)) / 1000
  pairs <- data.table(
    origin_id = rep(origins$station_id, each = nrow(expanded)),
    destination_id = rep(expanded$station_id, times = nrow(origins)),
    distance_km = as.vector(t(distance)))
  pairs <- pairs[origin_id != destination_id]
  pairs[, log_distance := log(pmax(distance_km, 0.1))]
  add_attributes <- function(destinations) {
    attributes <- copy(destinations)
    setnames(attributes, "station_id", "destination_id")
    merge(pairs, attributes, by = "destination_id", sort = FALSE)[order(origin_id, destination_id)]
  }
  existing_pairs <- add_attributes(baseline)
  future_pairs <- add_attributes(expanded)
  stopifnot(nrow(existing_pairs) == 184L * 183L,
            nrow(future_pairs) == 184L * 212L,
            min(existing_pairs$distance_km) > 0)

  counts <- list()
  hourly <- list()
  excluded <- list()
  for (month in c("202608", "202609", "202610")) {
    csv <- file.path(th3_root, "raw/ridership", paste0("origin_destination_train_", month, ".csv"))
    od <- fread(csv, showProgress = FALSE)
    od[, origin_id := crosswalk$station_id[match(ORIGIN_PT_CODE, crosswalk$raw_code)]]
    od[, destination_id := crosswalk$station_id[match(DESTINATION_PT_CODE, crosswalk$raw_code)]]
    stopifnot(!anyNA(od$origin_id), !anyNA(od$destination_id))
    excluded[[month]] <- od[, .(raw_rows = .N, raw_trips = sum(TOTAL_TRIPS),
      same_station_trips = sum(TOTAL_TRIPS[origin_id == destination_id])), by = .(YEAR_MONTH, DAY_TYPE)]
    od <- od[origin_id != destination_id]
    hourly[[month]] <- od[, .(trips = sum(TOTAL_TRIPS)), by = .(YEAR_MONTH, DAY_TYPE, TIME_PER_HOUR)]
    counts[[month]] <- od[, .(trips = sum(TOTAL_TRIPS)), by = .(YEAR_MONTH, DAY_TYPE, origin_id, destination_id)]
  }
  flows <- rbindlist(counts)
  join_observed <- function(month, day = "WEEKDAY") {
    obs <- flows[YEAR_MONTH == month & DAY_TYPE == day, .(origin_id, destination_id, trips)]
    panel <- merge(existing_pairs, obs, by = c("origin_id", "destination_id"), all.x = TRUE, sort = FALSE)
    panel[is.na(trips), trips := 0]
    panel[, market_potential := sum(trips), by = origin_id]
    panel[, observed_share := trips / market_potential]
    panel[order(origin_id, destination_id)]
  }
  train <- join_observed("2026-08")
  valid <- join_observed("2026-09")
  test <- join_observed("2026-10")
  stops <- st_as_sf(baseline, coords = c("longitude", "latitude"), crs = 4326, remove = FALSE) |> st_transform(3414)
  land <- st_read("data/geospatial/master_plan_2019_subzone_no_sea.geojson", quiet = TRUE) |>
    st_transform(3414) |> st_make_valid()
  region <- suppressWarnings(st_join(stops, land[, c("REGION_N", "PLN_AREA_N")], join = st_within))
  baseline[, region := region$REGION_N[match(station_id, region$station_id)]]
  baseline[is.na(region), region := "Outside mapped subzone"]
  output <- file.path(th3_root, "prepared")
  fwrite(crosswalk, file.path(output, "physical_station_crosswalk.csv"))
  fwrite(origins[, .(origin_id = station_id, station_name, longitude, latitude)], file.path(output, "origin_locations.csv"))
  fwrite(train[, .(local_market_potential = unique(market_potential)), by = origin_id],
         file.path(output, "origin_market_august.csv"))
  observed <- train[, .(observed_arrivals = sum(trips)), by = destination_id]
  destinations <- merge(baseline, observed, by.x = "station_id", by.y = "destination_id")
  setnames(destinations, "station_id", "destination_id")
  fwrite(destinations, file.path(output, "destination_attributes_august.csv"))
  fwrite(existing_pairs, file.path(output, "interaction_existing.csv.gz"))
  fwrite(future_pairs, file.path(output, "interaction_expanded.csv.gz"))
  fwrite(rbindlist(excluded), file.path(th3_root, "checks/analysis_exclusions.csv"))
  list(stations = baseline, expanded = expanded, origins = origins, crosswalk = crosswalk,
       future = future, land = land, sites = sites, hdb_points = hdb_points,
       existing_pairs = existing_pairs, future_pairs = future_pairs,
       train = train, valid = valid, test = test, flows = flows, hourly = rbindlist(hourly),
       exclusions = rbindlist(excluded))
}

th3_probabilities <- function(panel, beta) {
  eta <- if (!length(beta)) rep(0, nrow(panel)) else
    as.vector(as.matrix(panel[, names(beta), with = FALSE]) %*% beta)
  result <- copy(panel[, .(origin_id, destination_id)])
  result[, eta := eta]
  result[, score := exp(eta - max(eta)), by = origin_id]
  result[, probability := score / sum(score), by = origin_id]
  stopifnot(all(is.finite(result$probability)), all(result$probability > 0),
            max(abs(result[, sum(probability), by = origin_id]$V1 - 1)) < 1e-10)
  result$probability
}

th3_metrics <- function(panel, probability, model, period) {
  p <- copy(panel[, .(origin_id, destination_id, trips, market_potential)])
  p[, `:=`(probability = probability, estimate = market_potential * probability)]
  station <- p[, .(observed = sum(trips), predicted = sum(estimate)), by = destination_id]
  scores <- data.table(model = model, period = period,
    station_WAPE = sum(abs(station$predicted - station$observed)) / sum(station$observed),
    station_RMSE = sqrt(mean((station$predicted - station$observed)^2)),
    station_R2 = 1 - sum((station$predicted - station$observed)^2) / sum((station$observed - mean(station$observed))^2),
    OD_log_loss = -sum(p$trips * log(p$probability)) / sum(p$trips),
    OD_WAPE = sum(abs(p$estimate - p$trips)) / sum(p$trips),
    total_observed = sum(p$trips), total_predicted = sum(p$estimate))
  station[, `:=`(model = model, period = period)]
  list(scores = scores, station = station, pairs = p)
}

th3_fit_models <- function(data) {
  # Chapter 16.8.6: origin categories constrain the fitted outgoing totals.
  fit_huff <- glm(trips ~ factor(origin_id) + log_distance + log_bus,
                  family = poisson(link = "log"), data = data$train,
                  na.action = na.fail, control = glm.control(maxit = 100))
  fit_mci <- glm(trips ~ factor(origin_id) + log_distance + log_bus +
                   log_lines + log_hdb + is_lrt,
                 family = poisson(link = "log"), data = data$train,
                 na.action = na.fail, control = glm.control(maxit = 100))
  huff_terms <- c("log_distance", "log_bus")
  mci_terms <- c(huff_terms, "log_lines", "log_hdb", "is_lrt")
  stopifnot(fit_huff$converged, fit_mci$converged,
            !anyNA(coef(fit_huff)), !anyNA(coef(fit_mci)))
  betas <- list("Equal choice" = numeric(),
                "Fixed Huff" = c(log_distance = -2, log_bus = 1),
                "Calibrated Huff" = coef(fit_huff)[huff_terms],
                "Extended MCI" = coef(fit_mci)[mci_terms])
  history <- copy(data$train)
  history[, historic_prob := (trips + 0.5) / sum(trips + 0.5), by = origin_id]
  results <- list()
  for (period in c("August calibration", "September validation", "October test")) {
    panel <- switch(period, "August calibration" = data$train,
                    "September validation" = data$valid, "October test" = data$test)
    for (model in names(betas)) {
      results[[paste(period, model)]] <- th3_metrics(panel, th3_probabilities(panel, betas[[model]]), model, period)
    }
    stopifnot(identical(panel$origin_id, history$origin_id), identical(panel$destination_id, history$destination_id))
    results[[paste(period, "Historical OD")]] <- th3_metrics(panel, history$historic_prob, "Historical OD benchmark", period)
  }
  metrics <- rbindlist(lapply(results, `[[`, "scores"))
  station <- rbindlist(lapply(results, `[[`, "station"))
  candidates <- metrics[period == "September validation" & model %in% c("Calibrated Huff", "Extended MCI")]
  selected <- candidates[order(OD_log_loss), model][1]
  fitted_prob <- th3_probabilities(data$train, betas[["Extended MCI"]])
  relative_difference <- max(abs(fitted(fit_mci) - data$train$market_potential * fitted_prob) /
                               pmax(1, fitted(fit_mci)))
  stopifnot(relative_difference < 1e-5)
  coefficients <- rbindlist(lapply(list(Huff = fit_huff, MCI = fit_mci), function(model) {
    slopes <- coef(model)[intersect(names(coef(model)), mci_terms)]
    data.table(term = names(slopes), estimate = unname(slopes))
  }), idcol = "model")
  diagnostics <- rbindlist(lapply(list(Huff = fit_huff, MCI = fit_mci), function(model) {
    data.table(converged = model$converged, iterations = model$iter,
      pearson_dispersion = sum(residuals(model, type = "pearson")^2) / df.residual(model))
  }), idcol = "model")
  destination <- copy(data$stations)
  test_selected <- station[period == "October test" & model == selected]
  destination <- merge(destination, test_selected, by.x = "station_id", by.y = "destination_id")
  destination[, `:=`(error = predicted - observed,
                     relative_error = (predicted - observed) / pmax(1, observed))]
  dir.create(file.path(th3_root, "results"), recursive = TRUE, showWarnings = FALSE)
  fwrite(metrics, file.path(th3_root, "results/model_validation.csv"))
  fwrite(coefficients, file.path(th3_root, "results/model_coefficients.csv"))
  fwrite(diagnostics, file.path(th3_root, "results/model_diagnostics.csv"))
  fwrite(destination, file.path(th3_root, "results/october_station_predictions.csv"))
  list(huff = fit_huff, mci = fit_mci, betas = betas, selected = selected,
       metrics = metrics, station = station, coefficients = coefficients, diagnostics = diagnostics,
       test_stations = destination, poisson_probability_check = relative_difference)
}

th3_run_stage1 <- function() {
  data <- th3_prepare()
  models <- th3_fit_models(data)
  result <- list(data = data, models = models)
  saveRDS(result, file.path(th3_root, "results/stage1_results.rds"), compress = "xz")
  writeLines(capture.output(sessionInfo()), file.path(th3_root, "results/R-session-info.txt"))
  print(models$metrics)
  cat("Selected on September only:", models$selected, "\n")
  invisible(result)
}

if (sys.nframe() == 0L) th3_run_stage1()
