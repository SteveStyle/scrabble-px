# Rate Limiting

Design note for issue #25, which absorbed #12, #13 and #14. **Built, not yet
released** — this records the shape for review before it ships, and the test
plan alongside it is [25-rate-limiting-test-plan.md](25-rate-limiting-test-plan.md).

## One problem, three changes

Too much work arriving at a small box. Three issues divide it, and they are
sequenced because each needs the one before it.

| | | |
| --- | --- | --- |
| **#11** | how much runs **at once** | done, live |
| **#25** | how often anyone may **ask** | this change |
| **#28** | whether the numbers are **right** | next |

**#11 is what protects availability.** `spawn_blocking` around Argon2 so a
hash stops occupying an async worker, and semaphores bounding how many hashes
and engine searches run together. It holds against a distributed attempt
because it does not care where requests come from. When saturated it answers
`503` with a retry hint rather than queueing.

**#25 is the weakest of the three against anything determined**, and that is
fine — it is not what it is for. It stops one noisy caller monopolising the
service and returns an honest `429` instead of a queue that grows behind a
semaphore. Without it, #11 converts a load problem into a latency problem and
hides it.

**#28 is how any of this stays true.** The numbers here are a first guess
sized by hand with `curl`; nothing measures them, and nothing catches them
drifting. It runs against rehearsal, on the hardware the limits exist to
protect, and asserts the *rules* rather than the throughput — throughput ages,
rules do not.

The order is not arbitrary. Limits without concurrency bounds protect nothing
under real load; measurement before both has nothing to measure.

### Where they meet, and one place they disagree

Issue #28 pins what #11 and #25 claim, so the claims have to be worth pinning. Two
of its rules land on this change:

**`/health` is never limited**, so `deploy.sh`'s smoke test and
`rollback.sh`'s health poll cannot be throttled during an incident. Held here,
and asserted by `check-rate-limits.sh` already.

**The global limit should answer `503`, not `429`** — the codes distinguish
"you are asking too often" from "the server is full", and a caller can act
differently on each. **This change does not do that.** All four tiers answer
`429`, because they are all `tower_governor` and that is its refusal. The
distinction is real and worth having, and #28 will assert it, so it is better
settled before release than found by the test that was written to trust it.

Its third claim on the pair — the semaphore answering `503` with a retry hint
rather than queueing — is already true, in `with_hash_permit`.

## What this is for, and what it is not

The service already bounds how much expensive work runs *at once*: `hash_limit`
and `engine_limit` are semaphores, so four password hashes can be in flight and
the fifth waits. That is what stops a 954 MB box falling over.

Nothing bounds how *often* anyone asks. A caller can queue without limit —
memory stays bounded at four hashes while the queue behind them does not, and
everybody else waits behind it. The semaphore turns a load problem into a
latency problem and hides it.

**This protects the service from load. It is not how bad behaviour is dealt
with.** Registration is open, so a determined caller can spread across
addresses and accounts, and no arrangement of limits changes that. What limits
buy is a cost per attempt and an honest error instead of a growing queue.
Somebody behaving badly is stopped by stopping their account, which is
separate work.

That distinction is worth holding because it decides how the numbers are set.
Limits tuned to stop an attacker would refuse ordinary players; limits tuned so
ordinary players never meet them will not stop a determined attacker. The
second is the right failure.

## What each refusal means, and where it comes from

Two answers, and keeping them apart is the point. **"You are asking too
often"** is the caller's own doing and is fixed by slowing down. **"The
service is not available"** is not their fault at all, and is fixed by
waiting — it covers busy, down, and unreachable, which a caller cannot tell
apart and does not need to.

