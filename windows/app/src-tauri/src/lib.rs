//! Limita for Windows: Claude Code and Codex rate limits from the tray.

mod panel;
mod placement;
mod platform;
mod tray;
mod tray_icon;

use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use limita_core::store::Store;
use limita_core::{view, Service};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};

use panel::{Mode, Panel};
use tray::Tray;

// Commands run on the async pool (`async`), off the main thread: the panel's lock can be held by
// the hover thread while it waits for the main thread (window calls), and a command
// blocking the main thread on that lock would deadlock.

/// Everything the webview renders.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Current {
    mode: Mode,
    view: view::PanelView,
}

#[tauri::command(async)]
fn current(panel: State<'_, Arc<Panel>>, store: State<'_, Store>) -> Current {
    Current { mode: panel.mode(), view: view::panel(&store.snapshot(), Utc::now()) }
}

#[tauri::command(async)]
fn refresh(store: State<'_, Store>) {
    store.refresh(true);
}

#[tauri::command(async)]
fn connect(service: String, store: State<'_, Store>) {
    if let Some(service) = Service::from_id(&service) {
        store.connect(service);
    }
}

#[tauri::command(async)]
fn dismiss_setup(store: State<'_, Store>) {
    store.dismiss_setup_message();
}

#[tauri::command(async)]
fn expand(panel: State<'_, Arc<Panel>>) {
    panel.expand();
}

#[tauri::command(async)]
fn hide_panel(panel: State<'_, Arc<Panel>>) {
    panel.hide();
}

#[tauri::command(async)]
fn panel_resized(width: f64, height: f64, panel: State<'_, Arc<Panel>>) {
    panel.resized(width, height);
}

/// `limita-cli` next to the app; Claude Code runs it as its status line.
fn cli_path() -> Option<std::path::PathBuf> {
    let name = if cfg!(windows) { "limita-cli.exe" } else { "limita-cli" };
    Some(std::env::current_exe().ok()?.parent()?.join(name))
}

/// Re-renders on every store change and whenever a countdown or "UPDATED …" would
/// change by itself.
fn run_view_loop(app: AppHandle, store: Store, tray: Arc<Tray>, changes: mpsc::Receiver<()>) {
    std::thread::Builder::new()
        .name("limita-view".into())
        .spawn(move || loop {
            let snapshot = store.snapshot();
            let now = Utc::now();
            let _ = app.emit("view", view::panel(&snapshot, now));
            tray.update(&store);
            let next = view::next_tick(now, &view::reset_dates(&snapshot));
            let wait = (next - Utc::now()).to_std().unwrap_or(Duration::ZERO) + Duration::from_millis(20);
            match changes.recv_timeout(wait) {
                Ok(()) => while changes.try_recv().is_ok() {},
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            }
        })
        .expect("spawn the view thread");
}

pub fn run() {
    tauri::Builder::default()
        // Must come first: a second launch just opens the running app's dashboard.
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(panel) = app.try_state::<Arc<Panel>>() {
                let panel = panel.inner().clone();
                std::thread::spawn(move || panel.show_dashboard());
            }
        }))
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, None))
        .invoke_handler(tauri::generate_handler![
            current,
            refresh,
            connect,
            dismiss_setup,
            expand,
            hide_panel,
            panel_resized
        ])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let (changed, changes) = mpsc::channel();
            let store = Store::standard(cli_path(), move || {
                let _ = changed.send(());
            });
            store.repair_claude_hook_if_needed();
            app.manage(store.clone());

            let handle = app.handle().clone();
            let panel = Panel::new(handle.clone(), store.clone());
            app.manage(panel.clone());
            let tray = Tray::create(&handle, &store, panel.clone())?;
            app.manage(tray.clone());

            if let Some(window) = app.get_webview_window(panel::WINDOW) {
                let blur_panel = panel.clone();
                window.on_window_event(move |event| {
                    if let WindowEvent::Focused(false) = event {
                        let panel = blur_panel.clone();
                        std::thread::spawn(move || panel.blurred());
                    }
                });
            }

            run_view_loop(handle, store.clone(), tray, changes);
            panel.start_hover_tracking();
            store.start_auto_refresh();
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Limita");
}
