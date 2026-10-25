//! Which services Limita tracks, persisted as JSON in the app-data folder. Port of
//! `ServiceSettings.swift`.
//!
//! On first launch the set is auto-detected from what is installed; after that the
//! user's connect/disconnect choices are kept as they are.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

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
/// reads credentials, so first launch never needs any permission.
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
    fn detect_installed_uses_cli_or_config_folder() {
        let home = tempfile::tempdir().unwrap();
        assert_eq!(detect_installed(home.path(), |_| None), BTreeSet::new());
        std::fs::create_dir_all(home.path().join(".claude")).unwrap();
        assert_eq!(detect_installed(home.path(), |_| None), [Service::Claude].into());
        let with_codex = detect_installed(home.path(), |name| (name == "codex").then(|| PathBuf::from("/x/codex")));
        assert_eq!(with_codex, Service::ALL.into());
    }
}
