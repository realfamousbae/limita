//! Rate-limit data as the rest of Limita sees it. Port of `Limita/Models/LimitData.swift`.

use serde::{Deserialize, Serialize};

use crate::time::{seconds_between, Timestamp};

/// One rate-limit window (5-hour or 7-day). Both Codex and Claude report a percentage
/// directly, so this is modelled around `used_percent`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitWindow {
    /// 0...100, and above 100 once the limit is exceeded.
    pub used_percent: f64,
    /// When the window resets. Absent if the source did not report it.
    #[serde(default, with = "crate::time::iso_seconds_opt", skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<Timestamp>,
}

impl LimitWindow {
    pub fn new(used_percent: f64, resets_at: Option<Timestamp>) -> Self {
        Self { used_percent, resets_at }
    }

    /// A window whose reset time has passed carries a stale percentage: the CLI has not
    /// run since the reset, so its last number describes the previous window.
    pub fn is_expired(&self, now: Timestamp) -> bool {
        self.resets_at.is_some_and(|reset| reset <= now)
    }

    /// The percentage to display: an expired window has started over at zero.
    pub fn display_percent(&self, now: Timestamp) -> f64 {
        if self.is_expired(now) { 0.0 } else { self.used_percent }
    }

    /// Clamped to 0...1 for progress bars.
    pub fn display_fraction(&self, now: Timestamp) -> f64 {
        (self.display_percent(now) / 100.0).clamp(0.0, 1.0)
    }

    pub fn percent_text(&self, now: Timestamp) -> String {
        format_percent(self.display_percent(now))
    }

    /// What is left of the window, 0...100.
    pub fn remaining_percent(&self, now: Timestamp) -> f64 {
        (100.0 - self.display_percent(now)).clamp(0.0, 100.0)
    }

    /// The percentage `service` is displayed with — see `Service::shows_remaining`.
    pub fn shown_percent(&self, service: Service, now: Timestamp) -> f64 {
        if service.shows_remaining() {
            self.remaining_percent(now)
        } else {
            self.display_percent(now).clamp(0.0, 100.0)
        }
    }

    pub fn shown_text(&self, service: Service, now: Timestamp) -> String {
        format_percent(self.shown_percent(service, now))
    }

    pub fn reset_text(&self, now: Timestamp) -> Option<String> {
        let reset = self.resets_at?;
        if reset <= now {
            return Some("window reset".into());
        }
        Some(format!("resets in {}", duration_text(seconds_between(now, reset))))
    }
}

/// Whole percent, like the macOS app's `%.0f%%`.
fn format_percent(value: f64) -> String {
    format!("{value:.0}%")
}

/// "2 days 4 hours 5 min", "4 hours 5 min" or "42 min". Rounded up to the minute, so it
/// never reads "0 min" before the reset; it changes exactly on `resets_at` minus whole
/// minutes (see `view::next_tick`).
pub fn duration_text(interval: f64) -> String {
    // The epsilon keeps an exact minute boundary from rounding up to the next one.
    let total = (((interval - 0.001) / 60.0).ceil() as i64).max(1);
    let days = total / 1440;
    let hours = total % 1440 / 60;
    let minutes = total % 60;
    let count = |value: i64, one: &str, many: &str| format!("{value} {}", if value == 1 { one } else { many });
    if days > 0 {
        format!("{} {} {minutes} min", count(days, "day", "days"), count(hours, "hour", "hours"))
    } else if hours > 0 {
        format!("{} {minutes} min", count(hours, "hour", "hours"))
    } else {
        format!("{minutes} min")
    }
}

/// The longest `reset_text` a window can produce (a 7-day one), for sizing the dashboard.
pub fn longest_reset_text() -> String {
    format!("resets in {}", duration_text(7.0 * 86400.0 - 60.0))
}

/// The pair of windows a service reports, plus when we read them.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LimitSnapshot {
    pub five_hour: Option<LimitWindow>,
    pub seven_day: Option<LimitWindow>,
    pub captured_at: Timestamp,
    /// The source said outright that the plan has no 5-hour limit (Codex on a Team plan
    /// puts the weekly window where the 5-hour one goes). A merely missing `five_hour`
    /// means "unknown", never "no limit".
    pub has_no_five_hour_limit: bool,
}

impl LimitSnapshot {
    pub fn new(five_hour: Option<LimitWindow>, seven_day: Option<LimitWindow>, captured_at: Timestamp) -> Self {
        Self::with_flag(five_hour, seven_day, captured_at, false)
    }

