//! Tokens per local day for each service, read from the CLIs' own session logs, and
//! the GitHub-style grid the activity panel shows. Port of `ActivityReader.swift` and
//! `ActivityGrid.swift`; the counting and shading rules are the same.
//!
//! - Claude Code: every assistant line in `~/.claude/projects/**/*.jsonl` carries the
//!   request's `usage`. Resumed and forked sessions copy earlier lines into new files,
//!   so a request is counted once by `message.id` + `requestId`, whatever file it is in.
//! - Codex: `token_count` events in `~/.codex/sessions/**/rollout-*.jsonl` carry the
//!   session's running total; a day gets the growth of that total during it.
//!
//! Tokens are everything the model processed: input, output, cache writes and cache
//! reads (Codex counts cached input inside its input). Claude Code deletes old
//! transcripts (30 days by default), so the totals are kept in `activity.json`: a day
//! is only ever raised, never lowered because its files are gone.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

use chrono::{Datelike, Duration, NaiveDate, TimeZone};
use serde::Serialize;
use serde_json::Value;

use crate::model::Service;
use crate::paths;
use crate::time::parse_flexible;

/// "2026-10-16" → tokens.
pub type Days = BTreeMap<String, u64>;

pub const WEEKS: usize = 53;

pub struct ActivityReader {
    claude_projects: PathBuf,
    codex_dirs: Vec<PathBuf>,
    history: PathBuf,
    cache: Mutex<Cache>,
}

/// A transcript's requests by `message.id` + `requestId`: (day, tokens).
type Requests = HashMap<String, (String, u64)>;

#[derive(Default)]
struct Cache {
    claude: HashMap<PathBuf, Cached<Requests>>,
    codex: HashMap<PathBuf, Cached<Days>>,
}

struct Cached<T> {
    size: u64,
    modified: Option<SystemTime>,
    value: T,
}

impl Default for ActivityReader {
    fn default() -> Self {
        Self::new(&paths::home(), paths::app_data().join("activity.json"))
    }
}

impl ActivityReader {
    pub fn new(home: &Path, history: PathBuf) -> Self {
        let codex = home.join(".codex");
        Self {
            claude_projects: home.join(".claude").join("projects"),
            codex_dirs: vec![codex.join("sessions"), codex.join("archived_sessions")],
            history,
            cache: Mutex::new(Cache::default()),
        }
    }

    /// Scans the logs of `services`, merges them into the saved history and returns it.
    /// Slow on first run (every log is parsed); unchanged files are not re-read later.
    pub fn read<Tz: TimeZone>(&self, services: &[Service], tz: &Tz) -> BTreeMap<Service, Days> {
        let mut cache = self.cache.lock().unwrap_or_else(|p| p.into_inner());
        let mut history = self.load_history();
        for &service in services {
            let scanned = match service {
                Service::Claude => scan_claude(&mut cache, &self.claude_projects, tz),
                Service::Codex => scan_codex(&mut cache, &self.codex_dirs, tz),
            };
            merge(history.entry(service.id().to_string()).or_default(), &scanned);
        }
        self.save_history(&history);
        services
            .iter()
            .map(|&service| (service, history.get(service.id()).cloned().unwrap_or_default()))
            .collect()
    }

    fn load_history(&self) -> BTreeMap<String, Days> {
        std::fs::read(&self.history)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default()
    }

    fn save_history(&self, history: &BTreeMap<String, Days>) {
        if let Some(parent) = self.history.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_vec(history) {
            let _ = crate::claude_cache::write_atomically(&self.history, &json);
        }
    }
}

/// A day keeps the larger of its saved and scanned totals.
pub fn merge(saved: &mut Days, scanned: &Days) {
    for (day, &tokens) in scanned {
        let entry = saved.entry(day.clone()).or_insert(0);
        *entry = (*entry).max(tokens);
    }
}

fn day_key<Tz: TimeZone>(timestamp: &str, tz: &Tz) -> Option<String> {
    let date = parse_flexible(timestamp)?.with_timezone(tz).date_naive();
    Some(date.format("%Y-%m-%d").to_string())
}

// MARK: - Claude Code

fn scan_claude<Tz: TimeZone>(cache: &mut Cache, root: &Path, tz: &Tz) -> Days {
    refresh(&mut cache.claude, jsonl_files(root, |_| true), |data| claude_requests(data, tz));
    let mut requests: HashMap<&str, &(String, u64)> = HashMap::new();
    for file in cache.claude.values() {
        for (id, request) in &file.value {
            requests.entry(id.as_str()).or_insert(request);
        }
    }
    let mut days = Days::new();
    for (day, tokens) in requests.into_values() {
        *days.entry(day.clone()).or_insert(0) += tokens;
    }
    days
}

