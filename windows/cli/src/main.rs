//! `limita-cli`: the console half of Limita for Windows.
//!
//! - `--capture-claude-status`: Claude Code's status-line command (see `statusline`).
//!   A GUI executable has no usable stdout on Windows, hence this separate console tool.
//! - `--dump`: reads every source once and prints what Limita would show.
//! - `--remove-hook`: restores Claude Code's own status line; run by the uninstaller.

use std::io::{Read, Write};

use chrono::Utc;
use limita_core::statusline::{self, Configurator};
use limita_core::store::{Sources, Store};
use limita_core::{claude_cache::ClaudeStatusCache, codex_live::CodexLiveClient, locator, paths, view, Service};

fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    let code = match arguments.get(1).map(String::as_str) {
        Some(statusline::FLAG) => capture(&arguments),
        Some("--dump") => dump(),
        Some("--remove-hook") => remove_hook(),
        _ => {
            eprintln!("usage: limita-cli --capture-claude-status | --dump | --remove-hook");
            2
        }
    };
    std::process::exit(code);
}

fn capture(arguments: &[String]) -> i32 {
    let mut input = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut input);
    let mut stdout = std::io::stdout().lock();
    let code = statusline::run(
        arguments,
        &input,
        &ClaudeStatusCache::default_path(),
        &statusline::default_wrapped_file(),
        &mut stdout,
        Utc::now(),
    );
    let _ = stdout.flush();
    code
}

fn remove_hook() -> i32 {
    let Ok(executable) = std::env::current_exe() else { return 1 };
    match Configurator::new(executable).uninstall() {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("Limita: {error}");
            1
        }
    }
}

/// Everything a first check on a new machine needs, without the app or its settings.
fn dump() -> i32 {
    println!("home:            {}", paths::home().display());
    println!("app data:        {}", paths::app_data().display());
    println!("claude CLI:      {}", describe(locator::find("claude")));
    println!("codex CLI:       {}", describe(locator::find("codex")));
    println!("codex to start:  {}", describe(CodexLiveClient::default().find_executable()));
    let credentials = paths::claude_dir().join(".credentials.json");
    println!("claude login:    {} ({})", credentials.display(), if credentials.is_file() { "found" } else { "missing" });
    #[cfg(windows)]
    println!("git bash:        {}", describe(statusline::git_bash()));
    if let Ok(executable) = std::env::current_exe() {
        let configurator = Configurator::new(executable);
        println!("status line:     {:?}", configurator.status());
        println!("stable location: {}", configurator.is_running_from_stable_location());
    }
    println!();

    // All services, and settings in a throwaway file so the app's choice is untouched.
    let mut sources = Sources::standard(None);
    sources.settings.file = std::env::temp_dir().join(format!("limita-dump-{}.json", std::process::id()));
    let settings_file = sources.settings.file.clone();
    let store = Store::new(sources, || Service::ALL.into(), || {});
    if let Some(worker) = store.refresh(true) {
        let _ = worker.join();
    }
    let _ = std::fs::remove_file(settings_file);

    let snapshot = store.snapshot();
    let now = Utc::now();
    println!("{}", view::tray(&snapshot, now).tooltip);
    println!();
    match serde_json::to_string_pretty(&view::panel(&snapshot, now)) {
        Ok(json) => println!("{json}"),
        Err(error) => eprintln!("{error}"),
    }
    0
}

fn describe(path: Option<std::path::PathBuf>) -> String {
    path.map_or("not found".into(), |p| p.display().to_string())
}
