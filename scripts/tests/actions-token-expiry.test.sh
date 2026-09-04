#!/usr/bin/env bash
set -euo pipefail

# Tests the token-expiry countdown in scripts/actions.py (#309).
#
# A countdown rather than a warning under a threshold, so the case that matters
# most is the quiet one: at 200 days it must still say something, because a
# figure that only appears when it is nearly too late is a figure nobody has
# learned to read. The loud cases are tested too, and so is a token with no
# expiry at all, which must produce no line rather than a crash.
#
# `gh` is stubbed. The expiry header is generated relative to today so the test
# does not go stale.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"

cat > "$DIR/response.json" <<'JSON'
{"data":{"repository":{"issues":{"nodes":[]},"pullRequests":{"nodes":[]}}}}
JSON
cat > "$DIR/order.json" <<'ORDER'
{"data":{"organization":{"issueFields":{"nodes":[{"name":"Workstream","options":[]}]}}}}
ORDER

# `api -i user` must be answered with headers and every other `api` call with
# the issue listing. Answering either with the other is how a stub passes a test
# about something it never exercised.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  repo\ *)        echo "delphside tile-lite-elite" ;;
  *issueFields*)  cat "$ORDER" ;;
  *-i\ user*)     printf 'HTTP/2.0 200 OK\r\n'; [ -n "${EXPIRY:-}" ] && printf '%s\r\n' "$EXPIRY"; printf '\r\n{}\n' ;;
  api\ *)         cat "$RESPONSE" ;;
  *)              exit 1 ;;
esac
STUB
chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git"; chmod +x "$BIN/git"
export RESPONSE="$DIR/response.json" ORDER="$DIR/order.json"
export PATH="$BIN:$PATH"

in_days() { date -u -d "@$(( $(date -u +%s) + $1 * 86400 ))" "+Github-Authentication-Token-Expiration: %Y-%m-%d %H:%M:%S UTC"; }

check() { # <description> <expected-substring or -> <days or "none">
  local desc="$1" want="$2" days="$3"
  if [ "$days" = "none" ]; then unset EXPIRY; else EXPIRY="$(in_days "$days")"; export EXPIRY; fi
  local out; out="$("$HERE/actions.py" --all 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
  local got=no
  if [ "$want" = "-" ]; then
    grep -q "token expires" <<<"$out" || got=yes
  else
    grep -qF "$want" <<<"$out" && got=yes
  fi
  if [ "$got" = yes ]; then echo "  ok       $desc"
  else echo "  FAILED   $desc"; echo "$out" | tail -3 | sed 's/^/             /'; failures=$((failures+1)); fi
}

check "a distant expiry still shows a countdown" "token expires in 200 days" 200
check "31 days is still the quiet form"          "token expires in 31 days"  31
check "30 days or fewer says it plainly"         "token expires in 30 days"  30
check "7 days or fewer says regenerate it now"   "regenerate it now (#309)"  7
check "and names the issue when urgent"          "#309"                      3
check "a token with no expiry prints no line"    "-"                         none

echo
if [ "$failures" -eq 0 ]; then echo "all passed"; else echo "$failures failed"; fi
[ "$failures" -eq 0 ]
