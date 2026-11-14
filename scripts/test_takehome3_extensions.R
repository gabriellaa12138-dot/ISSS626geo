source("scripts/takehome3_extensions.R")
r <- th3_load_results()
e <- r$extensions
stopifnot(nrow(e$scenario$stations) == 213L,
          sum(e$scenario$stations$new_site) == 29L,
          uniqueN(e$scenario$expanded$origin_id) == 184L,
          nrow(e$market) == 184L,
          !anyNA(e$scenario$stations$future),
          all(e$scenario$stations$future > 0),
          abs(sum(e$scenario$stations$change)) < 1e-5)
for (panel in list(e$scenario$base, e$scenario$expanded)) {
  totals <- panel[, .(probability = sum(probability), predicted = sum(predicted)), by = origin_id]
  observed <- r$data$test[, .(trips = sum(trips)), by = origin_id]
  joined <- merge(totals, observed, by = "origin_id")
  stopifnot(max(abs(joined$probability - 1)) < 1e-10,
            max(abs(joined$predicted - joined$trips)) < 1e-5)
}
actual_baseline <- r$models$station[model == r$models$selected & period == "October test"]
baseline <- merge(e$scenario$stations[new_site == FALSE], actual_baseline,
  by.x = "station_id", by.y = "destination_id")
stopifnot(max(abs(baseline$baseline - baseline$predicted)) < 1e-5)
stopifnot(nrow(e$access) == nrow(r$data$hdb_points),
          all(e$access$after_m <= e$access$before_m + 1e-6),
          all(e$access_summary$expanded >= e$access_summary$baseline),
          sum(e$access_stations$newly_covered) == e$access_summary[radius_m == 800, newly_covered],
          sum(e$access_regions$newly_covered) == e$access_summary[radius_m == 800, newly_covered])
set.seed(14)
idx <- sample(seq_len(nrow(e$access)), 12)
direct <- st_distance(r$data$hdb_points[idx, ], r$data$sites)
stopifnot(max(abs(apply(units::drop_units(direct), 1, min) - e$access$after_m[idx])) < 1e-6,
          all(e$new_ranges$low <= e$new_ranges$main),
          all(e$new_ranges$main <= e$new_ranges$high),
          all(e$spatial_diagnostics$p_value > 0))
report <- readLines("take-home_ex03.qmd")
slides <- readLines("take-home_ex03_slides.qmd")
stopifnot(!any(grepl("Complete preparation and modelling code|th3-source-code", report)),
          sum(grepl("^## ", slides)) == 11L)
cat("PASS: both choice sets, October baseline agreement, origin conservation,\n",
    "all 213 station estimates, accessibility counts, independent distance checks,\n",
    "sensitivity ranges, removed code appendix and ten content slides plus contents.\n")
