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
  # One API call for every run of this exact head sha; classify by `path`
  # (the workflow file). Run `name` is the display name ("Fuego Wallet CI"),
  # which never equals the filename — matching on name produced 12h of
  # bogus "MISSING for this commit" while both runs had already finished.
  ROWS="$(gh api "repos/$REPO/actions/runs?branch=$BRANCH&head_sha=$HEAD_SHA&per_page=30" \
    --jq '[.workflow_runs[] | {name, path, status, conclusion, id}] | sort_by(.id) | reverse' 2>/dev/null || echo '[]')"
  for WF in "${WORKFLOWS[@]}"; do
    ROW="$(echo "$ROWS" | jq -c ".[] | select(.path == \".github/workflows/$WF\")" | head -1)"
    if [ -z "$ROW" ]; then
      STATE="MISSING for this commit"
      ALL_GREEN=false
    else
      ID="$(echo "$ROW" | jq -r .id)"
      STATUS="$(echo "$ROW" | jq -r .status)"
      CONCLUSION="$(echo "$ROW" | jq -r '.conclusion // "none"')"
      if [ "$STATUS" != "completed" ]; then
        STATE="RUNNING (run=$ID $STATUS)"
        ALL_GREEN=false
      elif [ "$CONCLUSION" = "success" ]; then
        STATE="GREEN (run=$ID)"
      else
        echo "❌ $WF FAILED on head $HEAD_SHA (run=$ID conclusion=$CONCLUSION)"
        echo "   See: gh run view $ID -R $REPO --log-failed"
        exit 2
      fi
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
