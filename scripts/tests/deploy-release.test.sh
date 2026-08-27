#!/usr/bin/env bash
set -euo pipefail

# Tests deploy.sh's GitHub Release step under the same `set -euo pipefail` the
# deploy itself runs with. A harness that relaxes it once let a silent-abort bug
# into a production deploy (docs/3.3, "Rolling back"), and this code runs *after*
# production is already serving the new version — so an abort here would turn a
# successful deploy into a failed one.
#
# It sources deploy.sh with DEPLOY_SH_FUNCTIONS_ONLY=1 rather than copying the
# pipeline into the test. A test that re-implements what it checks proves only
# that two copies agree.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

# shellcheck source=/dev/null
DEPLOY_SH_FUNCTIONS_ONLY=1 source "$HERE/deploy.sh"

# A scratch repo whose tags are the whole input, plus a `gh` that records the
# command line it was given instead of reaching GitHub.
setup() {
  DIR="$(mktemp -d)"
  REPO_DIR="$DIR"          # read by previous_release_tag
  BIN="$DIR/bin"; mkdir -p "$BIN"
  git -C "$DIR" init -q .
  git -C "$DIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
  cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$GH_CALLS"
exit "${GH_EXIT:-0}"
STUB
  chmod +x "$BIN/gh"
  GH_CALLS="$DIR/calls"; : > "$GH_CALLS"
  export GH_CALLS
  PATH="$BIN:$PATH"
}
teardown() { rm -rf "$DIR"; }

check() {  # name, expected, actual
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    echo "     wanted: $2"
    echo "     got:    $3"
    failures=$((failures + 1))
  fi
}

# --- previous_release_tag -----------------------------------------------------
# The cases that matter are the ones where it must not abort: an unguarded
# pipeline that matches nothing exits non-zero under pipefail.

setup
check "no tags at all yields nothing" "" "$(previous_release_tag prod-0.7.1)"

git -C "$DIR" tag prod-0.7.1
check "only its own tag yields nothing" "" "$(previous_release_tag prod-0.7.1)"

git -C "$DIR" tag prod-0.6.12; git -C "$DIR" tag prod-0.7.0
check "picks the newest predecessor" "0.7.0" "$(previous_release_tag prod-0.7.1)"

git -C "$DIR" tag prod-0.10.0
check "sorts numerically, not lexically" "0.10.0" "$(previous_release_tag prod-0.7.1)"

git -C "$DIR" tag prod-0.10.0-20260101T000000Z
check "ignores a redeploy tag's timestamp suffix" "0.10.0" "$(previous_release_tag prod-0.7.1)"

git -C "$DIR" tag prod-preview; git -C "$DIR" tag prod-0.7
check "ignores tags that are not versions" "0.10.0" "$(previous_release_tag prod-0.7.1)"
teardown

# --- publish_release ----------------------------------------------------------

setup
publish_release prod-0.7.1 0.7.1 > /dev/null
check "first release ever passes no start tag" \
  "release create prod-0.7.1 --generate-notes --verify-tag --title 0.7.1" \
  "$(cat "$GH_CALLS")"
teardown

setup
git -C "$DIR" tag prod-0.7.0
publish_release prod-0.7.1 0.7.1 > /dev/null
check "a predecessor becomes --notes-start-tag" \
  "release create prod-0.7.1 --generate-notes --verify-tag --title 0.7.1 --notes-start-tag prod-0.7.0" \
  "$(cat "$GH_CALLS")"
teardown

# A redeploy tag would claim a changelog that already exists.
setup
git -C "$DIR" tag prod-0.7.0
out="$(publish_release prod-0.7.1-20260101T000000Z 0.7.1)"
check "a redeploy publishes nothing" "" "$(cat "$GH_CALLS")"
check "and says why" "yes" "$(case "$out" in *redeploy*) echo yes ;; *) echo "$out" ;; esac)"
teardown

# The whole point: production is already serving by the time this runs.
setup
# `export`, not a variable prefix: the stub is a separate process, and a prefix
# on an assignment is not exported at all — which made an earlier version of
# this test pass while `gh` was still exiting 0.
export GH_EXIT=1
status=0
publish_release prod-0.7.1 0.7.1 > /dev/null 2>&1 || status=$?
check "a failed release does not fail the deploy" "0" "$status"

err="$(publish_release prod-0.7.1 0.7.1 2>&1 >/dev/null)"
check "and prints the command to run by hand" "yes" \
  "$(case "$err" in *"gh release create prod-0.7.1"*) echo yes ;; *) echo "$err" ;; esac)"
unset GH_EXIT
teardown

if (( failures )); then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo
echo "All deploy release tests passed."
