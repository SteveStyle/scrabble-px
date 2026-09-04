#!/usr/bin/env bash
set -euo pipefail

# Tests that scripts/actions.py treats a `Release Check` project as waiting for
# a release rather than as a review that is due (#310).
#
# Both halves matter and the second is the one that catches a blunt fix: a
# labelled project must stop nagging, and an *unlabelled* one at the same age
# must still nag. Suppressing both would pass a test written only for the first.
#
# `gh` is stubbed with the issue listing and the timeline query that dates the
# phase change, as in actions-review-due.test.sh. Dates are relative to today so
# the test does not go stale.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"

days_ago() { date -u -d "@$(( $(date -u +%s) - $1 * 86400 ))" +%Y-%m-%dT%H:%M:%SZ; }

# #101 carries the label, #102 does not. Everything else about them is equal.
cat > "$DIR/response.json" <<JSON
{"data":{"repository":{
  "issues":{"nodes":[
    {"number":101,"title":"Waiting for a release","body":"","state":"OPEN","issueType":{"name":"Project"},
     "labels":{"nodes":[{"name":"Release Check"}]},
     "issueFieldValues":{"nodes":[
        {"field":{"name":"Phase"},"value":"Post-deployment"},
        {"field":{"name":"Workstream"},"value":"Delivery Tooling"}]},
     "parent":null,"subIssues":{"nodes":[]}},
    {"number":102,"title":"Owes its review now","body":"","state":"OPEN","issueType":{"name":"Project"},
     "labels":{"nodes":[]},
     "issueFieldValues":{"nodes":[
        {"field":{"name":"Phase"},"value":"Post-deployment"},
        {"field":{"name":"Workstream"},"value":"Delivery Tooling"}]},
     "parent":null,"subIssues":{"nodes":[]}}
  ]},
  "pullRequests":{"nodes":[]}}}}
JSON
cat > "$DIR/timeline.json" <<JSON
{"data":{"repository":{
  "i101":{"number":101,"timelineItems":{"nodes":[
     {"createdAt":"$(days_ago 30)","newValue":"Post-deployment","issueField":{"name":"Phase"}}]}},
  "i102":{"number":102,"timelineItems":{"nodes":[
     {"createdAt":"$(days_ago 30)","newValue":"Post-deployment","issueField":{"name":"Phase"}}]}}
}}}
JSON
cat > "$DIR/order.json" <<'ORDER'
{"data":{"organization":{"issueFields":{"nodes":[
  {"name":"Workstream","options":[{"name":"Delivery Tooling"}]}]}}}}
ORDER

cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  repo\ *)          echo "delphside tile-lite-elite" ;;
  *issueFields*)    cat "$ORDER" ;;
  *timelineItems*)  cat "$TIMELINE" ;;
  *-i\ user*)       printf 'HTTP/2.0 200 OK\r\n\r\n{}\n' ;;
  api\ *)           cat "$RESPONSE" ;;
  *)                exit 1 ;;
esac
STUB
chmod +x "$BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/git"; chmod +x "$BIN/git"
export RESPONSE="$DIR/response.json" TIMELINE="$DIR/timeline.json" ORDER="$DIR/order.json"
export PATH="$BIN:$PATH"

OUT="$("$HERE/actions.py" --all 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
check() { local d="$1" e="$2" g="$3"
  if [ "$g" = "$e" ]; then echo "  ok       $d"
  else echo "  FAILED   $d (expected $e, got $g)"; failures=$((failures+1)); fi }

# The labelled one: shown, and shown as waiting rather than due.
check "the labelled project is still shown"      "yes" "$(grep -q '#101' <<<"$OUT" && echo yes || echo no)"
check "it says it waits for the next release"    "yes" "$(grep -q 'waits for the next release' <<<"$OUT" && echo yes || echo no)"
check "and is not called a review that is due"   "yes" \
  "$(awk '/#101/{f=1;next} /#102/{f=0} f' <<<"$OUT" | grep -q 'review is due' && echo no || echo yes)"

# The unlabelled one at the same age: the suppression must not have been blunt.
check "an unlabelled project still nags"         "yes" \
  "$(awk '/#102/{f=1} f' <<<"$OUT" | grep -q 'post-deployment review is due' && echo yes || echo no)"

# It is nobody's action, so it must not reach a per-person view.
MINE="$("$HERE/actions.py" --claude 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
check "waiting is not Claude's action"           "yes" \
  "$(grep -q 'waits for the next release' <<<"$MINE" && echo no || echo yes)"

echo
if [ "$failures" -eq 0 ]; then echo "all passed"; else echo "$failures failed"; fi
[ "$failures" -eq 0 ]
