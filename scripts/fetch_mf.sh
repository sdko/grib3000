#!/usr/bin/env bash
# Fetch a Météo-France public-data cycle from the OVH S3 mirror and
# concatenate every file in the cycle into a single GRIB2.
# Usage: fetch_mf.sh <arpege01|arome0025|arome001> <YYYY-MM-DD> <HH> <out>
set -euo pipefail
MODEL="${1:?model}"; DATE="${2:?date}"; HOUR="${3:?hour}"; OUT="${4:?out}"
STAMP="${DATE}T${HOUR}:00:00Z"
S3="https://meteofrance-pnt.s3.rbx.io.cloud.ovh.net/pnt"

fetch() {
  # Every file is expected to exist: detect_cycle.sh probes the cycle's LAST
  # file before we get here, and MF publishes steps in order. Download to a
  # temp file so a failed transfer can't leave partial GRIB messages (or,
  # with --retry to stdout, duplicated bytes) in the concatenation.
  local url="$1" tmp="${OUT}.part"
  if ! curl -fsS --retry 3 --retry-delay 2 --max-time 300 -o "$tmp" "$url"; then
    echo "failed to fetch $(basename "$url")" >&2
    rm -f "$tmp"
    exit 1
  fi
  cat "$tmp" >> "$OUT"
  rm -f "$tmp"
}

: > "$OUT"
case "$MODEL" in
  arpege01)
    # SP1 = surface package 1 (incl. 10 m wind, MSL, T2m, gust).
    for r in 000H012H 013H024H 025H036H 037H048H 049H060H 061H072H; do
      fetch "${S3}/${STAMP}/arpege/01/SP1/arpege__01__SP1__${r}__${STAMP}.grib2"
    done
    ;;
  arome001)
    # 0.01° AROME SP1 (surface package): hourly files 00H..51H (full
    # operational horizon). Not HP1 — that's height-level wind only (no
    # gust/T2m/MSLP) at ~3x the size. SP1 ships gust as UGUST/VGUST
    # components and carries no MSLP at this resolution.
    for h in $(seq -f '%02g' 0 51); do
      fetch "${S3}/${STAMP}/arome/001/SP1/arome__001__SP1__${h}H__${STAMP}.grib2"
    done
    ;;
  arome0025)
    # 0.025° AROME SP1: 6-h bundles 00H06H..43H48H + tail bundle 49H51H.
    # SP1 has 10 m wind, gust, T2m, MSLP; HP1 is height-level wind only.
    for r in 00H06H 07H12H 13H18H 19H24H 25H30H 31H36H 37H42H 43H48H 49H51H; do
      fetch "${S3}/${STAMP}/arome/0025/SP1/arome__0025__SP1__${r}__${STAMP}.grib2"
    done
    ;;
  *) echo "unsupported MF model: $MODEL" >&2; exit 2 ;;
esac

[ -s "$OUT" ] || { echo "no MF data fetched for $MODEL ${DATE} ${HOUR}Z" >&2; exit 1; }
echo "$MODEL cycle bundled into $OUT ($(stat -c%s "$OUT") bytes)"
