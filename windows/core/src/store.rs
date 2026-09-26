//! The refresh loop and everything the UI shows. Port of `LimitsStore.swift`.
//!
//! Local sources (Codex session logs, Claude status-line cache) are cheap and read every
//! minute; each service's network API is asked every `live_interval` or on manual
//! refresh. Work runs on background threads; `on_change` fires after every update.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::Duration;

use chrono::Utc;

use crate::claude_cache::{self, ClaudeLimitsReader};
use crate::claude_live::ClaudeLiveClient;
use crate::codex_live::CodexLiveClient;
use crate::codex_reader::{self, CodexLimitsReader};
use crate::model::{AccountDetails, LimitSnapshot, LiveReading, Service, ServiceState};
use crate::settings::{self, ServiceSettings};
use crate::statusline::{self, Configurator};
use crate::time::{seconds_between, Timestamp};

pub const LOCAL_INTERVAL: f64 = 60.0;

pub fn live_interval(service: Service) -> f64 {
    match service {
        Service::Claude => 3.0 * 60.0,
        Service::Codex => 5.0 * 60.0,
    }
}

pub type LiveFetch = Arc<dyn Fn(Timestamp) -> Result<LiveReading, String> + Send + Sync>;

/// Everything the store reads from or writes to; tests swap in fakes.
#[derive(Clone)]
pub struct Sources {
    pub codex_reader: CodexLimitsReader,
    pub claude_reader: ClaudeLimitsReader,
    pub codex_live: LiveFetch,
    pub claude_live: LiveFetch,
    /// `None` when `limita-cli` is missing (a development build): Claude then works
    /// from the usage API alone.
    pub configurator: Option<Configurator>,
    pub settings: ServiceSettings,
}

impl Sources {
    /// The real sources, with `limita-cli` at `cli_path` when it exists.
    pub fn standard(cli_path: Option<std::path::PathBuf>) -> Self {
        let codex = CodexLiveClient::default();
        let claude = ClaudeLiveClient::default();
        Self {
            codex_reader: CodexLimitsReader::default(),
            claude_reader: ClaudeLimitsReader::default(),
            codex_live: Arc::new(move |now| codex.fetch(now)),
            claude_live: Arc::new(move |now| claude.fetch(now)),
            configurator: cli_path.filter(|p| p.is_file()).map(Configurator::new),
            settings: ServiceSettings::default(),
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
    pending_live: bool,
}

#[derive(Clone)]
pub struct Store {
    inner: Arc<Mutex<Inner>>,
    sources: Arc<Sources>,
    on_change: Arc<dyn Fn() + Send + Sync>,
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
        let mut inner = Inner::default();
        inner.public.enabled = Service::ALL.into_iter().filter(|s| enabled.contains(s)).collect();
        Self { inner: Arc::new(Mutex::new(inner)), sources: Arc::new(sources), on_change: Arc::new(on_change) }
    }

    /// The standard store for this machine.
    pub fn standard(cli_path: Option<std::path::PathBuf>, on_change: impl Fn() + Send + Sync + 'static) -> Self {
        Self::new(Sources::standard(cli_path), settings::detect_installed_here, on_change)
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn snapshot(&self) -> Snapshot {
        self.lock().public.clone()
    }

    pub fn is_enabled(&self, service: Service) -> bool {
        self.lock().public.enabled.contains(&service)
    }

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
        let (codex_on, claude_on, codex_live_due, claude_live_due) = {
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
            let is_due = |inner: &Inner, service: Service| {
                force_live
                    || inner
                        .last_live_attempt
                        .get(&service)
                        .is_none_or(|last| seconds_between(*last, now) >= live_interval(service) - slack)
            };
            let codex_on = inner.public.enabled.contains(&Service::Codex);
            let claude_on = inner.public.enabled.contains(&Service::Claude);
            let codex_due = codex_on && is_due(&inner, Service::Codex);
            let claude_due = claude_on && is_due(&inner, Service::Claude);
            inner.public.is_refreshing = true;
            if codex_due {
                inner.last_live_attempt.insert(Service::Codex, now);
            }
            if claude_due {
                inner.last_live_attempt.insert(Service::Claude, now);
            }
            (codex_on, claude_on, codex_due, claude_due)
        };
        (self.on_change)();

        let store = self.clone();
        Some(std::thread::spawn(move || {
            let sources = &store.sources;
            let (codex_local, claude_local, codex_remote, claude_remote) = std::thread::scope(|scope| {
                let codex_remote = codex_live_due.then(|| scope.spawn(|| (sources.codex_live)(Utc::now())));
                let claude_remote = claude_live_due.then(|| scope.spawn(|| (sources.claude_live)(Utc::now())));
                let codex_local = codex_on.then(|| sources.codex_reader.read(Utc::now()));
                let claude_local = claude_on.then(|| {
                    let hooked = hook_installed(sources.configurator.as_ref());
                    sources.claude_reader.read(hooked, Utc::now())
                });
                let join = |handle: std::thread::ScopedJoinHandle<'_, Result<LiveReading, String>>| {
                    handle.join().unwrap_or_else(|_| Err("the update crashed".into()))
                };
                (codex_local, claude_local, codex_remote.map(join), claude_remote.map(join))
            });

            let pending = {
                let mut inner = store.lock();
                // A service disconnected while this refresh ran must stay cleared.
                for (service, local, remote, stale_after) in [
                    (Service::Codex, codex_local, codex_remote, codex_reader::STALE_AFTER),
                    (Service::Claude, claude_local, claude_remote, claude_cache::STALE_AFTER),
                ] {
                    if !inner.public.enabled.contains(&service) {
                        continue;
                    }
                    apply(&mut inner, service, remote);
                    if let Some(local) = local {
                        let merged = merge(local, inner.live_snapshots.get(&service).copied(), stale_after);
                        inner.public.states.insert(service, merged);
                    }
                }
                inner.last_refresh = Some(Utc::now());
                inner.public.is_refreshing = false;
                std::mem::take(&mut inner.pending_live)
            };
            (store.on_change)();
            if pending {
                store.refresh(true);
            }
        }))
    }

