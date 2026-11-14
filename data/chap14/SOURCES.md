# Chapter 14 Source Data

Status on 7 November 2026: ten source datasets were downloaded from data.gov.sg and LTA DataMall. These are raw inputs, not the prepared `mdata.rds` used by the course. No replacement model results have been produced.

## Downloaded Files

The files are in `rawdata/`. Run `Rscript scripts/download_chap14.R` from the project root to retrieve missing files. Existing downloads are kept. The two CSV manifests record official URLs, retrieval dates and MD5 checksums.

| Local file | Publisher and source |
| --- | --- |
| `hdb_resale.csv` | [HDB resale transactions from January 2017 onwards](https://data.gov.sg/datasets/d_8b84c4ee58e3cfc0ece0d773c8ca6abc/view) |
| `hdb_buildings.geojson` | [HDB Existing Building](https://data.gov.sg/datasets/d_16b157c52ed637edd6ba1232e026258d/view) |
| `kindergartens.geojson` | [ECDA Kindergartens](https://data.gov.sg/datasets/d_7fe9a72b1afff18e48111772c8d0fd39/view) |
| `childcare.geojson` | [ECDA Child Care Services](https://data.gov.sg/datasets/d_5d668e3f544335f8028f546827b773b4/view) |
| `hawker_centres.geojson` | [NEA Hawker Centres](https://data.gov.sg/datasets/d_4a086da0a5553be1d89383cd90d07ecd/view) |
| `parks.geojson` | [NParks Parks](https://data.gov.sg/datasets/d_0542d48f0991541706b58059381a6eca/view) |
| `eldercare.geojson` | [MOH Eldercare Services](https://data.gov.sg/datasets/d_f0fd1b3643ed8bd34bd403dedd7c1533/view) |
| `schools.csv` | [MOE General Information of Schools](https://data.gov.sg/datasets/d_688b934f82c1059ed0a6993d2a829089/view) |
| `bus_stops.zip` and extracted shapefile | [LTA DataMall: Bus Stop Location, September 2026](https://datamall.lta.gov.sg/content/datamall/en/static-data.html) |
| `train_stations.zip` and extracted shapefile | [LTA DataMall: Train Station, September 2026](https://datamall.lta.gov.sg/content/datamall/en/static-data.html) |

The project already contains the course's MP14 subzone shapefile under `data/chap13/geospatial/`. That file was not downloaded again.

## What Still Needs Preparation

- HDB transactions have block and street addresses but no coordinates. The extra HDB building layer contains street codes rather than street names, so it is not a direct address join. Do not join on block number alone.
- [OneMap Search](https://www.onemap.gov.sg/apidocs/search) now requires an authorised API token. The unauthenticated request returned an authentication error, so bulk geocoding has not been run. Any token must stay outside the notebook, Git repository and rendered HTML.
- The [SFA Supermarkets collection](https://data.gov.sg/collections/1451/view) currently has no published downloadable dataset. A verified supermarket location file is still needed for `PROX_SUPERMARKET`. Do not fill this predictor with zero or silently remove it from the model.
- The chapter obtains shopping mall names from [Wikipedia](https://en.wikipedia.org/wiki/List_of_shopping_malls_in_Singapore). These still need checking and geocoding for `PROX_MALL`. The CBD reference point also needs an explicit definition.
- School locations must be matched to the MOE primary school records before counting schools within 1 km.
- The chapter does not supply the date and flat type filters used to create its prepared table. Any reconstruction must disclose its own selection and must not claim to reproduce the original sample exactly.
- The raw download contains 244,312 HDB transactions from January 2017 through November 2026. November is incomplete. Facility layers have different reference dates; this limits any historical interpretation.

Only after these checks should the prepared spatial table be saved and the four models executed. The data download alone does not complete Hands-on 10 or verify its numerical results.
