#!/usr/bin/env bash
set -euo pipefail

# deploy.sh — Build the container images locally and ship them to the
# deployment VM.
#
# Why not build on the VM: the Always Free shape this project runs on
# (VM.Standard.E2.1.Micro) has 1GB RAM, which isn't enough to compile the
# Rust/wasm workspace. So this always builds locally (where there's room)
# and transfers the finished images instead of the source — `docker save`,
# scp, `docker load`, `docker compose up`. See docs/3.3-testing-ci-and-release.md's
# "Container Deployment" section for the full story, including the Oracle
# Cloud networking setup this assumes is already in place.
#
# What gets built is a *fresh checkout of a commit*, never the working
# tree. The build happens in a throwaway `git worktree`, so nothing on
# your disk — the branch you have checked out, staged changes, a
# half-finished edit — can reach production. Two things follow from that:
# deploying an older release is an ordinary operation rather than a
# manoeuvre (pass its ref), and "what is running in production" is always
# answerable from source control alone.
#
# Refuses to run unless: the commit is on origin/main, CI passed for it,
# local staging is currently running it, and production's database hasn't
# already moved past the schema this build knows. See the checks below.
#
# The deploy itself, once those pass:
#
#   1. build the images from a clean checkout, transfer them
#   2. retag the live images :previous, so rollback is a retag not a rebuild
#   3. stop the server and snapshot the database
#   4. apply migrations on their own — a failure here aborts with the
#      previous version still installed, rather than taking the site down
#   5. start the new version
#   6. smoke test the public URL for the expected version, and roll back
#      automatically if it doesn't appear
#
# Steps 3-6 are what make a bad release recoverable in seconds instead of a
# rebuild; `scripts/rollback.sh` does the same thing by hand.
#
# Usage:
#   ./scripts/deploy.sh                # deploy HEAD
#   ./scripts/deploy.sh <commit-ish>   # deploy a specific commit/tag/branch,
#                                      # e.g. `./scripts/deploy.sh prod-0.4.12`
#                                      # to roll back to a previous release
#
# Configure via environment variables (defaults match the current VM):
#   DEPLOY_HOST      Public IP or hostname of the VM (default: 129.151.69.246)
#   DEPLOY_USER      SSH user (default: ubuntu)
#   DEPLOY_SSH_KEY   Private key path (default: ~/.ssh/oracle_tile_lite_elite)
#   DEPLOY_REMOTE_DIR  Directory on the VM holding docker-compose.yml (default: tile-lite-elite)

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_HOST="${DEPLOY_HOST:-129.151.69.246}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/oracle_tile_lite_elite}"
DEPLOY_REMOTE_DIR="${DEPLOY_REMOTE_DIR:-tile-lite-elite}"
STAGING_URL="${STAGING_URL:-http://localhost:8081}"
PROD_URL="${PROD_URL:-https://tileliteelite.com}"
# How many pre-deploy database snapshots to keep on the VM. Rollback is
# expected to happen immediately if at all (a later rollback would discard
# real play), so depth beyond the last few releases has no consumer.
SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-5}"

SSH_OPTS=(-i "$DEPLOY_SSH_KEY" -o ConnectTimeout=10)
REMOTE="$DEPLOY_USER@$DEPLOY_HOST"

cd "$REPO_DIR"

# Fail fast with a clear message rather than a confusing worktree error
# further down if the ref doesn't exist locally.
DEPLOY_REF="${1:-HEAD}"
if ! TARGET_FULL_SHA="$(git rev-parse --verify "${DEPLOY_REF}^{commit}" 2>/dev/null)"; then
  echo "error: '$DEPLOY_REF' is not a valid local git ref (fetch it first if it's remote-only)" >&2
  exit 1
fi
# `gh run list --commit` matches on the full hash only — a short one silently
# returns no runs, which would make the CI gate below fail every deploy.
TARGET_SHA="$(git rev-parse --short "$TARGET_FULL_SHA")"

