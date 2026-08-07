//! Rate limiting: how often a caller may ask.
//!
//! Distinct from the concurrency bounds already in place. A semaphore limits
//! how much expensive work runs *at once*, which is what stops the server
//! falling over; nothing yet limits how *often* anyone asks, so a caller can
//! queue without limit — memory stays bounded at four hashes while the queue
//! does not, and everybody else waits behind it.
//!
//! Four layers, applied outermost first, each answering a different question:
//!
//! | layer | key | question |
//! | --- | --- | --- |
//! | registration | client address | is one source manufacturing accounts |
//! | heavy auth | client address | is one source burning Argon2 time |
//! | authenticated | session token | is one caller monopolising the service |
//! | global | none | is the service as a whole beyond its means |
//!
//! `/health` carries none of them. Monitoring and `deploy.sh`'s own smoke test
//! call it, and it has to answer while everything else is refusing — a health
//! check that fails under load reports an outage that is not happening, and
//! `deploy.sh` would roll back a release that was merely busy.
//!
//! This is not prevention. Registration is open, so a determined caller can
//! spread across addresses and accounts. It buys a cost per attempt and a
//! decent error instead of a growing queue; bad behaviour is dealt with by
//! stopping the account behind it.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use axum::extract::ConnectInfo;
use axum::http::Request;
use tower_governor::governor::GovernorConfigBuilder;
use tower_governor::key_extractor::KeyExtractor;
use tower_governor::{GovernorError, GovernorLayer};

use super::AppState;
use axum::Router;

