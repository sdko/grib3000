#!/usr/bin/env bash
# Fetch an ICON-2I cycle (Italian 2.2 km model run by ItaliaMeteo / ARPAE,
# published as open data on MeteoHub, CC-BY 4.0) and concatenate it into a
# single GRIB2.
# The server publishes ONE file per variable for the whole run: 73 hourly
# steps (0..72 h), ~84 MB each, on a regular lat-lon grid
# (0.02° lat x 0.025° lon, 33.7–48.9°N, 3–22°E). Runs: 00Z and 12Z.
# Usage: fetch_icon2i.sh <YYYY-MM-DD> <HH> <out.grib2>
set -euo pipefail
DATE="${1:?date}"; HOUR="${2:?hour}"; OUT="${3:?out}"
RUN="${DATE//-/}${HOUR}"
BASE="https://meteohub.agenziaitaliameteo.it/nwp/ICON-2I_SURFACE_PRESSURE_LEVELS/${RUN}"
VARS=(U_10M V_10M VMAX_10M PMSL T_2M)
STEPS_EXPECTED=73

: > "$OUT"
for v in "${VARS[@]}"; do
  # The file name encodes the level (heightAboveGround-10, meanSea-0, …):
  # read it from the directory listing rather than guessing.
  name=$(curl -fsS --retry 5 --retry-delay 10 --retry-all-errors --max-time 30 "$BASE/$v/" \
           | grep -o 'href="[^"]*\.grib"' | head -1 | cut -d'"' -f2) || true
  [ -n "$name" ] || { echo "no GRIB listed for $v in ICON-2I ${RUN}" >&2; exit 1; }
  tmp="${OUT}.part"
  if ! curl -fsS --retry 5 --retry-delay 10 --retry-all-errors \
       --connect-timeout 20 --max-time 900 -o "$tmp" "$BASE/$v/$name"; then
    echo "failed to fetch $v/$name" >&2; rm -f "$tmp"; exit 1
  fi
  # A file listed while still being uploaded would be short: require every
  # step so we never publish a truncated horizon (the next hourly run retries).
  n=$(wgrib2 "$tmp" | wc -l)
  if [ "$n" -lt "$STEPS_EXPECTED" ]; then
    echo "$v has $n/$STEPS_EXPECTED steps in ICON-2I ${RUN} — run not complete" >&2
    rm -f "$tmp"; exit 1
  fi
  cat "$tmp" >> "$OUT"; rm -f "$tmp"
done
echo "ICON-2I cycle bundled into $OUT ($(stat -c%s "$OUT") bytes)"
