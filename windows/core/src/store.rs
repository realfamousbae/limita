//! The refresh loop and everything the UI shows. Port of `LimitsStore.swift`.
//!
//! Local sources (Codex session logs, Claude status-line cache) are cheap and read every
//! minute; each service's network API is asked every `live_interval` (the user may change
//! it in Settings) or on manual refresh. DeepSeek has only its network source, a balance,
//! and Limita's own history of it (`balance_ledger`). Work runs on background threads;
//! `on_change` fires after every update.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::Duration;

use chrono::{Local, Utc};

use crate::balance_ledger::{self, BalanceLedger};
use crate::claude_cache::{self, ClaudeLimitsReader};
use crate::claude_live::ClaudeLiveClient;
use crate::codex_live::CodexLiveClient;
use crate::codex_reader::{self, CodexLimitsReader};
use crate::deepseek_live::{self, DeepSeekClient};
use crate::live;
use crate::model::{AccountDetails, Balance, LimitSnapshot, LiveReading, Service, ServiceKind, ServiceState};
use crate::resets::{self, ResetEvent, ResetFetch, ResetWatcher};
use crate::secrets::{CredentialStore, SecretStore};
use crate::settings::{self, ServiceSettings};
use crate::statusline::{self, Configurator};
use crate::time::{seconds_between, Timestamp};

pub const LOCAL_INTERVAL: f64 = 60.0;

/// How often a service's network API is asked unless the user chose otherwise.
pub fn default_live_interval(service: Service) -> f64 {
    match service {
        Service::Claude => 3.0 * 60.0,
        Service::Codex | Service::DeepSeek => 5.0 * 60.0,
    }
}

/// The intervals Settings offers, in seconds. Nothing under a minute: local reads tick
/// once a minute anyway, and a busier poll only earns 429s.
pub const LIVE_INTERVAL_CHOICES: [f64; 7] = [60.0, 120.0, 180.0, 300.0, 600.0, 900.0, 1800.0];

pub type LiveFetch = Arc<dyn Fn(Timestamp) -> Result<LiveReading, String> + Send + Sync>;
/// A network source that asks with the user's key, such as DeepSeek's balance API.
pub type KeyedFetch = Arc<dyn Fn(&str, Timestamp) -> Result<LiveReading, String> + Send + Sync>;
/// Shows a notification: title, body.
pub type Alert = Arc<dyn Fn(&str, &str) + Send + Sync>;

/// Everything the store reads from or writes to; tests swap in fakes.
#[derive(Clone)]
pub struct Sources {
    pub codex_reader: CodexLimitsReader,
    pub claude_reader: ClaudeLimitsReader,
    pub codex_live: LiveFetch,
    pub claude_live: LiveFetch,
    pub deepseek_live: KeyedFetch,
    /// Where the DeepSeek API key is kept: the Credential Manager.
    pub deepseek_key: Arc<dyn SecretStore>,
    /// The DeepSeek balance history; `None` keeps it in memory (tests, `limita-cli --dump`).
    pub ledger_file: Option<PathBuf>,
    /// `None` when `limita-cli` is missing (a development build): Claude then works
    /// from the usage API alone.
    pub configurator: Option<Configurator>,
    pub settings: ServiceSettings,
    /// The public trackers of limit resets, and where what was seen of them is saved.
    pub reset_fetch: ResetFetch,
    pub resets_file: std::path::PathBuf,
}

impl Sources {
    /// The real sources, with `limita-cli` at `cli_path` when it exists.
    pub fn standard(cli_path: Option<std::path::PathBuf>) -> Self {
        let codex = CodexLiveClient::default();
        let claude = ClaudeLiveClient::default();
        let deepseek = DeepSeekClient;
        Self {
            codex_reader: CodexLimitsReader::default(),
            claude_reader: ClaudeLimitsReader::default(),
            codex_live: Arc::new(move |now| codex.fetch(now)),
            claude_live: Arc::new(move |now| claude.fetch(now)),
            deepseek_live: Arc::new(move |key, now| deepseek.fetch(key, now)),
            deepseek_key: Arc::new(CredentialStore::deepseek()),
            ledger_file: Some(balance_ledger::standard_file()),
            configurator: cli_path.filter(|p| p.is_file()).map(Configurator::new),
            settings: ServiceSettings::default(),
            reset_fetch: resets::standard_fetch(),
            resets_file: resets::standard_file(),
        }
    }
}

/// What the UI reads.
#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    /// Services the user tracks, in display order. Only these are read, fetched and shown.
    pub enabled: Vec<Service>,
    pub states: BTreeMap<Service, ServiceState>,
    /// Last network error per service; cleared by the next successful fetch.
    pub live_errors: BTreeMap<Service, String>,
    /// Balances and extras from the last successful network read.
    pub details: BTreeMap<Service, AccountDetails>,
    pub is_refreshing: bool,
    /// Result of the last connect/disconnect, for the service it concerns.
    pub setup_message: Option<(Service, String)>,
    /// Limit resets from the public trackers and from the user's own numbers; each
    /// column shows its newest one (`resets::latest`).
    pub resets: Vec<ResetEvent>,
}

impl Snapshot {
    pub fn state(&self, service: Service) -> ServiceState {
        self.states
            .get(&service)
            .cloned()
            .unwrap_or_else(|| ServiceState::Unavailable(format!("{} data not read yet", service.display_name())))
    }
}

#[derive(Default)]
struct Inner {
    public: Snapshot,
    /// Newest snapshot fetched over the network per service.
    live_snapshots: BTreeMap<Service, LimitSnapshot>,
    last_refresh: Option<Timestamp>,
    last_live_attempt: BTreeMap<Service, Timestamp>,
    /// After a 429 the service's network API is left alone until then, even by Refresh.
    live_paused_until: BTreeMap<Service, Timestamp>,
    /// 429s in a row per service; each one doubles the pause.
    rate_limit_streak: BTreeMap<Service, u32>,
    pending_live: bool,
    /// Intervals the user changed in Settings; read once, as `refresh` runs every minute.
    live_intervals: BTreeMap<Service, f64>,
    /// DeepSeek balance at or below which the dot turns red and a notification fires.
    low_balance_threshold: Option<f64>,
    /// Whether a low or exhausted DeepSeek balance is announced.
    balance_alerts: bool,
    ledger: BalanceLedger,
}