# The working tree has no say in what ships, so a dirty one isn't an error
# here — it simply isn't part of the deploy. Say so rather than staying
# quiet: the previous behaviour (refusing to run until the tree was clean)
# taught the opposite expectation, that deploy.sh builds what you can see.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "==> Note: your working tree has uncommitted changes. They are NOT part of"
  echo "    this deploy — $TARGET_SHA is built from a clean checkout of that commit."
fi

# Refuses to ship a commit that only exists on this machine — if this
# machine were lost before anyone/anything else had a copy, "what's
# actually running in production" would stop being reproducible from
# source control at all. Fetches first so a stale local view of the
# remote can't produce a false pass.
#
# Asks that question directly rather than through the current branch's
# upstream. The property that matters is "this commit is on the remote";
# a branch's tracking config is only ever a proxy for it, and the proxy
# rejected the case this script now exists to support — a commit reached
# by tag or SHA has no `@{u}` at all, so a rollback failed a gate it
# actually passed.
git fetch --quiet origin
if ! git merge-base --is-ancestor "$TARGET_FULL_SHA" origin/main; then
  echo "error: $TARGET_SHA ($DEPLOY_REF) is not on origin/main — push it first: git push origin main" >&2
  exit 1
fi
echo "==> $TARGET_SHA confirmed present on origin/main"

# Refuses to ship a commit CI hasn't passed. Until this existed, CI was
# only a signal running alongside the release rather than a gate on it: a
# red run stopped nothing, and the only real check was whoever remembered
# to run the suites by hand.
#
# Delegated to ci-status.sh so that the check made by hand at step 1.e and
# the one enforced here are the same code, and cannot answer differently.
if [[ "${DEPLOY_SKIP_CI:-}" == "1" ]]; then
  echo "==> WARNING: skipping the CI gate (DEPLOY_SKIP_CI=1)"
elif ! "$REPO_DIR/scripts/ci-status.sh" "$TARGET_FULL_SHA"; then
  echo "error: refusing to deploy — see above. Fix CI rather than deploying past it," >&2
  echo "       or set DEPLOY_SKIP_CI=1 if GitHub itself is the problem." >&2
  exit 1
fi

# Refuses to ship a commit that was never actually exercised in staging —
# a passing `cargo test` only proves the code compiles and unit-tests
# clean, not that it boots/migrates cleanly in a real container. Without
# this check, testing commit A in staging and then committing a "quick
# fix" B before deploying would silently ship B untested — easy to do
# without noticing, since deploy.sh has no other way to know staging
# wasn't re-run. See docs/3.3-testing-ci-and-release.md.
if [[ "$DEPLOY_REF" == "HEAD" ]]; then
  STAGING_CMD="./scripts/deploy-staging.sh"
else
  STAGING_CMD="./scripts/deploy-staging.sh at $DEPLOY_REF"
fi
STAGING_HEALTH="$(curl -sf --max-time 5 "$STAGING_URL/health" 2>/dev/null || true)"
STAGING_VERSION="$(printf '%s' "$STAGING_HEALTH" | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4)"
STAGING_SHA="${STAGING_VERSION#*+}"
if [[ -z "$STAGING_VERSION" ]]; then
  echo "error: local staging ($STAGING_URL) isn't reachable — test this commit there first: $STAGING_CMD" >&2
  exit 1
elif [[ "$STAGING_SHA" == "$STAGING_VERSION" ]]; then
  echo "error: staging is running $STAGING_VERSION, which has no commit id — was it deployed via deploy-staging.sh?" >&2
  exit 1
elif [[ "$STAGING_SHA" != "$TARGET_SHA" ]]; then
  echo "error: staging is running commit $STAGING_SHA, not $TARGET_SHA ($DEPLOY_REF) — test it in staging first: $STAGING_CMD" >&2
  exit 1
fi
echo "==> Staging confirmed running this commit ($TARGET_SHA) — proceeding"

