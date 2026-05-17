#!/usr/bin/env bash
# Fetch the ECMWF Open Data IFS 0.25° cycle as a single concatenated GRIB2,
# using the .index sidecar and HTTP Range requests so we only pull the
# surface records we want (~3 MB / step instead of ~140 MB).
# Usage: fetch_ecmwf.sh <YYYY-MM-DD> <HH> <out.grib2>
set -euo pipefail
DATE="${1:?date}"; HOUR="${2:?hour}"; OUT="${3:?out}"
CD="${DATE//-/}"
HH="$HOUR"
BASE="https://data.ecmwf.int/forecasts/${CD}/${HH}z/ifs/0p25/oper"

# 0..72 h every 3 h covers normal sailing horizons. Extend to 240 later if needed.
STEPS=(0 3 6 9 12 15 18 21 24 27 30 33 36 39 42 45 48 54 60 66 72)
WANTED='10u 10v msl 2t 10fg'

: > "$OUT"
for step in "${STEPS[@]}"; do
  stem="${CD}${HH}0000-${step}h-oper-fc"
  idx_url="$BASE/${stem}.index"
  grib_url="$BASE/${stem}.grib2"

  idx=$(curl -fsS --max-time 30 "$idx_url" 2>/dev/null) || { echo "skip +${step}h (no index)"; continue; }

  pairs=$(printf '%s\n' "$idx" | jq -r --arg w "$WANTED" '
    select(.levtype == "sfc") |
    select(.param as $p | ($w | split(" ") | index($p))) |
    select(._length >= 256) |
    "\(._offset) \(._length)"')
  [ -z "$pairs" ] && continue

  while read -r off len; do
    [ -z "$off" ] && continue
    end=$(( off + len - 1 ))
    curl -fsS --max-time 120 --retry 5 --retry-delay 5 --retry-all-errors \
      -H "Range: bytes=${off}-${end}" "$grib_url" >> "$OUT"
    sleep 0.3
  done <<< "$pairs"
done

[ -s "$OUT" ] || { echo "no ECMWF data fetched for ${DATE} ${HH}Z" >&2; exit 1; }
echo "ECMWF cycle bundled into $OUT ($(stat -c%s "$OUT") bytes)"
