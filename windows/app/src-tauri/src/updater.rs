//! Finds a newer Limita on GitHub Releases and installs it, with `tauri-plugin-updater`.
//! Port of `AppUpdater.swift`'s schedule and status.
//!
//! The release's `latest.json` names the installer and its signature; the plugin checks
//! the signature against the public key in `tauri.conf.json` before running it. Until a
//! release has `latest.json` (the release workflow adds it a few minutes after the
//! release is published), the check fails and nothing is offered.
//!
//! Checks run at launch and every 3 hours unless the user turned them off in Settings;
//! Check Now there works either way.

use std::sync::{mpsc, Arc, Mutex, MutexGuard};
use std::time::Duration;

use chrono::Utc;
use limita_core::settings::ServiceSettings;
use limita_core::time::Timestamp;
use serde::Serialize;
use tauri::{AppHandle, Emitter};
use tauri_plugin_updater::{Update, UpdaterExt};

pub const CHECK_INTERVAL: Duration = Duration::from_secs(3 * 60 * 60);

/// What the header's update button shows; `version` is `None` while there is no update.
#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateView {
    pub version: Option<String>,
    pub installing: bool,
    /// Why the last install failed.
    pub error: Option<String>,
    /// A check is under way, for Settings.
    pub checking: bool,
}

#[derive(Default)]
struct State {
    update: Option<Update>,
    view: UpdateView,
    /// When the feed last answered, and why the last check failed.
    last_checked: Option<Timestamp>,
    last_error: Option<String>,
}

/// What Settings → Updates shows.
pub struct Status {
    pub view: UpdateView,
    pub last_checked: Option<Timestamp>,
    pub last_error: Option<String>,
}

#[derive(Clone)]
pub struct Updater {
    app: AppHandle,
    state: Arc<Mutex<State>>,
    settings: ServiceSettings,
    /// Wakes the schedule, e.g. when automatic checks are turned back on.
    wake: Arc<Mutex<Option<mpsc::Sender<()>>>>,
}

impl Updater {
    pub fn new(app: AppHandle, settings: ServiceSettings) -> Self {
        Self { app, state: Arc::default(), settings, wake: Arc::default() }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn view(&self) -> UpdateView {
        self.lock().view.clone()
    }

    pub fn status(&self) -> Status {
        let state = self.lock();
        Status { view: state.view.clone(), last_checked: state.last_checked, last_error: state.last_error.clone() }
    }

    /// Whether GitHub is asked every `CHECK_INTERVAL`.
    pub fn auto_check(&self) -> bool {
        self.settings.auto_update_check()
    }

    /// Turning automatic checks on checks right away.
    pub fn set_auto_check(&self, enabled: bool) {
        if enabled == self.auto_check() {
            return;
        }
        self.settings.set_auto_update_check(enabled);
        if enabled {
            if let Some(wake) = self.wake.lock().unwrap_or_else(|p| p.into_inner()).as_ref() {
                let _ = wake.send(());
            }
        }
    }

    /// Checks now and then every `CHECK_INTERVAL`, while automatic checks are on.
    pub fn start(&self) {
        let (wake, woken) = mpsc::channel();
        *self.wake.lock().unwrap_or_else(|p| p.into_inner()) = Some(wake);
        let updater = self.clone();
        std::thread::Builder::new()
            .name("limita-update".into())
            .spawn(move || loop {
                if updater.auto_check() {
                    tauri::async_runtime::block_on(updater.check());
                }
                match woken.recv_timeout(CHECK_INTERVAL) {
                    Ok(()) => while woken.try_recv().is_ok() {},
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => return,
                }
            })
            .expect("spawn the update thread");
    }

    /// Asks the feed once. Offline, rate-limited or no `latest.json` yet: the dashboard
    /// stays quiet and Settings shows why.
    pub async fn check(&self) {
        {
            let mut state = self.lock();
            if state.view.installing || state.view.checking {
                return;
            }
            state.view.checking = true;
            self.emit(&state.view);
        }
        let result = async { self.app.updater()?.check().await }.await;
        let mut state = self.lock();
        state.view.checking = false;
        match result {
            Ok(found) => {
                state.last_checked = Some(Utc::now());
                state.last_error = None;
                let version = found.as_ref().map(|update| update.version.clone());
                if version != state.view.version {
                    state.view = UpdateView { version, installing: false, error: None, checking: false };
                    state.update = found;
                }
            }
            Err(error) => state.last_error = Some(error.to_string()),
        }
        self.emit(&state.view);
    }

    /// Downloads the installer and runs it. On Windows the installer closes Limita and
    /// opens the new version itself.
    pub async fn install(&self) {
        let update = {
            let mut state = self.lock();
            if state.view.installing {
                return;
            }
            let Some(update) = state.update.clone() else { return };
            state.view.installing = true;
            state.view.error = None;
            self.emit(&state.view);
            update
        };
        match update.download_and_install(|_, _| {}, || {}).await {
            Ok(()) => self.app.restart(),
            Err(error) => {
                let mut state = self.lock();
                state.view.installing = false;
                state.view.error = Some(error.to_string());
                self.emit(&state.view);
            }
        }
    }

    fn emit(&self, view: &UpdateView) {
        let _ = self.app.emit("update", view);
    }
}
