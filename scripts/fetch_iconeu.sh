#!/usr/bin/env bash
# Fetch a DWD ICON-EU (0.0625°, regular lat-lon) cycle from the DWD open-data
# server and concatenate it into a single GRIB2.
# The server publishes one bzip2'd file per parameter per forecast step
# (~1 MB each): hourly to +78 h, then 3-hourly to +120 h, for the
# 00/06/12/18Z runs (03/09/15/21Z stop at +51 h and are not used).
# Usage: fetch_iconeu.sh <YYYY-MM-DD> <HH> <out.grib2>
set -euo pipefail
DATE="${1:?date}"; HOUR="${2:?hour}"; OUT="${3:?out}"
RUN="${DATE//-/}${HOUR}"
BASE="https://opendata.dwd.de/weather/nwp/icon-eu/grib/${HOUR}"
PARAMS=(u_10m v_10m vmax_10m pmsl t_2m)
STEPS=($(seq -f '%03g' 0 78) $(seq -f '%03g' 81 3 120))

TMP="${OUT}.d"
rm -rf "$TMP"; mkdir -p "$TMP"

# 465 small files: 4 at a time. The server sometimes resets connections,
# hence --retry-all-errors. A file that still fails leaves no output and
# the completeness check below aborts the build.
list="$TMP/urls.txt"
: > "$list"
for p in "${PARAMS[@]}"; do
  P="${p^^}"
  for s in "${STEPS[@]}"; do
    f="icon-eu_europe_regular-lat-lon_single-level_${RUN}_${s}_${P}.grib2.bz2"
    printf '%s %s\n' "$BASE/$p/$f" "$TMP/${s}_${p}.grib2.bz2" >> "$list"
  done
done
xargs -P 4 -L 1 bash -c '
  curl -fsS --retry 6 --retry-delay 5 --retry-all-errors --connect-timeout 20 \
       --max-time 120 -o "$1.part" "$0" && mv "$1.part" "$1" \
    || echo "failed to fetch $(basename "$0")" >&2
' < "$list"

: > "$OUT"
for s in "${STEPS[@]}"; do
  for p in "${PARAMS[@]}"; do
    f="$TMP/${s}_${p}.grib2.bz2"
    [ -s "$f" ] || { echo "missing ${p} +${s}h for ICON-EU ${RUN}" >&2; exit 1; }
    bunzip2 -c "$f" >> "$OUT"
  done
done

# Significant wave height from DWD's EWAM (European wave model, 0.05° x
# 0.1°, 30–66°N 10.5°W–42°E, driven by ICON-EU). EWAM only runs at 00Z and
# 12Z, hourly to +78 h: use the run at or just before this ICON-EU cycle
# (messages carry their own reference time, so valid times stay right).
# Best effort: waves are a bonus, a missing file must not fail the build.
EH=$(( 10#$HOUR / 12 * 12 )); EH=$(printf '%02d' "$EH")
ERUN="${DATE//-/}${EH}"
EBASE="https://opendata.dwd.de/weather/maritime/wave_models/ewam/grib/${EH}/swh"
: > "$list"
for s in $(seq -f '%03g' 0 78); do
  printf '%s %s\n' "$EBASE/EWAM_SWH_${ERUN}_${s}.grib2.bz2" "$TMP/ewam_${s}.grib2.bz2" >> "$list"
done
xargs -P 4 -L 1 bash -c '
  curl -fsS --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 20 \
       --max-time 120 -o "$1.part" "$0" 2>/dev/null && mv "$1.part" "$1" || true
' < "$list"
n_wave=0
for f in "$TMP"/ewam_*.grib2.bz2; do
  [ -s "$f" ] || continue
  bunzip2 -c "$f" >> "$OUT" && n_wave=$((n_wave+1))
done
echo "EWAM ${ERUN}: $n_wave/79 wave-height steps"

rm -rf "$TMP"
echo "ICON-EU cycle bundled into $OUT ($(stat -c%s "$OUT") bytes)"
