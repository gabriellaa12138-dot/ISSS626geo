source("scripts/takehome3_analysis.R")

th3_allocate <- function(data, beta, new_multiplier = 1) {
  market <- data$test[, .(market_potential = unique(market_potential)), by = origin_id]
  base <- copy(data$existing_pairs)
  expanded <- copy(data$future_pairs)
  base[, probability := th3_probabilities(base, beta)]
  expanded[, new_score := as.numeric(new_site) * log(new_multiplier)]
  expanded[, probability := th3_probabilities(expanded, c(beta, new_score = 1))]
  base[, predicted := probability * market$market_potential[match(origin_id, market$origin_id)]]
  expanded[, predicted := probability * market$market_potential[match(origin_id, market$origin_id)]]
  base_total <- base[, .(baseline = sum(predicted)), by = destination_id]
  future_total <- expanded[, .(future = sum(predicted)), by = destination_id]
  stations <- merge(copy(data$expanded), future_total, by.x = "station_id", by.y = "destination_id")
  stations <- merge(stations, base_total, by.x = "station_id", by.y = "destination_id", all.x = TRUE)
  stations[is.na(baseline), baseline := 0]
  stations[, `:=`(change = future - baseline,
    change_pct = fifelse(new_site, NA_real_, 100 * (future - baseline) / baseline))]
  stopifnot(abs(sum(stations$future) - sum(market$market_potential)) < 1e-5,
            abs(sum(stations$change)) < 1e-5)
  list(stations = stations, base = base, expanded = expanded)
}

