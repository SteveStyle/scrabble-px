#!/usr/bin/env bash
set -euo pipefail
# bench-rehearsal.sh — run the engine timing benchmark on rehearsal's hardware
# and record the row, as part of a release's technical tests.
#
# **A check, not a gate.** It prints the new row beside the last one for the
# same host and exits 0 either way. Timings move for reasons that are not
# regressions, and a threshold that failed a release on a noisy p99 would be
# routed around within two releases — so a person decides.
#
# **Rehearsal, not CI.** GitHub's runners are shared and their speed varies
# between runs, so a timing taken there cannot be compared with the one before
# it. Rehearsal is the same hardware as production, measured rather than
# assumed: both are AMD EPYC 7551, 2 cores, 954 MB.
#
# **Why the binary is copied.** Neither VM has a Rust toolchain and both run the
# same glibc as the development machine, so it is built here. `git` is not on
# the VM either, so the row comes back with `unknown` for the commit and this
# script substitutes the one the binary was actually built from.
#
# Raised by #291 R7. Usage: ./scripts/bench-rehearsal.sh [games]

GAMES="${1:-30}"
EDITION="${2:-official}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV="$REPO/crates/server-game/examples/engine_timing_results.csv"
BIN="$REPO/target/release/examples/engine_timing_bench"

# shellcheck source=/dev/null
. "$REPO/scripts/rehearsal-target.sh"

SSH=(ssh -n -o BatchMode=yes -o ConnectTimeout=10)
[ -f "$DEPLOY_SSH_KEY" ] && SSH+=(-i "$DEPLOY_SSH_KEY")
TARGET="$DEPLOY_USER@$DEPLOY_HOST"

# 30 games is not arbitrary: it yields ~1229 samples, and the p99 of the older
# 10-game runs came from 411 samples, which is four data points.
if [ "$GAMES" -lt 30 ]; then
  echo "refusing $GAMES games: a p99 needs about 1200 samples, which is 30 games" >&2
  exit 1
fi

echo "==> building the benchmark"
cargo build --release --example engine_timing_bench -p server-game --quiet

COMMIT="$(git -C "$REPO" rev-parse --short HEAD)"
if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
  COMMIT="$COMMIT-dirty"
  echo "==> note: the tree is dirty, so the row records $COMMIT"
fi

echo "==> copying to $DEPLOY_ENV ($DEPLOY_HOST)"
scp -q -o BatchMode=yes ${DEPLOY_SSH_KEY:+-i "$DEPLOY_SSH_KEY"} "$BIN" "$TARGET:/tmp/engine_timing_bench"

echo "==> running $GAMES games, $EDITION"
OUTPUT="$("${SSH[@]}" "$TARGET" "chmod +x /tmp/engine_timing_bench && cd /tmp && ./engine_timing_bench $GAMES $EDITION")"
"${SSH[@]}" "$TARGET" 'rm -f /tmp/engine_timing_bench' || true

ROW="$(printf '%s\n' "$OUTPUT" | grep '^row: ' | sed 's/^row: //')"
if [ -z "$ROW" ]; then
  echo "no row in the output — the benchmark did not complete:" >&2
  printf '%s\n' "$OUTPUT" >&2
  exit 1
fi
ROW="${ROW/,unknown,/,$COMMIT,}"

HOST="$(printf '%s' "$ROW" | cut -d, -f3)"
PREVIOUS="$(grep ",$HOST," "$CSV" | tail -1 || true)"

printf '%s\n' "$ROW" >> "$CSV"
echo "==> recorded to ${CSV#"$REPO"/}"
echo

# The comparison this exists for: the same host, then and now.
fmt() { printf '  %-15s median %6s ms   p99 %7s ms   CPU p99 %7s ms   steal %5s%%\n' \
  "$(printf '%s' "$1" | cut -d, -f2)" "$(printf '%s' "$1" | cut -d, -f10)" \
  "$(printf '%s' "$1" | cut -d, -f14)" "$(printf '%s' "$1" | cut -d, -f21)" \
  "$(printf '%s' "$1" | cut -d, -f24)"; }
echo "$HOST:"
[ -n "$PREVIOUS" ] && fmt "$PREVIOUS" || echo "  (no previous run on this host)"
fmt "$ROW"
echo
echo "A check, not a gate: read the two rows and decide. Nothing here fails a release."