#[derive(Clone)]
pub struct Store {
    inner: Arc<Mutex<Inner>>,
    sources: Arc<Sources>,
    on_change: Arc<dyn Fn() + Send + Sync>,
    resets: ResetWatcher,
    /// How a low or exhausted DeepSeek balance is announced.
    alert: Arc<Mutex<Option<Alert>>>,
}

impl Store {
    pub fn new(
        sources: Sources,
        detect_installed: impl FnOnce() -> BTreeSet<Service>,
        on_change: impl Fn() + Send + Sync + 'static,
    ) -> Self {
        let configurator = sources.configurator.clone();
        let enabled = sources.settings.load(|| {
            let mut detected = detect_installed();
            // An existing status-line hook means the user already chose Claude.
            if hook_installed(configurator.as_ref()) {
                detected.insert(Service::Claude);
            }
            detected
        });
        let mut inner = Inner {
            live_intervals: sources.settings.live_intervals(),
            low_balance_threshold: sources.settings.low_balance_threshold(),
            balance_alerts: sources.settings.balance_alerts(),
            ledger: BalanceLedger::open(sources.ledger_file.clone()),
            ..Inner::default()
        };
        inner.public.enabled = Service::ALL.into_iter().filter(|s| enabled.contains(s)).collect();
        let on_change: Arc<dyn Fn() + Send + Sync> = Arc::new(on_change);
        let resets = ResetWatcher::new(
            sources.resets_file.clone(),
            sources.settings.clone(),
            sources.reset_fetch.clone(),
            on_change.clone(),
        );
        Self { inner: Arc::new(Mutex::new(inner)), sources: Arc::new(sources), on_change, resets, alert: Arc::default() }
    }

    /// The standard store for this machine.
    pub fn standard(cli_path: Option<std::path::PathBuf>, on_change: impl Fn() + Send + Sync + 'static) -> Self {
        Self::new(Sources::standard(cli_path), settings::detect_installed_here, on_change)
    }

    /// Where every setting is kept, for the ones the store does not own (the activity panel).
    pub fn settings(&self) -> &ServiceSettings {
        &self.sources.settings
    }

    pub fn hover_pill(&self) -> bool {
        self.sources.settings.hover_pill()
    }

    pub fn set_hover_pill(&self, enabled: bool) {
        self.sources.settings.set_hover_pill(enabled);
    }

    pub fn floating(&self) -> bool {
        self.sources.settings.floating()
    }

    pub fn set_floating(&self, enabled: bool) {
        self.sources.settings.set_floating(enabled);
    }

    pub fn floating_position(&self) -> Option<(i32, i32)> {
        self.sources.settings.floating_position()
    }

