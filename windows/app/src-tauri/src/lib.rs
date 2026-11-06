//! Limita for Windows: Claude Code and Codex rate limits and the DeepSeek balance from
//! the tray.

mod hotkeys;
mod panel;
mod placement;
mod platform;
mod settings_window;
mod tray;
mod tray_icon;
mod updater;

use std::collections::BTreeMap;
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

use chrono::{Local, Utc};
use limita_core::activity::{self, ActivityReader};
use limita_core::hotkeys::{HotKeyAction, HotKeyBinding};
use limita_core::settings::ServiceSettings;
use limita_core::store::Store;
use limita_core::{deepseek_live, prime_time, view, Service, ServiceKind};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_notification::NotificationExt;

use hotkeys::HotKeyCenter;
use panel::{Mode, Panel};
use settings_window::SettingsState;
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
fn connect(service: String, app: AppHandle, store: State<'_, Store>) {
    if let Some(service) = Service::from_id(&service) {
        store.connect(service);
        settings_window::changed(&app);
    }
}

#[tauri::command(async)]
fn disconnect(service: String, app: AppHandle, store: State<'_, Store>) {
    if let Some(service) = Service::from_id(&service) {
        store.disconnect(service);
        settings_window::changed(&app);
    }
}

/// Checks the key with DeepSeek and stores it; the error says why it was not taken.
#[tauri::command(async)]
fn connect_deepseek(key: String, app: AppHandle, store: State<'_, Store>) -> Result<(), String> {
    let result = store.connect_deepseek(&key);
    settings_window::changed(&app);
    result
}

/// The dashboard's ⚙ and the connect prompt's DeepSeek row.
#[tauri::command(async)]
fn open_settings(tab: Option<String>, app: AppHandle) {
    settings_window::open(&app, tab.as_deref());
}

#[tauri::command(async)]
fn settings_state(
    app: AppHandle,
    store: State<'_, Store>,
    panel: State<'_, Arc<Panel>>,
    hotkeys: State<'_, Arc<HotKeyCenter>>,
    updater: State<'_, Updater>,
) -> SettingsState {
    settings_window::state(&app, &store, &panel, &hotkeys, &updater)
}

#[tauri::command(async)]
fn set_hover_pill(enabled: bool, app: AppHandle, panel: State<'_, Arc<Panel>>) {
    panel.set_hover_pill(enabled);
    settings_window::changed(&app);
}

#[tauri::command(async)]
fn set_floating(enabled: bool, app: AppHandle, panel: State<'_, Arc<Panel>>) {
    panel.set_floating(enabled);
    settings_window::changed(&app);
}

#[tauri::command(async)]
fn set_launch_at_login(enabled: bool, app: AppHandle) {
    let manager = app.autolaunch();
    let _ = if enabled { manager.enable() } else { manager.disable() };
    settings_window::changed(&app);
}

#[tauri::command(async)]
fn set_reset_notifications(enabled: bool, app: AppHandle, store: State<'_, Store>) {
    store.set_reset_notifications(enabled);
    settings_window::changed(&app);
}

#[tauri::command(async)]
fn set_balance_alerts(enabled: bool, app: AppHandle, store: State<'_, Store>) {
    store.set_balance_alerts(enabled);
    settings_window::changed(&app);
}

/// The low-balance alert as typed; empty turns it off.
#[tauri::command(async)]
fn set_low_balance(amount: String, app: AppHandle, store: State<'_, Store>) {
    store.set_low_balance_threshold(settings_window::parse_amount(&amount));
    settings_window::changed(&app);
}

#[tauri::command(async)]
fn set_live_interval(service: String, seconds: f64, app: AppHandle, store: State<'_, Store>) {
    if let Some(service) = Service::from_id(&service) {
        store.set_live_interval(service, seconds);
        settings_window::changed(&app);
    }
}

/// A key pressed while a shortcut is recorded: `key_code` is the browser's `keyCode`, the
/// Windows virtual-key code.
#[tauri::command(async)]
#[allow(clippy::too_many_arguments)]
fn set_hotkey(
    action: String,
    key_code: u32,
    ctrl: bool,
    alt: bool,
    shift: bool,
    win: bool,
    app: AppHandle,
    hotkeys: State<'_, Arc<HotKeyCenter>>,
) -> Result<(), String> {
    let action = HotKeyAction::from_id(&action).ok_or("Unknown shortcut")?;
    let binding = HotKeyBinding::from_key_press(key_code, ctrl, alt, shift, win)
        .filter(HotKeyBinding::is_valid)
        .ok_or("Press the key with Ctrl, Alt or Win")?;
    hotkeys.set(action, Some(binding));
    settings_window::changed(&app);
    Ok(())
}