The contract lives in [4.3 API Schema](../4.3-api-schema.md#status-codes-what-each-one-means-and-what-a-caller-does),
because both ends are written against it. What follows is the same table from
the server's side: which component produces each code, and on what condition.

| Code | HTTP text | Originates in | Condition |
| --- | --- | --- | --- |
| `429` | Too Many Requests | `throttle::registration` | more than 2 registrations a minute from one address |
| `429` | Too Many Requests | `throttle::heavy_auth` | more than 10 logins or password resets a minute from one address |
| `429` | Too Many Requests | `throttle::authenticated` | more than 240 requests a minute from one session |
| `503` | Service Unavailable | `throttle::global` | more than 1200 requests a minute across everybody |
| `503` | Service Unavailable | `with_hash_permit` | all four hashing permits taken, and none freed within the wait |
| `502` | Bad Gateway | Caddy | the `server` container is not answering — mid-deploy, crashed, or starting |
| `504` | Gateway Timeout | Caddy | the server accepted the connection and did not answer in time |
| *(none)* | — | the network | no response at all; the client treats it as `502` |

Every one of them carries `Retry-After` and an `ApiError` body, so a caller
gets the same shape whatever refused them.

That last point took a change to get right. `tower_governor` writes its own
plain-text body by default, which a client parsing `ApiError` cannot read — a
limit would have arrived as "something went wrong" rather than as the one
thing the caller could act on. Both families now go through
`ApiProblem`, via the layer's `error_handler`.

**Why the global floor is `503` and the keyed tiers are `429`.** A caller who
trips a keyed tier has personally asked too often; one who trips the floor may
have made a single request and been unlucky. Telling the second to slow down
would blame them for somebody else's traffic, and would hide a capacity
problem inside a log that looks full of abusers. `ApiProblem::unavailable`
already drew this line for the hashing semaphore; the floor joins it.

**One gap this leaves.** The client classifies `502`–`504` as unreachable and
has nothing at all for `429` — it has never seen one, because nothing has ever
produced one. Shipping this without a message for it means a rate-limited
player sees a generic failure. Raised separately; the server contract is what
this change settles.

## Four tiers

Applied outermost first, each answering a different question:

| Tier | Keyed by | Question |
| --- | --- | --- |
| registration | client address | is one source manufacturing accounts |
| heavy auth | client address | is one source burning Argon2 time |
| authenticated | session token | is one caller monopolising the service |
| global | nothing | is the service as a whole beyond its means |

### What is limited, and by what

The same four tiers as a grid of *what is counted* against *who it is counted
for*. A blank is not an oversight to be filled in — it is a combination
deliberately not limited, and the blanks are the more interesting half.

| | per IP | per session | per account | global |
| --- | --- | --- | --- | --- |
| **registrations** | 2/min, burst 3 | | | |
| **logins and password resets** | 10/min, burst 10 | | | |
| **authenticated requests** | | 240/min, burst 60 | | |
| **any request** | | | | 1200/min, burst 200 |

Three things fall out of it that the list above cannot show.

**The account column is empty, and that is a substitution rather than a gap.**
The issue asked for authenticated limits keyed per account. They are keyed per
session, because resolving a token to an account needs the database and a key
extractor cannot wait. Session is a proxy that coincides with account for the
case that matters — a bot harness reuses one session — and diverges for a
person with three devices, who gets three allowances. Acceptable, and worth
seeing rather than inferring.

**Authenticated traffic has no per-IP limit at all.** Ten sessions from one
address get ten times 240/min between them, bounded only by the global floor.
Acquiring those sessions is itself limited — ten logins a minute from that
address — but a session lasts up to ten days (`ACC-1`), so they can be
collected slowly and spent all at once. This is the one blank that might want
filling.

**No metric has a global limit of its own.** There is no service-wide cap on
registrations, so a registration flood spread across enough addresses is
bounded only by the 1200/min that covers everything. Whether that matters
depends on how much of the 1200 a determined caller can spend on registrations
before ordinary traffic notices, which is a question for #28 rather than a
guess here.

**Registration is tightest** because a throwaway account is how every other
limit here gets worked around, and nobody legitimately registers twice in a
minute.

**Heavy auth** covers login and the password-reset pair. Each spends ~47 ms of
Argon2 whether or not the credentials are real, which is exactly what makes
them worth reaching for. Loose enough for somebody mistyping a password.

**The authenticated tier is generous on purpose.** A person playing normally
must never meet it, and a client refreshing its games list every ten seconds
is ordinary traffic. Ten seconds is six a minute; the limit is forty times
that.

**The global tier is a floor under everything else**, catching what spreads
across addresses and accounts — which the keyed tiers by construction cannot.

### Two things carry no limit at all

`/health`, because monitoring and `deploy.sh`'s own smoke test call it, and it
has to answer while everything else is refusing. A health check that fails
under load reports an outage that is not happening, and `deploy.sh` would roll
back a release that was merely busy.

The admin routes, because they are loopback-only: the only caller is the
operator at the console, and throttling them in the middle of a cleanup helps
nobody.

## Keying

**By address, from `X-Forwarded-For`** where it is present, the socket's peer
otherwise, taking the leftmost entry — Caddy appends, so the original client
is first.

**The header is Caddy's, not the caller's** — and that is stronger than it
sounds. Caddy does not trust an incoming `X-Forwarded-For`: with no
`trusted_proxies` configured it **replaces** the header with the address the
connection actually came from. So a caller cannot forge their address, cannot
spread themselves across imaginary addresses to evade a limit, and cannot lock
out a chosen victim by claiming to be them.

Verified rather than assumed, on 2026-08-09: five registrations sent through
Caddy with five different `X-Forwarded-For` values shared one bucket, and the
same five sent straight at the server were treated as five callers. The proxy
is doing the sanitising.

**The precondition is therefore narrower than it first appears, and still
real.** It is not "the header must be trustworthy" — Caddy sees to that. It is
that **nothing may reach the server except through Caddy**, which
`docker-compose.yml` enforces by giving the `server` service no `ports:`.
Adding one would let a caller supply their own header and be believed.

The alternative — ignoring the header and keying on the peer — is worse rather
than safer: the peer is the `web` container for every request on the internet,
so the first abuser locks out everyone.

**One consequence for testing**, which cost a rehearsal run to find: per-caller
separation cannot be verified from outside, because every request from one
machine is genuinely one caller. It is verified in-process instead, by
`one_callers_allowance_is_not_anothers`. A test that appears to send from two
addresses through Caddy is testing nothing, and will fail — correctly.

**By session token, not by account**, on the authenticated tier. Resolving a
token to an account needs the database and a key extractor cannot wait. They
coincide for the case that matters: a bot harness reuses one session rather
than authenticating per move, so its traffic keys to one bucket and can be
reasoned about on its own.

A person with several devices gets an allowance each, which is right for a
person and tolerable for anybody else — logging in again to buy a fresh
allowance has to pass the heavy-auth limit first, so the loop costs more than
it yields.

## Refused, not queued

`governor` replenishes one permit every period rather than clearing the bucket
on the minute. A caller that stays under the rate is never refused, and one
that exceeds it is *slowed* rather than locked out for the rest of a window —
which matters for a person who fat-fingers a password three times and would
otherwise be shut out for a minute for no reason.

The answer is `429`, which is the point: refusal is information the caller can
act on, and a queue is not.

## Tuning

Every limit and burst reads from the environment, so the numbers can be
retuned on the rehearsal host without a rebuild. The variables are in
[4.1 Configuration](../4.1-configuration.md) and declared in both compose
files.

An *empty* value falls back to the default exactly as an unset one does. That
is not fussiness: Compose passes `${VAR:-}` through as an empty string rather
than omitting it, where Caddy's `{$VAR:default}` does the opposite — and that
difference has already taken a deploy down once.

The defaults are a first guess for a 2 vCPU, 954 MB box and have not been
measured. Measuring them needs real load, which is #28.

## Known gaps

**A WebSocket is limited once, at the upgrade.** `/games/{id}/events` sits in
the authenticated tier, so opening the socket costs a permit; messages sent
over it afterwards cost nothing. A client that holds one socket open and
floods it is unlimited by anything here. Not a problem today — the socket
carries few client-to-server messages — but it is where the next limit goes,
and worth knowing before somebody discovers it.

**The limits are off under `cfg(test)`.** The in-process suite shares one
bucket, with no forwarded header and no peer address, so a test registering
six players would meet the registration limit and the binary as a whole would
meet the global one. The limits would become ambient conditions of every test
rather than the subject of any. The limiter is tested directly instead, against
a router built for the purpose — but the consequence is real: **no test
exercises the wiring in `build_router`**, only the layer it applies. A tier
attached to the wrong routes would pass CI.

**Nothing tested replenishment, or the environment parsing.** Both closed:
`a_refused_caller_recovers_after_one_period` would fail against a fixed-window
limiter, and `an_unusable_limit_falls_back_to_the_default` covers every way of
not setting a limit — including the empty string Compose passes for an unset
variable, which has already taken a deploy down once.

**The global tier is not tested in-process**, being the one tier a caller
cannot detect from their own traffic. It is covered by the load test in #28
instead, which can generate the traffic needed to reach it.

The test plan records what remains rather than quietly leaving it out.