# Refuses to ship an image the live database has already moved past.
#
# Migrations only go forward. sqlx validates, on startup, that every
# migration recorded in the database is one the binary knows about
# (`ignore_missing` is false by default), so an older image meeting a
# newer database fails with `VersionMissing` and **never boots**. Without
# this check that failure arrives after the images are built, transferred
# and swapped in — i.e. as an outage.
#
# The database's own version comes from `/health`'s `schema_version`; the
# target's comes from the migration filenames in that commit's tree, read
# straight out of git so this can run before anything is checked out.
TARGET_SCHEMA="$(git ls-tree --name-only "$TARGET_FULL_SHA" crates/server-game/migrations/ \
  | grep '\.sql$' | sed 's#.*/##' | grep -oE '^[0-9]+' | sort -n | tail -1 | sed 's/^0*//')"
PROD_HEALTH="$(curl -sf --max-time 8 "$PROD_URL/health" 2>/dev/null || true)"
LIVE_SCHEMA="$(printf '%s' "$PROD_HEALTH" | grep -o '"schema_version":[0-9]*' | cut -d: -f2)"

if [[ -z "$PROD_HEALTH" ]]; then
  echo "==> Note: couldn't reach $PROD_URL/health, so the schema check was skipped."
elif [[ -z "$LIVE_SCHEMA" ]]; then
  # Every deployment before this field existed. Nothing to compare against,
  # and saying so is better than silently passing a check that never ran.
  echo "==> Note: production reports no schema_version (it predates the field),"
  echo "    so the schema check was skipped. It applies from the next deploy on."
elif (( LIVE_SCHEMA > TARGET_SCHEMA )); then
  echo "error: production's database is at migration $LIVE_SCHEMA, but $TARGET_SHA only knows up to $TARGET_SCHEMA." >&2
  echo "       That image would fail sqlx's startup check and never boot." >&2
  echo "" >&2
  echo "       Migrations don't run backwards. To go back past one, restore the" >&2
  echo "       snapshot taken before the deploy that applied it:" >&2
  echo "         ./scripts/rollback.sh                  # list snapshots and images" >&2
  echo "         ./scripts/rollback.sh <snapshot>       # restore it, then deploy" >&2
  exit 1
else
  echo "==> Schema check passed (database at $LIVE_SCHEMA, $TARGET_SHA knows up to $TARGET_SCHEMA)"
fi

# Read from the deployed commit's own tree, not the working tree's
# Cargo.toml — on a rollback those are different numbers, and the tag has
# to name the version that actually shipped.
DEPLOYED_VERSION="$(git show "$TARGET_FULL_SHA:Cargo.toml" | grep -m1 '^version' | cut -d'"' -f2)"

# The fresh checkout. A throwaway `git worktree` rather than checking $REF
# out here: it leaves the real working copy (branch, staged and unstaged
# changes) completely untouched, which is what makes it safe to deploy an
# older commit in the middle of unrelated work.
#
# The compose file comes from the worktree too, so the runtime
# configuration shipped to the VM is the one that belongs to the code
# being shipped — on a rollback, that matters as much as the images do.
WORKTREE_DIR="$(mktemp -d /tmp/tile-lite-elite-deploy-worktree-XXXXXX)"
TMP_TAR=""
cleanup() {
  # `if` rather than `[[ ... ]] &&`: an empty TMP_TAR would make the last
  # command in an EXIT trap return non-zero under `set -e`.
  if [[ -n "$TMP_TAR" ]]; then
    rm -f "$TMP_TAR"
  fi
  git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"
}
trap cleanup EXIT
# rmdir first: `git worktree add` refuses to target a directory mktemp
# already created, even an empty one.
rmdir "$WORKTREE_DIR"
git worktree add --detach "$WORKTREE_DIR" "$TARGET_FULL_SHA" >/dev/null

# Baked into both binaries as SemVer build metadata (e.g. `0.2.0+a1c9f02`) —
# see docs/4.1-configuration.md's "Versioning" section.
export TILE_LITE_ELITE_BUILD_ID="$TARGET_SHA"

# `-f <worktree>/docker-compose.yml` also sets the project directory to the
# worktree, so each service's `context: .` resolves to the checkout rather
# than to this repo. The image tags are unaffected: they derive from the
# `name:` pinned inside the compose file, not from the directory.
echo "==> Building images from a clean checkout of $TARGET_SHA (the slow step, ~2-3 min)"
docker compose -f "$WORKTREE_DIR/docker-compose.yml" build

