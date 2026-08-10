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
#   merged, awaiting release  a `Refs #N` commit is on origin/main
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
# The rehearsal host comes from the file that defines it, not a second copy —
# rehearsal-target.sh's own comment is the reason: two definitions eventually
# disagree, and the one that disagrees silently points somewhere wrong.
#
# Read in a *subshell* regardless: that file exports variables meant for
# deploy.sh, and this script only wants one value out of it. Before #24 the
# variable was called PROD_URL, and sourcing it directly overwrote
# production's URL with the rehearsal one — this script reported the
# rehearsal host on both lines, which looked plausible because they are
# usually on the same commit.
REHEARSAL_URL="${REHEARSAL_URL:-$(
  . "$(cd "$(dirname "$0")" && pwd)/rehearsal-target.sh" > /dev/null 2>&1
  printf '%s' "$TARGET_URL"
)}"
# `STAGING_URL` honoured as a fallback, as deploy.sh does: preview is what
# used to be called staging before #22 renamed the files.
PREVIEW_URL="${PREVIEW_URL:-${STAGING_URL:-http://localhost:8081}}"

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

# How far behind `main` an environment is, in commits. Answers "is this stale,
# and by how much" without having to compare two hashes by eye. `--` guards a
# build id that is not a commit this checkout knows.
behind_main() {
  local version="$1" sha
  sha="${version#*+}"
  [[ -z "$version" || "$sha" == "$version" ]] && { echo ""; return; }
  git rev-parse -q --verify "$sha^{commit}" > /dev/null 2>&1 || { echo "unknown commit"; return; }
  local n
  n="$(git rev-list --count "$sha..origin/main" 2>/dev/null || true)"
  case "$n" in
    "" ) echo "" ;;
    0  ) echo "up to date with main" ;;
    1  ) echo "1 commit behind main" ;;
    *  ) echo "$n commits behind main" ;;
  esac
}

echo "==> Environments"
PROD_V="$(version_of "$PROD_URL")"
REHEARSAL_V="$(version_of "$REHEARSAL_URL")"
PREVIEW_V="$(version_of "$PREVIEW_URL")"
printf '    %-12s %-18s %-28s %s\n' "production" "${PROD_V:-unreachable}" "$(behind_main "$PROD_V")" "what users have"
printf '    %-12s %-18s %-28s %s\n' "rehearsal" "${REHEARSAL_V:-not running}" "$(behind_main "$REHEARSAL_V")" "what the release gate checks"
printf '    %-12s %-18s %-28s %s\n' "preview" "${PREVIEW_V:-not running}" "$(behind_main "$PREVIEW_V")" "what you last looked at"
echo

# What a release from `main` would put out, right now.
#
# `Open changes` below answers "where is each change"; this answers the other
# question, which is the one asked immediately before deciding to ship: *what
# am I about to release, and is it the right kind of version?* Scanning thirty
# rows for "merged, awaiting release" is not the same thing, and it misses the
# commits that carry no issue at all — docs, tooling, the version bump — which
# is most of what usually sits in main.
echo "==> A release from main would ship"
MAIN_VERSION="$(git show origin/main:Cargo.toml 2>/dev/null | grep -m1 '^version' | cut -d'"' -f2 || true)"
LAST_PROD_TAG="$(git tag --list 'prod-[0-9]*' 2>/dev/null \
  | sed 's/^prod-//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)"

if [[ -z "$LAST_PROD_TAG" ]]; then
  printf '    %s\n' "no prod-* tag yet, so there is nothing to compare against"
else
  RANGE="prod-$LAST_PROD_TAG..origin/main"
  COMMIT_COUNT="$(git rev-list --count --no-merges "$RANGE" 2>/dev/null || echo 0)"
  printf '    %-12s %s\n' "version" "$MAIN_VERSION  (production has $LAST_PROD_TAG)"
  printf '    %-12s %s\n' "commits" "$COMMIT_COUNT on main since prod-$LAST_PROD_TAG"

  # Issues referenced by those commits, in the order they were merged.
  SHIPPING="$(git log "$RANGE" --no-merges -E --format=%s 2>/dev/null \
    | grep -oE 'Refs #[0-9]+' 2>/dev/null | grep -oE '[0-9]+' | sort -un || true)"
  # `Refs` lives in the body as often as the subject, so look there too.
  SHIPPING="$(printf '%s\n%s' "$SHIPPING" "$(git log "$RANGE" --no-merges --format=%b 2>/dev/null \
    | grep -oE 'Refs #[0-9]+' 2>/dev/null | grep -oE '[0-9]+' || true)" | sort -un | grep . || true)"

  if [[ -z "$SHIPPING" ]]; then
    printf '    %-12s %s\n' "issues" "none — nothing on main references an issue"
  else
    FUNCTIONAL=""
    while read -r num; do
      [[ -z "$num" ]] && continue
      meta="$(gh issue view "$num" --json title,labels \
        --jq '"\(.title)\t\([.labels[].name] | join(","))"' 2>/dev/null || true)"
      title="${meta%%$'\t'*}"
      labels="${meta#*$'\t'}"
      [[ -z "$meta" ]] && { title="(could not read issue)"; labels=""; }
      # Not everything on main reaches users at a release. Documentation and
      # non-production tooling run from the working tree or the repo, so they
      # were live the moment they merged — listing them as "ships" would
      # overstate what a deploy is actually putting out.
      case "$labels" in
        *documentation*|*non-prod-tooling*) reach="live at merge" ;;
        *prod-tooling*)                     reach="live at merge, unless it is admin-cli" ;;
        *)                                  reach="reaches users" ;;
      esac
      printf '    %-12s #%-4s %-40s %-16s %s\n' \
        "ships" "$num" "$(printf '%.40s' "$title")" "$labels" "$reach"
      case "$labels" in *major-function*|*minor-function*) FUNCTIONAL="yes" ;; esac
    done <<< "$SHIPPING"

    # The same judgement check-release-version.sh makes at deploy time, made
    # here instead — before the work of a preview and a rehearsal, rather than
    # after it.
    if [[ -n "$FUNCTIONAL" && "${MAIN_VERSION%.*}" == "${LAST_PROD_TAG%.*}" ]]; then
      printf '    %-12s %s\n' "warning" "functional change in a patch bump — see docs/3.3, \"Releases are branches\""
    fi
  fi
