#!/usr/bin/env bash
set -uo pipefail

# roadmap.sh — what is in each release, in release order, and what waits on what.
#
# `status.sh` answers *per issue*: is the work done, is it in production. That is
# the right shape for "where is this change" and the wrong shape for "what is in
# each release" — which means holding forty issues in your head and grouping them
# yourself. Owner, 2026-08-15: *"status.sh is difficult to parse because it isn't
# ordered in release order."*
#
# **Derived, never maintained.** It reads the milestones and issue bodies every
# time, so it cannot go stale — which a written roadmap could not promise, and is
# the same reason `status.sh` stores nothing.
#
# Order: version milestones oldest first (the next release is at the top), then
# the lanes that feed them, then unmilestoned last — because unmilestoned means
# nobody has decided, and that is worth seeing rather than buried.
#
# Uses `gh`'s embedded `--jq` rather than a standalone `jq`, which is not
# installed here and which nothing else in `scripts/` depends on.

command -v gh > /dev/null || { echo "roadmap.sh needs 'gh' on PATH" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

bold() { printf '\033[1m%s\033[0m' "$1"; }
dim()  { printf '\033[2m%s\033[0m' "$1"; }

rows_for() {   # rows_for <gh-args...>
  gh issue list --state open --limit 200 "$@" \
    --json number,title,labels \
    --jq '.[] | "\(.number)\t\(.title)\t\(.labels | map(.name) | join(","))"' 2>/dev/null
}

print_group() {  # print_group <title> <note> <gh-args...>
  local title="$1" note="$2"; shift 2
  local rows; rows="$(rows_for "$@" | sort -n)"
  [[ -z "$rows" ]] && return
  printf '\n%s' "$(bold "$title")"
  [[ -n "$note" ]] && printf '  %s' "$(dim "$note")"
  printf '\n'
  while IFS=$'\t' read -r num t labels; do
    [[ -z "$num" ]] && continue
    printf '  #%-5s %-62s %s\n' "$num" "${t:0:62}" "$(dim "${labels:0:26}")"
  done <<< "$rows"
}

# --- releases ----------------------------------------------------------------

printf '%s\n' "$(bold 'RELEASES')"
VERSIONS="$(gh api 'repos/{owner}/{repo}/milestones?state=open' \
  --jq '.[].title' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V || true)"
FOUND=0
for v in $VERSIONS; do
  if [[ -n "$(rows_for --milestone "$v")" ]]; then
    print_group "$v" "scheduled" --milestone "$v"; FOUND=1
  fi
done
(( FOUND )) || printf '  %s\n' "$(dim 'no version milestone has open issues')"

# --- the lanes ---------------------------------------------------------------

printf '\n%s\n' "$(bold 'QUEUED — the lane is decided, the release is not')"
print_group "fasttrack" "can ship on its own"            --milestone fasttrack
print_group "minor"     "batched into a minor release"   --milestone minor
print_group "major"     "needs a design note first"      --milestone major
print_group "merge"     "live when merged — no release"  --milestone merge

print_group "NO MILESTONE" "nobody has decided — decide, or it will not happen" \
  --search 'no:milestone'

# --- what waits on what ------------------------------------------------------
#
# Derived from `#N` references in issue bodies, and deliberately called
# "mentioned by" rather than "depends on": the text is unstructured, so this is
# evidence to read rather than a graph to trust. It is still the fastest way to
# see that five issues are queued behind one.

printf '\n%s\n' "$(bold 'MENTIONED BY OTHER OPEN ISSUES')"

OPEN_NUMS="$(gh issue list --state open --limit 200 --json number --jq '.[].number' 2>/dev/null)"
gh issue list --state open --limit 200 --json number,title,body \
  --jq '.[] | "\(.number)\(.title)\(.body // "" | gsub("[\n\r]"; " "))"' 2>/dev/null \
| awk -F'\001' -v open="$OPEN_NUMS" '
    BEGIN { n = split(open, o, "\n"); for (i = 1; i <= n; i++) if (o[i] != "") isopen[o[i]] = 1 }
    {
      from = $1; title[from] = $2; body = $3
      while (match(body, /#[0-9]+/)) {
        ref = substr(body, RSTART + 1, RLENGTH - 1)
        body = substr(body, RSTART + RLENGTH)
        if (ref == from || !(ref in isopen)) continue
        if (seen[ref "," from]++) continue
        by[ref] = by[ref] " #" from; count[ref]++
      }
    }
    END { for (r in count) if (count[r] >= 2) printf "%d\t%d\t%s\t%s\n", count[r], r, title[r], by[r] }' \
| sort -rn \
| while IFS=$'\t' read -r count ref t by; do
    [[ -z "$ref" ]] && continue
    printf '  #%-5s %-44s %s\n' "$ref" "${t:0:44}" "$(dim "$count mentions:$by")"
  done

printf '\n%s\n' "$(dim 'Derived from milestones and issue bodies at run time — nothing here is maintained.')"
