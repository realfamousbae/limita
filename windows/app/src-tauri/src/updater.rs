//! Finds a newer Limita on GitHub Releases and installs it, with `tauri-plugin-updater`.
//!
//! The release's `latest.json` names the installer and its signature; the plugin checks
//! the signature against the public key in `tauri.conf.json` before running it. Until a
//! release has `latest.json` (the release workflow adds it a few minutes after the
//! release is published), the check fails and nothing is offered.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter};
use tauri_plugin_updater::{Update, UpdaterExt};

const CHECK_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);

/// What the header's update button shows; `version` is `None` while there is no update.
#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateView {
    pub version: Option<String>,
    pub installing: bool,
    pub error: Option<String>,
}

#[derive(Default)]
struct State {
    update: Option<Update>,
    view: UpdateView,
}

#[derive(Clone)]
pub struct Updater {
    app: AppHandle,
    state: Arc<Mutex<State>>,
}

impl Updater {
    pub fn new(app: AppHandle) -> Self {
        Self { app, state: Arc::default() }
    }

    pub fn view(&self) -> UpdateView {
        self.state.lock().unwrap().view.clone()
    }

    /// Checks now and then every `CHECK_INTERVAL`.
    pub fn start(&self) {
        let updater = self.clone();
        std::thread::Builder::new()
            .name("limita-update".into())
            .spawn(move || loop {
                tauri::async_runtime::block_on(updater.check());
                std::thread::sleep(CHECK_INTERVAL);
            })
            .expect("spawn the update thread");
    }

    async fn check(&self) {
        if self.state.lock().unwrap().view.installing {
            return;
        }
        // Offline, rate-limited or no `latest.json` yet: try again at the next check.
        let Ok(found) = async { self.app.updater()?.check().await }.await else { return };
        let mut state = self.state.lock().unwrap();
        let version = found.as_ref().map(|update| update.version.clone());
        if version != state.view.version {
            state.view = UpdateView { version, installing: false, error: None };
            state.update = found;
            self.emit(&state.view);
        }
    }

    /// Downloads the installer and runs it. On Windows the installer closes Limita and
    /// opens the new version itself.
    pub async fn install(&self) {
        let update = {
            let mut state = self.state.lock().unwrap();
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
                let mut state = self.state.lock().unwrap();
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
