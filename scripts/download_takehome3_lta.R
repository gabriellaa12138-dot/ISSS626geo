# Run in RStudio: source("scripts/download_takehome3_lta.R"); download_takehome3_lta()
# Credentials are requested in a masked dialog and are never saved.
download_takehome3_lta <- function(months = c("202610", "202609", "202608"),
                                  key = NULL,
                                  root = "data/takehome3") {
  stopifnot(all(grepl("^[0-9]{6}$", months)), !anyDuplicated(months))
  on.exit({ key <- NULL }, add = TRUE)
  dir.create(file.path(root, "raw", "ridership"), recursive = TRUE, showWarnings = FALSE)
  dir.create(file.path(root, "archives"), recursive = TRUE, showWarnings = FALSE)
  manifest_file <- file.path(root, "ridership_manifest.csv")
  manifest <- if (file.exists(manifest_file)) {
    read.csv(manifest_file, stringsAsFactors = FALSE, colClasses = "character")
  } else NULL
  datasets <- c(station_volume = "Train", origin_destination = "ODTrain")

  for (month in months) {
    for (kind in names(datasets)) {
      if (!is.null(manifest)) {
        old <- manifest[manifest$dataset == kind & manifest$requested_month == month, ]
        if (nrow(old) == 1L && file.exists(file.path(root, old$file)) &&
            identical(unname(tools::md5sum(file.path(root, old$file))), old$md5)) {
          message("Kept verified local data: ", kind, " ", month)
          next
        }
      }
      if (is.null(key)) {
        if (!rstudioapi::isAvailable()) stop("Run from RStudio for the secure API key dialog.")
        key <- rstudioapi::askForPassword("LTA DataMall API AccountKey (not SDK; not saved)")
      }
      if (is.null(key) || !nzchar(trimws(key))) stop("No API key was supplied.")
      key <- trimws(key)
      endpoint <- paste0("https://datamall2.mytransport.sg/ltaodataservice/PV/", datasets[[kind]])
      request <- httr2::request(endpoint) |>
        httr2::req_url_query(Date = month) |>
        httr2::req_headers(AccountKey = key, Accept = "application/json") |>
        httr2::req_timeout(90) |>
        httr2::req_error(is_error = function(resp) FALSE)
      response <- tryCatch(httr2::req_perform(request), error = function(e) NULL)
      request <- NULL
      if (is.null(response)) stop("LTA connection failed. No credential was logged.")
      status <- httr2::resp_status(response)
      if (status %in% c(401L, 403L)) stop("LTA rejected the API key (HTTP ", status, ").")
      if (status != 200L) stop("LTA API returned HTTP ", status, " for ", kind, " ", month)
      result <- httr2::resp_body_json(response, simplifyVector = TRUE)
      response <- NULL
      link <- result$value$Link
      if (length(link) != 1L || is.na(link) || !nzchar(link)) {
        stop("LTA did not provide a download for ", kind, " ", month,
             ". Check the available three-month window.")
      }
      parsed <- httr2::url_parse(link)
      if (parsed$scheme != "https" ||
          !grepl("(^|\\.)amazonaws\\.com$", parsed$hostname)) {
        stop("Unexpected download host; file was not downloaded.")
      }
      archive <- file.path(root, "archives", paste0(kind, "_", month, ".zip"))
      temporary <- paste0(archive, ".partial")
      # A fresh request prevents forwarding the AccountKey to the download host.
      download <- tryCatch(
        httr2::request(link) |>
          httr2::req_timeout(300) |>
          httr2::req_error(is_error = function(resp) FALSE) |>
          httr2::req_perform(path = temporary),
        error = function(e) NULL
      )
      link <- result <- parsed <- NULL
      if (is.null(download) || httr2::resp_status(download) != 200L) {
        unlink(temporary)
        stop("File download failed for ", kind, " ", month, "; signed URL not logged.")
      }
      download <- NULL
      members <- utils::unzip(temporary, list = TRUE)$Name
      if (any(grepl("(^[/\\\\]|(^|[/\\\\])\\.\\.([/\\\\]|$))", members))) {
        unlink(temporary)
        stop("Unsafe archive member path.")
      }
      csv_member <- members[grepl("\\.csv$", members, ignore.case = TRUE)]
      if (length(csv_member) != 1L) stop("Expected one CSV in the LTA archive.")
      extraction <- tempfile("lta-extract-")
      dir.create(extraction)
      utils::unzip(temporary, files = csv_member, exdir = extraction)
      table <- data.table::fread(file.path(extraction, csv_member), showProgress = FALSE)
      required <- if (kind == "station_volume") {
        c("YEAR_MONTH", "DAY_TYPE", "TIME_PER_HOUR", "PT_TYPE", "PT_CODE",
          "TOTAL_TAP_IN_VOLUME", "TOTAL_TAP_OUT_VOLUME")
      } else {
        c("YEAR_MONTH", "DAY_TYPE", "TIME_PER_HOUR", "PT_TYPE",
          "ORIGIN_PT_CODE", "DESTINATION_PT_CODE", "TOTAL_TRIPS")
      }
      expected_month <- paste0(substr(month, 1, 4), "-", substr(month, 5, 6))
      stopifnot(nrow(table) > 0L, all(required %in% names(table)),
                !anyNA(table[, ..required]),
                identical(unique(as.character(table$YEAR_MONTH)), expected_month),
                all(table$PT_TYPE == "TRAIN"),
                all(table$TIME_PER_HOUR %in% 0:23))
      measures <- grep("^TOTAL_", required, value = TRUE)
      stopifnot(all(vapply(table[, ..measures], function(x) all(is.finite(x) & x >= 0), logical(1))))
      ids <- setdiff(required, measures)
      stopifnot(!anyDuplicated(table[, ..ids]))
      destination <- file.path(root, "raw", "ridership", basename(csv_member))
      stopifnot(file.copy(file.path(extraction, csv_member), destination, overwrite = TRUE))
      stopifnot(file.rename(temporary, archive))
      unlink(extraction, recursive = TRUE)
      record <- data.frame(
        dataset = kind, month = expected_month,
        file = file.path("raw", "ridership", basename(destination)),
        rows = nrow(table), columns = ncol(table),
        bytes = file.info(destination)$size,
        md5 = unname(tools::md5sum(destination)),
        source = endpoint, requested_month = month,
        retrieved_at = format(Sys.time(), tz = "Asia/Singapore", usetz = TRUE),
        stringsAsFactors = FALSE
      )
      if (!is.null(manifest)) manifest <- manifest[!(manifest$dataset == kind & manifest$month == expected_month), ]
      manifest <- rbind(manifest, record)
      write.csv(manifest, manifest_file, row.names = FALSE)
      message("Verified ", kind, " ", expected_month, ": ", nrow(table), " rows; ",
              format(file.info(destination)$size, big.mark = ","), " bytes.")
      rm(table)
      Sys.sleep(1)
    }
  }
  invisible(manifest)
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  if (!identical(args, "--stdin-key")) stop("Use RStudio, or the secure stdin launcher.")
  input <- file("stdin", open = "r")
  key <- readLines(input, n = 1L, warn = FALSE)
  close(input)
  tryCatch(download_takehome3_lta(key = key), finally = { key <- NULL })
}