    pub fn set_floating_position(&self, position: (i32, i32)) {
        self.sources.settings.set_floating_position(position);
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn snapshot(&self) -> Snapshot {
        let mut snapshot = self.lock().public.clone();
        snapshot.resets = self.resets.events();
        snapshot
    }

    /// How new limit resets are announced, e.g. a system notification.
    pub fn set_reset_notifier(&self, notify: resets::Notify) {
        self.resets.set_notifier(notify);
    }

    /// How a low or exhausted DeepSeek balance is announced.
    pub fn set_balance_notifier(&self, alert: Alert) {
        *self.alert.lock().unwrap_or_else(|p| p.into_inner()) = Some(alert);
    }

    pub fn reset_notifications(&self) -> bool {
        self.resets.notifications_enabled()
    }

    pub fn set_reset_notifications(&self, enabled: bool) {
        self.resets.set_notifications_enabled(enabled);
    }

    /// Asks the reset trackers of the connected services. Returns the workers, which
    /// tests join.
    pub fn refresh_resets(&self) -> Vec<JoinHandle<()>> {
        let enabled = self.lock().public.enabled.clone();
        self.resets.refresh(&enabled, Utc::now())
    }

    /// Where a column's reset line leads: the announcement, or with `site` the tracker.
    pub fn reset_link(&self, service: Service, site: bool) -> Option<String> {
        let events = self.resets.events();
        let event = resets::latest(&events, service, Utc::now())?;
        if site {
            event.source.site().map(String::from)
        } else {
            event.url.clone()
        }
    }

    pub fn is_enabled(&self, service: Service) -> bool {
        self.lock().public.enabled.contains(&service)
    }

    // MARK: - Polling intervals

    /// How often `service`'s network API is asked, in seconds.
    pub fn live_interval(&self, service: Service) -> f64 {
        interval(&self.lock(), service)
    }

    /// Changes it, never under a minute; the default is not stored.
    pub fn set_live_interval(&self, service: Service, seconds: f64) {
        if !seconds.is_finite() {
            return;
        }
        let seconds = seconds.max(LOCAL_INTERVAL);
        let intervals = {
            let mut inner = self.lock();
            if (seconds - default_live_interval(service)).abs() < 0.5 {
                inner.live_intervals.remove(&service);
            } else {
                inner.live_intervals.insert(service, seconds);
            }
            inner.live_intervals.clone()
        };
        self.sources.settings.set_live_intervals(&intervals);
        (self.on_change)();
    }

    /// Age after which a service's data reads as stale. A service with only a network
    /// source allows two missed fetches at the chosen interval.
    pub fn stale_after(&self, service: Service) -> f64 {
        stale_after(&self.lock(), service)
    }

    // MARK: - Refreshing

    /// Refreshes now, then every minute, for the life of the process.
    pub fn start_auto_refresh(&self) {
        self.refresh(true);
        let store = self.clone();
        std::thread::Builder::new()
            .name("limita-refresh".into())
            .spawn(move || loop {
                std::thread::sleep(Duration::from_secs_f64(LOCAL_INTERVAL));
                store.refresh(false);
            })
            .expect("spawn the refresh thread");
        self.refresh_resets();
        let store = self.clone();
        std::thread::Builder::new()
            .name("limita-resets".into())
            .spawn(move || loop {
                std::thread::sleep(Duration::from_secs_f64(resets::POLL_INTERVAL));
                store.refresh_resets();
            })
            .expect("spawn the reset-tracker thread");
    }

    /// Re-reads local sources unless that happened within `max_age` seconds — for opening
    /// the panel.
    pub fn refresh_if_older(&self, max_age: f64) {
        let last = self.lock().last_refresh;
        if last.is_some_and(|last| seconds_between(last, Utc::now()) < max_age) {
            return;
        }
        self.refresh(false);
    }

    /// Reads local sources, and also asks the network for each service when `force_live`
    /// is set or its last network attempt is older than its `live_interval`. Disabled
    /// services are skipped. Returns the worker, which tests join.
    pub fn refresh(&self, force_live: bool) -> Option<JoinHandle<()>> {
        let now = Utc::now();
        let (enabled, due) = {
            let mut inner = self.lock();
            if inner.public.is_refreshing {
                // A manual refresh during a background local read must not be lost.
                if force_live {
                    inner.pending_live = true;
                }
                return None;
            }
            // Timer ticks drift, so allow half a tick of slack to keep an interval from
            // slipping by a whole tick.
            let slack = LOCAL_INTERVAL / 2.0;
            let enabled = inner.public.enabled.clone();
            let due: Vec<Service> = enabled
                .iter()
                .copied()
                .filter(|&service| {
                    if inner.live_paused_until.get(&service).is_some_and(|until| now < *until) {
                        return false;
                    }
                    force_live
                        || inner
                            .last_live_attempt
                            .get(&service)
                            .is_none_or(|last| seconds_between(*last, now) >= interval(&inner, service) - slack)
                })
                .collect();
            inner.public.is_refreshing = true;
            for &service in &due {
                inner.last_live_attempt.insert(service, now);
            }
            (enabled, due)
        };
        (self.on_change)();

        let store = self.clone();
        Some(std::thread::spawn(move || {
            let (mut locals, mut remotes) = std::thread::scope(|scope| {
                let worker = &store;
                let remotes: Vec<_> =
                    due.iter().map(|&service| (service, scope.spawn(move || worker.fetch_live(service, Utc::now())))).collect();
                let locals: BTreeMap<Service, ServiceState> =
                    enabled.iter().filter_map(|&service| Some((service, worker.read_local(service)?))).collect();
                let remotes: BTreeMap<Service, Result<LiveReading, String>> = remotes
                    .into_iter()
                    .map(|(service, handle)| (service, handle.join().unwrap_or_else(|_| Err("the update crashed".into()))))
                    .collect();
                (locals, remotes)
            });

            let (pending, observed, alerts) = {
                let mut inner = store.lock();
                let mut observed = Vec::new();
                let mut alerts = Vec::new();
                // A service disconnected while this refresh ran must stay cleared.
                for service in Service::ALL {
                    if !inner.public.enabled.contains(&service) {
                        continue;
                    }
                    alerts.extend(apply(&mut inner, service, remotes.remove(&service)));
                    let now = Utc::now();
                    if let Some(local) = locals.remove(&service) {
                        let stale_after = stale_after(&inner, service);
                        let merged = merge(local, inner.live_snapshots.get(&service).cloned(), stale_after, now);
                        inner.public.states.insert(service, merged);
                    } else if service.kind() == ServiceKind::Balance {
                        // Recomputed on every pass, so a balance nobody could fetch goes stale.
                        if let Some(state) = live_only_state(&inner, service, now) {
                            inner.public.states.insert(service, state);
                        }
                    }
                    if service.kind() == ServiceKind::Limits {
                        let snapshot = inner.public.states.get(&service).and_then(ServiceState::snapshot).cloned();
                        observed.push((service, snapshot, inner.public.details.get(&service).cloned()));
                    }
                }
                inner.last_refresh = Some(Utc::now());
                inner.public.is_refreshing = false;
                (std::mem::take(&mut inner.pending_live), observed, alerts)
            };
            store.announce(alerts);
            // A weekly window that started over early, or a new Codex limit reset.
            for (service, snapshot, details) in observed {
                store.resets.observe(service, snapshot.as_ref(), details.as_ref(), Utc::now());
            }
            (store.on_change)();
            if pending {
                store.refresh(true);
            }
        }))
    }

    /// The service's cheap local read, `None` for one with only a network source.
    fn read_local(&self, service: Service) -> Option<ServiceState> {
        match service {
            Service::Codex => Some(self.sources.codex_reader.read(Utc::now())),
            Service::Claude => {
                let hooked = hook_installed(self.sources.configurator.as_ref());
                Some(self.sources.claude_reader.read(hooked, Utc::now()))
            }
            Service::DeepSeek => None,
        }
    }

    fn fetch_live(&self, service: Service, now: Timestamp) -> Result<LiveReading, String> {
        match service {
            Service::Codex => (self.sources.codex_live)(now),
            Service::Claude => (self.sources.claude_live)(now),
            Service::DeepSeek => (self.sources.deepseek_live)(&self.deepseek_key()?, now),
        }
    }

    /// The stored key; against the fake server (`LIMITA_DEEPSEEK_API`) none is needed.
    fn deepseek_key(&self) -> Result<String, String> {
        match self.sources.deepseek_key.read()? {
            Some(key) if !key.is_empty() => Ok(key),
            _ if deepseek_live::api_override().is_some() => Ok("fake".into()),
            _ => Err(deepseek_live::MISSING_KEY.into()),
        }
    }

    fn announce(&self, alerts: Vec<(String, String)>) {
        if alerts.is_empty() {
            return;
        }
        let Some(alert) = self.alert.lock().unwrap_or_else(|p| p.into_inner()).clone() else { return };
        for (title, body) in alerts {
            alert(&title, &body);
        }
    }

    // MARK: - Connecting services

    /// Starts tracking `service`. For Claude this also installs the status-line hook,
    /// which wraps any existing status line; its outcome is left in `setup_message`.
    /// DeepSeek connects with a key: `connect_deepseek`, from Settings.
    pub fn connect(&self, service: Service) {
        if self.is_enabled(service) {
            return;
        }
        if service == Service::DeepSeek && self.deepseek_key_hint().is_none() {
            self.lock().public.setup_message = Some((service, deepseek_live::MISSING_KEY.into()));
            (self.on_change)();
            return;
        }
        let message = (service == Service::Claude).then(|| self.install_claude_hook()).flatten();
        {
            let mut inner = self.lock();
            if let Some(message) = message {
                inner.public.setup_message = Some((service, message));
            }
            set_enabled(&mut inner, &self.sources.settings, service, true);
        }
        (self.on_change)();
        self.refresh(true);
        self.refresh_resets();
    }

    /// Checks `api_key` with DeepSeek and, if it works, stores it in the Credential Manager
    /// and starts tracking DeepSeek (or switches to the new key). Returns why it did not
    /// work; a rejected key is never stored. Blocks for the request.
    pub fn connect_deepseek(&self, api_key: &str) -> Result<(), String> {
        let key = api_key.trim();
        if key.is_empty() {
            return Err("Enter a DeepSeek API key".into());
        }
        let now = Utc::now();
        let reading = (self.sources.deepseek_live)(key, now)?;
        // Another key may be another account: its history would read as spending.
        let replaced = self.sources.deepseek_key.read().ok().flatten().as_deref() != Some(key);
        if replaced {
            self.lock().ledger.clear();
        }
        self.sources.deepseek_key.save(key)?;
        let alert = {
            let mut inner = self.lock();
            if !inner.public.enabled.contains(&Service::DeepSeek) {
                set_enabled(&mut inner, &self.sources.settings, Service::DeepSeek, true);
            }
            if inner.public.setup_message.as_ref().is_some_and(|(service, _)| *service == Service::DeepSeek) {
                inner.public.setup_message = None;
            }
            inner.last_live_attempt.insert(Service::DeepSeek, now);
            let alert = apply(&mut inner, Service::DeepSeek, Some(Ok(reading)));
            if let Some(state) = live_only_state(&inner, Service::DeepSeek, Utc::now()) {
                inner.public.states.insert(Service::DeepSeek, state);
            }
            alert
        };
        self.announce(alert.into_iter().collect());
        (self.on_change)();
        Ok(())
    }

    /// The stored DeepSeek key as "sk-…1a2b", `None` without one. Reads the Credential Manager.
    pub fn deepseek_key_hint(&self) -> Option<String> {
        let key = self.sources.deepseek_key.read().ok().flatten().filter(|key| !key.is_empty())?;
        Some(deepseek_live::key_hint(&key))
    }

    /// Stops tracking `service` and drops its data. For Claude this also removes the
    /// status-line hook and restores the previous status line; for DeepSeek it removes
    /// the API key from the Credential Manager and the balance history.
    pub fn disconnect(&self, service: Service) {
        if !self.is_enabled(service) {
            return;
        }
        let failure = match (&self.sources.configurator, service) {
            (Some(configurator), Service::Claude) => configurator
                .uninstall()
                .err()
                .map(|error| format!("Could not restore the Claude Code status line: {error}")),
            (_, Service::DeepSeek) => self.sources.deepseek_key.delete().err(),
            _ => None,
        };
        {
            let mut inner = self.lock();
            if let Some(failure) = failure {
                inner.public.setup_message = Some((service, failure));
            }
            if service == Service::DeepSeek {
                inner.ledger.clear();
            }
            set_enabled(&mut inner, &self.sources.settings, service, false);
            inner.public.states.remove(&service);
            inner.public.live_errors.remove(&service);
            inner.public.details.remove(&service);
            inner.live_snapshots.remove(&service);
        }
        (self.on_change)();
    }

    pub fn take_setup_message(&self) -> Option<(Service, String)> {
        let message = self.lock().public.setup_message.take();
        if message.is_some() {
            (self.on_change)();
        }
        message
    }

    pub fn dismiss_setup_message(&self) {
        self.take_setup_message();
    }

    fn install_claude_hook(&self) -> Option<String> {
        let configurator = self.sources.configurator.as_ref()?;
        let hint = if configurator.is_running_from_stable_location() {
            ""
        } else {
            "\nLimita is not running from its installed location: install it and connect again."
        };
        Some(match configurator.install() {
            Ok(statusline::Outcome::Installed) => {
                format!("Connected. Limits appear right away; the status line adds a fallback.{hint}")
            }
            Ok(statusline::Outcome::Wrapped) => {
                format!("Connected. Your Claude Code status line is kept and works as before.{hint}")
            }
            Ok(statusline::Outcome::Updated) => format!("Connected. Updated the Limita path in Claude Code settings.{hint}"),
            Ok(statusline::Outcome::AlreadyConfigured) => "Connected.".into(),
            Err(error) => format!("Connected, but the status line was not set up: {error}"),
        })
    }

    /// Silently fixes a hook left pointing at a moved or deleted copy of the app.
    pub fn repair_claude_hook_if_needed(&self) {
        if !self.is_enabled(Service::Claude) {
            return;
        }
        if let Some(configurator) = &self.sources.configurator {
            let _ = configurator.repair_if_needed();
        }
    }

    // MARK: - DeepSeek balance

    /// The DeepSeek balance at or below which it counts as low; `None` while off.
    pub fn low_balance_threshold(&self) -> Option<f64> {
        self.lock().low_balance_threshold
    }

    /// Zero or less turns it off. A changed threshold shows at once, without waiting for
    /// the next fetch.
    pub fn set_low_balance_threshold(&self, threshold: Option<f64>) {
        let threshold = threshold.filter(|value| value.is_finite() && *value > 0.0);
        self.sources.settings.set_low_balance_threshold(threshold);
        {
            let mut inner = self.lock();
            inner.low_balance_threshold = threshold;
            if let Some(snapshot) = inner.live_snapshots.get(&Service::DeepSeek).cloned() {
                if let Some(mut balance) = snapshot.balance {
                    balance.low_threshold = threshold;
                    let low = balance.is_low();
                    inner.live_snapshots.insert(Service::DeepSeek, LimitSnapshot::with_balance(balance, snapshot.captured_at));
                    if let Some(state) = live_only_state(&inner, Service::DeepSeek, Utc::now()) {
                        inner.public.states.insert(Service::DeepSeek, state);
                    }
                    if !low {
                        inner.ledger.set_alerted_low(false);
                    }
                }
            }
        }
        (self.on_change)();
    }

    /// Whether a low or exhausted DeepSeek balance is announced.
    pub fn balance_alerts(&self) -> bool {
        self.lock().balance_alerts
    }

    pub fn set_balance_alerts(&self, enabled: bool) {
        self.lock().balance_alerts = enabled;
        self.sources.settings.set_balance_alerts(enabled);
        (self.on_change)();
    }
}

fn hook_installed(configurator: Option<&Configurator>) -> bool {
    matches!(configurator.map(Configurator::status), Some(Ok(statusline::Status::Installed { .. })))
}

fn interval(inner: &Inner, service: Service) -> f64 {
    inner.live_intervals.get(&service).copied().unwrap_or_else(|| default_live_interval(service)).max(LOCAL_INTERVAL)
}

fn stale_after(inner: &Inner, service: Service) -> f64 {
    match service {
        Service::Claude => claude_cache::STALE_AFTER,
        Service::Codex => codex_reader::STALE_AFTER,
        Service::DeepSeek => (2.0 * interval(inner, service) + LOCAL_INTERVAL).max(30.0 * 60.0),
    }
}

/// A service without a local source shows its last network reading, or why there is none.
fn live_only_state(inner: &Inner, service: Service, now: Timestamp) -> Option<ServiceState> {
    if let Some(snapshot) = inner.live_snapshots.get(&service) {
        return Some(ServiceState::from_snapshot(snapshot.clone(), stale_after(inner, service), now));
    }
    inner.public.live_errors.get(&service).map(|error| ServiceState::Unavailable(error.clone()))
}

fn set_enabled(inner: &mut Inner, settings: &ServiceSettings, service: Service, enabled: bool) {
    let mut set: BTreeSet<Service> = inner.public.enabled.iter().copied().collect();
    if enabled {
        set.insert(service);
    } else {
        set.remove(&service);
    }
    inner.public.enabled = Service::ALL.into_iter().filter(|s| set.contains(s)).collect();
    settings.save(&set);
}

/// Takes a fetch's result. Returns a notification to show, for a DeepSeek balance that
/// just went low or ran out.
fn apply(inner: &mut Inner, service: Service, result: Option<Result<LiveReading, String>>) -> Option<(String, String)> {
    match result {
        Some(Ok(reading)) => {
            let (reading, alert) = with_history(inner, reading);
            inner.live_snapshots.insert(service, reading.snapshot);
            inner.public.details.insert(service, reading.details);
            inner.public.live_errors.remove(&service);
            inner.rate_limit_streak.remove(&service);
            inner.live_paused_until.remove(&service);
            alert
        }
        Some(Err(message)) => {
            match live::rate_limit_of(&message).map(|(text, retry_after)| (text.to_string(), retry_after)) {
                Some((text, retry_after)) => {
                    let streak = inner.rate_limit_streak.get(&service).copied().unwrap_or(0) + 1;
                    inner.rate_limit_streak.insert(service, streak);
                    let pause = rate_limit_pause(streak, retry_after);
                    inner.live_paused_until.insert(service, Utc::now() + chrono::Duration::milliseconds((pause * 1000.0) as i64));
                    let minutes = (pause / 60.0).ceil() as u64;
                    inner.public.live_errors.insert(service, format!("{text}, trying again in {minutes} min"));
                }
                // Keep the last good snapshot and extras; only record why this fetch failed.
                None => {
                    inner.public.live_errors.insert(service, message);
                }
            }
            None
        }
        None => None,
    }
}

/// A balance reading with what the history says, after recording it there, and the
/// notification it calls for.
fn with_history(inner: &mut Inner, reading: LiveReading) -> (LiveReading, Option<(String, String)>) {
    let Some(balance) = reading.snapshot.balance.clone() else { return (reading, None) };
    let captured = reading.snapshot.captured_at;
    let summary = inner.ledger.record(balance.total, &balance.currency, captured, &Local);
    let full = balance.with_summary(summary, inner.low_balance_threshold);
    let alert = announce_balance(inner, &full);
    (LiveReading { snapshot: LimitSnapshot::with_balance(full, captured), details: reading.details }, alert)
}

/// One notification per drop below the threshold and per running out; each is armed
/// again once the balance recovers.
fn announce_balance(inner: &mut Inner, balance: &Balance) -> Option<(String, String)> {
    let name = Service::DeepSeek.display_name();
    if !balance.is_available {
        let alert = (!inner.ledger.alerted_unavailable() && inner.balance_alerts).then(|| {
            (
                format!("{name} balance ran out"),
                format!("API calls are rejected until you top up. {} left.", balance.format_amount(balance.total)),
            )
        });
        inner.ledger.set_alerted_unavailable(true);
        inner.ledger.set_alerted_low(true);
        return alert;
    }
    inner.ledger.set_alerted_unavailable(false);
    let Some(threshold) = balance.low_threshold.filter(|_| balance.is_low()) else {
        inner.ledger.set_alerted_low(false);
        return None;
    };
    let alert = (!inner.ledger.alerted_low() && inner.balance_alerts).then(|| {
        (
            format!("{name} balance is low"),
            format!("{} left, at or below your {} alert.", balance.format_amount(balance.total), balance.format_amount(threshold)),
        )
    });
    inner.ledger.set_alerted_low(true);
    alert
}

/// How long to leave a service's network API alone after its `streak`-th 429 in a row:
/// 5 minutes, doubling up to half an hour, or longer if the server asks.
pub fn rate_limit_pause(streak: u32, retry_after: Option<f64>) -> f64 {
    let backoff = (5.0 * 60.0 * 2f64.powi(streak.max(1) as i32 - 1)).min(30.0 * 60.0);
    backoff.max(retry_after.unwrap_or(0.0).min(2.0 * 60.0 * 60.0))
}

/// Shows whichever of the local and network snapshots is newer.
fn merge(local: ServiceState, live: Option<LimitSnapshot>, stale_after: f64, now: Timestamp) -> ServiceState {
    let Some(live) = live else { return local };
    match local.snapshot() {
        Some(newer) if newer.captured_at >= live.captured_at => {
            // Otherwise the per-model meters and the unlimited 5-hour meter would vanish
            // after every Claude Code reply.
            ServiceState::from_snapshot(newer.clone().keeping_live_data(live), stale_after, now)
        }
        _ => ServiceState::from_snapshot(live, stale_after, now),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::LimitWindow;
    use crate::secrets::MemorySecret;
    use crate::time::from_unix;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    fn sources(root: &std::path::Path, claude_live: LiveFetch) -> Sources {
        Sources {
            codex_reader: CodexLimitsReader { sessions_dir: root.join("none"), archived_sessions_dir: root.join("none") },
            claude_reader: ClaudeLimitsReader { cache_file: root.join("claude.json") },
            codex_live: Arc::new(|_| Err("Codex CLI not found".into())),
            claude_live,
            deepseek_live: Arc::new(|_, _| Err("no DeepSeek in tests".into())),
            deepseek_key: Arc::new(MemorySecret::default()),
            ledger_file: None,
            configurator: Some(Configurator {
                settings_file: root.join("claude-settings.json"),
                executable: "/Apps/Limita/limita-cli.exe".into(),
                wrapped_file: root.join("wrapped.json"),
                stable_roots: vec!["/Apps".into()],
            }),
            settings: ServiceSettings { file: root.join("settings.json") },
            reset_fetch: Arc::new(|_, _| Ok(Vec::new())),
            resets_file: root.join("resets.json"),
        }
    }

    fn no_token() -> LiveFetch {
        Arc::new(|_| Err("no token in tests".into()))
    }

    #[test]
    fn newer_status_line_keeps_the_missing_five_hour_limit() {
        let weekly = LimitWindow::new(40.0, None);
        let (old, now) = (from_unix(100.0).unwrap(), from_unix(200.0).unwrap());
        let live = LimitSnapshot::with_flag(None, Some(weekly), old, true);
        let status_line = LimitSnapshot::new(None, Some(weekly), now);
        let merged = merge(ServiceState::Fresh(status_line), Some(live.clone()), 3600.0, now);
        assert!(merged.snapshot().unwrap().has_no_five_hour_limit);

        let back = LimitSnapshot::new(Some(LimitWindow::new(5.0, None)), Some(weekly), now);
        let merged = merge(ServiceState::Fresh(back), Some(live), 3600.0, now);
        assert!(!merged.snapshot().unwrap().has_no_five_hour_limit, "a 5-hour window that came back wins");
    }

    #[test]
    fn newer_status_line_keeps_the_per_model_windows() {
        let at = |seconds: f64| crate::time::from_unix(seconds).unwrap();
        let fable = crate::model::ScopedWindow { name: "Fable".into(), is_weekly: true, window: LimitWindow::new(4.0, None), weekly_share: None };
        let live = LimitSnapshot::new(Some(LimitWindow::new(19.0, None)), Some(LimitWindow::new(3.0, None)), at(100.0))
            .with_scoped(vec![fable.clone()]);
        let local = LimitSnapshot::new(Some(LimitWindow::new(21.0, None)), Some(LimitWindow::new(3.0, None)), at(200.0));
        let merged = merge(ServiceState::Fresh(local), Some(live.clone()), 1800.0, at(210.0));
        let merged = merged.snapshot().unwrap();
        assert_eq!(merged.five_hour.unwrap().used_percent, 21.0, "the newer numbers win");
        assert_eq!(merged.scoped, [fable], "the Fable meter stays");
        assert_eq!(merge(ServiceState::Unavailable("x".into()), Some(live.clone()), 1800.0, at(210.0)).snapshot(), Some(&live));
    }

    #[test]
    fn connect_and_disconnect_persist_and_keep_claude_first() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let make = || Store::new(sources(root, no_token()), BTreeSet::new, || {});
        let store = make();
        assert!(store.snapshot().enabled.is_empty());

        store.connect(Service::Codex);
        store.connect(Service::Claude);
        assert_eq!(store.snapshot().enabled, [Service::Claude, Service::Codex], "Claude is always first");
        let hook = sources(root, no_token()).configurator.unwrap();
        assert!(matches!(hook.status().unwrap(), statusline::Status::Installed { .. }), "connecting Claude installs the hook");
        assert!(store.snapshot().setup_message.is_some());
        assert_eq!(make().snapshot().enabled, [Service::Claude, Service::Codex], "the choice survives a relaunch");

        store.disconnect(Service::Claude);
        assert_eq!(store.snapshot().enabled, [Service::Codex]);
        assert_eq!(hook.status().unwrap(), statusline::Status::NotConfigured, "disconnecting removes the hook");
        assert_eq!(make().snapshot().enabled, [Service::Codex]);
    }

    #[test]
    fn refresh_merges_newest_and_keeps_last_good_live_data() {
        let dir = tempfile::tempdir().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let counter = calls.clone();
        let live: LiveFetch = Arc::new(move |now| {
            if counter.fetch_add(1, Ordering::SeqCst) == 0 {
                Ok(LiveReading {
                    snapshot: LimitSnapshot::new(Some(LimitWindow::new(12.0, None)), None, now),
                    details: AccountDetails::default(),
                })
            } else {
                Err("Claude usage API returned 500".into())
            }
        });
        let store = Store::new(sources(dir.path(), live), || [Service::Claude].into(), || {});
        store.refresh(true).unwrap().join().unwrap();
        let first = store.snapshot();
        assert_eq!(first.state(Service::Claude).snapshot().unwrap().five_hour.unwrap().used_percent, 12.0);
        assert!(first.live_errors.is_empty());

        store.refresh(true).unwrap().join().unwrap();
        let second = store.snapshot();
        assert_eq!(second.state(Service::Claude).snapshot().unwrap().five_hour.unwrap().used_percent, 12.0, "kept");
        assert_eq!(second.live_errors[&Service::Claude], "Claude usage API returned 500");

        store.refresh(false).unwrap().join().unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2, "not due yet without force");
    }

