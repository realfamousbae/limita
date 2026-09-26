//! Limita as Claude Code's status-line command: `limita-cli --capture-claude-status`.
//! Port of `ClaudeStatusLine.swift`, adapted to Windows.
//!
//! Claude Code pipes a JSON payload to stdin and shows whatever the command prints.
//! Limita stores the rate limits from that payload, then either runs the user's own
//! status-line command with the same stdin (so their status line keeps working) or,
//! with nothing to wrap, prints a short summary of the limits itself.
//!
//! Unlike the macOS app, the wrapped command is not embedded in Limita's command line:
//! it is kept in `wrapped-statusline.json` next to the cache. Quoting a command inside a
//! command is different in Git Bash, cmd and PowerShell; a plain quoted path is not.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::claude_cache::{self, ClaudeStatusCache};
use crate::paths;
use crate::time::Timestamp;

pub const FLAG: &str = "--capture-claude-status";
pub const WRAP_SEPARATOR: &str = "--";

/// Where the user's own status-line command is kept while Limita wraps it.
pub fn default_wrapped_file() -> PathBuf {
    paths::app_data().join("wrapped-statusline.json")
}

#[derive(Serialize, Deserialize)]
struct Wrapped {
    command: String,
}

fn load_wrapped(file: &Path) -> Option<String> {
    let data = std::fs::read(file).ok()?;
    serde_json::from_slice::<Wrapped>(&data).ok().map(|w| w.command).filter(|c| !c.trim().is_empty())
}

// MARK: - The command Claude Code runs

/// Runs the status-line command and returns the process exit code. Capture failures are
/// reported on stderr but never block the wrapped command: the user's status line
/// matters more than our cache.
pub fn run(
    arguments: &[String],
    input: &[u8],
    cache_file: &Path,
    wrapped_file: &Path,
    output: &mut dyn Write,
    now: Timestamp,
) -> i32 {
    let cache = match claude_cache::capture(input, cache_file, now) {
        Ok(cache) => cache,
        Err(error) => {
            eprintln!("Limita: {error}");
            None
        }
    };
    if let Some(wrapped) = wrapped_command_in(arguments).or_else(|| load_wrapped(wrapped_file)) {
        return run_shell(&wrapped, input, output);
    }
    if let Some(cache) = cache {
        let _ = writeln!(output, "{}", summary(&cache));
    }
    0
}

/// A command wrapped inline, as the macOS app writes it: `limita --capture-claude-status -- '<cmd>'`.
pub fn wrapped_command_in(arguments: &[String]) -> Option<String> {
    let flag = arguments.iter().position(|a| a == FLAG)?;
    let separator = flag + arguments[flag..].iter().position(|a| a == WRAP_SEPARATOR)?;
    arguments.get(separator + 1).filter(|c| !c.is_empty()).cloned()
}

pub fn summary(cache: &ClaudeStatusCache) -> String {
    [("5h", cache.five_hour), ("7d", cache.seven_day)]
        .into_iter()
        .filter_map(|(label, window)| window.map(|w| format!("{label} {}", w.percent_text(cache.captured_at))))
        .collect::<Vec<_>>()
        .join(" · ")
}

fn run_shell(command: &str, input: &[u8], output: &mut dyn Write) -> i32 {
    let mut process = shell_command(command);
    process.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit());
    let mut child = match process.spawn() {
        Ok(child) => child,
        Err(error) => {
            eprintln!("Limita: could not run the status line: {error}");
            return 1;
        }
    };
    // The command may exit without reading stdin; a closed pipe must not stop us.
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input);
    }
    match child.wait_with_output() {
        Ok(result) => {
            let _ = output.write_all(&result.stdout);
            result.status.code().unwrap_or(1)
        }
        Err(error) => {
            eprintln!("Limita: the status line failed: {error}");
            1
        }
    }
}

/// Claude Code on Windows runs commands through Git Bash; the wrapped command was written
/// for it, so it runs there too, with `cmd` as the fallback when Git Bash is missing.
#[cfg(windows)]
fn shell_command(command: &str) -> Command {
    use std::os::windows::process::CommandExt;
    if let Some(bash) = git_bash() {
        let mut process = Command::new(bash);
        process.args(["-c", command]);
        return process;
    }
    let mut process = Command::new("cmd");
    process.arg("/D").arg("/S").arg("/C").raw_arg(format!("\"{command}\""));
    process
}

