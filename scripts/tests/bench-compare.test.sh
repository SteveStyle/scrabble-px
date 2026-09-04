#!/usr/bin/env bash
set -euo pipefail
# bench-compare.test.sh — the pairing and the exclusion, against fixtures.
#
# The tool exists because a VM's p99 is not evidence about the code, and it is
# only correct if it pairs the *same* positions and excludes on the ratio rather
# than on an absolute time. Both are tested here, with a fixture built so that
# an absolute-time rule would give the wrong answer.

TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/bench-compare.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { local d="$1" e="$2" g="$3"
  if [ "$g" = "$e" ]; then echo "  ok       $d"; PASS=$((PASS+1))
  else echo "  FAILED   $d (expected $e, got $g)"; FAIL=$((FAIL+1)); fi }

H="run,game,turn,seat,blanks,rack_tiles,wall_ms,cpu_ms"
{ echo "$H"
  # a genuinely slow position: slow on BOTH machines, ratio 2x — must be kept,
  # even though its absolute time is the largest in the file
  echo "1,0,0,0,1,7,40.0,40.0"
  for i in $(seq 1 98); do echo "1,0,$i,0,0,7,1.0,1.0"; done
  # an ordinary position the hypervisor sat on: ratio 50x — must be excluded
  echo "1,0,99,0,0,7,1.0,1.0"
} > "$TMP/ref.csv"
{ echo "$H"
  echo "2,0,0,0,1,7,80.0,80.0"
  for i in $(seq 1 98); do echo "2,0,$i,0,0,7,2.0,2.0"; done
  echo "2,0,99,0,0,7,50.0,0.2"
} > "$TMP/sub.csv"

OUT="$("$TOOL" "$TMP/ref.csv" "$TMP/sub.csv")"
check "pairs every move"                 "yes" "$(grep -q 'paired on (game, turn): 100 moves' <<<"$OUT" && echo yes || echo no)"
check "excludes exactly the stalled one" "yes" "$(grep -q 'excluded: 1 (1.0%)' <<<"$OUT" && echo yes || echo no)"
# The 40 ms move is four times slower in absolute terms than the 50x one is in
# ratio terms; an absolute-time cut would drop it and report a 2.0x machine.
check "keeps the slow-on-both position"  "yes" "$(grep -qE 'ratio, cleaned:\s+2\.0x\s+2\.0x' <<<"$OUT" && echo yes || echo no)"
check "reports the uncleaned ratio too"  "yes" "$(grep -q 'ratio, all moves' <<<"$OUT" && echo yes || echo no)"

# Runs of different benchmarks share no positions and must not be compared.
{ echo "$H"; echo "3,9,9,0,0,7,1.0,1.0"; } > "$TMP/other.csv"
got=0; "$TOOL" "$TMP/ref.csv" "$TMP/other.csv" >/dev/null 2>&1 || got=$?
check "refuses runs with nothing in common" "1" "$got"

got=0; "$TOOL" >/dev/null 2>&1 || got=$?
check "refuses with no arguments"         "2" "$got"

check "is registered as a tool" "yes" \
  "$(grep -q 'bench-compare.py' "$(dirname "$TOOL")/../docs/3.0-tools.md" && echo yes || echo no)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