/// Requests in one transcript.
pub fn claude_requests<Tz: TimeZone>(data: &[u8], tz: &Tz) -> Requests {
    let mut requests = HashMap::new();
    for_each_line(data, b"\"usage\"", |object| {
        if object["type"].as_str() != Some("assistant") {
            return;
        }
        let message = &object["message"];
        let usage = &message["usage"];
        if !usage.is_object() {
            return;
        }
        let Some(day) = object["timestamp"].as_str().and_then(|t| day_key(t, tz)) else { return };
        let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .iter()
            .map(|key| usage[key].as_u64().unwrap_or(0))
            .sum();
        let request = object["requestId"].as_str().or(object["uuid"].as_str()).unwrap_or("");
        let id = format!("{}|{}", message["id"].as_str().unwrap_or(""), request);
        requests.insert(id, (day, tokens));
    });
    requests
}

// MARK: - Codex

fn scan_codex<Tz: TimeZone>(cache: &mut Cache, dirs: &[PathBuf], tz: &Tz) -> Days {
    let files = dirs
        .iter()
        .flat_map(|dir| {
            jsonl_files(dir, |path| path.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("rollout-")))
        })
        .collect();
    refresh(&mut cache.codex, files, |data| codex_days(data, tz));
    let mut days = Days::new();
    for file in cache.codex.values() {
        for (day, tokens) in &file.value {
            *days.entry(day.clone()).or_insert(0) += tokens;
        }
    }
    days
}

/// Growth of the session's running total, by the day of each `token_count` event.
/// Repeated events with the same total add nothing.
pub fn codex_days<Tz: TimeZone>(data: &[u8], tz: &Tz) -> Days {
    let mut days = Days::new();
    let mut previous = 0;
    for_each_line(data, b"\"token_count\"", |object| {
        let payload = &object["payload"];
        if payload["type"].as_str() != Some("token_count") {
            return;
        }
        let Some(total) = payload["info"]["total_token_usage"]["total_tokens"].as_u64() else { return };
        let Some(day) = object["timestamp"].as_str().and_then(|t| day_key(t, tz)) else { return };
        // A smaller total means the count started over.
        let growth = if total >= previous { total - previous } else { total };
        previous = total;
        if growth > 0 {
            *days.entry(day).or_insert(0) += growth;
        }
    });
    days
}

// MARK: - Files

struct FileInfo {
    path: PathBuf,
    size: u64,
    modified: Option<SystemTime>,
}

fn jsonl_files(root: &Path, include: impl Fn(&Path) -> bool + Copy) -> Vec<FileInfo> {
    let mut files = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                stack.push(path);
            } else if meta.is_file() && path.extension().is_some_and(|e| e == "jsonl") && include(&path) {
                files.push(FileInfo { path, size: meta.len(), modified: meta.modified().ok() });
            }
        }
    }
    files
}

/// Keeps cached results of unchanged files, parses the rest and forgets deleted ones.
fn refresh<T>(cache: &mut HashMap<PathBuf, Cached<T>>, files: Vec<FileInfo>, parse: impl Fn(&[u8]) -> T) {
    let mut next = HashMap::with_capacity(files.len());
    for file in files {
        match cache.remove(&file.path) {
            Some(cached) if cached.size == file.size && cached.modified == file.modified => {
                next.insert(file.path, cached);
            }
            _ => {
                if let Ok(data) = std::fs::read(&file.path) {
                    let value = parse(&data);
                    next.insert(file.path, Cached { size: file.size, modified: file.modified, value });
                }
            }
        }
    }
    *cache = next;
}

/// Calls `body` with each JSON object line that contains `needle`; the check skips
/// most lines without parsing them.
fn for_each_line(data: &[u8], needle: &[u8], mut body: impl FnMut(&Value)) {
    for line in data.split(|&b| b == b'\n') {
        if line.windows(needle.len()).any(|w| w == needle) {
            if let Ok(object) = serde_json::from_slice::<Value>(line) {
                body(&object);
            }
        }
    }
}

