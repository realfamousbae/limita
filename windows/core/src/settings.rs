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
}

impl ServiceSettings {
    /// The stored set, or the result of `detect` on first launch (which is then stored).
    pub fn load(&self, detect: impl FnOnce() -> BTreeSet<Service>) -> BTreeSet<Service> {
        let stored = std::fs::read(&self.file)
            .ok()
            .and_then(|data| serde_json::from_slice::<Stored>(&data).ok())
            .and_then(|stored| stored.enabled_services);
        if let Some(raw) = stored {
            return raw.iter().filter_map(|id| Service::from_id(id)).collect();
        }
        let detected = detect();
        self.save(&detected);
        detected
    }

    pub fn save(&self, services: &BTreeSet<Service>) {
        let stored = Stored {
            enabled_services: Some(services.iter().map(|s| s.id().to_string()).collect()),
        };
        if let Some(parent) = self.file.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_vec_pretty(&stored) {
            let _ = crate::claude_cache::write_atomically(&self.file, &json);
        }
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
    fn detect_installed_uses_cli_or_config_folder() {
        let home = tempfile::tempdir().unwrap();
        assert_eq!(detect_installed(home.path(), |_| None), BTreeSet::new());
        std::fs::create_dir_all(home.path().join(".claude")).unwrap();
        assert_eq!(detect_installed(home.path(), |_| None), [Service::Claude].into());
        let with_codex = detect_installed(home.path(), |name| (name == "codex").then(|| PathBuf::from("/x/codex")));
        assert_eq!(with_codex, Service::ALL.into());
    }
}
