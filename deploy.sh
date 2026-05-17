#!/usr/bin/env bash
# One-shot bootstrapper: init git in this directory, create a GitHub repo
# under <owner>, push main, and kick off the first workflow run.
# Requires: gh CLI authenticated (`gh auth login`).
# Usage: deploy.sh <owner> [repo_name=grib3000]
set -euo pipefail

OWNER="${1:?usage: deploy.sh <owner> [repo_name]}"
REPO="${2:-grib3000}"
SLUG="${OWNER}/${REPO}"

command -v gh >/dev/null || { echo "gh CLI not found — install from https://cli.github.com/" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated — run: gh auth login" >&2; exit 1; }

if [ ! -d .git ]; then
  git init -q -b main
fi

git add .
if git diff --cached --quiet; then
  echo "no changes to commit"
else
  git commit -q -m "Initial commit: grib3000 ($(ls scripts | wc -l) scripts, $(jq -r 'keys | length' regions.json) regions, $(jq -r 'keys | length' models.json) models)"
fi

if gh repo view "$SLUG" >/dev/null 2>&1; then
  echo "repo $SLUG already exists — skipping creation"
else
  gh repo create "$SLUG" --public \
    --description "Pre-baked GRIB files for French coastal sailing zones (ECMWF, GFS, Arpège, Arome)." \
    --source . --remote origin --push
fi

# If the remote existed already, make sure main is pushed.
if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "https://github.com/${SLUG}.git"
fi
git push -u origin main

# Trigger the first run instead of waiting up to an hour for cron.
gh workflow run cycle.yml --repo "$SLUG" || \
  echo "(workflow may not be registered yet — re-run: gh workflow run cycle.yml --repo $SLUG)"

cat <<EOF

Deployed: https://github.com/${SLUG}
  Releases: https://github.com/${SLUG}/releases
  Actions:  https://github.com/${SLUG}/actions

App-facing URLs once the first run completes:
  https://github.com/${SLUG}/releases/download/ecmwf-latest/france-med.grib2
  https://github.com/${SLUG}/releases/download/gfs-latest/atlantique.grib2
  https://github.com/${SLUG}/releases/download/arpege01-latest/manche-mer-du-nord.grib2
EOF