// MARK: - Grid

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityDay {
    pub key: String,
    /// 0 for no activity, 1...4 for the four shades.
    pub level: u8,
    /// "SUN, OCT 18, 2026", shown in the caption while the day is hovered.
    pub label: String,
    /// The chip over a hovered day: tokens in thousands.
    pub chip: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MonthLabel {
    pub column: usize,
    pub text: String,
}

/// One service's year: one column per week, Sunday on top, the newest week last.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityGrid {
    pub id: Service,
    /// `columns[week][weekday]`; `None` for the days after today in the last week.
    pub columns: Vec<Vec<Option<ActivityDay>>>,
    pub months: Vec<MonthLabel>,
    /// "433M TOKENS / YEAR".
    pub total: String,
}

pub fn grid(service: Service, days: &Days, today: NaiveDate) -> ActivityGrid {
    let this_week = today - Duration::days(today.weekday().num_days_from_sunday() as i64);
    let first = this_week - Duration::weeks(WEEKS as i64 - 1);
    let dates: Vec<Vec<Option<NaiveDate>>> = (0..WEEKS)
        .map(|week| {
            (0..7)
                .map(|day| {
                    let date = first + Duration::days((week * 7 + day) as i64);
                    (date <= today).then_some(date)
                })
                .collect()
        })
        .collect();
    let tokens = |date: NaiveDate| days.get(&date.format("%Y-%m-%d").to_string()).copied().unwrap_or(0);
    let values: Vec<u64> = dates.iter().flatten().flatten().map(|&d| tokens(d)).collect();
    let active: Vec<u64> = values.iter().copied().filter(|&v| v > 0).collect();
    let columns = dates
        .iter()
        .map(|week| {
            week.iter()
                .map(|date| {
                    date.map(|date| {
                        let value = tokens(date);
                        ActivityDay {
                            key: date.format("%Y-%m-%d").to_string(),
                            level: level(value, &active),
                            label: date.format("%a, %b %-d, %Y").to_string().to_uppercase(),
                            chip: thousands(value),
                        }
                    })
                })
                .collect()
        })
        .collect();
    let starts: Vec<NaiveDate> = dates.iter().map(|week| week[0].expect("week starts are past days")).collect();
    ActivityGrid {
        id: service,
        columns,
        months: month_labels(&starts),
        total: format!("{} TOKENS / YEAR", compact(values.iter().sum())),
    }
}

/// A day's shade is the share of active days with as many tokens or fewer, in
/// quarters: the busiest day is always the darkest, and one huge day does not wash out
/// the rest. The same rule as `ActivityGrid.swift` on macOS.
pub fn level(tokens: u64, active: &[u64]) -> u8 {
    if tokens == 0 || active.is_empty() {
        return 0;
    }
    let at_most = active.iter().filter(|&&v| v <= tokens).count();
    ((4 * at_most).div_ceil(active.len())).max(1) as u8
}

/// A label over the first week that starts in a new month. The first one is left out
/// when the next is too close for both to fit.
fn month_labels(starts: &[NaiveDate]) -> Vec<MonthLabel> {
    let mut labels: Vec<MonthLabel> = Vec::new();
    let mut previous = None;
    for (column, start) in starts.iter().enumerate() {
        if previous != Some(start.month()) {
            labels.push(MonthLabel { column, text: start.format("%b").to_string() });
        }
        previous = Some(start.month());
    }
    if labels.len() > 1 && labels[1].column - labels[0].column < 3 {
        labels.remove(0);
    }
    labels
}

/// "950", "12.3K", "4.5M", "1.2B".
pub fn compact(tokens: u64) -> String {
    let value = tokens as f64;
    for (size, suffix) in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")] {
        if value >= size {
            let scaled = value / size;
            let text = if scaled >= 100.0 { format!("{scaled:.0}") } else { format!("{scaled:.1}").replace(".0", "") };
            return text + suffix;
        }
    }
    tokens.to_string()
}

