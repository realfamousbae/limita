//! Limita for Windows: Claude Code and Codex rate limits from the tray.

mod panel;
mod placement;
mod platform;
mod tray;
mod tray_icon;
mod updater;

use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

use chrono::{Local, Utc};
use limita_core::activity::{self, ActivityReader};
use limita_core::settings::ServiceSettings;
use limita_core::store::Store;
use limita_core::{prime_time, view, Service};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_notification::NotificationExt;

use panel::{Mode, Panel};
use tray::Tray;
use updater::{UpdateView, Updater};

// Commands run on the async pool (`async`), off the main thread: the panel's lock can be held by
// the hover thread while it waits for the main thread (window calls), and a command
// blocking the main thread on that lock would deadlock.

/// Everything the webview renders.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Current {
    mode: Mode,
    hover_pill: bool,
    floating: bool,
    /// Shown next to the app name, so a screenshot tells which version it is.
    version: String,
    view: view::PanelView,
    update: UpdateView,
}

#[tauri::command(async)]
fn current(app: AppHandle, panel: State<'_, Arc<Panel>>, store: State<'_, Store>, updater: State<'_, Updater>) -> Current {
    Current {
        mode: panel.mode(),
        hover_pill: panel.hover_pill(),
        floating: panel.floating(),
        version: app.package_info().version.to_string(),
        view: view::panel(&store.snapshot(), Utc::now()),
        update: updater.view(),
    }
}

#[tauri::command]
async fn install_update(updater: State<'_, Updater>) -> Result<(), ()> {
    updater.install().await;
    Ok(())
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

/// A click on a column's reset line: the announcement, or with `site` the tracker.
#[tauri::command(async)]
fn open_reset(service: String, site: bool, store: State<'_, Store>) {
    if let Some(url) = Service::from_id(&service).and_then(|service| store.reset_link(service, site)) {
        platform::open_url(&url);
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
fn toggle_hover_pill(panel: State<'_, Arc<Panel>>) {
    panel.toggle_hover_pill();
}

#[tauri::command(async)]
fn toggle_floating(panel: State<'_, Arc<Panel>>) {
    panel.toggle_floating();
}

/// A press on the header of the floating dashboard: the user moves it.
#[tauri::command(async)]
fn start_drag(panel: State<'_, Arc<Panel>>) {
    panel.start_drag();
}

#[tauri::command(async)]
fn hide_panel(panel: State<'_, Arc<Panel>>) {
    panel.hide();
}

#[tauri::command(async)]
fn panel_resized(width: f64, height: f64, panel: State<'_, Arc<Panel>>) {
    panel.resized(width, height);
}

/// The activity panel under the dashboard. Logs are scanned only while it is open, on
/// request from the webview, never in the view loop.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ActivityPanel {
    expanded: bool,
    period: activity::Period,
    grids: Vec<activity::ActivityGrid>,
}

fn activity_panel(store: &Store, reader: &ActivityReader) -> ActivityPanel {
    let settings = ServiceSettings::default();
    let expanded = settings.activity_expanded();
    let period = settings.activity_period();
    let grids = if expanded {
        let enabled = store.snapshot().enabled;
        let today = Local::now().date_naive();
        let days = reader.read(&enabled, &Local);
        enabled.iter().map(|&service| activity::grid(service, &days[&service], period, today)).collect()
    } else {
        Vec::new()
    };
    ActivityPanel { expanded, period, grids }
}

#[tauri::command(async)]
fn activity(store: State<'_, Store>, reader: State<'_, Arc<ActivityReader>>) -> ActivityPanel {
    activity_panel(&store, &reader)
}

#[tauri::command(async)]
fn set_activity_expanded(expanded: bool, store: State<'_, Store>, reader: State<'_, Arc<ActivityReader>>) -> ActivityPanel {
    ServiceSettings::default().set_activity_expanded(expanded);
    activity_panel(&store, &reader)
}

#[tauri::command(async)]
fn set_activity_period(period: String, store: State<'_, Store>, reader: State<'_, Arc<ActivityReader>>) -> ActivityPanel {
    if let Some(period) = activity::Period::from_id(&period) {
        ServiceSettings::default().set_activity_period(period);
    }
    activity_panel(&store, &reader)
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
            let mut changes_at = view::reset_dates(&snapshot);
            changes_at.extend(prime_time::next_changes(now));
            let next = view::next_tick(now, &changes_at);
            let wait = (next - Utc::now()).to_std().unwrap_or(Duration::ZERO) + Duration::from_millis(20);
            match changes.recv_timeout(wait) {
                Ok(()) => while changes.try_recv().is_ok() {},
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            }
        })
        .expect("spawn the view thread");
}

