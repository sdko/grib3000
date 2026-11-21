#!/usr/bin/env bash
# Fetch the ECMWF Open Data IFS 0.25° cycle as a single concatenated GRIB2.
# Each step is one ~140 MB file plus a `.index` sidecar (JSON lines, one per
# GRIB message, with `_offset` / `_length`). We read the index and pull only
# the surface fields we keep with HTTP Range requests: ~3 MB per step
# instead of 140, which is what makes the 240 h horizon affordable.
# Usage: fetch_ecmwf.sh <YYYY-MM-DD> <HH> <out.grib2>
set -euo pipefail
DATE="${1:?date}"; HOUR="${2:?hour}"; OUT="${3:?out}"
CD="${DATE//-/}"
HH="$HOUR"
BASE="https://data.ecmwf.int/forecasts/${CD}/${HH}z/ifs/0p25/oper"
WAVE="https://data.ecmwf.int/forecasts/${CD}/${HH}z/ifs/0p25/wave"

# Every 3 h to +144 h, then every 6 h to +240 h. The 06Z/18Z runs stop at
# +144 h; 00Z/12Z go further.
case "$HH" in
  00|12) STEPS=($(seq 0 3 144) $(seq 150 6 240)) ;;
  *)     STEPS=($(seq 0 3 144)) ;;
esac

# Gust is `10fg` (max since the previous step) except between +93 h and
# +144 h, where the 3-hourly steps publish it as `10fg3`.
PARAMS='["10u","10v","10fg","10fg3","msl","2t"]'
# Sequential, one step at a time with a pause in between: polite to the
# open-data portal, which rate-limits per IP.
PAUSE=0.5
CURL=(-fsS --max-time 120 --retry 5 --retry-delay 10 --retry-all-errors)

: > "$OUT"
for step in "${STEPS[@]}"; do
  stem="${CD}${HH}0000-${step}h-oper-fc"
  # detect_cycle.sh probed the LAST step's index, so all are expected.
  index=$(curl "${CURL[@]}" "$BASE/${stem}.index") \
    || { echo "missing index for +${step}h" >&2; exit 1; }

  ranges=$(printf '%s\n' "$index" | jq -r --argjson p "$PARAMS" '
    select(.levtype == "sfc" and (.param as $x | $p | index($x)))
    | "\(._offset)-\(._offset + ._length - 1)"')
  [ -z "$ranges" ] && { echo "no wanted field at +${step}h" >&2; exit 1; }

  # All of a step's ranges in ONE curl invocation (`--next` separates the
  # transfers), so they share a single connection instead of paying a TLS
  # handshake each. Each range lands in its own temp file and is appended
  # only once the whole step succeeded: a failed or retried transfer can't
  # leave partial or duplicated bytes in the bundle.
  args=(); parts=(); i=0
  while read -r range; do
    part="${OUT}.part${i}"
    [ "$i" -gt 0 ] && args+=(--next)
    args+=("${CURL[@]}" -r "$range" -o "$part" "$BASE/${stem}.grib2")
    parts+=("$part"); i=$((i+1))
  done <<< "$ranges"
  if ! curl "${args[@]}"; then
    echo "failed to fetch +${step}h" >&2; rm -f "${parts[@]}"; exit 1
  fi
  cat "${parts[@]}" >> "$OUT"; rm -f "${parts[@]}"

  # Significant wave height (`swh`) from the wave stream of the same cycle,
  # same index + Range technique. Best effort: waves are a bonus, a missing
  # wave step must not fail the wind build.
  wstem="${CD}${HH}0000-${step}h-wave-fc"
  wrange=$(curl "${CURL[@]}" "$WAVE/${wstem}.index" 2>/dev/null | jq -r '
    select(.param == "swh") | "\(._offset)-\(._offset + ._length - 1)"' | head -n 1) || wrange=""
  if [ -n "$wrange" ] && curl "${CURL[@]}" -r "$wrange" -o "${OUT}.wpart" "$WAVE/${wstem}.grib2" 2>/dev/null; then
    cat "${OUT}.wpart" >> "$OUT"
  else
    echo "no wave height at +${step}h (skipped)"
  fi
  rm -f "${OUT}.wpart"
  sleep "$PAUSE"
done

[ -s "$OUT" ] || { echo "no ECMWF data fetched for ${DATE} ${HH}Z" >&2; exit 1; }
echo "ECMWF cycle bundled into $OUT ($(stat -c%s "$OUT") bytes)"
