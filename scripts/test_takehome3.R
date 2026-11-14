# Synthetic values in this file are unit tests only, never analysis inputs.
source("scripts/takehome3_analysis.R")

test_pairs <- CJ(origin_id = c("A", "B"), destination_id = c("X", "Y", "Z"))
test_pairs[, `:=`(bus_attraction = c(2, 3, 4, 2, 3, 4),
                  distance_km = c(1, 3, 6, 2, 4, 1))]
test_pairs[, `:=`(log_bus = log(bus_attraction), log_distance = log(distance_km))]
uniform <- th3_probabilities(test_pairs, numeric())
stopifnot(max(abs(uniform - 1 / 3)) < 1e-12)
beta <- c(log_bus = 0.6, log_distance = -0.8)
ours <- th3_probabilities(test_pairs, beta)
huff_input <- as.data.frame(test_pairs[, .(origin_id, destination_id, bus_attraction, distance_km)])
package_result <- MCI::huff.shares(huff_input, "origin_id", "destination_id",
                                  "bus_attraction", "distance_km", gamma = 0.6, lambda = -0.8)
package_result <- as.data.table(package_result)[order(origin_id, destination_id)]
stopifnot(max(abs(ours - package_result$p_ij)) < 1e-10)
stopifnot(identical(th3_lines("CG1/DT35"), 2L), identical(th3_lines("JS1/JE1/JW1"), 1L))

test_root <- tempfile("th3-roundtrip-")
dir.create(test_root)
test_file <- file.path(test_root, "input.csv")
connection <- gzfile(paste0(test_file, ".gz"), "wb")
writeBin(charToRaw("a,b\n1,2\n"), connection)
close(connection)
reference <- tempfile()
writeBin(charToRaw("a,b\n1,2\n"), reference)
manifest <- data.table(file = "input.csv", md5 = unname(tools::md5sum(reference)))
fwrite(manifest, file.path(test_root, "public_download_manifest.csv"))
fwrite(manifest, file.path(test_root, "ridership_manifest.csv"))
th3_restore_inputs(test_root)
stopifnot(identical(readBin(test_file, "raw", n = 100), readBin(reference, "raw", n = 100)))
unlink(test_root, recursive = TRUE)
unlink(reference)

results <- readRDS(file.path(th3_root, "results/stage1_results.rds"))
stopifnot(inherits(results$models$huff, "glm"), inherits(results$models$mci, "glm"),
          results$models$huff$converged, results$models$mci$converged,
          all(is.finite(results$models$coefficients$estimate)))
data <- results$data
stopifnot(nrow(data$stations) == 184L, nrow(data$expanded) == 213L,
          !anyDuplicated(data$train[, .(origin_id, destination_id)]),
          !any(data$train$origin_id == data$train$destination_id),
          all(data$train$distance_km > 0),
          all(data$train$trips >= 0), !anyNA(data$train$trips))
stopifnot(identical(data$train$origin_id, data$test$origin_id),
          identical(data$train$destination_id, data$test$destination_id))
scores <- results$models$metrics
expected <- scores[period == "September validation" & model %in% c("Calibrated Huff", "Extended MCI")][order(OD_log_loss), model][1]
stopifnot(identical(expected, results$models$selected),
          max(abs(scores$total_observed - scores$total_predicted)) < 1e-5,
          results$models$poisson_probability_check < 1e-5)
cat("PASS: Huff package agreement, probability sums, code grouping, gzip round trip,\n",
    "physical station identities, panel alignment, September-only selection and mass conservation.\n")
