# Limita for Windows

A port of Limita to Windows 10/11: Claude Code and Codex rate limits in the tray, a
dashboard next to the tray icon, and the hover pill at the top edge of the screen.
Built with [Tauri 2](https://tauri.app) (Rust + WebView2); the macOS app in the repository
root stays native Swift. Status: pre-release, not yet tried on real Windows machines.

## Install

1. Download `Limita_<version>_x64-setup.exe` from [Releases](../../../releases) (tags `windows-v*`).
2. Run it. It installs for the current user, no administrator rights needed.
3. The installer is not signed yet, so SmartScreen warns about it: **More info → Run anyway**.

Limita lives in the tray only. If Windows hides the icon in the overflow (**^**), drag it
onto the taskbar to keep it visible.

## Using it

- **Tray icon.** Left click opens the dashboard next to it; click elsewhere or press
  **Esc** to close it. Right click opens the menu: Show Limits, Refresh, Connect or
  Disconnect Claude Code and Codex, **Launch at Login**, Quit.
- **The dot on the icon** follows the 5-hour limit of the connected services, the most
  severe one wins: green, yellow from 70 % used (30 % left), red from 90 %; faded when
  the data is stale. The tooltip lists each service.
- **Hover pill.** Rest the cursor at the top edge of any screen, anywhere along it, and
  the pill slides in; click it for the dashboard. It never takes keyboard focus and does
  not appear over full-screen apps.

Everything else — what is shown, refresh intervals, colours, the countdown — matches the
macOS app; see the [main README](../README.md).

## What differs from macOS

| | Windows |
|---|---|
| Claude login | `%USERPROFILE%\.claude\.credentials.json` (Claude Code keeps it there on Windows); no Keychain prompt |
| Limita's files | `%APPDATA%\Limita\` — `settings.json`, `claude-status.json`, `wrapped-statusline.json` |
| Status-line hook | `"<install dir>/limita-cli.exe" --capture-claude-status`; your own status line is kept in `wrapped-statusline.json` and run through Git Bash (or `cmd` without it) |
| Codex CLI | an npm install (`%APPDATA%\npm\codex.cmd`) is started through its native `codex.exe`; the process tree is killed if it hangs |

## Checking a machine

`limita-cli.exe` sits next to `Limita.exe` in the install folder
(`%LOCALAPPDATA%\Limita`). Run it from a terminal to see what Limita finds and would show,
without the app and without changing anything:

```powershell
& "$env:LOCALAPPDATA\Limita\limita-cli.exe" --dump
```

`--remove-hook` puts Claude Code's own status line back, for when Limita was removed
while Claude Code was still connected.

## Build from source

Needs Rust (stable, MSVC toolchain on Windows), Node.js 22 and, on Windows, WebView2
(preinstalled on Windows 11).

```bash
cd windows
cargo test -p limita-core -p limita-cli   # the core runs and tests on macOS too
cd app
npm ci
npm run tauri dev                         # the app itself; also runs on macOS for UI work
npm run tauri build                       # the NSIS installer, on Windows
```

```text
windows/
├── core/   limita-core: sources, store and view model — all logic, no UI, tested anywhere
├── cli/    limita-cli: status-line capture, --dump, --remove-hook
└── app/    Tauri app: src-tauri/ (tray, panel, hover pill) and src/ (the webview UI)
```

The webview only renders what `core/src/view.rs` produces, so wording, thresholds and
formatting are unit-tested in Rust. `npm run sidecar` builds `limita-cli` into
`app/src-tauri/binaries/`, where the installer picks it up.

CI (`.github/workflows/windows.yml`) tests the core on Windows and macOS and builds the
installer as an artifact. Pushing a `windows-v<version>` tag publishes it as a pre-release.
