#!/usr/bin/env bash
# Fetch the ECMWF Open Data IFS 0.25° cycle as a single concatenated GRIB2.
# Pulls one full step file at a time (~140 MB each) to stay under ECMWF's
# per-IP request rate limit; the post-fetch wgrib2 -match step in
# build_cycle.sh drops everything but wind/gust/msl/2t, so the released
# asset stays tiny.
# Usage: fetch_ecmwf.sh <YYYY-MM-DD> <HH> <out.grib2>
set -euo pipefail
DATE="${1:?date}"; HOUR="${2:?hour}"; OUT="${3:?out}"
CD="${DATE//-/}"
HH="$HOUR"
BASE="https://data.ecmwf.int/forecasts/${CD}/${HH}z/ifs/0p25/oper"

# 0..72 h every 3 h covers normal sailing horizons.
STEPS=(0 3 6 9 12 15 18 21 24 27 30 33 36 39 42 45 48 54 60 66 72)

: > "$OUT"
for step in "${STEPS[@]}"; do
  stem="${CD}${HH}0000-${step}h-oper-fc"
  grib_url="$BASE/${stem}.grib2"

  if curl -fsS --max-time 300 --retry 5 --retry-delay 10 --retry-all-errors \
       "$grib_url" >> "$OUT"; then
    sleep 1
  else
    echo "skip +${step}h (download failed)"
  fi
done

[ -s "$OUT" ] || { echo "no ECMWF data fetched for ${DATE} ${HH}Z" >&2; exit 1; }
echo "ECMWF cycle bundled into $OUT ($(stat -c%s "$OUT") bytes)"
