#!/usr/bin/env bash
set -euo pipefail

# restore-prod-snapshot.sh — Put production's database back to a snapshot
# taken before a deploy.
#
# This is the rollback path for a schema change. Migrations only run
# forward: sqlx checks on startup that every migration recorded in the
# database is one the binary knows about, so an older image meeting a newer
# database fails with `VersionMissing` and never boots. There is no "undo"
# to run — going back past a migration means putting the earlier database
# back, which is what this does.
#
# `scripts/deploy.sh` takes one of these snapshots automatically before
# every deploy (server stopped first, so SQLite's WAL is quiesced and the
# copy is consistent), keeps the most recent few, and refuses a deploy
# whose target is behind the live schema — pointing here.
#
# **This discards everything written since the snapshot.** That is the
# accepted trade: a rollback is expected to happen immediately, when the
# new release is minutes old and the lost writes are the few games played
# in that window. It is not a way to recover last week.
#
# Usage:
#   ./scripts/restore-prod-snapshot.sh                 # list what's available
#   ./scripts/restore-prod-snapshot.sh <snapshot-name> # restore it
#
# After restoring, deploy the matching older image:
#   ./scripts/deploy-staging.sh at <ref>   # rehearse, as for any deploy
#   ./scripts/deploy.sh <ref>
#
# Configure via the same environment variables as deploy.sh:
#   DEPLOY_HOST, DEPLOY_USER, DEPLOY_SSH_KEY, DEPLOY_REMOTE_DIR

DEPLOY_HOST="${DEPLOY_HOST:-129.151.69.246}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/oracle_tile_lite_elite}"
DEPLOY_REMOTE_DIR="${DEPLOY_REMOTE_DIR:-tile-lite-elite}"

SSH_OPTS=(-i "$DEPLOY_SSH_KEY" -o ConnectTimeout=10)
REMOTE="$DEPLOY_USER@$DEPLOY_HOST"

SNAPSHOT="${1:-}"

# No argument: list and stop. Listing is the safe default deliberately —
# the destructive form has to be asked for by name, and you cannot name one
# without having seen this list first.
if [[ -z "$SNAPSHOT" ]]; then
  echo "==> Snapshots on $DEPLOY_HOST (newest first)"
  ssh "${SSH_OPTS[@]}" "$REMOTE" "
      cd $DEPLOY_REMOTE_DIR 2>/dev/null || { echo '    (no deploy directory)'; exit 0; }
      if ! ls snapshots/*.tgz > /dev/null 2>&1; then
          echo '    (none yet — deploy.sh writes one before each deploy)'
          exit 0
      fi
      ls -1t snapshots/*.tgz | while read -r f; do
          printf '    %-52s %6s  %s\n' \"\$(basename \"\$f\")\" \"\$(du -h \"\$f\" | cut -f1)\" \"\$(date -r \"\$f\" -u +%Y-%m-%dT%H:%MZ)\"
      done
  "
  echo
  echo "    Restore one with: ./scripts/restore-prod-snapshot.sh <name>"
  echo "    The name encodes the version and commit that were live *before*"
  echo "    that deploy — pre-<version>-<sha>-<when>.tgz"
  exit 0
fi

# Named form: confirm the snapshot exists before saying anything alarming,
# so a typo produces "not found" rather than a scary prompt for a restore
# that could never have happened.
if ! ssh "${SSH_OPTS[@]}" "$REMOTE" "test -f $DEPLOY_REMOTE_DIR/snapshots/$SNAPSHOT"; then
  echo "error: no snapshot named '$SNAPSHOT' on $DEPLOY_HOST." >&2
  echo "       Run without arguments to list what's there." >&2
  exit 1
fi

CURRENT="$(curl -sf --max-time 8 "https://tileliteelite.com/health" 2>/dev/null \
  | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || true)"

echo "==> About to restore production's database on $DEPLOY_HOST"
echo "        snapshot:  $SNAPSHOT"
echo "        live now:  ${CURRENT:-unknown}"
echo
echo "    This DISCARDS every game, move and account created since that"
echo "    snapshot was taken. It cannot be undone — the current database is"
echo "    replaced, not set aside."
echo
read -r -p "    Type the snapshot name again to confirm: " CONFIRM
if [[ "$CONFIRM" != "$SNAPSHOT" ]]; then
  echo "    Names don't match — nothing was changed."
  exit 1
fi

echo "==> Restoring"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
    set -e
    cd $DEPLOY_REMOTE_DIR

    # Stop the server first. Replacing the files under a running SQLite
    # connection would leave it reading a database that no longer exists.
    docker compose stop server > /dev/null

    # Clear the volume before unpacking rather than untarring over the top:
    # the WAL and shm sidecar files from the *current* database would
    # otherwise survive and be applied on top of the restored main file,
    # silently reintroducing some of the very writes being discarded.
    # \`--entrypoint sh\` because the app image's entrypoint is the server.
    docker run --rm \
        -v tile-lite-elite-data:/data \
        -v \"\$PWD/snapshots\":/snapshots:ro \
        --entrypoint sh \
        tile-lite-elite-server:latest \
        -c 'rm -rf /data/* /data/.[!.]* 2>/dev/null; tar xzf /snapshots/$SNAPSHOT -C /data'

    docker compose up -d
"

echo "==> Restored. Production is running its previous database."
echo "    The image is unchanged — if you are rolling back a release, deploy"
echo "    the matching older commit now:"
echo "      ./scripts/deploy-staging.sh at <ref>"
echo "      ./scripts/deploy.sh <ref>"
echo
echo "    Confirm what's live:  curl -s https://tileliteelite.com/health"