echo "==> Exporting images"
TMP_TAR="$(mktemp /tmp/tile-lite-elite-images-XXXXXX.tar.gz)"
docker save tile-lite-elite-server:latest tile-lite-elite-web:latest | gzip > "$TMP_TAR"
echo "    $(du -h "$TMP_TAR" | cut -f1) compressed"

echo "==> Transferring to $DEPLOY_HOST"
ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p $DEPLOY_REMOTE_DIR"
scp "${SSH_OPTS[@]}" "$TMP_TAR" "$WORKTREE_DIR/docker-compose.yml" "$REMOTE:$DEPLOY_REMOTE_DIR/"

REMOTE_TAR_NAME="$(basename "$TMP_TAR")"
SNAPSHOT_NAME="pre-$DEPLOYED_VERSION-$TARGET_SHA-$(date -u +%Y%m%dT%H%M%SZ).tgz"

# Rolls production back to the images and database it had a moment ago.
# Delegated to rollback.sh so the automatic recovery below and the one you
# would run by hand are the same code, and cannot drift apart. `--yes`
# because at these call sites the deploy has already failed and the
# confirmation prompt would only stand between a broken site and its fix.
roll_back() {
  echo "==> Rolling back to the pre-deploy state" >&2
  if "$REPO_DIR/scripts/rollback.sh" --yes "$SNAPSHOT_NAME"; then
    echo "==> Rolled back. Production is as it was before this deploy." >&2
  else
    echo "error: THE ROLLBACK ALSO FAILED. Production may be down." >&2
    echo "       Snapshot to restore by hand: $SNAPSHOT_NAME" >&2
    echo "       ssh in and check: docker compose logs --tail=50 server" >&2
  fi
}

echo "==> Loading images and snapshotting the database"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
    set -e
    cd $DEPLOY_REMOTE_DIR

    # Retag the live images as :previous *before* loading the new ones.
    # Without this the old image becomes dangling the moment :latest moves,
    # and the prune below destroys it — which is why rolling back used to
    # mean a full local rebuild and re-transfer for an image that had been
    # sitting here minutes earlier. Two generations, ~300MB, on a disk
    # that is 13% used.
    docker image tag tile-lite-elite-server:latest tile-lite-elite-server:previous 2>/dev/null || true
    docker image tag tile-lite-elite-web:latest tile-lite-elite-web:previous 2>/dev/null || true

    gunzip -c $REMOTE_TAR_NAME | docker load
    rm -f $REMOTE_TAR_NAME
    mkdir -p snapshots

    # Stop the server before snapshotting. The database is SQLite in WAL
    # mode, so tarring it live can capture a torn state — a main file
    # without the WAL entry that completes it. The container is about to be
    # recreated anyway, so quiescing it here costs no extra downtime and
    # makes the snapshot trustworthy.
    docker compose stop server > /dev/null

    # Uses the app's own image purely because it is already present and is
    # debian-slim, so it has tar — no extra pull onto a 1GB VM. The volume
    # is mounted read-only; this only ever reads.
    docker run --rm \
        -v tile-lite-elite-data:/data:ro \
        -v \"\$PWD/snapshots\":/snapshots \
        --entrypoint tar \
        tile-lite-elite-server:latest \
        czf /snapshots/$SNAPSHOT_NAME -C /data .
    echo \"    snapshot: \$(du -h snapshots/$SNAPSHOT_NAME | cut -f1)\"
"

# Apply the schema change on its own, before the new build becomes the
# server. Migrations otherwise run as a side effect of startup, which fuses
# "does the schema change work" with "does the new version serve traffic" —
# and fused, a failing migration is an outage, because the old container has
# already been replaced and the new one just exits and restarts. Asked
# separately, the old code is still installed and the deploy simply stops.
#
# `compose run` rather than a bare `docker run` so this gets the service's
# real volume mount and environment, exactly as the server would.
#
# Wrapped in a timeout because the failure mode of an image that *doesn't*
# understand `--migrate-only` is not an error — the flag is ignored, the
# server starts normally, and it runs forever. Found the hard way against a
# staging image built before the flag existed: the command simply never
# returned. A deploy that hangs is worse than one that fails, so cap it.
echo "==> Applying migrations (separately, so a failure here is not an outage)"
if ! ssh "${SSH_OPTS[@]}" "$REMOTE" "
    set -e
    cd $DEPLOY_REMOTE_DIR
    timeout 300 docker compose run --rm --no-deps server --migrate-only
