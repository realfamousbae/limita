//! Which services Limita tracks and every other setting, persisted as JSON in the
//! app-data folder. Port of `ServiceSettings.swift`. The DeepSeek API key is not here: it
//! lives in the Credential Manager (`secrets`).
//!
//! On first launch the set is auto-detected from what is installed; after that the
//! user's connect/disconnect choices are kept as they are.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::hotkeys::HotKeys;
use crate::locator;
use crate::model::Service;
use crate::paths;

#[derive(Clone, Debug)]
pub struct ServiceSettings {
    pub file: PathBuf,
}

impl Default for ServiceSettings {
    fn default() -> Self {
        Self { file: paths::app_data().join("settings.json") }
    }
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stored {
    /// Absent until the first launch has stored its detection.
    enabled_services: Option<Vec<String>>,
    /// Absent means on.
    hover_pill: Option<bool>,
    /// Whether the activity panel under the dashboard is open. Absent means closed.
    activity_expanded: Option<bool>,
    /// "week", "month" or "all". Absent means all.
    activity_period: Option<String>,
    /// Whether new limit resets are announced. Absent means on.
    reset_notifications: Option<bool>,
    /// Whether the dashboard floats where the user put it. Absent means off.
    floating: Option<bool>,
    /// Top-left corner of the floating dashboard in physical pixels, once moved.
    floating_position: Option<(i32, i32)>,
    /// How often each service's network API is asked, in seconds, where the user changed
    /// it: `{"claude": 600}`. Kept as JSON so an odd value costs only this setting.
    live_intervals: Option<serde_json::Value>,
    /// The DeepSeek balance at or below which it counts as low. Absent means off.
    deepseek_low_balance: Option<f64>,
    /// Whether a low or exhausted DeepSeek balance is announced. Absent means on.
    deepseek_balance_alerts: Option<bool>,
    /// Whether GitHub is asked for a newer Limita every 3 hours. Absent means on.
    auto_update_check: Option<bool>,
    /// Global shortcuts that differ from the defaults; see `hotkeys::HotKeys::from_stored`.
    hot_keys: Option<serde_json::Value>,
}

impl ServiceSettings {
    fn read(&self) -> Stored {
        std::fs::read(&self.file)
            .ok()
            .and_then(|data| serde_json::from_slice::<Stored>(&data).ok())
            .unwrap_or_default()
    }

    fn write(&self, stored: &Stored) {
        if let Some(parent) = self.file.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_vec_pretty(stored) {
            let _ = crate::claude_cache::write_atomically(&self.file, &json);
        }
    }

    /// Whether the cursor at the screen edge shows the pill. On unless the user turned it off.
    pub fn hover_pill(&self) -> bool {
        self.read().hover_pill.unwrap_or(true)
    }

    pub fn set_hover_pill(&self, enabled: bool) {
        let mut stored = self.read();
        stored.hover_pill = Some(enabled);
        self.write(&stored);
    }

    /// Whether the dashboard floats where the user put it instead of next to the tray.
    pub fn floating(&self) -> bool {
        self.read().floating.unwrap_or(false)
    }

    pub fn set_floating(&self, enabled: bool) {
        let mut stored = self.read();
        stored.floating = Some(enabled);
        self.write(&stored);
    }

    /// Where the floating dashboard was last left, as its top-left corner.
    pub fn floating_position(&self) -> Option<(i32, i32)> {
        self.read().floating_position
    }

    pub fn set_floating_position(&self, position: (i32, i32)) {
        let mut stored = self.read();
        stored.floating_position = Some(position);
        self.write(&stored);
    }

    /// Whether the activity panel is open, so the dashboard opens the way it was left.
    pub fn activity_expanded(&self) -> bool {
        self.read().activity_expanded.unwrap_or(false)
    }

    pub fn set_activity_expanded(&self, expanded: bool) {
        let mut stored = self.read();
        stored.activity_expanded = Some(expanded);
        self.write(&stored);
    }

    pub fn activity_period(&self) -> crate::activity::Period {
        self.read().activity_period.as_deref().and_then(crate::activity::Period::from_id).unwrap_or_default()
    }

    pub fn set_activity_period(&self, period: crate::activity::Period) {
        let mut stored = self.read();
        stored.activity_period = serde_json::to_value(period).ok().and_then(|v| v.as_str().map(String::from));
        self.write(&stored);
    }

