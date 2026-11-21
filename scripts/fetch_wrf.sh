#!/usr/bin/env bash
# Fetch a WRF 1.5 km cycle (ItaliaMeteo / CIMA / LaMMA, published as open
# data on MeteoHub) and concatenate it into a single GRIB2.
# Like ICON-2I, the server publishes ONE file per variable for the whole run:
# 73 hourly steps (0..72 h). Runs: 00Z and 12Z, online ~9–12 h after the run.
# The native grid is Lambert conformal (1399 x 1399, 1.5 km) with
# grid-relative winds — build_cycle.sh reprojects it to lat-lon.
# Only 10 m wind and gust are taken (10u ~137 MB, 10v ~131 MB, gust ~90 MB);
# pressure and temperature are heavy here and every other model has them.
# Usage: fetch_wrf.sh <YYYY-MM-DD> <HH> <out.grib2>
set -euo pipefail
DATE="${1:?date}"; HOUR="${2:?hour}"; OUT="${3:?out}"
RUN="${DATE//-/}${HOUR}"
BASE="https://meteohub.agenziaitaliameteo.it/nwp/WRF/${RUN}"
VARS=(10u 10v gust)
STEPS_EXPECTED=73

: > "$OUT"
for v in "${VARS[@]}"; do
  # The file name encodes the level (heightAboveGround-10, surface-0):
  # read it from the directory listing rather than guessing.
  listing=$(curl -fsS --http1.1 --retry 5 --retry-delay 10 --retry-all-errors \
              --max-time 30 "$BASE/$v/") \
    || { echo "cannot list $v for WRF ${RUN}" >&2; exit 1; }
  name=$(printf '%s\n' "$listing" | grep -o 'href="[^"]*\.grib"' | head -1 | cut -d'"' -f2 || true)
  [ -n "$name" ] || { echo "no GRIB listed for $v in WRF ${RUN}" >&2; exit 1; }
  tmp="${OUT}.part"
  rm -f "$tmp"
  # The server sometimes drops HTTP/2 streams mid-transfer (curl 92), hence
  # HTTP/1.1 and `-C -` so a retry resumes instead of restarting.
  if ! curl -fsS --http1.1 --retry 5 --retry-delay 10 --retry-all-errors -C - \
       --connect-timeout 20 --max-time 1200 -o "$tmp" "$BASE/$v/$name"; then
    echo "failed to fetch $v/$name" >&2; rm -f "$tmp"; exit 1
  fi
  # A file listed while still being uploaded would be short: require every
  # step so we never publish a truncated horizon (the next hourly run retries).
  n=$(wgrib2 "$tmp" | wc -l)
  if [ "$n" -lt "$STEPS_EXPECTED" ]; then
    echo "$v has $n/$STEPS_EXPECTED steps in WRF ${RUN} — run not complete" >&2
    rm -f "$tmp"; exit 1
  fi
  cat "$tmp" >> "$OUT"; rm -f "$tmp"
done
echo "WRF cycle bundled into $OUT ($(stat -c%s "$OUT") bytes)"
