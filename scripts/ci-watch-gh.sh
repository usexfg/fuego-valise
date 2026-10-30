#!/bin/bash
# Watches the CI runs for PR #14's head commit on usexfg/fuego-valise.
#
# Verdict rules (no green until evidence):
#   - Reports only from live run objects (gh api), not assumptions.
#   - Green requires: for every monitored workflow, the LATEST run for the
#     branch's CURRENT head commit has status=completed AND conclusion=success.
#   - If the latest run belongs to an older commit, it insists on a newer run.
#   - Exits 0 ONLY on full green; nonzero otherwise.
#
# Usage: ./scripts/ci-watch-gh.sh [branch]   (default: fix/ci-workflows-all-os)
# Env:   CI_WATCH_INTERVAL=seconds (default 60)
set -uo pipefail

REPO="${GH_REPO:-usexfg/fuego-valise}"
BRANCH="${1:-fix/ci-workflows-all-os}"
WORKFLOWS=("fuego-wallet-ci.yml" "fuego-wallet-mobile-ci.yml")
INTERVAL="${CI_WATCH_INTERVAL:-60}"

HEAD_SHA="$(git rev-parse HEAD)" || exit 1
echo "Watching $REPO branch=$BRANCH head=$(git rev-parse --short HEAD)"
echo "Green requires every workflow's newest run to be completed+success for head $HEAD_SHA"

while true; do
  CURRENT_SHA="$(git rev-parse HEAD 2>/dev/null || echo "$HEAD_SHA")"
  if [ "$CURRENT_SHA" != "$HEAD_SHA" ]; then
    echo "⏳ HEAD moved to $CURRENT_SHA; switching watch target"
    HEAD_SHA="$CURRENT_SHA"
  fi

  ALL_GREEN=true
  SUMMARY=""
  for WF in "${WORKFLOWS[@]}"; do
    ROW="$(gh api "repos/$REPO/actions/runs?workflow=$WF&branch=$BRANCH&per_page=1" \
      --jq '.workflow_runs[0] // {}' 2>/dev/null || echo '{}')"
    STATUS="$(echo "$ROW" | jq -r '.status // "none"')"
    CONCLUSION="$(echo "$ROW" | jq -r '.conclusion // "none"')"
    RUN_SHA="$(echo "$ROW" | jq -r '.head_sha // "none"')"
    RUN_ID="$(echo "$ROW" | jq -r '.id // "none"')"
    RUN_NAME="$(echo "$ROW" | jq -r '.display_title // "none"')"
    if [ "$RUN_SHA" != "$HEAD_SHA" ]; then
      STATE="STALE/MISSING (sha=$RUN_SHA)"
      ALL_GREEN=false
    elif [ "$STATUS" != "completed" ]; then
      STATE="RUNNING (run=$RUN_ID $STATUS)"
      ALL_GREEN=false
    elif [ "$CONCLUSION" = "success" ]; then
      STATE="GREEN (run=$RUN_ID)"
    else
      STATE="FAILED (run=$RUN_ID conclusion=$CONCLUSION)"
      ALL_GREEN=false
    fi
    SUMMARY="$SUMMARY
  $WF: $STATE"
  done

  echo "=== verdict $(date +%H:%M:%S) ===$SUMMARY"
  if [ "$ALL_GREEN" = true ]; then
    echo "✅ ALL CI JOBS VERIFIED GREEN (all OSes) for $HEAD_SHA"
    exit 0
  fi
  sleep "$INTERVAL"
done
