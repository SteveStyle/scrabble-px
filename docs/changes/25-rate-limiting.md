# Rate Limiting

Design note for issue #25, which absorbed #12, #13 and #14. **Built, not yet
released** — this records the shape for review before it ships, and the test
plan alongside it is [25-rate-limiting-test-plan.md](25-rate-limiting-test-plan.md).

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

## Four tiers

Applied outermost first, each answering a different question:

| Tier | Keyed by | Question | Default | Burst |
| --- | --- | --- | --- | --- |
| registration | client address | is one source manufacturing accounts | 2/min | 3 |
| heavy auth | client address | is one source burning Argon2 time | 10/min | 10 |
| authenticated | session token | is one caller monopolising the service | 240/min | 60 |
| global | nothing | is the service as a whole beyond its means | 1200/min | 200 |

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

**This trusts a header, and may only do so while the server has no port of its
own.** `docker-compose.yml` gives the `server` service no `ports:`, so Caddy is
the sole ingress and the header is Caddy's. The moment anything else can reach
the server the header is attacker-controlled, and this becomes a way to evade
the limit — or, worse, to lock out a chosen victim by forging their address.

The alternative is worse rather than safer: without the header the key is the
`web` container for every request on the internet, so the first abuser locks
out everyone. **The constraint is therefore real and belongs in the compose
file**, not merely in a comment here: adding a `ports:` line to the server
service silently converts this from a protection into a weapon.

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

**Nothing tests replenishment.** "Slowed rather than locked out" is a claim
made here and in the code and asserted nowhere; a config that locked a caller
out for a full window would pass everything.

**Nothing tests the global tier**, which is the one that cannot be checked by
a caller looking at their own traffic.

The test plan records these as gaps rather than quietly leaving them out.
