//! Where Limita keeps its own files. Shared by the app and `limita-cli`, so both agree
//! on the cache location whatever Tauri would derive from the bundle identifier.

use std::path::PathBuf;

/// The user's home folder (`%USERPROFILE%` on Windows).
pub fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

/// `%APPDATA%\Limita` on Windows, `~/Library/Application Support/Limita` on macOS
/// (the same folder the macOS app uses, with the same file formats).
pub fn app_data() -> PathBuf {
    dirs::config_dir().unwrap_or_else(home).join("Limita")
}

pub fn claude_dir() -> PathBuf {
    home().join(".claude")
}

pub fn codex_dir() -> PathBuf {
    home().join(".codex")
}
