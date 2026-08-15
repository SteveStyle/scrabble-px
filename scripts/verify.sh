#!/usr/bin/env bash
set -uo pipefail

# verify.sh — one command that confirms everything is in place.
#
# `status.sh` *shows* you the world; this one *asserts* it, and exits non-zero
# if any of it is wrong. The difference matters: a display has to be read and
# interpreted, and the failure mode of reading is not noticing.
#
# It exists because CI and the deploy gates each answer at a moment you are not
# necessarily present for. CI answers after a push and only if you go and look;
# the deploy gates answer during a deploy, which is a bad time to discover the
# tooling is broken. Owner, 2026-08-15:
#
#   > Having CI run things is good to do, but we sometimes miss what CI does.
#   > We also need a command we type which confirms everything is in place.
#
# Read-only. It builds nothing, deploys nothing and changes nothing.
#
# ## Two orders, on purpose
#
# Checks **run** fastest-first, so a failure shows up in seconds rather than
# after the slow ones. Measured 2026-08-15: `deploy.test.sh` is 47s and the
# deploy gates 16s; everything else together is under two seconds.
#
# They are **summarised** in the order a release actually follows, which is the
# order that answers "how far would this get?".
#
# ## Why it does not stop at the first failure
#
# These are independent assertions about current state, not stages of a
# pipeline: a failing CI query says nothing about whether preview is reachable.
# Stopping would hide failures that are equally true, and mean fixing one,
# waiting, and finding the next. Running everything costs the tail of the slow
# checks and answers the whole question in one pass.
#
# ## Nothing is skipped quietly
#
# A check that cannot run says so and counts as a failure, because an absent
# answer must never read like a passing one. That is the failure this repository
# has hit most often, and the verdict line carries it too — a `--quick` run says
# what it did not do.

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

declare -A RESULT DETAIL LABEL
failures=0

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
amber() { printf '\033[33m%s\033[0m' "$1"; }

# Records a verdict and prints it as it lands.
pass() { RESULT[$1]=ok;      DETAIL[$1]="${3:-}"; printf '  %s   %s\n' "$(green ok)" "$2"; }
fail() { RESULT[$1]=FAIL;    DETAIL[$1]="${3:-}"; failures=$((failures + 1)); printf '  %s %s\n' "$(red FAIL)" "$2"; }
skip() { RESULT[$1]=skipped; DETAIL[$1]="${3:-}"; printf '  %s %s\n' "$(amber '--')" "$2"; }

# ---------------------------------------------------------------------------
# The checks. Each sets its own verdict; none depends on another having run.
# ---------------------------------------------------------------------------

LABEL[tree]="Working tree clean"
check_tree() {
  if [[ -z "$(git status --porcelain)" ]]; then
    pass tree "working tree clean"
  else
    fail tree "working tree has uncommitted changes" "$(git status --porcelain | head -5)"
  fi
}

LABEL[pushed]="Branch pushed"
check_pushed() {
  git fetch -q origin 2>/dev/null || true
  local branch; branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$branch" 2>/dev/null)" ]]; then
    pass pushed "$branch matches origin"
  else
    local ahead; ahead="$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo '?')"
    fail pushed "$branch is $ahead commit(s) ahead of origin"
  fi
}

LABEL[ci]="CI passed for HEAD"
check_ci() {
  if ! command -v gh > /dev/null; then
    fail ci "CI not asked — no 'gh' on PATH"; return
  fi
  local out
  # Deliberately without --wait. A verification that blocks for twenty minutes
  # is not one anybody types.
  if out="$(./scripts/ci-status.sh --run "push:$(git rev-parse --abbrev-ref HEAD)" \
        "$(git rev-parse HEAD)" 2>&1)"; then
    pass ci "push run passed for $(git rev-parse --short HEAD)"
  else
    fail ci "push run has not passed for HEAD" "$(printf '%s' "$out" | tail -3)"
  fi
}

