#!/usr/bin/env bash
set -euo pipefail

# Tests deploy.sh's post-deploy behaviour: once production is swapped, a failing
# step is reported and the run continues (D41, #321).
#
# 0.7.2 is the case this exists for. The version bump's commit was refused by
# the pre-commit image rule and, being unguarded under `set -e`, ended the
# script — so the milestone was never settled and `announce_release_checks`
# never ran, after every success line had already printed. The milestone was
# repaired by hand; the announcement could not be, because it reports a moment
# rather than a state, and #310's R2 is still outstanding as a result.
#
# The property under test is therefore **a later step still runs after an
# earlier one fails**, which is the whole of it. Run under the same
# `set -euo pipefail` deploy.sh runs with.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

check() {
  local what="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$what" "$want" "$got"
    failures=$((failures + 1))
  fi
}

# shellcheck source=/dev/null
DEPLOY_SH_FUNCTIONS_ONLY=1 source "$HERE/deploy.sh"
DEPLOYED_VERSION="0.7.2"

echo "deploy-post-deploy"

# 1 — a step that succeeds is not recorded, and its status is passed through
POST_DEPLOY_FAILED=()
rc=0; post_deploy "a working step" true || rc=$?
check "a successful step returns 0"       "0" "$rc"
check "and records nothing"               "0" "${#POST_DEPLOY_FAILED[@]}"

# 2 — a step that fails is recorded by name and returns non-zero
POST_DEPLOY_FAILED=()
rc=0; post_deploy "the version bump commit" false 2>/dev/null || rc=$?
check "a failing step returns non-zero"   "1" "$rc"
check "and is recorded by name"           "the version bump commit" "${POST_DEPLOY_FAILED[0]:-}"

# 3 — the property that matters: a later step runs after an earlier one failed.
#     This is 0.7.2 exactly — the bump fails, and the milestone must still settle.
POST_DEPLOY_FAILED=()
RAN=""
settled()  { RAN="$RAN settled"; }
announced() { RAN="$RAN announced"; }
post_deploy "the version bump commit" false 2>/dev/null || true
post_deploy "settling the milestone" settled || true
post_deploy "the release-check announcement" announced || true
check "the milestone still settles after the bump fails" "1" "$(grep -c settled <<< "$RAN")"
check "and the announcement still runs"                  "1" "$(grep -c announced <<< "$RAN")"
check "only the failure is recorded"                     "1" "${#POST_DEPLOY_FAILED[@]}"

# 4 — several failures are all kept, in order
POST_DEPLOY_FAILED=()
post_deploy "first"  false 2>/dev/null || true
post_deploy "second" false 2>/dev/null || true
check "both failures are kept"    "2"      "${#POST_DEPLOY_FAILED[@]}"
check "in the order they happened" "first second" "${POST_DEPLOY_FAILED[*]}"

# 5 — the warning names the step and says production is live, so the line is
#     readable without the surrounding output
POST_DEPLOY_FAILED=()
out="$(post_deploy "settling the milestone" false 2>&1 || true)"
check "the warning names the step"        "1" "$(grep -c 'settling the milestone' <<< "$out")"
check "and says production is live"       "1" "$(grep -c 'production is live' <<< "$out")"

# 6 — arguments reach the command intact, since every real call passes some
POST_DEPLOY_FAILED=()
SEEN=""
record() { SEEN="$*"; }
post_deploy "with arguments" record 1 "two words" 3 || true
check "arguments are passed through" "1 two words 3" "$SEEN"

echo
if (( failures > 0 )); then
  echo "  $failures check(s) failed"
  exit 1
fi
echo "  all checks passed"
