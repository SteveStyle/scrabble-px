//! How long the unread messages have actually been in front of somebody.
//!
//! The unread indicator used to clear the moment a message arrived while the
//! game was open — "watching the panel counts as reading it". On a phone the
//! chat panel is often scrolled off screen entirely, and a tab can be in the
//! background, so that cleared the mark for messages nobody had seen. The
//! watermark meant *arrived*, and it needs to mean *seen*.
//!
//! This is the part with logic in it, kept free of the browser so it can be
//! tested without one. It knows nothing about observers or timers: something
//! else tells it when the messages became visible, when they stopped being
//! visible, and when a new message arrived; it answers whether they have been
//! watched for long enough.

/// How long the messages must be visible before they count as read.
pub const SEEN_AFTER_MS: i64 = 10_000;

/// Accumulated watching time, across however many interruptions.
///
/// Suspending keeps what has been earned rather than discarding it: somebody
/// who looks for six seconds, switches tab, and comes back needs four more, not
/// ten. That is the whole reason this holds state instead of being a timeout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SeenClock {
    /// Watching time banked from earlier stretches.
    banked_ms: i64,
    /// When the current stretch began, if the messages are visible now.
    visible_since: Option<i64>,
}

impl SeenClock {
    /// Nothing watched yet.
    pub fn new() -> Self {
        Self::default()
    }

    /// The messages became visible. Ignored if they already were, so a repeated
    /// notification — two observers, or a re-render — cannot restart the
    /// stretch and quietly lose the time already earned.
    pub fn became_visible(&mut self, now_ms: i64) {
        if self.visible_since.is_none() {
            self.visible_since = Some(now_ms);
        }
    }

    /// The messages stopped being visible: scrolled away, covered, or the tab
    /// went to the background. Banks the current stretch.
    pub fn became_hidden(&mut self, now_ms: i64) {
        if let Some(since) = self.visible_since.take() {
            self.banked_ms += (now_ms - since).max(0);
        }
    }

    /// A new message arrived: start again from nothing.
    ///
    /// The owner chose this over letting the clock run on (2026-08-11). It is
    /// the stricter reading of "seen" — each message earns its own ten seconds
    /// — and it has a consequence worth knowing: during an exchange where
    /// messages arrive faster than that, the indicator stays lit while somebody
    /// is actively reading. Keeps watching if they are watching now, because
    /// the new message is on screen too.
    pub fn restart(&mut self, now_ms: i64) {
        self.banked_ms = 0;
        if self.visible_since.is_some() {
            self.visible_since = Some(now_ms);
        }
    }

    /// Total watching time, including the stretch in progress.
    pub fn watched_ms(&self, now_ms: i64) -> i64 {
        let running = self
            .visible_since
            .map(|since| (now_ms - since).max(0))
            .unwrap_or(0);
        self.banked_ms + running
    }

    /// Have the messages been watched for long enough to count as read?
    pub fn is_seen(&self, now_ms: i64) -> bool {
        self.watched_ms(now_ms) >= SEEN_AFTER_MS
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The plain case: ten unbroken seconds.
    #[test]
    fn ten_seconds_of_watching_counts_as_seen() {
        let mut clock = SeenClock::new();
        clock.became_visible(0);
        assert!(!clock.is_seen(9_999), "not yet, a millisecond short");
        assert!(clock.is_seen(10_000));
    }

    /// Nothing counts while the messages are not on screen.
    ///
    /// This is the case the old behaviour got wrong: a message arriving into a
    /// panel scrolled off the bottom of a phone was marked read immediately.
    #[test]
    fn time_while_hidden_does_not_count() {
        let clock = SeenClock::new();
        assert_eq!(clock.watched_ms(60_000), 0);
        assert!(!clock.is_seen(60_000));
    }

    /// Suspending banks the time rather than discarding it, and resuming
    /// carries on — six seconds then four is seen, not six then ten.
    #[test]
    fn watching_resumes_where_it_left_off() {
        let mut clock = SeenClock::new();
        clock.became_visible(0);
        clock.became_hidden(6_000);
        assert_eq!(clock.watched_ms(30_000), 6_000, "the gap must not accrue");
        assert!(!clock.is_seen(30_000));

        clock.became_visible(30_000);
        assert!(!clock.is_seen(33_999), "six banked plus not quite four");
        assert!(clock.is_seen(34_000), "six banked plus four is ten");
    }

    /// Several interruptions add up.
    #[test]
    fn many_short_looks_add_up() {
        let mut clock = SeenClock::new();
        for stretch in 0..5 {
            let start = stretch * 100_000;
            clock.became_visible(start);
            clock.became_hidden(start + 2_000);
        }
        assert_eq!(clock.watched_ms(500_000), 10_000);
        assert!(clock.is_seen(500_000));
    }

    /// A repeated "visible" must not restart the stretch in progress.
    ///
    /// Two sources report visibility — the observer and the tab's own
    /// visibility — and a re-render can fire either again. If that reset
    /// `visible_since`, a tab left open would never accumulate anything and the
    /// indicator would never clear, which reads as the feature being broken
    /// rather than as double-notification.
    #[test]
    fn being_told_it_is_visible_twice_does_not_lose_the_stretch() {
        let mut clock = SeenClock::new();
        clock.became_visible(0);
        clock.became_visible(5_000);
        clock.became_visible(9_000);
        assert!(
            clock.is_seen(10_000),
            "the stretch began at 0, not at 9,000"
        );
    }

    /// A new message starts the ten seconds again.
    #[test]
    fn a_new_message_restarts_the_count() {
        let mut clock = SeenClock::new();
        clock.became_visible(0);
        assert!(!clock.is_seen(9_000));
        clock.restart(9_000);
        assert!(!clock.is_seen(18_999), "the new message earns its own ten");
        assert!(clock.is_seen(19_000));
    }

    /// Restarting while hidden discards the banked time and does not start a
    /// stretch — the new message is not on screen either.
    #[test]
    fn a_new_message_while_hidden_starts_from_nothing() {
        let mut clock = SeenClock::new();
        clock.became_visible(0);
        clock.became_hidden(8_000);
        clock.restart(20_000);
        assert_eq!(clock.watched_ms(30_000), 0);

        clock.became_visible(30_000);
        assert!(clock.is_seen(40_000));
    }

    /// A clock going backwards must not bank negative time.
    ///
    /// `performance.now()` is monotonic, but this takes whatever it is given,
    /// and negative banked time would make the indicator clear early — the
    /// exact failure being fixed.
    #[test]
    fn time_going_backwards_never_subtracts() {
        let mut clock = SeenClock::new();
        clock.became_visible(10_000);
        clock.became_hidden(5_000);
        assert_eq!(clock.watched_ms(10_000), 0);
    }
}