    #[test]
    fn a_429_pauses_the_network_api_even_for_refresh() {
        let dir = tempfile::tempdir().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let counter = calls.clone();
        let live: LiveFetch = Arc::new(move |_| {
            counter.fetch_add(1, Ordering::SeqCst);
            Err(crate::claude_live::rate_limited(None))
        });
        let store = Store::new(sources(dir.path(), live), || [Service::Claude].into(), || {});
        store.refresh(true).unwrap().join().unwrap();
        assert_eq!(store.snapshot().live_errors[&Service::Claude], "Claude is rate-limiting usage requests, trying again in 5 min");
        store.refresh(true).unwrap().join().unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 1, "paused");

        assert_eq!(rate_limit_pause(1, None), 300.0);
        assert_eq!(rate_limit_pause(2, None), 600.0);
        assert_eq!(rate_limit_pause(9, None), 1800.0);
        assert_eq!(rate_limit_pause(1, Some(2700.0)), 2700.0);
        assert_eq!(rate_limit_pause(1, Some(99999.0)), 7200.0);
    }

    #[test]
    fn disabled_services_are_neither_read_nor_fetched() {
        let dir = tempfile::tempdir().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let counter = calls.clone();
        let live: LiveFetch = Arc::new(move |_| {
            counter.fetch_add(1, Ordering::SeqCst);
            Err("x".into())
        });
        let store = Store::new(sources(dir.path(), live), BTreeSet::new, || {});
        store.refresh(true).unwrap().join().unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert!(store.snapshot().states.is_empty());
    }

    /// Answers the balance request with `total` CNY, or with `error`.
    #[derive(Default)]
    struct FakeDeepSeek {
        total: Mutex<f64>,
        unavailable: AtomicBool,
        error: Mutex<Option<String>>,
        /// When the reading was taken, if not now.
        captured_at: Mutex<Option<Timestamp>>,
        keys: Mutex<Vec<String>>,
    }

    impl FakeDeepSeek {
        fn new(total: f64) -> Arc<Self> {
            let fake = Arc::new(Self::default());
            fake.set_total(total);
            fake
        }

        fn set_total(&self, total: f64) {
            *self.total.lock().unwrap() = total;
        }

        fn fetch(self: &Arc<Self>) -> KeyedFetch {
            let fake = self.clone();
            Arc::new(move |key, now| {
                fake.keys.lock().unwrap().push(key.to_string());
                if let Some(error) = fake.error.lock().unwrap().clone() {
                    return Err(error);
                }
                let total = *fake.total.lock().unwrap();
                let balance = crate::model::Balance::new("CNY", total, 0.0, total, !fake.unavailable.load(Ordering::SeqCst));
                let captured = fake.captured_at.lock().unwrap().unwrap_or(now);
                Ok(LiveReading { snapshot: LimitSnapshot::with_balance(balance, captured), details: AccountDetails::default() })
            })
        }
    }

    fn deepseek_store(root: &std::path::Path, fake: &Arc<FakeDeepSeek>, secret: &Arc<MemorySecret>) -> Store {
        let mut sources = sources(root, no_token());
        sources.deepseek_live = fake.fetch();
        sources.deepseek_key = secret.clone();
        Store::new(sources, BTreeSet::new, || {})
    }

    #[test]
    fn a_rejected_key_is_neither_stored_nor_connected() {
        let dir = tempfile::tempdir().unwrap();
        let fake = FakeDeepSeek::new(50.0);
        *fake.error.lock().unwrap() = Some("DeepSeek rejected the API key (401) — check it in Settings".into());
        let secret = Arc::new(MemorySecret::default());
        let store = deepseek_store(dir.path(), &fake, &secret);
        assert_eq!(store.connect_deepseek("  sk-wrong "), Err("DeepSeek rejected the API key (401) — check it in Settings".into()));
        assert_eq!(*fake.keys.lock().unwrap(), ["sk-wrong"], "the key is trimmed");
        assert_eq!(secret.read(), Ok(None));
        assert!(!store.is_enabled(Service::DeepSeek));
        assert_eq!(store.connect_deepseek(" "), Err("Enter a DeepSeek API key".into()));
    }

    #[test]
    fn connecting_deepseek_stores_the_key_and_shows_the_balance() {
        let dir = tempfile::tempdir().unwrap();
        let fake = FakeDeepSeek::new(50.0);
        let secret = Arc::new(MemorySecret::default());
        let store = deepseek_store(dir.path(), &fake, &secret);
        assert_eq!(store.connect_deepseek("sk-0123456789abcdef"), Ok(()));
        assert_eq!(secret.read(), Ok(Some("sk-0123456789abcdef".into())));
        let snapshot = store.snapshot();
        assert_eq!(snapshot.enabled, [Service::DeepSeek]);
        assert_eq!(snapshot.state(Service::DeepSeek).snapshot().unwrap().balance.as_ref().unwrap().total, 50.0);
        assert_eq!(store.deepseek_key_hint().as_deref(), Some("sk-…cdef"));
        let settings = std::fs::read_to_string(dir.path().join("settings.json")).unwrap();
        assert!(!settings.contains("0123456789abcdef"), "the key is not in settings.json");

        // The refresh loop asks with the stored key.
        store.refresh(true).unwrap().join().unwrap();
        assert_eq!(fake.keys.lock().unwrap().last().map(String::as_str), Some("sk-0123456789abcdef"));

        store.disconnect(Service::DeepSeek);
        assert_eq!(secret.read(), Ok(None), "disconnecting removes the key");
        assert!(store.snapshot().enabled.is_empty());
    }

    #[test]
    fn deepseek_cannot_connect_without_a_key() {
        let dir = tempfile::tempdir().unwrap();
        let store = deepseek_store(dir.path(), &FakeDeepSeek::new(1.0), &Arc::new(MemorySecret::default()));
        store.connect(Service::DeepSeek);
        assert!(!store.is_enabled(Service::DeepSeek));
        assert_eq!(store.snapshot().setup_message, Some((Service::DeepSeek, "Add your DeepSeek API key in Settings".into())));
    }

    #[test]
    fn a_lost_key_and_a_429_are_explained_in_the_column() {
        let dir = tempfile::tempdir().unwrap();
        let fake = FakeDeepSeek::new(10.0);
        let secret = Arc::new(MemorySecret::default());
        std::fs::write(dir.path().join("settings.json"), r#"{"enabledServices": ["deepseek"]}"#).unwrap();
        let store = deepseek_store(dir.path(), &fake, &secret);
        store.refresh(true).unwrap().join().unwrap();
        assert_eq!(store.snapshot().state(Service::DeepSeek), ServiceState::Unavailable("Add your DeepSeek API key in Settings".into()));
        assert!(fake.keys.lock().unwrap().is_empty(), "nothing is asked without a key");

        secret.save("sk-key").unwrap();
        *fake.error.lock().unwrap() = Some(live::rate_limited("DeepSeek is rate-limiting balance requests", None));
        store.refresh(true).unwrap().join().unwrap();
        assert_eq!(store.snapshot().live_errors[&Service::DeepSeek], "DeepSeek is rate-limiting balance requests, trying again in 5 min");
    }

    #[test]
    fn an_old_balance_goes_stale() {
        let dir = tempfile::tempdir().unwrap();
        let fake = FakeDeepSeek::new(10.0);
        *fake.captured_at.lock().unwrap() = Some(Utc::now() - chrono::Duration::hours(1));
        let store = deepseek_store(dir.path(), &fake, &Arc::new(MemorySecret::default()));
        store.connect_deepseek("sk-key").unwrap();
        assert!(store.snapshot().state(Service::DeepSeek).is_stale(), "older than half an hour");
        *fake.error.lock().unwrap() = Some("DeepSeek balance API returned 500".into());
        store.refresh(true).unwrap().join().unwrap();
        let snapshot = store.snapshot();
        assert!(snapshot.state(Service::DeepSeek).is_stale(), "the last balance stays, marked stale");
        assert_eq!(snapshot.live_errors[&Service::DeepSeek], "DeepSeek balance API returned 500");
    }

    #[test]
    fn low_balance_is_announced_once_per_drop() {
        let dir = tempfile::tempdir().unwrap();
        let fake = FakeDeepSeek::new(50.0);
        let store = deepseek_store(dir.path(), &fake, &Arc::new(MemorySecret::default()));
        let alerts = Arc::new(Mutex::new(Vec::<String>::new()));
        let recorded = alerts.clone();
        store.set_balance_notifier(Arc::new(move |title, _| recorded.lock().unwrap().push(title.to_string())));
        store.set_low_balance_threshold(Some(10.0));
        let titles = || alerts.lock().unwrap().clone();

        store.connect_deepseek("sk-key").unwrap();
        assert!(titles().is_empty());

        fake.set_total(8.0);
        store.connect_deepseek("sk-key").unwrap();
        store.connect_deepseek("sk-key").unwrap();
        assert_eq!(titles(), ["DeepSeek balance is low"], "once, not at every reading");
        assert_eq!(store.snapshot().state(Service::DeepSeek).level(Utc::now()), Some(crate::model::LimitLevel::Critical));

        fake.set_total(80.0);
        store.connect_deepseek("sk-key").unwrap();
        fake.set_total(5.0);
        store.connect_deepseek("sk-key").unwrap();
        assert_eq!(titles().len(), 2, "a top-up arms it again");

        fake.unavailable.store(true, Ordering::SeqCst);
        store.connect_deepseek("sk-key").unwrap();
        assert_eq!(titles().last().map(String::as_str), Some("DeepSeek balance ran out"));

        store.set_balance_alerts(false);
        fake.unavailable.store(false, Ordering::SeqCst);
        fake.set_total(90.0);
        store.connect_deepseek("sk-key").unwrap();
        fake.set_total(1.0);
        store.connect_deepseek("sk-key").unwrap();
        assert_eq!(titles().len(), 3, "alerts turned off");
    }

    #[test]
    fn a_changed_threshold_shows_at_once() {
        let dir = tempfile::tempdir().unwrap();
        let store = deepseek_store(dir.path(), &FakeDeepSeek::new(12.0), &Arc::new(MemorySecret::default()));
        store.connect_deepseek("sk-key").unwrap();
        let level = || store.snapshot().state(Service::DeepSeek).level(Utc::now());
        assert_eq!(level(), Some(crate::model::LimitLevel::Normal));
        store.set_low_balance_threshold(Some(20.0));
        let balance = store.snapshot().state(Service::DeepSeek).snapshot().unwrap().balance.clone().unwrap();
        assert_eq!(balance.low_threshold, Some(20.0));
        assert_eq!(level(), Some(crate::model::LimitLevel::Critical));
        store.set_low_balance_threshold(Some(-1.0));
        assert_eq!(store.low_balance_threshold(), None, "zero or less turns it off");
    }

    #[test]
    fn live_intervals_are_saved_and_have_a_floor() {
        let dir = tempfile::tempdir().unwrap();
        let make = || Store::new(sources(dir.path(), no_token()), BTreeSet::new, || {});
        let store = make();
        assert_eq!(store.live_interval(Service::Claude), 180.0);
        assert_eq!(store.live_interval(Service::DeepSeek), 300.0);
        store.set_live_interval(Service::Claude, 600.0);
        store.set_live_interval(Service::Codex, 10.0);
        assert_eq!(store.live_interval(Service::Codex), 60.0, "never under a minute");
        let reloaded = make();
        assert_eq!(reloaded.live_interval(Service::Claude), 600.0);
        reloaded.set_live_interval(Service::Claude, 180.0);
        assert!(!ServiceSettings { file: dir.path().join("settings.json") }.live_intervals().contains_key(&Service::Claude), "the default is not stored");
        assert_eq!(store.stale_after(Service::DeepSeek), 30.0 * 60.0);
        store.set_live_interval(Service::DeepSeek, 30.0 * 60.0);
        assert_eq!(store.stale_after(Service::DeepSeek), 61.0 * 60.0, "two missed fetches");
    }

    #[test]
    fn a_new_key_starts_the_history_over() {
        let dir = tempfile::tempdir().unwrap();
        let fake = FakeDeepSeek::new(40.0);
        let mut sources = sources(dir.path(), no_token());
        sources.deepseek_live = fake.fetch();
        sources.ledger_file = Some(dir.path().join("deepseek-balance.json"));
        let store = Store::new(sources, BTreeSet::new, || {});
        store.connect_deepseek("sk-first").unwrap();
        fake.set_total(30.0);
        store.connect_deepseek("sk-first").unwrap();
        let spent = || store.snapshot().state(Service::DeepSeek).snapshot().unwrap().balance.clone().unwrap().spent_today;
        assert_eq!(spent(), Some(10.0));
        store.connect_deepseek("sk-second").unwrap();
        assert_eq!(spent(), Some(0.0), "another account's history would read as spending");
        store.disconnect(Service::DeepSeek);
        assert!(!dir.path().join("deepseek-balance.json").exists(), "disconnecting removes the history");
    }
}
