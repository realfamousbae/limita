//! The app's global shortcuts as the user set them. Port of the model in
//! `GlobalHotKey.swift` (`HotKeyBinding`, `HotKeyAction` and `HotKeyCenter`'s storage).
//! Registering them with Windows is the app's (`hotkeys.rs` in the Tauri crate); what is
//! here is plain data, so it is tested on any OS.
//!
//! A binding is a Windows virtual-key code and `RegisterHotKey` modifier flags. The
//! Settings window records it from the key the user presses, so it is the key with that
//! label on the user's keyboard layout.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `RegisterHotKey`'s modifier flags.
pub const MOD_ALT: u32 = 0x1;
pub const MOD_CONTROL: u32 = 0x2;
pub const MOD_SHIFT: u32 = 0x4;
pub const MOD_WIN: u32 = 0x8;
const ALLOWED: u32 = MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN;

/// What a global shortcut does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HotKeyAction {
    Dashboard,
    HoverPill,
    FloatingWindow,
}

impl HotKeyAction {
    pub const ALL: [HotKeyAction; 3] = [HotKeyAction::Dashboard, HotKeyAction::HoverPill, HotKeyAction::FloatingWindow];

    pub fn id(self) -> &'static str {
        match self {
            Self::Dashboard => "dashboard",
            Self::HoverPill => "hoverPill",
            Self::FloatingWindow => "floatingWindow",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|action| action.id() == id)
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Dashboard => "Show or hide the dashboard",
            Self::HoverPill => "Turn the hover pill on or off",
            Self::FloatingWindow => "Pin or unpin the floating window",
        }
    }

    /// Ctrl+Alt+L, Ctrl+Alt+H and Ctrl+Alt+P, as before shortcuts could be changed.
    pub fn default_binding(self) -> HotKeyBinding {
        let letter = match self {
            Self::Dashboard => b'L',
            Self::HoverPill => b'H',
            Self::FloatingWindow => b'P',
        };
        HotKeyBinding::new(u32::from(letter), MOD_CONTROL | MOD_ALT)
    }
}

/// A shortcut: a key and at least one of Ctrl, Alt and Win.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HotKeyBinding {
    /// Windows virtual-key code, e.g. 0x4C for L.
    pub key: u32,
    /// `MOD_*` flags.
    pub modifiers: u32,
}

impl HotKeyBinding {
    pub fn new(key: u32, modifiers: u32) -> Self {
        Self { key, modifiers: modifiers & ALLOWED }
    }

    /// A key press in the Settings window: `key_code` is the browser's `keyCode`, which on
    /// Windows is the virtual-key code. `None` for a key that cannot be a shortcut.
    pub fn from_key_press(key_code: u32, ctrl: bool, alt: bool, shift: bool, win: bool) -> Option<Self> {
        key_name(key_code)?;
        let flag = |on: bool, flag: u32| if on { flag } else { 0 };
        Some(Self::new(
            key_code,
            flag(ctrl, MOD_CONTROL) | flag(alt, MOD_ALT) | flag(shift, MOD_SHIFT) | flag(win, MOD_WIN),
        ))
    }

    /// A shortcut needs Ctrl, Alt or Win: Shift alone would take a letter from every text field.
    pub fn is_valid(&self) -> bool {
        self.modifiers & (MOD_CONTROL | MOD_ALT | MOD_WIN) != 0 && key_name(self.key).is_some()
    }

