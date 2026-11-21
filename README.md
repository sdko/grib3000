# grib3000

Pre-baked, bbox-subsetted GRIB files for French and Italian coastal sailing
zones. Hosted free on GitHub Actions + Releases — no server, no card, no
API key.

A scheduled workflow runs hourly. For each model (ECMWF, GFS, Arpège,
ICON-EU, ICON-2I, WRF 1.5 km, Arome 0.025°, Arome 0.01°) it:

1. Detects the most-recent *fully* published cycle (with sensible lag
   accounting) by probing the cycle's **last** file or step — every
   upstream publishes its horizon incrementally (Arpège `097H102H`, Arome
   `51H` / `49H51H`, GFS `f240`, ECMWF `240h` / `144h`, ICON-EU `120`).
2. Bails if a release already exists for that cycle.
3. Pulls the native-domain GRIB2 from the upstream open-data endpoint
   (ECMWF/GFS via index + HTTP Range, MF via the OVH S3 mirror, ICON-EU
   from the DWD open-data server, ICON-2I and WRF from MeteoHub). Downloads retry
   on any error and the build hard-fails on a missing file or step rather
   than shipping a truncated horizon.
4. Filters to 10 m wind, gust, MSL pressure and 2 m temperature (plus
   significant wave height for ECMWF, GFS and ICON-EU), runs
   `wgrib2 -small_grib` once per region, then rounds and repacks each cut
   (see [Size and precision](#size-and-precision)). WRF, whose native grid
   is Lambert conformal, is reprojected onto each region's box instead.
5. Publishes two releases:
   - `<model>-<YYYY-MM-DD>-<HH>Z` — dated archive, auto-pruned after 3 days.
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

| id          | source                                                  | grid     | runs (UTC)   | step                     | horizon | regions |
|-------------|---------------------------------------------------------|----------|--------------|--------------------------|---------|---------|
| `ecmwf`     | data.ecmwf.int IFS, index + Range (10u/10v/10fg/msl/2t + wave `swh`) | 0.25°    | 00 06 12 18  | 3 h to 144 h, then 6 h   | 240 h (144 h for 06Z/18Z) | all |
| `ecmwfens`  | ECMWF Open Data ENS (Google Cloud mirror), index + Range, 50 perturbed members, 10 m wind only | 0.25° | 00 06 12 18 | 3 h to 72 h, then 6 h | 144 h | all |
| `gfs`       | NOAA NOMADS, idx + Range (UGRD/VGRD/GUST/PRMSL/TMP + GFS-Wave HTSGW) | 0.25°    | 00 06 12 18  | 3 h to 144 h, then 6 h   | 240 h   | all     |
| `arpege01`  | MF OVH S3, Arpège Europe, SP1 package                   | 0.1°     | 00 06 12 18  | 1 h                      | 102 h   | all     |
| `iconeu`    | DWD open data, ICON-EU regular lat-lon (+ EWAM wave height) | 0.0625°  | 00 06 12 18  | 1 h to 78 h, then 3 h    | 120 h   | all     |
| `icon2i`    | MeteoHub (ItaliaMeteo / ARPAE), ICON-2I 2.2 km          | 0.02° × 0.025° | 00 12  | 1 h                      | 72 h    | `italie-med` |
| `wrf`       | MeteoHub (ItaliaMeteo / CIMA / LaMMA), WRF 1.5 km, wind + gust only | Lambert 1.5 km → 0.015° × 0.02° | 00 12 | 1 h                | 72 h    | `italie-med` |
| `arome0025` | MF OVH S3, Arome W. Europe, SP1                         | 0.025°   | every 3 h    | 1 h                      | 51 h    | med + atl + `italie-med` (partial) |
| `arome001`  | MF OVH S3, Arome W. Europe, SP1                         | 0.01°    | every 3 h    | 1 h                      | 51 h    | med + atl |

`models.json` carries the same facts (`horizon_h`, `regions`,
`partial_regions`) for programmatic discovery.

Coverage notes:

- Arome's native domain is 37.5–55.4 °N, 12 °W–16 °E. It can't cover the
  top of `manche-mer-du-nord` (omitted), and it only covers **part** of
  `italie-med`: the `arome0025` asset for that region is clipped to
  37.5–45 °N, 6–16 °E, so it has **no data for southern Sicily, Malta or
  anything east of 16 °E**. Use `icon2i` (whole region at 2.2 km) or a
  coarser model there. `arome001` is not cut for `italie-med` (too heavy).
- ICON-2I's native domain is 33.7–48.9 °N, 3–22 °E.
- WRF's native grid is Lambert conformal (1399 × 1399 points, 1.5 km,
  roughly 31–49.5 °N, 0–24.5 °E) with grid-relative winds. It is
  reprojected bilinearly to a regular lat-lon grid on the region's bbox
  (`regrid` in `models.json`: 0.02° lon × 0.015° lat) with winds rotated to
  earth-relative. Only 10 m wind and gust are published (pressure and
  temperature are heavy on this grid and every other model has them). The
  run appears on MeteoHub 9–12 h after its reference time.
- ICON-EU and ICON-2I encode the forecast time in minutes, and their gust
  is the maximum over the preceding output step (the +0 h message is a
  degenerate `0-0` interval).

Every asset carries 10 m wind, gust, MSL pressure and 2 m temperature,
with two exceptions: `wrf` is wind + gust only, and at 0.01° Arome ships
**no scalar `GUST` and no `PRMSL`**. Consumers of `arome001` must derive gust magnitude from the
`UGUST`/`VGUST` components and take pressure from another model. (0.025°
Arome ships both forms of gust; the redundant components are dropped.)

### Ensemble (`ecmwfens`)

One asset holds the **50 perturbed members** of the ECMWF ensemble for the
region: 10 m U/V only, ordered by step, then member, U before V. Each
message uses GRIB2 product template 4.1 (individual ensemble forecast);
the member is its perturbation number, 1–50 (`ENS=+N` in wgrib2). A
consumer must read one member at a time — taking every message of a step
as one field mixes the members. The control run is not included: it is
the deterministic run published as `ecmwf`.

Meant for routing the same passage on every member: a tight fan of routes
means the forecast is solid, a wide one shows where it is not.

### Wave height

`ecmwf`, `gfs` and `iconeu` assets also carry significant wave height
(GRIB2 discipline 10, category 0, number 3 — `HTSGW` in wgrib2):

| asset    | wave source                                   | wave grid      | wave steps |
|----------|-----------------------------------------------|----------------|------------|
| `ecmwf`  | IFS wave stream of the same cycle (`swh`)      | 0.25°          | same as wind |
| `gfs`    | GFS-Wave `global.0p25` of the same cycle       | 0.25°          | same as wind |
| `iconeu` | DWD EWAM, latest 00Z/12Z run at or before the cycle | 0.05° × 0.1° | hourly to +78 h of the EWAM run |

Things a consumer must know: the wave messages sit on their **own grid**
(different from the wind grid of the same file, even at equal resolution),
land points are **masked by a bitmap** (undefined values), ECMWF tags the
level as `surface` and EWAM as `mean sea level`, and for `iconeu` 06Z/18Z
cycles the wave messages have an **earlier reference time** than the wind
(valid times are still correct). Waves are fetched best-effort: a missing
wave step is skipped and never fails the build, so an asset can
occasionally have fewer wave steps than wind steps, or none.

Licences: ECMWF Open Data, ICON-2I and WRF (MeteoHub) are CC-BY 4.0, Météo-France is
Etalab Licence Ouverte 2.0, DWD open data requires attribution to
"Deutscher Wetterdienst", GFS is public domain.

## Regions

| id                    | name                                  | bbox (latS,latN,lonW,lonE) |
|-----------------------|---------------------------------------|----------------------------|
| `france-med`          | Méditerranée française + Corse        | 39.5, 44.5, 2.5, 11.0      |
| `italie-med`          | Méditerranée italienne (Gênes, Corse, Sardaigne, Sicile, Malte) | 35.0, 45.0, 6.0, 17.0 |
| `manche-mer-du-nord`  | Manche + Mer du Nord                  | 48.5, 56.0, -6.0, 9.0      |
| `atlantique`          | Atlantique (Gascogne + Bretagne)      | 43.0, 50.0, -10.0, -1.0    |

To add or shift a region: edit `regions.json`, push, and the next
workflow run picks it up. Region IDs become asset filenames; keep them
stable once apps start consuming them.

## Size and precision

`wgrib2 -small_grib` always writes simple packing at the producer's
precision (16–24 bits per value). Each cut is therefore rewritten:

- **Rounding.** Wind, gust and temperature are stored as multiples of
  0.125 (m/s, K): measured max error 0.0625 m/s (0.12 kt). Pressure is
  stored as multiples of 16 Pa (max error 0.08 hPa), wave height as
  multiples of 0.0625 m (measured max error 0.031 m).
- **Packing.** Complex packing with spatial differencing (GRIB2 data
  template 5.3, wgrib2 `c3`), lossless on top of the rounding.

Measured asset sizes for one cycle (all fields, full horizon):

| model       | france-med | italie-med | manche-mer-du-nord | atlantique | before (france-med) |
|-------------|-----------:|-----------:|-------------------:|-----------:|--------------------:|
| `ecmwf`     | 0.30 MB    | 0.61 MB    | 0.54 MB            | 0.36 MB    | 0.12 MB (72 h, no pressure, no waves) |
| `gfs`       | 0.29 MB    | 0.58 MB    | 0.51 MB            | 0.34 MB    | 0.13 MB (72 h, no waves) |
| `arpege01`  | 1.5 MB     | 3.7 MB     | 3.2 MB             | 1.8 MB     | 3.2 MB (72 h)       |
| `iconeu`    | 3.0 MB     | 7.6 MB     | 6.6 MB             | 3.6 MB     | —                   |
| `icon2i`    | —          | 37.1 MB    | —                  | —          | —                   |
| `wrf`       | —          | 40.9 MB    | —                  | —          | —                   |
| `arome0025` | 8.4 MB     | 10.5 MB    | —                  | 10.7 MB    | 37.4 MB             |
| `arome001`  | ≈ 39 MB (estimated from one hourly file: 3.31 → 0.76 MB) | — | — | not measured | 170 MB |

(Measured on the 2026-11-21 00Z/03Z/06Z cycles. "Before" is the asset
published with simple packing at producer precision.)

There is no land masking: a consumer that interpolates bilinearly needs
all four corners of a cell, so masked land would punch holes along every
coast.

## Known limits

- **Cron drift.** Actions' scheduler is best-effort: cycle pickup can be
  5–30 min late. Fine for forecast data.
- **60-day inactivity disables crons.** Any push resets the clock.
- **No SLA.** If a run fails, the app stays on whatever it last cached.
  A failed build publishes nothing, so the next hourly run retries the
  same cycle.
- **NOMADS rate cap.** NOMADS blocks IPs above ~120 hits/minute, so the
  GFS fetch paces itself (~10 min per cycle). Don't parallelise it.
- **Cost shape: regions are cheap, models are expensive.** Adding a region
  is one more `wgrib2` call; adding a model is a whole new fetcher.

## Local dry-run

```sh
# Needs wgrib2 + jq + curl on PATH.
# (WRF additionally needs a wgrib2 built with IPOLATES for -new_grid;
# the conda-forge build has it.)
bash scripts/build_cycle.sh ecmwf 2026-05-17 12
bash scripts/build_cycle.sh gfs   2026-05-17 12
ls dist/ecmwf/ dist/gfs/

# Or with docker, mirroring the CI environment (micromamba + conda-forge):
printf 'FROM mambaorg/micromamba:latest\nRUN micromamba install -y -n base -c conda-forge wgrib2 jq curl bzip2\n' \
  | docker build -t wgrib2-local -
docker run --rm -u $(id -u):$(id -g) -v "$PWD":/w -w /w wgrib2-local \
  bash -c 'eval $(bash scripts/detect_cycle.sh icon2i) && bash scripts/build_cycle.sh icon2i $date $hour'
```

## First-time deploy

```sh
# From this directory, with the gh CLI authenticated (gh auth login):
bash deploy.sh <your-github-handle-or-org>
```

The script initializes git, creates a public repo named `grib3000`, pushes
`main`, and kicks off the first workflow run. After that the hourly cron
takes over.


