library(ggplot2)
library(patchwork)

th3_theme <- function(size = 12) {
  theme_minimal(base_size = size) + theme(panel.grid.minor = element_blank(),
    plot.title = element_text(face = "bold", size = size + 1),
    plot.subtitle = element_text(size = size - 1), legend.position = "bottom",
    plot.margin = margin(8, 10, 8, 10))
}

th3_map_base <- function(r) {
  ggplot() + geom_sf(data = st_union(r$data$land), fill = "#f0f3f2",
    color = "#bec7c2", linewidth = 0.2) + coord_sf(datum = NA) +
    th3_theme() + theme(panel.grid = element_blank(), axis.title = element_blank(),
      axis.text = element_blank(), axis.ticks = element_blank())
}

th3_plot_study <- function(r) {
  x <- r$data$expanded
  th3_map_base(r) + geom_point(data = x, aes(x, y, color = scenario_group, shape = scenario_group), size = 2) +
    scale_color_manual(values = c("Existing" = "#6d7773", "Existing interchange upgraded" = "#b03b65",
      "JRL original 24" = "#16806b", "CRL Phase 1" = "#cc821b")) +
    scale_shape_manual(values = c("Existing" = 16, "Existing interchange upgraded" = 8,
      "JRL original 24" = 17, "CRL Phase 1" = 15)) + labs(color = NULL, shape = NULL)
}

th3_plot_observed <- function(r) {
  hourly <- copy(r$data$hourly)
  hourly[, share := trips / sum(trips), by = .(YEAR_MONTH, DAY_TYPE)]
  p1 <- ggplot(hourly[DAY_TYPE == "WEEKDAY"], aes(TIME_PER_HOUR, share, color = YEAR_MONTH)) +
    geom_line(linewidth = 1) + scale_y_continuous(labels = scales::label_percent()) +
    scale_color_manual(values = c("#16806b", "#cc821b", "#b03b65")) +
    labs(title = "Weekday departure profile", x = "Hour", y = "Share of trips", color = "Month") + th3_theme()
  arrivals <- r$data$train[, .(arrivals = sum(trips)), by = destination_id]
  arrivals[, station_name := r$data$stations$station_name[match(destination_id, r$data$stations$station_id)]]
  p2 <- ggplot(arrivals[order(-arrivals)][1:10], aes(arrivals, reorder(station_name, arrivals))) +
    geom_col(fill = "#16806b", width = 0.7) + scale_x_continuous(labels = scales::label_number(scale = 1e-6, suffix = "m")) +
    labs(title = "Largest August destinations", x = "Monthly weekday arrivals", y = NULL) + th3_theme()
  p1 + p2
}

th3_plot_validation <- function(r) {
  score <- r$models$metrics[period == "October test"]
  p1 <- ggplot(score, aes(station_WAPE, reorder(model, -station_WAPE))) +
    geom_col(fill = "#16806b", width = 0.65) +
    geom_text(aes(label = scales::percent(station_WAPE, accuracy = 0.1)), hjust = -0.1, size = 3.8) +
    scale_x_continuous(labels = scales::label_percent(), limits = c(0, 0.94)) +
    labs(title = "October station error", x = "WAPE", y = NULL) + th3_theme()
  p2 <- ggplot(r$models$test_stations, aes(observed, predicted)) +
    geom_abline(slope = 1, intercept = 0, color = "#b03b65") +
    geom_point(color = "#16806b", alpha = 0.7) + coord_equal() +
    scale_x_continuous(labels = scales::label_number(scale = 1e-6, suffix = "m")) +
    scale_y_continuous(labels = scales::label_number(scale = 1e-6, suffix = "m")) +
    labs(title = "Selected MCI model", x = "Recorded arrivals", y = "Estimated arrivals") + th3_theme()
  p1 + p2 + plot_layout(widths = c(1.25, 1))
}