    pub fn with_flag(
        five_hour: Option<LimitWindow>,
        seven_day: Option<LimitWindow>,
        captured_at: Timestamp,
        has_no_five_hour_limit: bool,
    ) -> Self {
        Self {
            five_hour,
            seven_day,
            captured_at,
            has_no_five_hour_limit: has_no_five_hour_limit && five_hour.is_none() && seven_day.is_some(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.five_hour.is_none() && self.seven_day.is_none()
    }

    /// The window the pill and the traffic light follow: the 5-hour one, or the weekly
    /// one only when the plan has no 5-hour limit. `None` while the 5-hour window is unknown.
    pub fn headline(&self) -> Option<(&'static str, LimitWindow)> {
        if let Some(window) = self.five_hour {
            return Some(("5h", window));
        }
        if self.has_no_five_hour_limit {
            return self.seven_day.map(|window| ("7d", window));
        }
        None
    }
}

/// Traffic-light level of a window, by usage. On a threshold the more severe level wins:
/// Claude used 70 % (Codex left 30 %) is `Warning`, used 90 % (left 10 %) is `Critical`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LimitLevel {
    Normal,
    Warning,
    Critical,
}

impl LimitLevel {
    pub fn from_used(used_percent: f64) -> Self {
        if used_percent >= 90.0 {
            Self::Critical
        } else if used_percent >= 70.0 {
            Self::Warning
        } else {
            Self::Normal
        }
    }
}

/// What we know about one service right now.
#[derive(Clone, Debug, PartialEq)]
pub enum ServiceState {
    /// No data at all. `reason` is shown to the user verbatim, so it must be actionable.
    Unavailable(String),
    /// Data we read, but old enough that it may not reflect current usage.
    Stale(LimitSnapshot),
    /// Recent data.
    Fresh(LimitSnapshot),
}

impl ServiceState {
    pub fn snapshot(&self) -> Option<&LimitSnapshot> {
        match self {
            Self::Unavailable(_) => None,
            Self::Stale(snapshot) | Self::Fresh(snapshot) => Some(snapshot),
        }
    }

    pub fn unavailable_reason(&self) -> Option<&str> {
        match self {
            Self::Unavailable(reason) => Some(reason),
            _ => None,
        }
    }

    pub fn is_stale(&self) -> bool {
        matches!(self, Self::Stale(_))
    }

    /// Traffic-light level of the headline window; `None` without data.
    pub fn level(&self, now: Timestamp) -> Option<LimitLevel> {
        self.snapshot()?
            .headline()
            .map(|(_, window)| LimitLevel::from_used(window.display_percent(now)))
    }

    /// Builds a state from a snapshot, deciding freshness by age.
    pub fn from_snapshot(snapshot: LimitSnapshot, stale_after: f64, now: Timestamp) -> Self {
        if seconds_between(snapshot.captured_at, now) > stale_after {
            Self::Stale(snapshot)
        } else {
            Self::Fresh(snapshot)
        }
    }
}

/// Declaration order is display order: Claude first, then Codex, everywhere.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Service {
    Claude,
    Codex,
}

impl Service {
    pub const ALL: [Service; 2] = [Service::Claude, Service::Codex];

    pub fn id(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|service| service.id() == id)
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Claude => "Claude",
            Self::Codex => "Codex",
        }
    }

    /// Name of the product the user connects, as shown in the menu.
    pub fn product_name(self) -> &'static str {
        match self {
            Self::Claude => "Claude Code",
            Self::Codex => "Codex",
        }
    }

    /// Codex is shown as remaining quota, Claude as used quota — by user preference.
    pub fn shows_remaining(self) -> bool {
        self == Self::Codex
    }

    /// Short word for what the percentage means.
    pub fn percent_meaning(self) -> &'static str {
        if self.shows_remaining() { "left" } else { "used" }
    }
}

/// Balances and extras beyond the rate-limit windows. Only the network sources report
/// these; a field is `None` when the service did not report it, and the UI hides it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AccountDetails {
    /// Codex: rate-limit reset credits available to redeem.
    pub limit_resets: Option<i64>,
    /// Codex: credit balance, in credits.
    pub codex_credits: Option<f64>,
    pub codex_credits_unlimited: bool,
    /// Claude: credits that cover usage beyond the plan limits.
    pub claude_usage_credits: Option<UsageCredits>,
    /// Claude: cloud session credits.
    pub cloud_credits: Option<Allowance>,
}

impl AccountDetails {
    /// Codex sells credits at $1 = 25 credits (1 credit = $0.04).
    pub const CODEX_CREDITS_PER_DOLLAR: f64 = 25.0;
}

/// A prepaid dollar allowance, e.g. Claude's cloud session credits.
#[derive(Clone, Debug, PartialEq)]
pub struct Allowance {
    pub remaining: f64,
    pub limit: Option<f64>,
    pub expires_at: Option<Timestamp>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum UsageCredits {
    Off,
    Balance { dollars: f64 },
    Spent { dollars: f64, limit: Option<f64> },
}

/// What a network source returns: the windows plus any account details.
#[derive(Clone, Debug, PartialEq)]
pub struct LiveReading {
    pub snapshot: LimitSnapshot,
    pub details: AccountDetails,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::from_unix;

    fn at(seconds: f64) -> Timestamp {
        from_unix(seconds.max(0.001)).unwrap()
    }

