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
# **Draft pull requests are listed too.** They are not task-list items, but they
# are the other thing that sits waiting on a person, and the point of this
# script is not having to look in two places.
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
    printf '  %-6s %s\n' "#$num" "$text"
  done
}

printf '%s  %s\n' "$(bold 'ACTIONS')" "$(dim 'unchecked items in open issues — tick them in the issue body')"

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

# Draft PRs: the other thing waiting on a person, and not a task-list item.
if [[ -z "$WHO" || "$WHO" == "Steve" ]]; then
  DRAFTS="$(gh pr list --state open --limit 50 --json number,title,isDraft \
    --jq '.[] | select(.isDraft) | "\(.number)\t\(.title)"' 2>/dev/null)"
  if [[ -n "$DRAFTS" ]]; then
    printf '\n%s %s\n' "$(bold 'Drafts awaiting a read')" "$(dim '(not task-list items)')"
    printf '%s\n' "$DRAFTS" | while IFS=$'\t' read -r num title; do
      printf '  %-6s %s\n' "#$num" "$title"
    done
  fi
fi

printf '\n%s\n' "$(dim 'Read-only, derived at run time — the issue body is the record.')"
