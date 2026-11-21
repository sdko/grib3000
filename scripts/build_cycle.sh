#!/usr/bin/env bash
# Fetch one cycle's native-domain GRIB and produce per-region bbox cuts.
# Usage: build_cycle.sh <model> <YYYY-MM-DD> <HH>
# Writes dist/<model>/<region>.grib2 for every region listed for the model.
set -euo pipefail

MODEL="${1:?model}"
DATE="${2:?YYYY-MM-DD}"
HOUR="${3:?HH}"
DIST="dist/${MODEL}"
mkdir -p "$DIST"
NATIVE="$DIST/_native.grib2"

case "$MODEL" in
  ecmwf)
    bash scripts/fetch_ecmwf.sh "$DATE" "$HOUR" "$NATIVE"
    ;;
  ecmwfens)
    bash scripts/fetch_ecmwfens.sh "$DATE" "$HOUR" "$NATIVE"
    ;;
  gfs)
    bash scripts/fetch_gfs.sh "$DATE" "$HOUR" "$NATIVE"
    ;;
  arpege01|arome0025|arome001)
    bash scripts/fetch_mf.sh "$MODEL" "$DATE" "$HOUR" "$NATIVE"
    ;;
  iconeu)
    bash scripts/fetch_iconeu.sh "$DATE" "$HOUR" "$NATIVE"
    ;;
  icon2i)
    bash scripts/fetch_icon2i.sh "$DATE" "$HOUR" "$NATIVE"
    ;;
  wrf)
    bash scripts/fetch_wrf.sh "$DATE" "$HOUR" "$NATIVE"
    ;;
  *)
    echo "unknown model: $MODEL" >&2; exit 2
    ;;
esac

# Keep only 10 m wind + gust + MSLP + 2 m temp (+ significant wave height
# where the fetcher added it), regardless of producer.
# (ECMWF's `msl` decodes as PRES:mean sea level in wgrib2, not PRMSL.)
# Producers vary in what they ship; this normalises the asset to the
# minimum a sailing app needs. UGUST/VGUST: 0.01° AROME has no scalar
# GUST — it publishes gust as u/v components instead.
F="$DIST/_filtered.grib2"
wgrib2 "$NATIVE" \
  -match ':((UGRD|VGRD|UGUST|VGUST):10 m above ground|GUST:[^:]+|(PRMSL|PRES):mean sea level|TMP:2 m above ground|HTSGW:[^:]+):' \
  -GRIB "$F" >/dev/null
mv "$F" "$NATIVE"
# 0.025° AROME ships the gust twice (scalar GUST and UGUST/VGUST). When the
# scalar is there the components are dead weight (~a quarter of the asset).
n_gust=$(wgrib2 "$NATIVE" -match ':GUST:' -s | wc -l)
if [ "$n_gust" -gt 0 ]; then
  wgrib2 "$NATIVE" -not ':(UGUST|VGUST):' -GRIB "$F" >/dev/null
  mv "$F" "$NATIVE"
fi

# Models on a non lat-lon native grid (WRF: Lambert conformal) declare a
# `regrid` step in models.json and are reprojected straight onto each
# region's box instead of being cut with -small_grib.
REGRID_DLON=$(jq -r --arg m "$MODEL" '.[$m].regrid.dlon // empty' models.json)
REGRID_DLAT=$(jq -r --arg m "$MODEL" '.[$m].regrid.dlat // empty' models.json)
if [ -n "$REGRID_DLON" ]; then
  # -new_grid rotates grid-relative winds to earth-relative only when each
  # UGRD is immediately followed by its VGRD. Reorder by forecast time, then
  # variable name (GUST, UGRD, VGRD) — which also makes the file chronological.
  wgrib2 "$NATIVE" -s | awk -F: '{
      t = $6; h = 0
      if (t ~ /^[0-9]/) { h = t + 0; if (t ~ / min /) h /= 60; if (t ~ / day /) h *= 24 }
      printf "%09.3f:%s\t%s\n", h, $4, $0
    }' | sort -s -t "$(printf '\t')" -k1,1 | cut -f2- \
    | wgrib2 -i "$NATIVE" -GRIB "$F" >/dev/null
  mv "$F" "$NATIVE"
fi

# Per-region cut, then repack.
#
# wgrib2's `-small_grib` takes lonW:lonE then latS:latN (degrees on the
# source grid; a bbox larger than the model domain is clipped to it) and
# always writes simple packing, so the size reduction has to come after it:
#
#  - precision: values are rounded to a binary step (`-set_scaling 0 B`
#    stores multiples of 2^B). Wind, gust and temperature keep 2^-3 =
#    0.125 (m/s, K), i.e. a max error of 0.0625 m/s ≈ 0.12 kt; pressure
#    keeps 2^4 = 16 Pa (max error 0.08 hPa); wave height keeps 2^-4 =
#    0.0625 m (max error 0.03 m). Producers ship 16–24 bits per value,
#    most of it noise far below forecast skill.
#    Wave fields mask land with a bitmap, which both steps preserve.
#  - packing: complex packing with spatial differencing (`c3`, GRIB2
#    template 5.3), lossless on top of the rounding above.
#
# No land masking: a consumer that interpolates bilinearly needs all four
# corners of a cell, so masked land would punch holes along every coast.
regions=$(jq -r --arg m "$MODEL" '.[$m].regions[]' models.json)
for region_id in $regions; do
  read -r lat0 lat1 lon0 lon1 < <(jq -r --arg id "$region_id" \
    '.[$id].bbox | "\(.[0]) \(.[1]) \(.[2]) \(.[3])"' regions.json)
  out="$DIST/${region_id}.grib2"
  rm -f "$out"
  if [ -n "$REGRID_DLON" ]; then
    # Bilinear reprojection onto a regular lat-lon grid spanning the bbox
    # (the last row/column is the last full step inside it), winds rotated
    # to earth-relative, rounded and packed in the same pass.
    nx=$(awk -v a="$lon0" -v b="$lon1" -v d="$REGRID_DLON" 'BEGIN{printf "%d", (b-a)/d + 1.0000001}')
    ny=$(awk -v a="$lat0" -v b="$lat1" -v d="$REGRID_DLAT" 'BEGIN{printf "%d", (b-a)/d + 1.0000001}')
    wgrib2 "$NATIVE" -new_grid_winds earth -new_grid_interpolation bilinear \
      -set_scaling 0 -3 -set_grib_type c3 \
      -new_grid latlon "${lon0}:${nx}:${REGRID_DLON}" "${lat0}:${ny}:${REGRID_DLAT}" "$out" >/dev/null
  else
    cut="$DIST/_cut.grib2"
    wgrib2 "$NATIVE" -small_grib "${lon0}:${lon1}" "${lat0}:${lat1}" "$cut" >/dev/null
    wgrib2 "$cut" -set_grib_type c3 \
      -if ':(PRMSL|PRES):mean sea level:' -set_scaling 0 4  -grib_out "$out" \
      -elseif ':HTSGW:'                   -set_scaling 0 -4 -grib_out "$out" \
      -else                               -set_scaling 0 -3 -grib_out "$out" \
      -endif >/dev/null
    rm -f "$cut"
  fi
  [ -s "$out" ] || { echo "empty cut for $MODEL $region_id" >&2; exit 1; }
  printf '[%s %s] %s → %s bytes, %s messages\n' "$MODEL" "$region_id" "$out" \
    "$(stat -c%s "$out")" "$(wgrib2 "$out" | wc -l)"
done
rm -f "$NATIVE"