#[cfg(windows)]
pub fn git_bash() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CLAUDE_CODE_GIT_BASH_PATH").map(PathBuf::from) {
        if path.is_file() {
            return Some(path);
        }
    }
    let program_files = [std::env::var_os("ProgramFiles"), std::env::var_os("ProgramW6432")];
    for root in program_files.into_iter().flatten() {
        let path = PathBuf::from(root).join("Git").join("bin").join("bash.exe");
        if path.is_file() {
            return Some(path);
        }
    }
    if let Some(local) = dirs::data_local_dir() {
        let path = local.join("Programs").join("Git").join("bin").join("bash.exe");
        if path.is_file() {
            return Some(path);
        }
    }
    None
}

#[cfg(not(windows))]
fn shell_command(command: &str) -> Command {
    let mut process = Command::new("/bin/sh");
    process.args(["-c", command]);
    process
}

// MARK: - Installing the hook

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
    NotConfigured,
    /// Someone else's status line; installing will wrap it.
    Foreign(String),
    Installed { executable: String, wrapped: Option<String> },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Installed,
    Wrapped,
    Updated,
    AlreadyConfigured,
}

/// Installs `limita-cli` as Claude Code's status-line command in `~/.claude/settings.json`.
/// An existing status line is wrapped rather than replaced, and restored on removal.
#[derive(Clone, Debug)]
pub struct Configurator {
    pub settings_file: PathBuf,
    /// `limita-cli`, which Claude Code will run.
    pub executable: PathBuf,
    pub wrapped_file: PathBuf,
    /// Folders an installed Limita lives in; see `is_running_from_stable_location`.
    pub stable_roots: Vec<PathBuf>,
}

impl Configurator {
    pub fn new(executable: PathBuf) -> Self {
        Self {
            settings_file: paths::claude_dir().join("settings.json"),
            executable,
            wrapped_file: default_wrapped_file(),
            stable_roots: default_stable_roots(),
        }
    }

    /// Only an installed app has a stable path. A build under `target\`, or a copy in
    /// Downloads, moves or disappears, and a hook pointing there blanks the status line.
    pub fn is_running_from_stable_location(&self) -> bool {
        let path = normalized(&self.executable.to_string_lossy());
        if path.contains("/target/") {
            return false;
        }
        self.stable_roots.iter().any(|root| {
            let root = normalized(&root.to_string_lossy());
            path.starts_with(&format!("{}/", root.trim_end_matches('/')))
        })
    }

    pub fn status(&self) -> Result<Status, String> {
        Ok(self.status_of(&self.load_settings()?))
    }

    pub fn install(&self) -> Result<Outcome, String> {
        let mut settings = self.load_settings()?;
        let (outcome, wrapped) = match self.status_of(&settings) {
            Status::NotConfigured => (Outcome::Installed, None),
            Status::Foreign(command) => (Outcome::Wrapped, Some(command)),
            Status::Installed { executable, wrapped } => {
                if same_path(&executable, &self.executable.to_string_lossy()) {
                    return Ok(Outcome::AlreadyConfigured);
                }
                (Outcome::Updated, wrapped)
            }
        };
        self.save_wrapped(wrapped.as_deref())?;

        let status_line = settings
            .entry("statusLine")
            .or_insert_with(|| Value::Object(Map::new()));
        if !status_line.is_object() {
            *status_line = Value::Object(Map::new());
        }
        let status_line = status_line.as_object_mut().expect("just made an object");
        status_line.insert("type".into(), "command".into());
        status_line.insert("command".into(), self.command().into());
        self.write(&settings)?;
        Ok(outcome)
    }

    /// Restores the wrapped status line, or removes ours if there was none.
    pub fn uninstall(&self) -> Result<(), String> {
        let mut settings = self.load_settings()?;
        let Status::Installed { wrapped, .. } = self.status_of(&settings) else { return Ok(()) };
        match (wrapped, settings.get_mut("statusLine").and_then(Value::as_object_mut)) {
            (Some(wrapped), Some(status_line)) => {
                status_line.insert("command".into(), wrapped.into());
            }
            _ => {
                settings.remove("statusLine");
            }
        }
        self.write(&settings)?;
        let _ = std::fs::remove_file(&self.wrapped_file);
        Ok(())
    }

