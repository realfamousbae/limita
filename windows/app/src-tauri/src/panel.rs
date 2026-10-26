//! The floating panel: the hover pill and the dashboard share one window, as on macOS.
//! Port of `BezelPanelController.swift`.
//!
//! - Resting the cursor at the top edge of a screen shows a compact pill there; clicking
//!   it expands the dashboard. Moving away hides either again.
//! - The tray icon opens the dashboard next to it; clicking elsewhere closes it.
//! - Floating (Ctrl+Alt+P): the dashboard stays where the user drags it until the
//!   shortcut, the tray icon or the toggle closes it, and never takes the keyboard.
//!
//! The webview renders whatever mode it is told and reports the size it needs; the panel
//! is sized and placed here, in physical pixels of the target monitor.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard};
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
    /// The floating dashboard, its top-left corner at `x`, `y`.
    Pinned { screen: Screen, x: f64, y: f64 },
}

impl Anchor {
    fn screen(&self) -> Screen {
        match self {
            Anchor::Top { screen, .. } | Anchor::Tray { screen, .. } | Anchor::Pinned { screen, .. } => *screen,
        }
    }

    fn frame(&self, logical: (f64, f64)) -> Area {
        let scale = self.screen().scale;
        let size = ((logical.0 * scale).round(), (logical.1 * scale).round());
        match self {
            Anchor::Top { screen, x } => screen.below_top(size, *x),
            Anchor::Tray { screen, icon } => screen.beside_tray(size, *icon),
            Anchor::Pinned { screen, x, y } => screen.pinned(size, (*x, *y)),
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
    /// Top-left corner of the floating dashboard; it grows and shrinks downwards from it.
    pinned: Option<(f64, f64)>,
    screens: Vec<Screen>,
    screens_read_at: Option<Instant>,
}

pub struct Panel {
    app: AppHandle,
    store: Store,
    state: Mutex<State>,
    /// Whether resting the cursor at the screen edge shows the pill. While it is off and
    /// nothing is open, the hover thread sleeps and does not poll the cursor at all.
    hover_pill: AtomicBool,
    /// Whether the dashboard floats where the user put it.
    floating: AtomicBool,
    /// Wakes the sleeping hover thread.
    wake: Mutex<mpsc::Sender<()>>,
    wake_receiver: Mutex<Option<mpsc::Receiver<()>>>,
}

#[derive(Clone, Serialize)]
pub struct HoverPayload {
    pub enabled: bool,
}

#[derive(Clone, Serialize)]
pub struct FloatingPayload {
    pub enabled: bool,
}

#[derive(Clone, Serialize)]
pub struct ModePayload {
    pub mode: Mode,
}

impl Panel {
    pub fn new(app: AppHandle, store: Store) -> Arc<Self> {
        let (wake, wake_receiver) = mpsc::channel();
        let pinned = store.floating_position().map(|(x, y)| (f64::from(x), f64::from(y)));
        Arc::new(Self {
            hover_pill: AtomicBool::new(store.hover_pill()),
            floating: AtomicBool::new(store.floating()),
            wake: Mutex::new(wake),
            wake_receiver: Mutex::new(Some(wake_receiver)),
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
                pinned,
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

    pub fn hover_pill(&self) -> bool {
        self.hover_pill.load(Ordering::Relaxed)
    }

    /// Turns the hover pill on or off, and remembers the choice.
    pub fn set_hover_pill(&self, enabled: bool) {
        if self.hover_pill.swap(enabled, Ordering::Relaxed) == enabled {
            return;
        }
        self.store.set_hover_pill(enabled);
        if enabled {
            self.wake_hover_thread();
        } else {
            let mut state = self.lock();
            if state.mode == Mode::Pill {
                self.transition(&mut state, Mode::Hidden, false, None);
            }
            state.dwell_started = None;
        }
        let _ = self.app.emit("hover-pill", HoverPayload { enabled });
    }

    pub fn toggle_hover_pill(&self) {
        self.set_hover_pill(!self.hover_pill());
    }

    pub fn floating(&self) -> bool {
        self.floating.load(Ordering::Relaxed)
    }

    /// Pins the dashboard as a floating window, or returns it to the tray, and remembers
    /// the choice. Turning it on opens the dashboard; turning it off closes it.
    pub fn set_floating(&self, enabled: bool) {
        if self.floating.swap(enabled, Ordering::Relaxed) == enabled {
            return;
        }
        self.store.set_floating(enabled);
        {
            let mut state = self.lock();
            if enabled {
                if state.mode == Mode::Dashboard {
                    // Stays where it is open now until it is dragged.
                    if state.pinned.is_none() {
                        state.pinned = state.frame.map(|frame| (frame.x, frame.y));
                    }
                }
                let anchor = self.pinned_anchor(&mut state).or_else(|| self.top_of_cursor_screen(&mut state));
                self.transition(&mut state, Mode::Dashboard, false, anchor);
            } else {
                self.transition(&mut state, Mode::Hidden, false, None);
            }
        }
        // Outside the lock: the menu call waits for the main thread.
        if let Some(tray) = self.app.try_state::<Arc<crate::tray::Tray>>() {
            tray.set_floating(enabled);
        }
        let _ = self.app.emit("floating", FloatingPayload { enabled });
    }

    pub fn toggle_floating(&self) {
        self.set_floating(!self.floating());
    }

    /// The floating dashboard's place, once it has one.
    fn pinned_anchor(&self, state: &mut State) -> Option<Anchor> {
        if !self.floating() {
            return None;
        }
        let (x, y) = state.pinned?;
        screen_containing(&self.screens(state), x, y).map(|screen| Anchor::Pinned { screen, x, y })
    }

    /// Centred at the top of the screen the cursor is on.
    fn top_of_cursor_screen(&self, state: &mut State) -> Option<Anchor> {
        let screens = self.screens(state);
        let cursor = self.app.cursor_position().ok();
        let screen = cursor.and_then(|c| screen_containing(&screens, c.x, c.y)).or_else(|| screens.first().copied())?;
        Some(Anchor::Top { screen, x: screen.frame.x + screen.frame.width / 2.0 })
    }

    /// The window moved. A move the panel did not make is the user dragging the floating
    /// dashboard: it stays there from now on.
    pub fn moved(&self, x: i32, y: i32) {
        let mut state = self.lock();
        if !self.floating() || state.mode != Mode::Dashboard {
            return;
        }
        let Some(frame) = state.frame else { return };
        let (x, y) = (f64::from(x), f64::from(y));
        if frame.x.round() == x && frame.y.round() == y {
            return;
        }
        state.frame = Some(Area::new(x, y, frame.width, frame.height));
        state.pinned = Some((x, y));
        if let Some(screen) = screen_containing(&self.screens(&mut state), x, y) {
            state.anchor = Some(Anchor::Pinned { screen, x, y });
        }
        self.store.set_floating_position((x as i32, y as i32));
    }

    /// Drags the floating dashboard by its header. The ordinary one stays put.
    pub fn start_drag(&self) {
        if self.floating() && self.mode() == Mode::Dashboard {
            if let Some(window) = self.window() {
                let _ = window.start_dragging();
            }
        }
    }

    fn wake_hover_thread(&self) {
        let _ = self.wake.lock().unwrap_or_else(|p| p.into_inner()).send(());
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
        if let Some(anchor) = self.pinned_anchor(&mut state) {
            self.transition(&mut state, Mode::Dashboard, false, Some(anchor));
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
        if let Some(anchor) = self.pinned_anchor(&mut state) {
            self.transition(&mut state, Mode::Dashboard, false, Some(anchor));
            return;
        }
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

    /// Ctrl+Alt+L: hides whatever is open, otherwise opens the dashboard centred at the
    /// top of the screen the cursor is on, as ⌃⌥L does on macOS.
    pub fn toggle_from_shortcut(&self) {
        let mut state = self.lock();
        if state.mode != Mode::Hidden {
            self.transition(&mut state, Mode::Hidden, false, None);
            return;
        }
        let anchor = self.pinned_anchor(&mut state).or_else(|| self.top_of_cursor_screen(&mut state));
        self.transition(&mut state, Mode::Dashboard, false, anchor);
    }

    /// The pill was clicked.
    pub fn expand(&self) {
        let mut state = self.lock();
        if state.mode == Mode::Pill {
            // The floating dashboard opens where it is pinned and does not follow the cursor.
            let floating = self.floating();
            let anchor = self.pinned_anchor(&mut state).or(state.anchor);
            self.transition(&mut state, Mode::Dashboard, !floating, anchor);
        }
    }

    pub fn hide(&self) {
        let mut state = self.lock();
        self.transition(&mut state, Mode::Hidden, false, None);
    }

    /// The window lost focus: a tray-opened dashboard closes, as a click elsewhere should.
    pub fn blurred(&self) {
        let mut state = self.lock();
        if state.mode == Mode::Dashboard && !state.hover_driven && !self.floating() {
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

    /// Polls the cursor for the life of the app, except while the hover pill is off and
    /// nothing is open: then the thread blocks until it is needed again.
    pub fn start_hover_tracking(self: &Arc<Self>) {
        let panel = Arc::clone(self);
        let Some(wake) = self.wake_receiver.lock().unwrap_or_else(|p| p.into_inner()).take() else { return };
        std::thread::Builder::new()
            .name("limita-hover".into())
            .spawn(move || loop {
                if panel.idle() {
                    // A wake-up sent after the check above is queued, so it is not lost.
                    if wake.recv().is_err() {
                        return;
                    }
                    while wake.try_recv().is_ok() {}
                    continue;
                }
                std::thread::sleep(POLL);
                panel.track_cursor();
            })
            .expect("spawn the hover thread");
    }

    /// Nothing to watch: no pill to pop, no hover-opened panel to follow, no click outside
    /// to close on, and no window waiting for its size.
    fn idle(&self) -> bool {
        let state = self.lock();
        if state.pending_show {
            return false;
        }
        match state.mode {
            Mode::Hidden => !self.hover_pill(),
            Mode::Dashboard => self.floating() && !state.hover_driven,
            Mode::Pill => false,
        }
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
        let pinned = self.floating() && state.mode == Mode::Dashboard;
        if state.mode != Mode::Hidden && !pinned && crate::platform::mouse_button_down() {
            let on_panel = state.frame.is_some_and(|frame| frame.contains(cursor.x, cursor.y));
            let on_tray = state.last_tray_icon.is_some_and(|icon| icon.inflated(2.0).contains(cursor.x, cursor.y));
            if !on_panel && !on_tray && state.frame.is_some() {
                self.transition(&mut state, Mode::Hidden, false, None);
                return;
            }
        }

        match state.mode {
            Mode::Hidden => {
                if !self.hover_pill() {
                    state.dwell_started = None;
                    return;
                }
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
                // A closed floating dashboard leaves the hover pill to watch for again.
                self.wake_hover_thread();
            }
            return;
        }
        let Some(anchor) = anchor.or(state.anchor) else { return };
        let changed = state.mode != mode || state.hover_driven != hover_driven;
        // Click-outside detection needs the hover thread even while the pill is off, and
        // so does the size timeout of a floating dashboard.
        self.wake_hover_thread();
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
        if self.floating() && state.mode == Mode::Dashboard && !state.hover_driven {
            // From now on it grows and shrinks downwards from this corner.
            let (x, y) = (frame.x, frame.y);
            state.pinned = Some((x, y));
            state.anchor = Some(Anchor::Pinned { screen: anchor.screen(), x, y });
        }
        // Position first: moving to a monitor with another scale may resize the window.
        let _ = window.set_position(PhysicalPosition::new(frame.x.round() as i32, frame.y.round() as i32));
        let _ = window.set_size(PhysicalSize::new(frame.width as u32, frame.height as u32));
        if state.pending_show {
            state.pending_show = false;
            // The floating dashboard stays open over the app the user is typing in.
            let takes_focus = state.mode == Mode::Dashboard && !state.hover_driven && !self.floating();
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