fi
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
  local num="$1" type="${2:-}" branch
  branch="$(branch_for_issue "$num")"
  [[ -z "$branch" ]] && branch="$(remote_branch_for_issue "$num")"

  # Ask main's history first, not the branches. A merged change has its
  # branch deleted, so branch-only detection reported finished work as "not
  # started" — which it did for three issues the moment they were merged.
  # `Refs #N` is in every commit by convention, and unlike a branch it is
  # permanent. The trailing guard stops #1 matching "Refs #19".
  if git log origin/main -E --grep="Refs #${num}([^0-9]|\$)" \
       --format=%h 2>/dev/null | grep -q .; then
    # Only the types that change the app wait for a release. Documentation
    # and non-production tooling are finished at merge, so say so as an
    # action rather than leaving them looking blocked on something.
    case "$type" in
      documentation)    echo "merged — close it" ;;
      non-prod-tooling) echo "merged — smoke-test, then close" ;;
      *)                echo "merged, awaiting release" ;;
    esac
    return
  fi

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
  # A branch whose commits are all in main but which carries no `Refs #N`
  # — an older change, or one whose trailer was forgotten.
  elif git merge-base --is-ancestor "$branch" origin/main 2>/dev/null; then
    echo "merged (no Refs trailer)"
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
    *appearance*)       echo "appearance" ;;
    *)                  echo "unclassified" ;;
  esac
}

# Width available for the title: whatever the terminal has left after the
# fixed columns. Titles were cut at 40 characters with no ellipsis, so a
# truncated one read as a complete one — "DTO conversion belongs at the
# boundary," looked like the whole issue.
#
# 22 covers the number and type columns and their gaps; 30 leaves room for
# the longest state ("merged — smoke-test, then close"). Falls back to 100
# columns when there is no terminal, so piping to a file stays readable.
TERM_COLS="${COLUMNS:-$(tput cols 2> /dev/null || echo 100)}"
TITLE_WIDTH=$((TERM_COLS - 22 - 30))
(( TITLE_WIDTH < 30 )) && TITLE_WIDTH=30

# Cut to fit and pad to the column, with a trailing ellipsis only when
# something was actually cut.
#
# Padded here rather than with printf's `%-Ns`, which pads to a width in
# *bytes* while `${#title}` counts *characters*. An em-dash is 3 bytes and one
# display column, so every one in a title cost two spaces of padding and the
# columns after it drifted left. The ellipsis is multi-byte too, so truncated
# rows drifted as well.
fit_title() {
  local title="$1"
  if (( ${#title} > TITLE_WIDTH )); then
    title="${title:0:$((TITLE_WIDTH - 1))}…"
  fi
  local padding=$(( TITLE_WIDTH - ${#title} ))
  printf '%s' "$title"
  (( padding > 0 )) && printf '%*s' "$padding" ''
  return 0
}

echo "==> Open changes"
printf "    %-4s %-${TITLE_WIDTH}s %-16s %s\n" "#" "TITLE" "TYPE" "STATE"
printf '    '; printf '%*s' $((TITLE_WIDTH + 44)) '' | tr ' ' '-'; echo

ISSUES="$(gh issue list --state open --limit 100 \
  --json number,title,labels,milestone \
  -q '.[] | [.number, .title, (.labels | map(.name) | join(",")), (.milestone.title // "")] | @tsv' \
  2>/dev/null || true)"

if [[ -z "$ISSUES" ]]; then
  echo "    (none open)"
else
  while IFS=$'\t' read -r num title labels milestone; do
    [[ -z "$num" ]] && continue
    TYPE="$(type_of "$labels")"
    state="$(state_of_issue "$num" "$TYPE")"
    [[ -n "$milestone" ]] && state="$state · $milestone"
    printf "    %-4s %s %-16s %s\n" "$num" "$(fit_title "$title")" "$TYPE" "$state"
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
      printf "    %-4s %s %s\n" "$num" "$(fit_title "$title")" "$milestone"
      FOUND=1
    fi
  done <<< "$AWAITING"
fi
(( FOUND == 0 )) && echo "    (nothing waiting — everything closed is live)"

echo
echo "    Types: docs/3.3, \"The six types of change\"."
echo "    A branch not named issue-<N>-* shows as \"not started\" — rename it."