    /// Whether new limit resets come as a notification. On unless the user turned it off.
    pub fn reset_notifications(&self) -> bool {
        self.read().reset_notifications.unwrap_or(true)
    }

    pub fn set_reset_notifications(&self, enabled: bool) {
        let mut stored = self.read();
        stored.reset_notifications = Some(enabled);
        self.write(&stored);
    }

    /// Network intervals in seconds per service, only where the user changed them.
    pub fn live_intervals(&self) -> BTreeMap<Service, f64> {
        let Some(serde_json::Value::Object(raw)) = self.read().live_intervals else { return BTreeMap::new() };
        raw.iter()
            .filter_map(|(id, seconds)| Some((Service::from_id(id)?, seconds.as_f64().filter(|s| s.is_finite() && *s > 0.0)?)))
            .collect()
    }

    pub fn set_live_intervals(&self, intervals: &BTreeMap<Service, f64>) {
        let mut stored = self.read();
        stored.live_intervals = (!intervals.is_empty()).then(|| {
            serde_json::Value::Object(intervals.iter().map(|(service, seconds)| (service.id().to_string(), (*seconds).into())).collect())
        });
        self.write(&stored);
    }

    /// The DeepSeek balance below which it counts as low; `None` while not set.
    pub fn low_balance_threshold(&self) -> Option<f64> {
        self.read().deepseek_low_balance.filter(|value| value.is_finite() && *value > 0.0)
    }

    /// Zero or less turns it off.
    pub fn set_low_balance_threshold(&self, threshold: Option<f64>) {
        let mut stored = self.read();
        stored.deepseek_low_balance = threshold.filter(|value| value.is_finite() && *value > 0.0);
        self.write(&stored);
    }

    /// Whether a low or exhausted DeepSeek balance is announced. On unless turned off.
    pub fn balance_alerts(&self) -> bool {
        self.read().deepseek_balance_alerts.unwrap_or(true)
    }

    pub fn set_balance_alerts(&self, enabled: bool) {
        let mut stored = self.read();
        stored.deepseek_balance_alerts = Some(enabled);
        self.write(&stored);
    }

    /// Whether updates are looked for every few hours. On unless turned off; Check Now
    /// in Settings works either way.
    pub fn auto_update_check(&self) -> bool {
        self.read().auto_update_check.unwrap_or(true)
    }

    pub fn set_auto_update_check(&self, enabled: bool) {
        let mut stored = self.read();
        stored.auto_update_check = Some(enabled);
        self.write(&stored);
    }

    pub fn hot_keys(&self) -> HotKeys {
        HotKeys::from_stored(self.read().hot_keys.as_ref())
    }

    pub fn set_hot_keys(&self, keys: &HotKeys) {
        let mut stored = self.read();
        stored.hot_keys = keys.to_stored();
        self.write(&stored);
    }

    /// The stored set, or the result of `detect` on first launch (which is then stored).
    pub fn load(&self, detect: impl FnOnce() -> BTreeSet<Service>) -> BTreeSet<Service> {
        if let Some(raw) = self.read().enabled_services {
            return raw.iter().filter_map(|id| Service::from_id(id)).collect();
        }
        let detected = detect();
        self.save(&detected);
        detected
    }

