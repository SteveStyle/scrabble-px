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
check "keeps the slow-on-both position"  "yes" "$(grep -qE 'ratio, cleaned:\s+2\.000x\s+2\.000x' <<<"$OUT" && echo yes || echo no)"
check "reports the uncleaned ratio too"  "yes" "$(grep -q 'ratio, all moves' <<<"$OUT" && echo yes || echo no)"

# Runs of different benchmarks share no positions and must not be compared.
{ echo "$H"; echo "3,9,9,0,0,7,1.0,1.0"; } > "$TMP/other.csv"
got=0; "$TOOL" "$TMP/ref.csv" "$TMP/other.csv" >/dev/null 2>&1 || got=$?
check "refuses runs with nothing in common" "1" "$got"

got=0; "$TOOL" >/dev/null 2>&1 || got=$?
check "refuses with no arguments"         "2" "$got"

# The self-check the method must pass: runs of the SAME thing, split in two,
# must compare as 1.0. The median-based baseline scored 0.390x on this and the
# minimum scores 1.077x — a stall drags a two-run median up with it and escapes
# rejection, which is invisible until you compare something against itself.
# Ten stalls per run, at turns nothing else stalls on, so that with two runs a
# side the polluted fraction is 10% and reaches the p95 and p99. Two stalls in
# 200 positions would sit below the p99 index and the wrong baseline would pass
# unnoticed, which is what the first version of this fixture did.
mk() { # <file> <first-stalled-turn>
  { echo "$H"
    for i in $(seq 0 199); do
      if [ "$(( (i - $2) % 100 ))" = 0 ] && [ "$i" -ge "$2" ] || [ "$i" = "$2" ]; then
        echo "9,0,$i,0,0,7,60.0,0.5"
      elif [ "$(( i % 20 ))" = "$(( $2 % 20 ))" ]; then
        echo "9,0,$i,0,0,7,60.0,0.5"
      else
        echo "9,0,$i,0,0,7,1.0,1.0"
      fi
    done
  } > "$1"
}
mk "$TMP/x1.csv" 3; mk "$TMP/x2.csv" 7
mk "$TMP/y1.csv" 11; mk "$TMP/y2.csv" 13; mk "$TMP/y3.csv" 17
SELF="$("$TOOL" "$TMP/x1.csv" "$TMP/x2.csv" -- "$TMP/y1.csv" "$TMP/y2.csv" "$TMP/y3.csv")"
check "same input compares as 1.0 at every percentile" "yes" \
  "$(grep -qE 'ratio, per-move means:\s+1\.000x\s+1\.000x\s+1\.000x' <<<"$SELF" && echo yes || echo no)"
# Three subject runs, ten stalls each, and the count reports the subject side.
check "the stalls were discarded, not averaged in" "yes" \
  "$(grep -q '30 stalled timings discarded' <<<"$SELF" && echo yes || echo no)"

check "is registered as a tool" "yes" \
  "$(grep -q 'bench-compare.py' "$(dirname "$TOOL")/../docs/3.0-tools.md" && echo yes || echo no)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