    fn modifier_names(&self, win: &'static str) -> Vec<&'static str> {
        [(MOD_CONTROL, "Ctrl"), (MOD_ALT, "Alt"), (MOD_SHIFT, "Shift"), (MOD_WIN, win)]
            .into_iter()
            .filter(|(flag, _)| self.modifiers & flag != 0)
            .map(|(_, name)| name)
            .collect()
    }

    /// "Ctrl+Alt+L", "Ctrl+Shift+F5".
    pub fn display_text(&self) -> String {
        let mut parts: Vec<String> = self.modifier_names("Win").into_iter().map(String::from).collect();
        parts.push(key_name(self.key).unwrap_or_else(|| format!("Key {}", self.key)));
        parts.join("+")
    }

    /// The same shortcut as a menu accelerator, for the hint next to Show Limits.
    pub fn accelerator(&self) -> Option<String> {
        let key = accelerator_key(self.key)?;
        let mut parts: Vec<String> = self.modifier_names("Super").into_iter().map(String::from).collect();
        parts.push(key);
        Some(parts.join("+"))
    }
}

/// How a key is shown, `None` for one that cannot be a shortcut (Esc cancels recording,
/// the modifiers are not keys of their own).
pub fn key_name(key: u32) -> Option<String> {
    Some(match key {
        0x30..=0x39 | 0x41..=0x5A => char::from_u32(key)?.to_string(),
        0x60..=0x69 => format!("Num {}", key - 0x60),
        0x70..=0x87 => format!("F{}", key - 0x6F),
        _ => named_key(key)?.0.to_string(),
    })
}

/// Name and menu-accelerator name of the keys without a character of their own.
fn named_key(key: u32) -> Option<(&'static str, &'static str)> {
    Some(match key {
        0x08 => ("Backspace", "Backspace"),
        0x09 => ("Tab", "Tab"),
        0x0D => ("Enter", "Enter"),
        0x20 => ("Space", "Space"),
        0x21 => ("Page Up", "PageUp"),
        0x22 => ("Page Down", "PageDown"),
        0x23 => ("End", "End"),
        0x24 => ("Home", "Home"),
        0x25 => ("Left", "Left"),
        0x26 => ("Up", "Up"),
        0x27 => ("Right", "Right"),
        0x28 => ("Down", "Down"),
        0x2D => ("Insert", "Insert"),
        0x2E => ("Delete", "Delete"),
        0x6A => ("Num *", "NumMultiply"),
        0x6B => ("Num +", "NumAdd"),
        0x6D => ("Num -", "NumSubtract"),
        0x6E => ("Num .", "NumDecimal"),
        0x6F => ("Num /", "NumDivide"),
        0xBA => (";", ";"),
        0xBB => ("=", "="),
        0xBC => (",", ","),
        0xBD => ("-", "-"),
        0xBE => (".", "."),
        0xBF => ("/", "/"),
        0xC0 => ("`", "`"),
        0xDB => ("[", "["),
        0xDC => ("\\", "\\"),
        0xDD => ("]", "]"),
        0xDE => ("'", "'"),
        _ => return None,
    })
}

fn accelerator_key(key: u32) -> Option<String> {
    Some(match key {
        0x30..=0x39 | 0x41..=0x5A => char::from_u32(key)?.to_string(),
        0x60..=0x69 => format!("Numpad{}", key - 0x60),
        0x70..=0x87 => format!("F{}", key - 0x6F),
        _ => named_key(key)?.1.to_string(),
    })
}

/// Every action's shortcut, `None` for one turned off.
#[derive(Clone, Debug, PartialEq)]
pub struct HotKeys {
    bindings: BTreeMap<HotKeyAction, Option<HotKeyBinding>>,
}

impl Default for HotKeys {
    fn default() -> Self {
        Self { bindings: HotKeyAction::ALL.into_iter().map(|action| (action, Some(action.default_binding()))).collect() }
    }
}

impl HotKeys {
    /// What `settings.json` keeps under `hotKeys`: one entry per changed action, a binding
    /// or `null` for a shortcut turned off. An action without an entry has its default,
    /// and so does one whose entry cannot be read.
    pub fn from_stored(stored: Option<&Value>) -> Self {
        let mut keys = Self::default();
        let Some(Value::Object(entries)) = stored else { return keys };
        for action in HotKeyAction::ALL {
            match entries.get(action.id()) {
                None => {}
                Some(Value::Null) => {
                    keys.bindings.insert(action, None);
                }
                Some(entry) => {
                    if let Some(binding) = serde_json::from_value::<HotKeyBinding>(entry.clone()).ok().filter(HotKeyBinding::is_valid) {
                        keys.bindings.insert(action, Some(binding));
                    }
                }
            }
        }
        keys
    }

    /// The changed actions, `None` while every shortcut has its default.
    pub fn to_stored(&self) -> Option<Value> {
        let changed: serde_json::Map<String, Value> = HotKeyAction::ALL
            .into_iter()
            .filter(|&action| self.binding(action) != Some(action.default_binding()))
            .map(|action| (action.id().to_string(), serde_json::to_value(self.binding(action)).unwrap_or(Value::Null)))
            .collect();
        (!changed.is_empty()).then_some(Value::Object(changed))
    }

    pub fn binding(&self, action: HotKeyAction) -> Option<HotKeyBinding> {
        self.bindings.get(&action).copied().flatten()
    }

