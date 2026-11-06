//! The global shortcuts: what each is set to, registering them with Windows, and saving
//! changes. Port of `HotKeyCenter` in `GlobalHotKey.swift`; the bindings themselves are
//! `limita_core::hotkeys`.
//!
//! A hot key belongs to the thread that registered it, and only that thread can
//! unregister it. So one thread owns them all: it waits in its message loop, runs the
//! action of a pressed shortcut, and re-registers the whole set when another thread asks
//! (`WM_APP_RELOAD`, posted with `PostThreadMessageW`). A shortcut another app holds is
//! reported in Settings, not lost.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard};

use limita_core::hotkeys::{HotKeyAction, HotKeyBinding, HotKeys};
use limita_core::settings::ServiceSettings;
use serde::Serialize;

pub type Action = Box<dyn Fn() + Send + Sync>;

/// One shortcut as Settings → Shortcuts shows it.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShortcutView {
    pub id: &'static str,
    pub title: &'static str,
    /// "Ctrl+Alt+L", or "Off".
    pub text: String,
    pub off: bool,
    pub is_default: bool,
    pub default_text: String,
    /// Windows refused it, usually because another app holds it.
    pub failed: bool,
}

struct State {
    keys: HotKeys,
    /// Actions whose shortcut Windows refused.
    failed: BTreeSet<HotKeyAction>,
    /// Actions whose shortcut is registered and works.
    registered: BTreeSet<HotKeyAction>,
    /// While a shortcut is being recorded, the current ones must not fire.
    suspended: bool,
}

pub struct HotKeyCenter {
    settings: ServiceSettings,
    state: Mutex<State>,
    worker: Option<worker::Worker>,
    /// Called after any change, e.g. to update the tray menu's hint.
    on_change: Box<dyn Fn() + Send + Sync>,
}

impl HotKeyCenter {
    /// Registers every shortcut with what it does.
    pub fn start(
        settings: ServiceSettings,
        actions: BTreeMap<HotKeyAction, Action>,
        on_change: impl Fn() + Send + Sync + 'static,
    ) -> Arc<Self> {
        let keys = settings.hot_keys();
        let center = Arc::new(Self {
            settings,
            state: Mutex::new(State { keys, failed: BTreeSet::new(), registered: BTreeSet::new(), suspended: false }),
            worker: worker::Worker::spawn(actions),
            on_change: Box::new(on_change),
        });
        center.register_all();
        center
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Sets a shortcut, `None` to turn it off. One already used by another action moves here.
    pub fn set(&self, action: HotKeyAction, binding: Option<HotKeyBinding>) {
        let keys = {
            let mut state = self.lock();
            state.keys.set(action, binding);
            state.keys.clone()
        };
        self.settings.set_hot_keys(&keys);
        self.register_all();
    }

    pub fn reset(&self, action: HotKeyAction) {
        self.set(action, Some(action.default_binding()));
    }

    pub fn suspend(&self, suspended: bool) {
        {
            let mut state = self.lock();
            if state.suspended == suspended {
                return;
            }
            state.suspended = suspended;
        }
        self.register_all();
    }

    /// The menu hint for Show Limits: the dashboard's shortcut, while it works.
    pub fn dashboard_accelerator(&self) -> Option<String> {
        let state = self.lock();
        if !state.registered.contains(&HotKeyAction::Dashboard) {
            return None;
        }
        state.keys.binding(HotKeyAction::Dashboard)?.accelerator()
    }

    pub fn views(&self) -> Vec<ShortcutView> {
        let state = self.lock();
        HotKeyAction::ALL
            .into_iter()
            .map(|action| {
                let binding = state.keys.binding(action);
                ShortcutView {
                    id: action.id(),
                    title: action.title(),
                    text: binding.map_or("Off".into(), |b| b.display_text()),
                    off: binding.is_none(),
                    is_default: binding == Some(action.default_binding()),
                    default_text: action.default_binding().display_text(),
                    failed: state.failed.contains(&action),
                }
            })
            .collect()
    }

    fn register_all(&self) {
        let (wanted, suspended) = {
            let state = self.lock();
            (if state.suspended { Vec::new() } else { state.keys.active() }, state.suspended)
        };
        // No worker (a development build elsewhere): nothing is registered, nothing failed.
        let failed = self.worker.as_ref().map(|worker| worker.reload(wanted.clone()));
        {
            let mut state = self.lock();
            state.registered = match &failed {
                Some(failed) => wanted.iter().map(|(action, _)| *action).filter(|action| !failed.contains(action)).collect(),
                None => BTreeSet::new(),
            };
            if !suspended {
                state.failed = failed.unwrap_or_default();
            }
        }
        (self.on_change)();
    }
}

#[cfg(windows)]
mod worker {
    use std::collections::{BTreeMap, BTreeSet};
    use std::sync::mpsc;
    use std::time::Duration;

