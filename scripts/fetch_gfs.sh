#!/usr/bin/env bash
# Fetch the NOAA GFS 0.25° cycle from NOMADS using the .idx sidecar and
# HTTP Range requests, keeping only the surface fields we want.
# Usage: fetch_gfs.sh <YYYY-MM-DD> <HH> <out.grib2>
set -euo pipefail
DATE="${1:?date}"; HOUR="${2:?hour}"; OUT="${3:?out}"
CD="${DATE//-/}"
HH="$HOUR"
BASE="https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod/gfs.${CD}/${HH}/atmos"

# Match ECMWF horizon: 0..72 h every 3 h.
STEPS=(000 003 006 009 012 015 018 021 024 027 030 033 036 039 042 045 048 054 060 066 072)

# GFS idx variable:level lines we want. Pattern is anchored with ":".
WANTED_RE=':(UGRD:10 m above ground|VGRD:10 m above ground|GUST:surface|PRMSL:mean sea level|TMP:2 m above ground):'

: > "$OUT"
for step in "${STEPS[@]}"; do
  stem="gfs.t${HH}z.pgrb2.0p25.f${step}"
  idx_url="$BASE/${stem}.idx"
  grib_url="$BASE/${stem}"

  idx=$(curl -fsS --max-time 30 "$idx_url" 2>/dev/null) || { echo "skip +${step}h (no idx)"; continue; }

  # NOMADS .idx format: "N:byte_offset:date:VAR:LEVEL:STEP:" — length of a
  # record is the next record's offset minus this one's.
  pairs=$(printf '%s\n' "$idx" | awk -F: -v re="$WANTED_RE" '
    { n=NR; off[n]=$2; line[n]=$0 }
    END {
      for (i=1;i<=n;i++) {
        if (line[i] ~ re) {
          end = (i<n) ? off[i+1]-1 : ""
          print off[i], end
        }
      }
    }')
  [ -z "$pairs" ] && continue

  while read -r off end; do
    [ -z "$off" ] && continue
    if [ -z "$end" ]; then
      curl -fsS --max-time 120 -H "Range: bytes=${off}-" "$grib_url" >> "$OUT"
    else
      curl -fsS --max-time 120 -H "Range: bytes=${off}-${end}" "$grib_url" >> "$OUT"
    fi
    sleep 0.06
  done <<< "$pairs"
done

[ -s "$OUT" ] || { echo "no GFS data fetched for ${DATE} ${HH}Z" >&2; exit 1; }
echo "GFS cycle bundled into $OUT ($(stat -c%s "$OUT") bytes)"
