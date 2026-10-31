//! What the tray, the pill and the dashboard show, computed for a given `now`. The
//! webview only renders this; all wording and thresholds live here, where they are
//! tested. Port of the logic in `ExpandedView.swift` and `MiniPillView.swift`.

use serde::Serialize;

use crate::model::{
    duration_text, longest_reset_text, AccountDetails, LimitLevel, LimitSnapshot, LimitWindow, Service, ServiceState, UsageCredits,
};
use crate::prime_time::PrimeTimeNotice;
use crate::store::Snapshot;
use crate::time::{relative_text, seconds_between, Timestamp};

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PanelView {
    pub services: Vec<ServiceView>,
    /// Shown when no service is connected.
    pub connect: Vec<ConnectOption>,
    pub is_refreshing: bool,
    pub pill: Vec<PillItem>,
    /// Sizes both meters to the longest countdown, so it always fits on one line.
    pub longest_reset_text: String,
    /// The header badge while an enabled service is in its peak hours.
    pub prime_time: Option<PrimeTimeNotice>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceView {
    pub id: Service,
    pub name: String,
    /// Traffic light of the headline window; `None` is grey.
    pub level: Option<LimitLevel>,
    pub stale: bool,
    /// How fresh the data is: "LIVE DATA", "STALE DATA" or "NO DATA". Shown on the
    /// right of the name; the meter titles already say "used" or "left".
    pub status: String,
    /// Outcome of connecting, shown instead of the meters until dismissed.
    pub setup_message: Option<String>,
    pub meters: Vec<MeterView>,
    /// Claude's credits as meters, in rows after the limits.
    pub credits: Vec<MeterView>,
    pub details: Vec<DetailRow>,
    /// The newest limit reset, under the details; absent when there is none to show.
    pub reset: Option<ResetLine>,
    /// "UPDATED 2 MIN AGO"; absent without data.
    pub updated: Option<String>,
    /// Why the last live update failed, shown under the meters.
    pub error: Option<String>,
    /// Shown instead of the meters when there is no data at all.
    pub message: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MeterView {
    pub title: String,
    /// "97%", "—" or "∞".
    pub value: String,
    /// Dollars beside the value, e.g. "$163.05 OF $250.00".
    pub amount: Option<String>,
    /// 0...1 of the bar that is filled: what the percentage shows (left or used).
    pub fill: f64,
    pub tone: BarTone,
    /// The first part of the fill, 0...`fill`, in the `Share` tone: Fable's share of the
    /// weekly limit.
    pub highlight: Option<f64>,
    pub caption: String,
}

/// Bar colour. It follows usage, so red still means "almost out" when Codex shows left.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BarTone {
    Accent,
    AccentSoft,
    /// A model's share of the weekly limit: a lighter tone that stands out on the bar.
    Share,
    /// The 5-hour meter of a plan without a 5-hour limit, on either service.
    Unlimited,
    Warning,
    Critical,
}

/// "RESET FOR EVERYONE · 5 HOURS AGO", with the tracker's credit under it. Clicking the
/// line opens the announcement, the credit the tracker (see `Store::reset_link`).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetLine {
    pub title: String,
    /// "DATA: CODEX-RESET.COM"; absent for resets Limita noticed itself.
    pub credit: Option<String>,
    /// Whether the line leads to an announcement.
    pub has_link: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct DetailRow {
    pub label: String,
    pub value: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ConnectOption {
    pub id: Service,
    pub label: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PillItem {
    pub id: Service,
    pub level: Option<LimitLevel>,
    pub stale: bool,
    pub label: String,
}

/// The tray icon's dot and tooltip.
#[derive(Clone, Debug, PartialEq)]
pub struct TraySummary {
    /// The most severe level among connected services.
    pub level: Option<LimitLevel>,
    /// Every service with data is stale.
    pub stale: bool,
    pub tooltip: String,
}

pub fn panel(snapshot: &Snapshot, now: Timestamp) -> PanelView {
    let services = snapshot
        .enabled
        .iter()
        .map(|&service| service_view(service, snapshot, now))
        .collect();
    let connect = if snapshot.enabled.is_empty() {
        Service::ALL
            .into_iter()
            .map(|id| ConnectOption { id, label: format!("Connect {}", id.product_name()) })
            .collect()
    } else {
        Vec::new()
    };
    let pill = snapshot
        .enabled
        .iter()
        .map(|&id| {
            let state = snapshot.state(id);
            PillItem { id, level: state.level(now), stale: state.is_stale(), label: pill_label(id, &state, now) }
        })
        .collect();
    PanelView {
        services,
        connect,
        is_refreshing: snapshot.is_refreshing,
        pill,
        longest_reset_text: longest_reset_text().to_uppercase(),
        prime_time: {
            let active: Vec<Service> = snapshot
                .enabled
                .iter()
                .copied()
                .filter(|service| service.prime_time().is_some_and(|window| window.contains(now)))
                .collect();
            PrimeTimeNotice::new(&active, &snapshot.enabled)
        },
    }
}

fn service_view(service: Service, snapshot: &Snapshot, now: Timestamp) -> ServiceView {
    let state = snapshot.state(service);
    let live_error = snapshot.live_errors.get(&service).cloned();
    let setup_message = snapshot
        .setup_message
        .as_ref()
        .filter(|(for_service, _)| *for_service == service)
        .map(|(_, text)| text.clone());
    let status = match (&state, state.snapshot()) {
        (_, None) => "NO DATA",
        (ServiceState::Stale(_), _) => "STALE DATA",
        _ => "LIVE DATA",
    };

    let mut view = ServiceView {
        id: service,
        name: match snapshot.details.get(&service).and_then(|details| details.plan.as_deref()) {
            Some(plan) => format!("{} {plan}", service.display_name()),
            None => service.display_name().into(),
        },
        level: state.level(now),
        stale: state.is_stale(),
        status: status.into(),
        setup_message: setup_message.clone(),
        meters: Vec::new(),
        credits: Vec::new(),
        details: Vec::new(),
        reset: None,
        updated: None,
        error: None,
        message: None,
    };
    if setup_message.is_some() {
        return view;
    }
    let Some(data) = state.snapshot() else {
        view.message = Some(live_error.or(state.unavailable_reason().map(str::to_string)).unwrap_or("No data".into()));
        return view;
    };
    let five_hour = if data.has_no_five_hour_limit {
        MeterView {
            title: "5 HOURS".into(),
            value: "∞".into(),
            amount: None,
            fill: 1.0,
            tone: BarTone::Unlimited,
            highlight: None,
            caption: "UNLIMITED".into(),
        }
    } else {
        // Claude's two bars share the softer weekly tone; Codex keeps a brighter 5-hour bar.
        let tone = if service == Service::Claude { BarTone::AccentSoft } else { BarTone::Accent };
        meter("5 HOURS", service, data.five_hour, tone, now)
    };
    // While the bar shows what is used, the per-model windows' part of the week is drawn
    // first in their own lighter tone, like Claude's settings do.
    let mut seven_day = meter("7 DAYS", service, data.seven_day, BarTone::AccentSoft, now);
    let share: f64 = data.scoped.iter().filter_map(|s| s.weekly_share_percent(now)).sum();
    if !service.shows_remaining() && share > 0.0 {
        seven_day.highlight = Some((share / 100.0).min(seven_day.fill));
    }
    view.meters = vec![five_hour, seven_day];
    // Per-model windows last, one per row. With a share of the week, the bar takes that
    // share's tone and the share sits right of it.
    view.meters.extend(data.scoped.iter().map(|s| match s.weekly_share_percent(now) {
        Some(used) => MeterView {
            amount: Some(weekly_share_text(used, s.weekly_share.and_then(|share| share.allowance_percent))),
            ..meter(&s.title(), service, Some(s.window), BarTone::Share, now)
        },
        None => meter(&s.title(), service, Some(s.window), BarTone::AccentSoft, now),
    }));
    let details = snapshot.details.get(&service).cloned().unwrap_or_default();
    view.credits = credit_meters(service, &details, now);
    view.details = detail_rows(service, &details);
    view.reset = crate::resets::latest(&snapshot.resets, service, now).map(|event| ResetLine {
        title: event.title(now),
        credit: event.source.credit().map(String::from),
        has_link: event.url.is_some(),
    });
    view.updated = Some(format!("UPDATED {}", updated_text(data.captured_at, now).to_uppercase()));
    view.error = live_error;
    view
}

/// "12% OF WEEKLY · MAX 50%".
pub fn weekly_share_text(used: f64, allowance: Option<f64>) -> String {
    match allowance {
        Some(allowance) => format!("{used:.0}% OF WEEKLY · MAX {allowance:.0}%"),
        None => format!("{used:.0}% OF WEEKLY"),
    }
}

fn meter(title: &str, service: Service, window: Option<LimitWindow>, tone: BarTone, now: Timestamp) -> MeterView {
    let used = window.map_or(0.0, |w| w.display_fraction(now));
    MeterView {
        title: format!("{title} {}", service.percent_meaning().to_uppercase()),
        value: window.map_or("—".into(), |w| w.shown_text(service, now)),
        amount: None,
        fill: window.map_or(0.0, |w| w.shown_percent(service, now) / 100.0),
        tone: pressure_tone(used, tone),
        highlight: None,
        caption: window
            .and_then(|w| w.reset_text(now))
            .map_or("NO WINDOW".into(), |text| text.to_uppercase()),
    }
}

/// Orange from 70 %, red from 90 % used.
fn pressure_tone(used: f64, tone: BarTone) -> BarTone {
    if used >= 0.9 {
        BarTone::Critical
    } else if used >= 0.7 {
        BarTone::Warning
    } else {
        tone
    }
}

/// Like Claude's own settings: the percentage and the bar show what is spent, the dollars
/// what is left. A meter is hidden when the service did not report it, and usage credits
/// also while they are turned off.
pub fn credit_meters(service: Service, details: &AccountDetails, now: Timestamp) -> Vec<MeterView> {
    if service != Service::Claude {
        return Vec::new();
    }
    let credit = |title: &str, value: String, amount: Option<String>, fill: f64, used: f64, caption: &str| MeterView {
        title: title.into(),
        value,
        amount,
        fill,
        tone: pressure_tone(used, BarTone::AccentSoft),
        highlight: None,
        caption: caption.into(),
    };
    let percent = |fraction: f64| format!("{:.0}%", fraction * 100.0);
    let mut meters = Vec::new();
    match &details.claude_usage_credits {
        Some(UsageCredits::Balance { dollars }) => {
            meters.push(credit("USAGE CREDITS", usd(*dollars), Some("LEFT".into()), 0.0, 0.0, "BALANCE"))
        }
        Some(UsageCredits::Spent { dollars, limit: Some(limit) }) if *limit > 0.0 => {
            let used = (dollars / limit).clamp(0.0, 1.0);
            let amount = format!("{} OF {} LEFT", dollars_text((limit - dollars).max(0.0)), dollars_text(*limit));
            meters.push(credit("USAGE CREDITS", percent(used), Some(amount), used, used, "SPEND LIMIT"));
        }
        Some(UsageCredits::Spent { dollars, .. }) => {
            meters.push(credit("USAGE CREDITS", usd(*dollars), Some("SPENT".into()), 0.0, 0.0, "NO SPEND LIMIT"))
        }
        Some(UsageCredits::Off) | None => {}
    }
    // Cloud credits are a grant that ends: once the date has passed they are gone.
    if let Some(cloud) = details.cloud_credits.as_ref().filter(|c| c.expires_at.is_none_or(|date| date > now)) {
        let caption = cloud_expiry_text(cloud.expires_at, cloud.remaining < 0.005, now);
        match cloud.limit.filter(|limit| *limit > 0.0) {
            Some(limit) => {
                let used = 1.0 - (cloud.remaining / limit).clamp(0.0, 1.0);
                let amount = format!("{} OF {} LEFT", dollars_text(cloud.remaining), dollars_text(limit));
                meters.push(credit("CLOUD CREDITS", percent(used), Some(amount), used, used, &caption));
            }
            None => meters.push(credit("CLOUD CREDITS", usd(cloud.remaining), Some("LEFT".into()), 0.0, 0.0, &caption)),
        }
    }
    meters
}

/// When the credits run out, or, with all of them spent, when the row goes away. A
/// countdown within a week, without the minutes while it counts days, and further out
/// the date: both stay within the meter's width.
pub fn cloud_expiry_text(date: Option<Timestamp>, spent: bool, now: Timestamp) -> String {
    let Some(date) = date else { return "NO EXPIRY DATE".into() };
    let verb = if spent { "DISAPPEARS" } else { "EXPIRES" };
    let left = seconds_between(now, date);
    if left <= 7.0 * 86400.0 {
        let text = duration_text(left);
        let words: Vec<&str> = text.split(' ').collect();
        let shown = if words.len() > 4 { &words[..words.len() - 2] } else { &words[..] };
        return format!("{verb} IN {}", shown.join(" ")).to_uppercase();
    }
    format!("{verb} ON {}", date.with_timezone(&chrono::Local).format("%b %-d").to_string().to_uppercase())
}

/// "just now" for fresh data. A tick can predate a just-fetched snapshot, which would
/// otherwise read "in 0 seconds".
pub fn updated_text(captured_at: Timestamp, now: Timestamp) -> String {
    if seconds_between(captured_at, now) < 10.0 {
        "just now".into()
    } else {
        relative_text(captured_at, now)
    }
}

/// "5h 12% used", "7d 66% left", or "5h —" while the 5-hour window is unknown.
pub fn pill_label(service: Service, state: &ServiceState, now: Timestamp) -> String {
    match state.snapshot().and_then(|s| s.headline()) {
        Some((label, window)) => format!("{label} {} {}", window.shown_text(service, now), service.percent_meaning()),
        None => "5h —".into(),
    }
}

/// Rows under the meters. A row is hidden when the service did not report its value.
pub fn detail_rows(service: Service, details: &AccountDetails) -> Vec<DetailRow> {
    let row = |label: &str, value: String| DetailRow { label: label.into(), value };
    let mut rows = Vec::new();
    if let Some(resets) = details.limit_resets {
        rows.push(row("LIMIT RESETS", resets.to_string()));
    }
    match service {
        Service::Codex => {
            if details.codex_credits_unlimited {
                rows.push(row("CREDITS", "Unlimited".into()));
            } else if let Some(credits) = details.codex_credits {
                let dollars = credits / AccountDetails::CODEX_CREDITS_PER_DOLLAR;
                rows.push(row("CREDITS", format!("{} credits · {}", number(credits, 0, 2), usd(dollars))));
            }
        }
        // Claude's credits are meters; see `credit_meters`.
        Service::Claude => {}
    }
    rows
}

/// "$1,234.50"; negative amounts as "-$1.00".
/// Whole dollars, as Claude's settings show them, but cents below $10 so a small balance
/// does not round to nothing.
pub fn dollars_text(value: f64) -> String {
    if value >= 10.0 {
        format!("${}", number(value, 0, 0))
    } else {
        usd(value)
    }
}

pub fn usd(value: f64) -> String {
    let sign = if value < 0.0 { "-" } else { "" };
    format!("{sign}${}", number(value.abs(), 2, 2))
}

/// Grouped thousands with between `min` and `max` fraction digits.
pub fn number(value: f64, min_fraction: usize, max_fraction: usize) -> String {
    let fixed = format!("{:.*}", max_fraction, value.abs());
    let (whole, fraction) = fixed.split_once('.').unwrap_or((&fixed, ""));
    let mut fraction = fraction.to_string();
    while fraction.len() > min_fraction && fraction.ends_with('0') {
        fraction.pop();
    }
    let mut grouped = String::new();
    for (index, digit) in whole.chars().enumerate() {
        if index > 0 && (whole.len() - index) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    let sign = if value < 0.0 && fixed.chars().any(|c| c.is_ascii_digit() && c != '0') { "-" } else { "" };
    if fraction.is_empty() { format!("{sign}{grouped}") } else { format!("{sign}{grouped}.{fraction}") }
}

pub fn tray(snapshot: &Snapshot, now: Timestamp) -> TraySummary {
    let states: Vec<_> = snapshot.enabled.iter().map(|&s| (s, snapshot.state(s))).collect();
    let level = states.iter().filter_map(|(_, state)| state.level(now)).max_by_key(|level| match level {
        LimitLevel::Normal => 0,
        LimitLevel::Warning => 1,
        LimitLevel::Critical => 2,
    });
    let with_data: Vec<_> = states.iter().filter(|(_, s)| s.snapshot().is_some()).collect();
    let stale = !with_data.is_empty() && with_data.iter().all(|(_, s)| s.is_stale());
    let tooltip = if states.is_empty() {
        "Limita — connect a service".to_string()
    } else {
        let parts: Vec<_> = states
            .iter()
            .map(|(service, state)| format!("{} {}", service.display_name(), pill_label(*service, state, now)))
            .collect();
        format!("Limita\n{}", parts.join("\n"))
    };
    TraySummary { level, stale, tooltip }
}

/// When the view next changes by itself: a countdown's minute, an expired window, or the
/// 30-second tick for "UPDATED …". `duration_text` rounds up, so a countdown to `reset`
/// changes at `reset` minus whole minutes.
pub fn next_tick(now: Timestamp, resets: &[Timestamp]) -> Timestamp {
    let mut next = now + chrono::Duration::seconds(30);
    for &reset in resets.iter().filter(|&&reset| reset > now) {
        let minutes = (seconds_between(now, reset) / 60.0).floor();
        let mut tick = reset - chrono::Duration::milliseconds((minutes * 60_000.0) as i64);
        if tick <= now {
            tick += chrono::Duration::seconds(60);
        }
        next = next.min(tick);
    }
    next
}

/// Every reset time the enabled services report, the cloud credits' included.
pub fn reset_dates(snapshot: &Snapshot) -> Vec<Timestamp> {
    snapshot
        .enabled
        .iter()
        .flat_map(|s| {
            let windows = snapshot.states.get(s).and_then(ServiceState::snapshot).map(LimitSnapshot::reset_dates);
            let cloud = snapshot.details.get(s).and_then(|d| d.cloud_credits.as_ref()?.expires_at);
            windows.unwrap_or_default().into_iter().chain(cloud)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Allowance, LimitSnapshot};
    use crate::time::from_unix;

    fn at(seconds: f64) -> Timestamp {
        from_unix(seconds.max(0.001)).unwrap()
    }

    #[test]
    fn detail_rows_formatting() {
        let codex = AccountDetails { limit_resets: Some(0), codex_credits: Some(250.0), ..Default::default() };
        let values: Vec<_> = detail_rows(Service::Codex, &codex).into_iter().map(|r| r.value).collect();
        assert_eq!(values, ["0", "250 credits · $10.00"]);

        let claude = AccountDetails {
            claude_usage_credits: Some(UsageCredits::Off),
            cloud_credits: Some(Allowance { remaining: 95.089746, limit: Some(100.0), expires_at: None }),
            ..Default::default()
        };
        assert!(detail_rows(Service::Claude, &claude).is_empty(), "Claude's credits are meters");
        assert_eq!(usd(1234.5), "$1,234.50");
        assert_eq!(number(1234567.126, 0, 2), "1,234,567.13");
        assert_eq!(number(12.5, 0, 2), "12.5");
    }

    #[test]
    fn credit_meters_show_spent_with_dollars_left() {
        let now = crate::time::parse_flexible("2026-10-21T19:00:00Z").unwrap();
        let mut details = AccountDetails {
            claude_usage_credits: Some(UsageCredits::Off),
            cloud_credits: Some(Allowance {
                remaining: 163.053854,
                limit: Some(250.0),
                expires_at: crate::time::parse_flexible("2026-11-05T07:59:00Z"),
            }),
            ..Default::default()
        };
        let meters = credit_meters(Service::Claude, &details, now);
        assert_eq!(meters.len(), 1, "usage credits that are off are hidden");
        let cloud = &meters[0];
        assert_eq!(cloud.title, "CLOUD CREDITS");
        assert_eq!(cloud.value, "35%", "the percentage is what is spent");
        assert_eq!(cloud.amount.as_deref(), Some("$163 OF $250 LEFT"), "the dollars are what is left");
        assert!((cloud.fill - 0.348).abs() < 0.001, "the bar shows what is spent");
        assert_eq!(cloud.tone, BarTone::AccentSoft);
        assert!(cloud.caption.starts_with("EXPIRES ON NOV"), "{}", cloud.caption);

        details.claude_usage_credits = Some(UsageCredits::Spent { dollars: 12.5, limit: Some(50.0) });
        details.cloud_credits = Some(Allowance { remaining: 5.0, limit: Some(100.0), expires_at: Some(now + chrono::Duration::minutes(90)) });
        let meters = credit_meters(Service::Claude, &details, now);
        assert_eq!(meters[0].value, "25%");
        assert_eq!(meters[0].title, "USAGE CREDITS");
        assert_eq!(meters[0].amount.as_deref(), Some("$38 OF $50 LEFT"));
        assert_eq!(meters[1].amount.as_deref(), Some("$5.00 OF $100 LEFT"), "cents below $10");
        assert_eq!(meters[1].tone, BarTone::Critical, "the colour follows what is spent");
        assert_eq!(meters[1].caption, "EXPIRES IN 1 HOUR 30 MIN", "a near expiry counts down");
        let in_days = now + chrono::Duration::hours(4 * 24 + 19) + chrono::Duration::minutes(1);
        details.cloud_credits = Some(Allowance { remaining: 5.0, limit: Some(100.0), expires_at: Some(in_days) });
        assert_eq!(credit_meters(Service::Claude, &details, now)[1].caption, "EXPIRES IN 4 DAYS 19 HOURS");
        details.cloud_credits = Some(Allowance { remaining: 0.0, limit: Some(250.0), expires_at: Some(in_days) });
        assert_eq!(credit_meters(Service::Claude, &details, now)[1].caption, "DISAPPEARS IN 4 DAYS 19 HOURS", "nothing left to expire");
        details.cloud_credits = Some(Allowance { remaining: 0.0, limit: Some(250.0), expires_at: Some(now + chrono::Duration::days(30)) });
        assert!(credit_meters(Service::Claude, &details, now)[1].caption.starts_with("DISAPPEARS ON "));
        details.cloud_credits = Some(Allowance { remaining: 5.0, limit: Some(100.0), expires_at: None });
        assert_eq!(credit_meters(Service::Claude, &details, now)[1].caption, "NO EXPIRY DATE");
        details.cloud_credits = Some(Allowance { remaining: 5.0, limit: Some(100.0), expires_at: Some(now) });
        assert_eq!(credit_meters(Service::Claude, &details, now).len(), 1, "expired credits are gone");
        assert!(credit_meters(Service::Claude, &AccountDetails::default(), now).is_empty(), "missing values hide meters");
        assert!(credit_meters(Service::Codex, &details, now).is_empty());
    }

    #[test]
    fn each_column_shows_its_newest_reset_with_the_credit() {
        use crate::resets::{ResetEvent, ResetKind, ResetSource};
        let now = at(1_800_000_000.0);
        let mut snapshot = Snapshot { enabled: vec![Service::Claude, Service::Codex], ..Default::default() };
        for service in Service::ALL {
            snapshot.states.insert(service, ServiceState::Fresh(LimitSnapshot::new(Some(LimitWindow::new(1.0, None)), None, now)));
        }
        let hours_ago = |hours: i64| now - chrono::Duration::hours(hours);
        let mut global = ResetEvent::new("g".into(), Service::Codex, ResetKind::Global, hours_ago(5), ResetSource::CodexReset);
        global.url = Some("https://x.com/1".into());
        let older = ResetEvent::new("o".into(), Service::Codex, ResetKind::Global, hours_ago(30), ResetSource::CodexReset);
        let gone = ResetEvent::new("c".into(), Service::Claude, ResetKind::Global, hours_ago(24 * 8), ResetSource::ClaudeResets);
        snapshot.resets = vec![older, global, gone];
        let view = panel(&snapshot, now);
        assert_eq!(view.services[0].reset, None, "a reset older than a week is not shown");
        assert_eq!(
            view.services[1].reset,
            Some(ResetLine { title: "RESET FOR EVERYONE · 5 HOURS AGO".into(), credit: Some("DATA: CODEX-RESET.COM".into()), has_link: true })
        );

        snapshot.resets = vec![ResetEvent::new("e".into(), Service::Claude, ResetKind::EarlyWeekly, hours_ago(2), ResetSource::Local)];
        let claude = panel(&snapshot, now).services[0].reset.clone().unwrap();
        assert_eq!(claude.title, "YOUR WEEKLY LIMIT WAS RESET EARLY · 2 HOURS AGO");
        assert_eq!(claude.credit, None, "nothing to credit for what Limita noticed itself");
    }

    #[test]
    fn per_model_windows_get_their_own_meters() {
        let now = at(1_800_000_000.0);
        let reset = at(1_800_000_000.0 + 3600.0);
        let mut snapshot = Snapshot { enabled: vec![Service::Claude], ..Default::default() };
        let two = LimitSnapshot::new(Some(LimitWindow::new(19.0, None)), Some(LimitWindow::new(3.0, None)), now);
        snapshot.states.insert(Service::Claude, ServiceState::Fresh(two.clone()));
        let view = panel(&snapshot, now);
        assert_eq!(view.services[0].meters.len(), 2);

        let fable = crate::model::ScopedWindow { name: "Fable".into(), is_weekly: true, window: LimitWindow::new(4.0, Some(reset)), weekly_share: None };
        snapshot.states.insert(Service::Claude, ServiceState::Fresh(two.with_scoped(vec![fable])));
        let view = panel(&snapshot, now);
        let claude = &view.services[0];
        assert_eq!(claude.meters[2].title, "FABLE 7 DAYS USED");
        assert_eq!(claude.meters[2].value, "4%");
        assert_eq!(reset_dates(&snapshot), [reset], "the per-model countdown ticks too");
    }

    #[test]
    fn pill_labels() {
        let now = at(1_789_800_000.0);
        let team = LimitSnapshot::with_flag(None, Some(LimitWindow::new(34.0, None)), now, true);
        assert_eq!(pill_label(Service::Codex, &ServiceState::Fresh(team), now), "7d 66% left");
        let weekly = LimitSnapshot::new(None, Some(LimitWindow::new(40.0, None)), now);
        assert_eq!(pill_label(Service::Claude, &ServiceState::Fresh(weekly), now), "5h —");
        assert_eq!(pill_label(Service::Claude, &ServiceState::Unavailable("x".into()), now), "5h —");
        let both = LimitSnapshot::new(Some(LimitWindow::new(12.0, None)), Some(LimitWindow::new(40.0, None)), now);
        assert_eq!(pill_label(Service::Claude, &ServiceState::Fresh(both), now), "5h 12% used");
    }

    #[test]
    fn updated_text_never_says_in_the_future() {
        let now = at(1_000_000.0);
        assert_eq!(updated_text(at(1_000_000.4), now), "just now");
        assert_eq!(updated_text(at(999_997.0), now), "just now");
        assert_eq!(updated_text(at(1_000_000.0 - 7200.0), now), "2 hours ago");
    }

    #[test]
    fn ticks_land_when_the_minute_changes() {
        let reset = at(1000.0);
        assert_eq!(next_tick(at(10.0), &[reset]), at(40.0));
        assert_eq!(next_tick(at(40.0), &[reset]), at(70.0), "on a boundary, the next minute");
        assert_eq!(next_tick(at(980.0), &[reset]), at(1000.0), "the reset itself");
        assert_eq!(next_tick(at(1000.0), &[reset]), at(1030.0), "only the 30 s tick after it");
        let mut start = 1.0;
        while start < 1000.0 {
            let now = at(start);
            let next = next_tick(now, &[reset]);
            let before = duration_text(seconds_between(now, reset));
            let just_before = next - chrono::Duration::milliseconds(10);
            assert_eq!(duration_text(seconds_between(just_before, reset)), before, "no change is missed before {next}");
            start += 7.0;
        }
    }

    #[test]
    fn panel_view_for_claude_and_codex() {
        let now = at(1_800_000_000.0);
        let mut snapshot = Snapshot { enabled: vec![Service::Claude, Service::Codex], ..Default::default() };
        snapshot.states.insert(
            Service::Claude,
            ServiceState::Fresh(LimitSnapshot::new(
                Some(LimitWindow::new(75.0, Some(at(1_800_000_000.0 + 5400.0)))),
                Some(LimitWindow::new(20.0, None)),
                now,
            )),
        );
        snapshot.live_errors.insert(Service::Codex, "Codex CLI not found".into());
        let view = panel(&snapshot, now);

        let claude = &view.services[0];
        assert_eq!(claude.status, "LIVE DATA");
        assert_eq!(claude.level, Some(LimitLevel::Warning));
        assert_eq!(claude.meters[0].title, "5 HOURS USED");
        assert_eq!(claude.meters[0].value, "75%");
        assert_eq!(claude.meters[0].tone, BarTone::Warning);
        assert_eq!(claude.meters[0].caption, "RESETS IN 1 HOUR 30 MIN");
        assert_eq!(claude.meters[1].caption, "NO WINDOW");
        assert_eq!(claude.updated.as_deref(), Some("UPDATED JUST NOW"));

        let codex = &view.services[1];
        assert!(codex.meters.is_empty());
        assert_eq!(codex.message.as_deref(), Some("Codex CLI not found"), "the live error explains missing data");
        assert!(view.connect.is_empty());
        assert_eq!(view.pill[0].label, "5h 75% used");

        let summary = tray(&snapshot, now);
        assert_eq!(summary.level, Some(LimitLevel::Warning));
        assert!(!summary.stale);
        assert_eq!(summary.tooltip, "Limita\nClaude 5h 75% used\nCodex 5h —");
    }

    #[test]
    fn prime_time_badge_for_enabled_services_in_peak_hours() {
        let peak = crate::time::parse_flexible("2026-10-07T06:00:00-07:00").unwrap();
        let quiet = crate::time::parse_flexible("2026-10-07T12:00:00-07:00").unwrap();
        let both = Snapshot { enabled: vec![Service::Claude, Service::Codex], ..Default::default() };
        // 6:00 PT is 13:00 UTC: both services are in their peak hours.
        let badge = panel(&both, peak).prime_time.unwrap();
        assert_eq!(badge.first_line(), "PEAK HOURS FOR ALL PROVIDERS");
        assert_eq!(badge.detail, "USAGE LIMITS RUN OUT FASTER");
        // 12:00 PT is 19:00 UTC: neither.
        assert_eq!(panel(&both, quiet).prime_time, None);
        let codex_only = Snapshot { enabled: vec![Service::Codex], ..Default::default() };
        assert_eq!(panel(&codex_only, peak).prime_time.unwrap().first_line(), "CODEX PEAK HOURS", "only connected services count");
    }

    #[test]
    fn nothing_connected_offers_both_services() {
        let view = panel(&Snapshot::default(), at(1.0));
        let labels: Vec<_> = view.connect.iter().map(|c| c.label.as_str()).collect();
        assert_eq!(labels, ["Connect Claude Code", "Connect Codex"]);
        assert_eq!(tray(&Snapshot::default(), at(1.0)).level, None);
    }
}
