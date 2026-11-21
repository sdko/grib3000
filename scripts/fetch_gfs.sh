#!/usr/bin/env bash
# Fetch the NOAA GFS 0.25° cycle from NOMADS using the .idx sidecar and
# HTTP Range requests, keeping only the surface fields we want.
# Usage: fetch_gfs.sh <YYYY-MM-DD> <HH> <out.grib2>
set -euo pipefail
DATE="${1:?date}"; HOUR="${2:?hour}"; OUT="${3:?out}"
CD="${DATE//-/}"
HH="$HOUR"
BASE="https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod/gfs.${CD}/${HH}/atmos"
WAVE="https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod/gfs.${CD}/${HH}/wave/gridded"

# Same horizon as ECMWF: every 3 h to +144 h, then every 6 h to +240 h.
STEPS=($(seq -f '%03g' 0 3 144) $(seq -f '%03g' 150 6 240))

# NOMADS blocks an IP that goes over ~120 hits/minute. 65 steps x (1 idx +
# 5 ranges + 2 for the wave height) = 520 requests, so every request is
# followed by this pause (~110/min worst case, ~10 min for the whole cycle).
PAUSE=0.55

# GFS idx variable:level lines we want. Pattern is anchored with ":".
WANTED_RE=':(UGRD:10 m above ground|VGRD:10 m above ground|GUST:surface|PRMSL:mean sea level|TMP:2 m above ground):'

# One ranged GET to a temp file, appended only when complete, so a failed
# or retried transfer can't leave partial/duplicated bytes in the bundle.
fetch_range() {
  local range="$1" tmp="${OUT}.part"
  if ! curl -fsS --max-time 120 --retry 4 --retry-delay 5 --retry-all-errors \
       -H "Range: bytes=${range}" -o "$tmp" "$grib_url"; then
    echo "failed range ${range} of $(basename "$grib_url")" >&2
    rm -f "$tmp"; exit 1
  fi
  cat "$tmp" >> "$OUT"; rm -f "$tmp"
  sleep "$PAUSE"
}

: > "$OUT"
for step in "${STEPS[@]}"; do
  stem="gfs.t${HH}z.pgrb2.0p25.f${step}"
  idx_url="$BASE/${stem}.idx"
  grib_url="$BASE/${stem}"

  # detect_cycle.sh probed the LAST step, so every idx is expected.
  idx=$(curl -fsS --max-time 30 --retry 4 --retry-delay 5 --retry-all-errors "$idx_url") \
    || { echo "missing idx for +${step}h" >&2; exit 1; }
  sleep "$PAUSE"

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
    fetch_range "${off}-${end}"
  done <<< "$pairs"

  # Significant wave height (HTSGW) from GFS-Wave, a separate file set of
  # the same cycle with its own .idx. Best effort: waves are a bonus, a
  # missing wave step must not fail the wind build.
  wave_url="$WAVE/gfswave.t${HH}z.global.0p25.f${step}.grib2"
  widx=$(curl -fsS --max-time 30 --retry 2 --retry-delay 5 "${wave_url}.idx" 2>/dev/null) || widx=""
  sleep "$PAUSE"
  wrange=$(printf '%s\n' "$widx" | awk -F: '
    { n=NR; off[n]=$2; var[n]=$4 }
    END { for (i=1;i<=n;i++) if (var[i]=="HTSGW") { print off[i] "-" ((i<n) ? off[i+1]-1 : ""); exit } }')
  if [ -n "$wrange" ] && curl -fsS --max-time 120 --retry 2 --retry-delay 5 \
       -H "Range: bytes=${wrange}" -o "${OUT}.wpart" "$wave_url" 2>/dev/null; then
    cat "${OUT}.wpart" >> "$OUT"
  else
    echo "no wave height at +${step}h (skipped)"
  fi
  rm -f "${OUT}.wpart"
  sleep "$PAUSE"
done

[ -s "$OUT" ] || { echo "no GFS data fetched for ${DATE} ${HH}Z" >&2; exit 1; }
echo "GFS cycle bundled into $OUT ($(stat -c%s "$OUT") bytes)"
