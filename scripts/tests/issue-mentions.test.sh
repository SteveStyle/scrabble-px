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

# The exact case that fired on a production release: #174 from d2adc63, which
# fifty commits mention. The old `git log … | grep -q .` reports failure here
# ten times out of ten, not intermittently.
check "many commits: counted, not lost to SIGPIPE" "50" "$(commits_mentioning d2adc63 174)"

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
  [[ "$(commits_mentioning d2adc63 174)" == "50" ]] && runs_ok=$((runs_ok + 1))
done
check "ten consecutive runs agree" "10" "$runs_ok"

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
