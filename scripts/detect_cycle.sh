#!/usr/bin/env bash
# Print the most-recently-published cycle for <model> as key=value lines
# suitable for `>> $GITHUB_OUTPUT`:
#   date=YYYY-MM-DD
#   hour=HH
# Walks back up to 4 cycles if the latest expected one isn't online yet.
set -euo pipefail
MODEL="${1:?usage: detect_cycle.sh <model>}"

step_h=$(jq -r --arg m "$MODEL" '.[$m].cycle_step_h' models.json)
lag_min=$(jq -r --arg m "$MODEL" '.[$m].lag_minutes' models.json)
[ "$step_h" = "null" ] && { echo "unknown model: $MODEL" >&2; exit 2; }

probe() {
  local d="$1" h="$2"
  case "$MODEL" in
    ecmwf)
      local cd="${d//-/}"
      curl -fsS -o /dev/null --max-time 10 \
        "https://data.ecmwf.int/forecasts/${cd}/${h}z/ifs/0p25/oper/${cd}${h}0000-0h-oper-fc.index"
      ;;
    gfs)
      local cd="${d//-/}"
      curl -fsS -o /dev/null --max-time 10 -I \
        "https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod/gfs.${cd}/${h}/atmos/gfs.t${h}z.pgrb2.0p25.f000.idx"
      ;;
    arpege01)
      local stamp="${d}T${h}:00:00Z"
      curl -fsS -o /dev/null --max-time 10 -I \
        "https://meteofrance-pnt.s3.rbx.io.cloud.ovh.net/pnt/${stamp}/arpege/01/SP1/arpege__01__SP1__000H012H__${stamp}.grib2"
      ;;
    arome0025|arome001)
      local res=${MODEL#arome}
      local stamp="${d}T${h}:00:00Z"
      curl -fsS -o /dev/null --max-time 10 -I \
        "https://meteofrance-pnt.s3.rbx.io.cloud.ovh.net/pnt/${stamp}/arome/${res}/HP1/arome__${res}__HP1__00H__${stamp}.grib2"
      ;;
    *) return 1 ;;
  esac
}

ref_s=$(( $(date -u +%s) - lag_min*60 ))
slot_s=$(( ref_s - ref_s % (step_h*3600) ))

for i in 0 1 2 3 4; do
  cand_s=$(( slot_s - i*step_h*3600 ))
  d=$(date -u -d "@$cand_s" +%Y-%m-%d)
  h=$(date -u -d "@$cand_s" +%H)
  if probe "$d" "$h" 2>/dev/null; then
    printf 'date=%s\nhour=%s\n' "$d" "$h"
    exit 0
  fi
done
echo "no cycle online for $MODEL after 4 fallbacks" >&2
exit 1
