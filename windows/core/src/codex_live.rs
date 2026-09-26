//! Current Codex rate limits from the Codex CLI's own app server (`codex app-server`,
//! JSON-RPC over stdio, method `account/rateLimits/read`). Port of `CodexLiveClient.swift`.
//!
//! Unlike the session logs, this asks the backend, so the numbers are current even when
//! Codex has not been used for hours. Authentication stays inside the CLI.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use serde::Deserialize;

use crate::codex_reader::{self, Entry, RateLimitsPayload};
use crate::locator;
use crate::model::{AccountDetails, LiveReading};
use crate::time::Timestamp;

const TIMEOUT: Duration = Duration::from_secs(20);

const MESSAGES: [&str; 3] = [
    r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"limita","title":"Limita","version":"1.0"},"capabilities":null}}"#,
    r#"{"jsonrpc":"2.0","method":"initialized"}"#,
    r#"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}"#,
];

#[derive(Clone, Debug, Default)]
pub struct CodexLiveClient {
    /// Overrides the CLI lookup; tests point it at nothing.
    pub executable: Option<PathBuf>,
    pub disabled: bool,
}

impl CodexLiveClient {
    /// The CLI to start: the native binary where an npm shim would add `cmd` and `node`.
    pub fn find_executable(&self) -> Option<PathBuf> {
        if self.disabled {
            return None;
        }
        if let Some(path) = &self.executable {
            return Some(path.clone());
        }
        let found = locator::find("codex")?;
        let is_shim = found
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("cmd") || ext.eq_ignore_ascii_case("bat"));
        if is_shim {
            if let Some(native) = locator::codex_native_beside_shim(&found) {
                return Some(native);
            }
        }
        Some(found)
    }

    pub fn fetch(&self, now: Timestamp) -> Result<LiveReading, String> {
        let executable = self.find_executable().ok_or("Codex CLI not found")?;
        let response = request(&executable, &["app-server"], &MESSAGES, 2, TIMEOUT)?;
        reading_from_response(&response, now)
    }
}

pub fn reading_from_response(data: &[u8], captured_at: Timestamp) -> Result<LiveReading, String> {
    let envelope: Envelope =
        serde_json::from_slice(data).map_err(|error| format!("Codex app-server returned invalid JSON: {error}"))?;
    if let Some(error) = envelope.error {
        return Err(format!("Codex: {}", error.message.unwrap_or_else(|| "app-server error".into())));
    }
    let result = envelope.result.ok_or("Codex app-server returned an empty response")?;
    let limits = result
        .rate_limits_by_limit_id
        .and_then(|mut by_id| by_id.remove("codex"))
        .or(result.rate_limits);
    let payload = RateLimitsPayload {
        primary: limits.as_ref().and_then(|l| l.primary.as_ref()).map(Window::entry),
        secondary: limits.as_ref().and_then(|l| l.secondary.as_ref()).map(Window::entry),
    };
    let snapshot = codex_reader::snapshot(&payload, captured_at);
    if snapshot.is_empty() {
        return Err("Codex app-server returned no limit windows".into());
    }

    let mut details = AccountDetails {
        limit_resets: result.rate_limit_reset_credits.and_then(|c| c.available_count),
        ..AccountDetails::default()
    };
    if let Some(credits) = limits.and_then(|l| l.credits) {
        details.codex_credits_unlimited = credits.unlimited.unwrap_or(false);
        // `balance` is a decimal string of credits, as the CLI's /status shows it.
        details.codex_credits = credits.balance.and_then(|b| b.trim().parse().ok());
    }
    Ok(LiveReading { snapshot, details })
}

// Wire format (camelCase, unlike the session logs).

#[derive(Deserialize)]
struct Envelope {
    result: Option<RpcResult>,
    error: Option<RpcError>,
}

#[derive(Deserialize)]
struct RpcError {
    message: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcResult {
    rate_limits: Option<Limits>,
    rate_limits_by_limit_id: Option<std::collections::HashMap<String, Limits>>,
    rate_limit_reset_credits: Option<ResetCredits>,
}

#[derive(Deserialize)]
struct Limits {
    primary: Option<Window>,
    secondary: Option<Window>,
    credits: Option<Credits>,
}

#[derive(Deserialize)]
struct Credits {
    unlimited: Option<bool>,
    balance: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResetCredits {
    available_count: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Window {
    used_percent: Option<f64>,
    window_duration_mins: Option<f64>,
    resets_at: Option<f64>,
}

impl Window {
    fn entry(&self) -> Entry {
        Entry {
            used_percent: self.used_percent,
            window_minutes: self.window_duration_mins,
            resets_at: self.resets_at,
        }
    }
}

// JSON-RPC session.

/// Runs a stdio JSON-RPC server just long enough to get the response with `response_id`.
pub fn request(
    executable: &Path,
    arguments: &[&str],
    messages: &[&str],
    response_id: i64,
    timeout: Duration,
) -> Result<Vec<u8>, String> {
    let mut command = Command::new(executable);
    command
        .args(arguments)
        .env("PATH", locator::child_path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    hide_console(&mut command);
    let mut child = command
        .spawn()
        .map_err(|error| format!("Could not start the Codex CLI: {error}"))?;
    // Whatever happens below, the server and anything it started must end with us.
    let guard = ChildGuard::new(&mut child);

    let stdout = guard.child.stdout.take().ok_or("Codex app-server has no output")?;
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            if response_id_of(&line) == Some(response_id) {
                let _ = sender.send(line);
                return;
            }
        }
    });

