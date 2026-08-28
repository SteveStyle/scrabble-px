#!/usr/bin/env bash
# issue-mentions.sh — how many commits reachable from a ref mention an issue.
#
# Sourced by `deploy.sh` (the milestone gate) and `verify.sh` (the milestone
# check). One function in one file because the alternative was two copies, and
# two copies is how the same defect came to exist in two places: #194 found it
# in `deploy.sh`, and `verify.sh` carried the identical line untouched.
#
# The defect, for anyone tempted to write the obvious thing again:
#
#     git log --oneline "$ref" --grep="#${num}\b" | grep -q .
#
# `grep -q` exits on its first match, `git log` keeps writing, takes SIGPIPE and
# dies with 141. Under `set -o pipefail` the *pipeline* is 141, so the `if`
# takes the else branch — reporting "no commit mentions this" precisely because
# it found one. Measured on #174 from d2adc63, 50 matching commits: 10 runs out
# of 10 report failure.
#
# `git rev-list --count` has no pipe, so there is no race to lose, and it
# answers with a number rather than a boolean — which is more use in the message
# the caller prints.

# commits_mentioning <ref> <issue-number> -> prints a count, always 0 or more.
#
# `|| echo 0` because an unknown ref must not abort a deploy that has already
# passed every other gate: not knowing is reported as "nothing mentions it",
# which is the safe direction — it warns rather than closing an issue silently.
commits_mentioning() {
  local ref="$1" num="$2"
  git rev-list --count "$ref" --grep="#${num}\b" 2>/dev/null || echo 0
}
