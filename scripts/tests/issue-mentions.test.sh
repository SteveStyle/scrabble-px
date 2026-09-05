#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/issue-mentions.sh under the same `set -euo pipefail` its callers
# run with — which is the whole point. The defect it replaces is **invisible**
# without `pipefail`: the same line reports correctly under `set -eu` and wrongly
# under `set -euo pipefail`, which is how it survived into a production deploy.
#
# The fixtures are real commits in this repository's history, because the
# failure depends on **volume**. A fixture with one matching commit passes
# against the broken code, which is exactly why #194 survived to fire on a real
# release. CI checks out with fetch-depth: 0 for this reason.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/issue-mentions.sh"
failures=0

check() {  # name, expected, actual
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: wanted '$2', got '$3'"
    failures=$((failures + 1))
  fi
}

# The exact case that fired on a production release: #174 from d2adc63. Fifty
# commits *mention* it; **thirty-five carry its trailer**, and the other fifteen
# are documentation commits citing it in prose while belonging to something else
# (D40, #320). Volume is what matters here — the old `git log … | grep -q .`
# reports failure ten times out of ten at this size, not intermittently.
check "many commits: counted, not lost to SIGPIPE" "35" "$(commits_mentioning d2adc63 174)"

# The case that passed against the broken code, and so proved nothing: with one
# matching commit `git log` finishes before `grep -q` bails, so the old pipeline
# reported correctly. A suite built only from cases like this is why #194
# survived to fire on a real release.
check "one commit: still counted" "1" "$(commits_mentioning HEAD 153)"

# The case the gate exists for. A check that can only say yes is not a gate.
check "no commits: reports none" "0" "$(commits_mentioning HEAD 99999)"

# An unknown ref must not abort a deploy that has passed every other gate.
# Not knowing is reported as "nothing mentions it", which warns rather than
# closing an issue silently.
check "unknown ref: 0, and no abort" "0" "$(commits_mentioning no-such-ref-exists 174)"

# `\b` matters: #17 must not match #174, #175, #176… Measured from d2adc63,
# the pattern `#17` without a boundary matches **68** commits and `#17\b`
# matches **1**. Without it the gate would call a stale issue built, on the
# strength of commits belonging to a different one.
check "word boundary: #17 is not #170-something" "1" "$(commits_mentioning d2adc63 17)"

# Ten runs, because the defect this replaces is a race in principle even where
# it is deterministic in practice — a single green run would not distinguish
# "fixed" from "got lucky".
runs_ok=0
for _ in $(seq 1 10); do
  [[ "$(commits_mentioning d2adc63 174)" == "35" ]] && runs_ok=$((runs_ok + 1))
done
check "ten consecutive runs agree" "10" "$runs_ok"

# --- D40: the trailer is the claim, a mention is not -------------------------
#
# The 0.7.2 release was refused by this. `b231721` changed one documentation
# file, carries `Refs #299`, and names #224 and #241 in its prose as examples of
# projects sitting in `no-release`. Counting any `#N` read that as both of them
# shipping — and the gate's own advice, move them into the release milestone,
# would have closed two projects that had shipped nothing.
check "a prose mention does not count (#224 in b231721)" "0" "$(commits_mentioning 9293893 224)"
check "nor does the second one (#241)"                   "0" "$(commits_mentioning 9293893 241)"

# And the trailer still does, on the same commit, for the issue it belongs to.
# Scoped to that one commit with a range: `rev-list <ref>` walks all history
# reachable from it, which is the whole point everywhere else in this file.
check "the trailer on that same commit counts"           "1" "$(commits_mentioning 'b231721^..b231721' 299)"
check "and its prose mention of #224 still does not"     "0" "$(commits_mentioning 'b231721^..b231721' 224)"

# The mixed case, which is the one a looser rule gets wrong in the other
# direction: #103 has four commits mentioning it and three carrying its trailer.
# The fourth is db1b7f6, whose trailer is `Refs #299`.
check "mentions and trailers are told apart (#103)"      "3" "$(commits_mentioning 9293893 103)"

# `Closes` counts too — `CLAUDE.md` reserves it for a change that never leaves
# the repository, but it is still a claim of ownership.
closes_form="$(git log --format=%B -400 | grep -cE '^Closes #[0-9]+' || true)"
check "the history really does use Closes, so that arm is exercised"   "1" "$([[ "$closes_form" -gt 0 ]] && echo 1 || echo 0)"

# The defect itself, asserted rather than described: the shape this function
# exists to replace still fails, so this test would notice if somebody
# reintroduced it believing it worked.
old_shape_status=0
( set -euo pipefail; git log --oneline d2adc63 --grep="#174\b" 2>/dev/null | grep -q . ) \
  || old_shape_status=$?
check "the old pipeline still fails, so this is not cargo cult" "141" "$old_shape_status"

if (( failures )); then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo
echo "All issue-mentions tests passed."
