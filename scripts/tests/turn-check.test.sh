#!/usr/bin/env bash
set -euo pipefail
# turn-check.test.sh — the comment filter, against a fixture rather than GitHub.
#
# This is the part that has failed twice, both times silently, because the real
# pipeline sends stderr to /dev/null and an empty result is indistinguishable
# from a quiet day:
#
#   1. it excluded Claude's comments by testing the body for "Typed by Claude",
#      a convention from when both accounts were one. Nothing had written that
#      marker for weeks, so every comment Claude wrote was reported as Steve's.
#   2. the fix used `--jq --arg me "$ME"`, and `gh api` has no --arg. It failed
#      with "accepts 1 arg(s), received 4" and reported nothing at all.
#
# The filter is fetched with `--print-filter` so the test exercises what the
# script actually runs, rather than a copy that can drift from it.

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.claude/turn-check.sh"
PASS=0; FAIL=0

check() {
  local desc="$1" expect="$2" got="$3"
  if [ "$got" = "$expect" ]; then echo "  ok       $desc"; PASS=$((PASS+1))
  else echo "  FAILED   $desc (expected $expect, got $got)"; FAIL=$((FAIL+1)); fi
}

command -v jq > /dev/null || { echo "  jq not installed, skipping"; exit 0; }

FILTER="$("$HOOK" --print-filter)"
[ -n "$FILTER" ] || { echo "  FAILED: --print-filter printed nothing"; exit 1; }

# The bot login is whatever the filter was built with, so the fixture is written
# against the filter rather than against a hardcoded name.
ME="$(printf '%s' "$FILTER" | sed -n 's/.*select(.user.login != "\([^"]*\)").*/\1/p' | head -1)"
check "the filter names an account to exclude" "yes" "$([ -n "$ME" ] && echo yes || echo no)"

fixture() {
  cat <<JSON
[ {"user":{"login":"$ME"},"issue_url":"https://api.github.com/repos/o/r/issues/1",
   "updated_at":"2026-09-04T09:00:00Z","body":"a note Claude wrote"},
  {"user":{"login":"SteveStyle"},"issue_url":"https://api.github.com/repos/o/r/issues/2",
   "updated_at":"2026-09-04T09:01:00Z","body":"not approved, see the checklist"},
  {"user":{"login":"SteveStyle"},"issue_url":"https://api.github.com/repos/o/r/issues/3",
   "updated_at":"2026-09-04T09:02:00Z","body":"[deploy.sh] deployed 0.7.1 to production"},
  {"user":{"login":"$ME"},"issue_url":"https://api.github.com/repos/o/r/issues/4",
   "updated_at":"2026-09-04T09:03:00Z","body":"Typed by Claude — the old marker, which nothing writes now"} ]
JSON
}

OUT="$(fixture | jq -r "$FILTER")"
N="$(printf '%s' "$OUT" | grep -c '^#' || true)"

check "only the owner's own comment survives"        "1"  "$N"
check "it is the one from issue 2"                   "yes" "$(printf '%s' "$OUT" | grep -q '^#2 ' && echo yes || echo no)"
check "Claude's comment is excluded"                 "yes" "$(printf '%s' "$OUT" | grep -q '^#1 ' && echo no || echo yes)"
check "deploy.sh's comment is excluded"              "yes" "$(printf '%s' "$OUT" | grep -q '^#3 ' && echo no || echo yes)"
check "exclusion is by author, not the old marker"   "yes" "$(printf '%s' "$OUT" | grep -q '^#4 ' && echo no || echo yes)"

# The regression that started this: if the filter matched on body text instead
# of author, comment 4 would be the only one excluded and comment 1 would show.
check "a Claude comment without the marker is still excluded" "yes" \
  "$(printf '%s' "$OUT" | grep -q 'a note Claude wrote' && echo no || echo yes)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
