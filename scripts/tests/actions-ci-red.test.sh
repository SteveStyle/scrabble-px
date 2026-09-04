#!/usr/bin/env bash
set -euo pipefail

# Tests that scripts/actions.py reports a red `main`, and only a red one.
#
# On 2026-09-04 CI was red on main for fourteen commits because the tool that
# checks it was not run. This puts the answer in the tool that is read daily.
#
# The case that matters most is the quiet one: a run still in progress is the
# normal state immediately after a push, and reporting it would put a line on
# every reading until people stopped seeing any of them.
#
# `actions.py` calls `ci-status.sh` by absolute path from its own directory, so
# the fixture copies actions.py beside a stub rather than trying to shadow the
# real script on PATH.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"
cp "$HERE/actions.py" "$DIR/actions.py"

cat > "$DIR/response.json" <<'JSON'
{"data":{"repository":{"issues":{"nodes":[]},"pullRequests":{"nodes":[]}}}}
JSON
cat > "$DIR/order.json" <<'ORDER'
{"data":{"organization":{"issueFields":{"nodes":[{"name":"Workstream","options":[]}]}}}}
ORDER
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  repo\ *)       echo "delphside tile-lite-elite" ;;
  *issueFields*) cat "$ORDER" ;;
  *-i\ user*)    printf 'HTTP/2.0 200 OK\r\n\r\n{}\n' ;;
  api\ *)        cat "$RESPONSE" ;;
  *)             exit 1 ;;
esac
STUB
chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git"; chmod +x "$BIN/git"
export RESPONSE="$DIR/response.json" ORDER="$DIR/order.json"
export PATH="$BIN:$PATH"

stub_ci() {  # $1 = exit code, rest = output
  local rc="$1"; shift
  { printf '#!/usr/bin/env bash\n'; printf 'cat <<'"'"'EOF'"'"'\n%s\nEOF\n' "$*"; printf 'exit %s\n' "$rc"; } > "$DIR/ci-status.sh"
  chmod +x "$DIR/ci-status.sh"
}
run() { "$DIR/actions.py" --all 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }
check() { local d="$1" e="$2" g="$3"
  if [ "$g" = "$e" ]; then echo "  ok       $d"
  else echo "  FAILED   $d (expected $e, got $g)"; failures=$((failures+1)); fi }

stub_ci 1 "CI: the 'push on main' run for abc1234 concluded 'failure', not success."
out="$(run)"
check "a concluded failure is reported"        "yes" "$(grep -q "concluded 'failure'" <<<"$out" && echo yes || echo no)"
check "and says the later steps never ran"     "yes" "$(grep -q 'no clippy, no tests' <<<"$out" && echo yes || echo no)"

stub_ci 1 "CI: the 'push on main' run for abc1234 is still in_progress."
check "a run in progress is not reported"      "yes" "$(grep -q 'in_progress' <<<"$(run)" && echo no || echo yes)"

stub_ci 1 "CI: no 'push on main' run found for abc1234."
check "no run yet is not reported"             "yes" "$(grep -qi 'no .push on main. run' <<<"$(run)" && echo no || echo yes)"

stub_ci 0 "CI: passed."
check "a green main says nothing"              "yes" "$(grep -q 'CI:' <<<"$(run)" && echo no || echo yes)"

rm -f "$DIR/ci-status.sh"
check "a missing ci-status.sh is survivable"   "0" "$("$DIR/actions.py" --all >/dev/null 2>&1; echo $?)"

echo
if [ "$failures" -eq 0 ]; then echo "all passed"; else echo "$failures failed"; fi
[ "$failures" -eq 0 ]
