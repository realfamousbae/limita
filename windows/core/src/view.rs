//! What the tray, the pill and the dashboard show, computed for a given `now`. The
//! webview only renders this; all wording and thresholds live here, where they are
//! tested. Port of the logic in `ExpandedView.swift` and `MiniPillView.swift`.

use serde::Serialize;

use crate::model::{
    longest_reset_text, AccountDetails, LimitLevel, LimitWindow, Service, ServiceState, UsageCredits,
};
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
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceView {
    pub id: Service,
    pub name: String,
    /// Traffic light of the headline window; `None` is grey.
    pub level: Option<LimitLevel>,
    pub stale: bool,
    /// Claude only: "LIVE DATA · SHOWING USED". Codex meters already say "left".
    pub subtitle: Option<String>,
    /// Outcome of connecting, shown instead of the meters until dismissed.
    pub setup_message: Option<String>,
    pub meters: Vec<MeterView>,
    pub details: Vec<DetailRow>,
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
    /// 0...1 of the bar that is filled: what the percentage shows (left or used).
    pub fill: f64,
    pub tone: BarTone,
    pub caption: String,
}

/// Bar colour. It follows usage, so red still means "almost out" when Codex shows left.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BarTone {
    Accent,
    AccentSoft,
    Warning,
    Critical,
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
    let subtitle = (service == Service::Claude).then(|| {
        let status = match (&state, state.snapshot()) {
            (_, None) => "NO DATA",
            (ServiceState::Stale(_), _) => "STALE DATA",
            _ => "LIVE DATA",
        };
        format!("{status} · SHOWING {}", service.percent_meaning().to_uppercase())
    });

    let mut view = ServiceView {
        id: service,
        name: service.display_name().into(),
        level: state.level(now),
        stale: state.is_stale(),
        subtitle,
        setup_message: setup_message.clone(),
        meters: Vec::new(),
        details: Vec::new(),
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
            fill: 0.0,
            tone: BarTone::AccentSoft,
            caption: "NO 5-HOUR LIMIT".into(),
        }
    } else {
        // Claude's two bars share the softer weekly tone; Codex keeps a brighter 5-hour bar.
        let tone = if service == Service::Claude { BarTone::AccentSoft } else { BarTone::Accent };
        meter("5 HOURS", service, data.five_hour, tone, now)
    };
    view.meters = vec![five_hour, meter("7 DAYS", service, data.seven_day, BarTone::AccentSoft, now)];
    view.details = detail_rows(service, snapshot.details.get(&service).unwrap_or(&AccountDetails::default()));
    view.updated = Some(format!("UPDATED {}", updated_text(data.captured_at, now).to_uppercase()));
    view.error = live_error;
    view
}

fn meter(title: &str, service: Service, window: Option<LimitWindow>, tone: BarTone, now: Timestamp) -> MeterView {
    let used = window.map_or(0.0, |w| w.display_fraction(now));
    MeterView {
        title: format!("{title} {}", service.percent_meaning().to_uppercase()),
        value: window.map_or("—".into(), |w| w.shown_text(service, now)),
        fill: window.map_or(0.0, |w| w.shown_percent(service, now) / 100.0),
        // Orange from 70 %, red from 90 % used.
        tone: if used >= 0.9 {
            BarTone::Critical
        } else if used >= 0.7 {
            BarTone::Warning
        } else {
            tone
        },
        caption: window
            .and_then(|w| w.reset_text(now))
            .map_or("NO WINDOW".into(), |text| text.to_uppercase()),
    }
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
        Service::Claude => {
            match &details.claude_usage_credits {
                Some(UsageCredits::Off) => rows.push(row("USAGE CREDITS", "Off".into())),
                Some(UsageCredits::Balance { dollars }) => rows.push(row("USAGE CREDITS", usd(*dollars))),
                Some(UsageCredits::Spent { dollars, limit }) => rows.push(row(
                    "USAGE CREDITS",
                    match limit {
                        Some(limit) => format!("{} of {} used", usd(*dollars), usd(*limit)),
                        None => format!("{} used", usd(*dollars)),
                    },
                )),
                None => {}
            }
            if let Some(cloud) = &details.cloud_credits {
                let mut value = usd(cloud.remaining);
                if let Some(limit) = cloud.limit {
                    value += &format!(" / {}", usd(limit));
                }
                rows.push(row("CLOUD CREDITS", value));
            }
        }
    }
    rows
}

/// "$1,234.50"; negative amounts as "-$1.00".
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

/// Every reset time the enabled services report.
pub fn reset_dates(snapshot: &Snapshot) -> Vec<Timestamp> {
    snapshot
        .enabled
        .iter()
        .filter_map(|&s| snapshot.states.get(&s).and_then(|state| state.snapshot().copied()))
        .flat_map(|data| [data.five_hour, data.seven_day])
        .flatten()
        .filter_map(|window| window.resets_at)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{duration_text, Allowance, LimitSnapshot};
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
        let values: Vec<_> = detail_rows(Service::Claude, &claude).into_iter().map(|r| r.value).collect();
        assert_eq!(values, ["Off", "$95.09 / $100.00"]);
        assert!(detail_rows(Service::Claude, &AccountDetails::default()).is_empty(), "missing values hide rows");
        assert_eq!(usd(1234.5), "$1,234.50");
        assert_eq!(number(1234567.126, 0, 2), "1,234,567.13");
        assert_eq!(number(12.5, 0, 2), "12.5");
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
        assert_eq!(claude.subtitle.as_deref(), Some("LIVE DATA · SHOWING USED"));
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
    fn nothing_connected_offers_both_services() {
        let view = panel(&Snapshot::default(), at(1.0));
        let labels: Vec<_> = view.connect.iter().map(|c| c.label.as_str()).collect();
        assert_eq!(labels, ["Connect Claude Code", "Connect Codex"]);
        assert_eq!(tray(&Snapshot::default(), at(1.0)).level, None);
    }
}
