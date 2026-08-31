#!/usr/bin/env bash
set -euo pipefail

# Tests that scripts/actions.py reminds about a project left at Post-deployment
# for its review (#263), and — as much as it matters — that it stays quiet
# before the review is due.
#
# The quiet half is the one worth a test. A reminder that fires the day a
# release ships is one you learn to ignore, and D4 is explicit that the review
# waits *"a week … for the interesting failures to surface"*.
#
# `gh` is stubbed with two canned responses: the issue listing, and the
# timeline query that dates the phase change. The dates are generated relative
# to today, so the test does not go stale.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"

days_ago() { date -u -d "@$(( $(date -u +%s) - $1 * 86400 ))" +%Y-%m-%dT%H:%M:%SZ; }

write_responses() {  # $1 = days since the phase was set on #101
  cat > "$DIR/response.json" <<JSON
{"data":{"repository":{
  "issues":{"nodes":[
    {"number":101,"title":"A shipped project","body":"","state":"OPEN","issueType":{"name":"Project"},
     "issueFieldValues":{"nodes":[
        {"field":{"name":"Phase"},"value":"Post-deployment"},
        {"field":{"name":"Workstream"},"value":"Delivery Tooling"}]},
     "parent":null,"subIssues":{"nodes":[]}},
    {"number":102,"title":"A project still being built","body":"","state":"OPEN","issueType":{"name":"Project"},
     "issueFieldValues":{"nodes":[
        {"field":{"name":"Phase"},"value":"Development"},
        {"field":{"name":"Workstream"},"value":"Delivery Tooling"}]},
     "parent":null,"subIssues":{"nodes":[]}}
  ]},
  "pullRequests":{"nodes":[]}}}}
JSON
  cat > "$DIR/timeline.json" <<JSON
{"data":{"repository":{
  "i101":{"number":101,"timelineItems":{"nodes":[
     {"createdAt":"$(days_ago 60)","newValue":"Development","issueField":{"name":"Phase"}},
     {"createdAt":"$(days_ago "$1")","newValue":"Post-deployment","issueField":{"name":"Phase"}}]}}
}}}
JSON
}

cat > "$DIR/order.json" <<'ORDER'
{"data":{"organization":{"issueFields":{"nodes":[
  {"name":"Workstream","options":[{"name":"Delivery Tooling"}]}]}}}}
ORDER
export ORDER="$DIR/order.json"

# Dispatch has to tell the timeline query from the issue listing: both are
# `gh api graphql`, and answering either with the other is how a stub passes a
# test about something it never exercised.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  repo\ *)           echo "delphside tile-lite-elite" ;;
  *issueFields*)     cat "$ORDER" ;;
  *timelineItems*)   cat "$TIMELINE" ;;
  api\ *)            cat "$RESPONSE" ;;
  *)                 exit 1 ;;
esac
STUB
chmod +x "$BIN/gh"
cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/git"
export RESPONSE="$DIR/response.json" TIMELINE="$DIR/timeline.json"

run() { PATH="$BIN:$PATH" python3 "$HERE/actions.py" "$1" 2>&1; }
check() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"
  else echo "FAIL $1"; echo "     wanted: $2"; echo "     got:    $3"; failures=$((failures + 1)); fi
}
says() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# --- before it is due, nothing is said ---------------------------------------
write_responses 3
out="$(run --all)"
check "at 3 days, no reminder"        "no"  "$(says "$out" "post-deployment review is due")"
check "but the project is still shown" "yes" "$(says "$out" "#101")"

# --- on the boundary ---------------------------------------------------------
write_responses 7
check "at 7 days, the reminder appears" "yes" \
  "$(says "$(run --all)" "post-deployment review is due")"

# --- and it says how long, and where the template is -------------------------
write_responses 21
out="$(run --all)"
check "it says how long it has waited" "yes" "$(says "$out" "21 days at Post-deployment")"
check "and points at the template"     "yes" \
  "$(says "$out" "docs/templates/post-deployment-review.md")"

# --- whose turn: Claude writes it, per D4 ------------------------------------
write_responses 21
check "it is Claude's action"     "yes" "$(says "$(run --claude)" "post-deployment review is due")"
check "and not Steve's yet"       "no"  "$(says "$(run '')"        "post-deployment review is due")"

# --- a project that has not shipped is never reminded about ------------------
write_responses 21
check "a project at Development is not chased" "no" \
  "$(says "$(run --all)" "#102"$'\n'"       - post-deployment")"

if (( failures )); then echo; echo "$failures test(s) failed" >&2; exit 1; fi
echo
echo "All actions.py review-reminder tests passed."
