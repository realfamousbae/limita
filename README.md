<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.png">
    <img src="docs/banner-light.png" alt="Limita" width="520">
  </picture>
</p>

<p align="center">
  <b>Claude Code and Codex rate limits, one glance from the top of your Mac — or from the Windows tray.</b>
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000?logo=apple">
  <img alt="Windows 10+" src="https://img.shields.io/badge/Windows-10%2B-0078D4?logo=windows">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white">
  <img alt="Status" src="https://img.shields.io/badge/status-pre--release-7C3AED">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-22D3EE">
</p>

---

Limita is a tiny native menu-bar app that shows how much of your **Claude** and **Codex** 5-hour and weekly limits you have, without opening a terminal.

## Features

- **Hover pill.** Rest the cursor at the top edge of any screen and a compact pill slides in with each service's 5-hour limit. Click it for the full dashboard.
- **Stays away from the notch.** The camera housing plus 80 pt on each side is left to other apps: nothing triggers or draws there.
- **Menu bar.** Left-click the icon for the dashboard, right-click for the menu. Clicking elsewhere closes it. The button next to **↻** in the dashboard hides or shows the icon until Limita quits; the icon is back on every launch.
- **Keyboard shortcut.** **⌃⌥L** opens the dashboard at the top of the screen from any app, a terminal included; press it again to close it.
- **iTerm2 status bar.** An optional plugin shows your 5-hour and weekly limits in iTerm2's status bar while Claude Code or Codex runs in the tab, and a click on them opens the dashboard. See [iTerm2](#iterm2).
- **Only what you use.** Connect or disconnect Claude Code and Codex from the menu; disconnected services are neither shown nor queried. On first launch Limita connects whatever it finds installed.
- **Live numbers.** Claude is queried every 3 minutes, Codex every 5 minutes, and both on **Refresh**; local sources are re-read every minute.
- **Balances.** Codex limit resets and credits (credits and USD, $1 = 25 credits); Claude usage credits and cloud session credits. Rows a service does not report are hidden.
- **Readable at a glance.** Claude shows what is **used**, Codex what is **left**, and the dashboard labels which is which. Each service's dot follows its 5-hour limit: green, yellow from 70 % used (30 % left), red from 90 %; stale data keeps its colour, dimmed. Percentages stay plain white, and the dashboard counts down to each reset to the minute. If a live update fails, the reason is shown right in the dashboard.
- **Prime time.** During a service's peak hours, when work can burn through limits faster, the dashboard header shows a burning-gauge badge. Claude: weekdays 5–11 AM Pacific time; Codex: weekdays 12:00–18:00 UTC. Both are shown in your local time.
- Multiple displays and full-screen Spaces. JetBrains Mono everywhere.

# Screenshots

This is how Limita looks on your Mac.

<p align="center">
  <img src="docs/screenshots/pill-claude-desktop.png" alt="Pill with Claude on the desktop" width="303">
  <img src="docs/screenshots/pill-menu-bar.png" alt="Pill with both services under the menu bar" width="512">
</p>

<p align="center">
  <img src="docs/screenshots/dashboard-claude-desktop.png" alt="Dashboard with Claude only" width="820">
</p>

<p align="center">
  <img src="docs/screenshots/dashboard-both.png" alt="Dashboard with Claude and Codex under the menu bar" width="820">
</p>

## Install

1. Download `Limita-<version>.dmg` from [Releases](../../releases).
2. Open it and drag **Limita** into **Applications**.
3. The build is not notarized yet, so the first launch needs one extra step: right-click **Limita** in Applications → **Open** → **Open**. On recent macOS versions, use **System Settings → Privacy & Security → Open Anyway** instead.

Limita lives in the menu bar only; it has no Dock icon.

On the first Claude refresh, macOS asks whether Limita may read `Claude Code-credentials` from the Keychain. Choose **Always Allow**.

## iTerm2

The plugin adds a **Limita** component to iTerm2's status bar:

```text
🟢 Claude 5h 52% · 7d 49% used  │  🟢 Codex 5h 80% · 7d 64% left
```

It appears only in tabs where Claude Code or Codex is running and lists every service
you have connected in Limita. When the bar is short of room only the 5-hour limits are
shown. A click opens the Limita dashboard. The plugin reads what the running app shows, so Limita must be running; without
it the component says `Limita: not running`.

1. Download `limita.py` from [Releases](../../releases).
2. In iTerm2, open **Settings → General → Magic** and turn on **Enable Python API**.
3. Put the plugin into iTerm2's AutoLaunch folder, so it starts with iTerm2:

   ```bash
   mkdir -p ~/Library/Application\ Support/iTerm2/Scripts/AutoLaunch
   mv ~/Downloads/limita.py ~/Library/Application\ Support/iTerm2/Scripts/AutoLaunch/
   ```

4. Start it once from the menu bar: **Scripts → AutoLaunch → limita.py** (restart iTerm2 if
   AutoLaunch is not there yet). The first run asks to download iTerm2's Python runtime;
   allow it.
5. **Settings → Profiles → Session**: turn on **Status bar enabled** and click
   **Configure Status Bar**. Drag **Limita** from the component menu down into
   **Active Components** and click **OK**.

To make it look like the rest of the terminal, open **Configure Status Bar → Advanced…**:

- **Font**: choose the font of your profile (**Profiles → Text**).
- **Centred**: choose the **Tight packing** layout, then put a **Spring** on each side of
  Limita.
