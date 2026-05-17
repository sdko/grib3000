# grib3000

Pre-baked, bbox-subsetted GRIB files for French coastal sailing zones.
Hosted free on GitHub Actions + Releases — no server, no card, no API key.

A scheduled workflow runs hourly. For each model (ECMWF, GFS, Arpège,
Arome 0.025°, Arome 0.01°) it:

1. Detects the most-recent published cycle (with sensible lag accounting).
2. Bails if a release already exists for that cycle.
3. Pulls the native-domain GRIB2 from the upstream open-data endpoint
   (ECMWF/GFS via index + HTTP Range, MF via the OVH S3 mirror).
4. Runs `wgrib2 -small_grib` once per region.
5. Publishes two releases:
   - `<model>-<YYYY-MM-DD>-<HH>Z` — dated archive, auto-pruned after 7 days.
   - `<model>-latest` — rolling pointer the app reads.

## URLs the app consumes

- Regions (static): `https://raw.githubusercontent.com/<owner>/grib3000/main/regions.json`
- Models (static): `https://raw.githubusercontent.com/<owner>/grib3000/main/models.json`
- Latest GRIB: `https://github.com/<owner>/grib3000/releases/download/<model>-latest/<region>.grib2`
- Dated GRIB: `https://github.com/<owner>/grib3000/releases/download/<model>-<date>-<hh>Z/<region>.grib2`

The pair `(regions.json, models.json)` is the discovery route — fetch both,
cross-reference `models[m].regions[]` with `regions[r].bbox`, and you have
every URL you can pull.

## Models

| id          | source                                               | step | horizon | regions |
|-------------|------------------------------------------------------|------|---------|---------|
| `ecmwf`     | data.ecmwf.int 0.25° IFS, surface (10u/10v/10fg)        | 3 h  | 72 h    | all     |
| `gfs`       | NOAA NOMADS 0.25°, surface (UGRD/VGRD/GUST)             | 3 h  | 72 h    | all     |
| `arpege01`  | MF OVH S3, Arpège 0.1° Europe, SP1 package           | 1 h  | 48 h    | all     |
| `arome0025` | MF OVH S3, Arome 0.025° W. Europe, HP1               | 1 h  | 51 h    | med + atl |
| `arome001`  | MF OVH S3, Arome 0.01° W. Europe, HP1                | 1 h  | 51 h    | med + atl |

Arome's native domain stops at ~55.4 °N, so it can't cover the top of
`manche-mer-du-nord` — handled by omitting that region from its
`models.json` entry.

## Regions

| id                    | name                                  | bbox (latS,latN,lonW,lonE) |
|-----------------------|---------------------------------------|----------------------------|
| `france-med`          | Méditerranée française + Corse        | 39.5, 44.5, 2.5, 11.0      |
| `manche-mer-du-nord`  | Manche + Mer du Nord                  | 48.5, 56.0, -6.0, 9.0      |
| `atlantique`          | Atlantique (Gascogne + Bretagne)      | 43.0, 50.0, -10.0, -1.0    |

To add or shift a region: edit `regions.json`, push, and the next
workflow run picks it up. Region IDs become asset filenames; keep them
stable once apps start consuming them.

## Known limits

- **Cron drift.** Actions' scheduler is best-effort: cycle pickup can be
  5–30 min late. Fine for forecast data.
- **60-day inactivity disables crons.** Any push resets the clock.
- **No SLA.** If a run fails, the app stays on whatever it last cached.
- **Cost shape: regions are cheap, models are expensive.** Adding a region
  is one more `wgrib2` call; adding a model is a whole new fetcher.

## Local dry-run

```sh
# Needs wgrib2 + jq + curl on PATH.
bash scripts/build_cycle.sh ecmwf 2026-05-17 12
bash scripts/build_cycle.sh gfs   2026-05-17 12
ls dist/ecmwf/ dist/gfs/
```

## First-time deploy

```sh
# From this directory, with the gh CLI authenticated (gh auth login):
bash deploy.sh <your-github-handle-or-org>
```

The script initializes git, creates a public repo named `grib3000`, pushes
`main`, and kicks off the first workflow run. After that the hourly cron
takes over.
