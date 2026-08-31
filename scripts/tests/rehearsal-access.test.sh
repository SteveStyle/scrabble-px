#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/rehearsal-access.sh under the same `set -euo pipefail` it runs
# with — a harness missing pipefail once hid a silent abort that reached a
# production deploy.
#
# `ssh` is stubbed, so nothing touches the rehearsal host. Every case runs
# against a scripted remote whose .env contents and command results are set per
# test. The cases that matter are the two that would otherwise read as success:
# a host with no key configured, and a key written to .env but never applied —
# the second looks exactly like a wrong key when a device is refused.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ACCESS="$HERE/rehearsal-access.sh"
failures=0

setup() {
  DIR="$(mktemp -d)"; BIN="$DIR/bin"; mkdir -p "$BIN"
  CALLS="$DIR/calls"; : > "$CALLS"; export CALLS
  # The stub answers the three remote reads the script makes, and records the
  # writes so a test can assert what would have happened on the host.
  cat > "$BIN/ssh" <<'STUB'
#!/usr/bin/env bash
CMD="$*"
echo "$CMD" >> "$CALLS"
case "$CMD" in
  *"grep -m1 '^REHEARSAL_ACCESS_KEY='"*) printf '%s' "${ENV_KEY:-}" ;;
  *"printenv REHEARSAL_ACCESS_KEY"*)     printf '%s' "${LIVE_KEY:-}" ;;
  *"openssl rand -hex 24"*)       printf '%s' "${NEW_KEY:-deadbeef}" ;;
  *"docker compose up -d web"*)   [[ "${APPLY_EXIT:-0}" == 0 ]] || exit 1
                                  echo applied ;;
  *) : ;;
esac
STUB
  chmod +x "$BIN/ssh"
  # qrencode absent, so `grant` takes the printed-URL path and the test does
  # not depend on a package being installed.
  PATH="$BIN:$PATH"
  unset ENV_KEY LIVE_KEY NEW_KEY APPLY_EXIT 2>/dev/null || true
  export HOME="$DIR"   # the ssh key path is derived from $HOME; never read
}
teardown() { rm -rf "$DIR"; }

check() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"
  else echo "FAIL $1"; echo "     wanted: $2"; echo "     got:    $3"; failures=$((failures + 1)); fi
}
status_of() { local s=0; "$@" > /dev/null 2>&1 || s=$?; echo "$s"; }

# --- called wrong ------------------------------------------------------------
setup
check "no argument prints usage and exits 2" "2" "$(status_of "$ACCESS")"
check "an unknown argument does too"         "2" "$(status_of "$ACCESS" unlock-everything)"
teardown

# --- grant on a host that has never been configured --------------------------
setup
ENV_KEY=""; NEW_KEY="abc123"; export ENV_KEY NEW_KEY
OUT="$("$ACCESS" grant 2>&1)"
check "grant generates a key when none is set" "1" \
  "$(printf '%s' "$OUT" | grep -c 'No key configured')"
check "and writes it to the host's .env" "1" \
  "$(grep -c "echo 'REHEARSAL_ACCESS_KEY=abc123'" "$CALLS")"
check "and applies it with 'up -d web', not restart" "1" \
  "$(grep -c 'docker compose up -d web' "$CALLS")"
check "and shows the unlock URL carrying that key" "1" \
  "$(printf '%s' "$OUT" | grep -c 'https://rehearsal.tileliteelite.com/unlock/abc123')"
teardown

# --- the sentinel is treated as "not configured", not as a key ---------------
setup
ENV_KEY="no-rehearsal-key-configured"; NEW_KEY="fresh99"; export ENV_KEY NEW_KEY
OUT="$("$ACCESS" grant 2>&1)"
check "the sentinel is replaced rather than handed out" "0" \
  "$(printf '%s' "$OUT" | grep -c 'unlock/no-rehearsal-key-configured')"
check "and a real key is issued instead" "1" \
  "$(printf '%s' "$OUT" | grep -c 'unlock/fresh99')"
teardown

# --- grant on a configured host does not rotate ------------------------------
setup
ENV_KEY="existing42"; export ENV_KEY
OUT="$("$ACCESS" grant 2>&1)"
check "grant reuses the existing key" "1" \
  "$(printf '%s' "$OUT" | grep -c 'unlock/existing42')"
# Matched as the *write* — `REHEARSAL_ACCESS_KEY=` also appears in the read command
# (`grep -m1 '^REHEARSAL_ACCESS_KEY=' .env`), so the bare string matches a call that
# changed nothing. The same trap as matching an account name anywhere on a
# stubbed argument line rather than as the delete's argument.
check "and writes nothing — the laptop stays unlocked" "0" \
  "$(grep -c "echo 'REHEARSAL_ACCESS_KEY=" "$CALLS")"
teardown

# --- revoke always rotates ---------------------------------------------------
setup
ENV_KEY="existing42"; NEW_KEY="rotated7"; export ENV_KEY NEW_KEY
"$ACCESS" revoke > /dev/null 2>&1
check "revoke writes a new key even when one is set" "1" \
  "$(grep -c "echo 'REHEARSAL_ACCESS_KEY=rotated7'" "$CALLS")"
teardown

# --- a write that does not apply is a failure, not a shrug -------------------
setup
ENV_KEY=""; NEW_KEY="abc123"; APPLY_EXIT=1; export ENV_KEY NEW_KEY APPLY_EXIT
check "grant fails when the container will not take the key" "1" \
  "$(status_of "$ACCESS" grant)"
teardown

# --- status tells the three states apart -------------------------------------
setup
ENV_KEY=""; LIVE_KEY="no-rehearsal-key-configured"; export ENV_KEY LIVE_KEY
check "no key in .env reports locked" "1" \
  "$("$ACCESS" status 2>&1 | grep -c 'locked to everybody')"
teardown

setup
ENV_KEY="k1"; LIVE_KEY="k1"; export ENV_KEY LIVE_KEY
check "a matching pair reports healthy" "0" "$(status_of "$ACCESS" status)"
teardown

setup
ENV_KEY="k2"; LIVE_KEY="k1"; export ENV_KEY LIVE_KEY
check "a key written but never applied is non-zero" "1" "$(status_of "$ACCESS" status)"
check "and says why"                                "1" \
  "$("$ACCESS" status 2>&1 | grep -c "without 'docker compose up -d web'")"
teardown

echo
if (( failures > 0 )); then echo "$failures check(s) failed" >&2; exit 1; fi
echo "All rehearsal-access checks passed."