#[tauri::command(async)]
fn clear_hotkey(action: String, app: AppHandle, hotkeys: State<'_, Arc<HotKeyCenter>>) {
    if let Some(action) = HotKeyAction::from_id(&action) {
        hotkeys.set(action, None);
        settings_window::changed(&app);
    }
}

#[tauri::command(async)]
fn reset_hotkey(action: String, app: AppHandle, hotkeys: State<'_, Arc<HotKeyCenter>>) {
    if let Some(action) = HotKeyAction::from_id(&action) {
        hotkeys.reset(action);
        settings_window::changed(&app);
    }
}

/// While a shortcut is recorded, the current ones must not fire.
#[tauri::command(async)]
fn suspend_hotkeys(suspended: bool, hotkeys: State<'_, Arc<HotKeyCenter>>) {
    hotkeys.suspend(suspended);
}

#[tauri::command(async)]
fn set_auto_update(enabled: bool, app: AppHandle, updater: State<'_, Updater>) {
    updater.set_auto_check(enabled);
    settings_window::changed(&app);
}

#[tauri::command]
async fn check_updates(updater: State<'_, Updater>) -> Result<(), ()> {
    updater.check().await;
    Ok(())
}

/// The links Settings shows. Rust picks the address; the webview only names which.
#[tauri::command(async)]
fn open_link(link: String, updater: State<'_, Updater>) {
    let url = match link.as_str() {
        "deepseek-keys" => Some(deepseek_live::KEYS_PAGE.to_string()),
        "release-notes" => updater
            .view()
            .version
            .map(|version| format!("https://github.com/realfamousbae/limita/releases/tag/v{version}")),
        _ => None,
    };
    if let Some(url) = url {
        platform::open_url(&url);
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
        enabled
            .iter()
            .map(|&service| match (service.kind(), days.get(&service)) {
                (ServiceKind::Limits, Some(days)) => activity::grid(service, days, period, today),
                // No local logs to count tokens in; the spending is in the column above.
                _ => activity::no_activity(service),
            })
            .collect()
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
            disconnect,
            connect_deepseek,
            open_settings,
            settings_state,
            set_hover_pill,
            set_floating,
            set_launch_at_login,
            set_reset_notifications,
            set_balance_alerts,
            set_low_balance,
            set_live_interval,
            set_hotkey,
            clear_hotkey,
            reset_hotkey,
            suspend_hotkeys,
            set_auto_update,
            check_updates,
            open_link,
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
            // New limit resets and a low or exhausted DeepSeek balance come as a Windows
            // notification. Clicking one starts Limita again, which the single-instance
            // plugin turns into opening the dashboard (unverified on a real machine).
            let notifier = app.handle().clone();
            store.set_reset_notifier(Arc::new(move |event| {
                let _ = notifier
                    .notification()
                    .builder()
                    .title(event.notification_title())
                    .body(event.notification_body())
                    .show();
            }));
            let notifier = app.handle().clone();
            store.set_balance_notifier(Arc::new(move |title, body| {
                let _ = notifier.notification().builder().title(title).body(body).show();
            }));
            app.manage(store.clone());
            app.manage(Arc::new(ActivityReader::default()));

            let handle = app.handle().clone();
            let updater = Updater::new(handle.clone(), store.settings().clone());
            app.manage(updater.clone());
            let panel = Panel::new(handle.clone(), store.clone());
            app.manage(panel.clone());
            let (dashboard_panel, hover_panel, floating_panel) = (panel.clone(), panel.clone(), panel.clone());
            let mut actions: BTreeMap<HotKeyAction, hotkeys::Action> = BTreeMap::new();
            actions.insert(HotKeyAction::Dashboard, Box::new(move || dashboard_panel.toggle_from_shortcut()));
            actions.insert(HotKeyAction::HoverPill, Box::new(move || hover_panel.toggle_hover_pill()));
            actions.insert(HotKeyAction::FloatingWindow, Box::new(move || floating_panel.toggle_floating()));
            let hint_app = handle.clone();
            let hotkeys = HotKeyCenter::start(store.settings().clone(), actions, move || {
                // The Show Limits hint follows the shortcut, whatever it is set to.
                if let (Some(tray), Some(hotkeys)) = (hint_app.try_state::<Arc<Tray>>(), hint_app.try_state::<Arc<HotKeyCenter>>()) {
                    tray.set_shortcut(hotkeys.dashboard_accelerator());
                }
            });
            app.manage(hotkeys.clone());
            let tray = Tray::create(&handle, &store, panel.clone(), hotkeys.dashboard_accelerator())?;
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