LABEL[envs]="Environments reachable"
check_envs() {
  local lines="" bad=0 v
  for pair in "production https://tileliteelite.com" \
              "rehearsal https://rehearsal.tileliteelite.com" \
              "preview http://localhost:8081"; do
    set -- $pair
    v="$(curl -fsS --max-time 10 "$2/health" 2>/dev/null \
         | sed -n 's/.*"app_version":"\([^"]*\)".*/\1/p')"
    if [[ -n "$v" ]]; then
      lines+="$(printf '%-11s %s' "$1" "$v")"$'\n'
    else
      lines+="$(printf '%-11s unreachable' "$1")"$'\n'; bad=1
    fi
  done
  if (( bad )); then fail envs "an environment is unreachable" "$lines"
  else pass envs "production, rehearsal and preview all answering" "$lines"; fi
}

LABEL[milestone]="Milestone carries only built work"
check_milestone() {
  local version ms unbuilt="" lines=""
  version="$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)"
  if ! command -v gh > /dev/null; then
    fail milestone "milestone $version not read — no 'gh' on PATH"; return
  fi
  if ! ms="$(gh issue list --milestone "$version" --state open \
        --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>&1)"; then
    fail milestone "milestone $version could not be read" "$ms"; return
  fi
  if [[ -z "$ms" ]]; then
    pass milestone "milestone $version has no open issues"; return
  fi
  while IFS=$'\t' read -r num title; do
    [[ -z "$num" ]] && continue
    if git log --oneline HEAD --grep="#${num}\b" 2>/dev/null | grep -q .; then
      lines+="#$num ${title:0:58}"$'\n'
    else
      lines+="#$num ${title:0:58}   <-- no commit mentions this"$'\n'
      unbuilt="$unbuilt #$num"
    fi
  done <<< "$ms"
  if [[ -n "$unbuilt" ]]; then
    fail milestone "milestone $version carries unbuilt issues:$unbuilt" "$lines"
  else
    pass milestone "milestone $version — every issue has a commit" "$lines"
  fi
}

LABEL[tests]="Tooling tests pass"
check_tests() {
  if (( QUICK )); then skip tests "tooling tests skipped (--quick)"; return; fi
  local bad="" lines="" out name
  for t in scripts/tests/*.test.sh; do
    [[ -e "$t" ]] || continue
    name="$(basename "$t" .test.sh)"
    # Named before it runs: deploy.test.sh takes 47 seconds, and an
    # unattributed silence reads as a hang.
    printf '       %s ... ' "$name"
    if out="$("$t" 2>&1)"; then
      printf '\r       %s %s\n' "$(green ok)" "$name        "
    else
      printf '\r       %s %s\n' "$(red FAIL)" "$name        "
      bad="$bad $name"; lines+="$name: $(printf '%s' "$out" | tail -2)"$'\n'
    fi
  done
  if [[ -n "$bad" ]]; then fail tests "failing suites:$bad" "$lines"
  else pass tests "all tooling test suites pass"; fi
}

LABEL[gates]="A production deploy would be allowed"
check_gates() {
  if (( QUICK )); then skip gates "deploy gates skipped (--quick)"; return; fi
  local out status=0
  # Bounded. deploy.sh's CI gate polls with --wait, which is right for a deploy
  # and wrong here — it once made this sit for ten minutes against a run that
  # was still going.
  out="$(timeout 120 env DEPLOY_GATES_ONLY=1 ./scripts/deploy.sh 2>&1)" || status=$?
  if (( status == 124 )); then
    fail gates "gate check timed out after 120s (CI probably still running)"
  elif (( status == 0 )); then
    pass gates "a production deploy of HEAD would be allowed" \
      "$(printf '%s' "$out" | grep -E '^==> Gates run:')"
  else
    fail gates "a production deploy of HEAD would be refused" \
      "$(printf '%s' "$out" | grep -E '^error:' | tail -3)"
  fi
}

# ---------------------------------------------------------------------------
# Run fastest-first. Summarise in the order a release follows.
# ---------------------------------------------------------------------------

RUN_ORDER=(tree pushed envs milestone ci tests gates)
PROCESS_ORDER=(tree pushed ci tests envs milestone gates)

printf '\n\033[1mChecking\033[0m  (fastest first, so a failure shows early)\n'
for key in "${RUN_ORDER[@]}"; do "check_$key"; done

printf '\n\033[1mIn process order\033[0m\n'
for key in "${PROCESS_ORDER[@]}"; do
  case "${RESULT[$key]:-notrun}" in
    ok)      printf '  %s   %s\n' "$(green ok)"   "${LABEL[$key]}" ;;
    FAIL)    printf '  %s %s\n'   "$(red FAIL)"   "${LABEL[$key]}" ;;
    skipped) printf '  %s %s\n'   "$(amber '--')" "${LABEL[$key]} (skipped)" ;;
    *)       printf '  %s %s\n'   "$(amber '??')" "${LABEL[$key]} (did not run)" ;;
  esac
  if [[ "${RESULT[$key]:-}" == "FAIL" && -n "${DETAIL[$key]:-}" ]]; then
    printf '%s\n' "${DETAIL[$key]}" | while read -r l; do
      [[ -n "$l" ]] && printf '         %s\n' "$l"
    done
  fi
done

printf '\n'
if (( failures > 0 )); then
  printf '%s\n' "$(red "$failures check(s) failed")"
  (( QUICK )) && printf '%s\n' "$(amber '(quick run: tooling tests and deploy gates were not run)')"
  exit 1
fi
if (( QUICK )); then
  printf '%s — %s\n' "$(green 'Everything checked is in place')" \
    "$(amber 'quick run: tooling tests and deploy gates not run')"
else
  printf '%s\n' "$(green 'Everything in place.')"
fi
