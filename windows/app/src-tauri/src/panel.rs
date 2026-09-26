//! The floating panel: the hover pill and the dashboard share one window, as on macOS.
//! Port of `BezelPanelController.swift`.
//!
//! - Resting the cursor at the top edge of a screen shows a compact pill there; clicking
//!   it expands the dashboard. Moving away hides either again.
//! - The tray icon opens the dashboard next to it; clicking elsewhere closes it.
//!
//! The webview renders whatever mode it is told and reports the size it needs; the panel
//! is sized and placed here, in physical pixels of the target monitor.

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use limita_core::store::Store;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewWindow};

use crate::placement::{Area, Screen};

pub const WINDOW: &str = "panel";

/// How long the cursor must rest at the edge, so passing through does not pop the pill.
const DWELL: Duration = Duration::from_millis(300);
const HIDE_DELAY: Duration = Duration::from_millis(700);
/// A tray click right after a blur-hide is the click that caused the blur: it closes.
const BLUR_GRACE: Duration = Duration::from_millis(400);
const POLL: Duration = Duration::from_millis(80);
/// If the webview has not reported its size by then, the panel is shown at the last
/// known size rather than not at all.
const SIZE_TIMEOUT: Duration = Duration::from_millis(500);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    Hidden,
    Pill,
    Dashboard,
}

#[derive(Clone, Copy, Debug)]
enum Anchor {
    /// Hanging from the top edge of `screen`, centred on `x`.
    Top { screen: Screen, x: f64 },
    /// Next to the tray icon.
    Tray { screen: Screen, icon: Area },
}

impl Anchor {
    fn screen(&self) -> Screen {
        match self {
            Anchor::Top { screen, .. } | Anchor::Tray { screen, .. } => *screen,
        }
    }

    fn frame(&self, logical: (f64, f64)) -> Area {
        let scale = self.screen().scale;
        let size = ((logical.0 * scale).round(), (logical.1 * scale).round());
        match self {
            Anchor::Top { screen, x } => screen.below_top(size, *x),
            Anchor::Tray { screen, icon } => screen.beside_tray(size, *icon),
        }
    }
}

struct State {
    mode: Mode,
    /// Opened from the pill: follows the cursor. From the tray: stays until a click outside.
    hover_driven: bool,
    anchor: Option<Anchor>,
    /// Size the webview last reported for the current mode, in logical pixels.
    size: Option<(f64, f64)>,
    /// Where the window is, once placed.
    frame: Option<Area>,
    /// Shown as soon as the webview reports its size for the new mode.
    pending_show: bool,
    mode_changed_at: Option<Instant>,
    /// Last reported size per mode, for when a report does not arrive.
    last_sizes: std::collections::HashMap<Mode, (f64, f64)>,
    dwell_started: Option<Instant>,
    outside_since: Option<Instant>,
    blur_hidden_at: Option<Instant>,
    last_tray_icon: Option<Area>,
    screens: Vec<Screen>,
    screens_read_at: Option<Instant>,
}

pub struct Panel {
    app: AppHandle,
    store: Store,
    state: Mutex<State>,
}

#[derive(Clone, Serialize)]
pub struct ModePayload {
    pub mode: Mode,
}