/// Requests a minute, read from the environment so the numbers can be retuned
/// on the rehearsal host without a rebuild. The defaults are a first guess for
/// a 2 vCPU, 954 MB box.
///
/// An *empty* value falls back to the default as an unset one does, which
/// matters because Compose passes `${VAR:-}` through as an empty string rather
/// than omitting it. Caddy's `{$VAR:default}` does the opposite and took a
/// deploy down over it; the parse here fails on an empty string, so both cases
/// land on the default.
fn limit_from_env(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|raw| raw.parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

/// The burst allowed on top of the rate, tunable for the same reason: it is
/// what decides whether an ordinary caller ever meets the limit at all. A
/// rate without a burst refuses the second of two clicks.
fn burst_from_env(name: &str, default: u32) -> u32 {
    std::env::var(name)
        .ok()
        .and_then(|raw| raw.parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

/// The caller's address, taken from `X-Forwarded-For` when it is there and
/// the socket's peer otherwise.
///
/// **This trusts a header, and may only do so while the server has no port of
/// its own.** `docker-compose.yml` gives the `server` service no `ports:`, so
/// Caddy is the sole ingress and the header is Caddy's. The moment anything
/// else can reach the server, the header is attacker-controlled and this
/// becomes a way to evade the limit — or, worse, to lock out a chosen victim
/// by forging their address.
///
/// Without it the key would be the `web` container for every request on the
/// internet, which is worse than no limit at all: the first abuser locks out
/// everyone.
#[derive(Clone)]
pub struct ClientAddress;

impl KeyExtractor for ClientAddress {
    type Key = IpAddr;

    fn extract<T>(&self, request: &Request<T>) -> Result<Self::Key, GovernorError> {
        if let Some(forwarded) = request
            .headers()
            .get("x-forwarded-for")
            .and_then(|value| value.to_str().ok())
            // Left-most is the original client; Caddy appends, so anything
            // after the first entry is a proxy in the chain.
            .and_then(|value| value.split(',').next())
            .map(str::trim)
            .and_then(|value| value.parse::<IpAddr>().ok())
        {
            return Ok(forwarded);
        }

        Ok(request
            .extensions()
            .get::<ConnectInfo<SocketAddr>>()
            .map(|ConnectInfo(address)| address.ip())
            // A request with neither header nor peer address is an in-process
            // test. Give them all one bucket rather than refusing: the tests
            // that care set one of the two.
            .unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED)))
    }
}

/// The session token, for callers who have one.
///
/// Per session rather than per account, because resolving a token to an
/// account needs the database and a key extractor cannot wait. In practice
/// they coincide for the case that matters: a bot harness reuses one session
/// rather than authenticating per move, so its traffic keys to one bucket and
/// can be reasoned about on its own.
///
/// A caller with several devices gets an allowance each, which is the right
/// answer for a person and a tolerable one for anybody else — logging in
/// again to buy a fresh allowance has to pass the heavy-auth limit first, so
/// the loop costs more than it yields.
///
/// Falls back to the address, so an unauthenticated caller on these routes is
/// still keyed to something.
#[derive(Clone)]
pub struct SessionOrAddress;

impl KeyExtractor for SessionOrAddress {
    type Key = String;

    fn extract<T>(&self, request: &Request<T>) -> Result<Self::Key, GovernorError> {
        if let Some(token) = request
            .headers()
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "))
            .map(str::trim)
            .filter(|token| !token.is_empty())
        {
            return Ok(format!("session:{token}"));
        }
        Ok(format!("address:{:?}", ClientAddress.extract(request)?))
    }
}

/// Every seat at once: no key, so one bucket for the whole service.
#[derive(Clone)]
pub struct Everything;

impl KeyExtractor for Everything {
    type Key = ();

    fn extract<T>(&self, _request: &Request<T>) -> Result<Self::Key, GovernorError> {
        Ok(())
    }
}

/// Applies a limit of `per_minute` requests a minute, with a burst of `burst`
/// on top.
///
/// `governor` replenishes one permit every period rather than clearing the
/// bucket on the minute, so a caller that stays under the rate is never
/// refused and one that exceeds it is slowed rather than locked out for the
/// rest of a window.
///
/// The layer is applied here rather than returned because its type names a
/// middleware `tower_governor` does not export, and inference sidesteps that
/// without a dependency on `governor` for one type name.
fn apply<K>(router: Router<AppState>, key: K, per_minute: u64, burst: u32) -> Router<AppState>
where
    K: KeyExtractor + Send + Sync + 'static,
    K::Key: Send + Sync,
{
    // Off under `cfg(test)`. The in-process suite shares one bucket — no
    // forwarded header, no peer address — so a test registering six players
    // would meet the registration limit, and the whole binary would meet the
    // global one. The limits are then ambient conditions of every test rather
    // than the subject of any, which is how a suite starts failing for
    // reasons unrelated to what it asserts.
    //
    // The limiter is tested directly instead, below, against a router built
    // for the purpose with the numbers written down in the test.
    if cfg!(test) {
        return router;
    }

    let config = GovernorConfigBuilder::default()
        .period(std::time::Duration::from_millis(60_000 / per_minute.max(1)))
        .burst_size(burst)
        .key_extractor(key)
        .finish()
        .expect("a positive period and burst make a valid governor config");
    router.layer(GovernorLayer::new(std::sync::Arc::new(config)))
}

/// Creating accounts, keyed by address. The tightest of the four: a throwaway
/// account is how every other limit here gets worked around, and nobody
/// legitimately registers twice in a minute.
pub fn registration(router: Router<AppState>) -> Router<AppState> {
    apply(
        router,
        ClientAddress,
        limit_from_env("TILE_LITE_ELITE_LIMIT_REGISTER_PER_MIN", 2),
        burst_from_env("TILE_LITE_ELITE_LIMIT_REGISTER_BURST", 3),
    )
}

/// Logging in, and the password-reset pair. Each spends ~47 ms of Argon2 on a
/// 2 vCPU box, so the cost is real whether or not the credentials are. Loose
/// enough for somebody mistyping a password, tight enough that guessing is
/// not worth attempting from one address.
pub fn heavy_auth(router: Router<AppState>) -> Router<AppState> {
    apply(
        router,
        ClientAddress,
        limit_from_env("TILE_LITE_ELITE_LIMIT_AUTH_PER_MIN", 10),
        burst_from_env("TILE_LITE_ELITE_LIMIT_AUTH_BURST", 10),
    )
}

/// Everything a signed-in caller does. Generous, because a person playing
/// normally must never meet it and a client refreshing its games list every
/// ten seconds is ordinary traffic.
pub fn authenticated(router: Router<AppState>) -> Router<AppState> {
    apply(
        router,
        SessionOrAddress,
        limit_from_env("TILE_LITE_ELITE_LIMIT_SESSION_PER_MIN", 240),
        burst_from_env("TILE_LITE_ELITE_LIMIT_SESSION_BURST", 60),
    )
}

/// A floor under the service as a whole, after the keyed limits have had
/// their say. Catches what spreads across addresses and accounts, which the
/// others by construction cannot.
pub fn global(router: Router<AppState>) -> Router<AppState> {
    apply(
        router,
        Everything,
        limit_from_env("TILE_LITE_ELITE_LIMIT_GLOBAL_PER_MIN", 1_200),
        burst_from_env("TILE_LITE_ELITE_LIMIT_GLOBAL_BURST", 200),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use axum::routing::get;
    use tower::util::ServiceExt;

    fn forwarded(address: &str) -> Request<Body> {
        Request::builder()
            .uri("/")
            .header("x-forwarded-for", address)
            .body(Body::empty())
            .expect("request should build")
    }

    /// The key is the caller Caddy reports, not the proxy that relayed it —
    /// otherwise every request on the internet shares one bucket and the
    /// first abuser locks out everyone.
    #[test]
    fn the_key_is_the_forwarded_client_not_the_proxy() {
        let key = ClientAddress
            .extract(&forwarded("203.0.113.7"))
            .expect("a forwarded address should extract");
        assert_eq!(key.to_string(), "203.0.113.7");
    }

    /// Caddy appends, so a request that has crossed two proxies lists the
    /// original client first.
    #[test]
    fn the_leftmost_forwarded_address_wins() {
        let key = ClientAddress
            .extract(&forwarded("203.0.113.7, 198.51.100.2"))
            .expect("a chain should extract");
        assert_eq!(key.to_string(), "203.0.113.7");
    }

    /// Two people behind one address share a bucket; two sessions do not.
    /// That is the whole reason the authenticated tier keys on the session —
    /// a bot harness and its owner are one address and two callers.
    #[test]
    fn sessions_are_keyed_apart_even_from_one_address() {
        let with_token = |token: &str| {
            Request::builder()
                .uri("/")
                .header("x-forwarded-for", "203.0.113.7")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .expect("request should build")
        };
        let one = SessionOrAddress
            .extract(&with_token("aaa"))
            .expect("a token should extract");
        let two = SessionOrAddress
            .extract(&with_token("bbb"))
            .expect("a token should extract");
        assert_ne!(one, two, "two sessions are two callers");

        let anonymous = SessionOrAddress
            .extract(&forwarded("203.0.113.7"))
            .expect("an address should extract");
        assert_ne!(
            anonymous, one,
            "and somebody with no session is a third, not folded in with them"
        );
    }

    /// A caller over its allowance is refused rather than queued, which is the
    /// point: the queue is what the concurrency bounds cannot protect.
    #[tokio::test]
    async fn a_caller_over_the_allowance_is_refused() {
        let config = GovernorConfigBuilder::default()
            .period(std::time::Duration::from_secs(60))
            .burst_size(2)
            .key_extractor(ClientAddress)
            .finish()
            .expect("a valid config");
        let app = Router::new()
            .route("/", get(|| async { "ok" }))
            .layer(GovernorLayer::new(std::sync::Arc::new(config)));

        let mut statuses = Vec::new();
        for _ in 0..4 {
            let response = app
                .clone()
                .oneshot(forwarded("203.0.113.7"))
                .await
                .expect("the router should answer");
            statuses.push(response.status());
        }

        assert_eq!(
            statuses[0],
            StatusCode::OK,
            "the first request is within the burst"
        );
        assert_eq!(statuses[1], StatusCode::OK, "and so is the second");
        assert_eq!(
            statuses[3],
            StatusCode::TOO_MANY_REQUESTS,
            "the fourth is over it, and is told so rather than made to wait: {statuses:?}"
        );
    }

    /// One caller's allowance is their own — a busy neighbour must not be
    /// able to lock somebody else out.
    #[tokio::test]
    async fn one_callers_allowance_is_not_anothers() {
        let config = GovernorConfigBuilder::default()
            .period(std::time::Duration::from_secs(60))
            .burst_size(1)
            .key_extractor(ClientAddress)
            .finish()
            .expect("a valid config");
        let app = Router::new()
            .route("/", get(|| async { "ok" }))
            .layer(GovernorLayer::new(std::sync::Arc::new(config)));

        for _ in 0..3 {
            let _ = app.clone().oneshot(forwarded("203.0.113.7")).await;
        }
        let other = app
            .clone()
            .oneshot(forwarded("198.51.100.9"))
            .await
            .expect("the router should answer");
        assert_eq!(
            other.status(),
            StatusCode::OK,
            "a different address starts with its own allowance"
        );
    }
}
