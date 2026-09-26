//! Finding the `claude` and `codex` CLIs from a GUI app. Port of `CLILocator`.
//!
//! A GUI process may not see the PATH a terminal has (and on macOS it never does), so
//! the usual install folders are searched first.

use std::path::{Path, PathBuf};

use crate::paths;

/// Install folders searched before PATH, most specific first.
pub fn search_directories() -> Vec<PathBuf> {
    let home = paths::home();
    let mut dirs = Vec::new();
    #[cfg(windows)]
    {
        if let Some(roaming) = dirs::config_dir() {
            dirs.push(roaming.join("npm"));
        }
        dirs.push(home.join(".local").join("bin"));
        if let Some(local) = dirs::data_local_dir() {
            dirs.push(local.join("Programs").join("claude"));
            dirs.push(local.join("pnpm"));
        }
        dirs.push(home.join(".bun").join("bin"));
        dirs.push(home.join(".volta").join("bin"));
        dirs.push(home.join("scoop").join("shims"));
    }
    #[cfg(not(windows))]
    {
        dirs.push(home.join(".local/bin"));
        dirs.push("/opt/homebrew/bin".into());
        dirs.push("/usr/local/bin".into());
        dirs.push(home.join(".npm-global/bin"));
        dirs.push(home.join(".bun/bin"));
        dirs.push(home.join(".volta/bin"));
        dirs.push("/usr/bin".into());
        dirs.push("/bin".into());
    }
    dirs
}

/// The search directories followed by the inherited PATH.
fn all_directories() -> Vec<PathBuf> {
    let mut dirs = search_directories();
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    dirs
}

/// PATH for child processes, so script-based CLIs can find `node` and friends.
pub fn child_path() -> std::ffi::OsString {
    std::env::join_paths(all_directories()).unwrap_or_default()
}

/// Finds `name` as an executable. On Windows a real `.exe` anywhere wins over an npm
/// `.cmd` shim, since a shim adds `cmd` and `node` processes around the real tool.
pub fn find(name: &str) -> Option<PathBuf> {
    find_in(name, &all_directories())
}

pub fn find_in(name: &str, dirs: &[PathBuf]) -> Option<PathBuf> {
    let extensions: &[&str] = if cfg!(windows) { &["exe", "cmd", "bat"] } else { &[""] };
    for extension in extensions {
        for dir in dirs {
            let mut path = dir.join(name);
            if !extension.is_empty() {
                path.set_extension(extension);
            }
            if is_executable(&path) {
                return Some(path);
            }
        }
    }
    None
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

/// The native `codex.exe` inside an npm install of `@openai/codex`, next to the `.cmd`
/// shim that would otherwise start it through `node`.
pub fn codex_native_beside_shim(shim: &Path) -> Option<PathBuf> {
    let vendor = shim.parent()?.join("node_modules").join("@openai").join("codex").join("vendor");
    let binary = if cfg!(windows) { "codex.exe" } else { "codex" };
    let mut candidates: Vec<PathBuf> = std::fs::read_dir(vendor)
        .ok()?
        .flatten()
        .map(|entry| entry.path().join("codex").join(binary))
        .filter(|path| path.is_file())
        .collect();
    // Prefer the build for this machine's architecture.
    let arch = if cfg!(target_arch = "aarch64") { "aarch64" } else { "x86_64" };
    candidates.sort_by_key(|path| !path.to_string_lossy().contains(arch));
    candidates.into_iter().next()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_in_order_and_prefers_native_binaries() {
        let root = tempfile::tempdir().unwrap();
        let first = root.path().join("a");
        let second = root.path().join("b");
        std::fs::create_dir_all(&first).unwrap();
        std::fs::create_dir_all(&second).unwrap();
        let dirs = vec![first.clone(), second.clone()];
        assert_eq!(find_in("tool", &dirs), None);

        #[cfg(windows)]
        {
            std::fs::write(first.join("tool.cmd"), "").unwrap();
            std::fs::write(second.join("tool.exe"), "").unwrap();
            assert_eq!(find_in("tool", &dirs), Some(second.join("tool.exe")), ".exe beats a shim");
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::write(second.join("tool"), "").unwrap();
            assert_eq!(find_in("tool", &dirs), None, "not executable");
            std::fs::set_permissions(second.join("tool"), std::fs::Permissions::from_mode(0o755)).unwrap();
            assert_eq!(find_in("tool", &dirs), Some(second.join("tool")));
        }
    }

    #[test]
    fn finds_native_codex_beside_npm_shim() {
        let root = tempfile::tempdir().unwrap();
        let binary = if cfg!(windows) { "codex.exe" } else { "codex" };
        let arch = if cfg!(target_arch = "aarch64") { "aarch64" } else { "x86_64" };
        let native = root.path().join(format!("node_modules/@openai/codex/vendor/{arch}-triple/codex"));
        std::fs::create_dir_all(&native).unwrap();
        std::fs::write(native.join(binary), "").unwrap();
        assert_eq!(codex_native_beside_shim(&root.path().join("codex.cmd")), Some(native.join(binary)));
        assert_eq!(codex_native_beside_shim(&root.path().join("missing/codex.cmd")), None);
    }
}