/// Thousands with separators, for the chip over a hovered day: "0K", "<1K", "12,346K".
pub fn thousands(tokens: u64) -> String {
    if tokens == 0 {
        return "0K".into();
    }
    if tokens < 500 {
        return "<1K".into();
    }
    let digits = ((tokens + 500) / 1000).to_string();
    let mut grouped = String::new();
    for (index, ch) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            grouped.push(',');
        }
        grouped.push(ch);
    }
    grouped + "K"
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;

    fn moscow() -> FixedOffset {
        FixedOffset::east_opt(3 * 3600).unwrap()
    }

    #[test]
    fn levels_split_active_days_into_quarters() {
        let active = [10, 20, 30, 40];
        assert_eq!(active.map(|v| level(v, &active)), [1, 2, 3, 4]);
        assert_eq!(level(0, &active), 0);
        assert_eq!(level(5, &[5]), 4, "the busiest day is always the darkest");
        assert_eq!([1, 1_000_000].map(|v| level(v, &[1, 1_000_000])), [2, 4]);
    }

    #[test]
    fn grid_ends_today_with_sunday_on_top() {
        let today = NaiveDate::from_ymd_opt(2026, 10, 19).unwrap(); // a Monday
        let days: Days = [("2026-10-18", 100), ("2026-10-19", 300), ("2025-01-01", 999)]
            .map(|(d, v)| (d.to_string(), v))
            .into();
        let grid = grid(Service::Claude, &days, today);
        assert_eq!(grid.columns.len(), WEEKS);
        let last = grid.columns.last().unwrap();
        assert_eq!(last[0].as_ref().unwrap().key, "2026-10-18");
        assert_eq!(last[1].as_ref().unwrap().label, "MON, OCT 19, 2026");
        assert!(last[2].is_none());
        assert_eq!(last[1].as_ref().unwrap().level, 4);
        assert_eq!(last[0].as_ref().unwrap().level, 2);
        assert_eq!(grid.total, "400 TOKENS / YEAR", "days before the first week are not counted");
        assert_eq!(grid.months.last().unwrap().text, "Oct");
    }

    #[test]
    fn token_formats() {
        assert_eq!(compact(950), "950");
        assert_eq!(compact(12_340), "12.3K");
        assert_eq!(compact(185_862_783), "186M");
        assert_eq!(compact(2_000_000), "2M");
        assert_eq!(thousands(0), "0K");
        assert_eq!(thousands(300), "<1K");
        assert_eq!(thousands(12_345_678), "12,346K");
        assert_eq!(thousands(999_400), "999K");
    }

    fn claude_line(id: &str, time: &str, input: u64) -> String {
        format!(
            r#"{{"type":"assistant","requestId":"r{id}","timestamp":"{time}","message":{{"id":"m{id}","usage":{{"input_tokens":{input},"output_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}}}}"#
        )
    }

    #[test]
    fn claude_requests_count_once_across_files_and_history_is_kept() {
        let home = tempfile::tempdir().unwrap();
        let project = home.path().join(".claude/projects/-p");
        std::fs::create_dir_all(&project).unwrap();
        let original = [claude_line("1", "2026-10-16T10:00:00.000Z", 10), claude_line("2", "2026-10-16T23:30:00Z", 20)];
        std::fs::write(project.join("a.jsonl"), original.join("\n")).unwrap();
        // A resumed session repeats request 1 and adds request 3.
        let resumed = [claude_line("1", "2026-10-16T10:00:00.000Z", 10), r#"{"type":"user"}"#.into(), claude_line("3", "2026-10-17T09:00:00Z", 30)];
        std::fs::write(project.join("b.jsonl"), resumed.join("\n")).unwrap();

        let history = home.path().join("activity.json");
        let expected: Days = [("2026-10-16".to_string(), 16), ("2026-10-17".to_string(), 62)].into();
        // 23:30 UTC is already the 17th in Moscow.
        let reader = ActivityReader::new(home.path(), history.clone());
        assert_eq!(reader.read(&[Service::Claude], &moscow())[&Service::Claude], expected);

        std::fs::remove_file(project.join("a.jsonl")).unwrap();
        let fresh = ActivityReader::new(home.path(), history);
        assert_eq!(fresh.read(&[Service::Claude], &moscow())[&Service::Claude], expected, "deleted transcripts do not lower saved days");
    }

    #[test]
    fn codex_counts_growth_of_the_running_total() {
        let event = |time: &str, total: u64| {
            format!(r#"{{"timestamp":"{time}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"total_tokens":{total}}}}}}}}}"#)
        };
        let log = [
            event("2026-10-16T10:00:00Z", 100),
            event("2026-10-16T10:00:01Z", 100),
            r#"{"timestamp":"2026-10-16T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#.into(),
            event("2026-10-17T10:00:00Z", 250),
        ]
        .join("\n");
        let days = codex_days(log.as_bytes(), &chrono::Utc);
        let expected: Days = [("2026-10-16".to_string(), 100), ("2026-10-17".to_string(), 150)].into();
        assert_eq!(days, expected);
    }
}
