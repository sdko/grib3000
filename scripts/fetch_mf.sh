#!/usr/bin/env bash
# Fetch a Météo-France public-data cycle from the OVH S3 mirror and
# concatenate every file in the cycle into a single GRIB2.
# Usage: fetch_mf.sh <arpege01|arome0025|arome001> <YYYY-MM-DD> <HH> <out>
set -euo pipefail
MODEL="${1:?model}"; DATE="${2:?date}"; HOUR="${3:?hour}"; OUT="${4:?out}"
STAMP="${DATE}T${HOUR}:00:00Z"
S3="https://meteofrance-pnt.s3.rbx.io.cloud.ovh.net/pnt"

fetch() {
  # Tolerate missing files (Arome/Arpège publish later steps after the early
  # ones), but keep going on transient errors via curl --retry.
  local url="$1"
  if curl -fsS --retry 3 --retry-delay 2 --max-time 300 "$url" >> "$OUT"; then
    return 0
  fi
  echo "  skip $(basename "$url")"
  return 0
}

: > "$OUT"
case "$MODEL" in
  arpege01)
    # SP1 = surface package 1 (incl. 10 m wind, MSL, T2m, gust).
    for r in 000H012H 013H024H 025H036H 037H048H; do
      fetch "${S3}/${STAMP}/arpege/01/SP1/arpege__01__SP1__${r}__${STAMP}.grib2"
    done
    ;;
  arome001)
    # 0.01° AROME HP1: hourly files 00H..24H.
    for h in $(seq -f '%02g' 0 24); do
      fetch "${S3}/${STAMP}/arome/001/HP1/arome__001__HP1__${h}H__${STAMP}.grib2"
    done
    ;;
  arome0025)
    # 0.025° AROME HP1: 6-hour bundles up to 48 h.
    for r in 00H06H 07H12H 13H18H 19H24H; do
      fetch "${S3}/${STAMP}/arome/0025/HP1/arome__0025__HP1__${r}__${STAMP}.grib2"
    done
    ;;
  *) echo "unsupported MF model: $MODEL" >&2; exit 2 ;;
esac

[ -s "$OUT" ] || { echo "no MF data fetched for $MODEL ${DATE} ${HOUR}Z" >&2; exit 1; }
echo "$MODEL cycle bundled into $OUT ($(stat -c%s "$OUT") bytes)"
