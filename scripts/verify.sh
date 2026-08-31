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
#
# ## `note` is not a failure
#
# One verdict reports rather than asserts: housekeeping that is worth seeing and
# blocks nothing. It never changes the exit status, so a non-zero exit keeps
# meaning "something is wrong" rather than "something is worth a look".

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

HERE="$(cd "$(dirname "$0")/.." && pwd)"

# How many commits mention an issue. Shared with `deploy.sh`: this file carried
# the identical defective line, untouched, because it was a copy (#194).
source "$(dirname "${BASH_SOURCE[0]}")/issue-mentions.sh"
cd "$HERE"

declare -A RESULT DETAIL LABEL
failures=0

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
amber() { printf '\033[33m%s\033[0m' "$1"; }

# Records a verdict and prints it as it lands.
#
# `note` is not a fourth kind of failure. It reports something worth being aware
# of that is nobody's fault and blocks nothing — housekeeping, not correctness —
# so it must not colour the exit status, or the exit status stops meaning
# "something is wrong". Owner, 2026-08-17, on merged branches left behind:
# "Being notified is enough. It is good to be aware it is happening."
pass() { RESULT[$1]=ok;      DETAIL[$1]="${3:-}"; printf '  %s   %s\n' "$(green ok)" "$2"; }
fail() { RESULT[$1]=FAIL;    DETAIL[$1]="${3:-}"; failures=$((failures + 1)); printf '  %s %s\n' "$(red FAIL)" "$2"; }
skip() { RESULT[$1]=skipped; DETAIL[$1]="${3:-}"; printf '  %s %s\n' "$(amber '--')" "$2"; }
note() { RESULT[$1]=note;    DETAIL[$1]="${3:-}"; printf '  %s %s\n' "$(amber 'note')" "$2"; }

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

