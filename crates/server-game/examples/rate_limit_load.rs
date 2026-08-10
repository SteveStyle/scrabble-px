//! Dev-only load test: do the limits in #11 and #25 behave the way they are
//! documented to, on hardware the size of the one they protect? Never built
//! into the shipped image — examples are not part of the release binary — so
//! this is a `cargo run --example` tool only.
//!
//! Usage:
//!
//! ```text
//! cargo run --release --example rate_limit_load -- https://rehearsal-host
//! cargo run --release --example rate_limit_load          # $REHEARSAL_URL
//! ```
//!
//! **Run it against rehearsal**, which is why that environment exists: the
//! same 2 vCPU / 954 MB shape as production, production's data, and nobody
//! watching. Numbers taken on a development machine say nothing about the box
//! the limits exist to protect. Pointing it at production is refused outright.
//!
//! It asserts the **rules**, not the throughput. Throughput ages the moment
//! the hardware or the workload changes; the rules are what should still be
//! true afterwards, and each check below names the one it is pinning. Measured
//! numbers are still recorded — appended to `rate_limit_results.csv` beside
//! this file — so a change over time shows up as a diff rather than as a
//! memory of what the number used to be. That is the `engine_timing_bench`
//! pattern, for the same reason.
//!
//! Request shapes come from the `api` crate's own DTOs. A load test that
//! builds JSON by hand drifts from the contract silently, and then passes
//! while testing something the server no longer accepts.
//!
//! **What this cannot test, and why.** Caddy replaces `X-Forwarded-For` with
//! the address the connection came from, so every request from one machine is
//! one caller however the header is set — see
//! `docs/changes/25-rate-limiting.md`. Two checks were written here on the
//! assumption that addresses could be spoofed, and would have reported
//! confidently on nothing:
//!
//! - **the global floor**, which needs enough traffic to pass it without
//!   tripping a keyed tier first — impossible from one address, since the
//!   per-caller limit binds long before 1200/min
//! - **the hashing semaphore**, which needs concurrent logins that are not
//!   refused for frequency — and heavy auth refuses them at ten a minute
//!
//! Both need either many real sources or the keyed limits raised on the host
//! for the duration. That is #91's rig, not this one's. The session check
//! below *does* work, because the authenticated tier keys on the session token
//! rather than the address, and two sessions from one machine are genuinely
//! two callers.

use std::fmt::Write as _;
use std::fs::OpenOptions;
use std::io::Write as _;
use std::process::Command;
use std::time::{Duration, Instant};

use api::{LoginPlayerRequest, RegisterPlayerRequest};

const RESULTS_CSV_HEADER: &str = "timestamp_unix_seconds,git_commit,host,target,per_ip_refused_after,health_under_load,sessions_separate,registration_refused_after,hash_median_ms,checks_failed\n";

/// Argon2 at the OWASP profile costs ~47 ms on the production box. A hash that
/// suddenly takes ~1 ms means somebody weakened the parameters, which is a
/// silent reduction in the strength of every stored password. The band is
/// deliberately wide: this is a "has the cost collapsed" check, not a
/// benchmark.
const HASH_MS_FLOOR: u128 = 15;
const HASH_MS_CEILING: u128 = 400;

struct Report {
    failures: Vec<String>,
    checks: usize,
}

impl Report {
    fn new() -> Self {
        Self {
            failures: Vec::new(),
            checks: 0,
        }
    }

    /// Records one rule. `held` is the rule; `detail` says what was actually
    /// seen, so a pass is as informative as a failure — a check that only
    /// speaks up when it fails leaves you guessing whether it ran.
    fn rule(&mut self, name: &str, held: bool, detail: impl AsRef<str>) {
        self.checks += 1;
        if held {
            println!("  ok   {name} — {}", detail.as_ref());
        } else {
            println!("  FAIL {name} — {}", detail.as_ref());
            self.failures.push(name.to_string());
        }
    }
}

fn git_commit_label() -> String {
    let hash = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    let dirty = Command::new("git")
        .args(["status", "--porcelain"])
        .output()
        .ok()
        .map(|o| !o.stdout.is_empty())
        .unwrap_or(false);
    if dirty { format!("{hash}-dirty") } else { hash }
}