    #[test]
    fn codex_shows_remaining_and_claude_shows_used() {
        let now = at(1.0);
        let window = LimitWindow::new(3.0, Some(at(100.0)));
        assert_eq!(window.shown_text(Service::Codex, now), "97%");
        assert_eq!(window.shown_text(Service::Claude, now), "3%");
        assert_eq!(LimitWindow::new(120.0, None).shown_percent(Service::Codex, now), 0.0, "over the limit");
        assert_eq!(window.shown_text(Service::Codex, at(200.0)), "100%", "a reset window is full again");
    }

    #[test]
    fn expired_window_displays_zero() {
        let window = LimitWindow::new(80.0, Some(at(1000.0)));
        assert_eq!(window.display_percent(at(999.0)), 80.0);
        assert_eq!(window.display_percent(at(1000.0)), 0.0);
        assert_eq!(window.reset_text(at(2000.0)).as_deref(), Some("window reset"));
    }

    #[test]
    fn level_thresholds_take_the_more_severe_colour_on_the_boundary() {
        let cases = [
            (0.0, LimitLevel::Normal),
            (69.9, LimitLevel::Normal),
            (70.0, LimitLevel::Warning),
            (89.9, LimitLevel::Warning),
            (90.0, LimitLevel::Critical),
            (100.0, LimitLevel::Critical),
        ];
        for (used, level) in cases {
            assert_eq!(LimitLevel::from_used(used), level, "used {used} %");
        }
    }

    #[test]
    fn codex_level_follows_the_same_thresholds_as_left() {
        let now = at(1.0);
        let level = |left: f64| {
            let window = LimitWindow::new(100.0 - left, None);
            ServiceState::Fresh(LimitSnapshot::new(Some(window), None, now)).level(now)
        };
        assert_eq!(level(100.0), Some(LimitLevel::Normal));
        assert_eq!(level(30.1), Some(LimitLevel::Normal));
        assert_eq!(level(30.0), Some(LimitLevel::Warning));
        assert_eq!(level(10.1), Some(LimitLevel::Warning));
        assert_eq!(level(10.0), Some(LimitLevel::Critical));
        assert_eq!(level(0.0), Some(LimitLevel::Critical));
    }

    #[test]
    fn level_follows_five_hour_window_only_and_stale_keeps_it() {
        let now = at(1.0);
        let snapshot = LimitSnapshot::new(
            Some(LimitWindow::new(20.0, None)),
            Some(LimitWindow::new(95.0, None)),
            now,
        );
        assert_eq!(ServiceState::Fresh(snapshot).level(now), Some(LimitLevel::Normal), "the weekly window does not count");
        assert_eq!(ServiceState::Stale(snapshot).level(now), Some(LimitLevel::Normal));
        assert_eq!(ServiceState::Unavailable("x".into()).level(now), None);
    }

    #[test]
    fn no_five_hour_flag_needs_a_weekly_window_and_no_five_hour_one() {
        let now = at(1.0);
        let both = LimitSnapshot::with_flag(
            Some(LimitWindow::new(1.0, None)),
            Some(LimitWindow::new(2.0, None)),
            now,
            true,
        );
        assert!(!both.has_no_five_hour_limit);
        assert!(!LimitSnapshot::with_flag(None, None, now, true).has_no_five_hour_limit);
        let weekly = LimitSnapshot::with_flag(None, Some(LimitWindow::new(92.0, None)), now, true);
        assert_eq!(weekly.headline().map(|h| h.0), Some("7d"));
        assert_eq!(ServiceState::Fresh(weekly).level(now), Some(LimitLevel::Critical), "the dot follows the weekly window");
    }

    #[test]
    fn reset_countdown_format() {
        let minute = 60.0;
        let hour = 3600.0;
        let day = 86400.0;
        let cases = [
            (1.0, "1 min"),
            (59.0, "1 min"),
            (minute, "1 min"),
            (minute + 1.0, "2 min"),
            (59.0 * minute, "59 min"),
            (59.0 * minute + 1.0, "1 hour 0 min"),
            (hour, "1 hour 0 min"),
            (hour + 42.0 * minute, "1 hour 42 min"),
            (4.0 * hour + 59.0 * minute + 59.0, "5 hours 0 min"),
            (23.0 * hour + 59.0 * minute, "23 hours 59 min"),
            (day, "1 day 0 hours 0 min"),
            (day + 1.0, "1 day 0 hours 1 min"),
            (4.0 * day + 2.0 * hour + 5.0 * minute, "4 days 2 hours 5 min"),
            (7.0 * day - minute, "6 days 23 hours 59 min"),
        ];
        for (interval, text) in cases {
            assert_eq!(duration_text(interval), text, "{interval} s");
        }
        let now = at(0.0);
        let window = LimitWindow::new(10.0, Some(at(90.0 * 60.0)));
        assert_eq!(window.reset_text(now).as_deref(), Some("resets in 1 hour 30 min"));
        assert_eq!(window.reset_text(at(90.0 * 60.0)).as_deref(), Some("window reset"));
        assert_eq!(longest_reset_text(), "resets in 6 days 23 hours 59 min");
    }
}
