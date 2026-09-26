//! The Claude Code status-line capture: what `limita-cli --capture-claude-status` writes
//! and the app reads. Port of `ClaudeLimitsReader.swift` and `ClaudeStatusCapture`.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Deserializer, Serialize};

use crate::model::{LimitSnapshot, LimitWindow, ServiceState};
use crate::paths;
use crate::time::{from_unix, parse_flexible, Timestamp};

pub const STALE_AFTER: f64 = 30.0 * 60.0;

/// The only data persisted from Claude's status-line JSON. No transcript, prompt,
/// project path, account information, or credential is retained. Same JSON as the
/// macOS app writes.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeStatusCache {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub five_hour: Option<LimitWindow>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seven_day: Option<LimitWindow>,
    #[serde(with = "crate::time::iso_seconds")]
    pub captured_at: Timestamp,
}

impl ClaudeStatusCache {
    pub fn default_path() -> PathBuf {
        paths::app_data().join("claude-status.json")
    }

    pub fn snapshot(&self) -> LimitSnapshot {
        LimitSnapshot::new(self.five_hour, self.seven_day, self.captured_at)
    }
}

#[derive(Clone, Debug)]
pub struct ClaudeLimitsReader {
    pub cache_file: PathBuf,
}

impl Default for ClaudeLimitsReader {
    fn default() -> Self {
        Self { cache_file: ClaudeStatusCache::default_path() }
    }
}

impl ClaudeLimitsReader {
    /// `is_connected` only picks the wording of the "no data" reason: the cache may still
    /// hold data from before the hook was removed, which is shown as stale.
    pub fn read(&self, is_connected: bool, now: Timestamp) -> ServiceState {
        let Ok(data) = std::fs::read(&self.cache_file) else {
            return ServiceState::Unavailable(if is_connected {
                "Start Claude Code — limits appear after its first response".into()
            } else {
                "Connect Claude Code to see its limits".into()
            });
        };
        let Ok(cache) = serde_json::from_slice::<ClaudeStatusCache>(&data) else {
            return ServiceState::Unavailable(
                "Claude cache is corrupted — wait for the next Claude Code response".into(),
            );
        };
        let snapshot = cache.snapshot();
        if snapshot.is_empty() {
            return ServiceState::Unavailable("Claude Code has not reported limits yet".into());
        }
        ServiceState::from_snapshot(snapshot, STALE_AFTER, now)
    }
}

/// Persists the rate limits from a status-line payload. Returns what was written, or
/// `None` when the payload carried no limits — the previous cache is then kept, since
/// Claude Code omits limits until the first response of a session.
pub fn capture(input: &[u8], destination: &Path, now: Timestamp) -> Result<Option<ClaudeStatusCache>, String> {
    let payload: StatusLineInput =
        serde_json::from_slice(input).map_err(|error| format!("status-line input is not JSON: {error}"))?;
    let limits = payload.rate_limits.unwrap_or_default();
    let cache = ClaudeStatusCache {
        five_hour: limits.five_hour().and_then(Entry::limit_window),
        seven_day: limits.seven_day().and_then(Entry::limit_window),
        captured_at: now,
    };
    if cache.snapshot().is_empty() {
        return Ok(None);
    }
    if let Some(parent) = destination.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("could not create {}: {error}", parent.display()))?;
    }
    let json = serde_json::to_vec(&cache).map_err(|error| error.to_string())?;
    write_atomically(destination, &json)?;
    Ok(Some(cache))
}

/// Writes through a temporary file and a rename, so the app never reads half a file.
pub fn write_atomically(destination: &Path, data: &[u8]) -> Result<(), String> {
    let temporary = destination.with_extension("tmp");
    std::fs::write(&temporary, data).map_err(|error| format!("could not write {}: {error}", temporary.display()))?;
    std::fs::rename(&temporary, destination)
        .map_err(|error| format!("could not replace {}: {error}", destination.display()))
}

#[derive(Deserialize)]
struct StatusLineInput {
    #[serde(default, deserialize_with = "lenient")]
    rate_limits: Option<RateLimits>,
}

#[derive(Default, Deserialize)]
struct RateLimits {
    #[serde(default, deserialize_with = "lenient")]
    five_hour: Option<Entry>,
    #[serde(default, deserialize_with = "lenient")]
    seven_day: Option<Entry>,
    #[serde(default, deserialize_with = "lenient")]
    limits: Option<WindowSet>,
}

impl RateLimits {
    fn five_hour(&self) -> Option<&Entry> {
        self.five_hour.as_ref().or_else(|| self.limits.as_ref()?.five_hour.as_ref())
    }

    fn seven_day(&self) -> Option<&Entry> {
        self.seven_day.as_ref().or_else(|| self.limits.as_ref()?.seven_day.as_ref())
    }
}

