#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/backup-to-oci.sh under the same `set -euo pipefail` it runs
# with, against stubbed `docker`, `curl` and `sqlite3`. A harness that relaxes
# that once let a silent-abort bug into a production deploy (docs/3.3), and this
# script runs unattended at 03:00, where a silent abort is the worst kind.
#
# What matters is the failure paths, because the success path announces itself
# and the failures are the ones that would otherwise be discovered by a restore
# that does not work.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/backup-to-oci.sh"
failures=0

# A PATH containing only the tools the script uses, each a stub we control.
# Naming them is the only way to be sure of what is absent — an earlier test in
# this directory passed locally and failed in CI because a binary lived
# somewhere different.
make_env() {
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  for tool in date mktemp rm stat gzip printf cat mkdir; do
    ln -sf "$(command -v "$tool" || echo /bin/true)" "$dir/bin/$tool" 2>/dev/null || true
  done
  echo "$dir"
}

# docker stub: `exec` runs sqlite3-ish things, `cp` produces a file.
write_docker() {
  cat > "$1/bin/docker" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == cp ]]; then
    # the last argument is the destination
    dest="${@: -1}"
    printf 'SQLite format 3\0' > "$dest"
    exit 0
  fi
done
exit 0
STUB
  chmod +x "$1/bin/docker"
}

write_sqlite3() {   # $2 = what integrity_check reports
  cat > "$1/bin/sqlite3" <<STUB
#!/usr/bin/env bash
echo "$2"
STUB
  chmod +x "$1/bin/sqlite3"
}

write_curl() {      # $2 = exit status for the upload, $3 = for the marker
  cat > "$1/bin/curl" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *marker-backup-ok* ]]; then exit $3; fi
exit $2
STUB
  chmod +x "$1/bin/curl"
}

run_case() {        # name, integrity, upload-status, marker-status, want-exit, want-text
  local name="$1" integrity="$2" up="$3" marker="$4" want_exit="$5" want_text="$6"
  local dir; dir="$(make_env)"
  write_docker "$dir"; write_sqlite3 "$dir" "$integrity"; write_curl "$dir" "$up" "$marker"
  local out status
  set +e
  out="$(PATH="$dir/bin:$PATH" HOME="$dir" PAR_URL="https://example.invalid/p/x/o/" \
         COMPOSE="$dir/compose.yml" bash "$SCRIPT" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -ne "$want_exit" ]]; then
    echo "FAIL  $name: exit $status, wanted $want_exit"; echo "      $out"; failures=1
  elif [[ -n "$want_text" && "$out" != *"$want_text"* ]]; then
    echo "FAIL  $name: output did not mention '$want_text'"; echo "      $out"; failures=1
  else
    echo "ok    $name"
  fi
  rm -rf "$dir"
}

run_case "a good backup uploads and marks"        ok  0 0 0 "uploaded"
run_case "a corrupt copy is never uploaded"       "*** in database main" 0 0 1 "integrity check failed"
run_case "a failed upload is an error"            ok  1 0 1 "upload failed"
run_case "a failed marker warns but does not fail" ok 0 1 0 "the alarm will fire"

# No credential at all: the one that would otherwise upload nothing, quietly.
dir="$(make_env)"; write_docker "$dir"; write_sqlite3 "$dir" ok; write_curl "$dir" 0 0
set +e
out="$(PATH="$dir/bin:$PATH" HOME="$dir" COMPOSE="$dir/compose.yml" bash "$SCRIPT" 2>&1)"; status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "FAIL  no credential: exited 0"; failures=1
elif [[ "$out" != *"no PAR_URL"* ]]; then
  echo "FAIL  no credential: did not say why"; echo "      $out"; failures=1
else
  echo "ok    no credential is an error, not a silent no-op"
fi
rm -rf "$dir"

# --- the one thing a stubbed curl can never check -----------------------------
#
# Every case above answers through a fake `curl`, which accepts any arguments it
# is given. That is what let a real defect pass a green suite on 2026-08-23: all
# three marker uploads used `curl -T -`, reading the body from stdin. curl cannot
# know the length in advance, so it sends `Transfer-Encoding: chunked` — and OCI
# Object Storage answers **501 Not Implemented**. Measured on the production host:
# stdin 501, the identical bytes from a file 200.
#
# The alarms all watch marker objects for *absence of success*, so not one of the
# three could ever have been satisfied. Backups would have run nightly while the
# alarms insisted they had not.
#
# A stub cannot catch that: the difference is in what the real service accepts.
# What can be checked is the flag, in every script that uploads. A lint rather
# than a behaviour test, and here because the behaviour needs a bucket to test.
for f in backup-to-oci.sh restore-backup.sh check-log-hygiene-nightly.sh; do
  [[ -e "$HERE/$f" ]] || continue
  # Uncommented occurrences only — the explanatory comments quote the flag.
  if grep -vE '^[[:space:]]*#' "$HERE/$f" | grep -q -- '-T -'; then
    echo "FAIL  $f uploads from stdin (-T -); OCI rejects chunked with 501"
    failures=1
  fi
done
(( failures )) || echo "ok    no script uploads a marker from stdin"

if (( failures )); then echo; echo "backup-to-oci.sh: FAILURES"; exit 1; fi
echo; echo "backup-to-oci.sh: all cases pass"
