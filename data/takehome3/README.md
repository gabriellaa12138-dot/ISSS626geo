# Take-home Exercise 3 Data

Downloaded and checked on 14 November 2026 for the
[Take-home 3 brief](https://isss626-ay2026-27aug.netlify.app/take-home_ex03).
This folder contains the frozen source data, preparation checks, model tables
and the first calibration and validation results. It is the first checkpoint,
not the completed submission.

## Files and Sources

| Input | Location | Source and scope |
| --- | --- | --- |
| Station tap in and tap out volumes | `raw/ridership/transport_node_train_2026MM.csv` | LTA DataMall, August, September and October 2026 |
| Station origin destination trips | `raw/ridership/origin_destination_train_2026MM.csv` | LTA DataMall, the same three months |
| Train station polygons | `raw/spatial/train_stations/` | LTA September 2026 shapefile from the assignment |
| Bus stop locations | `raw/spatial/bus_stops/` | LTA September 2026 shapefile |
| Station exit locations | `raw/spatial/station_exits/` | LTA published archive, internal layer dated July 2026 |
| Official station code table | `raw/spatial/station_codes/` | LTA Train Station Codes and Chinese Names workbook |
| Existing and future station coordinates | `raw/stations/` | The repository linked in the assignment, pinned to commit `9f5972c71db8a529801eee9c527946a45a78e409` |
| HDB building polygons | `raw/housing/hdb_existing_buildings.geojson` | Official data.gov.sg file downloaded on 7 November, reused with an identical checksum |
| HDB building attributes and dwelling counts | `raw/housing/hdb_property_information.csv` | HDB Property Information; 13,392 records, of which 10,817 are residential |

`public_download_manifest.csv` and `ridership_manifest.csv` record source URLs,
file sizes, retrieval dates and MD5 checksums. Temporary signed URLs and API keys
are not saved. The coordinate dataset licence is retained beside its CSV files.

Official source pages:

- [LTA dynamic datasets](https://datamall.lta.gov.sg/content/datamall/en/dynamic-data.html)
- [LTA static datasets](https://datamall.lta.gov.sg/content/datamall/en/static-data.html)
- [LTA API documentation](https://datamall.lta.gov.sg/content/dam/datamall/datasets/LTA_DataMall_API_User_Guide.pdf)
- [HDB Existing Building](https://data.gov.sg/datasets/d_16b157c52ed637edd6ba1232e026258d/view)
- [HDB Property Information](https://data.gov.sg/datasets/d_17f5382f26140b1fdae0ba2ef6239d2f/view)
- [Assignment station coordinate repository](https://github.com/elliotwutingfeng/singapore_train_station_coordinates)

OSM POIs have not been downloaded. They are a recommended, not mandatory, input
in the brief. No substitute POI observations have been generated.

## Ridership Coverage

| Month | Station volume rows | OD rows | Recorded station IDs |
| --- | ---: | ---: | ---: |
| August 2026 | 7,379 | 906,985 | 185 |
| September 2026 | 7,376 | 887,478 | 185 |
| October 2026 | 7,380 | 910,115 | 185 |

The files contain monthly totals for each day type and hourly time band, not
average daily counts. Do not divide by 30 or treat a weekday total as one day's
ridership. Converting to daily averages requires the correct calendar and public
holiday counts for each month.

No missing cells, duplicate record keys or negative counts were detected in
these six files. Station volume and OD totals do not agree exactly. Their
differences are preserved in `checks/od_station_reconciliation.csv`; the cause
has not been established. Do not average the two measures or present them as
identical. Choose and document one observed ridership definition for calibration.

## Spatial Checks

- The LTA station layer contains **234 polygons**, not 234 independent operating
  station points. Interchange platforms and records must be reconciled before modelling.
- The bus stop layer contains 5,205 points and the exit layer contains 613 points.
- The HDB polygon file has 13,436 features. Four invalid geometries were detected.
  A separate repaired EPSG:3414 layer is saved in
  `prepared/hdb_buildings_valid_3414.gpkg`; the raw file is unchanged.
- The native LTA projection is described by an SVY21 WKT with no numeric EPSG
  identifier. `st_transform()` uses that WKT to transform to EPSG:3414. The CRS
  was not blindly reassigned with `st_set_crs()`.
- HDB polygon street codes differ from the street names in the property table.
  The two files have **not** been joined. Block numbers alone are not unique
  addresses; the different row counts must not be resolved with a row order join.

## Station Identity and Scenario Scope

`prepared/observed_station_coordinate_lookup.csv` retains the 185 exact station
IDs in the LTA ridership files. Compound IDs such as `NS27/CC33/TE20` are split
only for coordinate lookup, never to duplicate their observed ridership.
All 185 IDs have a coordinate match; partial component matches are explicitly listed.

The assignment's coordinate repository was updated in March 2026. Its future
list still includes CC30, CC31 and CC32, although the August to October ridership
files already contain them. Those stations belong in the observed baseline for
these months, not in the JRL/CRL future scenario.

CC33 and CC34 do not appear in the downloaded station code workbook or coordinate
CSV. They occur within composite IDs with known NS27/TE20 and DT16 respectively.
The lookup uses those known components, whose station names agree. It records
the unmatched components rather than silently inventing new station locations.

`prepared/planned_jrl_crl_brief_scope.csv` selects the brief's 24 original JRL
line stations and 12 CRL Phase 1 line stations. Seven names already match
observed stations. These are not 36 additional independent station sites.
The analysis merges Stevens DT10 and TE11 into one physical site, leaving 184
existing destinations. The expanded table adds 29 new sites and increases the
line count at the seven existing interchanges, giving 213 physical destinations.

The full 65-row future coordinate file is also retained. JS2A Forest Hill and
later CRL phases are outside the brief's 24 plus 12 core scenario, not deleted
from the source. No opening year or guaranteed future patronage is inferred
from the coordinate list.

## Running the Checks in RStudio

Open `ISSS626geo.Rproj`, then run:

```r
source("scripts/check_takehome3_data.R")
source("scripts/takehome3_analysis.R")
th3_run_stage1()
source("scripts/test_takehome3.R")
```

Then open `take-home_ex03.qmd` and click Render. It rebuilds the analysis from the
frozen inputs without contacting the API. The first render is not the final
submission: future scenario results and the executive summary are still pending.

The calibration follows Chapter 16.8.6 using base R `glm()` with a Poisson log
link and an origin factor. Chapter 18 supplies the Huff probability structure.
August fits the coefficients, September selects the structural specification,
and October evaluates the fixed model conditional on observed origin totals.
`results/model_validation.csv` includes weak results as well as strong ones;
no performance threshold is imposed by removing difficult stations.

The three large OD CSV files and the HDB GeoJSON are stored as lossless `.gz`
snapshots for Git. `scripts/takehome3_io.R` expands missing originals and checks
their MD5 against the manifests. Keep the `.gz` files. The restored originals,
rebuildable model RDS and repaired HDB GeoPackage are ignored by Git. Unit tests
also check agreement with `MCI::huff.shares()`, conserved origin totals and the
selected validation month.

To retrieve missing LTA files:

```r
source("scripts/download_takehome3_lta.R")
download_takehome3_lta()
```

Already downloaded files are reused only if their checksums match. Missing
files trigger a masked RStudio prompt for the **API AccountKey**, not the SDK
key. Never enter a key as a literal in a script, Console command or `.qmd` file.
The LTA service only exposes a recent three-month window, so retain the verified
CSV snapshots to reproduce this period later.

To refresh public inputs, run `source("scripts/download_takehome3_public.R")`
and then `download_takehome3_public()`. A refresh can change live government
datasets; keep the original manifest and data snapshot when reproducing this run.

For rendering, install `sf`, `data.table`, `units`, `ggplot2`, `patchwork`,
`scales`, `leaflet`, `htmltools`, `knitr`, `rmarkdown` and `MCI` (the last one is
used by the tests). The download scripts additionally use `httr2` and
`rstudioapi` for the masked credential prompt. Quarto and R are required.
Versions are recorded in `checks/R-session-info.txt` and
`results/R-session-info.txt`. Calibration does not require `fixest`.

Downloaded ZIP archives are excluded from Git because extracted files already
contain the inputs. Retain source attribution and check redistribution terms
before publication. The first checkpoint does not yet include future scenario
estimates or executive summary slides.
