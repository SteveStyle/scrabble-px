#!/usr/bin/env bash
set -euo pipefail

# Tests .githooks/commit-msg, under the same `set -euo pipefail` its caller
# runs with — git invokes hooks directly, so a hook that aborts on an unset
# variable fails the commit with no explanation at all.
#
# The hook is a convenience rather than a gate: it lives in a working copy and
# `--no-verify` skips it, which is why check-commit-stamp.sh still runs in CI.
# What it must not do is refuse a *correct* commit, because a hook that cries
# wolf gets disabled and then protects nothing. So the accept cases matter as
# much as the refusals here.

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$HERE/.githooks/commit-msg"
failures=0

# A scratch repo carrying the two files the hook reads versions from.
new_repo() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q .
  mkdir -p "$dir/crates/api/src" "$dir/scripts"
  printf '[workspace.package]\nversion = "0.5.2"\n' > "$dir/Cargo.toml"
  printf 'pub const API_VERSION: ApiVersion = ApiVersion { major: 2, minor: 10 };\n' \
    > "$dir/crates/api/src/lib.rs"
  cp "$HERE/scripts/read-api-version.sh" "$dir/scripts/"
  printf '%s' "$dir"
}

check() {
  local want="$1" subject="$2" name="$3"
  local dir; dir="$(new_repo)"
  printf '%s\n' "$subject" > "$dir/msg"
  local got=accept
  ( cd "$dir" && "$HOOK" "$dir/msg" ) >/dev/null 2>&1 || got=refuse
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: wanted $want, got $got"
    failures=$((failures + 1))
  fi
  rm -rf "$dir"
}

# --- what it must refuse ----------------------------------------------------

# The mistake that prompted the hook: a stamp with the colon missing. CI caught
# it six minutes later, by which time the commit was no longer the tip and
# fixing it needed a rebase rather than an amend.
check refuse "app 0.5.2 api 2.10 no colon here"      "the missing colon"
check refuse "app 0.5.2 api 2.10:"                   "a stamp with no subject after it"
check refuse "docs: a bare scope prefix"             "no stamp at all"
check refuse "app 0.5.1 api 2.10: wrong app"         "an app version the tree disagrees with"
check refuse "app 0.5.2 api 2.9: wrong api"          "an api version the tree disagrees with"

# --- and what it must accept ------------------------------------------------

check accept "app 0.5.2 api 2.10: a real subject"    "a correct stamp"
check accept "Merge branch 'x' into y"               "a merge, whose subject git generates"
check accept "Revert \"app 0.5.2 api 2.10: x\""      "a revert, likewise"
check accept "fixup! app 0.5.2 api 2.10: x"          "a fixup, resolved at rebase time"
check accept "squash! app 0.5.2 api 2.10: x"         "a squash, likewise"

echo
if (( failures > 0 )); then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "All commit-msg hook tests passed."