impl Panel {
    pub fn new(app: AppHandle, store: Store) -> Arc<Self> {
        Arc::new(Self {
            app,
            store,
            state: Mutex::new(State {
                mode: Mode::Hidden,
                hover_driven: false,
                anchor: None,
                size: None,
                frame: None,
                pending_show: false,
                mode_changed_at: None,
                last_sizes: std::collections::HashMap::new(),
                dwell_started: None,
                outside_since: None,
                blur_hidden_at: None,
                last_tray_icon: None,
                screens: Vec::new(),
                screens_read_at: None,
            }),
        })
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn window(&self) -> Option<WebviewWindow> {
        self.app.get_webview_window(WINDOW)
    }

    pub fn mode(&self) -> Mode {
        self.lock().mode
    }

    // MARK: - Entry points

    /// Left click on the tray icon: toggles the dashboard next to it.
    pub fn toggle_from_tray(&self, icon: Area) {
        let mut state = self.lock();
        state.last_tray_icon = Some(icon);
        if state.mode == Mode::Dashboard && !state.hover_driven {
            drop(state);
            self.hide();
            return;
        }
        if state.blur_hidden_at.is_some_and(|at| at.elapsed() < BLUR_GRACE) {
            return;
        }
        let Some(screen) = screen_containing(&self.screens(&mut state), icon.x + icon.width / 2.0, icon.y + icon.height / 2.0)
        else {
            return;
        };
        self.transition(&mut state, Mode::Dashboard, false, Some(Anchor::Tray { screen, icon }));
    }

    /// "Show Limits" from the menu, or a second launch: the dashboard at the tray icon,
    /// or under the cursor before the tray has been clicked.
    pub fn show_dashboard(&self) {
        let mut state = self.lock();
        let screens = self.screens(&mut state);
        let anchor = match state.last_tray_icon {
            Some(icon) => screen_containing(&screens, icon.x + icon.width / 2.0, icon.y + icon.height / 2.0)
                .map(|screen| Anchor::Tray { screen, icon }),
            None => self.app.cursor_position().ok().and_then(|cursor| {
                screen_containing(&screens, cursor.x, cursor.y).map(|screen| Anchor::Top { screen, x: cursor.x })
            }),
        };
        let Some(anchor) = anchor.or_else(|| screens.first().map(|&screen| Anchor::Top { screen, x: screen.frame.x + screen.frame.width / 2.0 })) else {
            return;
        };
        self.transition(&mut state, Mode::Dashboard, false, Some(anchor));
    }

    /// The pill was clicked.
    pub fn expand(&self) {
        let mut state = self.lock();
        if state.mode == Mode::Pill {
            let anchor = state.anchor;
            self.transition(&mut state, Mode::Dashboard, true, anchor);
        }
    }

    pub fn hide(&self) {
        let mut state = self.lock();
        self.transition(&mut state, Mode::Hidden, false, None);
    }

    /// The window lost focus: a tray-opened dashboard closes, as a click elsewhere should.
    pub fn blurred(&self) {
        let mut state = self.lock();
        if state.mode == Mode::Dashboard && !state.hover_driven {
            state.blur_hidden_at = Some(Instant::now());
            self.transition(&mut state, Mode::Hidden, false, None);
        }
    }

    /// The webview laid out the current mode at `width`×`height` CSS pixels.
    pub fn resized(&self, width: f64, height: f64) {
        let mut state = self.lock();
        if state.mode == Mode::Hidden || width <= 0.0 || height <= 0.0 {
            return;
        }
        let size = (width.ceil(), height.ceil());
        state.size = Some(size);
        let mode = state.mode;
        state.last_sizes.insert(mode, size);
        self.place(&mut state);
    }

    // MARK: - Hover tracking

    /// Polls the cursor for the life of the app.
    pub fn start_hover_tracking(self: &Arc<Self>) {
        let panel = Arc::clone(self);
        std::thread::Builder::new()
            .name("limita-hover".into())
            .spawn(move || loop {
                std::thread::sleep(POLL);
                panel.track_cursor();
            })
            .expect("spawn the hover thread");
    }

    fn track_cursor(&self) {
        let mut state = self.lock();
        if state.pending_show && state.mode_changed_at.is_some_and(|at| at.elapsed() >= SIZE_TIMEOUT) {
            let mode = state.mode;
            let fallback = if mode == Mode::Pill { (260.0, 34.0) } else { (880.0, 270.0) };
            state.size = Some(state.last_sizes.get(&mode).copied().unwrap_or(fallback));
            self.place(&mut state);
        }
        let Ok(cursor) = self.app.cursor_position() else { return };

        // A click anywhere else closes the panel, as on macOS. Focus alone is not enough:
        // Windows may refuse to focus the dashboard, and then it never blurs.
        if state.mode != Mode::Hidden && crate::platform::mouse_button_down() {
            let on_panel = state.frame.is_some_and(|frame| frame.contains(cursor.x, cursor.y));
            let on_tray = state.last_tray_icon.is_some_and(|icon| icon.inflated(2.0).contains(cursor.x, cursor.y));
            if !on_panel && !on_tray && state.frame.is_some() {
                self.transition(&mut state, Mode::Hidden, false, None);
                return;
            }
        }

        match state.mode {
            Mode::Hidden => {
                let screens = self.screens(&mut state);
                let trigger = screens
                    .iter()
                    .find(|screen| screen.is_trigger(cursor.x, cursor.y))
                    .copied()
                    .filter(|screen| !crate::platform::foreground_is_fullscreen(screen.frame));
                let Some(screen) = trigger else {
                    state.dwell_started = None;
                    return;
                };
                match state.dwell_started {
                    None => state.dwell_started = Some(Instant::now()),
                    Some(started) if started.elapsed() >= DWELL => {
                        state.dwell_started = None;
                        self.transition(&mut state, Mode::Pill, true, Some(Anchor::Top { screen, x: cursor.x }));
                    }
                    Some(_) => {}
                }
            }
            Mode::Pill | Mode::Dashboard if state.hover_driven => {
                let (Some(anchor), Some(frame)) = (state.anchor, state.frame) else { return };
                if anchor.screen().hover_zone(frame).contains(cursor.x, cursor.y) {
                    state.outside_since = None;
                } else {
                    match state.outside_since {
                        None => state.outside_since = Some(Instant::now()),
                        Some(since) if since.elapsed() >= HIDE_DELAY => {
                            self.transition(&mut state, Mode::Hidden, false, None);
                        }
                        Some(_) => {}
                    }
                }
            }
            _ => {}
        }
    }

    // MARK: - Presentation

    fn transition(&self, state: &mut State, mode: Mode, hover_driven: bool, anchor: Option<Anchor>) {
        state.outside_since = None;
        state.dwell_started = None;
        let Some(window) = self.window() else { return };
        if mode == Mode::Hidden {
            if state.mode != Mode::Hidden {
                state.mode = Mode::Hidden;
                state.pending_show = false;
                state.frame = None;
                let _ = window.hide();
                self.store.dismiss_setup_message();
                let _ = self.app.emit("panel-mode", ModePayload { mode });
            }
            return;
        }
        let Some(anchor) = anchor.or(state.anchor) else { return };
        let changed = state.mode != mode || state.hover_driven != hover_driven;
        state.mode = mode;
        state.hover_driven = hover_driven;
        state.anchor = Some(anchor);
        if changed {
            // The webview answers with `resized` for the new mode; the window appears then.
            state.size = None;
            state.pending_show = true;
            state.mode_changed_at = Some(Instant::now());
            let _ = self.app.emit("panel-mode", ModePayload { mode });
            self.store.refresh_if_older(15.0);
        } else {
            self.place(state);
        }
    }

    /// Sizes and places the window for the current mode, and shows it if it is waiting.
    fn place(&self, state: &mut State) {
        let (Some(anchor), Some(size), Some(window)) = (state.anchor, state.size, self.window()) else { return };
        let frame = anchor.frame(size);
        state.frame = Some(frame);
        // Position first: moving to a monitor with another scale may resize the window.
        let _ = window.set_position(PhysicalPosition::new(frame.x.round() as i32, frame.y.round() as i32));
        let _ = window.set_size(PhysicalSize::new(frame.width as u32, frame.height as u32));
        if state.pending_show {
            state.pending_show = false;
            let takes_focus = state.mode == Mode::Dashboard && !state.hover_driven;
            crate::platform::show(&window, takes_focus);
        }
    }

    fn screens(&self, state: &mut State) -> Vec<Screen> {
        let fresh = state.screens_read_at.is_some_and(|at| at.elapsed() < Duration::from_secs(2));
        if !fresh || state.screens.is_empty() {
            if let Ok(monitors) = self.app.available_monitors() {
                state.screens = monitors
                    .iter()
                    .map(|monitor| {
                        let (position, size, work) = (monitor.position(), monitor.size(), monitor.work_area());
                        Screen {
                            frame: Area::new(position.x as f64, position.y as f64, size.width as f64, size.height as f64),
                            work: Area::new(
                                work.position.x as f64,
                                work.position.y as f64,
                                work.size.width as f64,
                                work.size.height as f64,
                            ),
                            scale: monitor.scale_factor(),
                        }
                    })
                    .collect();
                state.screens_read_at = Some(Instant::now());
            }
        }
        state.screens.clone()
    }
}

fn screen_containing(screens: &[Screen], x: f64, y: f64) -> Option<Screen> {
    screens
        .iter()
        .find(|screen| screen.frame.contains(x, y))
        .or_else(|| {
            // A tray rect can sit a pixel outside; take the nearest screen.
            screens.iter().min_by(|a, b| {
                distance(&a.frame, x, y).total_cmp(&distance(&b.frame, x, y))
            })
        })
        .copied()
}

fn distance(area: &Area, x: f64, y: f64) -> f64 {
    let dx = (area.x - x).max(0.0).max(x - area.right());
    let dy = (area.y - y).max(0.0).max(y - area.bottom());
    dx.hypot(dy)
}
