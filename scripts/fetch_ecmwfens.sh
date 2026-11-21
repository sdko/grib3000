#!/usr/bin/env bash
# Fetch the 10 m wind of every perturbed member (1..50) of an ECMWF ENS cycle
# as one concatenated GRIB2. The control run is not included: it is the
# deterministic IFS run already published as the `ecmwf` model.
#
# A step file holds ~8850 messages for ~6 GB; the `.index` sidecar gives the
# byte range of each one, so only the 100 wind messages (~72 MB) are pulled,
# with HTTP Range requests. Uses the Google Cloud mirror of ECMWF Open Data:
# the AWS mirror answers 503 SlowDown to bursts of ranged requests.
#
# Usage: fetch_ecmwfens.sh <YYYY-MM-DD> <HH> <out.grib2>
set -euo pipefail
DATE="${1:?date}"; HOUR="${2:?hour}"; OUT="${3:?out}"
CD="${DATE//-/}"
BASE="${ECMWF_ENS_BASE:-https://storage.googleapis.com/ecmwf-open-data}/${CD}/${HOUR}z/ifs/0p25/enfo"
PARALLEL="${ECMWF_ENS_PARALLEL:-6}"

# 3-hourly to +72 h, 6-hourly to +144 h (the horizon every cycle reaches).
STEPS="${ECMWF_ENS_STEPS:-$(seq 0 3 72) $(seq 78 6 144)}"

TMP="$(mktemp -d "${OUT}.tmp.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fetch_range() {
  # <url> <offset> <length> <dest>
  local url="$1" off="$2" len="$3" dest="$4"
  curl -fsS --retry 6 --retry-delay 3 --retry-all-errors --max-time 120 \
    -r "${off}-$((off + len - 1))" -o "$dest" "$url"
  [ "$(stat -c%s "$dest")" = "$len" ] || { echo "short read: $dest" >&2; return 1; }
}
export -f fetch_range

: > "$OUT"
n_steps=0
for step in $STEPS; do
  stem="${CD}${HOUR}0000-${step}h-enfo-ef"
  idx="$TMP/${step}.index"
  curl -fsS --retry 6 --retry-delay 3 --retry-all-errors --max-time 60 \
    -o "$idx" "$BASE/${stem}.index" \
    || { echo "ECMWF ENS +${step}h: no index" >&2; exit 1; }
  # One line per wanted message: "<member 2 digits>_<param> <offset> <length>",
  # sorted so the output is ordered by member, then u before v.
  jq -r 'select(.type == "pf" and .levtype == "sfc" and (.param == "10u" or .param == "10v"))
         | "\(.number | tonumber | . + 100 | tostring | .[1:])_\(.param) \(._offset) \(._length)"' \
    "$idx" | sort > "$TMP/${step}.plan"
  n=$(wc -l < "$TMP/${step}.plan")
  [ "$n" -eq 100 ] || { echo "ECMWF ENS +${step}h: expected 100 wind messages, index has $n" >&2; exit 1; }
  mkdir -p "$TMP/$step"
  awk -v url="$BASE/${stem}.grib2" -v dir="$TMP/$step" '{ print url, $2, $3, dir "/" $1 }' \
    "$TMP/${step}.plan" \
    | xargs -P "$PARALLEL" -n 4 bash -c 'fetch_range "$@"' _
  cat "$TMP/$step"/* >> "$OUT"
  rm -rf "$TMP/$step"
  n_steps=$((n_steps + 1))
done
echo "ECMWF ENS cycle bundled into $OUT ($n_steps steps, $(stat -c%s "$OUT") bytes)"
