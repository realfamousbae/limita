//! Codex rate limits from the Codex CLI's own session logs. Port of `CodexLimitsReader.swift`.
//!
//! Codex writes a rollout JSONL per session under
//! `~/.codex/sessions/YYYY/MM/DD/rollout-<ISO8601>-<uuid>.jsonl`, appending a
//! `token_count` event after every assistant response. Those events carry the live limits:
//!
//! ```json
//! {"type":"event_msg","payload":{"type":"token_count","rate_limits":{
//!   "primary":  {"used_percent":96.0,"window_minutes":300,"resets_at":1789751544},
//!   "secondary":{"used_percent":55.0,"window_minutes":10080,"resets_at":1790268541}}}}
//! ```
//!
//! We take the newest session file and scan it backwards for the last such event.
//! Windows are classified by `window_minutes` rather than by the `primary`/`secondary`
//! key, since those names describe ordering, not duration.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::model::{LimitSnapshot, LimitWindow, ServiceState};
use crate::paths;
use crate::tail::TailLines;
use crate::time::{from_unix, parse_flexible, Timestamp};

/// How old a snapshot may be before the UI marks it stale.
pub const STALE_AFTER: f64 = 30.0 * 60.0;

#[derive(Clone, Debug)]
pub struct CodexLimitsReader {
    pub sessions_dir: PathBuf,
    pub archived_sessions_dir: PathBuf,
}

impl Default for CodexLimitsReader {
    fn default() -> Self {
        let codex = paths::codex_dir();
        Self {
            sessions_dir: codex.join("sessions"),
            archived_sessions_dir: codex.join("archived_sessions"),
        }
    }
}

impl CodexLimitsReader {
    /// Never fails: every failure is `Unavailable` with a reason for the user.
    pub fn read(&self, now: Timestamp) -> ServiceState {
        let files = self.session_files_newest_first();
        if files.is_empty() {
            return ServiceState::Unavailable("Codex CLI not found or has no sessions yet".into());
        }
        for (path, modified) in files {
            if let Some(snapshot) = last_snapshot(&path, modified.unwrap_or(now)) {
                return ServiceState::from_snapshot(snapshot, STALE_AFTER, now);
            }
        }
        ServiceState::Unavailable("Codex sessions contain no limit data yet".into())
    }

    fn session_files_newest_first(&self) -> Vec<(PathBuf, Option<Timestamp>)> {
        let mut files = Vec::new();
        collect_rollouts(&self.sessions_dir, true, &mut files);
        collect_rollouts(&self.archived_sessions_dir, false, &mut files);
        let mut dated: Vec<_> = files
            .into_iter()
            .map(|path| {
                let modified = std::fs::metadata(&path)
                    .and_then(|m| m.modified())
                    .ok()
                    .map(Timestamp::from);
                (path, modified)
            })
            .collect();
        dated.sort_by_key(|entry| std::cmp::Reverse(entry.1));
        dated
    }
}

fn collect_rollouts(dir: &Path, recursive: bool, into: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') {
            continue;
        }
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            if recursive {
                collect_rollouts(&path, true, into);
            }
        } else if name.starts_with("rollout-") && name.ends_with(".jsonl") {
            into.push(path);
        }
    }
}

/// Scans `file` from the end and returns the newest usable rate-limit snapshot.
///
/// Records without any 5h/7d window are skipped: Codex also logs other buckets (e.g.
/// `premium`) whose `primary`/`secondary` are null.
pub fn last_snapshot(file: &Path, fallback_date: Timestamp) -> Option<LimitSnapshot> {
    for line in TailLines::open(file) {
        // Cheap pre-filter: most lines are transcript, not rate limits.
        if !line.contains("\"rate_limits\"") {
            continue;
        }
        // One malformed line must not abort the scan — transcripts can be truncated
        // mid-write if the CLI was killed.
        let Ok(record) = serde_json::from_str::<RolloutRecord>(&line) else { continue };
        let Some(limits) = record.payload.and_then(|p| p.rate_limits) else { continue };
        let captured_at = record
            .timestamp
            .as_deref()
            .and_then(parse_flexible)
            .unwrap_or(fallback_date);
        let snapshot = snapshot(&limits, captured_at);
        if !snapshot.is_empty() {
            return Some(snapshot);
        }
    }
    None
}

/// Classifies `primary`/`secondary` by duration into 5-hour and weekly windows.
pub fn snapshot(payload: &RateLimitsPayload, captured_at: Timestamp) -> LimitSnapshot {
    let mut five_hour = None;
    let mut seven_day = None;
    for entry in [&payload.primary, &payload.secondary].into_iter().flatten() {
        let Some(window) = entry.limit_window() else { continue };
        match entry.scale() {
            WindowScale::FiveHour => five_hour = five_hour.or(Some(window)),
            WindowScale::SevenDay => seven_day = seven_day.or(Some(window)),
            WindowScale::Unknown => {}
        }
    }
    // Codex puts the shortest window in `primary`. A weekly `primary` with no
    // `secondary` is how it reports a plan without a 5-hour limit.
    let weekly_only = payload.primary.as_ref().map(Entry::scale) == Some(WindowScale::SevenDay)
        && payload.secondary.is_none();
    LimitSnapshot::with_flag(five_hour, seven_day, captured_at, weekly_only)
}