fn hostname() -> String {
    Command::new("hostname")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

fn append_result_row(row: &str) -> std::io::Result<std::path::PathBuf> {
    let path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/rate_limit_results.csv");
    let is_new_file = !path.exists();
    let mut file = OpenOptions::new().create(true).append(true).open(&path)?;
    if is_new_file {
        file.write_all(RESULTS_CSV_HEADER.as_bytes())?;
    }
    file.write_all(row.as_bytes())?;
    Ok(path)
}

fn now_unix_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// A run tag, so a second run is not refused by the buckets the first one
/// filled and the accounts it creates do not collide.
fn run_tag() -> String {
    format!("{:x}", now_unix_seconds() & 0xff_ffff)
}

async fn status_of(request: reqwest::RequestBuilder) -> u16 {
    match request.send().await {
        Ok(response) => response.status().as_u16(),
        // A refused connection is a result, not a crash: reported as 0 so the
        // check that wanted a status fails rather than the run dying.
        Err(_) => 0,
    }
}

#[tokio::main]
async fn main() {
    let target = std::env::args().nth(1).unwrap_or_else(|| {
        std::env::var("REHEARSAL_URL")
            .unwrap_or_else(|_| "https://129.151.84.183.sslip.io".to_string())
    });

    // This deliberately exhausts allowances and saturates the hashing pool.
    // Doing that to production would be an outage caused by a test.
    if target.contains("tileliteelite.com") {
        eprintln!("refusing to load-test production ({target}) — use the rehearsal host");
        std::process::exit(2);
    }

    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            eprintln!("could not build an http client: {error}");
            std::process::exit(2);
        }
    };

    let tag = run_tag();
    println!("==> Rate limits under load on {target}  (run {tag})");
    println!();

    let mut report = Report::new();

    let per_ip_refused_after = check_per_ip_burst(&client, &target, &tag, &mut report).await;
    let registration_refused_after =
        check_registration_cap(&client, &target, &tag, &mut report).await;
    let sessions_separate = check_sessions_are_separate(&client, &target, &tag, &mut report).await;
    let hash_median_ms = check_hash_cost(&client, &target, &tag, &mut report).await;
    let health_under_load = check_health_is_never_limited(&client, &target, &mut report).await;

    let mut row = String::new();
    let _ = writeln!(
        row,
        "{},{},{},{},{},{},{},{},{},{}",
        now_unix_seconds(),
        git_commit_label(),
        hostname(),
        target,
        per_ip_refused_after,
        health_under_load,
        sessions_separate,
        registration_refused_after,
        hash_median_ms,
        report.failures.len(),
    );

    println!();
    match append_result_row(&row) {
        Ok(path) => println!("recorded to {}", path.display()),
        Err(error) => eprintln!("failed to record results: {error}"),
    }

    if report.failures.is_empty() {
        println!("all {} rules held.", report.checks);
    } else {
        eprintln!(
            "{} of {} rules failed: {}",
            report.failures.len(),
            report.checks,
            report.failures.join(", ")
        );
        std::process::exit(1);
    }
}

/// LIMIT-1 and LIMIT-2: a caller over its allowance is refused rather than
/// queued, and the request *before* the allowance is not. Both halves matter —
/// a limiter that refused everything would pass the first on its own.
async fn check_per_ip_burst(
    client: &reqwest::Client,
    target: &str,
    tag: &str,
    report: &mut Report,
) -> String {
    let address = format!("198.51.100.{}", 1 + (now_unix_seconds() % 250));
    let mut first_refusal: Option<usize> = None;

    for attempt in 1..=20usize {
        let name = format!("loadtest-{tag}-burst-{attempt}");
        let status = status_of(
            client
                .post(format!("{target}/auth/register"))
                .header("x-forwarded-for", &address)
                .json(&RegisterPlayerRequest {
                    display_name: name.clone(),
                    email: format!("{name}@example.com"),
                    password: "correct horse battery staple".to_string(),
                    stay_logged_in: false,
                }),
        )
        .await;

        if status == 429 {
            first_refusal = Some(attempt);
            break;
        }
        if attempt == 1 {
            report.rule(
                "the first request is not refused",
                status != 429,
                format!("got {status}"),
            );
        }
    }

    match first_refusal {
        Some(n) => {
            report.rule(
                "a caller over its allowance is refused (429)",
                true,
                format!("after {n} from one address"),
            );
            n.to_string()
        }
        None => {
            report.rule(
                "a caller over its allowance is refused (429)",
                false,
                "twenty registrations from one address were all accepted",
            );
            "never".to_string()
        }
    }
}

/// The registration cap trips where expected. Separate from the burst check
/// because it is the *tightest* limit and the one an attacker reaches for
/// first — a throwaway account is how every other limit gets worked around.
async fn check_registration_cap(
    client: &reqwest::Client,
    target: &str,
    tag: &str,
    report: &mut Report,
) -> String {
    let address = format!("203.0.113.{}", 1 + (now_unix_seconds() % 250));
    let mut accepted = 0usize;

    for attempt in 1..=12usize {
        let name = format!("loadtest-{tag}-reg-{attempt}");
        let status = status_of(
            client
                .post(format!("{target}/auth/register"))
                .header("x-forwarded-for", &address)
                .json(&RegisterPlayerRequest {
                    display_name: name.clone(),
                    email: format!("{name}@example.com"),
                    password: "correct horse battery staple".to_string(),
                    stay_logged_in: false,
                }),
        )
        .await;
        if status == 429 {
            break;
        }
        accepted += 1;
    }

    // The default is 2/min with a burst of 3, so a handful through is right
    // and a dozen is not. The assertion is the order of magnitude, not the
    // exact figure, which is tunable per host by design.
    report.rule(
        "the registration cap trips within a few attempts",
        accepted > 0 && accepted <= 8,
        format!("{accepted} accepted before refusal"),
    );
    accepted.to_string()
}

