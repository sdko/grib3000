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
  gfs)
    bash scripts/fetch_gfs.sh "$DATE" "$HOUR" "$NATIVE"
    ;;
  arpege01|arome0025|arome001)
    bash scripts/fetch_mf.sh "$MODEL" "$DATE" "$HOUR" "$NATIVE"
    ;;
  *)
    echo "unknown model: $MODEL" >&2; exit 2
    ;;
esac

# Keep only 10 m wind + gust + MSLP + 2 m temp, regardless of producer.
# Producers vary in what they ship; this normalises the asset to the
# minimum a sailing app needs. UGUST/VGUST: 0.01° AROME has no scalar
# GUST — it publishes gust as u/v components instead.
F="$DIST/_filtered.grib2"
wgrib2 "$NATIVE" \
  -match ':((UGRD|VGRD|UGUST|VGUST):10 m above ground|GUST:[^:]+|PRMSL:mean sea level|TMP:2 m above ground):' \
  -GRIB "$F" >/dev/null
mv "$F" "$NATIVE"

# Bbox-cut for each region the model serves. wgrib2's `-small_grib` takes
# lonW:lonE then latS:latN; coordinates are degrees on the source grid.
regions=$(jq -r --arg m "$MODEL" '.[$m].regions[]' models.json)
for region_id in $regions; do
  read -r lat0 lat1 lon0 lon1 < <(jq -r --arg id "$region_id" \
    '.[$id].bbox | "\(.[0]) \(.[1]) \(.[2]) \(.[3])"' regions.json)
  out="$DIST/${region_id}.grib2"
  wgrib2 "$NATIVE" -small_grib "${lon0}:${lon1}" "${lat0}:${lat1}" "$out" >/dev/null
  printf '[%s %s] %s → %s bytes\n' "$MODEL" "$region_id" "$out" "$(stat -c%s "$out")"
done
rm -f "$NATIVE"