    /// Starts tracking `service`. For Claude this also installs the status-line hook,
    /// which wraps any existing status line; its outcome is left in `setup_message`.
    pub fn connect(&self, service: Service) {
        if self.is_enabled(service) {
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
    }

    /// Stops tracking `service` and drops its data. For Claude this also removes the
    /// status-line hook and restores the previous status line.
    pub fn disconnect(&self, service: Service) {
        if !self.is_enabled(service) {
            return;
        }
        let failure = match (&self.sources.configurator, service) {
            (Some(configurator), Service::Claude) => configurator
                .uninstall()
                .err()
                .map(|error| format!("Could not restore the Claude Code status line: {error}")),
            _ => None,
        };
        {
            let mut inner = self.lock();
            if let Some(failure) = failure {
                inner.public.setup_message = Some((service, failure));
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
}

fn hook_installed(configurator: Option<&Configurator>) -> bool {
    matches!(configurator.map(Configurator::status), Some(Ok(statusline::Status::Installed { .. })))
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

fn apply(inner: &mut Inner, service: Service, result: Option<Result<LiveReading, String>>) {
    match result {
        Some(Ok(reading)) => {
            inner.live_snapshots.insert(service, reading.snapshot);
            inner.public.details.insert(service, reading.details);
            inner.public.live_errors.remove(&service);
        }
        // Keep the last good snapshot and extras; only record why this fetch failed.
        Some(Err(message)) => {
            inner.public.live_errors.insert(service, message);
        }
        None => {}
    }
}

/// Shows whichever of the local and network snapshots is newer.
fn merge(local: ServiceState, live: Option<LimitSnapshot>, stale_after: f64) -> ServiceState {
    let Some(live) = live else { return local };
    if local.snapshot().is_some_and(|l| l.captured_at >= live.captured_at) {
        return local;
    }
    ServiceState::from_snapshot(live, stale_after, Utc::now())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::LimitWindow;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn sources(root: &std::path::Path, claude_live: LiveFetch) -> Sources {
        Sources {
            codex_reader: CodexLimitsReader { sessions_dir: root.join("none"), archived_sessions_dir: root.join("none") },
            claude_reader: ClaudeLimitsReader { cache_file: root.join("claude.json") },
            codex_live: Arc::new(|_| Err("Codex CLI not found".into())),
            claude_live,
            configurator: Some(Configurator {
                settings_file: root.join("claude-settings.json"),
                executable: "/Apps/Limita/limita-cli.exe".into(),
                wrapped_file: root.join("wrapped.json"),
                stable_roots: vec!["/Apps".into()],
            }),
            settings: ServiceSettings { file: root.join("settings.json") },
        }
    }

    fn no_token() -> LiveFetch {
        Arc::new(|_| Err("no token in tests".into()))
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
                Err("Claude is rate-limiting usage requests".into())
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
        assert_eq!(second.live_errors[&Service::Claude], "Claude is rate-limiting usage requests");

        store.refresh(false).unwrap().join().unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2, "not due yet without force");
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
}
