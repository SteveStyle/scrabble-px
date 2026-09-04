#!/usr/bin/env bash
set -euo pipefail

# Tests deploy.sh's `Release Check` announcement (#310), under the same
# `set -euo pipefail` the deploy runs with. This code runs *after* production is
# already serving the new version, so an abort here would turn a successful
# deploy into a failed one — which is why the cases below include GitHub being
# unreachable and returning nothing.
#
# Sources deploy.sh with DEPLOY_SH_FUNCTIONS_ONLY=1 rather than copying the
# logic. A test that re-implements what it checks proves only that two copies
# agree.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
# shellcheck source=/dev/null
DEPLOY_SH_FUNCTIONS_ONLY=1 source "$HERE/deploy.sh"

DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${GH_FAIL:-}" ] && exit 1
cat "$GH_OUT"
STUB
chmod +x "$BIN/gh"
PATH="$BIN:$PATH"
GH_OUT="$DIR/out"; export GH_OUT
printf '  #214  Build once, deploy the same artefact\n' > "$GH_OUT"

check() { local d="$1" e="$2" g="$3"
  if [ "$g" = "$e" ]; then echo "  ok       $d"
  else echo "  FAILED   $d (expected $e, got $g)"; failures=$((failures+1)); fi }

out="$(announce_release_checks 1 production)"
check "a production release names them"        "yes" "$(grep -q '#214' <<<"$out" && echo yes || echo no)"
check "and says what to do with them"          "yes" "$(grep -q 'take the label off' <<<"$out" && echo yes || echo no)"

# The three cases where it must say nothing at all.
check "a preview deploy says nothing"          ""    "$(announce_release_checks 1 preview)"
check "a rehearsal deploy says nothing"        ""    "$(announce_release_checks 1 rehearsal)"
check "a non-release deploy says nothing"      ""    "$(announce_release_checks 0 production)"

: > "$GH_OUT"
check "nothing labelled means no output"       ""    "$(announce_release_checks 1 production)"

# It runs after production is already live, so it must never be the thing that
# fails the deploy.
printf '  #214  x\n' > "$GH_OUT"
GH_FAIL=1
rc=0; announce_release_checks 1 production > /dev/null 2>&1 || rc=$?
check "GitHub being unreachable still exits 0" "0" "$rc"
unset GH_FAIL

echo
if [ "$failures" -eq 0 ]; then echo "all passed"; else echo "$failures failed"; fi
[ "$failures" -eq 0 ]
