#!/usr/bin/env bash
set -euo pipefail

# status.sh — Where every open change currently is, in one screen.
#
# **This is a view, not a tracking system.** It stores nothing and records
# nothing. Every column is derived from something that is already true:
#
#   is the work done          issue open/closed
#   is it in production       milestone open/closed
#   is it being worked on     a branch named `issue-<N>-*` exists
#   merged, awaiting release  git merge-base --is-ancestor <branch> origin/main
#   what type of change       the issue's type label (docs/3.3, "The six types")
#   what is live right now    GET /health
#
# Because nothing is stored, nothing can drift and there is nothing to keep
# up to date — which is the whole reason to derive status rather than record
# it. The cost of that choice is that the view is only as good as the branch
# naming convention: a branch not named `issue-<N>-*` leaves its issue
# showing "not started". That is deliberate. The convention is what makes
# the work findable, and a view that quietly papered over a mis-named branch
# would remove the one signal that the convention had slipped.
#
# Usage:
#   ./scripts/status.sh            # open changes + what production is running
#   ./scripts/status.sh --fetch    # `git fetch` first, for accurate ancestry
#
# Needs `gh` authenticated (same as deploy.sh's milestone handling).

PROD_URL="${PROD_URL:-https://tileliteelite.com}"
STAGING_URL="${STAGING_URL:-http://localhost:8081}"

if [[ "${1:-}" == "--fetch" ]]; then
  echo "==> Fetching"
  git fetch --quiet origin
fi

if ! command -v gh > /dev/null 2>&1; then
  echo "error: needs the GitHub CLI (gh) on PATH and authenticated." >&2
  exit 1
fi

# Every `grep` below is guarded with `|| true`. Under `set -o pipefail` a
# grep that matches nothing exits 1, and inside a command substitution that
# status propagates out and kills the assignment — which is how a silent
# abort once reached a production deploy (docs/3.3, "Rolling back").
version_of() {
  curl -sf --max-time 5 "$1/health" 2>/dev/null \
    | grep -o '"app_version":"[^"]*"' 2>/dev/null | cut -d'"' -f4 || true
}

echo "==> Environments"
printf '    %-12s %s\n' "production" "$(v=$(version_of "$PROD_URL"); echo "${v:-unreachable}")"
printf '    %-12s %s\n' "staging" "$(v=$(version_of "$STAGING_URL"); echo "${v:-not running}")"
echo

# The branch for an issue, preferring a local one (that is what you are
# working in) over its remote copy. Printed in the "in progress" line so a
# mis-named or forgotten branch is visible rather than merely absent.
branch_for_issue() {
  git branch --list "issue-$1-*" --format='%(refname:short)' 2>/dev/null | head -1 \
    || true
}
remote_branch_for_issue() {
  git branch --remotes --list "origin/issue-$1-*" --format='%(refname:short)' 2>/dev/null \
    | head -1 || true
}

state_of_issue() {
  local num="$1" branch
  branch="$(branch_for_issue "$num")"
  [[ -z "$branch" ]] && branch="$(remote_branch_for_issue "$num")"

  if [[ -z "$branch" ]]; then
    echo "not started"
    return
  fi
  # A branch that is still exactly origin/main carries no commits yet, so it
  # is an ancestor trivially. Checking that first stops a branch created
  # seconds ago from reporting itself as merged — which it did, on the very
  # branch this script was written on.
  if [[ "$(git rev-parse "$branch" 2>/dev/null)" == "$(git rev-parse origin/main 2>/dev/null)" ]]; then
    echo "branched, no commits ($branch)"
  # Merged means "its commits are reachable from origin/main" — which is
  # true for a fast-forward merge and stays true if the branch is later
  # deleted, unlike anything that inspects the branch itself.
  elif git merge-base --is-ancestor "$branch" origin/main 2>/dev/null; then
    echo "merged, awaiting release"
  else
    echo "in progress ($branch)"
  fi
}

# One type label per issue — see docs/3.3, "The six types of change". An
# issue with none reads "unclassified", which is the point: the gap is a
# prompt to classify it, not something to paper over with a default.
type_of() {
  case "$1" in
    *documentation*)    echo "documentation" ;;
    # `non-prod-tooling` must be tested before `prod-tooling`: the second
    # pattern is a substring of the first, so the wrong order would report
    # every non-production change as production tooling.
    *non-prod-tooling*) echo "non-prod-tooling" ;;
    *prod-tooling*)     echo "prod-tooling" ;;
    *major-function*)   echo "major-function" ;;
    *minor-function*)   echo "minor-function" ;;
    *bug*)              echo "defect fix" ;;
    *)                  echo "unclassified" ;;
  esac
}

echo "==> Open changes"
printf '    %-4s %-40s %-16s %s\n' "#" "TITLE" "TYPE" "STATE"
printf '    '; printf '%.0s-' {1..96}; echo

ISSUES="$(gh issue list --state open --limit 100 \
  --json number,title,labels,milestone \
  -q '.[] | [.number, .title, (.labels | map(.name) | join(",")), (.milestone.title // "")] | @tsv' \
  2>/dev/null || true)"

if [[ -z "$ISSUES" ]]; then
  echo "    (none open)"
else
  while IFS=$'\t' read -r num title labels milestone; do
    [[ -z "$num" ]] && continue
    state="$(state_of_issue "$num")"
    [[ -n "$milestone" ]] && state="$state · $milestone"
    printf '    %-4s %-40s %-16s %s\n' "$num" "${title:0:40}" "$(type_of "$labels")" "$state"
  done <<< "$(printf '%s' "$ISSUES" | sort -n)"
fi
echo

# Closed issue + open milestone = the work is done but has not shipped.
# This is the section that answers "what is waiting to go out", which is the
# question the issue list alone cannot answer.
echo "==> Done, not yet released"
AWAITING="$(gh issue list --state closed --limit 100 \
  --json number,title,milestone \
  -q '.[] | select(.milestone != null) | [.number, .title, .milestone.title] | @tsv' \
  2>/dev/null || true)"

OPEN_MILESTONES="$(gh api "repos/{owner}/{repo}/milestones?state=open" \
  -q '.[].title' 2>/dev/null || true)"

FOUND=0
if [[ -n "$AWAITING" && -n "$OPEN_MILESTONES" ]]; then
  while IFS=$'\t' read -r num title milestone; do
    [[ -z "$num" ]] && continue
    if grep -qxF "$milestone" <<< "$OPEN_MILESTONES" 2>/dev/null; then
      printf '    %-4s %-40s %s\n' "$num" "${title:0:40}" "$milestone"
      FOUND=1
    fi
  done <<< "$AWAITING"
fi
(( FOUND == 0 )) && echo "    (nothing waiting — everything closed is live)"

echo
echo "    Types: docs/3.3, \"The six types of change\"."
echo "    A branch not named issue-<N>-* shows as \"not started\" — rename it."