#[derive(Deserialize)]
struct RolloutRecord {
    timestamp: Option<String>,
    payload: Option<Payload>,
}

#[derive(Deserialize)]
struct Payload {
    rate_limits: Option<RateLimitsPayload>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct RateLimitsPayload {
    pub primary: Option<Entry>,
    pub secondary: Option<Entry>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Entry {
    pub used_percent: Option<f64>,
    pub window_minutes: Option<f64>,
    pub resets_at: Option<f64>,
}

impl Entry {
    fn limit_window(&self) -> Option<LimitWindow> {
        let used = self.used_percent.filter(|value| value.is_finite())?;
        Some(LimitWindow::new(used, self.resets_at.and_then(from_unix)))
    }

    /// Classify by duration, tolerating small drift in what the server reports.
    fn scale(&self) -> WindowScale {
        match self.window_minutes {
            Some(minutes) if minutes > 0.0 && within_10_percent(minutes, 300.0) => WindowScale::FiveHour,
            Some(minutes) if minutes > 0.0 && within_10_percent(minutes, 10080.0) => WindowScale::SevenDay,
            _ => WindowScale::Unknown,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WindowScale {
    FiveHour,
    SevenDay,
    Unknown,
}

fn within_10_percent(value: f64, target: f64) -> bool {
    (value - target).abs() <= target * 0.1
}


#[cfg(test)]
mod tests {
    use super::*;
    use filetime::{set_file_mtime, FileTime};

    #[test]
    fn skips_newest_session_without_limits() {
        let root = tempfile::tempdir().unwrap();
        let sessions = root.path().join("sessions/2026/09/19");
        let archived = root.path().join("archived");
        std::fs::create_dir_all(&sessions).unwrap();
        std::fs::create_dir_all(&archived).unwrap();
        let valid = sessions.join("rollout-old.jsonl");
        let empty = sessions.join("rollout-new.jsonl");
        std::fs::write(&valid, r#"{"payload":{"rate_limits":{"primary":{"used_percent":42,"window_minutes":300,"resets_at":1893456000},"secondary":{"used_percent":73,"window_minutes":10080,"resets_at":1894060800}}}}"#).unwrap();
        std::fs::write(&empty, r#"{"payload":{}}"#).unwrap();
        set_file_mtime(&valid, FileTime::from_unix_time(100, 0)).unwrap();
        set_file_mtime(&empty, FileTime::from_unix_time(200, 0)).unwrap();

        let reader = CodexLimitsReader {
            sessions_dir: root.path().join("sessions"),
            archived_sessions_dir: archived,
        };
        let state = reader.read(from_unix(200.0).unwrap());
        let snapshot = state.snapshot().unwrap();
        assert_eq!(snapshot.five_hour.unwrap().used_percent, 42.0);
        assert_eq!(snapshot.seven_day.unwrap().used_percent, 73.0);
    }

    #[test]
    fn skips_buckets_without_windows_and_uses_record_timestamp() {
        let root = tempfile::tempdir().unwrap();
        let sessions = root.path().join("sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        let lines = [
            r#"{"timestamp":"2026-09-23T11:29:40.211Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1790180964},"secondary":{"used_percent":98.0,"window_minutes":10080,"resets_at":1790268541}}}}"#,
            r#"{"timestamp":"2026-09-23T11:30:00Z","payload":{"type":"message","text":"hello"}}"#,
            r#"{"timestamp":"2026-09-23T11:31:00Z","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}"#,
        ];
        std::fs::write(sessions.join("rollout-a.jsonl"), lines.join("\n")).unwrap();

        let reader = CodexLimitsReader {
            sessions_dir: sessions,
            archived_sessions_dir: root.path().join("missing"),
        };
        let state = reader.read(parse_flexible("2026-09-23T11:35:00Z").unwrap());
        let snapshot = state.snapshot().unwrap();
        assert_eq!(snapshot.five_hour.unwrap().used_percent, 1.0);
        assert_eq!(snapshot.seven_day.unwrap().used_percent, 98.0);
        assert_eq!(snapshot.captured_at, parse_flexible("2026-09-23T11:29:40.211Z").unwrap());
        assert!(!state.is_stale());
    }

    #[test]
    fn team_plan_reports_only_the_weekly_window() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("rollout-team.jsonl");
        std::fs::write(&file, r#"{"timestamp":"2026-09-13T16:30:00Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":34.0,"window_minutes":10080,"resets_at":1789897438},"secondary":null,"plan_type":"team"}}}"#).unwrap();
        let snapshot = last_snapshot(&file, from_unix(1.0).unwrap()).unwrap();
        assert!(snapshot.five_hour.is_none());
        assert_eq!(snapshot.seven_day.unwrap().used_percent, 34.0);
        assert!(snapshot.has_no_five_hour_limit);
    }

    #[test]
    fn missing_five_hour_window_is_unknown_unless_the_source_says_so() {
        let now = from_unix(1.0).unwrap();
        let payload = RateLimitsPayload {
            primary: None,
            secondary: Some(Entry { used_percent: Some(40.0), window_minutes: Some(10080.0), resets_at: None }),
        };
        let codex = snapshot(&payload, now);
        assert!(!codex.has_no_five_hour_limit);
        assert!(codex.headline().is_none());
        assert_eq!(ServiceState::Fresh(codex).level(now), None);
    }
}
