#!/usr/bin/env bash
set -euo pipefail

# check-rate-limits.sh — does the running server refuse a caller who asks too
# often, and keep answering everybody else?
#
# This is the technical test that stands in for user testing on a change with
# nothing to look at. Run it against the **rehearsal host**, which is why that
# environment exists: same shape as production (2 vCPU, 954 MB), production's
# data, and nobody watching. Numbers tuned on a development machine are
# meaningless — the limits are there to protect a box a fraction its size.
#
#   ./scripts/check-rate-limits.sh                     # the rehearsal host
#   ./scripts/check-rate-limits.sh http://localhost:8081   # or preview
#
# What it asserts, in the order the layers are applied:
#
#   1. /health never refuses, however hard anything else is being refused.
#      deploy.sh smoke-tests this, so a health check that fails under load
#      would roll back a release that was merely busy.
#   2. Registering repeatedly from one address is refused with 429.
#   3. A different address still registers — one caller's allowance is not
#      another's, or the first abuser locks out everyone.
#   4. Logging in repeatedly from one address is refused.
#
# It does not assert the numbers are *right*. It asserts the shape holds:
# refusal rather than a growing queue, per-caller rather than global, and
# health exempt. Whether 2 registrations a minute is the correct figure is a
# judgement about real use, and #28's load tests are where that gets measured.

TARGET="${1:-${REHEARSAL_URL:-https://129.151.84.183.sslip.io}}"
FAILURES=0

say() { printf '  %s\n' "$*"; }

check() {
  local what="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    say "ok   $what"
  else
    say "FAIL $what — wanted $expected, got $actual"
    FAILURES=$((FAILURES + 1))
  fi
}

# A distinct address per run, so a re-run is not refused by the buckets the
# last one filled. `X-Forwarded-For` is what the server keys on, and it is
# trusted only because Caddy is the sole ingress — see `app/throttle.rs`.
RUN="$(( RANDOM % 250 + 1 ))"
BUSY="203.0.113.$RUN"
QUIET="198.51.100.$RUN"

post_status() {
  local path="$1" address="$2" body="$3"
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H 'content-type: application/json' \
    -H "x-forwarded-for: $address" \
    -X POST "$TARGET$path" -d "$body" || echo "000"
}

echo "==> Rate limits on $TARGET"
echo "    busy caller $BUSY, quiet caller $QUIET"
echo

# 2. Registration, from one address, repeatedly.
registered_refusal=""
for attempt in $(seq 1 8); do
  name="ratecheck-$RUN-$attempt"
  status="$(post_status /auth/register "$BUSY" \
    "{\"display_name\":\"$name\",\"email\":\"$name@example.com\",\"password\":\"correct horse battery staple\",\"stay_logged_in\":false}")"
  if [[ "$status" == "429" ]]; then
    registered_refusal="$attempt"
    break
  fi
done
if [[ -n "$registered_refusal" ]]; then
  say "ok   registration refused after $registered_refusal from one address"
else
  say "FAIL registration never refused — eight attempts from one address all passed"
  FAILURES=$((FAILURES + 1))
fi

# 1. Health, while that address is being refused.
check "health still answers while a caller is being refused" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$TARGET/health" || echo 000)"

# 3. A different address is unaffected.
other="ratecheck-$RUN-other"
other_status="$(post_status /auth/register "$QUIET" \
  "{\"display_name\":\"$other\",\"email\":\"$other@example.com\",\"password\":\"correct horse battery staple\",\"stay_logged_in\":false}")"
if [[ "$other_status" == "429" ]]; then
  say "FAIL a quiet caller was refused because a noisy one was busy"
  FAILURES=$((FAILURES + 1))
else
  say "ok   a different address still registers (got $other_status)"
fi

# 4. Login, which costs Argon2 whether or not the credentials are real.
login_refusal=""
for attempt in $(seq 1 20); do
  status="$(post_status /auth/login "$BUSY" \
    '{"display_name":"nobody-at-all","password":"wrong"}')"
  if [[ "$status" == "429" ]]; then
    login_refusal="$attempt"
    break
  fi
done
if [[ -n "$login_refusal" ]]; then
  say "ok   login refused after $login_refusal from one address"
else
  say "FAIL login never refused — twenty attempts from one address all passed"
  FAILURES=$((FAILURES + 1))
fi

echo
if (( FAILURES > 0 )); then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "All rate-limit checks passed."