th3_plot_scenario <- function(r) {
  x <- r$extensions$scenario$stations
  largest <- max(c(x$baseline, x$future))
  one <- function(column, title) {
    d <- x[get(column) > 0]
    th3_map_base(r) + geom_point(data = d, aes(x, y, size = .data[[column]]), color = "#16806b", alpha = 0.65) +
      scale_size_area(max_size = 7, limits = c(0, largest), breaks = c(4e5, 8e5, 12e5, 16e5),
        labels = scales::label_number(scale = 1e-6, suffix = "m")) +
      labs(title = title, size = "Arrivals")
  }
  change <- th3_map_base(r) + geom_point(data = x, aes(x, y, color = change / 1000, size = abs(change)), alpha = 0.8) +
    scale_size_area(max_size = 7, guide = "none") +
    scale_color_gradient2(low = "#2a6894", mid = "#eeeeee", high = "#b53d5a", midpoint = 0, name = "Change (000)") +
    labs(title = "Change in allocations")
  one("baseline", "184 destination baseline") + one("future", "213 destination scenario") + change +
    plot_layout(guides = "collect") & theme(legend.position = "bottom")
}

th3_plot_impacts <- function(r) {
  x <- r$extensions$scenario$stations
  existing <- unique(rbind(x[new_site == FALSE][order(change)][1:6],
    head(x[new_site == FALSE & change > 0][order(-change)], 6)), by = "station_id")
  p1 <- ggplot(existing, aes(change / 1000, reorder(station_name, change), fill = change > 0)) +
    geom_col(width = 0.7) + scale_fill_manual(values = c("FALSE" = "#2a6894", "TRUE" = "#b53d5a"), guide = "none") +
    labs(title = "Existing station changes", x = "Monthly arrivals change (000)", y = NULL) + th3_theme()
  p2 <- ggplot(x[new_site == TRUE][order(-future)][1:10], aes(future / 1000, reorder(station_name, future))) +
    geom_col(fill = "#16806b", width = 0.7) +
    labs(title = "Largest new site allocations", x = "Monthly arrivals (000)", y = NULL) + th3_theme()
  p1 + p2
}

th3_plot_markets <- function(r) {
  x <- r$extensions$market
  changed <- x[changed == TRUE]
  changed[, future_name := r$data$expanded$station_name[match(preferred_future, r$data$expanded$station_id)]]
  changed[, previous_name := r$data$expanded$station_name[match(preferred_baseline, r$data$expanded$station_id)]]
  p1 <- th3_map_base(r) + geom_point(data = x, aes(x = r$data$origins$x[match(origin_id, r$data$origins$station_id)],
      y = r$data$origins$y[match(origin_id, r$data$origins$station_id)], color = new_share), size = 2.7) +
    scale_color_viridis_c(option = "C", labels = scales::label_percent(), name = "New site share") +
    labs(title = "New sites draw from existing origins")
  p2 <- ggplot(x[order(-new_share)][1:10], aes(new_share, reorder(station_name, new_share))) +
    geom_col(fill = "#cc821b", width = 0.7) + scale_x_continuous(labels = scales::label_percent()) +
    labs(title = "Origins with the largest new site share", x = "Probability assigned to new sites", y = NULL) + th3_theme()
  p1 + p2
}

th3_plot_focus <- function(r) {
  x <- copy(r$extensions$focus)
  coords <- st_coordinates(st_transform(st_as_sf(x, coords = c("longitude", "latitude"), crs = 4326), 3414))
  x[, `:=`(x = coords[, 1], y = coords[, 2])]
  focus <- r$data$stations[station_id == r$extensions$focus_id]
  limit <- max(c(x$baseline_share, x$future_share))
  one <- function(column, title) {
    th3_map_base(r) + geom_point(data = x, aes(x, y, color = .data[[column]]), size = 2.3) +
      geom_point(data = focus, aes(x, y), shape = 8, size = 4, color = "black") +
      scale_color_viridis_c(option = "C", limits = c(0, limit), labels = scales::label_percent(), name = "Choice probability") +
      labs(title = title)
  }
  p3 <- th3_map_base(r) + geom_point(data = x, aes(x, y, color = change_pp), size = 2.3) +
    scale_color_gradient(low = "#2a6894", high = "#e8edf0", name = "Change (pp)") + labs(title = "Change by origin")
  one("baseline_share", "Existing choice set") + one("future_share", "Expanded choice set") + p3 +
    plot_annotation(title = paste("Market of", focus$station_name)) +
    plot_layout(guides = "collect") & theme(legend.position = "bottom")
}

