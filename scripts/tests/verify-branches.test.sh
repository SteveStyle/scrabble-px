#!/usr/bin/env bash
set -euo pipefail

# Tests that verify.sh notices a merged branch whose remote has been deleted.
#
# **The check existed and did not work, and the reason is the thing under test.**
# `check_branches` reads `[gone]` from `upstream:track`, which git only sets once
# the stale remote-tracking ref has been pruned — and `check_pushed`, the only
# thing that fetches, fetched without `--prune`. So the ref survived, `track`
# stayed empty, and the check passed for a reason with nothing to do with
# branches. `103-tab-icon` was merged on 2026-09-05, GitHub deleted its remote on
# merge, and verify.sh reported "no merged branches left behind" for a day.
#
# A real git fixture rather than a stub, because the defect is entirely in what
# git reports about refs. A stubbed `git` would have been written against the
# same wrong assumption as the code.

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0

check() {
  local what="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then printf '  ok   %s\n' "$what"
  else printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$what" "$want" "$got"; failures=$((failures + 1)); fi
}

DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT

# A bare "origin", a clone, a branch merged into main, and its remote deleted —
# which is exactly what GitHub does when a pull request merges.
git init -q --bare "$DIR/origin.git"
git clone -q "$DIR/origin.git" "$DIR/work" 2>/dev/null
cd "$DIR/work"
git config user.email t@example.com; git config user.name test
git commit -q --allow-empty -m "base"; git branch -M main; git push -q -u origin main
git checkout -q -b feature; git commit -q --allow-empty -m "work"; git push -q -u origin feature
git checkout -q main; git merge -q --ff-only feature; git push -q origin main
# Deleted **in the bare repo directly**, not with `git push --delete` from here.
# That distinction is the whole fixture: pushing a delete prunes this clone's
# remote-tracking ref as a side effect, so `track` would read `[gone]` with no
# fetch at all and the test would pass against the broken code. GitHub deletes
# the branch server-side on merge, and this clone cannot know until it prunes.
# The first version of this test got that wrong and said so on the first run.
git -C "$DIR/origin.git" branch -D feature -q 2>/dev/null || git -C "$DIR/origin.git" branch -D feature
cd "$DIR/work"

# The state before anything prunes: the branch is merged, its remote is gone,
# and git has not been told.
before="$(git for-each-ref --format='%(upstream:track)' refs/heads/feature)"
check "before pruning, track is empty rather than [gone]" "" "$before"

# What the old code did: fetch without --prune.
git fetch -q origin 2>/dev/null || true
after_plain="$(git for-each-ref --format='%(upstream:track)' refs/heads/feature)"
check "a plain fetch leaves the stale ref, so the check cannot fire" "" "$after_plain"

# What verify.sh does now.
git fetch -q --prune origin 2>/dev/null || true
after_prune="$(git for-each-ref --format='%(upstream:track)' refs/heads/feature)"
check "a pruning fetch marks it [gone], which is what the check reads" "[gone]" "$after_prune"

# And the check's own condition, run against the fixture.
found=""
while read -r ref track; do
  [[ "$track" == "[gone]" ]] || continue
  git merge-base --is-ancestor "$ref" origin/main 2>/dev/null || continue
  found="$found $ref"
done < <(git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads)
check "the merged branch is named" " feature" "$found"

# An unmerged branch with a live remote must not be named — a scratch branch
# mid-thought is not litter, and naming it trains the reader to ignore the line.
git checkout -q -b scratch; git commit -q --allow-empty -m "wip"; git push -q -u origin scratch
git checkout -q main; git fetch -q --prune origin
quiet=""
while read -r ref track; do
  [[ "$track" == "[gone]" ]] && quiet="$quiet $ref"
done < <(git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads)
check "a live branch is left alone" " feature" "$quiet"

# The guard that would catch the regression: verify.sh must prune.
cd "$HERE"
check "verify.sh fetches with --prune" "1" \
  "$(grep -c 'git fetch -q --prune origin' scripts/verify.sh)"

echo
if (( failures > 0 )); then echo "  $failures check(s) failed"; exit 1; fi
echo "  all checks passed"