"; then
  echo "error: migrations failed (or timed out) — this build's schema change does not apply" >&2
  echo "       to production's database, or the image ignored --migrate-only and hung." >&2
  echo "       Nothing was swapped in. SQLite wraps each migration in a transaction," >&2
  echo "       so the database is unchanged, and the previous version is still installed." >&2
  echo "       Restoring the snapshot and restarting it now, to be certain." >&2
  roll_back
  exit 1
fi

echo "==> Starting the new version"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
    set -e
    cd $DEPLOY_REMOTE_DIR
    docker compose up -d

    # Prunes the image the *previous* deploy had tagged :previous, which
    # this deploy's retag just displaced. Keeps exactly two generations.
    docker image prune -f > /dev/null

    # \`ls -t\` is safe here: these names are generated by this script and
    # contain no whitespace.
    ls -1t snapshots/*.tgz 2>/dev/null | tail -n +$((SNAPSHOT_KEEP + 1)) | xargs -r rm -f
    echo \"    snapshots kept: \$(ls -1 snapshots/*.tgz | wc -l)\"
"

# The smoke test. End to end on purpose — public DNS, TLS, Caddy, and the
# server behind it — because that is the path a player takes, and each hop
# is something a deploy can break without the container itself looking
# unhealthy. Checking the version rather than just a 200 is what makes it a
# test of *this* deploy: a stale container still answering would otherwise
# pass.
EXPECTED_VERSION="$DEPLOYED_VERSION+$TARGET_SHA"
echo "==> Smoke testing $PROD_URL (expecting $EXPECTED_VERSION)"
SMOKE_OK=0
for _ in $(seq 1 30); do
  LIVE_HEALTH="$(curl -sf --max-time 5 "$PROD_URL/health" 2>/dev/null || true)"
  LIVE_APP="$(printf '%s' "$LIVE_HEALTH" | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4)"
  if [[ "$LIVE_APP" == "$EXPECTED_VERSION" ]]; then
    SMOKE_OK=1
    echo "    $LIVE_HEALTH"
    break
  fi
  sleep 2
done

if (( SMOKE_OK == 0 )); then
  echo "error: production did not come up healthy on $EXPECTED_VERSION within 60s." >&2
  echo "       last /health: ${LIVE_HEALTH:-<no response>}" >&2
  roll_back
  exit 1
fi

echo "==> Ensuring the 'sa' alias for tile-lite-elite-admin is set up and current on the VM"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
    # Drop any existing 'alias sa=' line first, then re-append the current
    # definition. A stale line (e.g. an old deploy dir, or the pre-rename
    # admin binary name) used to survive because the previous logic only
    # appended when *no* 'alias sa=' line existed at all — so an out-of-date
    # value was never refreshed. Delete-then-append converges to exactly one
    # correct line whether the alias was absent, current, or stale.
    sed -i '/alias sa=/d' ~/.bashrc 2>/dev/null || true
    echo \"alias sa='docker compose -f ~/$DEPLOY_REMOTE_DIR/docker-compose.yml exec server tile-lite-elite-admin'\" >> ~/.bashrc \
        || echo \"    (warning: could not set up the 'sa' alias for tile-lite-elite-admin)\"
"

# Stamp the deployed commit in git history. A tag rather than a commit: it
# points at the *thing that shipped*, not at the bump that follows it, and
# it costs no history. `git tag --list 'prod-*'` is then the deployment log,
# `git describe --tags` on any commit says which release it came after, and
# `git log prod-0.4.12..prod-0.4.13` is exactly what a given deploy carried.
#
# Annotated (-a), so it records who deployed and when as a real object
# rather than a bare pointer. Named explicitly against the deployed SHA, so
# it lands correctly regardless of the bump below.
DEPLOY_TAG="prod-$DEPLOYED_VERSION"
if git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/$DEPLOY_TAG" > /dev/null; then
  # Same version deployed twice — a redeploy, a rollback to a release that
  # already carries its tag, or a bump that didn't happen. Keep both rather
  # than moving the tag: a force-moved tag loses the record of the earlier
  # deploy, which is the one thing this exists to keep.
  DEPLOY_TAG="$DEPLOY_TAG-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "==> Tag exists already; using $DEPLOY_TAG"
fi
git -C "$REPO_DIR" tag -a "$DEPLOY_TAG" "$TARGET_FULL_SHA" \
  -m "Deployed to production $(date -u +%Y-%m-%dT%H:%MZ) from $TARGET_SHA"
git -C "$REPO_DIR" push --quiet origin "$DEPLOY_TAG"
echo "==> Tagged $DEPLOY_TAG"

# The working tree moves one patch ahead of what was just shipped, so no
# later commit is ever built carrying a version number already live. This
# used to be a step you had to remember (docs/3.3, an explicit final step) — but it is
# only ever correct immediately after a successful deploy, which is exactly
# here, and nowhere else.
#
# Only when rolling *forward*, though. After a rollback the branch tip is
# already ahead of what's now in production, and bumping it again would
# claim a release that never happened — the version to move on from is the
# newest one, not the one just redeployed.
CURRENT_BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
BRANCH_TIP="$(git -C "$REPO_DIR" rev-parse HEAD)"
NEXT_VERSION="$(printf '%s' "$DEPLOYED_VERSION" | awk -F. '{printf "%s.%s.%d", $1, $2, $3 + 1}')"

if [[ "${DEPLOY_SKIP_BUMP:-}" == "1" ]]; then
  echo "==> Skipping the version bump (DEPLOY_SKIP_BUMP=1) — production is on $DEPLOYED_VERSION"
elif [[ "$BRANCH_TIP" != "$TARGET_FULL_SHA" ]]; then
  echo "==> Deployed $DEPLOYED_VERSION from an earlier commit, so leaving the version alone."
  echo "    Your branch ($CURRENT_BRANCH) is already ahead of what's now in production."
elif [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
  echo "==> Detached HEAD, so leaving the version alone — nothing to bump onto."
elif ! git -C "$REPO_DIR" diff --quiet -- Cargo.toml Cargo.lock; then
  echo "==> Cargo.toml/Cargo.lock have uncommitted edits, so leaving the version alone." >&2
  echo "    Bump to $NEXT_VERSION by hand once they're committed." >&2
else
  echo "==> Bumping the working tree to $NEXT_VERSION (production now holds $DEPLOYED_VERSION)"
  sed -i "0,/^version = \"$DEPLOYED_VERSION\"/s//version = \"$NEXT_VERSION\"/" "$REPO_DIR/Cargo.toml"
  # Refreshes Cargo.lock's workspace versions so the bump commit is complete.
  ( cd "$REPO_DIR" && cargo check --workspace --quiet > /dev/null 2>&1 || true )
  git -C "$REPO_DIR" add Cargo.toml Cargo.lock
  # Read API_VERSION from the commit, not the working tree. This commit
  # carries only Cargo.toml/Cargo.lock, so its api/src/lib.rs is HEAD's —
  # and check-commit-stamp.sh validates the stamp against the commit's own
  # tree. An uncommitted edit to API_VERSION would otherwise produce a
  # stamp that fails its own check.
  BUMP_API="$(git -C "$REPO_DIR" show HEAD:crates/api/src/lib.rs \
    | grep -m1 'API_VERSION: ApiVersion' \
    | grep -o 'major: [0-9]*, minor: [0-9]*' | sed 's/major: //; s/, minor: /./')"
  git -C "$REPO_DIR" commit --quiet \
    -m "app $NEXT_VERSION api $BUMP_API: bump dev version following production release" \
    -m "Production now runs $DEPLOYED_VERSION+$TARGET_SHA."
  git -C "$REPO_DIR" push --quiet origin "$CURRENT_BRANCH"
  echo "    committed and pushed"
fi

echo "==> Done — https://$DEPLOY_HOST.sslip.io (or your configured hostname)"