    /// Re-points an installed hook whose executable no longer exists (the app was moved
    /// or reinstalled elsewhere). Returns whether anything changed.
    pub fn repair_if_needed(&self) -> Result<bool, String> {
        let Status::Installed { executable, .. } = self.status()? else { return Ok(false) };
        if same_path(&executable, &self.executable.to_string_lossy())
            || Path::new(&executable).exists()
            || !self.is_running_from_stable_location()
        {
            return Ok(false);
        }
        Ok(self.install()? == Outcome::Updated)
    }

    /// `"C:/Users/…/limita-cli.exe" --capture-claude-status`: a double-quoted path with
    /// forward slashes reads the same in Git Bash and cmd.
    pub fn command(&self) -> String {
        let path = self.executable.to_string_lossy().replace('\\', "/");
        format!("\"{path}\" {FLAG}")
    }

    fn status_of(&self, settings: &Map<String, Value>) -> Status {
        let Some(command) = settings
            .get("statusLine")
            .and_then(|s| s.get("command"))
            .and_then(Value::as_str)
            .filter(|c| !c.trim().is_empty())
        else {
            return Status::NotConfigured;
        };
        match shell_words::split(command) {
            Some(words) if words.len() >= 2 && words[1] == FLAG => Status::Installed {
                executable: words[0].clone(),
                wrapped: wrapped_command_in(&words).or_else(|| load_wrapped(&self.wrapped_file)),
            },
            _ => Status::Foreign(command.to_string()),
        }
    }

    fn save_wrapped(&self, wrapped: Option<&str>) -> Result<(), String> {
        match wrapped {
            Some(command) => {
                if let Some(parent) = self.wrapped_file.parent() {
                    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                }
                let json = serde_json::to_vec_pretty(&Wrapped { command: command.into() }).map_err(|e| e.to_string())?;
                claude_cache::write_atomically(&self.wrapped_file, &json)
            }
            None => {
                let _ = std::fs::remove_file(&self.wrapped_file);
                Ok(())
            }
        }
    }

    fn load_settings(&self) -> Result<Map<String, Value>, String> {
        let Ok(data) = std::fs::read(&self.settings_file) else { return Ok(Map::new()) };
        if data.iter().all(u8::is_ascii_whitespace) {
            return Ok(Map::new());
        }
        match serde_json::from_slice::<Value>(&data) {
            Ok(Value::Object(object)) => Ok(object),
            _ => Err("Could not read ~/.claude/settings.json: it is not a JSON object.".into()),
        }
    }

    fn write(&self, settings: &Map<String, Value>) -> Result<(), String> {
        if let Some(parent) = self.settings_file.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        // Keep the user's original settings once, before our first change.
        let backup = PathBuf::from(format!("{}.limita-backup", self.settings_file.display()));
        if self.settings_file.exists() && !backup.exists() {
            std::fs::copy(&self.settings_file, &backup).map_err(|e| format!("could not back up settings: {e}"))?;
        }
        let mut json = serde_json::to_vec_pretty(settings).map_err(|e| e.to_string())?;
        json.push(b'\n');
        claude_cache::write_atomically(&self.settings_file, &json)
    }
}

fn default_stable_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    #[cfg(windows)]
    {
        // The per-user NSIS install goes to %LOCALAPPDATA%\Limita.
        roots.extend(dirs::data_local_dir());
        roots.extend(std::env::var_os("ProgramFiles").map(PathBuf::from));
    }
    #[cfg(not(windows))]
    {
        roots.push("/Applications".into());
        roots.push(paths::home().join("Applications"));
    }
    roots
}

/// Forward slashes, and case-insensitive on Windows.
fn normalized(path: &str) -> String {
    let path = path.replace('\\', "/");
    if cfg!(windows) { path.to_lowercase() } else { path }
}

fn same_path(a: &str, b: &str) -> bool {
    normalized(a) == normalized(b)
}

/// Minimal POSIX-shell word splitting — enough to recognise the commands we write.
pub mod shell_words {
    pub fn quote(value: &str) -> String {
        format!("'{}'", value.replace('\'', "'\\''"))
    }