- **No gap when hidden**: turn on **Remove empty components**, so the bar has no blank
  space where Limita sits in other tabs.

To see the limits in every tab, select Limita in **Configure Status Bar**, click
**Configure Component** and turn off **Only while Claude Code or Codex runs**.

With a script in AutoLaunch, iTerm2 stops opening a window at startup. To keep that window,
turn on **Settings → General → Startup → Always open at least one terminal window at
startup**.

## Keeping Claude up to date

Claude Code's login token is **short-lived**, and only Claude Code itself renews it, while it is running. Limita reads that token but never renews it, because renewing it from outside could sign Claude Code out.

So after a long break from Claude Code, typically several hours, Claude's numbers stop updating:

- the dashboard shows **"Claude Code login expired … — open Claude Code to renew it"**;
- the last known numbers stay visible, dimmed and marked **STALE DATA**.

**To fix it, start Claude Code** (run `claude` in a terminal, or open it in your editor), then press **↻** in Limita or wait for the next refresh. Live data comes back as soon as Claude Code has renewed the login. Codex is not affected.

A long-lived token from `claude setup-token` does not help here: it only allows model requests, not reading usage limits.

## Data sources

| | Claude | Codex |
|---|---|---|
| **Live** | `GET api.anthropic.com/api/oauth/usage` with Claude Code's OAuth token | `codex app-server` → `account/rateLimits/read` (official; auth stays in the CLI) |
| **Fallback** | Claude Code status line, set up when you connect Claude Code | Latest `rate_limits` in `~/.codex/sessions/**/rollout-*.jsonl` |
| **Extras** | Usage credits, cloud session credits | Limit resets, credit balance |

**Claude usage API.** The endpoint is undocumented, the same one Claude Code's `/usage` uses, and it may change without notice. Limita reads the token from Claude Code's Keychain item `Claude Code-credentials`; macOS asks once. The token is only sent to `api.anthropic.com`. Limita never stores or refreshes it; see [Keeping Claude up to date](#keeping-claude-up-to-date).

**Claude status line.** **Connect Claude Code** in the menu adds Limita to `statusLine` in `~/.claude/settings.json`:

- An existing status line is wrapped, not replaced. Limita saves the limits and runs your command with the same input, so its output is unchanged.
- **Disconnect Claude Code** restores it. A backup is kept as `settings.json.limita-backup`.
- Connect from `/Applications`: a build-folder path disappears after a clean build.

## Privacy

- No accounts, cookies or passwords, and no analytics.
- Only rate-limit numbers and balances are read. Prompts, transcripts, project paths and session IDs are ignored.
- The Claude status-line cache (`~/Library/Application Support/Limita/claude-status.json`) holds only the two windows and a timestamp.
- For the iTerm2 plugin, the app writes what the dashboard shows to `~/Library/Application Support/Limita/snapshot.json`: percentages, reset times and status, nothing else. The file is removed when Limita quits.

## Build from source

The macOS app lives in `macos/`; the Windows app in [`windows/`](windows/README.md).
Requires macOS 14+, Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd macos
swift test
xcodegen generate
xcodebuild -project Limita.xcodeproj -scheme Limita -configuration Release build
```

`macos/Limita.xcodeproj` is generated from `macos/project.yml`. Run `xcodegen generate` after adding or removing files.

`macos/scripts/make-dmg.sh` builds a Release copy and packages it as `macos/build/Limita-<version>.dmg` with the drag-to-install window. Its background is rendered from `macos/design/dmg-background-source.webp` by `macos/scripts/dmg-background.py` (needs Pillow); rerun that after changing the layout. The prime-time badge animation, `prime-time.webp` for both apps, is built from `macos/design/prime-time-source.webm` by `macos/scripts/prime-time-sprite.sh` (needs ffmpeg and cwebp).

Live-update failures are logged: `log show --predicate 'subsystem == "com.limita.app"' --last 1h`.

```text
macos/
├── Limita/
│   ├── App/        lifecycle, status item, CLI entry for the status-line hook
│   ├── Data/       readers, live clients, Claude status-line setup
│   ├── Models/     limit windows, service state, balances
│   ├── UI/         panel controller, pill, dashboard, layout, font
│   └── Resources/  app icon, menu-bar icon, bundled font
├── Tests/LimitaTests/
├── integrations/   the iTerm2 status-bar plugin
├── scripts/        DMG packaging, prime-time sprite
└── dmg/, design/   DMG background and artwork sources
windows/            the Windows app (Tauri + Rust)
docs/               banners and screenshots
```

## Windows

Limita also runs on Windows 10 and 11: a tray icon with the traffic-light dot, the same
dashboard next to it, and the hover pill in the middle of the top edge of any screen. The
pill stays out of the corners, where menus and window buttons are, and never appears over
full-screen apps and games, borderless ones included. Both apps share one version and one
release.

1. Download `Limita_<version>_x64-setup.exe` from [Releases](../../releases).
2. Run it; it installs for your user, no administrator rights needed. The installer is not
   signed yet: on the SmartScreen warning choose **More info → Run anyway**.

The Windows app is built with Tauri and Rust in [`windows/`](windows/README.md), which
covers the differences from macOS, troubleshooting and building from source.

## License

MIT, see [LICENSE](LICENSE). The bundled JetBrains Mono Nerd Font is under the SIL Open Font License 1.1, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Limita is not affiliated with OpenAI or Anthropic.