th3_plot_access <- function(r) {
  x <- r$extensions$access
  limit <- max(c(x$before_m, x$after_m))
  one <- function(column, title) {
    th3_map_base(r) + geom_point(data = x, aes(x, y, color = .data[[column]]), size = 0.45, alpha = 0.75) +
      scale_color_viridis_c(option = "C", limits = c(0, limit), name = "Distance (m)") + labs(title = title)
  }
  gain <- th3_map_base(r) + geom_point(data = x[improvement_m <= 1], aes(x, y), color = "#c7ceca", size = 0.4) +
    geom_point(data = x[improvement_m > 1], aes(x, y, color = improvement_m), size = 0.8) +
    scale_color_viridis_c(option = "D", name = "Distance saved (m)") + labs(title = "Nearest distance reduction")
  one("before_m", "Existing station access") + one("after_m", "Expanded station access") + gain +
    plot_layout(guides = "collect") & theme(legend.position = "bottom")
}

th3_plot_access_detail <- function(r) {
  e <- r$extensions
  thresholds <- melt(e$access_summary, id.vars = c("radius_m", "newly_covered", "total_buildings"),
    measure.vars = c("baseline", "expanded"), variable.name = "network", value.name = "buildings")
  p1 <- ggplot(thresholds, aes(factor(radius_m), buildings / total_buildings, fill = network)) +
    geom_col(position = "dodge", width = 0.65) +
    scale_y_continuous(labels = scales::label_percent(), limits = c(0, 1)) +
    scale_fill_manual(values = c("baseline" = "#94a39c", "expanded" = "#16806b")) +
    labs(title = "Coverage at three distance thresholds", x = "Straight line threshold (m)", y = "HDB building share", fill = NULL) + th3_theme()
  x <- e$access_stations
  label <- unique(rbind(x[order(-newly_covered)][1:3], x[order(-future)][1:2]), by = "station_id")
  p2 <- ggplot(x, aes(newly_covered, future / 1000)) + geom_point(size = 2.3, color = "#cc821b") +
    ggrepel::geom_text_repel(data = label, aes(label = station_name), size = 3.4, seed = 14, max.overlaps = Inf) +
    labs(title = "Access gains and arrivals differ", x = "Newly covered HDB buildings (800 m)", y = "Scenario arrivals (000)") + th3_theme()
  p1 + p2
}

th3_plot_sensitivity <- function(r) {
  e <- r$extensions
  p1 <- ggplot(e$sensitivity, aes(new_share, reorder(assumption, new_share))) +
    geom_col(fill = "#16806b", width = 0.65) +
    scale_x_continuous(labels = scales::label_percent()) +
    labs(title = "Share assigned to new sites", x = "Share of fixed demand", y = NULL) + th3_theme()
  top <- e$new_ranges[order(-main)][1:10]
  p2 <- ggplot(top, aes(main / 1000, reorder(station_name, main))) +
    geom_segment(aes(x = low / 1000, xend = high / 1000, yend = reorder(station_name, main)), color = "#bccac3", linewidth = 2.5) +
    geom_point(color = "#b03b65", size = 2.5) +
    labs(title = "Assumption ranges for new sites", x = "Monthly arrivals (000)", y = NULL) + th3_theme()
  p1 + p2 + plot_layout(widths = c(1.2, 1))
}