th3_extend <- function(data, models) {
  beta <- models$betas[[models$selected]]
  scenario <- th3_allocate(data, beta)
  market <- scenario$expanded[, .(new_share = sum(probability[new_site]),
    preferred_future = destination_id[which.max(probability)]), by = origin_id]
  previous <- scenario$base[, .(preferred_baseline = destination_id[which.max(probability)]), by = origin_id]
  market <- merge(market, previous, by = "origin_id")
  market <- merge(market, data$origins[, .(origin_id = station_id, station_name, longitude, latitude)], by = "origin_id")
  market[, changed := preferred_future != preferred_baseline]
  focus_id <- scenario$stations[new_site == FALSE][which.min(change), station_id]
  focus <- merge(scenario$base[destination_id == focus_id, .(origin_id, baseline_share = probability)],
    scenario$expanded[destination_id == focus_id, .(origin_id, future_share = probability)], by = "origin_id")
  focus <- merge(focus, market[, .(origin_id, longitude, latitude)], by = "origin_id")
  focus[, change_pp := 100 * (future_share - baseline_share)]

  assumptions <- data.table(
    assumption = c("Main MCI", "Weaker distance decay", "Stronger distance decay",
      "New site attraction x0.5", "New site attraction x1.5", "Calibrated Huff"),
    distance_factor = c(1, 0.75, 1.25, 1, 1, 1), new_multiplier = c(1, 1, 1, 0.5, 1.5, 1))
  sensitivity_sites <- rbindlist(lapply(seq_len(nrow(assumptions)), function(i) {
    b <- if (assumptions$assumption[i] == "Calibrated Huff") models$betas[["Calibrated Huff"]] else beta
    b["log_distance"] <- b["log_distance"] * assumptions$distance_factor[i]
    x <- th3_allocate(data, b, assumptions$new_multiplier[i])$stations
    x[, assumption := assumptions$assumption[i]]
    x
  }))
  sensitivity <- sensitivity_sites[, .(new_share = sum(future[new_site]) / sum(future),
    upgraded_change = sum(change[scenario_group == "Existing interchange upgraded"]),
    largest_new_site = station_name[new_site][which.max(future[new_site])]), by = assumption]
  new_ranges <- sensitivity_sites[new_site & assumption != "Calibrated Huff",
    .(low = min(future), high = max(future)), by = .(station_id, station_name)]
  new_ranges <- merge(new_ranges, scenario$stations[new_site == TRUE, .(station_id, main = future)], by = "station_id")

  # Chapter 17 connection: nearest facility distance and threshold accessibility.
  buildings <- data$hdb_points
  existing <- data$sites[match(data$stations$station_id, data$sites$station_id), ]
  before_id <- st_nearest_feature(buildings, existing)
  after_id <- st_nearest_feature(buildings, data$sites)
  before <- as.numeric(st_distance(buildings, existing[before_id, ], by_element = TRUE))
  after <- as.numeric(st_distance(buildings, data$sites[after_id, ], by_element = TRUE))
  regions <- st_intersects(buildings, data$land)
  region <- vapply(regions, function(x) if (length(x)) data$land$REGION_N[x[1]] else "Outside mapped subzone", character(1))
  access <- data.table(building_id = buildings$OBJECTID, x = st_coordinates(buildings)[, 1],
    y = st_coordinates(buildings)[, 2], region = region, before_m = before, after_m = after,
    improvement_m = pmax(0, before - after), nearest_future = data$sites$station_id[after_id])
  access[, category := fifelse(before_m <= 800, "Already within 800 m",
    fifelse(after_m <= 800, "Newly within 800 m", "Still beyond 800 m"))]
  stopifnot(all(after <= before + 1e-6), !anyNA(access), nrow(access) == nrow(buildings))
  access_summary <- rbindlist(lapply(c(500, 800, 1000), function(r) {
    data.table(radius_m = r, baseline = sum(before <= r), expanded = sum(after <= r),
      newly_covered = sum(before > r & after <= r), total_buildings = length(before))
  }))
  access_regions <- access[, .(buildings = .N, newly_covered = sum(category == "Newly within 800 m"),
    mean_improvement_m = mean(improvement_m), median_before_m = median(before_m),
    median_after_m = median(after_m)), by = region]
  access_stations <- access[category == "Newly within 800 m", .(newly_covered = .N), by = nearest_future]
  access_stations <- merge(scenario$stations[new_site == TRUE], access_stations,
    by.x = "station_id", by.y = "nearest_future", all.x = TRUE)
  access_stations[is.na(newly_covered), newly_covered := 0L]

  # The same residual diagnostic at several neighbourhood sizes avoids one arbitrary k.
  residual <- models$test_stations
  xy <- as.matrix(residual[, .(x, y)])
  residual_value <- log1p(residual$observed) - log1p(residual$predicted)
  spatial_diagnostics <- rbindlist(lapply(c(6L, 8L, 10L), function(k) {
    nb <- spdep::knn2nb(spdep::knearneigh(xy, k = k), sym = TRUE)
    weights <- spdep::nb2listw(nb, style = "W")
    set.seed(20261114)
    mc <- spdep::moran.mc(residual_value, weights, nsim = 999, alternative = "greater")
    data.table(neighbours_k = k, moran_I = unname(mc$statistic), p_value = mc$p.value,
      permutations = 999L)
  }))
  result <- list(scenario = scenario, market = market, focus = focus, focus_id = focus_id,
    assumptions = assumptions, sensitivity = sensitivity, sensitivity_sites = sensitivity_sites,
    new_ranges = new_ranges, access = access, access_summary = access_summary,
    access_regions = access_regions, access_stations = access_stations,
    spatial_diagnostics = spatial_diagnostics)
  out <- file.path(th3_root, "results")
  fwrite(scenario$stations, file.path(out, "future_station_scenario.csv"))
  fwrite(market, file.path(out, "origin_market_changes.csv"))
  fwrite(sensitivity, file.path(out, "scenario_sensitivity.csv"))
  fwrite(new_ranges, file.path(out, "new_station_sensitivity_ranges.csv"))
  fwrite(access, file.path(out, "building_accessibility.csv.gz"))
  fwrite(access_summary, file.path(out, "accessibility_thresholds.csv"))
  fwrite(access_regions, file.path(out, "accessibility_regions.csv"))
  fwrite(access_stations, file.path(out, "station_accessibility_benefits.csv"))
  fwrite(spatial_diagnostics, file.path(out, "residual_moran.csv"))
  result
}

th3_signature <- function() {
  tools::md5sum(c("scripts/takehome3_analysis.R", "scripts/takehome3_extensions.R",
    "scripts/takehome3_io.R", "data/takehome3/public_download_manifest.csv",
    "data/takehome3/ridership_manifest.csv"))
}

th3_save_results <- function(data, models, extensions) {
  # Formula environments and dense QR matrices are unnecessary for plotting the fitted results.
  compact <- function(model) {
    model[c("qr", "data", "model", "y", "weights", "prior.weights")] <- NULL
    environment(model$formula) <- baseenv()
    attr(model$terms, ".Environment") <- baseenv()
    model
  }
  models$huff <- compact(models$huff)
  models$mci <- compact(models$mci)
  result <- list(data = data, models = models, extensions = extensions, signature = th3_signature())
  saveRDS(result, file.path(th3_root, "results/final_results.rds"), compress = "gzip")
  writeLines(capture.output(sessionInfo()), file.path(th3_root, "results/R-session-info.txt"))
  invisible(result)
}

th3_load_results <- function() {
  path <- file.path(th3_root, "results/final_results.rds")
  if (file.exists(path)) {
    result <- readRDS(path)
    if (identical(result$signature, th3_signature())) return(result)
  }
  data <- th3_prepare()
  models <- th3_fit_models(data)
  extensions <- th3_extend(data, models)
  th3_save_results(data, models, extensions)
}
