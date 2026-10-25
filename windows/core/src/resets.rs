//! Limit resets worth telling the user about: ones a service gave everyone (from a
//! public tracker) and ones Limita notices in the user's own numbers. Port of
//! `ResetEvent.swift`, `ResetFeed.swift` and `ResetWatcher.swift`.
//!
//! The trackers, one per service:
//!
//! - Codex: codex-reset.com's forecast. A reset is confirmed when its `last_reset_at`
//!   moves forward; `latest_alert` links the post it came from.
//! - Claude: claude-resets.com's event list (CC BY 4.0), of which only `kind: "reset"`
//!   counts. Events it has not checked yet are marked provisional.
//!
//! Both ask for a visible credit next to their data, a User-Agent that names the app,
//! at most one request a minute, and respect for `Retry-After`. Parsing is lenient: a
//! missing or unknown field drops that event, never the whole feed.
//!
//! What was seen is saved in `resets.json`, so a relaunch announces nothing twice. The
//! very first look at a source only records what is there: an old reset is shown, never
//! announced.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::Duration;

use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::model::{AccountDetails, LimitSnapshot, Service};
use crate::paths;
use crate::settings::ServiceSettings;
use crate::time::{parse_flexible, relative_text, seconds_between, Timestamp};

pub const CODEX_URL: &str = "https://codex-reset.com/api/forecast";
pub const CLAUDE_URL: &str = "https://claude-resets.com/api/resets";
/// How often the trackers are asked.
pub const POLL_INTERVAL: f64 = 15.0 * 60.0;
/// Lines stay up for a week, banked resets for as long as they can be applied.
pub const SHOWN_FOR: f64 = 7.0 * 86400.0;
const TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "type")]
pub enum ResetKind {
    /// Limits reset for everyone in `scope`.
    Global,
    /// A reset to apply whenever the user likes, until `usable_until`.
    #[serde(rename_all = "camelCase")]
    Banked { usable_until: Option<Timestamp> },
    /// The user's weekly window started over before its scheduled reset.
    EarlyWeekly,
    /// Codex granted a limit reset to redeem; `count` is how many there are now.
    NewBankedCredit { count: i64 },
}

impl ResetKind {
    fn same_kind(&self, other: &Self) -> bool {
        std::mem::discriminant(self) == std::mem::discriminant(other)
    }
}

/// Where an event came from. The public trackers ask for a visible credit.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ResetSource {
    CodexReset,
    ClaudeResets,
    Local,
}

impl ResetSource {
    /// "DATA: CODEX-RESET.COM", shown under every line that uses the tracker's data.
    pub fn credit(self) -> Option<&'static str> {
        match self {
            Self::CodexReset => Some("DATA: CODEX-RESET.COM"),
            Self::ClaudeResets => Some("DATA: CLAUDE-RESETS.COM"),
            Self::Local => None,
        }
    }

    pub fn site(self) -> Option<&'static str> {
        match self {
            Self::CodexReset => Some("https://codex-reset.com"),
            Self::ClaudeResets => Some("https://claude-resets.com"),
            Self::Local => None,
        }
    }

    fn host(self) -> Option<&'static str> {
        self.site().map(|site| site.trim_start_matches("https://"))
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetEvent {
    /// Stable across fetches, so one event is announced once.
    pub id: String,
    pub service: Service,
    pub kind: ResetKind,
    pub date: Timestamp,
    /// The announcement, e.g. a post on X.
    #[serde(default)]
    pub url: Option<String>,
    /// Who it applies to as the tracker says it, e.g. "all" or "Pro, Max + Team".
    #[serde(default)]
    pub scope: Option<String>,
    /// The tracker's one-line description.
    #[serde(default)]
    pub note: Option<String>,
    pub source: ResetSource,
    /// Not yet confirmed by the tracker: shown, but not announced.
    #[serde(default)]
    pub provisional: bool,
}

impl ResetEvent {
    pub fn new(id: String, service: Service, kind: ResetKind, date: Timestamp, source: ResetSource) -> Self {
        Self { id, service, kind, date, url: None, scope: None, note: None, source, provisional: false }
    }

    pub fn is_shown(&self, now: Timestamp) -> bool {
        if let ResetKind::Banked { usable_until: Some(until) } = self.kind {
            return now < until;
        }
        seconds_between(self.date, now) < SHOWN_FOR
    }

    /// "RESET FOR EVERYONE · 5 HOURS AGO", in the dashboard's caption style.
    pub fn title(&self, now: Timestamp) -> String {
        let ago = relative_text(self.date.min(now), now).to_uppercase();
        match &self.kind {
            ResetKind::Global => format!("RESET FOR {} · {ago}", self.audience()),
            ResetKind::Banked { usable_until: Some(until) } => format!("BANKED RESET · USE BY {}", day_text(*until).to_uppercase()),
            ResetKind::Banked { usable_until: None } => format!("BANKED RESET · {ago}"),
            ResetKind::EarlyWeekly => format!("YOUR WEEKLY LIMIT WAS RESET EARLY · {ago}"),
            ResetKind::NewBankedCredit { count } => format!("NEW LIMIT RESET TO REDEEM · {count} IN TOTAL"),
        }
    }

