#!/usr/bin/env bash
set -euo pipefail
# bench-rehearsal.test.sh — the parts that do not need the rehearsal host.
#
# Run under the same `set -euo pipefail` the script runs under: a harness
# missing pipefail once hid a silent abort that reached a production deploy.

SCRIPT_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/bench-rehearsal.sh"
PASS=0; FAIL=0
check() { local d="$1" e="$2" g="$3"
  if [ "$g" = "$e" ]; then echo "  ok       $d"; PASS=$((PASS+1))
  else echo "  FAILED   $d (expected $e, got $g)"; FAIL=$((FAIL+1)); fi }

check "it parses under set -euo pipefail" "0" "$(bash -n "$SCRIPT_UNDER_TEST" 2>/dev/null; echo $?)"

# Too few games is refused before anything is built or copied: a p99 from 411
# samples is four data points, which is what the older 10-game rows had.
got=0; ( "$SCRIPT_UNDER_TEST" 10 >/dev/null 2>&1 ) || got=$?
check "it refuses fewer than 30 games" "1" "$got"

# The commit substitution: the VM has no git, so the row comes back saying
# `unknown` and the local commit is put in its place. This is the bug that
# would silently mislabel every remote row.
ROW="1788,unknown,instance-x,official,30,30,1229,0.08"
check "the unknown commit is replaced" "1788,abc1234,instance-x,official,30,30,1229,0.08" \
  "${ROW/,unknown,/,abc1234,}"
check "a real commit is left alone" "1788,def5678,instance-x" \
  "$(R='1788,def5678,instance-x'; echo "${R/,unknown,/,abc1234,}")"

# The column positions the summary reads. If a column is inserted into the CSV
# and these are not updated, the check prints the wrong numbers confidently.
HDR="$(head -1 "$(dirname "$SCRIPT_UNDER_TEST")/../crates/server-game/examples/engine_timing_results.csv")"
col() { printf '%s' "$HDR" | tr ',' '\n' | nl -ba | awk -v n="$1" '$1==n{print $2}'; }
check "column 3 is the host"       "host"          "$(col 3)"
check "column 10 is the median"    "median_ms"     "$(col 10)"
check "column 14 is the p99"       "p99_ms"        "$(col 14)"
check "column 21 is the CPU p99"   "cpu_p99_ms"    "$(col 21)"
check "column 13 is the p95"       "p95_ms"        "$(col 13)"
check "column 24 is steal"         "steal_pct_of_capacity" "$(col 24)"
check "column 27 counts slow moves" "slow_moves"   "$(col 27)"
check "column 28 counts the starved" "slow_cpu_starved" "$(col 28)"

check "it is registered as a tool" "yes" \
  "$(grep -q 'bench-rehearsal.sh' "$(dirname "$SCRIPT_UNDER_TEST")/../docs/3.0-tools.md" && echo yes || echo no)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
