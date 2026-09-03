#!/usr/bin/env bash
set -euo pipefail
# pre-commit-hook.test.sh — the image rule refuses what ships and passes what
# does not.
#
# Run under the same `set -euo pipefail` the hook itself runs under: a harness
# missing pipefail once hid a silent abort that reached a production deploy.
#
# The rule is an allowlist of non-shipping paths, so the cases that matter most
# are the ones nobody listed: an unrecognised new file at the repo root must be
# refused, not waved through.

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.githooks/pre-commit"
PASS=0; FAIL=0

# One throwaway repo per case: the hook reads the branch, the index and HEAD.
run_case() {
  local desc="$1" expect="$2"; shift 2
  local tmp got=0; tmp="$(mktemp -d)"
  # `|| got=$?` and not a bare call: under `set -e` a failing subshell aborts
  # the script before the next line runs, so every refusal case would vanish.
  (
    cd "$tmp"
    git init -q .
    git config user.email t@t; git config user.name t
    git config core.hooksPath /dev/null
    mkdir -p docs scripts
    # docs/3.0-tools.md must exist: rule 2 reads it, and check-docs is skipped
    # by keeping every fixture free of markdown.
    printf 'x\n' > docs/3.0-tools.md
    git add -A; git commit -qm "app 0.0.0 api 0.0: base"
    git branch -M main
    for f in "$@"; do mkdir -p "$(dirname "$f")"; printf 'x\n' >> "$f"; git add "$f"; done
    "$HOOK" > /dev/null 2>&1
  ) || got=$?
  if [ "$got" -eq "$expect" ]; then
    echo "  ok       $desc"; PASS=$((PASS+1))
  else
    echo "  FAILED   $desc (expected exit $expect, got $got)"; FAIL=$((FAIL+1))
  fi
  rm -rf "$tmp"
}

echo "refused on main (ships in the image):"
run_case "a crate source file"            1 crates/server-game/src/lib.rs
run_case "Cargo.toml"                     1 Cargo.toml
run_case "Cargo.lock"                     1 Cargo.lock
run_case "the Dockerfile"                 1 Dockerfile
run_case "docker-compose.yml"             1 docker-compose.yml
run_case "the Caddyfile"                  1 Caddyfile
run_case ".dockerignore"                  1 .dockerignore
run_case ".cargo/config.toml"             1 .cargo/config.toml
run_case "a build asset nobody listed"    1 build-assets/nginx.conf
run_case "an unknown file at the root"    1 something-new.yml
run_case "old-crates, which the Dockerfile COPYs" 1 old-crates/first-try/src/main.rs
run_case "one shipping file among safe ones" 1 docs/x.txt crates/api/src/a.rs

echo "allowed on main (does not ship):"
run_case "a script"                       0 scripts/thing.sh.tmp
run_case "an e2e test"                    0 e2e/login.spec.ts
run_case "a workflow"                     0 .github/workflows/ci.yml
run_case "a crate example"                0 crates/server-game/examples/bench.rs
run_case "a crate integration test"       0 crates/rules-shared/tests/words.rs

run_case "the gitignore"                  0 .gitignore

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