    /// Splits on unquoted whitespace, honouring single quotes, double quotes and
    /// backslash escapes. Returns `None` for unbalanced quotes.
    pub fn split(command: &str) -> Option<Vec<String>> {
        let mut words = Vec::new();
        let mut current = String::new();
        let mut in_word = false;
        let mut chars = command.chars();
        while let Some(c) = chars.next() {
            match c {
                '\'' => {
                    in_word = true;
                    loop {
                        match chars.next()? {
                            '\'' => break,
                            next => current.push(next),
                        }
                    }
                }
                '"' => {
                    in_word = true;
                    loop {
                        match chars.next()? {
                            '"' => break,
                            '\\' => {
                                let escaped = chars.next()?;
                                if !"\"\\$`".contains(escaped) {
                                    current.push('\\');
                                }
                                current.push(escaped);
                            }
                            next => current.push(next),
                        }
                    }
                }
                '\\' => {
                    in_word = true;
                    if let Some(escaped) = chars.next() {
                        current.push(escaped);
                    }
                }
                c if c.is_whitespace() => {
                    if in_word {
                        words.push(std::mem::take(&mut current));
                        in_word = false;
                    }
                }
                c => {
                    in_word = true;
                    current.push(c);
                }
            }
        }
        if in_word {
            words.push(current);
        }
        Some(words)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::from_unix;

    struct Fixture {
        _dir: tempfile::TempDir,
        root: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path().to_path_buf();
            Self { _dir: dir, root }
        }

        fn configurator(&self, executable: &str) -> Configurator {
            Configurator {
                settings_file: self.root.join("settings.json"),
                executable: executable.into(),
                wrapped_file: self.root.join("wrapped.json"),
                stable_roots: vec!["/Apps".into()],
            }
        }

        fn settings(&self) -> Value {
            serde_json::from_slice(&std::fs::read(self.root.join("settings.json")).unwrap()).unwrap()
        }
    }

    const APP: &str = "/Apps/Limita/limita-cli.exe";

    #[test]
    fn wraps_existing_status_line_and_restores_it() {
        let fixture = Fixture::new();
        let original = r#"jq -r '"[\(.model.display_name)] \(.context_window.used_percentage // 0)% context"'"#;
        let json = serde_json::json!({"model": "opus", "statusLine": {"type": "command", "command": original, "padding": 2}});
        std::fs::write(fixture.root.join("settings.json"), json.to_string()).unwrap();

        let configurator = fixture.configurator(APP);
        assert_eq!(configurator.status().unwrap(), Status::Foreign(original.into()));
        assert_eq!(configurator.install().unwrap(), Outcome::Wrapped);
        assert_eq!(
            configurator.status().unwrap(),
            Status::Installed { executable: APP.into(), wrapped: Some(original.into()) }
        );
        assert_eq!(configurator.install().unwrap(), Outcome::AlreadyConfigured);

        let installed = fixture.settings();
        assert_eq!(installed["model"], "opus");
        assert_eq!(installed["statusLine"]["padding"], 2);
        assert_eq!(installed["statusLine"]["command"], format!("\"{APP}\" {FLAG}"));
        assert!(fixture.root.join("settings.json.limita-backup").exists());

        configurator.uninstall().unwrap();
        assert_eq!(configurator.status().unwrap(), Status::Foreign(original.into()));
        assert_eq!(fixture.settings()["statusLine"]["padding"], 2);
        assert!(!fixture.root.join("wrapped.json").exists());
    }

    #[test]
    fn installs_alone_and_uninstall_removes_it() {
        let fixture = Fixture::new();
        let path = r"C:\Users\Jo Doe\AppData\Local\Limita\limita-cli.exe";
        let configurator = fixture.configurator(path);
        assert_eq!(configurator.install().unwrap(), Outcome::Installed);
        assert_eq!(
            fixture.settings()["statusLine"]["command"],
            format!("\"C:/Users/Jo Doe/AppData/Local/Limita/limita-cli.exe\" {FLAG}")
        );
        assert_eq!(configurator.install().unwrap(), Outcome::AlreadyConfigured, "slashes do not matter");
        configurator.uninstall().unwrap();
        assert_eq!(configurator.status().unwrap(), Status::NotConfigured);
        assert!(fixture.settings().get("statusLine").is_none());
    }

