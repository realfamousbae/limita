//! The tray icon and its menu. Port of the status item in `AppDelegate.swift`.
//!
//! Left click toggles the dashboard; right click opens the menu.

use std::sync::{Arc, Mutex};

use limita_core::store::Store;
use limita_core::{view, Service};
use tauri::image::Image;
use tauri::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, Position, Size};
use tauri_plugin_autostart::ManagerExt;

use crate::panel::Panel;
use crate::placement::Area;
use crate::tray_icon;

const SHOW: &str = "show";
const REFRESH: &str = "refresh";
const LOGIN: &str = "launch-at-login";
const RESET_NOTIFICATIONS: &str = "reset-notifications";
const FLOATING: &str = "floating-window";
const QUIT: &str = "quit";

/// Level, stale, light taskbar, tooltip: everything the icon is drawn from.
type Drawn = (Option<limita_core::LimitLevel>, bool, bool, String);

pub struct Tray {
    icon: TrayIcon,
    services: Vec<(Service, MenuItem<tauri::Wry>)>,
    floating: CheckMenuItem<tauri::Wry>,
    /// What the icon shows now, to skip redrawing an identical one.
    shown: Mutex<Option<Drawn>>,
}

pub fn menu_title(service: Service, connected: bool) -> String {
    format!("{} {}", if connected { "Disconnect" } else { "Connect" }, service.product_name())
}

impl Tray {
    /// `shortcut`, `floating_shortcut`: Ctrl+Alt+L and Ctrl+Alt+P were registered, so their
    /// items show them as a hint.
    pub fn create(app: &AppHandle, store: &Store, panel: Arc<Panel>, shortcut: bool, floating_shortcut: bool) -> tauri::Result<Arc<Self>> {
        let show = MenuItem::with_id(app, SHOW, "Show Limits", true, shortcut.then_some("Ctrl+Alt+L"))?;
        let floating =
            CheckMenuItem::with_id(app, FLOATING, "Floating Window", true, panel.floating(), floating_shortcut.then_some("Ctrl+Alt+P"))?;
        let refresh = MenuItem::with_id(app, REFRESH, "Refresh", true, None::<&str>)?;
        let services: Vec<_> = Service::ALL
            .into_iter()
            .map(|service| {
                MenuItem::with_id(app, service.id(), menu_title(service, store.is_enabled(service)), true, None::<&str>)
                    .map(|item| (service, item))
            })
            .collect::<tauri::Result<_>>()?;
        let at_login = app.autolaunch().is_enabled().unwrap_or(false);
        let login = CheckMenuItem::with_id(app, LOGIN, "Launch at Login", true, at_login, None::<&str>)?;
        let notifications =
            CheckMenuItem::with_id(app, RESET_NOTIFICATIONS, "Reset Notifications", true, store.reset_notifications(), None::<&str>)?;
        let quit = MenuItem::with_id(app, QUIT, "Quit Limita", true, None::<&str>)?;

        let menu = Menu::new(app)?;
        menu.append(&show)?;
        menu.append(&refresh)?;
        menu.append(&floating)?;
        menu.append(&PredefinedMenuItem::separator(app)?)?;
        for (_, item) in &services {
            menu.append(item)?;
        }
        menu.append(&PredefinedMenuItem::separator(app)?)?;
        menu.append(&notifications)?;
        menu.append(&login)?;
        menu.append(&PredefinedMenuItem::separator(app)?)?;
        menu.append(&quit)?;

        let summary = view::tray(&store.snapshot(), chrono::Utc::now());
        let light = tray_icon::light_taskbar();
        let click_panel = panel.clone();
        let menu_panel = panel;
        let menu_store = store.clone();
        let icon = TrayIconBuilder::with_id("limita")
            .icon(image(summary.level, summary.stale, light))
            .tooltip(&summary.tooltip)
            .menu(&menu)
            .show_menu_on_left_click(false)
            .on_tray_icon_event(move |tray, event| {
                if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, rect, .. } = event {
                    let scale = tray
                        .app_handle()
                        .primary_monitor()
                        .ok()
                        .flatten()
                        .map_or(1.0, |monitor| monitor.scale_factor());
                    let icon = physical(rect.position, rect.size, scale);
                    let panel = click_panel.clone();
                    // Off the main thread; see the note on commands in lib.rs.
                    std::thread::spawn(move || panel.toggle_from_tray(icon));
                }
            })
            .on_menu_event(move |app, event| {
                let (app, store, panel) = (app.clone(), menu_store.clone(), menu_panel.clone());
                let checks = (login.clone(), notifications.clone());
                // Off the main thread; see the note on commands in lib.rs.
                std::thread::spawn(move || handle_menu(&app, &event, &store, &panel, &checks));
            })
            .build(app)?;

