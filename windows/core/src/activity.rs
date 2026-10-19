//! Activity per local day for each service, read from the CLIs' own session logs, and
//! the graph and summary the activity panel shows for a period. Port of
//! `ActivityReader.swift` and `ActivityGrid.swift`; the counting, layout and shading
//! rules are the same.
//!
//! - Claude Code: every assistant line in `~/.claude/projects/**/*.jsonl` carries the
//!   request's `usage` and model; user lines are your prompts. Resumed and forked
//!   sessions copy earlier lines into new files, so a request is counted once by
//!   `message.id` + `requestId` and a prompt once by its `uuid`, whatever file it is in.
//! - Codex: `token_count` events in `~/.codex/sessions/**/rollout-*.jsonl` carry the
//!   session's running total; a day gets the growth of that total during it. Codex
//!   counts cached input inside its input and writes no cache of its own, so cached
//!   input is a cache read and the rest is input. Messages are `user_message` and
//!   `agent_message` events, the model comes from `turn_context`.
//!
//! Claude Code deletes old transcripts (30 days by default), so the days are kept in
//! `activity.json` and only ever raised, never lowered because their files are gone.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

use chrono::{Datelike, Duration, NaiveDate, TimeZone, Timelike};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::model::Service;
use crate::paths;
use crate::time::parse_flexible;

/// "2026-10-16" → that day.
pub type Days = BTreeMap<String, DayStats>;

/// Tokens by kind.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TokenUsage {
    /// Input not served from the cache.
    pub input: u64,
    pub output: u64,
    pub cache_write: u64,
    pub cache_read: u64,
}

impl TokenUsage {
    pub fn total(&self) -> u64 {
        self.input + self.output + self.cache_write + self.cache_read
    }

    fn minus(&self, other: &TokenUsage) -> TokenUsage {
        TokenUsage {
            input: self.input.saturating_sub(other.input),
            output: self.output.saturating_sub(other.output),
            cache_write: self.cache_write.saturating_sub(other.cache_write),
            cache_read: self.cache_read.saturating_sub(other.cache_read),
        }
    }
}

/// What one service did on one local day. Stored in `activity.json`; the same format
/// on macOS.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, from = "StoredDay")]
pub struct DayStats {
    /// Everything the model processed: the four kinds added up.
    pub tokens: u64,
    pub input: u64,
    pub output: u64,
    pub cache_write: u64,
    pub cache_read: u64,
    /// Your prompts plus the model's replies.
    pub messages: u64,
    /// Tokens by model id.
    pub models: BTreeMap<String, u64>,
    /// Messages by local hour, 0...23.
    pub hours: Vec<u64>,
}

impl Default for DayStats {
    fn default() -> Self {
        Self {
            tokens: 0,
            input: 0,
            output: 0,
            cache_write: 0,
            cache_read: 0,
            messages: 0,
            models: BTreeMap::new(),
            hours: vec![0; 24],
        }
    }
}

/// Days saved by 0.8.0 are a bare token count.
#[derive(Deserialize)]
#[serde(untagged)]
enum StoredDay {
    Count(u64),
    Full(FullDay),
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct FullDay {
    tokens: u64,
    input: u64,
    output: u64,
    cache_write: u64,
    cache_read: u64,
    messages: u64,
    models: BTreeMap<String, u64>,
    hours: Vec<u64>,
}

impl From<StoredDay> for DayStats {
    fn from(stored: StoredDay) -> Self {
        match stored {
            StoredDay::Count(tokens) => DayStats { tokens, ..DayStats::default() },
            StoredDay::Full(day) => DayStats {
                tokens: day.tokens,
                input: day.input,
                output: day.output,
                cache_write: day.cache_write,
                cache_read: day.cache_read,
                messages: day.messages,
                models: day.models,
                hours: if day.hours.len() == 24 { day.hours } else { vec![0; 24] },
            },
        }
    }
}

impl DayStats {
    pub fn is_active(&self) -> bool {
        self.tokens > 0 || self.messages > 0
    }

