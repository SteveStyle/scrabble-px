#!/usr/bin/env bash
set -euo pipefail

# Tests that scripts/actions.py reads a project's phase from the `Phase` issue
# field rather than from a `phase:` label. The labels were deleted on
# 2026-08-27, so the old path cannot be exercised any more — and its replacement
# was, until this file, only ever run against the live repository, where a
# regression would look like "everything says not started" rather than an error.
#
# `gh` is stubbed with a canned GraphQL response, so the only input is the JSON.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"

# One workstream with two projects: one carrying a Phase, one without. Anything
# else actions.py asks `gh` for gets an empty answer, which is what a repository
# with no pull requests looks like.
cat > "$DIR/response.json" <<'JSON'
{"data":{"repository":{
  "issues":{"nodes":[
    {"number":100,"title":"A workstream","body":"","issueType":{"name":"Workstream"},
     "issueFieldValues":{"nodes":[]},"parent":null,
     "subIssues":{"nodes":[{"number":101,"title":"A project mid-flight","state":"OPEN","issueType":{"name":"Project"}},
                           {"number":102,"title":"A project nobody started","state":"OPEN","issueType":{"name":"Project"}},
                           {"number":103,"title":"A requirement awaiting a project","state":"OPEN","issueType":{"name":"Requirement"}},
                           {"number":104,"title":"A project already delivered","state":"CLOSED","issueType":{"name":"Project"}}]}},
    {"number":101,"title":"A project mid-flight","body":"","issueType":{"name":"Project"},
     "issueFieldValues":{"nodes":[
        {"field":{"name":"Phase"},"value":"User testing"},
        {"field":{"name":"Type of change"},"value":"minor-function"}]},
     "parent":{"number":100},"subIssues":{"nodes":[]}},
    {"number":102,"title":"A project nobody started","body":"","issueType":{"name":"Project"},
     "issueFieldValues":{"nodes":[{"field":{"name":"Type of change"},"value":"bug"}]},
     "parent":{"number":100},"subIssues":{"nodes":[]}},
    {"number":103,"title":"A requirement awaiting a project","body":"","issueType":{"name":"Requirement"},
     "issueFieldValues":{"nodes":[]},"parent":{"number":100},"subIssues":{"nodes":[]}}
  ]},
  "pullRequests":{"nodes":[]}}}}
JSON

# Dispatch on the subcommand, not just on `gh`: actions.py asks who the
# repository is before it asks anything about issues, and a stub that answers
# both with the same thing fails with "could not identify the repository".
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  repo) echo "delphside tile-lite-elite" ;;
  api)  cat "$RESPONSE" ;;
  *)    exit 1 ;;
esac
STUB
chmod +x "$BIN/gh"
export RESPONSE="$DIR/response.json"

# `git branch` is the other thing actions.py runs; an empty answer means no
# issue has a branch, so "in progress" can only come from a phase.
cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/git"

out="$(PATH="$BIN:$PATH" python3 "$HERE/actions.py" --all 2>&1)"

check() {  # name, expected substring
  if [[ "$out" == *"$2"* ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    echo "     wanted to find: $2"
    echo "     in: ${out:0:600}"
    failures=$((failures + 1))
  fi
}

check "a project's phase is read from the Phase field" "user testing"
# A workstream's direct children were labelled `project` unconditionally, from
# when they all were. Triage parents requirements to workstreams, so the label
# has to come from the issue type.
check "a requirement under a workstream is not called a project" "requirement #103"
# `issues` holds open issues only, so a closed child's type must come from the
# sub-issue node or a delivered project reads as a plain `issue`.
check "a closed child keeps its type"                            "project #104"
check "an unset phase falls back to a derived state" "not started"

if [[ "$out" == *"phase:"* ]]; then
  echo "FAIL a phase: label leaked into the output"
  failures=$((failures + 1))
else
  echo "ok   no phase: label appears anywhere"
fi

if (( failures )); then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo
echo "All actions.py phase tests passed."
