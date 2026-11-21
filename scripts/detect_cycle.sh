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
      # Probe the LAST step fetch_ecmwf.sh pulls: +240 h for 00Z/12Z,
      # +144 h for the shorter 06Z/18Z runs.
      local last=144
      case "$h" in 00|12) last=240 ;; esac
      curl -fsS -o /dev/null --max-time 10 \
        "https://data.ecmwf.int/forecasts/${cd}/${h}z/ifs/0p25/oper/${cd}${h}0000-${last}h-oper-fc.index"
      ;;
    ecmwfens)
      local cd="${d//-/}"
      # Same mirror fetch_ecmwfens.sh reads; +144 h is its last step and the
      # horizon every ENS cycle reaches.
      curl -fsS -o /dev/null --max-time 10 \
        "https://storage.googleapis.com/ecmwf-open-data/${cd}/${h}z/ifs/0p25/enfo/${cd}${h}0000-144h-enfo-ef.index"
      ;;
    gfs)
      local cd="${d//-/}"
      # Probe the LAST step fetch_gfs.sh pulls (f240): NOMADS posts the
      # horizon incrementally over about an hour.
      curl -fsS -o /dev/null --max-time 10 -I \
        "https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod/gfs.${cd}/${h}/atmos/gfs.t${h}z.pgrb2.0p25.f240.idx"
      ;;
    arpege01)
      # Probe the LAST bundle we fetch (097H102H), not the first: MF publishes
      # the horizon incrementally, so only the final file's presence proves
      # the whole cycle is online (fetch_mf.sh hard-fails on missing files).
      local stamp="${d}T${h}:00:00Z"
      curl -fsS -o /dev/null --max-time 10 -I \
        "https://meteofrance-pnt.s3.rbx.io.cloud.ovh.net/pnt/${stamp}/arpege/01/SP1/arpege__01__SP1__097H102H__${stamp}.grib2"
      ;;
    arome001)
      # Probe the LAST hourly file (51H), not the first: AROME publishes its
      # horizon incrementally over ~4 h, so only the final file's presence
      # proves the whole cycle is online. Probing 00H would accept a
      # half-published cycle and yield a truncated release.
      local stamp="${d}T${h}:00:00Z"
      curl -fsS -o /dev/null --max-time 10 -I \
        "https://meteofrance-pnt.s3.rbx.io.cloud.ovh.net/pnt/${stamp}/arome/001/SP1/arome__001__SP1__51H__${stamp}.grib2"
      ;;
    arome0025)
      # 0.025° AROME ships 6-hour bundles, not hourly files. Probe the LAST
      # bundle (49H51H) so we only accept a fully-published cycle (see above).
      local stamp="${d}T${h}:00:00Z"
      curl -fsS -o /dev/null --max-time 10 -I \
        "https://meteofrance-pnt.s3.rbx.io.cloud.ovh.net/pnt/${stamp}/arome/0025/SP1/arome__0025__SP1__49H51H__${stamp}.grib2"
      ;;
    iconeu)
      # One file per parameter per step; the last step (+120 h) of every
      # parameter we fetch must be there. Only 00/06/12/18Z reach +120 h,
      # which cycle_step_h = 6 already selects.
      local run="${d//-/}${h}" p
      for p in u_10m v_10m vmax_10m pmsl t_2m; do
        curl -fsS -o /dev/null --max-time 15 --retry 3 --retry-all-errors -I \
          "https://opendata.dwd.de/weather/nwp/icon-eu/grib/${h}/${p}/icon-eu_europe_regular-lat-lon_single-level_${run}_120_${p^^}.grib2.bz2" \
          || return 1
      done
      ;;
    icon2i)
      # One whole-run file per variable: all five directories must list a
      # GRIB. (A file still being uploaded is caught by fetch_icon2i.sh's
      # step count, and the next hourly run retries.)
      local run="${d//-/}${h}" v listing
      for v in U_10M V_10M VMAX_10M PMSL T_2M; do
        listing=$(curl -fsS --max-time 15 --retry 3 --retry-all-errors \
          "https://meteohub.agenziaitaliameteo.it/nwp/ICON-2I_SURFACE_PRESSURE_LEVELS/${run}/${v}/") \
          || return 1
        case "$listing" in *'.grib"'*) ;; *) return 1 ;; esac
      done
      ;;
    wrf)
      # Same layout as ICON-2I: one whole-run file per variable.
      local run="${d//-/}${h}" v listing
      for v in 10u 10v gust; do
        listing=$(curl -fsS --http1.1 --max-time 15 --retry 3 --retry-all-errors \
          "https://meteohub.agenziaitaliameteo.it/nwp/WRF/${run}/${v}/") \
          || return 1
        case "$listing" in *'.grib"'*) ;; *) return 1 ;; esac
      done
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