    let mut stdin = guard.child.stdin.take().ok_or("Codex app-server has no input")?;
    let payload: String = messages.iter().map(|m| format!("{m}\n")).collect();
    // A server that exits early closes the pipe; that surfaces below as "no response".
    let _ = stdin.write_all(payload.as_bytes()).and_then(|_| stdin.flush());

    let result = match receiver.recv_timeout(timeout) {
        Ok(line) => Ok(line.into_bytes()),
        Err(mpsc::RecvTimeoutError::Timeout) => {
            Err(format!("Codex app-server did not respond within {} s", timeout.as_secs()))
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => Err("Codex app-server exited without a response".into()),
    };
    drop(stdin);
    drop(guard);
    result
}

fn response_id_of(line: &str) -> Option<i64> {
    #[derive(Deserialize)]
    struct IdOnly {
        id: Option<serde_json::Value>,
    }
    serde_json::from_str::<IdOnly>(line).ok()?.id?.as_i64()
}

#[cfg(windows)]
fn hide_console(command: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    command.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
fn hide_console(_: &mut Command) {}

/// Kills the child when dropped. On Windows the child is also put in a job object that
/// kills every process in it when the job closes, so an npm shim's `node` and the real
/// `codex.exe` it starts cannot outlive a timeout.
struct ChildGuard<'a> {
    child: &'a mut Child,
    #[cfg(windows)]
    job: Option<job::Job>,
}

impl<'a> ChildGuard<'a> {
    fn new(child: &'a mut Child) -> Self {
        #[cfg(windows)]
        let job = job::Job::kill_on_close().filter(|job| job.assign(child));
        Self {
            child,
            #[cfg(windows)]
            job,
        }
    }
}

impl Drop for ChildGuard<'_> {
    fn drop(&mut self) {
        #[cfg(windows)]
        drop(self.job.take());
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(windows)]
mod job {
    use std::os::windows::io::AsRawHandle;
    use std::process::Child;

    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };

    pub struct Job(HANDLE);

    impl Job {
        pub fn kill_on_close() -> Option<Self> {
            unsafe {
                let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if handle.is_null() {
                    return None;
                }
                let job = Job(handle);
                let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                let ok = SetInformationJobObject(
                    job.0,
                    JobObjectExtendedLimitInformation,
                    &info as *const _ as *const _,
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                );
                (ok != 0).then_some(job)
            }
        }

        pub fn assign(&self, child: &Child) -> bool {
            unsafe { AssignProcessToJobObject(self.0, child.as_raw_handle() as HANDLE) != 0 }
        }
    }

    impl Drop for Job {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::from_unix;

    #[test]
    fn app_server_response_prefers_codex_bucket() {
        let response = r#"{"id":2,"result":{"rateLimits":{"limitId":"premium","primary":null,"secondary":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":1790215642},"secondary":{"usedPercent":98,"windowDurationMins":10080,"resetsAt":1790268541}}}}}"#;
        let now = from_unix(1_790_200_000.0).unwrap();
        let snapshot = reading_from_response(response.as_bytes(), now).unwrap().snapshot;
        let five = snapshot.five_hour.unwrap();
        assert_eq!(five.used_percent, 3.0);
        assert_eq!(five.resets_at, from_unix(1_790_215_642.0));
        assert_eq!(snapshot.seven_day.unwrap().used_percent, 98.0);
        assert_eq!(snapshot.captured_at, now);

        let error = r#"{"id":2,"error":{"code":-32600,"message":"not logged in"}}"#;
        assert_eq!(reading_from_response(error.as_bytes(), now).unwrap_err(), "Codex: not logged in");
    }

    #[test]
    fn details_read_resets_and_credits() {
        let response = r#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1790215642},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"250"}},"rateLimitsByLimitId":null,"rateLimitResetCredits":{"availableCount":2,"credits":null}}}"#;
        let details = reading_from_response(response.as_bytes(), from_unix(1.0).unwrap()).unwrap().details;
        assert_eq!(details.limit_resets, Some(2));
        assert_eq!(details.codex_credits, Some(250.0));
        assert!(!details.codex_credits_unlimited);
    }

    #[test]
    fn team_plan_shape_from_app_server() {
        let response = r#"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1789897438},"secondary":null}}}}"#;
        let snapshot = reading_from_response(response.as_bytes(), from_unix(1.0).unwrap()).unwrap().snapshot;
        assert!(snapshot.has_no_five_hour_limit);
        assert_eq!(snapshot.headline().map(|h| h.0), Some("7d"));
    }

    #[cfg(unix)]
    #[test]
    fn request_returns_the_matching_line_and_times_out() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("server.sh");
        std::fs::write(
            &script,
            "#!/bin/sh\nread a; read b; read c\necho '{\"id\":1,\"result\":{}}'\necho '{\"id\":2,\"result\":{\"ok\":true}}'\nsleep 30\n",
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let line = request(&script, &[], &MESSAGES, 2, Duration::from_secs(5)).unwrap();
        assert_eq!(String::from_utf8(line).unwrap(), r#"{"id":2,"result":{"ok":true}}"#);

        let started = std::time::Instant::now();
        let error = request(&script, &[], &MESSAGES, 3, Duration::from_millis(300)).unwrap_err();
        assert!(error.contains("did not respond"), "{error}");
        assert!(started.elapsed() < Duration::from_secs(5), "the server is killed on timeout");
    }
}
