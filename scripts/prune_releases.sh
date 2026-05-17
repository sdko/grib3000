#!/usr/bin/env bash
# Delete dated releases for one model older than <days>. Leaves the
# `<model>-latest` rolling pointer alone.
# Usage: prune_releases.sh <model> [days=7]
set -euo pipefail
MODEL="${1:?model}"
DAYS="${2:-7}"

cutoff_s=$(( $(date -u +%s) - DAYS*86400 ))

gh release list --repo "$GITHUB_REPOSITORY" --limit 200 \
  --json tagName,createdAt \
  | jq -r --arg prefix "$MODEL-" --argjson cutoff "$cutoff_s" '
      .[] |
      select(.tagName | startswith($prefix)) |
      select(.tagName != ($prefix + "latest")) |
      select((.createdAt | fromdateiso8601) < $cutoff) |
      .tagName' \
  | while read -r tag; do
      [ -z "$tag" ] && continue
      echo "delete $tag"
      gh release delete "$tag" --yes --cleanup-tag --repo "$GITHUB_REPOSITORY" || true
    done
