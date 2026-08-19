#!/usr/bin/env bash
set -uo pipefail

# actions.sh — every outstanding action, in one query.
#
# Owner, 2026-08-19: *"We have issues and comments, but not actions."* And then
# the requirement that decides the shape: *"As long as I can query all actions
# in one go, and not have to go looking."*
#
# **An action is an unchecked task-list item in an open issue's body.** That is
# the only surface we have that can carry state: an issue holds one bit,
# open or closed; a comment is append-only, so it can never be marked done; a
# pull request body freezes at merge. A checkbox in a body can be ticked, is
# rendered and counted by GitHub, and can be promoted to a real issue in one
# click when it turns out to be work. See #181.
#
# **Owner prefix.** `- [ ] (Steve) …` or `- [ ] (Claude) …`, so "waiting on
# you" is derived rather than judged — the same trick the `Typed by` footer
# plays for `inbox.sh`. An item with no prefix is nobody's yet, which is worth
# seeing rather than hiding.
#
# **Continuation lines are joined**, so an action may be wrapped in the body
# without this printing half of it. A line that is indented and does not start a
# new item belongs to the item above.
#
# **Pull requests are listed too**, split by whose turn it is. They are not
# task-list items, but they are the other thing that sits waiting on a person,
# and the point of this script is not having to look in two places.
#
# Read-only, and derived like `status.sh` and `roadmap.sh`: nothing is stored,
# so nothing can drift. The issue body is the record; this is only a view of it.
#
# Uses `gh`'s embedded `--jq`; no standalone `jq` is installed here.

command -v gh > /dev/null || { echo "actions.sh needs 'gh' on PATH" >&2; exit 1; }

WHO=""
case "${1:-}" in
  "")        ;;
  --mine)    WHO="Steve" ;;
  --claude)  WHO="Claude" ;;
  *) echo "usage: actions.sh [--mine|--claude]" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

bold() { printf '\033[1m%s\033[0m' "$1"; }
dim()  { printf '\033[2m%s\033[0m' "$1"; }

# One call for every open issue. `--jq` emits `<number>\t<line>` for every body
# line, and awk does the item assembly — joining wrapped lines and dropping
# everything that is not an unchecked item.
ROWS="$(gh issue list --state open --limit 200 --json number,body \
  --jq '.[] | . as $i | (($i.body // "") | split("\n"))[] | "\($i.number)\t\(.)"' 2>/dev/null \
  | awk -F'\t' '
      function flush() { if (item != "") print num "\t" item; item = "" }
      {
        line = $2
        if (line ~ /^[[:space:]]*- \[ \]/) {
          flush()
          num = $1
          sub(/^[[:space:]]*- \[ \][[:space:]]*/, "", line)
          item = line
        } else if (item != "" && line ~ /^[[:space:]]+[^[:space:]]/ && line !~ /^[[:space:]]*- \[/) {
          sub(/^[[:space:]]+/, " ", line)
          item = item line
        } else {
          flush()
        }
      }
      END { flush() }
  ')"

print_group() {  # print_group <owner-label> <grep-args...>
  local label="$1"; shift
  local rows
  rows="$(printf '%s\n' "$ROWS" | grep "$@" 2>/dev/null)"
  [[ -z "$rows" ]] && return
  printf '\n%s\n' "$(bold "$label")"
  printf '%s\n' "$rows" | while IFS=$'\t' read -r num text; do
    text="${text#\(Steve\) }"; text="${text#\(Claude\) }"
    printf '  %-12s %s\n' "issue #$num" "$text"
  done
}

# Issue numbers and pull request numbers come from one sequence, so a bare `#185`
# does not say which it is. Every row names its kind.
printf '%s  %s\n' "$(bold 'ACTIONS')" "$(dim 'unchecked items in open *issue* bodies — tick them there')"
printf '%s\n' "$(dim "a review checklist lives in a pull request body and is not an action: it is the review itself, and shows under 'To review'")"

if [[ -z "$WHO" || "$WHO" == "Steve" ]]; then
  print_group "Steve" -E $'\t\\(Steve\\) '
fi
if [[ -z "$WHO" || "$WHO" == "Claude" ]]; then
  print_group "Claude" -E $'\t\\(Claude\\) '
fi
if [[ -z "$WHO" ]]; then
  print_group "Unassigned" -vE $'\t\\((Steve|Claude)\\) '
fi

if [[ -z "$ROWS" ]]; then
  printf '  %s\n' "$(dim 'none — no unchecked task-list items in any open issue')"
fi

# Pull requests, which are not task-list items but are the other thing sitting
# waiting on a person. **A review here is a cycle, not an ending** — a design
# note goes out, comes back with questions, is revised and goes out again — so
# what matters is not "approved yet?" but *whose turn is it now*.
#
# The turn is carried by two labels: `awaiting-review` means Steve's, `approved`
# means his review is done and the merge is mine, and neither means it is still
# being written. Approval is a label rather than a GitHub review because a pull
# request author may never approve their own — see below. The two more natural mechanisms are both closed
# to us:
#
#   - **draft -> ready for review** is the obvious signal, and the token cannot
#     set it: `markPullRequestReadyForReview` is refused to a fine-grained PAT
#     and the REST `draft` field is ignored, so only a person in the UI can
#     flip it.
#   - **an approving review** cannot happen at all: a pull request author may
#     never approve their own, and every commit here is authored by the one
#     account. See #171 — an argument for a second account that has nothing to
#     do with attribution.
# The document is named, not just the pull request: what these reviews are *of*
# is a file, and "read #178" costs a click to find out which one. Ranked by
# churn, so a rename (delete plus add) names the file that now exists rather
# than the one that does not.
PRS="$(gh pr list --state open --limit 50 --json number,title,labels,files \
  --jq '.[]
        | ([.labels[].name]) as $l
        | (if ($l | index("approved")) then "merge"
           elif ($l | index("awaiting-review")) then "yours"
           else "mine" end) as $turn
        | ([.files[] | {path: .path, churn: (.additions + .deletions)}] | sort_by(-.churn)) as $f
        | [$turn, .number, .title, ($f[0].path // ""), (($f | length) - 1)] | @tsv' 2>/dev/null)"

print_prs() {  # print_prs <heading> <key> <note>
  local rows; rows="$(printf '%s\n' "$PRS" | grep -E "^$2"$'\t' 2>/dev/null)"
  [[ -z "$rows" ]] && return
  printf '\n%s %s\n' "$(bold "$1")" "$(dim "$3")"
  printf '%s\n' "$rows" | while IFS=$'\t' read -r _ num title path extra; do
    printf '  %-12s %s\n' "PR #$num" "$title"
    [[ -z "$path" ]] && continue
    # Deep paths keep their last two segments: the folder is what identifies
    # `.../174-logs-and-backups/design.md`, and the basename alone would not.
    local short="$path"
    if [[ "$(tr -cd / <<< "$path" | wc -c)" -gt 1 ]]; then
      short=".../${path#"${path%/*/*}/"}"
    fi
    local more=""
    (( extra > 0 )) && more=" $(dim "+$extra more")"
    printf '  %-12s %s%s\n' "" "$short" "$more"
  done
}

if [[ -z "$WHO" || "$WHO" == "Steve" ]]; then
  print_prs "To review" "yours" "(labelled awaiting-review — your turn)"
fi
if [[ -z "$WHO" || "$WHO" == "Claude" ]]; then
  print_prs "To merge" "merge" "(approved — mine to land)"
  print_prs "In hand" "mine" "(not handed over yet)"
fi

printf '\n%s\n' "$(dim 'Read-only, derived at run time — the issue body is the record.')"
