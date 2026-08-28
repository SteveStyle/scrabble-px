#!/usr/bin/env bash
set -uo pipefail

# inbox.sh — what has been said on GitHub since you last looked.
#
# GitHub knows, and tells nobody here: `gh api notifications` needs a
# `notifications` *user* permission this repository's token does not carry, and
# adding an account-wide permission to read one repository is the wrong trade.
# The comments endpoint is repo-scoped and needs nothing we do not already have.
#
# It exists because a conversation only works if both sides can see it. Owner,
# 2026-08-18, after replying to a comment and having to say so out loud:
#
#   > I have replied to your comment, there should be a way of being notified,
#   > or seeing updates in GitHub.
#
# **Seven days by default.** Not because a week is the natural rhythm, but
# because the current one will not last. Owner, same day: *"Right now I am
# working on this most days, but that won't last forever."* A default sized for
# today's cadence would be exactly wrong on the first day it changed.
#
# **Grouped by issue, oldest first inside each.** A flat chronological list
# across issues interleaves three conversations and reads as none of them. This
# way a thread arrives whole, in the order it was written.
#
# **`>` marks a comment Steve typed** — the ones worth reading, whichever of us
# is running this. `deploy.sh` announces its own releases and is neither party's,
# so it is matched by its opening text and dimmed rather than being counted as
# somebody's remark.
# Claude footers everything it posts (see #169), so the absence of one means the owner typed it — which on an issue
# means a point not yet discussed. That was not what the footer was for, but it
# is what makes this a filter rather than a wall of text.
#
# Read-only, and stateless like `status.sh`: no "last read" file to go stale,
# drift between machines, or need clearing when it is wrong. You pass the window.
#
# Uses `gh`'s embedded `--jq`; no standalone `jq` is installed here.

command -v gh > /dev/null || { echo "inbox.sh needs 'gh' on PATH" >&2; exit 1; }

DAYS="${1:-7}"
if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || (( DAYS < 1 )); then
  echo "usage: inbox.sh [days]   (a whole number of days, default 7)" >&2
  exit 2
fi

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

SINCE="$(date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)"

bold() { printf '\033[1m%s\033[0m' "$1"; }
dim()  { printf '\033[2m%s\033[0m' "$1"; }

printf '%s  %s\n' "$(bold 'INBOX')" "$(dim "since $SINCE — $DAYS day(s)")"

# Issue and PR comments share one endpoint and one number sequence, so this
# catches both. `since` is on *updated*, so an edited older comment surfaces
# too — which is right: an edit is a change you have not seen.
COMMENTS="$(gh api "repos/{owner}/{repo}/issues/comments?since=$SINCE&sort=updated&direction=asc&per_page=100" \
  --paginate \
  --jq '.[] | [(.issue_url | split("/") | last), .updated_at[0:16], (if (.body | test("Typed by Claude")) then "claude" elif (.body | test("^Released in prod-")) then "deploy" else "you" end), (.body | gsub("\n"; " ") | .[0:150])] | @tsv' 2>/dev/null)"

# PR review comments live on a different endpoint entirely — inline code
# comments are not issue comments, and a review left on a diff would otherwise
# be invisible here.
REVIEWS="$(gh api "repos/{owner}/{repo}/pulls/comments?since=$SINCE&sort=updated&direction=asc&per_page=100" \
  --paginate \
  --jq '.[] | [(.pull_request_url | split("/") | last), .updated_at[0:16], (if (.body | test("Typed by Claude")) then "claude" else "you" end), ("(review) " + (.body | gsub("\n"; " ") | .[0:140]))] | @tsv' 2>/dev/null)"

ALL="$(printf '%s\n%s\n' "$COMMENTS" "$REVIEWS" | grep -v '^$' | sort -t$'\t' -k1,1n -k2,2)"

# The issue list, fetched once and used twice: for the headings above and the
# opened/closed section below. It was two calls asking the same question with
# different `--json` fields — 1.2s each, and the largest avoidable cost in the
# script. Measured after the owner noticed the first section was slow.
#
# Not parallelised. The three remaining calls could run at once and save about
# a second and a half, but background jobs in bash bring temp-file cleanup and
# exit-status handling with them, and this repository has already shipped one
# production bug to a shell subtlety. A second and a half, once a day, is not
# worth that.
ISSUES="$(gh issue list --state all --limit 200 \
  --json number,title,createdAt,closedAt \
  --jq '.[] | [(.number|tostring), .title, .createdAt, (.closedAt // "")] | @tsv' 2>/dev/null)"

if [[ -z "$ALL" ]]; then
  printf '\n  %s\n' "$(dim 'no comments in this window')"
else
  declare -A TITLE
  while IFS=$'\t' read -r n t; do
    [[ -n "$n" ]] && TITLE[$n]="${t:0:66}"
  done < <(printf '%s\n' "$ISSUES" | cut -f1,2)

  last=""
  while IFS=$'\t' read -r num when who body; do
    [[ -z "$num" ]] && continue
    if [[ "$num" != "$last" ]]; then
      printf '\n%s  %s\n' "$(bold "#$num")" "$(dim "${TITLE[$num]:-}")"
      last="$num"
    fi
    case "$who" in
      you)    printf '  %s %s  %s\n' "$(bold '>')" "$(dim "$when")" "$body" ;;
      deploy) printf '    %s  %s\n' "$(dim "$when")" "$(dim "[deploy.sh] $body")" ;;
      *)      printf '    %s  %s\n' "$(dim "$when")" "$(dim "$body")" ;;
    esac
  done <<< "$ALL"
fi

# Issues opened or closed in the window. Comments show what was *said*; this
# shows what was *decided*, which a comment listing never reveals — an issue
# closed in silence produces no comment at all.
printf '\n%s\n' "$(bold 'OPENED OR CLOSED')"
# `gh --jq` takes no `--arg`, so the window is interpolated by the shell. Found
# by this script reporting nothing on a day four issues opened and four closed:
# the malformed call failed into `2>/dev/null` and looked like a quiet week.
EVENTS="$(printf '%s\n' "$ISSUES" | awk -F'\t' -v since="$SINCE" '
  $3 >= since && $4 >= since { print $1 "\tboth\t"   $2; next }
  $3 >= since               { print $1 "\topened\t" $2; next }
  $4 != "" && $4 >= since   { print $1 "\tclosed\t" $2 }
' | sort -n)"
if [[ -z "$EVENTS" ]]; then
  printf '  %s\n' "$(dim 'nothing opened or closed')"
else
  while IFS=$'\t' read -r num what title; do
    [[ -z "$num" ]] && continue
    # An issue opened *and* closed inside the window needs saying: reporting
    # only "opened" reads as still-open, which after a week away is the one
    # thing you would act on wrongly.
    [[ "$what" == "both" ]] && what="opened+closed"
    printf '  #%-5s %-13s %s\n' "$num" "$what" "${title:0:56}"
  done <<< "$EVENTS"
fi

printf '\n%s\n' "$(dim "Read-only, and derived at run time — nothing here is maintained. '>' is what Steve typed.")"
