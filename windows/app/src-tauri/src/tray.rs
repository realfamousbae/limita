//! The tray icon and its menu. Port of the status item in `AppDelegate.swift`.
//!
//! Left click toggles the dashboard; right click opens the menu. As on macOS since
//! 0.24.0 the menu keeps what is used every day; everything else lives in Settings.

use std::sync::{Arc, Mutex};

use limita_core::store::Store;
use limita_core::view;
use tauri::image::Image;
use tauri::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Position, Size};

use crate::panel::Panel;
use crate::placement::Area;
use crate::tray_icon;

const SHOW: &str = "show";
const REFRESH: &str = "refresh";
const SETTINGS: &str = "settings";
const QUIT: &str = "quit";

/// Level, stale, light taskbar, tooltip: everything the icon is drawn from.
type Drawn = (Option<limita_core::LimitLevel>, bool, bool, String);

pub struct Tray {
    icon: TrayIcon,
    show: MenuItem<tauri::Wry>,
    /// What the icon shows now, to skip redrawing an identical one.
    shown: Mutex<Option<Drawn>>,
}

impl Tray {
    /// `shortcut`: the dashboard's shortcut while it works, shown next to Show Limits.
    pub fn create(app: &AppHandle, store: &Store, panel: Arc<Panel>, shortcut: Option<String>) -> tauri::Result<Arc<Self>> {
        let show = MenuItem::with_id(app, SHOW, "Show Limits", true, None::<&str>)?;
        let refresh = MenuItem::with_id(app, REFRESH, "Refresh", true, None::<&str>)?;
        let settings = MenuItem::with_id(app, SETTINGS, "Settings…", true, None::<&str>)?;
        let quit = MenuItem::with_id(app, QUIT, "Quit Limita", true, None::<&str>)?;

        let menu = Menu::new(app)?;
        menu.append(&show)?;
        menu.append(&refresh)?;
        menu.append(&PredefinedMenuItem::separator(app)?)?;
        menu.append(&settings)?;
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
                // Off the main thread; see the note on commands in lib.rs.
                std::thread::spawn(move || handle_menu(&app, &event, &store, &panel));
            })
            .build(app)?;

        let tray = Arc::new(Self { icon, show, shown: Mutex::new(Some((summary.level, summary.stale, light, summary.tooltip))) });
        tray.set_shortcut(shortcut);
        Ok(tray)
    }

    /// Only a hint: the shortcut itself works from any app, and may be changed or off.
    pub fn set_shortcut(&self, accelerator: Option<String>) {
        if self.show.set_accelerator(accelerator.as_deref()).is_err() {
            let _ = self.show.set_accelerator(None::<&str>);
        }
    }

    /// Redraws the icon and tooltip.
    pub fn update(&self, store: &Store) {
        let summary = view::tray(&store.snapshot(), chrono::Utc::now());
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

fn handle_menu(app: &AppHandle, event: &MenuEvent, store: &Store, panel: &Arc<Panel>) {
    match event.id().as_ref() {
        SHOW => panel.show_dashboard(),
        REFRESH => {
            store.refresh(true);
        }
        SETTINGS => crate::settings_window::open(app, None),
        QUIT => app.exit(0),
        _ => {}
    }
}
