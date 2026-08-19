#!/usr/bin/env bash
set -uo pipefail

# check-docs.sh — the documentation's own gate: lint, links, and placement.
#
# 3.3's rule, applied to itself: *"wherever a rule can be checked by the
# tooling, check it there — a rule in a document is advisory; a rule in a gate
# is real."* Every check here was being run by hand, which means run when
# remembered, which is how #137 shipped 81 broken anchors into a branch and
# found them by luck.
#
# One script, called by `.github/workflows/docs.yml`, so the check you make
# before pushing and the one the pull request enforces are the same code — the
# same reason `ci-status.sh` is shared between `deploy.sh` and the terminal.
#
# Three checks, each reported separately and all of them run even when an
# earlier one fails, because "fix one, discover the next" wastes a lap:
#
#   1. markdownlint  — the house style in .markdownlint.jsonc
#   2. links         — every `](#anchor)` resolves (scripts/check-doc-links.py)
#   3. placement     — the folder convention settled on #156
#
# Exits non-zero if any check failed.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
FAILED=0

bold "1. markdownlint"
if npx --yes markdownlint-cli2 "docs/**/*.md" "*.md" 2>&1 | tail -3; then
  :
else
  FAILED=1
fi

bold "2. links"
python3 scripts/check-doc-links.py || FAILED=1

# The convention (#156): design documents live in an issue folder named for the
# issue that owns them — or for the parent issue where there is a workstream —
# and testing documents live in a release folder. Both under docs/changes/.
#
# The five files already in the flat directory stay there: GitHub does not
# follow a rename and several issue comments point at them. They are listed
# rather than pattern-matched so that the list can only shrink.
bold "3. placement"
GRANDFATHERED=(
  "docs/changes/README.md"
  "docs/changes/0.6.0-user-testing.md"
  "docs/changes/25-rate-limiting-test-plan.md"
  "docs/changes/41-user-deletion-test-plan.md"
  "docs/changes/glossary-draft-2026-08-15.md"
  "docs/changes/process-review-2026-08-13.md"
)
STRAY=0
while IFS= read -r file; do
  keep=0
  for old in "${GRANDFATHERED[@]}"; do [[ "$file" == "$old" ]] && keep=1 && break; done
  (( keep )) && continue
  echo "  STRAY   $file"
  echo "          → docs/changes/issues/<issue>-<name>/ for a design document,"
  echo "            docs/changes/releases/<version>/ for a testing document (#156)"
  STRAY=1
done < <(find docs/changes -maxdepth 1 -name '*.md' | sort)
if (( STRAY )); then
  FAILED=1
else
  echo "  every change document is in an issue or release folder"
fi

echo
if (( FAILED )); then
  bold "FAILED"
else
  bold "OK"
fi
exit "$FAILED"
