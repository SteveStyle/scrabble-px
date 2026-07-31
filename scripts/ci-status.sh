#!/usr/bin/env bash
set -euo pipefail

# ci-status.sh — Did CI pass for a commit?
#
# Push is the one step of the release that has an *answer* rather than just
# an effect (docs/3.3, step 1.e), and this is how you get it. Relying on
# GitHub's failure emails instead has two problems: they only arrive when
# something breaks, so silence means "passed", "never started" and "went to
# spam" all at once; and they land somewhere other than where you are
# working.
#
# `deploy.sh` runs this as its CI gate, so the check you make by hand and
# the one the release enforces are the same code and cannot drift apart.
#
# Usage:
#   ./scripts/ci-status.sh              # HEAD — ask once, answer now
#   ./scripts/ci-status.sh --wait       # HEAD — block until CI finishes
#   ./scripts/ci-status.sh <commit-ish> # a specific commit
#   ./scripts/ci-status.sh --wait <commit-ish>
#
# Exits 0 only if CI completed successfully for that exact commit.

WAIT=0
COMMITISH="HEAD"
for arg in "$@"; do
  case "$arg" in
    --wait) WAIT=1 ;;
    *) COMMITISH="$arg" ;;
  esac
done

if ! command -v gh > /dev/null; then
  echo "error: 'gh' is not installed — install it and run 'gh auth login'." >&2
  exit 1
fi

# `gh run list --commit` matches full hashes only; a short one silently
# returns nothing, which reads identically to "CI hasn't run".
FULL_SHA="$(git rev-parse "$COMMITISH")"
SHORT_SHA="$(git rev-parse --short "$COMMITISH")"

# CI takes 3-10 minutes; poll gently and give up well after the slowest run
# rather than hanging forever if a run is stuck or was never created.
POLL_SECONDS=10
MAX_ATTEMPTS=120   # 20 minutes

attempt=0
while true; do
  attempt=$((attempt + 1))
  JSON="$(gh run list --commit "$FULL_SHA" --workflow CI --limit 1 \
    --json status,conclusion,url 2>/dev/null || true)"
  STATUS="$(printf '%s' "$JSON" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)"
  CONCLUSION="$(printf '%s' "$JSON" | grep -o '"conclusion":"[^"]*"' | cut -d'"' -f4)"
  URL="$(printf '%s' "$JSON" | grep -o '"url":"[^"]*"' | cut -d'"' -f4)"

  if [[ "$STATUS" == "completed" ]]; then
    break
  fi

  if (( WAIT == 0 )); then
    if [[ -z "$STATUS" ]]; then
      echo "CI: no run found for $SHORT_SHA — has the push landed? GitHub may not have started it yet." >&2
    else
      echo "CI: $SHORT_SHA is still $STATUS." >&2
      [[ -n "$URL" ]] && echo "    $URL" >&2
    fi
    exit 1
  fi

  if (( attempt >= MAX_ATTEMPTS )); then
    echo "CI: gave up waiting for $SHORT_SHA after $(( MAX_ATTEMPTS * POLL_SECONDS / 60 )) minutes (last seen: ${STATUS:-no run})." >&2
    [[ -n "$URL" ]] && echo "    $URL" >&2
    exit 1
  fi

  if (( attempt == 1 )); then
    echo "CI: waiting for $SHORT_SHA${STATUS:+ ($STATUS)}..."
  fi
  sleep "$POLL_SECONDS"
done

if [[ "$CONCLUSION" == "success" ]]; then
  echo "CI: passed for $SHORT_SHA"
  exit 0
fi

echo "CI: $SHORT_SHA concluded '$CONCLUSION', not success." >&2
[[ -n "$URL" ]] && echo "    $URL" >&2
echo "    Fix it and commit again — the release gate will refuse this commit." >&2
exit 1