    /// "EVERYONE" for "all" or no scope, otherwise the scope, e.g. "MAX".
    fn audience(&self) -> String {
        match self.scope.as_deref().map(str::trim) {
            None | Some("") => "EVERYONE".into(),
            Some(scope) if scope.eq_ignore_ascii_case("all") => "EVERYONE".into(),
            Some(scope) => scope.to_uppercase(),
        }
    }

    pub fn notification_title(&self) -> String {
        let name = self.service.display_name();
        match self.kind {
            ResetKind::Global => {
                let who = if self.audience() == "EVERYONE" { "everyone" } else { self.scope.as_deref().unwrap_or_default() };
                format!("{name} limits were reset for {who}")
            }
            ResetKind::Banked { .. } => format!("{name} gave a banked limit reset"),
            ResetKind::EarlyWeekly => format!("Your {name} weekly limit was reset early"),
            ResetKind::NewBankedCredit { .. } => "You have a new Codex limit reset".into(),
        }
    }

    pub fn notification_body(&self) -> String {
        let mut lines: Vec<String> = Vec::new();
        if let Some(note) = &self.note {
            lines.push(note.clone());
        }
        match self.kind {
            ResetKind::Banked { usable_until: Some(until) } => lines.push(format!("Use it by {}.", day_text(until))),
            ResetKind::NewBankedCredit { count } => lines.push(format!("{count} available to redeem.")),
            _ => {}
        }
        if let Some(host) = self.source.host() {
            lines.push(format!("Data: {host}"));
        }
        lines.join("\n")
    }
}

/// "Oct 22". Deadlines are announced as "until October 22", i.e. 23:59:59 UTC; read in
/// the user's zone that could be the 23rd.
fn day_text(date: Timestamp) -> String {
    date.format("%b %-d").to_string()
}

/// The line for a service's column: its newest reset still worth showing.
pub fn latest(events: &[ResetEvent], service: Service, now: Timestamp) -> Option<&ResetEvent> {
    events
        .iter()
        .filter(|event| event.service == service && event.is_shown(now))
        .max_by_key(|event| event.date)
}

// MARK: - Feeds

/// The tracker for `service`; `LIMITA_RESET_FEED_CODEX` / `LIMITA_RESET_FEED_CLAUDE`
/// point it elsewhere (a `file://` URL works) to test against a local copy.
pub fn feed_url(service: Service, env: impl Fn(&str) -> Option<String>) -> String {
    let (key, default) = match service {
        Service::Codex => ("LIMITA_RESET_FEED_CODEX", CODEX_URL),
        Service::Claude => ("LIMITA_RESET_FEED_CLAUDE", CLAUDE_URL),
    };
    env(key).filter(|url| !url.is_empty()).unwrap_or_else(|| default.into())
}

/// "Limita/0.19.0 (+https://github.com/realfamousbae/limita)".
pub fn user_agent() -> String {
    format!("Limita/{} (+https://github.com/realfamousbae/limita)", env!("CARGO_PKG_VERSION"))
}

#[derive(Clone, Debug, PartialEq)]
pub enum FeedError {
    /// A 429, with the wait the server asked for when it named one.
    RateLimited(Option<f64>),
    Failed(String),
}

/// The service's latest events, newest first.
pub fn fetch(service: Service, url: &str, now: Timestamp) -> Result<Vec<ResetEvent>, FeedError> {
    if let Some(path) = url.strip_prefix("file://") {
        let data = std::fs::read(path).map_err(|error| FeedError::Failed(format!("Could not read {path}: {error}")))?;
        return parse(&data, service).map_err(FeedError::Failed);
    }
    let tls = native_tls::TlsConnector::new().map_err(|error| FeedError::Failed(format!("Could not set up TLS: {error}")))?;
    let agent = ureq::AgentBuilder::new().tls_connector(Arc::new(tls)).build();
    let response = agent
        .get(url)
        .timeout(TIMEOUT)
        .set("User-Agent", &user_agent())
        .set("Accept", "application/json")
        .call();
    match response {
        Ok(response) => {
            let body = response.into_string().map_err(|error| FeedError::Failed(format!("Could not read the tracker: {error}")))?;
            parse(body.as_bytes(), service).map_err(FeedError::Failed)
        }
        Err(ureq::Error::Status(429, response)) => Err(FeedError::RateLimited(
            response.header("Retry-After").and_then(|header| crate::claude_live::retry_after(header, now)),
        )),
        Err(ureq::Error::Status(status, _)) => Err(FeedError::Failed(format!("The reset tracker answered {status}"))),
        Err(ureq::Error::Transport(error)) => Err(FeedError::Failed(format!("Could not reach the reset tracker: {error}"))),
    }
}

