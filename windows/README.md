# Limita for Windows

A port of Limita to Windows 10/11: Claude Code and Codex rate limits and the DeepSeek
balance in the tray, a dashboard next to the tray icon, the hover pill at the top edge of
the screen, and a Settings window.
Built with [Tauri 2](https://tauri.app) (Rust + WebView2); the macOS app in the repository
root stays native Swift. Windows 10 and 11, x64.

## Install

1. Download `Limita_<version>_x64-setup.exe` from [Releases](../../../releases). The
   Windows and macOS apps share one version and one release.
2. Run it. It installs for the current user, no administrator rights needed.
3. The installer is not signed yet, so SmartScreen warns about it: **More info → Run anyway**.

Limita lives in the tray only. If Windows hides the icon in the overflow (**^**), drag it
onto the taskbar to keep it visible.

## Using it

- **Tray icon.** Left click opens the dashboard next to it; click elsewhere or press
  **Esc** to close it (while the dashboard has focus; not in the floating window). Right
  click opens the menu: Show Limits, Refresh, **Settings…**, Quit.
- **Settings.** Opened from the tray menu or the **⚙** button in the dashboard:
  **General** (hover pill, floating window, launch at login, notifications),
  **Providers** (connect and disconnect Claude Code, Codex and DeepSeek, how often each
  API is asked, the DeepSeek key and low-balance alert), **Shortcuts** and **Updates**
  (version, Check Now, automatic checks). Changes apply at once.
- **The dot on the icon** follows the 5-hour limit of the connected services, the most
  severe one wins: green, yellow from 70 % used (30 % left), red from 90 %; faded when
  the data is stale. The tooltip lists each service.
- **Hover pill.** Push the cursor against the top edge of any screen, in its middle part
  (the corners with menus and window buttons are left alone), and the pill slides in;
  click it for the dashboard. It never takes keyboard focus and does not appear over
  full-screen or borderless full-screen apps such as games.
- **Shortcuts.** By default **Ctrl+Alt+L** opens the dashboard at the top of the screen
  the cursor is on, or closes it; **Ctrl+Alt+H** turns the hover pill on or off;
  **Ctrl+Alt+P** pins the dashboard as a floating window you can drag anywhere. They work
  in other apps too, so Ctrl+Alt+L replaces Reformat Code in JetBrains IDEs and AltGr+L on
  layouts that type a letter with it (Polish ł). Change or turn off any of them in
  **Settings → Shortcuts**: click one and press the new keys with Ctrl, Alt or Win; a
  combination another app already holds is reported there.
- **DeepSeek.** Paste an API key in **Settings → Providers**; Limita checks it with
  DeepSeek and keeps it in the Windows Credential Manager. The column shows the balance,
  what you spent and how long it lasts; see [DeepSeek](../README.md#deepseek).

What is shown, the refresh intervals, colours and countdowns match the macOS app; see the
[main README](../README.md). A few things are macOS only for now: folding meters, hiding
the tray icon from the dashboard and the iTerm2 integration.
[`docs/platform-parity.md`](../docs/platform-parity.md) lists every difference.

## What differs from macOS

| | Windows |
|---|---|
| Claude login | `%USERPROFILE%\.claude\.credentials.json` (Claude Code keeps it there on Windows); no Keychain prompt |
| Limita's files | `%APPDATA%\Limita\` — `settings.json`, `claude-status.json`, `activity.json` (tokens per day), `deepseek-balance.json` (the balance history), `wrapped-statusline.json`, `resets.json` (the limit resets already seen); the Claude hook also edits `~/.claude/settings.json` |
| DeepSeek API key | the Windows Credential Manager, generic credential `Limita/deepseek-api-key` (`Limita/fake/deepseek-api-key` while `LIMITA_DEEPSEEK_API` points at the fake server); never in `settings.json`. **Disconnect** removes it |
| Status-line hook | `"<install dir>/limita-cli.exe" --capture-claude-status`; your own status line is kept in `wrapped-statusline.json` and run through Git Bash (or `cmd` without it) |
| Updates | [Tauri's updater](https://v2.tauri.app/plugin/updater/) reads `latest.json` from the latest release, checks the installer's signature and runs it in passive mode, then Limita reopens |
| Notifications | limit resets and a low or exhausted DeepSeek balance come as Windows notifications, through Tauri's notification plugin |
| Codex CLI | an npm install (`%APPDATA%\npm\codex.cmd`) is started through its native `codex.exe`; the process tree is killed if it hangs |

## Checking a machine

`limita-cli.exe` sits next to `Limita.exe` in the install folder
(`%LOCALAPPDATA%\Limita`). Run it from a terminal to see what Limita finds and would show,
without the app and without changing anything:

```powershell
& "$env:LOCALAPPDATA\Limita\limita-cli.exe" --dump
```

With DeepSeek connected it reads the balance with the stored key, but keeps the reading out
of the balance history. `--remove-hook` puts Claude Code's own status line back, for when Limita was removed
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
└── app/    Tauri app: src-tauri/ (tray, panel, hover pill, Settings window, shortcuts)
            and src/ (the webview UI: main.ts for the panel, settings.ts for Settings)
```

The webview only renders what `core/src/view.rs` produces, so wording, thresholds and
formatting are unit-tested in Rust. `npm run sidecar` builds `limita-cli` into
`app/src-tauri/binaries/`, where the installer picks it up.

CI (`.github/workflows/windows.yml`) tests the core on Windows and builds the installer
as an artifact.
