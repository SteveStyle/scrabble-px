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

# --- attribution ------------------------------------------------------------
#
# The hook adds `Co-Authored-By: Claude` when CLAUDECODE is set, so that the
# absence of one means the owner typed the commit himself. Both directions
# matter: adding it when it should not be there would make his own commits
# claim Claude wrote them, which is the failure this whole convention exists to
# avoid.

trailer_check() {
  local want="$1" claudecode="$2" msg="$3" name="$4"
  local dir; dir="$(new_repo)"
  printf '%s
' "$msg" > "$dir/msg"
  if [[ -n "$claudecode" ]]; then
    ( cd "$dir" && CLAUDECODE=1 "$HOOK" "$dir/msg" ) >/dev/null 2>&1 || true
  else
    ( cd "$dir" && env -u CLAUDECODE "$HOOK" "$dir/msg" ) >/dev/null 2>&1 || true
  fi
  local got=absent
  grep -q '^Co-Authored-By: Claude' "$dir/msg" && got=present
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: wanted $want, got $got"
    failures=$((failures + 1))
  fi
  rm -rf "$dir"
}

trailer_check absent  ""    "app 0.5.2 api 2.10: x" "no trailer when the owner commits"
trailer_check present "yes" "app 0.5.2 api 2.10: x" "a trailer when Claude commits"

# A named trailer must survive: the hook cannot know the model, and the history
# distinguishes Opus 5, Sonnet 5 and Opus 4.8.
kept_dir="$(new_repo)"
printf 'app 0.5.2 api 2.10: x\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>\n' > "$kept_dir/msg"
( cd "$kept_dir" && CLAUDECODE=1 "$HOOK" "$kept_dir/msg" ) >/dev/null 2>&1 || true
if [[ "$(grep -c '^Co-Authored-By:' "$kept_dir/msg")" == "1" ]] \
   && grep -q 'Claude Opus 5' "$kept_dir/msg"; then
  echo "ok   a hand-written model-specific trailer is not duplicated or replaced"
else
  echo "FAIL a hand-written model-specific trailer should survive untouched"
  failures=$((failures + 1))
fi
rm -rf "$kept_dir"

# A refused commit must not be quietly annotated on its way out.
refused_dir="$(new_repo)"
printf 'no stamp here\n' > "$refused_dir/msg"
( cd "$refused_dir" && CLAUDECODE=1 "$HOOK" "$refused_dir/msg" ) >/dev/null 2>&1 || true
if grep -q '^Co-Authored-By:' "$refused_dir/msg"; then
  echo "FAIL a refused commit should not gain a trailer"
  failures=$((failures + 1))
else
  echo "ok   a refused commit gains no trailer"
fi
rm -rf "$refused_dir"

echo
if (( failures > 0 )); then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "All commit-msg hook tests passed."
