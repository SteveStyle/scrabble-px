#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/ci-status.sh, under the same `set -euo pipefail` its callers
# run with.
#
# This is the gate `deploy.sh` trusts to say CI passed, so if it ever answered
# "passed" for a run that had not, a broken commit reaches production and every
# other check in the release is irrelevant.
#
# It is also the gate whose *refusal* has never run in anger: you do not
# rehearse a deploy against a commit whose CI failed, so every real invocation
# has taken the happy path. The branch that says **no** is exercised here and
# nowhere else.
#
# `gh` is replaced with a stub printing the TSV that `gh run list --jq` would.
# That is the whole of the script's input, so the stub is the whole of the
# fixture.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$HERE/ci-status.sh"
failures=0

# A scratch repo with one commit, and a `gh` on PATH printing `$1`.
run_with_gh() {
  local runs="$1"
  local dir bin
  dir="$(mktemp -d)"
  bin="$dir/bin"
  mkdir -p "$bin"
  {
    echo '#!/usr/bin/env bash'
    printf 'printf %s "%s"\n' "'%s'" "$runs"
  } > "$bin/gh"
  chmod +x "$bin/gh"

  git -C "$dir" init -q .
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name Test
  git -C "$dir" commit -q --allow-empty -m "a commit"

  ( cd "$dir" && PATH="$bin:$PATH" "$CHECK" 2>&1 )
  local status=$?
  rm -rf "$dir"
  return $status
}

# Same, with no `gh` reachable at all. PATH names every tool the script needs
# rather than trimming to /usr/bin — where `gh` lives on a CI runner, which is
# how this suite's sibling once passed locally and failed there.
run_without_gh() {
  local dir bin
  dir="$(mktemp -d)"
  bin="$dir/bin"
  mkdir -p "$bin"
  for tool in env bash git printf sleep; do
    src="$(command -v "$tool" || true)"
    [[ -n "$src" ]] && ln -s "$src" "$bin/$tool"
  done
  git -C "$dir" init -q .
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name Test
  git -C "$dir" commit -q --allow-empty -m "a commit"
  ( cd "$dir" && PATH="$bin" "$CHECK" 2>&1 )
  local status=$?
  rm -rf "$dir"
  return $status
}

check_exit() {
  local name="$1" want="$2"
  shift 2
  local got=0
  "$@" > /dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: wanted exit $want, got $got"
    failures=$((failures + 1))
  fi
}

check_says() {
  local name="$1" want="$2"
  shift 2
  local out
  out="$("$@" 2>&1 || true)"
  if [[ "$out" == *"$want"* ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: output did not mention '$want'"
    echo "     got: $out"
    failures=$((failures + 1))
  fi
}

TAB="$(printf '\t')"

# --- the one path every real run has taken ---------------------------------

check_exit "a successful run passes" 0 \
  run_with_gh "completed${TAB}success${TAB}https://example/1"
check_says "and says so" "passed" \
  run_with_gh "completed${TAB}success${TAB}https://example/1"

# --- the paths nothing has ever exercised ----------------------------------

check_exit "a failed run is refused" 1 \
  run_with_gh "completed${TAB}failure${TAB}https://example/2"
check_says "and names the conclusion" "failure" \
  run_with_gh "completed${TAB}failure${TAB}https://example/2"

check_exit "a cancelled run is refused" 1 \
  run_with_gh "completed${TAB}cancelled${TAB}https://example/3"
# A cancelled run usually means a newer push superseded it, so the advice
# differs — re-run this commit's CI rather than go looking for a bug.
check_says "and a cancelled one advises a re-run" "rerun" \
  run_with_gh "completed${TAB}cancelled${TAB}https://example/3"

check_exit "a run still going is refused without --wait" 1 \
  run_with_gh "in_progress${TAB}${TAB}https://example/4"
check_says "and says it is still going" "still in_progress" \
  run_with_gh "in_progress${TAB}${TAB}https://example/4"

check_exit "no run at all is refused" 1 run_with_gh ""
check_says "and says none was found" "no run found" run_with_gh ""

# gh failing is indistinguishable from no runs, and both must refuse — this is
# the fail-closed direction, and the one that matters.
check_exit "gh returning nothing is refused, not treated as success" 1 run_with_gh ""

check_exit "gh missing is refused" 1 run_without_gh
check_says "and says gh is missing" "not installed" run_without_gh

# --- the case that looks like a failure and is not --------------------------

# A first run failed and a re-run succeeded. The script scans every run for a
# success rather than reading only the newest, so the commit passes. Pinning it
# because the obvious implementation — take the first line — would refuse a
# commit whose CI is green, and the fix for that is exactly what could be
# broken into "any line saying success anywhere is good enough".
check_exit "a re-run that succeeded passes despite an earlier failure" 0 \
  run_with_gh "completed${TAB}failure${TAB}https://example/5
completed${TAB}success${TAB}https://example/6"

echo
if (( failures > 0 )); then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "All ci-status tests passed."