LABEL[branches]="No merged branches left behind"
check_branches() {
  # 3.3's "Delete the branch once its change is live" is a two-part step, and
  # only the first part can be automated away: GitHub can delete the *remote*
  # branch on merge, but nothing reaches this workstation to remove the local
  # one. `git fetch --prune` drops the remote-tracking ref and leaves the branch
  # — which is exactly how issue-33 and issue-50 survived their own releases
  # until 2026-08-17.
  #
  # Deliberately conservative: upstream gone *and* merged into origin/main. A
  # branch that never had an upstream might be a scratch branch mid-thought, and
  # naming it would train the reader to ignore this line.
  if ! git rev-parse --verify -q origin/main > /dev/null; then
    fail branches "cannot tell — no origin/main to compare against"; return
  fi
  local lines="" names="" ref track
  while read -r ref track; do
    [[ "$track" == "[gone]" ]] || continue
    git merge-base --is-ancestor "$ref" origin/main 2> /dev/null || continue
    names="$names $ref"
    lines+="$(printf '%s  (merged, remote deleted)' "$ref")"$'\n'
  done < <(git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads)
  if [[ -z "$names" ]]; then
    pass branches "no merged branches left behind"
  else
    lines+="delete with: git branch -d$names"$'\n'
    note branches "merged branches still here:$names" "$lines"
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

LABEL[reviews]="Shipped projects have been closed out"
# A project is left open at `Post-deployment` by the deploy that ships it (#263),
# so the column means *awaiting its review*. That is a passive reminder, which is
# the point — but a passive reminder is also one a column can quietly accumulate.
#
# This is the bound. `actions.py` mentions a project a week after it ships;
# this fails once a **later release has shipped** while the earlier one was still
# unreviewed, which is a different and much stronger statement: we moved on
# without looking back.
#
# The clock is GitHub's own — `IssueFieldChangedEvent` carries `createdAt` — so
# nothing is stored and a project moved by hand is dated like one moved by
# deploy.sh. Matched on the value moved *to*, because the events keep the option
# name as it was and a rename does not rewrite them.
check_reviews() {
  local lines="" overdue=0 num when tag_date
  if ! command -v gh > /dev/null; then
    fail reviews "not checked — no 'gh' on PATH"; return
  fi
  # The most recent release, as the thing a project should not have outlived.
  tag_date="$(git for-each-ref --sort=-creatordate --format='%(creatordate:unix)' \
    'refs/tags/prod-*' 2>/dev/null | head -1)"
  [[ -n "$tag_date" ]] || { pass reviews "no releases yet — nothing to have outlived"; return; }

  # Both phases a *shipped* project can sit in and rot: it still owes its review
  # (`Post-deployment`), or it owes only its closing (`Project Closedown`).
  #
  # **Dated from entering `Post-deployment`**, not from the phase it is in now.
  # That is when it shipped, and it is the clock that matters — a project that
  # wrote its review promptly and then sat unclosed for a month has still been
  # open for a month.
  for num in $(gh api graphql -f query='{repository(owner:"delphside",name:"tile-lite-elite"){issues(first:100,states:OPEN){nodes{number issueType{name} issueFieldValues(first:10){nodes{... on IssueFieldSingleSelectValue{name field{... on IssueFieldSingleSelect{name}}}}}}}}}' \
      --jq '.data.repository.issues.nodes[] | select(.issueType.name=="Project") | select(any(.issueFieldValues.nodes[]?; .field.name=="Phase" and (.name=="Post-deployment" or .name=="Project Closedown"))) | .number' 2>/dev/null); do
    when="$(gh api graphql -f query="{repository(owner:\"delphside\",name:\"tile-lite-elite\"){issue(number:$num){timelineItems(last:30,itemTypes:[ISSUE_FIELD_CHANGED_EVENT,ISSUE_FIELD_ADDED_EVENT]){nodes{... on IssueFieldChangedEvent{createdAt newValue issueField{... on IssueFieldSingleSelect{name}}} ... on IssueFieldAddedEvent{createdAt value issueField{... on IssueFieldSingleSelect{name}}}}}}}}" \
      --jq '[.data.repository.issue.timelineItems.nodes[] | select(.issueField.name=="Phase") | select((.newValue // .value)=="Post-deployment") | .createdAt] | last // ""' 2>/dev/null)"
    [[ -n "$when" ]] || continue
    if (( $(date -u -d "$when" +%s) < tag_date )); then
      lines+="$(printf '#%-6s shipped, and a later release shipped while it was still open' "$num")"$'\n'
      overdue=1
    fi
  done

  if (( overdue )); then
    fail reviews "a shipped project was still open when the next release went out" "$lines"
  else
    pass reviews "nothing shipped past a project still open from an earlier release"
  fi
}

LABEL[rehearsal]="Rehearsal is closed"
# Rehearsal's gate (#240) is closed by *default*: with no `REHEARSAL_ACCESS_KEY` in the
# host's .env, docker-compose.yml supplies a sentinel and the Caddyfile compares
# every cookie against a value nobody holds, so the site refuses everybody. That
# is the safe failure, and it is also a silent one — a refusal looks the same
# whether the key is missing or simply not held by this machine.
#
# So the state is asserted here rather than discovered when somebody cannot get
# in. The probe needs no ssh and no extra configuration: the unlock path is
# `/unlock/{$REHEARSAL_ACCESS_KEY}`, so asking for the *sentinel's* unlock path answers
# 200 if and only if the host is running the sentinel, and 403 once a real key
# is set. Measured both ways, 2026-08-30.
#
# It sets the sentinel's cookie on the way past, which is why this is a curl and
# not a browser: nothing keeps it.
check_rehearsal() {
  local url="https://rehearsal.tileliteelite.com" body code
  body="$(curl -s -w '\n%{http_code}' --max-time 10 \
    "$url/unlock/no-rehearsal-key-configured" 2>/dev/null)" || body=$'\n000'
  code="${body##*$'\n'}"
  case "$code" in
    403)
      pass rehearsal "a key is configured and the gate is holding" ;;
    200)
      # 200 means two opposite things, and only the body tells them apart.
      # The sentinel's unlock handler answers with its own sentence; anything
      # else at this path is the SPA fallback, which means the gate is not in
      # the deployment at all. Found by running this against the live host
      # while the gate was still unmerged — it reported "locked" about a site
      # that was wide open.
      if [[ "$body" == *"Rehearsal unlocked"* ]]; then
        fail rehearsal "rehearsal has no access key — it is locked to everybody" \
          "fix with: ./scripts/rehearsal-access.sh grant"
      else
        fail rehearsal "rehearsal has no access gate — it is OPEN to the internet" \
          "the gate (#240) is not in the deployed image; deploy it"
      fi ;;
    000)
      fail rehearsal "rehearsal did not answer" \
        "the host may be down; the environments check above says which" ;;
    *)
      fail rehearsal "unexpected answer from rehearsal's gate: HTTP $code" ;;
  esac
}