/// Lenient about fields, but a body that is not a JSON object (e.g. an error page served
/// with 200) is a failure: taken as "no events", it would hide the line and, on a first
/// run, record nothing, so the next good answer would announce old resets.
pub fn parse(data: &[u8], service: Service) -> Result<Vec<ResetEvent>, String> {
    let Ok(Value::Object(_)) = serde_json::from_slice::<Value>(data) else {
        return Err("The reset tracker sent something other than JSON".into());
    };
    Ok(match service {
        Service::Codex => codex_forecast(data).into_iter().collect(),
        Service::Claude => claude_resets(data),
    })
}

/// The last confirmed Codex reset, `None` when the forecast names none.
pub fn codex_forecast(data: &[u8]) -> Option<ResetEvent> {
    let root: Value = serde_json::from_slice(data).ok()?;
    let date = root.get("last_reset_at")?.as_str().and_then(parse_flexible)?;
    // The alert is about this reset only if it is a reset at the same moment.
    let url = root
        .get("latest_alert")
        .filter(|alert| alert.get("kind").and_then(Value::as_str) == Some("reset"))
        .and_then(|alert| {
            let link = alert.get("confirmation_url").and_then(Value::as_str).or(alert.get("url").and_then(Value::as_str))?;
            let same_moment = ["source_at", "observed_at", "confirmed_at"]
                .iter()
                .filter_map(|key| alert.get(*key).and_then(Value::as_str).and_then(parse_flexible))
                .any(|time| seconds_between(time, date).abs() < 60.0);
            same_moment.then(|| link.to_string())
        });
    let mut event =
        ResetEvent::new(format!("codex-reset-{}", date.timestamp()), Service::Codex, ResetKind::Global, date, ResetSource::CodexReset);
    event.url = url.or(ResetSource::CodexReset.site().map(String::from));
    Some(event)
}

/// Claude's resets, newest first; policy changes and malformed events are dropped.
pub fn claude_resets(data: &[u8]) -> Vec<ResetEvent> {
    let Ok(root) = serde_json::from_slice::<Value>(data) else { return Vec::new() };
    let Some(events) = root.pointer("/providers/claude/events").and_then(Value::as_array) else { return Vec::new() };
    let provisional_ids: BTreeSet<&str> = root
        .pointer("/meta/provisionalEventIds")
        .and_then(Value::as_array)
        .map(|ids| ids.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let text = |event: &Value, key: &str| event.get(key).and_then(Value::as_str).map(String::from);
    let mut parsed: Vec<ResetEvent> = events
        .iter()
        .filter_map(|event| {
            if event.get("kind").and_then(Value::as_str) != Some("reset") {
                return None;
            }
            let id = match event.get("id")? {
                Value::String(id) => id.clone(),
                Value::Number(id) => id.to_string(),
                _ => return None,
            };
            let date = event.get("date").and_then(Value::as_str).and_then(parse_flexible)?;
            let kind = if event.get("resetType").and_then(Value::as_str) == Some("banked") {
                ResetKind::Banked { usable_until: event.get("usableUntil").and_then(Value::as_str).and_then(parse_flexible) }
            } else {
                ResetKind::Global
            };
            let verification = event.get("verification").and_then(Value::as_str);
            let mut parsed = ResetEvent::new(format!("claude-{id}"), Service::Claude, kind, date, ResetSource::ClaudeResets);
            parsed.url = text(event, "url").or(ResetSource::ClaudeResets.site().map(String::from));
            parsed.scope = text(event, "scope");
            parsed.note = text(event, "note");
            parsed.provisional = provisional_ids.contains(id.as_str()) || verification.is_some_and(|v| v != "curated");
            Some(parsed)
        })
        .collect();
    parsed.sort_by_key(|event| std::cmp::Reverse(event.date));
    parsed
}

// MARK: - Watcher

/// The weekly window as last seen, to tell an early reset from a scheduled one.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WeeklyMark {
    pub resets_at: Timestamp,
    pub used_percent: f64,
    pub captured_at: Timestamp,
}

/// Everything that survives a relaunch.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Memory {
    /// The newest Codex reset seen; a forecast going back in time is a correction.
    codex_last_reset: Option<Timestamp>,
    /// Claude event ids already recorded or announced.
    claude_seen: Option<BTreeSet<String>>,
    weekly: BTreeMap<Service, WeeklyMark>,
    limit_resets: Option<i64>,
    /// Resets noticed in the user's own numbers that are still shown, one per service
    /// and kind.
    local: Vec<ResetEvent>,
}

pub type ResetFetch = Arc<dyn Fn(Service, Timestamp) -> Result<Vec<ResetEvent>, FeedError> + Send + Sync>;
pub type Notify = Arc<dyn Fn(&ResetEvent) + Send + Sync>;

/// The real trackers.
pub fn standard_fetch() -> ResetFetch {
    Arc::new(|service, now| fetch(service, &feed_url(service, |key| std::env::var(key).ok()), now))
}

