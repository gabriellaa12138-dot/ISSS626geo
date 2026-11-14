# Restore the frozen source snapshots without contacting the data services.
th3_restore_inputs <- function(root = "data/takehome3") {
  manifests <- do.call(rbind, lapply(c("public_download_manifest.csv", "ridership_manifest.csv"),
    function(name) {
      manifest <- read.csv(file.path(root, name), stringsAsFactors = FALSE)
      manifest[, c("file", "md5")]
    }))
  restore_one <- function(path, checksum) {
    if (!file.exists(path) && file.exists(paste0(path, ".gz"))) {
      dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
      input <- gzfile(paste0(path, ".gz"), "rb")
      on.exit(close(input), add = TRUE)
      temporary <- paste0(path, ".partial")
      on.exit(unlink(temporary), add = TRUE)
      output <- file(temporary, "wb")
      tryCatch({
        repeat {
          bytes <- readBin(input, "raw", n = 1024L * 1024L)
          if (!length(bytes)) break
          writeBin(bytes, output)
        }
      }, finally = close(output))
      stopifnot(identical(unname(tools::md5sum(temporary)), checksum))
      stopifnot(file.rename(temporary, path))
    }
    stopifnot(file.exists(path), identical(unname(tools::md5sum(path)), checksum))
  }
  for (i in seq_len(nrow(manifests))) {
    restore_one(file.path(root, manifests$file[i]), manifests$md5[i])
  }
  invisible(TRUE)
}