        Ok(Arc::new(Self { icon, services, floating, shown: Mutex::new(Some((summary.level, summary.stale, light, summary.tooltip))) }))
    }

    /// Puts the Floating Window checkmark in step, however the mode was switched.
    pub fn set_floating(&self, enabled: bool) {
        let _ = self.floating.set_checked(enabled);
    }

    /// Redraws the icon and tooltip and retitles the Connect/Disconnect items.
    pub fn update(&self, store: &Store) {
        let snapshot = store.snapshot();
        for (service, item) in &self.services {
            let _ = item.set_text(menu_title(*service, snapshot.enabled.contains(service)));
        }
        let summary = view::tray(&snapshot, chrono::Utc::now());
        let light = tray_icon::light_taskbar();
        let key = (summary.level, summary.stale, light, summary.tooltip.clone());
        let mut shown = self.shown.lock().unwrap_or_else(|p| p.into_inner());
        if shown.as_ref() == Some(&key) {
            return;
        }
        let _ = self.icon.set_icon(Some(image(summary.level, summary.stale, light)));
        let _ = self.icon.set_tooltip(Some(&summary.tooltip));
        *shown = Some(key);
    }
}

fn image(level: Option<limita_core::LimitLevel>, stale: bool, light: bool) -> Image<'static> {
    Image::new_owned(tray_icon::render(level, stale, light), tray_icon::SIZE, tray_icon::SIZE)
}

fn physical(position: Position, size: Size, scale: f64) -> Area {
    let position = position.to_physical::<f64>(scale);
    let size = size.to_physical::<f64>(scale);
    Area::new(position.x, position.y, size.width, size.height)
}

/// Launch at Login and Reset Notifications, whose checkmarks follow the setting.
type Checks = (CheckMenuItem<tauri::Wry>, CheckMenuItem<tauri::Wry>);

fn handle_menu(app: &AppHandle, event: &MenuEvent, store: &Store, panel: &Arc<Panel>, (login, notifications): &Checks) {
    match event.id().as_ref() {
        SHOW => panel.show_dashboard(),
        // The click has already flipped the checkmark; put it in step with the mode.
        FLOATING => {
            panel.toggle_floating();
            app.state::<Arc<Tray>>().set_floating(panel.floating());
        }
        REFRESH => {
            store.refresh(true);
        }
        LOGIN => {
            let manager = app.autolaunch();
            let enable = !manager.is_enabled().unwrap_or(false);
            let _ = if enable { manager.enable() } else { manager.disable() };
            let _ = login.set_checked(manager.is_enabled().unwrap_or(enable));
        }
        RESET_NOTIFICATIONS => {
            store.set_reset_notifications(!store.reset_notifications());
            let _ = notifications.set_checked(store.reset_notifications());
        }
        QUIT => app.exit(0),
        id => {
            let Some(service) = Service::from_id(id) else { return };
            if store.is_enabled(service) {
                store.disconnect(service);
            } else {
                store.connect(service);
            }
            // From the menu there is nowhere else to show how connecting went.
            if store.snapshot().setup_message.is_some() {
                panel.show_dashboard();
            }
        }
    }
    app.state::<Arc<Tray>>().update(store);
}