    /// Saved days are only ever raised: each count keeps the larger value.
    pub fn merged(&self, other: &DayStats) -> DayStats {
        let mut models = self.models.clone();
        for (model, &tokens) in &other.models {
            let entry = models.entry(model.clone()).or_insert(0);
            *entry = (*entry).max(tokens);
        }
        DayStats {
            tokens: self.tokens.max(other.tokens),
            input: self.input.max(other.input),
            output: self.output.max(other.output),
            cache_write: self.cache_write.max(other.cache_write),
            cache_read: self.cache_read.max(other.cache_read),
            messages: self.messages.max(other.messages),
            models,
            hours: self.hours.iter().zip(&other.hours).map(|(a, b)| *a.max(b)).collect(),
        }
    }

    fn add(&mut self, event: &Event) {
        let tokens = event.usage.total();
        self.tokens += tokens;
        self.input += event.usage.input;
        self.output += event.usage.output;
        self.cache_write += event.usage.cache_write;
        self.cache_read += event.usage.cache_read;
        if event.is_message {
            self.messages += 1;
            self.hours[event.hour as usize] += 1;
        }
        if let (Some(model), true) = (&event.model, tokens > 0) {
            *self.models.entry(model.clone()).or_insert(0) += tokens;
        }
    }

    /// Adds another session's day.
    fn sum(&mut self, other: &DayStats) {
        self.tokens += other.tokens;
        self.input += other.input;
        self.output += other.output;
        self.cache_write += other.cache_write;
        self.cache_read += other.cache_read;
        self.messages += other.messages;
        for (model, tokens) in &other.models {
            *self.models.entry(model.clone()).or_insert(0) += tokens;
        }
        for (hour, count) in self.hours.iter_mut().zip(&other.hours) {
            *hour += count;
        }
    }
}

/// One counted thing in a log: a request's tokens, a message, or both.
#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    day: String,
    hour: u32,
    model: Option<String>,
    usage: TokenUsage,
    is_message: bool,
}

// MARK: - Reader

pub struct ActivityReader {
    claude_projects: PathBuf,
    codex_dirs: Vec<PathBuf>,
    history: PathBuf,
    cache: Mutex<Cache>,
}

#[derive(Default)]
struct Cache {
    claude: HashMap<PathBuf, Cached<HashMap<String, Event>>>,
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

pub fn merge(saved: &mut Days, scanned: &Days) {
    for (key, day) in scanned {
        let merged = saved.get(key).map_or_else(|| day.clone(), |old| old.merged(day));
        saved.insert(key.clone(), merged);
    }
}

fn day_and_hour<Tz: TimeZone>(timestamp: &str, tz: &Tz) -> Option<(String, u32)> {
    let local = parse_flexible(timestamp)?.with_timezone(tz);
    Some((local.date_naive().format("%Y-%m-%d").to_string(), local.hour()))
}

// MARK: - Claude Code

fn scan_claude<Tz: TimeZone>(cache: &mut Cache, root: &Path, tz: &Tz) -> Days {
    refresh(&mut cache.claude, jsonl_files(root, |_| true), |data| claude_events(data, tz));
    let mut events: HashMap<&str, &Event> = HashMap::new();
    for file in cache.claude.values() {
        for (id, event) in &file.value {
            events.entry(id.as_str()).or_insert(event);
        }
    }
    let mut days = Days::new();
    for event in events.into_values() {
        days.entry(event.day.clone()).or_default().add(event);
    }
    days
}

/// Events in one transcript: requests by `message.id` + `requestId`, prompts by `uuid`.
pub fn claude_events<Tz: TimeZone>(data: &[u8], tz: &Tz) -> HashMap<String, Event> {
    let mut events = HashMap::new();
    for_each_line(data, b"\"type\":", |object| {
        let kind = object["type"].as_str();
        if kind != Some("assistant") && kind != Some("user") {
            return;
        }
        let message = &object["message"];
        if !message.is_object() {
            return;
        }
        let Some((day, hour)) = object["timestamp"].as_str().and_then(|t| day_and_hour(t, tz)) else { return };
        if kind == Some("assistant") {
            let usage = &message["usage"];
            if !usage.is_object() {
                return;
            }
            let count = |key: &str| usage[key].as_u64().unwrap_or(0);
            let usage = TokenUsage {
                input: count("input_tokens"),
                output: count("output_tokens"),
                cache_write: count("cache_creation_input_tokens"),
                cache_read: count("cache_read_input_tokens"),
            };
            let model = message["model"].as_str().filter(|m| !m.starts_with('<')).map(String::from);
            let request = object["requestId"].as_str().or(object["uuid"].as_str()).unwrap_or("");
            let id = format!("a|{}|{}", message["id"].as_str().unwrap_or(""), request);
            events.insert(id, Event { day, hour, model, usage, is_message: true });
        } else if is_prompt(object, message) {
            if let Some(uuid) = object["uuid"].as_str() {
                let event = Event { day, hour, model: None, usage: TokenUsage::default(), is_message: true };
                events.insert(format!("u|{uuid}"), event);
            }
        }
    });
    events
}

/// A line you typed: not a tool result, not a subagent's prompt, not command output.
fn is_prompt(object: &Value, message: &Value) -> bool {
    if object["isMeta"].as_bool() == Some(true) || object["isSidechain"].as_bool() == Some(true) {
        return false;
    }
    match &message["content"] {
        Value::String(text) => !text.starts_with("<local-command-"),
        Value::Array(parts) => {
            parts.iter().any(|p| p["type"].as_str() == Some("text"))
                && !parts.iter().any(|p| p["type"].as_str() == Some("tool_result"))
        }
        _ => false,
    }
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
        for (key, day) in &file.value {
            days.entry(key.clone()).or_default().sum(day);
        }
    }
    days
}