pub fn standard_file() -> PathBuf {
    paths::app_data().join("resets.json")
}

#[derive(Default)]
struct State {
    /// The trackers' latest events per service, newest first.
    feed: BTreeMap<Service, Vec<ResetEvent>>,
    memory: Memory,
    fetching: BTreeSet<Service>,
    last_fetch: BTreeMap<Service, Timestamp>,
    paused_until: BTreeMap<Service, Timestamp>,
    rate_limit_streak: BTreeMap<Service, u32>,
}

/// Keeps track of limit resets. Cheap to clone; clones share their state.
#[derive(Clone)]
pub struct ResetWatcher {
    state: Arc<Mutex<State>>,
    file: PathBuf,
    settings: ServiceSettings,
    fetch: ResetFetch,
    notify: Arc<Mutex<Option<Notify>>>,
    on_change: Arc<dyn Fn() + Send + Sync>,
}

impl ResetWatcher {
    pub fn new(file: PathBuf, settings: ServiceSettings, fetch: ResetFetch, on_change: Arc<dyn Fn() + Send + Sync>) -> Self {
        let memory = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        Self {
            state: Arc::new(Mutex::new(State { memory, ..State::default() })),
            file,
            settings,
            fetch,
            notify: Arc::default(),
            on_change,
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// How new resets are announced; without one they are only shown.
    pub fn set_notifier(&self, notify: Notify) {
        *self.notify.lock().unwrap_or_else(|p| p.into_inner()) = Some(notify);
    }

    /// Whether new resets are announced. The dashboard line shows either way.
    pub fn notifications_enabled(&self) -> bool {
        self.settings.reset_notifications()
    }

    pub fn set_notifications_enabled(&self, enabled: bool) {
        self.settings.set_reset_notifications(enabled);
    }

    /// Every event that may be shown: the trackers' and the ones noticed locally.
    pub fn events(&self) -> Vec<ResetEvent> {
        let state = self.lock();
        state.feed.values().flatten().chain(&state.memory.local).cloned().collect()
    }

    /// Asks the trackers of `services`, except one that asked for a pause or was asked
    /// within the last minute. Returns the workers, which tests join.
    pub fn refresh(&self, services: &[Service], now: Timestamp) -> Vec<JoinHandle<()>> {
        let due: Vec<Service> = {
            let mut state = self.lock();
            let due: Vec<Service> = services
                .iter()
                .copied()
                .filter(|service| {
                    !state.fetching.contains(service)
                        && state.paused_until.get(service).is_none_or(|until| now >= *until)
                        // The trackers ask for at most one request a minute.
                        && state.last_fetch.get(service).is_none_or(|last| seconds_between(*last, now) >= 60.0)
                })
                .collect();
            for &service in &due {
                state.fetching.insert(service);
                state.last_fetch.insert(service, now);
            }
            due
        };
        due.into_iter()
            .map(|service| {
                let watcher = self.clone();
                let tracked = services.to_vec();
                std::thread::spawn(move || {
                    let result = (watcher.fetch)(service, Utc::now());
                    let mut announce = Vec::new();
                    {
                        let mut state = watcher.lock();
                        state.fetching.remove(&service);
                        match result {
                            Ok(events) => {
                                state.rate_limit_streak.remove(&service);
                                announce = ingest(&mut state, events, service, Utc::now());
                            }
                            Err(FeedError::RateLimited(retry_after)) => {
                                let streak = state.rate_limit_streak.get(&service).copied().unwrap_or(0) + 1;
                                state.rate_limit_streak.insert(service, streak);
                                let pause = crate::store::rate_limit_pause(streak, retry_after);
                                state.paused_until.insert(service, now + chrono::Duration::milliseconds((pause * 1000.0) as i64));
                            }
                            // Offline or the site is down: keep what is shown, try at the next tick.
                            Err(FeedError::Failed(_)) => {}
                        }
                        watcher.save(&state.memory);
                    }
                    watcher.announce(announce, &tracked);
                    (watcher.on_change)();
                })
            })
            .collect()
    }

    /// Takes a tracker's events, as `refresh` does with what it fetched.
    pub fn ingest(&self, events: Vec<ResetEvent>, service: Service, tracked: &[Service], now: Timestamp) {
        let announce = {
            let mut state = self.lock();
            let announce = ingest(&mut state, events, service, now);
            self.save(&state.memory);
            announce
        };
        self.announce(announce, tracked);
    }

    /// Compares a service's numbers with the last ones seen: a weekly window that
    /// started over early, or a new Codex limit reset to redeem, is an event.
    pub fn observe(&self, service: Service, snapshot: Option<&LimitSnapshot>, details: Option<&AccountDetails>, now: Timestamp) {
        let announce = {
            let mut state = self.lock();
            let before = state.memory.clone();
            let mut recorded = Vec::new();
            if let Some((snapshot, weekly, resets_at)) =
                snapshot.and_then(|s| s.seven_day.and_then(|w| w.resets_at.map(|r| (s, w, r))))
            {
                let previous = state.memory.weekly.get(&service).copied();
                // An older snapshot (e.g. a stale local file) must not overwrite a newer one.
                if previous.is_none_or(|previous| snapshot.captured_at >= previous.captured_at) {
                    let current = WeeklyMark { resets_at, used_percent: weekly.used_percent, captured_at: snapshot.captured_at };
                    state.memory.weekly.insert(service, current);
                    if previous.is_some_and(|previous| is_early_weekly_reset(&previous, &current, now)) {
                        recorded.push(ResetEvent::new(
                            format!("early-{}-{}", service.id(), resets_at.timestamp()),
                            service,
                            ResetKind::EarlyWeekly,
                            snapshot.captured_at.min(now),
                            ResetSource::Local,
                        ));
                    }
                }
            }
            if let (Service::Codex, Some(count)) = (service, details.and_then(|d| d.limit_resets)) {
                let previous = state.memory.limit_resets;
                state.memory.limit_resets = Some(count);
                // Fewer is the user redeeming one.
                if previous.is_some_and(|previous| count > previous) {
                    recorded.push(ResetEvent::new(
                        format!("credit-{}", now.timestamp()),
                        Service::Codex,
                        ResetKind::NewBankedCredit { count },
                        now,
                        ResetSource::Local,
                    ));
                }
            }
            for event in &recorded {
                record(&mut state, event.clone(), now);
            }
            if state.memory != before {
                self.save(&state.memory);
            }
            recorded.into_iter().filter(|event| !is_echo(&state, event)).collect::<Vec<_>>()
        };
        self.announce(announce, &[service]);
    }

    fn announce(&self, events: Vec<ResetEvent>, tracked: &[Service]) {
        if events.is_empty() || !self.notifications_enabled() {
            return;
        }
        let Some(notify) = self.notify.lock().unwrap_or_else(|p| p.into_inner()).clone() else { return };
        let now = Utc::now();
        for event in events.iter().filter(|e| !e.provisional && e.is_shown(now) && tracked.contains(&e.service)) {
            notify(event);
        }
    }

    fn save(&self, memory: &Memory) {
        if let Some(parent) = self.file.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_vec_pretty(memory) {
            let _ = crate::claude_cache::write_atomically(&self.file, &json);
        }
    }
}

/// Shows a tracker's events and returns those to announce: the ones not seen before.
fn ingest(state: &mut State, events: Vec<ResetEvent>, service: Service, now: Timestamp) -> Vec<ResetEvent> {
    state.feed.insert(service, events.clone());
    let announce: Vec<ResetEvent> = match service {
        Service::Codex => {
            let Some(latest) = events.into_iter().max_by_key(|event| event.date) else { return Vec::new() };
            let Some(last) = state.memory.codex_last_reset else {
                state.memory.codex_last_reset = Some(latest.date);
                return Vec::new();
            };
            // Only a reset after the last one counts; an earlier date is a correction.
            if latest.date <= last {
                return Vec::new();
            }
            state.memory.codex_last_reset = Some(latest.date);
            vec![latest]
        }
        Service::Claude => {
            let confirmed: Vec<ResetEvent> = events.into_iter().filter(|event| !event.provisional).collect();
            let Some(seen) = state.memory.claude_seen.clone() else {
                // Nothing to record yet; the first reset to appear is news.
                if !confirmed.is_empty() {
                    state.memory.claude_seen = Some(confirmed.iter().map(|event| event.id.clone()).collect());
                }
                return Vec::new();
            };
            let new: Vec<ResetEvent> = confirmed.into_iter().filter(|event| !seen.contains(&event.id)).collect();
            let mut seen = seen;
            seen.extend(new.iter().map(|event| event.id.clone()));
            state.memory.claude_seen = Some(seen);
            // A batch of old events (e.g. the tracker backfilled) is recorded quietly.
            new.into_iter().filter(|event| event.is_shown(now)).collect()
        }
    };
    announce.into_iter().filter(|event| !is_echo(state, event)).collect()
}

fn record(state: &mut State, event: ResetEvent, now: Timestamp) {
    state.memory.local.retain(|old| old.is_shown(now) && !(old.service == event.service && old.kind.same_kind(&event.kind)));
    state.memory.local.push(event);
}

/// A reset for everyone also restarts the user's own weekly window: whichever of the two
/// is seen second is the same news.
fn is_echo(state: &State, event: &ResetEvent) -> bool {
    let window = 3.0 * 3600.0;
    let close = |other: &ResetEvent| seconds_between(other.date, event.date).abs() < window;
    match event.kind {
        ResetKind::EarlyWeekly => state.feed.get(&event.service).is_some_and(|feed| feed.iter().any(close)),
        ResetKind::Global | ResetKind::Banked { .. } => state
            .memory
            .local
            .iter()
            .any(|other| other.service == event.service && other.kind == ResetKind::EarlyWeekly && close(other)),
        ResetKind::NewBankedCredit { .. } => false,
    }
}

/// The window started over well before its scheduled reset, with a lower usage.
///
/// Guards against a wrong clock either way: the old reset must still be half an hour
/// away by the current clock (so a clock that jumped forward past it reads as a scheduled
/// reset), and the new one must not be a whole week after the old one (which is what a
/// scheduled reset looks like to a clock running behind).
pub fn is_early_weekly_reset(previous: &WeeklyMark, current: &WeeklyMark, now: Timestamp) -> bool {
    let week = 7.0 * 86400.0;
    let ahead = |from: Timestamp, to: Timestamp| seconds_between(from, to);
    ahead(now, previous.resets_at) > 30.0 * 60.0
        && ahead(previous.resets_at, current.resets_at) > 3600.0
        && ahead(previous.resets_at, current.resets_at) < week - 30.0 * 60.0
        && previous.used_percent - current.used_percent >= 5.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::LimitWindow;
    use crate::time::from_unix;

    fn at(seconds: f64) -> Timestamp {
        from_unix(1_800_000_000.0 + seconds).unwrap()
    }

    const HOUR: f64 = 3600.0;
    const DAY: f64 = 86400.0;

    fn watcher(dir: &std::path::Path) -> (ResetWatcher, Arc<Mutex<Vec<String>>>) {
        let watcher = ResetWatcher::new(
            dir.join("resets.json"),
            ServiceSettings { file: dir.join("settings.json") },
            Arc::new(|_, _| Ok(Vec::new())),
            Arc::new(|| {}),
        );
        let announced = Arc::new(Mutex::new(Vec::new()));
        let sink = announced.clone();
        watcher.set_notifier(Arc::new(move |event| sink.lock().unwrap().push(event.id.clone())));
        (watcher, announced)
    }

    fn codex(date: Timestamp) -> ResetEvent {
        ResetEvent::new(format!("codex-reset-{}", date.timestamp()), Service::Codex, ResetKind::Global, date, ResetSource::CodexReset)
    }

    #[test]
    fn parses_the_codex_forecast_and_its_alert() {
        let json = br#"{"last_reset_at":"2026-10-25T06:10:01.000Z","latest_alert":{"kind":"reset","url":"https://x.com/thsottiaux/status/1","observed_at":"2026-10-25T06:10:01.000Z"}}"#;
        let event = codex_forecast(json).unwrap();
        assert_eq!(event.date, parse_flexible("2026-10-25T06:10:01Z").unwrap());
        assert_eq!(event.url.as_deref(), Some("https://x.com/thsottiaux/status/1"));
        assert_eq!(event.kind, ResetKind::Global);

        let other_alert = br#"{"last_reset_at":"2026-10-25T06:10:01Z","latest_alert":{"kind":"reset","url":"https://x.com/1","observed_at":"2026-10-20T00:00:00Z"}}"#;
        assert_eq!(codex_forecast(other_alert).unwrap().url.as_deref(), Some("https://codex-reset.com"), "an alert about another reset is not linked");
        assert!(codex_forecast(br#"{"last_reset_at":null}"#).is_none());
        assert_eq!(parse(br#"{"mode":"model"}"#, Service::Codex).unwrap(), Vec::new());
        assert!(parse(b"<html>down</html>", Service::Codex).is_err(), "not JSON is a failure, not \"no events\"");
    }

    #[test]
    fn parses_claude_resets_newest_first() {
        let json = br#"{"providers":{"claude":{"events":[
            {"id":"1","date":"2026-09-01T18:35:27Z","kind":"reset","scope":"all","note":"Reset for all.","url":"https://x.com/a","verification":"curated"},
            {"id":"2","date":"2026-09-22T16:44:06Z","kind":"reset","resetType":"banked","usableUntil":"2026-10-22T23:59:59Z","scope":"Pro, Max + Team","verification":"curated"},
            {"id":"3","date":"2026-09-10T00:00:00Z","kind":"policy"},
            {"id":"4","date":"2026-10-01T00:00:00Z","kind":"reset","verification":"provisional"},
            {"date":"2026-10-02T00:00:00Z","kind":"reset"}
        ]}},"meta":{"provisionalEventIds":[]}}"#;
        let events = claude_resets(json);
        assert_eq!(events.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), ["claude-4", "claude-2", "claude-1"]);
        assert!(events[0].provisional);
        assert_eq!(events[1].kind, ResetKind::Banked { usable_until: parse_flexible("2026-10-22T23:59:59Z") });
        assert_eq!(events[1].url.as_deref(), Some("https://claude-resets.com"), "no post: the tracker");
        assert_eq!(events[2].note.as_deref(), Some("Reset for all."));
    }

    #[test]
    fn titles_and_visibility() {
        let now = at(0.0);
        let mut event = codex(at(-5.0 * HOUR));
        assert_eq!(event.title(now), "RESET FOR EVERYONE · 5 HOURS AGO");
        event.scope = Some("Max".into());
        assert_eq!(event.title(now), "RESET FOR MAX · 5 HOURS AGO");
        assert!(event.is_shown(now));
        assert!(!codex(at(-7.0 * DAY)).is_shown(now), "a week later the line is gone");

        let until = parse_flexible("2026-10-22T23:59:59Z").unwrap();
        let banked = ResetEvent::new("b".into(), Service::Claude, ResetKind::Banked { usable_until: Some(until) }, at(-30.0 * DAY), ResetSource::ClaudeResets);
        assert_eq!(banked.title(now), "BANKED RESET · USE BY OCT 22");
        assert!(banked.is_shown(until - chrono::Duration::seconds(1)), "shown while it can be applied");
        assert!(!banked.is_shown(until));
        assert_eq!(banked.notification_body(), "Use it by Oct 22.\nData: claude-resets.com");
        assert_eq!(codex(now).notification_title(), "Codex limits were reset for everyone");
    }

    #[test]
    fn the_first_look_records_and_later_resets_are_announced_once() {
        let dir = tempfile::tempdir().unwrap();
        let (watcher, announced) = watcher(dir.path());
        let now = Utc::now();
        let tracked = [Service::Codex];
        watcher.ingest(vec![codex(now - chrono::Duration::hours(30))], Service::Codex, &tracked, now);
        assert!(announced.lock().unwrap().is_empty(), "an old reset is shown, never announced");
        assert_eq!(latest(&watcher.events(), Service::Codex, now).map(|e| e.id.clone()), Some(codex(now - chrono::Duration::hours(30)).id));

        let fresh = codex(now - chrono::Duration::minutes(5));
        watcher.ingest(vec![fresh.clone()], Service::Codex, &tracked, now);
        watcher.ingest(vec![fresh.clone()], Service::Codex, &tracked, now);
        assert_eq!(*announced.lock().unwrap(), std::slice::from_ref(&fresh.id));

        // A relaunch remembers it.
        let (again, announced_again) = self::watcher(dir.path());
        again.ingest(vec![fresh], Service::Codex, &tracked, now);
        assert!(announced_again.lock().unwrap().is_empty());
    }

    #[test]
    fn claude_announces_new_confirmed_events_only() {
        let dir = tempfile::tempdir().unwrap();
        let (watcher, announced) = watcher(dir.path());
        let now = Utc::now();
        let event = |id: &str, hours: i64, provisional: bool| {
            let mut event = ResetEvent::new(id.into(), Service::Claude, ResetKind::Global, now - chrono::Duration::hours(hours), ResetSource::ClaudeResets);
            event.provisional = provisional;
            event
        };
        let tracked = [Service::Claude];
        watcher.ingest(vec![event("a", 900, false)], Service::Claude, &tracked, now);
        watcher.ingest(vec![event("b", 1, true), event("a", 900, false)], Service::Claude, &tracked, now);
        assert!(announced.lock().unwrap().is_empty(), "provisional is not announced");
        watcher.ingest(vec![event("b", 1, false), event("old", 2000, false)], Service::Claude, &tracked, now);
        assert_eq!(*announced.lock().unwrap(), ["b"], "a backfilled old event is recorded quietly");
        watcher.ingest(vec![event("c", 1, false)], Service::Claude, &[], now);
        assert_eq!(announced.lock().unwrap().len(), 1, "untracked services are not announced");
    }

    #[test]
    fn notifications_can_be_turned_off() {
        let dir = tempfile::tempdir().unwrap();
        let (watcher, announced) = watcher(dir.path());
        assert!(watcher.notifications_enabled());
        watcher.set_notifications_enabled(false);
        let now = Utc::now();
        watcher.ingest(vec![codex(now - chrono::Duration::hours(30))], Service::Codex, &[Service::Codex], now);
        watcher.ingest(vec![codex(now)], Service::Codex, &[Service::Codex], now);
        assert!(announced.lock().unwrap().is_empty());
        assert_eq!(latest(&watcher.events(), Service::Codex, now).map(|e| e.date), Some(codex(now).date), "the line still shows");
    }

    #[test]
    fn early_weekly_reset_rules() {
        let now = at(0.0);
        let mark = |resets_in: f64, used: f64| WeeklyMark { resets_at: at(resets_in), used_percent: used, captured_at: now };
        assert!(is_early_weekly_reset(&mark(3.0 * DAY, 60.0), &mark(7.0 * DAY, 0.0), now));
        assert!(!is_early_weekly_reset(&mark(10.0 * 60.0, 60.0), &mark(7.0 * DAY, 0.0), now), "a reset due anyway");
        assert!(!is_early_weekly_reset(&mark(3.0 * DAY, 60.0), &mark(3.0 * DAY + 600.0, 0.0), now), "the same window, a few minutes off");
        assert!(!is_early_weekly_reset(&mark(3.0 * DAY, 60.0), &mark(10.0 * DAY, 0.0), now), "a whole week later: a clock running behind");
        assert!(!is_early_weekly_reset(&mark(3.0 * DAY, 60.0), &mark(7.0 * DAY, 58.0), now), "usage did not drop");
    }

    #[test]
    fn notices_early_weekly_resets_and_new_codex_credits() {
        let dir = tempfile::tempdir().unwrap();
        let (watcher, announced) = watcher(dir.path());
        let now = Utc::now();
        let snapshot = |resets_in_days: i64, used: f64, captured: Timestamp| {
            LimitSnapshot::new(None, Some(LimitWindow::new(used, Some(now + chrono::Duration::days(resets_in_days)))), captured)
        };
        let details = |count| AccountDetails { limit_resets: Some(count), ..AccountDetails::default() };
        watcher.observe(Service::Codex, Some(&snapshot(3, 60.0, now)), Some(&details(1)), now);
        assert!(announced.lock().unwrap().is_empty(), "the first look only records");

        watcher.observe(Service::Codex, Some(&snapshot(7, 0.0, now)), Some(&details(2)), now);
        let ids = announced.lock().unwrap().clone();
        assert_eq!(ids.len(), 2, "{ids:?}");
        assert!(ids[0].starts_with("early-codex-") && ids[1].starts_with("credit-"));
        let events = watcher.events();
        let shown = latest(&events, Service::Codex, now).unwrap();
        assert!(matches!(shown.kind, ResetKind::EarlyWeekly | ResetKind::NewBankedCredit { .. }));

        watcher.observe(Service::Codex, None, Some(&details(1)), now);
        assert_eq!(announced.lock().unwrap().len(), 2, "redeeming one is not news");
        // An older snapshot does not overwrite the newer one.
        watcher.observe(Service::Codex, Some(&snapshot(3, 60.0, now - chrono::Duration::hours(1))), None, now);
        watcher.observe(Service::Codex, Some(&snapshot(7, 0.0, now)), None, now);
        assert_eq!(announced.lock().unwrap().len(), 2);
    }

    #[test]
    fn a_global_reset_and_the_users_own_are_one_piece_of_news() {
        let dir = tempfile::tempdir().unwrap();
        let (watcher, announced) = watcher(dir.path());
        let now = Utc::now();
        watcher.ingest(vec![codex(now - chrono::Duration::hours(40))], Service::Codex, &[Service::Codex], now);
        watcher.ingest(vec![codex(now - chrono::Duration::minutes(10))], Service::Codex, &[Service::Codex], now);
        let snapshot = |days: i64, used: f64| LimitSnapshot::new(None, Some(LimitWindow::new(used, Some(now + chrono::Duration::days(days)))), now);
        watcher.observe(Service::Codex, Some(&snapshot(3, 60.0)), None, now);
        watcher.observe(Service::Codex, Some(&snapshot(7, 0.0)), None, now);
        assert_eq!(announced.lock().unwrap().len(), 1, "{:?}", announced.lock().unwrap());
    }

    #[test]
    fn refresh_fetches_tracked_services_at_most_once_a_minute_and_pauses_after_a_429() {
        let dir = tempfile::tempdir().unwrap();
        let calls = Arc::new(Mutex::new(Vec::new()));
        let log = calls.clone();
        let watcher = ResetWatcher::new(
            dir.path().join("resets.json"),
            ServiceSettings { file: dir.path().join("settings.json") },
            Arc::new(move |service, _| {
                log.lock().unwrap().push(service);
                match service {
                    Service::Codex => Err(FeedError::RateLimited(None)),
                    Service::Claude => Ok(Vec::new()),
                }
            }),
            Arc::new(|| {}),
        );
        let now = Utc::now();
        let join = |handles: Vec<JoinHandle<()>>| handles.into_iter().for_each(|h| h.join().unwrap());
        join(watcher.refresh(&Service::ALL, now));
        join(watcher.refresh(&Service::ALL, now + chrono::Duration::seconds(30)));
        assert_eq!(calls.lock().unwrap().len(), 2, "once a minute");
        join(watcher.refresh(&Service::ALL, now + chrono::Duration::seconds(90)));
        let count = |service| calls.lock().unwrap().iter().filter(|&&s| s == service).count();
        assert_eq!((count(Service::Claude), count(Service::Codex)), (2, 1), "Codex is paused after its 429");
        join(watcher.refresh(&[], now + chrono::Duration::hours(1)));
        assert_eq!(calls.lock().unwrap().len(), 3, "untracked services are not asked");
    }

    #[test]
    fn feed_urls_can_be_overridden() {
        assert_eq!(feed_url(Service::Codex, |_| None), CODEX_URL);
        assert_eq!(feed_url(Service::Claude, |key| (key == "LIMITA_RESET_FEED_CLAUDE").then(|| "file:///tmp/r.json".into())), "file:///tmp/r.json");
        assert!(user_agent().starts_with("Limita/") && user_agent().ends_with("(+https://github.com/realfamousbae/limita)"));
    }
}