LABEL[milestone]="Milestone carries only built work"
check_milestone() {
  local version ms unbuilt="" lines=""
  version="$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)"
  if ! command -v gh > /dev/null; then
    fail milestone "milestone $version not read — no 'gh' on PATH"; return
  fi
  if ! ms="$(gh issue list --milestone "$version" --state open \
        --json number,title,issueType \
        --jq '.[] | "\(.number)\t\(.issueType.name // "untyped")\t\(.title)"' 2>&1)"; then
    fail milestone "milestone $version could not be read" "$ms"; return
  fi
  if [[ -z "$ms" ]]; then
    pass milestone "milestone $version has no open issues"; return
  fi
  while IFS=$'\t' read -r num kind title; do
    [[ -z "$num" ]] && continue
    # `rev-list --count`, not `git log … | grep -q .`. The pipe was the defect:
    # `grep -q` exits on the first match, `git log` takes SIGPIPE, and under
    # `set -o pipefail` the pipeline reports failure — so an issue that *is*
    # mentioned reported "no commit mentions this" once the history was long
    # enough. `deploy.sh` carried the identical line and returned 141 on #174.
    mentions="$(commits_mentioning HEAD "$num")"
    if (( mentions > 0 )); then
      lines+="#$num ${kind:0:11} ${title:0:46} ($mentions commits)"$'\n'
    else
      lines+="#$num ${kind:0:11} ${title:0:46}   <-- no commit mentions this"$'\n'
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
    # unattributed silence reads as a hang. Only on a terminal — `\r` does not
    # overwrite in a pipe, it just leaves both halves in the file.
    [[ -t 1 ]] && printf '       %s ... ' "$name"
    if out="$("$t" 2>&1)"; then
      [[ -t 1 ]] && printf '\r'
      printf '       %s %s\n' "$(green ok)" "$name        "
    else
      [[ -t 1 ]] && printf '\r'
      printf '       %s %s\n' "$(red FAIL)" "$name        "
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

# `branches` runs straight after `pushed`, which is what does the fetch — it
# compares against origin/main and would otherwise read a stale one. In process
# order it comes last: tidying up after a change has shipped is the final step,
# and it is the only line here that is housekeeping rather than readiness.
RUN_ORDER=(tree pushed branches envs rehearsal reviews milestone ci tests gates)
PROCESS_ORDER=(tree pushed ci tests envs rehearsal reviews milestone gates branches)

printf '\n\033[1mChecking\033[0m  (fastest first, so a failure shows early)\n'
for key in "${RUN_ORDER[@]}"; do "check_$key"; done

printf '\n\033[1mIn process order\033[0m\n'
for key in "${PROCESS_ORDER[@]}"; do
  case "${RESULT[$key]:-notrun}" in
    ok)      printf '  %s   %s\n' "$(green ok)"     "${LABEL[$key]}" ;;
    FAIL)    printf '  %s %s\n'   "$(red FAIL)"     "${LABEL[$key]}" ;;
    note)    printf '  %s %s\n'   "$(amber 'note')" "${LABEL[$key]}" ;;
    skipped) printf '  %s %s\n'   "$(amber '--')"   "${LABEL[$key]} (skipped)" ;;
    *)       printf '  %s %s\n'   "$(amber '??')"   "${LABEL[$key]} (did not run)" ;;
  esac
  if [[ "${RESULT[$key]:-}" =~ ^(FAIL|note)$ && -n "${DETAIL[$key]:-}" ]]; then
    printf '%s\n' "${DETAIL[$key]}" | while read -r l; do
      [[ -n "$l" ]] && printf '         %s\n' "$l"
    done
  fi
done

# Notes are counted for the verdict line only — never for the exit status.
notes=0
for key in "${PROCESS_ORDER[@]}"; do
  [[ "${RESULT[$key]:-}" == "note" ]] && notes=$((notes + 1))
done
note_suffix=""
(( notes > 0 )) && note_suffix=" $(amber "($notes note(s) — nothing blocking)")"

printf '\n'
if (( failures > 0 )); then
  printf '%s%s\n' "$(red "$failures check(s) failed")" "$note_suffix"
  (( QUICK )) && printf '%s\n' "$(amber '(quick run: tooling tests and deploy gates were not run)')"
  exit 1
fi
if (( QUICK )); then
  printf '%s — %s%s\n' "$(green 'Everything checked is in place')" \
    "$(amber 'quick run: tooling tests and deploy gates not run')" "$note_suffix"
else
  printf '%s%s\n' "$(green 'Everything in place.')" "$note_suffix"
fi