    pub fn save(&self, services: &BTreeSet<Service>) {
        let mut stored = self.read();
        stored.enabled_services = Some(services.iter().map(|s| s.id().to_string()).collect());
        self.write(&stored);
    }
}

/// A service counts as installed when its CLI or its config folder exists. Nothing here
/// reads credentials, so first launch never needs any permission. DeepSeek is never
/// detected: it needs an API key, entered in Settings.
pub fn detect_installed(home: &Path, find_cli: impl Fn(&str) -> Option<PathBuf>) -> BTreeSet<Service> {
    let mut services = BTreeSet::new();
    if find_cli("claude").is_some() || home.join(".claude").exists() {
        services.insert(Service::Claude);
    }
    if find_cli("codex").is_some() || home.join(".codex").exists() {
        services.insert(Service::Codex);
    }
    services
}

pub fn detect_installed_here() -> BTreeSet<Service> {
    detect_installed(&paths::home(), locator::find)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_once_then_keep_choice() {
        let dir = tempfile::tempdir().unwrap();
        let settings = ServiceSettings { file: dir.path().join("settings.json") };
        let mut detections = 0;
        let codex: BTreeSet<_> = [Service::Codex].into();
        assert_eq!(settings.load(|| { detections += 1; codex.clone() }), codex);
        assert_eq!(settings.load(|| { detections += 1; Service::ALL.into() }), codex, "detection runs only once");
        assert_eq!(detections, 1);

        settings.save(&BTreeSet::new());
        assert_eq!(settings.load(|| [Service::Claude].into()), BTreeSet::new(), "an empty choice is kept");
    }

    #[test]
    fn hover_pill_defaults_on_and_survives_service_changes() {
        let dir = tempfile::tempdir().unwrap();
        let settings = ServiceSettings { file: dir.path().join("settings.json") };
        assert!(settings.hover_pill());
        settings.set_hover_pill(false);
        settings.save(&[Service::Codex].into());
        assert!(!settings.hover_pill(), "saving services keeps the hover choice");
        assert_eq!(settings.load(BTreeSet::new), [Service::Codex].into());
    }

    #[test]
    fn floating_defaults_off_and_remembers_its_corner() {
        let dir = tempfile::tempdir().unwrap();
        let settings = ServiceSettings { file: dir.path().join("settings.json") };
        assert!(!settings.floating());
        assert_eq!(settings.floating_position(), None);
        settings.set_floating(true);
        settings.set_floating_position((-1200, 40));
        settings.save(&[Service::Claude].into());
        assert!(settings.floating(), "saving services keeps the floating choice");
        assert_eq!(settings.floating_position(), Some((-1200, 40)));
    }

    #[test]
    fn detect_installed_uses_cli_or_config_folder() {
        let home = tempfile::tempdir().unwrap();
        assert_eq!(detect_installed(home.path(), |_| None), BTreeSet::new());
        std::fs::create_dir_all(home.path().join(".claude")).unwrap();
        assert_eq!(detect_installed(home.path(), |_| None), [Service::Claude].into());
        let with_codex = detect_installed(home.path(), |name| (name == "codex").then(|| PathBuf::from("/x/codex")));
        assert_eq!(with_codex, [Service::Claude, Service::Codex].into());
    }

    #[test]
    fn intervals_alerts_updates_and_shortcuts_are_saved() {
        let dir = tempfile::tempdir().unwrap();
        let settings = ServiceSettings { file: dir.path().join("settings.json") };
        assert!(settings.live_intervals().is_empty());
        assert_eq!(settings.low_balance_threshold(), None);
        assert!(settings.balance_alerts());
        assert!(settings.auto_update_check());
        assert_eq!(settings.hot_keys(), HotKeys::default());

        settings.set_live_intervals(&[(Service::Claude, 600.0), (Service::DeepSeek, 120.0)].into());
        settings.set_low_balance_threshold(Some(5.0));
        settings.set_balance_alerts(false);
        settings.set_auto_update_check(false);
        let mut keys = HotKeys::default();
        keys.set(crate::hotkeys::HotKeyAction::HoverPill, None);
        settings.set_hot_keys(&keys);
        settings.save(&[Service::DeepSeek].into());

        assert_eq!(settings.live_intervals(), [(Service::Claude, 600.0), (Service::DeepSeek, 120.0)].into());
        assert_eq!(settings.low_balance_threshold(), Some(5.0));
        assert!(!settings.balance_alerts());
        assert!(!settings.auto_update_check());
        assert_eq!(settings.hot_keys(), keys);
        assert_eq!(settings.load(BTreeSet::new), [Service::DeepSeek].into());
        settings.set_low_balance_threshold(Some(0.0));
        assert_eq!(settings.low_balance_threshold(), None, "zero turns it off");

        let json: serde_json::Value = serde_json::from_slice(&std::fs::read(&settings.file).unwrap()).unwrap();
        assert_eq!(json["liveIntervals"], serde_json::json!({"claude": 600.0, "deepseek": 120.0}));
        assert_eq!(json["hotKeys"], serde_json::json!({"hoverPill": null}));
        assert!(json.get("deepseekLowBalance").is_none_or(serde_json::Value::is_null));
        let text = String::from_utf8(std::fs::read(&settings.file).unwrap()).unwrap();
        assert!(!text.contains("sk-"), "no key is ever written here");
    }
}
