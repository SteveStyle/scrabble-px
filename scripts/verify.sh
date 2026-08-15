#!/usr/bin/env bash
set -uo pipefail

# verify.sh — one command that confirms everything is in place.
#
# `status.sh` *shows* you the world; this one *asserts* it, and exits non-zero
# if any of it is wrong. The difference matters: a display has to be read and
# interpreted, and the failure mode of reading is not noticing.
#
# It exists because CI and the deploy gates each answer at a moment you are not
# necessarily present for. CI answers after a push, and only if you go and look;
# the deploy gates answer during a deploy, which is a bad time to discover the
# tooling is broken. Owner, 2026-08-15:
#
#   > Having CI run things is good to do, but we sometimes miss what CI does.
#   > We also need a command we type which confirms everything is in place.
#
# Every check prints ok or FAIL with a reason, and nothing is skipped quietly —
# a check that cannot run says so and counts as a failure, because an absent
# answer must never read like a passing one. That rule is the whole design; it
# is also the failure this repository has hit most often.
#
# Read-only. It builds nothing, deploys nothing and changes nothing.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

failures=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; failures=$((failures + 1)); }
note() { printf '       %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- the repository ---------------------------------------------------------

head_ "Repository"

if [[ -z "$(git status --porcelain)" ]]; then
  ok "working tree clean"
else
  bad "working tree has uncommitted changes"
  git status --porcelain | head -5 | while read -r l; do note "$l"; done
fi

git fetch -q origin 2>/dev/null || true
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$BRANCH" 2>/dev/null)" ]]; then
  ok "$BRANCH matches origin"
else
  AHEAD="$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo '?')"
  bad "$BRANCH is $AHEAD commit(s) ahead of origin — push before deploying"
fi

# --- the tooling's own tests ------------------------------------------------
#
# The gates decide what reaches users, so a broken gate is worse than a broken
# feature. These are the tests CI runs; running them here answers the question
# without waiting for a push, and without having to remember to read CI.

head_ "Tooling tests"

for t in scripts/tests/*.test.sh; do
  [[ -e "$t" ]] || continue
  name="$(basename "$t" .test.sh)"
  if out="$("$t" 2>&1)"; then
    ok "$name"
  else
    bad "$name"
    printf '%s\n' "$out" | tail -4 | while read -r l; do note "$l"; done
  fi
done

# --- CI's verdict on what is pushed -----------------------------------------

head_ "CI"

if ! command -v gh > /dev/null; then
  bad "cannot ask — no 'gh' on PATH"
elif ! CI_OUT="$(./scripts/ci-status.sh --run "push:$BRANCH" "$(git rev-parse HEAD)" 2>&1)"; then
  bad "the push:$BRANCH run has not passed for HEAD"
  printf '%s\n' "$CI_OUT" | tail -3 | while read -r l; do note "$l"; done
else
  ok "push:$BRANCH run passed for $(git rev-parse --short HEAD)"
fi

# --- what each environment is running ---------------------------------------
#
# Not an assertion that they match — preview and rehearsal legitimately lag or
# lead. It is here so that "everything in place" includes knowing where the
# world actually is, which is the question the deploy gates ask later anyway.

head_ "Environments"

env_version() {
  curl -fsS --max-time 10 "$1/health" 2>/dev/null \
    | sed -n 's/.*"app_version":"\([^"]*\)".*/\1/p'
}
for pair in "production https://tileliteelite.com" \
            "rehearsal https://rehearsal.tileliteelite.com" \
            "preview http://localhost:8081"; do
  set -- $pair
  v="$(env_version "$2")"
  if [[ -n "$v" ]]; then
    ok "$(printf '%-11s %s' "$1" "$v")"
  else
    bad "$(printf '%-11s unreachable' "$1")"
  fi
done

# --- the milestone about to ship --------------------------------------------
#
# A milestone is a shipping list, and a deploy closes everything in it. An issue
# with no commit mentioning it was never built, and would be closed claiming it
# shipped. deploy.sh checks this too — asking here means finding out before the
# release rather than during it.

head_ "Milestone"

VERSION="$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)"
if ! command -v gh > /dev/null; then
  bad "cannot read milestone $VERSION — no 'gh' on PATH"
elif ! MS="$(gh issue list --milestone "$VERSION" --state open \
       --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>&1)"; then
  bad "cannot read milestone $VERSION"
  printf '%s\n' "$MS" | head -2 | while read -r l; do note "$l"; done
elif [[ -z "$MS" ]]; then
  ok "milestone $VERSION has no open issues"
else
  unbuilt=""
  while IFS=$'\t' read -r num title; do
    [[ -z "$num" ]] && continue
    if git log --oneline HEAD --grep="#${num}\b" 2>/dev/null | grep -q .; then
      note "#$num ${title:0:60}"
    else
      note "#$num ${title:0:60}   <-- no commit mentions this"
      unbuilt="$unbuilt #$num"
    fi
  done <<< "$MS"
  if [[ -n "$unbuilt" ]]; then
    bad "milestone $VERSION carries unbuilt issues:$unbuilt"
  else
    ok "milestone $VERSION — every issue has a commit"
  fi
fi

# --- would a deploy be allowed ----------------------------------------------
#
# The strongest single check available, because it is the real gates rather than
# a description of them. DEPLOY_GATES_ONLY stops before anything is built.

head_ "Deploy gates"

if out="$(DEPLOY_GATES_ONLY=1 ./scripts/deploy.sh 2>&1)"; then
  ok "a production deploy of HEAD would be allowed"
  printf '%s\n' "$out" | grep -E '^==> Gates run:' | while read -r l; do note "$l"; done
else
  bad "a production deploy of HEAD would be refused"
  printf '%s\n' "$out" | grep -E '^error:|^ *[A-Z]' | tail -4 | while read -r l; do note "$l"; done
fi

# --- verdict ----------------------------------------------------------------

printf '\n'
if (( failures > 0 )); then
  printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
  exit 1
fi
printf '\033[32mEverything in place.\033[0m\n'