/// One rollout is one session. Tokens are the growth of its running total by the day
/// of each `token_count` event; repeated events with the same total add nothing.
pub fn codex_days<Tz: TimeZone>(data: &[u8], tz: &Tz) -> Days {
    let mut days = Days::new();
    let mut previous = TokenUsage::default();
    let mut model: Option<String> = None;
    for_each_line(data, b"\"payload\"", |object| {
        let payload = &object["payload"];
        match object["type"].as_str() {
            Some("turn_context") => {
                if let Some(name) = payload["model"].as_str() {
                    model = Some(name.to_string());
                }
                return;
            }
            Some("event_msg") => {}
            _ => return,
        }
        let Some((day, hour)) = object["timestamp"].as_str().and_then(|t| day_and_hour(t, tz)) else { return };
        let mut event = Event { day, hour, model: model.clone(), usage: TokenUsage::default(), is_message: false };
        match payload["type"].as_str() {
            Some("user_message") | Some("agent_message") => event.is_message = true,
            Some("token_count") => {
                let usage = &payload["info"]["total_token_usage"];
                if !usage.is_object() {
                    return;
                }
                let count = |key: &str| usage[key].as_u64().unwrap_or(0);
                let cached = count("cached_input_tokens");
                let total = TokenUsage {
                    input: count("input_tokens").saturating_sub(cached),
                    output: count("output_tokens"),
                    cache_write: 0,
                    cache_read: cached,
                };
                // A smaller total means the count started over.
                event.usage = if total.total() >= previous.total() { total.minus(&previous) } else { total };
                previous = total;
                if event.usage.total() == 0 {
                    return;
                }
            }
            _ => return,
        }
        days.entry(event.day.clone()).or_default().add(&event);
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

// MARK: - Graph

/// What the activity panel shows: the last week, the last month, or everything saved
/// up to half a year.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Period {
    Week,
    Month,
    #[default]
    All,
}

impl Period {
    pub fn from_id(id: &str) -> Option<Period> {
        match id {
            "week" => Some(Period::Week),
            "month" => Some(Period::Month),
            "all" => Some(Period::All),
            _ => None,
        }
    }
}

pub const MAX_WEEKS: usize = 26;
/// Enough weeks to fill a column, however short the history.
pub const MIN_WEEKS: usize = 18;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Layout {
    /// The last 7 days in one row.
    Row,
    /// The last 5 weeks, a row per week from Monday.
    Calendar,
    /// A column per week, Monday on top.
    Weeks,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityDay {
    pub key: String,
    /// 0 for no activity, 1...4 for the four shades.
    pub level: u8,
    /// "SUN, OCT 18, 2026", shown under the graph while the day is hovered.
    pub label: String,
    /// The chip over a hovered day: tokens in thousands.
    pub chip: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Tile {
    pub label: String,
    pub value: String,
}

/// One service's graph and summary for a period. Port of `ActivityGrid.swift`.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityGrid {
    pub id: Service,
    pub layout: Layout,
    /// `cells[row][column]`; `None` after today.
    pub cells: Vec<Vec<Option<ActivityDay>>>,
    /// Over each column: weekday names, or the month where a week starts one.
    pub column_labels: Vec<Option<String>>,
    /// Left of each row: Mon, Wed and Fri in the weeks layout.
    pub row_labels: Vec<Option<String>>,
    /// Four to a row: the totals, then tokens by kind.
    pub summary: Vec<Tile>,
}

pub fn grid(service: Service, days: &Days, period: Period, today: NaiveDate) -> ActivityGrid {
    let this_monday = today - Duration::days(today.weekday().num_days_from_monday() as i64);
    let past = |date: NaiveDate| (date <= today).then_some(date);
    let (layout, dates): (Layout, Vec<Vec<Option<NaiveDate>>>) = match period {
        Period::Week => (Layout::Row, vec![(0..7).map(|d| Some(today - Duration::days(6 - d))).collect()]),
        Period::Month => (
            Layout::Calendar,
            (0..5)
                .map(|week| (0..7).map(|d| past(this_monday + Duration::days((week - 4) * 7 + d))).collect())
                .collect(),
        ),
        Period::All => {
            let first = days
                .iter()
                .filter(|(_, day)| day.is_active())
                .filter_map(|(key, _)| NaiveDate::parse_from_str(key, "%Y-%m-%d").ok())
                .min()
                .unwrap_or(today);
            let span = (this_monday - first).num_days().max(0) as usize;
            let weeks = (span.div_ceil(7) + 1).clamp(MIN_WEEKS, MAX_WEEKS) as i64;
            let dates = (0..7)
                .map(|d| (0..weeks).map(|week| past(this_monday + Duration::days((week - weeks + 1) * 7 + d))).collect())
                .collect();
            (Layout::Weeks, dates)
        }
    };

    let key = |date: NaiveDate| date.format("%Y-%m-%d").to_string();
    let shown: Vec<NaiveDate> = dates.iter().flatten().flatten().copied().collect();
    let tokens = |date: NaiveDate| days.get(&key(date)).map_or(0, |d| d.tokens);
    let active: Vec<u64> = shown.iter().map(|&d| tokens(d)).filter(|&t| t > 0).collect();
    let cells = dates
        .iter()
        .map(|row| {
            row.iter()
                .map(|date| {
                    date.map(|date| ActivityDay {
                        key: key(date),
                        level: level(tokens(date), &active),
                        label: date.format("%a, %b %-d, %Y").to_string().to_uppercase(),
                        chip: thousands(tokens(date)),
                    })
                })
                .collect()
        })
        .collect();

    let (column_labels, row_labels) = match layout {
        Layout::Row => (dates[0].iter().map(|d| d.map(|d| d.format("%a %-d").to_string())).collect(), vec![None]),
        Layout::Calendar => (
            ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map(|d| Some(d.to_string())).to_vec(),
            vec![None; 5],
        ),
        Layout::Weeks => {
            let mondays: Vec<NaiveDate> = dates[0].iter().map(|d| d.expect("Mondays are past days")).collect();
            let rows = ["Mon", "", "Wed", "", "Fri", "", ""];
            (month_labels(&mondays), rows.map(|r| (!r.is_empty()).then(|| r.to_string())).to_vec())
        }
    };

    let shown_days: Vec<&DayStats> = shown.iter().filter_map(|&d| days.get(&key(d))).collect();
    ActivityGrid { id: service, layout, cells, column_labels, row_labels, summary: summary(&shown_days) }
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

/// The month over the first week that starts in it. The first label is left out when
/// the next is too close for both to fit.
fn month_labels(mondays: &[NaiveDate]) -> Vec<Option<String>> {
    let mut labels = vec![None; mondays.len()];
    let mut placed = Vec::new();
    let mut previous = None;
    for (index, monday) in mondays.iter().enumerate() {
        if previous != Some(monday.month()) {
            labels[index] = Some(monday.format("%b").to_string());
            placed.push(index);
        }
        previous = Some(monday.month());
    }
    if placed.len() > 1 && placed[1] - placed[0] < 3 {
        labels[placed[0]] = None;
    }
    labels
}

fn summary(days: &[&DayStats]) -> Vec<Tile> {
    let sum = |f: fn(&DayStats) -> u64| days.iter().map(|d| f(d)).sum::<u64>();
    let mut models: BTreeMap<&str, u64> = BTreeMap::new();
    let mut hours = [0u64; 24];
    for day in days {
        for (model, tokens) in &day.models {
            *models.entry(model).or_insert(0) += tokens;
        }
        for (hour, count) in hours.iter_mut().zip(&day.hours) {
            *hour += count;
        }
    }
    // The most tokens; on a tie, the first id.
    let favorite = models.iter().max_by(|a, b| a.1.cmp(b.1).then(b.0.cmp(a.0))).map(|(id, _)| model_name(id));
    let busiest = *hours.iter().max().unwrap_or(&0);
    let peak = (busiest > 0).then(|| format!("{:02}:00", hours.iter().position(|&h| h == busiest).unwrap_or(0)));
    let tile = |label: &str, value: String| Tile { label: label.into(), value };
    vec![
        tile("TOTAL TOKENS", compact(sum(|d| d.tokens))),
        tile("FAVORITE MODEL", favorite.unwrap_or_else(|| "—".into())),
        tile("MESSAGES", grouped(sum(|d| d.messages))),
        tile("PEAK HOUR", peak.unwrap_or_else(|| "—".into())),
        tile("INPUT", compact(sum(|d| d.input))),
        tile("OUTPUT", compact(sum(|d| d.output))),
        tile("CACHE WRITE", compact(sum(|d| d.cache_write))),
        tile("CACHE READ", compact(sum(|d| d.cache_read))),
    ]
}

/// "claude-opus-5-5" → "Opus 5.5", "claude-3-5-haiku-20241022" → "Haiku 3.5"; other ids
/// as they are.
pub fn model_name(id: &str) -> String {
    let Some(rest) = id.strip_prefix("claude-") else { return id.to_string() };
    let parts: Vec<&str> = rest
        .split('-')
        .filter(|p| !(p.len() == 8 && p.chars().all(|c| c.is_ascii_digit())))
        .collect();
    let Some(family) = parts.iter().find(|p| p.chars().next().is_some_and(|c| c.is_alphabetic())) else {
        return id.to_string();
    };
    let version: Vec<&str> = parts.iter().copied().filter(|p| p.chars().all(|c| c.is_ascii_digit())).collect();
    let mut name: String = family[..1].to_uppercase() + &family[1..];
    if !version.is_empty() {
        name += &format!(" {}", version.join("."));
    }
    name
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

/// "3,685".
pub fn grouped(value: u64) -> String {
    let digits = value.to_string();
    let mut out = String::new();
    for (index, ch) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(ch);
    }
    out
}

/// Thousands with separators, for the chip over a hovered day: "0K", "<1K", "12,346K".
pub fn thousands(tokens: u64) -> String {
    match tokens {
        0 => "0K".into(),
        1..500 => "<1K".into(),
        _ => grouped((tokens + 500) / 1000) + "K",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;

    fn moscow() -> FixedOffset {
        FixedOffset::east_opt(3 * 3600).unwrap()
    }

    /// A Monday.
    fn today() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 10, 19).unwrap()
    }

    fn day(tokens: u64) -> DayStats {
        DayStats { tokens, ..DayStats::default() }
    }

    fn keys(row: &[Option<ActivityDay>]) -> Vec<Option<&str>> {
        row.iter().map(|d| d.as_ref().map(|d| d.key.as_str())).collect()
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
    fn week_is_the_last_seven_days_in_a_row() {
        let days: Days = [("2026-10-13".to_string(), day(5))].into();
        let grid = grid(Service::Claude, &days, Period::Week, today());
        assert_eq!(grid.layout, Layout::Row);
        assert_eq!(
            keys(&grid.cells[0]),
            ["2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18", "2026-10-19"].map(Some)
        );
        assert_eq!(grid.column_labels[0].as_deref(), Some("Tue 13"));
        assert_eq!(grid.cells[0][0].as_ref().unwrap().level, 4);
        assert_eq!(grid.cells[0][6].as_ref().unwrap().label, "MON, OCT 19, 2026");
    }

    #[test]
    fn month_is_five_calendar_weeks_from_monday() {
        let grid = grid(Service::Claude, &Days::new(), Period::Month, today());
        assert_eq!(grid.layout, Layout::Calendar);
        assert_eq!(grid.cells.len(), 5);
        assert_eq!(grid.cells[0][0].as_ref().unwrap().key, "2026-09-21");
        let last = grid.cells.last().unwrap();
        assert_eq!(last[0].as_ref().unwrap().key, "2026-10-19");
        assert!(last[1].is_none());
        assert_eq!(grid.column_labels[0].as_deref(), Some("Mon"));
    }

    #[test]
    fn all_starts_at_the_first_saved_week_within_half_a_year() {
        let recent = grid(Service::Claude, &[("2026-10-16".to_string(), day(1))].into(), Period::All, today());
        assert_eq!(recent.layout, Layout::Weeks);
        assert_eq!(recent.cells.len(), 7);
        assert_eq!(recent.cells[0].len(), MIN_WEEKS);
        assert_eq!(recent.cells[0][0].as_ref().unwrap().key, "2026-06-22");
        assert_eq!(recent.row_labels[0].as_deref(), Some("Mon"));
        assert!(recent.row_labels[1].is_none());
        assert_eq!(recent.cells[0].last().unwrap().as_ref().unwrap().key, "2026-10-19");
        assert!(recent.cells[1].last().unwrap().is_none());

        let five_months = grid(Service::Claude, &[("2026-05-20".to_string(), day(1))].into(), Period::All, today());
        assert_eq!(five_months.cells[0].len(), 23);
        assert_eq!(five_months.cells[0][0].as_ref().unwrap().key, "2026-05-18");

        let old = grid(Service::Claude, &[("2025-01-01".to_string(), day(1))].into(), Period::All, today());
        assert_eq!(old.cells[0].len(), MAX_WEEKS);
        assert_eq!(old.summary[0].value, "0", "days before the first week are not counted");
    }

    #[test]
    fn summary_counts_the_period() {
        let mut sunday = DayStats { tokens: 300, input: 10, output: 40, cache_write: 50, cache_read: 200, messages: 4, ..DayStats::default() };
        sunday.models = [("claude-opus-5-5".to_string(), 250), ("claude-sonnet-5-5".to_string(), 50)].into();
        sunday.hours[15] = 4;
        sunday.hours[9] = 1;
        let mut saturday = DayStats { tokens: 100, cache_read: 100, messages: 2, ..DayStats::default() };
        saturday.models = [("claude-sonnet-5-5".to_string(), 100)].into();
        saturday.hours[9] = 2;
        let days: Days =
            [("2026-10-17".to_string(), saturday), ("2026-10-18".to_string(), sunday), ("2026-09-01".to_string(), day(999))].into();
        let summary = grid(Service::Claude, &days, Period::Week, today()).summary;
        let values: Vec<(&str, &str)> = summary.iter().map(|t| (t.label.as_str(), t.value.as_str())).collect();
        assert_eq!(
            values,
            [
                ("TOTAL TOKENS", "400"),
                ("FAVORITE MODEL", "Opus 5.5"),
                ("MESSAGES", "6"),
                ("PEAK HOUR", "15:00"),
                ("INPUT", "10"),
                ("OUTPUT", "40"),
                ("CACHE WRITE", "50"),
                ("CACHE READ", "300"),
            ]
        );
    }

    #[test]
    fn model_names() {
        assert_eq!(model_name("claude-opus-5-5"), "Opus 5.5");
        assert_eq!(model_name("claude-3-5-haiku-20241022"), "Haiku 3.5");
        assert_eq!(model_name("claude-sonnet-4-20250514"), "Sonnet 4");
        assert_eq!(model_name("gpt-5.5-codex"), "gpt-5.5-codex");
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
        assert_eq!(grouped(3685), "3,685");
    }

    #[test]
    fn day_stats_read_the_old_format_and_merge_upwards() {
        let old: Days = serde_json::from_str(r#"{"2026-10-16":42}"#).unwrap();
        assert_eq!(old["2026-10-16"], day(42));
        let saved = DayStats { tokens: 10, cache_read: 10, hours: { let mut h = vec![0; 24]; h[3] = 5; h }, ..DayStats::default() };
        let scanned = DayStats { tokens: 8, input: 8, messages: 2, hours: { let mut h = vec![0; 24]; h[3] = 1; h }, ..DayStats::default() };
        let merged = saved.merged(&scanned);
        assert_eq!((merged.tokens, merged.input, merged.cache_read, merged.messages, merged.hours[3]), (10, 8, 10, 2, 5));
        let json = serde_json::to_string(&merged).unwrap();
        assert!(json.contains(r#""cacheRead":10"#), "same keys as macOS: {json}");
    }

    fn reply(id: &str, time: &str, input: u64) -> String {
        format!(
            r#"{{"type":"assistant","sessionId":"s1","requestId":"r{id}","timestamp":"{time}","message":{{"id":"m{id}","model":"claude-opus-5-5","usage":{{"input_tokens":{input},"output_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}}}}"#
        )
    }

    #[test]
    fn claude_requests_and_prompts_count_once_across_files() {
        let home = tempfile::tempdir().unwrap();
        let project = home.path().join(".claude/projects/-p");
        std::fs::create_dir_all(&project).unwrap();
        let prompt = r#"{"type":"user","sessionId":"s1","uuid":"u1","timestamp":"2026-10-16T09:59:00Z","message":{"role":"user","content":"hi"}}"#.to_string();
        let tool_result = r#"{"type":"user","sessionId":"s1","uuid":"u2","timestamp":"2026-10-16T10:00:30Z","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#.to_string();
        let original = [prompt.clone(), reply("1", "2026-10-16T10:00:00.000Z", 10), tool_result, reply("2", "2026-10-16T23:30:00Z", 20)];
        std::fs::write(project.join("a.jsonl"), original.join("\n")).unwrap();
        // A resumed session repeats the prompt and request 1, then adds request 3.
        let resumed = [prompt, reply("1", "2026-10-16T10:00:00.000Z", 10), reply("3", "2026-10-17T09:00:00Z", 30)];
        std::fs::write(project.join("b.jsonl"), resumed.join("\n")).unwrap();

        let history = home.path().join("activity.json");
        let reader = ActivityReader::new(home.path(), history.clone());
        let days = &reader.read(&[Service::Claude], &moscow())[&Service::Claude];
        // 23:30 UTC is already the 17th in Moscow.
        let tokens: Vec<(&str, u64)> = days.iter().map(|(k, d)| (k.as_str(), d.tokens)).collect();
        assert_eq!(tokens, [("2026-10-16", 16), ("2026-10-17", 62)]);
        assert_eq!(days["2026-10-16"].messages, 2, "the prompt and one reply; tool results are not prompts");
        assert_eq!((days["2026-10-16"].hours[12], days["2026-10-16"].hours[13]), (1, 1));
        let next = &days["2026-10-17"];
        assert_eq!(next.models, [("claude-opus-5-5".to_string(), 62)].into());
        assert_eq!((next.input, next.output, next.cache_write, next.cache_read), (50, 2, 4, 6));

        std::fs::remove_file(project.join("a.jsonl")).unwrap();
        let fresh = ActivityReader::new(home.path(), history);
        let again = &fresh.read(&[Service::Claude], &moscow())[&Service::Claude];
        assert_eq!(again["2026-10-16"].tokens, 16, "deleted transcripts do not lower saved days");
    }

    #[test]
    fn codex_counts_growth_messages_and_model() {
        // Input 100 of which 30 cached, output 20 at first; 200 / 80 cached / 50 later.
        let event = |time: &str, input: u64, cached: u64, output: u64| {
            format!(
                r#"{{"timestamp":"{time}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":{input},"cached_input_tokens":{cached},"output_tokens":{output},"total_tokens":{}}}}}}}}}"#,
                input + output
            )
        };
        let log = [
            r#"{"timestamp":"2026-10-16T09:00:01Z","type":"turn_context","payload":{"model":"gpt-5.5-codex"}}"#.to_string(),
            r#"{"timestamp":"2026-10-16T09:59:00Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}"#.into(),
            event("2026-10-16T10:00:00Z", 100, 30, 20),
            event("2026-10-16T10:00:01Z", 100, 30, 20),
            r#"{"timestamp":"2026-10-16T10:00:02Z","type":"event_msg","payload":{"type":"agent_message","message":"hello"}}"#.into(),
            r#"{"timestamp":"2026-10-16T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#.into(),
            event("2026-10-17T10:00:00Z", 200, 80, 50),
        ]
        .join("\n");
        let days = codex_days(log.as_bytes(), &chrono::Utc);
        let first = &days["2026-10-16"];
        assert_eq!((first.tokens, first.input, first.cache_read, first.output, first.messages), (120, 70, 30, 20, 2));
        assert_eq!(first.models, [("gpt-5.5-codex".to_string(), 120)].into());
        let second = &days["2026-10-17"];
        assert_eq!((second.tokens, second.input, second.cache_read, second.output), (130, 50, 50, 30));
    }
}
