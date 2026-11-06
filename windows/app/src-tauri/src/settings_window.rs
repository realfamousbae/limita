//! The Settings window: General, Providers, Shortcuts and Updates, as on macOS
//! (`SettingsView.swift`, `SettingsWindowController.swift`). Changes apply at once; there
//! is no Save.
//!
//! It is a second webview window, made when it is opened and destroyed when it is
//! closed, so its WebView2 processes are gone while nobody looks at settings.

use std::sync::Arc;

use chrono::Utc;
use limita_core::store::Store;
use limita_core::{deepseek_live, view, Service};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder, WindowEvent};
use tauri_plugin_autostart::ManagerExt;

use crate::hotkeys::{HotKeyCenter, ShortcutView};
use crate::panel::Panel;
use crate::updater::Updater;

pub const WINDOW: &str = "settings";
const TABS: [&str; 4] = ["general", "providers", "shortcuts", "updates"];

/// Opens the window on `tab` ("general", "providers", "shortcuts" or "updates"), or
/// where it was left. Call it off the main thread: on Windows, making a webview from a
/// synchronous command or event handler deadlocks.
pub fn open(app: &AppHandle, tab: Option<&str>) {
    let tab = tab.filter(|tab| TABS.contains(tab));
    // The dashboard would cover the window unless it floats where the user put it.
    if let Some(panel) = app.try_state::<Arc<Panel>>() {
        if !panel.floating() {
            panel.hide();
        }
    }
    if let Some(window) = app.get_webview_window(WINDOW) {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        if let Some(tab) = tab {
            let _ = window.emit("settings-tab", tab);
        }
        return;
    }
    let url = match tab {
        Some(tab) => format!("settings.html#{tab}"),
        None => "settings.html".to_string(),
    };
    let built = WebviewWindowBuilder::new(app, WINDOW, WebviewUrl::App(url.into()))
        .title("Limita Settings")
        .inner_size(600.0, 620.0)
        .min_inner_size(520.0, 420.0)
        .theme(Some(tauri::Theme::Dark))
        .maximizable(false)
        .center()
        .focused(true)
        .build();
    if let Ok(window) = built {
        let app = app.clone();
        window.on_window_event(move |event| {
            // A shortcut being recorded when the window closed must not stay suspended.
            if let WindowEvent::Destroyed = event {
                if let Some(hotkeys) = app.try_state::<Arc<HotKeyCenter>>() {
                    let hotkeys = hotkeys.inner().clone();
                    std::thread::spawn(move || hotkeys.suspend(false));
                }
            }
        });
    }
}

/// Tells an open Settings window to read its state again.
pub fn changed(app: &AppHandle) {
    let _ = app.emit("settings-changed", ());
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsState {
    general: General,
    providers: Vec<view::ProviderRow>,
    deepseek: DeepSeek,
    shortcuts: Vec<ShortcutView>,
    updates: Updates,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct General {
    hover_pill: bool,
    floating: bool,
    launch_at_login: bool,
    reset_notifications: bool,
    balance_alerts: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DeepSeek {
    /// "sk-…1a2b" of the stored key; the key itself never reaches the webview.
    key_hint: Option<String>,
    /// Running against `LIMITA_DEEPSEEK_API`, where no key is needed.
    fake: bool,
    /// The low-balance alert as typed back into its field, "5.00"; `None` while off.
    low_balance: Option<String>,
    /// The balance's currency, "CNY" until DeepSeek has said.
    currency: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Updates {
    /// The running version, "0.24.0".
    version: String,
    auto_check: bool,
    checking: bool,
    status: String,
    /// The newer version, when GitHub has one.
    available: Option<String>,
    installing: bool,
    /// Why the last install failed.
    error: Option<String>,
}

pub fn state(app: &AppHandle, store: &Store, panel: &Panel, hotkeys: &HotKeyCenter, updater: &Updater) -> SettingsState {
    let snapshot = store.snapshot();
    let now = Utc::now();
    let status = updater.status();
    let currency = snapshot
        .states
        .get(&Service::DeepSeek)
        .and_then(|state| state.snapshot())
        .and_then(|data| data.balance.as_ref())
        .map_or("CNY".to_string(), |balance| balance.currency.clone());
    SettingsState {
        general: General {
            hover_pill: panel.hover_pill(),
            floating: panel.floating(),
            launch_at_login: app.autolaunch().is_enabled().unwrap_or(false),
            reset_notifications: store.reset_notifications(),
            balance_alerts: store.balance_alerts(),
        },
        providers: view::provider_rows(&snapshot, now, |service| store.live_interval(service)),
        deepseek: DeepSeek {
            key_hint: store.deepseek_key_hint(),
            fake: deepseek_live::api_override().is_some(),
            low_balance: store.low_balance_threshold().map(|value| format!("{value:.2}")),
            currency,
        },
        shortcuts: hotkeys.views(),
        updates: Updates {
            version: app.package_info().version.to_string(),
            auto_check: updater.auto_check(),
            checking: status.view.checking,
            status: view::update_status(
                status.view.checking,
                status.last_error.as_deref(),
                status.view.version.is_some(),
                status.last_checked,
                now,
            ),
            available: status.view.version.clone(),
            installing: status.view.installing,
            error: status.view.error,
        },
    }
}

/// A threshold as typed: "5", "5.5" or "5,5"; empty, zero or less turns it off.
pub fn parse_amount(text: &str) -> Option<f64> {
    text.trim().replace(',', ".").parse::<f64>().ok().filter(|value| value.is_finite() && *value > 0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thresholds_are_read_as_typed() {
        assert_eq!(parse_amount(" 5 "), Some(5.0));
        assert_eq!(parse_amount("5,5"), Some(5.5));
        assert_eq!(parse_amount(""), None);
        assert_eq!(parse_amount("0"), None);
        assert_eq!(parse_amount("-3"), None);
        assert_eq!(parse_amount("lots"), None);
    }
}