const AUTOSTART_FLAG: &str = "--autostart";

pub fn run() {
    tauri::Builder::default()
        // Must come first: a second launch just opens the running app's dashboard.
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(panel) = app.try_state::<Arc<Panel>>() {
                let panel = panel.inner().clone();
                std::thread::spawn(move || panel.show_dashboard());
            }
        }))
        // Started at login, Limita gets `AUTOSTART_FLAG` and stays in the tray.
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, Some(vec![AUTOSTART_FLAG])))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_notification::init())
        .invoke_handler(tauri::generate_handler![
            current,
            refresh,
            connect,
            dismiss_setup,
            expand,
            hide_panel,
            toggle_hover_pill,
            toggle_floating,
            start_drag,
            panel_resized,
            activity,
            set_activity_expanded,
            set_activity_period,
            open_reset,
            install_update
        ])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let (changed, changes) = mpsc::channel();
            let store = Store::standard(cli_path(), move || {
                let _ = changed.send(());
            });
            store.repair_claude_hook_if_needed();
            // New limit resets come as a Windows notification. Clicking one starts Limita
            // again, which the single-instance plugin turns into opening the dashboard.
            let notifier = app.handle().clone();
            store.set_reset_notifier(Arc::new(move |event| {
                let _ = notifier
                    .notification()
                    .builder()
                    .title(event.notification_title())
                    .body(event.notification_body())
                    .show();
            }));
            app.manage(store.clone());
            app.manage(Arc::new(ActivityReader::default()));

            let handle = app.handle().clone();
            let updater = Updater::new(handle.clone());
            app.manage(updater.clone());
            let panel = Panel::new(handle.clone(), store.clone());
            app.manage(panel.clone());
            let dashboard_panel = panel.clone();
            let hover_panel = panel.clone();
            let floating_panel = panel.clone();
            let registered = platform::register_hotkeys(vec![
                platform::HotKey { letter: b'L', on_press: Box::new(move || dashboard_panel.toggle_from_shortcut()) },
                platform::HotKey { letter: b'H', on_press: Box::new(move || hover_panel.toggle_hover_pill()) },
                platform::HotKey { letter: b'P', on_press: Box::new(move || floating_panel.toggle_floating()) },
            ]);
            let tray = Tray::create(&handle, &store, panel.clone(), registered[0], registered[2])?;
            app.manage(tray.clone());

            if let Some(window) = app.get_webview_window(panel::WINDOW) {
                let blur_panel = panel.clone();
                // Moves go through one thread, in order, so the last one is what is saved.
                let (moved, moves) = mpsc::channel::<(i32, i32)>();
                let move_panel = panel.clone();
                std::thread::Builder::new()
                    .name("limita-moves".into())
                    .spawn(move || {
                        while let Ok(mut position) = moves.recv() {
                            while let Ok(newer) = moves.try_recv() {
                                position = newer;
                            }
                            move_panel.moved(position.0, position.1);
                        }
                    })
                    .expect("spawn the moves thread");
                window.on_window_event(move |event| match event {
                    WindowEvent::Focused(false) => {
                        let panel = blur_panel.clone();
                        std::thread::spawn(move || panel.blurred());
                    }
                    WindowEvent::Moved(position) => {
                        let _ = moved.send((position.x, position.y));
                    }
                    _ => {}
                });
            }

            run_view_loop(handle, store.clone(), tray, changes);
            panel.start_hover_tracking();
            store.start_auto_refresh();
            updater.start();

            // Login entries written before `AUTOSTART_FLAG` existed lack it; rewriting
            // the entry adds it.
            let autolaunch = app.autolaunch();
            if autolaunch.is_enabled().unwrap_or(false) {
                let _ = autolaunch.enable();
            }
            // Opened by hand (Start menu, a shortcut, or after an update): show the
            // dashboard, so a fresh start is never just an icon in the tray. At login only
            // a floating dashboard shows, since it is meant to be always there.
            if !std::env::args().any(|arg| arg == AUTOSTART_FLAG) || panel.floating() {
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(500));
                    panel.show_dashboard();
                });
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Limita");
}