#[derive(Deserialize)]
struct WindowSet {
    #[serde(default, deserialize_with = "lenient")]
    five_hour: Option<Entry>,
    #[serde(default, deserialize_with = "lenient")]
    seven_day: Option<Entry>,
}

#[derive(Deserialize)]
struct Entry {
    #[serde(default, deserialize_with = "lenient")]
    used_percentage: Option<f64>,
    #[serde(default, deserialize_with = "lenient")]
    utilization: Option<f64>,
    #[serde(default, deserialize_with = "flexible_date")]
    resets_at: Option<Timestamp>,
}

impl Entry {
    fn limit_window(&self) -> Option<LimitWindow> {
        let percentage = self
            .used_percentage
            .or(self.utilization.map(|value| if value <= 1.0 { value * 100.0 } else { value }))
            .filter(|value| value.is_finite())?;
        Some(LimitWindow::new(percentage, self.resets_at))
    }
}

/// A field of an unexpected shape reads as absent instead of failing the whole payload.
fn lenient<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: serde::de::DeserializeOwned,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    Ok(serde_json::from_value(value).ok())
}

/// ISO 8601 text or seconds since 1970.
fn flexible_date<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Timestamp>, D::Error> {
    Ok(match serde_json::Value::deserialize(deserializer)? {
        serde_json::Value::String(text) => parse_flexible(&text),
        serde_json::Value::Number(number) => number.as_f64().and_then(from_unix),
        _ => None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_keeps_only_rate_limits_and_reader_returns_fresh_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let destination = dir.path().join("claude.json");
        let input = r#"{
          "session_id":"secret-session",
          "transcript_path":"/private/transcript.jsonl",
          "rate_limits":{
            "five_hour":{"used_percentage":18.5,"resets_at":"2030-01-01T10:00:00Z"},
            "seven_day":{"used_percentage":64,"resets_at":"2030-01-07T10:00:00.123Z"}
          }
        }"#;
        let now = from_unix(1_800_000_000.0).unwrap();
        capture(input.as_bytes(), &destination, now).unwrap();

        let persisted = std::fs::read_to_string(&destination).unwrap();
        assert!(!persisted.contains("secret-session"));
        assert!(!persisted.contains("transcript"));

        let reader = ClaudeLimitsReader { cache_file: destination };
        let state = reader.read(true, from_unix(1_800_000_060.0).unwrap());
        let snapshot = state.snapshot().unwrap();
        assert_eq!(snapshot.five_hour.unwrap().used_percent, 18.5);
        assert_eq!(snapshot.seven_day.unwrap().used_percent, 64.0);
        assert!(!state.is_stale());
    }

    #[test]
    fn capture_does_not_replace_good_cache_when_limits_are_missing() {
        let dir = tempfile::tempdir().unwrap();
        let destination = dir.path().join("claude.json");
        let now = from_unix(1_800_000_000.0).unwrap();
        capture(br#"{"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":"2030-01-01T10:00:00Z"}}}"#, &destination, now).unwrap();
        let original = std::fs::read(&destination).unwrap();
        assert_eq!(capture(br#"{"rate_limits":null}"#, &destination, now).unwrap(), None);
        assert_eq!(std::fs::read(&destination).unwrap(), original);
    }

    #[test]
    fn capture_accepts_nested_utilization_shape() {
        let dir = tempfile::tempdir().unwrap();
        let destination = dir.path().join("claude.json");
        let now = from_unix(1_800_000_000.0).unwrap();
        capture(br#"{"rate_limits":{"limits":{"five_hour":{"utilization":0.4,"resets_at":1893456000}}}}"#, &destination, now).unwrap();
        let state = ClaudeLimitsReader { cache_file: destination }.read(true, now);
        let window = state.snapshot().unwrap().five_hour.unwrap();
        assert_eq!(window.used_percent, 40.0);
        assert_eq!(window.resets_at, from_unix(1_893_456_000.0));
    }

    #[test]
    fn reads_the_macos_app_cache_format() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("claude.json");
        std::fs::write(&file, r#"{"capturedAt":"2026-09-26T10:00:00Z","fiveHour":{"resetsAt":"2026-09-26T12:00:00Z","usedPercent":12}}"#).unwrap();
        let state = ClaudeLimitsReader { cache_file: file.clone() }.read(true, parse_flexible("2026-09-26T10:05:00Z").unwrap());
        assert_eq!(state.snapshot().unwrap().five_hour.unwrap().used_percent, 12.0);

        let written = serde_json::to_string(&ClaudeStatusCache {
            five_hour: Some(LimitWindow::new(12.0, parse_flexible("2026-09-26T12:00:00.5Z"))),
            seven_day: None,
            captured_at: parse_flexible("2026-09-26T10:00:00.25Z").unwrap(),
        })
        .unwrap();
        assert_eq!(written, r#"{"fiveHour":{"usedPercent":12.0,"resetsAt":"2026-09-26T12:00:00Z"},"capturedAt":"2026-09-26T10:00:00Z"}"#);
    }
}