    #[test]
    fn recognises_the_macos_inline_form() {
        let fixture = Fixture::new();
        let command = format!("'/Applications/Limita.app/Contents/MacOS/Limita' {FLAG} -- 'echo hi'");
        std::fs::write(fixture.root.join("settings.json"), serde_json::json!({"statusLine": {"command": command}}).to_string()).unwrap();
        assert_eq!(
            fixture.configurator(APP).status().unwrap(),
            Status::Installed { executable: "/Applications/Limita.app/Contents/MacOS/Limita".into(), wrapped: Some("echo hi".into()) }
        );
    }

    #[test]
    fn updates_path_of_moved_app_only_from_a_stable_location() {
        let fixture = Fixture::new();
        assert_eq!(fixture.configurator("/old/limita-cli.exe").install().unwrap(), Outcome::Installed);
        assert!(!fixture.configurator("/work/target/debug/limita-cli").repair_if_needed().unwrap());
        assert!(fixture.configurator(APP).repair_if_needed().unwrap());
        assert_eq!(fixture.configurator(APP).status().unwrap(), Status::Installed { executable: APP.into(), wrapped: None });
    }

    #[test]
    fn only_install_folders_count_as_stable() {
        let fixture = Fixture::new();
        assert!(fixture.configurator(APP).is_running_from_stable_location());
        assert!(!fixture.configurator("/Apps/Limita/target/release/limita-cli").is_running_from_stable_location());
        assert!(!fixture.configurator("/Downloads/limita-cli.exe").is_running_from_stable_location());
        assert!(!fixture.configurator("/Appsx/limita-cli.exe").is_running_from_stable_location());
    }

    #[test]
    fn rejects_non_object_settings() {
        let fixture = Fixture::new();
        std::fs::write(fixture.root.join("settings.json"), "[1,2]").unwrap();
        assert!(fixture.configurator(APP).install().is_err());
        assert_eq!(std::fs::read_to_string(fixture.root.join("settings.json")).unwrap(), "[1,2]");
    }

    #[cfg(unix)]
    #[test]
    fn command_runs_wrapped_status_line_with_same_input() {
        let fixture = Fixture::new();
        let cache = fixture.root.join("claude.json");
        let wrapped = fixture.root.join("wrapped.json");
        std::fs::write(&wrapped, r#"{"command":"sed 's/.*display_name\":\"\\([^\"]*\\)\".*/[\\1]/'"}"#).unwrap();
        let input = r#"{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1893456000}}}"#;
        let mut output = Vec::new();
        let now = from_unix(1_800_000_000.0).unwrap();
        let status = run(&["x".into(), FLAG.into()], input.as_bytes(), &cache, &wrapped, &mut output, now);
        assert_eq!(status, 0);
        assert_eq!(String::from_utf8(output).unwrap(), "[Opus]");
        let state = crate::claude_cache::ClaudeLimitsReader { cache_file: cache }.read(true, now);
        assert_eq!(state.snapshot().unwrap().five_hour.unwrap().used_percent, 12.0);
    }

    #[test]
    fn command_prints_summary_without_wrapped_status_line() {
        let fixture = Fixture::new();
        let input = r#"{"rate_limits":{"five_hour":{"used_percentage":12.4},"seven_day":{"used_percentage":40}}}"#;
        let mut output = Vec::new();
        run(
            &["x".into(), FLAG.into()],
            input.as_bytes(),
            &fixture.root.join("claude.json"),
            &fixture.root.join("wrapped.json"),
            &mut output,
            from_unix(1_800_000_000.0).unwrap(),
        );
        assert_eq!(String::from_utf8(output).unwrap(), "5h 12% · 7d 40%\n");
    }

    #[test]
    fn shell_words_round_trip() {
        let words = ["/Applications/My App.app/Limita", FLAG, "--", r#"jq -r '"\(.a) it's"'"#];
        let command = words.iter().map(|w| shell_words::quote(w)).collect::<Vec<_>>().join(" ");
        assert_eq!(shell_words::split(&command).unwrap(), words);
        assert_eq!(shell_words::split(r#"a "b \"c\"" d\ e"#).unwrap(), ["a", r#"b "c""#, "d e"]);
        assert_eq!(shell_words::split("a 'b"), None);
    }
}
