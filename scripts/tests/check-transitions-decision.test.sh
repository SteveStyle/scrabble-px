#!/usr/bin/env bash
set -euo pipefail

# check-transitions-decision.test.sh — the Decision rules in check-transitions.sh.
#
# A Decision has no Stage and no Phase. Open and closed is its whole state
# machine, which is what lets `closed` mean *applied* rather than *answered* —
# the distinction the glossary's decision index could not express, and the
# reason #298 exists. So the rules under test are the one transition it has.
#
# `gh` is stubbed, so the only input is the canned JSON. The stub answers two
# different queries: the script asks for open issues, then for closed ones, and
# it tells them apart the same way the script does — by `states:CLOSED` in the
# query text.
#
# Run under the same `set -euo pipefail` the script runs under: a harness
# missing pipefail once hid a silent abort that reached a production deploy.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"

# Bodies are written as files and base64'd into the JSON, because the thing
# being tested is heading-and-newline structure. Building them inline as escaped
# strings is how a fixture comes to test something other than what it looks like.
mkbody() { printf '%s' "$1" | base64 -w0; }

SETTLED="$(mkbody '### Context & Proposal

meat or fish

### Agreed Decision

meat

### Open actions

- [x] (Steve) choose
- [x] (Claude) record it
')"

IN_PROGRESS="$(mkbody '### Context & Proposal

meat or fish

### Agreed Decision

meat

### Open actions

- [x] (Steve) choose
- [ ] (Claude) record it
')"

UNDECIDED="$(mkbody '### Context & Proposal

meat or fish

### Agreed Decision

_No response_

### Open actions

- [ ] (Steve) choose
')"

OLD_HEADING="$(mkbody '### Context & Proposal

meat or fish

### Agreed Decision

meat

### Action Items

- [ ] Action item 1
- [ ] Action item 2
')"

run() {
  local desc="$1" want_exit="$2" want_text="$3" open_nodes="$4" closed_nodes="$5"
  cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *states:CLOSED*)
      cat <<'JSON'
{"data":{"repository":{"issues":{"nodes":[$closed_nodes]}}}}
JSON
      exit 0 ;;
  esac
done
cat <<'JSON'
{"data":{"repository":{"issues":{"nodes":[$open_nodes]}}}}
JSON
EOF
  chmod +x "$BIN/gh"
  local out got=0
  out="$(PATH="$BIN:$PATH" "$HERE/check-transitions.sh" 2>&1)" || got=$?
  if [ "$got" -ne "$want_exit" ]; then
    echo "  FAILED   $desc (expected exit $want_exit, got $got)"; failures=$((failures+1)); return
  fi
  if [ -n "$want_text" ] && ! grep -qF "$want_text" <<< "$out"; then
    echo "  FAILED   $desc (exit $got, but no line matched '$want_text')"
    printf '%s\n' "$out" | sed 's/^/           /'
    failures=$((failures+1)); return
  fi
  if [ -z "$want_text" ] && grep -q '^  #' <<< "$out"; then
    echo "  FAILED   $desc (expected nothing reported)"
    printf '%s\n' "$out" | sed 's/^/           /'
    failures=$((failures+1)); return
  fi
  echo "  ok       $desc"
}

dec() { printf '{"number":%s,"title":"d","body":"","issueType":{"name":"Decision"},"issueFieldValues":{"nodes":[]}}' "$1"; }
# The open query selects body via jq from the node, so the body has to be real
# text there; the closed query base64s it in the script. Both take plain text.
open_dec() {  # $1 = number, $2 = base64 body
  printf '{"number":%s,"title":"d","body":%s,"issueType":{"name":"Decision"},"issueFieldValues":{"nodes":[]}}' \
    "$1" "$(printf '%s' "$2" | base64 -d | jq -Rs .)"
}
closed_dec() { open_dec "$1" "$2"; }

echo "open decisions:"
run "settled and every action done is reported"        1 "close it"                    "$(open_dec 900 "$SETTLED")"     ""
run "an action still open is left alone"               0 ""                            "$(open_dec 901 "$IN_PROGRESS")" ""
run "no agreed decision yet is left alone"             0 ""                            "$(open_dec 902 "$UNDECIDED")"   ""
run "an unreadable actions heading is reported as that" 1 "invisible to actions.py"    "$(open_dec 903 "$OLD_HEADING")" ""

echo "closed decisions:"
run "closed and complete is left alone"                0 ""                            "" "$(closed_dec 910 "$SETTLED")"
run "closed with no agreed decision is reported"       1 "no agreed decision"          "" "$(closed_dec 911 "$UNDECIDED")"
run "closed with an action still open is reported"     1 "1 action(s) still open"      "" "$(closed_dec 912 "$IN_PROGRESS")"
run "closed with an unreadable heading is reported"    1 "no 'Open actions' heading"   "" "$(closed_dec 913 "$OLD_HEADING")"

echo "other types:"
run "a requirement is not judged as a decision"        0 "" \
  '{"number":920,"title":"r","body":"","issueType":{"name":"Requirement"},"issueFieldValues":{"nodes":[]}}' ""

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all decision transition tests passed."