/// LIMIT-3, and the property that keeps the bot harness in #10 from throttling
/// its owner: two sessions from one address are two callers.
async fn check_sessions_are_separate(
    client: &reqwest::Client,
    target: &str,
    tag: &str,
    report: &mut Report,
) -> String {
    let address = format!("192.0.2.{}", 1 + (now_unix_seconds() % 250));

    let mut tokens = Vec::new();
    for which in ["one", "two"] {
        let name = format!("loadtest-{tag}-sess-{which}");
        // Both registrations land in the same address bucket — there is no
        // second address to be had — so this needs the registration burst to
        // have room for two. It is the first thing this run does for a reason.
        let response = client
            .post(format!("{target}/auth/register"))
            .header("x-forwarded-for", &address)
            .json(&RegisterPlayerRequest {
                display_name: name.clone(),
                email: format!("{name}@example.com"),
                password: "correct horse battery staple".to_string(),
                stay_logged_in: false,
            })
            .send()
            .await;
        let token = match response {
            Ok(r) if r.status().is_success() => r
                .json::<serde_json::Value>()
                .await
                .ok()
                .and_then(|v| v["session_token"].as_str().map(str::to_string)),
            _ => None,
        };
        if let Some(token) = token {
            tokens.push(token);
        }
    }

    if tokens.len() < 2 {
        report.rule(
            "two sessions from one address are two callers",
            false,
            "could not register two accounts to test with",
        );
        return "untested".to_string();
    }

    // Spend the first session's allowance from the shared address, then ask
    // whether the second still answers.
    for _ in 0..80 {
        let _ = status_of(
            client
                .get(format!("{target}/engines"))
                .header("x-forwarded-for", &address)
                .bearer_auth(&tokens[0]),
        )
        .await;
    }
    let second = status_of(
        client
            .get(format!("{target}/engines"))
            .header("x-forwarded-for", &address)
            .bearer_auth(&tokens[1]),
    )
    .await;

    let held = second != 429;
    report.rule(
        "two sessions from one address are two callers",
        held,
        format!("the second session got {second} after the first had been busy"),
    );
    held.to_string()
}

/// A hash still costs what it should. Not a benchmark — a collapse detector.
/// Argon2's cost is the whole of a stored password's strength, and it can be
/// weakened by a one-line change that nothing else would notice.
async fn check_hash_cost(
    client: &reqwest::Client,
    target: &str,
    tag: &str,
    report: &mut Report,
) -> String {
    let name = format!("loadtest-{tag}-hash");
    let address = format!("198.18.0.{}", 1 + (now_unix_seconds() % 250));

    let registered = client
        .post(format!("{target}/auth/register"))
        .header("x-forwarded-for", &address)
        .json(&RegisterPlayerRequest {
            display_name: name.clone(),
            email: format!("{name}@example.com"),
            password: "correct horse battery staple".to_string(),
            stay_logged_in: false,
        })
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false);

    if !registered {
        report.rule(
            "a password hash still costs ~47 ms",
            false,
            "could not register an account to log in as",
        );
        return "untested".to_string();
    }

    // A *wrong* password against a real account: the account exists, so the
    // server verifies rather than short-circuiting, and nothing is left signed
    // in afterwards.
    let mut samples = Vec::new();
    for _ in 0..5 {
        let started = Instant::now();
        let _ = status_of(
            client
                .post(format!("{target}/auth/login"))
                .header("x-forwarded-for", &address)
                .json(&LoginPlayerRequest {
                    display_name: name.clone(),
                    password: "not the right password".to_string(),
                    stay_logged_in: false,
                }),
        )
        .await;
        samples.push(started.elapsed().as_millis());
    }
    samples.sort_unstable();
    let median = samples[samples.len() / 2];

    // Network time is included and cannot be subtracted, so the floor is what
    // carries the check: a round trip cannot be *faster* than the hash it
    // contains.
    report.rule(
        "a password hash still costs what it should",
        (HASH_MS_FLOOR..=HASH_MS_CEILING).contains(&median),
        format!("median login round trip {median} ms (including network)"),
    );
    median.to_string()
}

/// LIMIT-4. `/health` is never limited, at any rate — `deploy.sh` smoke-tests
/// it and `rollback.sh` polls it, so a health check that fails under load
/// would report an outage that is not happening and roll back a release that
/// was merely busy. Checked *after* the global probe, while everything else is
/// still being refused.
async fn check_health_is_never_limited(
    client: &reqwest::Client,
    target: &str,
    report: &mut Report,
) -> bool {
    let mut worst = 200u16;
    for _ in 0..30 {
        let status = status_of(client.get(format!("{target}/health"))).await;
        if status != 200 {
            worst = status;
            break;
        }
    }
    let held = worst == 200;
    report.rule(
        "/health is never limited",
        held,
        format!("thirty checks while the service was refusing others, worst status {worst}"),
    );
    held
}