    /// Sets a shortcut, `None` to turn it off. One already used by another action moves here.
    pub fn set(&mut self, action: HotKeyAction, binding: Option<HotKeyBinding>) {
        if let Some(binding) = binding {
            for (other, existing) in self.bindings.iter_mut() {
                if *other != action && *existing == Some(binding) {
                    *existing = None;
                }
            }
        }
        self.bindings.insert(action, binding);
    }

    pub fn reset(&mut self, action: HotKeyAction) {
        self.set(action, Some(action.default_binding()));
    }

    /// Every action that has a shortcut, with it.
    pub fn active(&self) -> Vec<(HotKeyAction, HotKeyBinding)> {
        HotKeyAction::ALL.into_iter().filter_map(|action| Some((action, self.binding(action)?))).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binding_text() {
        let binding = HotKeyBinding::from_key_press(0x4C, true, true, false, false).unwrap();
        assert_eq!(binding.display_text(), "Ctrl+Alt+L");
        assert_eq!(binding.accelerator().as_deref(), Some("Ctrl+Alt+L"));
        assert!(binding.is_valid());
        assert_eq!(HotKeyBinding::new(0x4C, MOD_CONTROL | MOD_ALT | 0x4000).modifiers, MOD_CONTROL | MOD_ALT, "only Ctrl, Alt, Shift and Win are kept");
        let function = HotKeyBinding::from_key_press(0x74, true, false, true, false).unwrap();
        assert_eq!(function.display_text(), "Ctrl+Shift+F5");
        let windows = HotKeyBinding::from_key_press(0x26, false, false, false, true).unwrap();
        assert_eq!(windows.display_text(), "Win+Up");
        assert_eq!(windows.accelerator().as_deref(), Some("Super+Up"));
        assert_eq!(HotKeyBinding::new(0xBF, MOD_ALT).display_text(), "Alt+/");
        assert_eq!(HotKeyBinding::new(0x61, MOD_ALT).accelerator().as_deref(), Some("Alt+Numpad1"));
        assert!(!HotKeyBinding::from_key_press(0x41, false, false, true, false).unwrap().is_valid(), "Shift alone is not enough");
        assert_eq!(HotKeyBinding::from_key_press(0x11, true, false, false, false), None, "a modifier is not a key");
        assert_eq!(HotKeyBinding::from_key_press(0x1B, true, false, false, false), None, "Esc cancels recording");
        assert_eq!(HotKeyAction::Dashboard.default_binding().display_text(), "Ctrl+Alt+L");
        assert_eq!(HotKeyAction::from_id("hoverPill"), Some(HotKeyAction::HoverPill));
    }

    #[test]
    fn saved_turned_off_and_reset() {
        let mut keys = HotKeys::default();
        assert_eq!(keys.binding(HotKeyAction::HoverPill), Some(HotKeyAction::HoverPill.default_binding()));
        assert_eq!(keys.to_stored(), None, "defaults are not stored");

        let custom = HotKeyBinding::new(0x4B, MOD_CONTROL | MOD_WIN);
        keys.set(HotKeyAction::Dashboard, Some(custom));
        keys.set(HotKeyAction::FloatingWindow, None);
        let stored = keys.to_stored().unwrap();
        assert_eq!(stored, serde_json::json!({"dashboard": {"key": 0x4B, "modifiers": 10}, "floatingWindow": null}));
        let mut reloaded = HotKeys::from_stored(Some(&stored));
        assert_eq!(reloaded.binding(HotKeyAction::Dashboard), Some(custom));
        assert_eq!(reloaded.binding(HotKeyAction::FloatingWindow), None, "turned off stays off");
        assert_eq!(reloaded.binding(HotKeyAction::HoverPill), Some(HotKeyAction::HoverPill.default_binding()));
        assert_eq!(reloaded.active().len(), 2);

        reloaded.set(HotKeyAction::HoverPill, Some(custom));
        assert_eq!(reloaded.binding(HotKeyAction::Dashboard), None, "one shortcut does one thing");

        for action in HotKeyAction::ALL {
            reloaded.reset(action);
        }
        assert_eq!(reloaded.to_stored(), None);
    }

    #[test]
    fn unreadable_entries_keep_the_default() {
        let stored = serde_json::json!({"dashboard": {"key": 0x41, "modifiers": MOD_SHIFT}, "hoverPill": "Ctrl+H"});
        assert_eq!(HotKeys::from_stored(Some(&stored)), HotKeys::default());
        assert_eq!(HotKeys::from_stored(Some(&serde_json::json!([1]))), HotKeys::default());
    }
}
