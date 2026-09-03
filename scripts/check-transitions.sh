#!/usr/bin/env bash
set -euo pipefail
# check-transitions.sh — has an issue done the work its stage or phase claims?
#
# A field says where something has got to. Nothing says the steps behind it were
# taken, so a requirement can reach `Ready for Project` with no effort recorded
# and a project can sit at `Development` with no test approach.
#
# **It reports; it does not refuse.** A field is changed in a browser and nothing
# here can stand in front of that. What it can do is notice afterwards, which is
# the same shape as verify.sh.
#
# Owner, 2026-09-03: "whenever a requirement or project moves stage or phase
# there should be a check that the previous steps are completed."

command -v gh >/dev/null || { echo "check-transitions: no 'gh' on PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "check-transitions: no 'jq' on PATH" >&2; exit 2; }

Q='{repository(owner:"delphside",name:"tile-lite-elite"){issues(first:100,states:OPEN){nodes{number title body issueType{name} issueFieldValues(first:12){nodes{... on IssueFieldSingleSelectValue{name field{... on IssueFieldSingleSelect{name}}}}}}}}}'
ISSUES="$(gh api graphql -f query="$Q" 2>/dev/null)" || {
  echo "check-transitions: could not read the issues" >&2; exit 2; }

echo "==> Open issues, against what their stage or phase claims"

ROWS="$(printf '%s' "$ISSUES" | jq -r '
  .data.repository.issues.nodes[] | . as $i
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Stage")|.name][0] // "-") as $stage
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Phase")|.name][0] // "-") as $phase
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Workstream")|.name][0] // "-") as $ws
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Type of change")|.name][0] // "-") as $toc
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Priority")|.name][0] // "-") as $pri
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Effort")|.name][0] // "-") as $eff
  | [$i.number, ($i.issueType.name // ""), $stage, $phase, $ws, $toc, $pri, $eff,
     (($i.body // "") | gsub("[\n\r]"; " "))] | @tsv')"

FAILURES=0
report() { printf "  #%-5s %-24s %s\n" "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); }

# Every field is emitted as "-" when empty, because tab is an IFS whitespace
# character: bash collapses a run of them, so a genuinely empty field would
# merge with the next and shift the body out of reach. That failure is silent —
# the check simply stops finding anything.
while IFS=$'\t' read -r num kind stage phase ws toc pri eff body; do
  [ -n "$num" ] || continue
  for v in stage phase ws toc pri eff; do
    [ "${!v}" = "-" ] && printf -v "$v" '%s' ""
  done
  case "$kind" in
    Requirement)
      case "$stage" in
        "Scope, Options and Dependencies"|"On Hold"|"Ready for Project"|Candidate*)
          [ -n "$ws" ]  || report "$num" "$stage" "triage set no workstream"
          [ -n "$toc" ] || report "$num" "$stage" "triage set no type of change"
          [ -n "$pri" ] || report "$num" "$stage" "triage set no priority"
          ;;
      esac
      case "$stage" in
        "On Hold")
          printf '%s' "$body" | grep -qi "depend" || report "$num" "$stage" "on hold with nothing under dependencies"
          ;;
      esac
      case "$stage" in
        "Ready for Project"|Candidate*)
          [ -n "$eff" ] || report "$num" "$stage" "scoped but no effort recorded"
          ;;
      esac
      ;;
    Project|"Project Delivery")
      case "$phase" in
        "Design and Test Approach"|Development|"User testing"|Deployment|Post-deployment|"Project Closedown")
          printf '%s' "$body" | grep -q "## Requirements" || report "$num" "$phase" "no requirements heading"
          printf '%s' "$body" | grep -q "## Design"       || report "$num" "$phase" "no design heading"
          ;;
      esac
      case "$phase" in
        Development|"User testing"|Deployment|Post-deployment|"Project Closedown")
          printf '%s' "$body" | grep -q "## Test approach"       || report "$num" "$phase" "no test approach"
          printf '%s' "$body" | grep -q "Technical tests"        || report "$num" "$phase" "test approach has no Preview/Rehearsal lists"
          printf '%s' "$body" | grep -q "## Impacted artefacts"  || report "$num" "$phase" "no impacted artefacts"
          ;;
      esac
      case "$phase" in
        Deployment|Post-deployment|"Project Closedown")
          printf '%s' "$body" | grep -q "## Deliveries"        || report "$num" "$phase" "no deliveries"
          printf '%s' "$body" | grep -qi "post-deployment check" || report "$num" "$phase" "no post-deployment checks"
          ;;
      esac
      case "$phase" in
        "Project Closedown")
          printf '%s' "$body" | grep -qi "lessons learnt" || report "$num" "$phase" "closing down with no lessons learnt"
          ;;
      esac
      ;;
  esac
done <<< "$ROWS"

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "  $FAILURES issue(s) are further along than their content supports."
  exit 1
fi
echo "  every open issue has done the work its field claims"