    use limita_core::hotkeys::{HotKeyAction, HotKeyBinding};
    use windows_sys::Win32::System::Threading::GetCurrentThreadId;
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{RegisterHotKey, UnregisterHotKey, MOD_NOREPEAT};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetMessageW, PeekMessageW, PostThreadMessageW, MSG, PM_NOREMOVE, WM_APP, WM_HOTKEY, WM_USER,
    };

    use super::Action;

    const WM_APP_RELOAD: u32 = WM_APP + 1;

    type Request = (Vec<(HotKeyAction, HotKeyBinding)>, mpsc::Sender<BTreeSet<HotKeyAction>>);

    pub struct Worker {
        thread_id: u32,
        requests: mpsc::Sender<Request>,
    }

    /// Hot key ids per action, 1 and up.
    fn id_of(action: HotKeyAction) -> i32 {
        HotKeyAction::ALL.iter().position(|a| *a == action).map_or(0, |index| index as i32 + 1)
    }

    impl Worker {
        /// The thread that owns the hot keys. One thread waits in the message loop and
        /// uses no CPU between presses.
        pub fn spawn(actions: BTreeMap<HotKeyAction, Action>) -> Option<Self> {
            let (requests, incoming) = mpsc::channel::<Request>();
            let (started, thread_id) = mpsc::channel();
            std::thread::Builder::new()
                .name("limita-hotkey".into())
                .spawn(move || unsafe {
                    let mut message: MSG = std::mem::zeroed();
                    // Creates the thread's message queue before anyone posts to it.
                    PeekMessageW(&mut message, std::ptr::null_mut(), WM_USER, WM_USER, PM_NOREMOVE);
                    let _ = started.send(GetCurrentThreadId());
                    let mut registered: Vec<(i32, HotKeyAction)> = Vec::new();
                    while GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) > 0 {
                        match message.message {
                            WM_HOTKEY => {
                                let id = message.wParam as i32;
                                if let Some(action) = registered.iter().find(|(key, _)| *key == id).map(|(_, action)| *action) {
                                    if let Some(perform) = actions.get(&action) {
                                        perform();
                                    }
                                }
                            }
                            WM_APP_RELOAD => {
                                while let Ok((wanted, reply)) = incoming.try_recv() {
                                    for (id, _) in registered.drain(..) {
                                        UnregisterHotKey(std::ptr::null_mut(), id);
                                    }
                                    let mut failed = BTreeSet::new();
                                    for (action, binding) in wanted {
                                        let id = id_of(action);
                                        if RegisterHotKey(std::ptr::null_mut(), id, binding.modifiers | MOD_NOREPEAT, binding.key) != 0 {
                                            registered.push((id, action));
                                        } else {
                                            failed.insert(action);
                                        }
                                    }
                                    let _ = reply.send(failed);
                                }
                            }
                            _ => {}
                        }
                    }
                })
                .ok()?;
            let thread_id = thread_id.recv_timeout(Duration::from_secs(2)).ok()?;
            Some(Self { thread_id, requests })
        }

        /// Replaces every registered shortcut with `wanted`; returns the ones Windows refused.
        pub fn reload(&self, wanted: Vec<(HotKeyAction, HotKeyBinding)>) -> BTreeSet<HotKeyAction> {
            let everything: BTreeSet<HotKeyAction> = wanted.iter().map(|(action, _)| *action).collect();
            let (reply, answer) = mpsc::channel();
            if self.requests.send((wanted, reply)).is_err() {
                return everything;
            }
            // SAFETY: posting a message to a thread id is safe whatever the thread's state.
            if unsafe { PostThreadMessageW(self.thread_id, WM_APP_RELOAD, 0, 0) } == 0 {
                return everything;
            }
            answer.recv_timeout(Duration::from_secs(2)).unwrap_or(everything)
        }
    }
}

/// Elsewhere (a development build on macOS) there are no global shortcuts.
#[cfg(not(windows))]
mod worker {
    use std::collections::{BTreeMap, BTreeSet};

    use limita_core::hotkeys::{HotKeyAction, HotKeyBinding};

    use super::Action;

    pub struct Worker;

    impl Worker {
        pub fn spawn(_: BTreeMap<HotKeyAction, Action>) -> Option<Self> {
            None
        }

        pub fn reload(&self, wanted: Vec<(HotKeyAction, HotKeyBinding)>) -> BTreeSet<HotKeyAction> {
            wanted.into_iter().map(|(action, _)| action).collect()
        }
    }
}
