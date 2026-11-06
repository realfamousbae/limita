# Platform parity: macOS and Windows

Limita ships two apps from this repository: the native macOS app in `macos/` (Swift, SwiftUI, AppKit) and the Windows app in `windows/` (a Rust core, a Tauri 2 shell and a TypeScript frontend). They share one version and one release, and the Windows app is meant to behave like the macOS one (see the module comment in `windows/core/src/lib.rs`). In practice they drift: a change lands on one platform first.

This file lists every known difference between the two, so the Windows port can catch up and nobody has to rediscover the gap by reading both code bases.

**Keep it current.** Every pull request that changes one platform only (or changes both differently) must add, change or remove the matching row here, in the same pull request. A row is removed once the gap is closed; a deliberate difference stays, with the reason in *Notes*.

How to read it:

- **Notes** starts with a status: **Same** (equivalent behaviour, listed so nobody re-checks it), **Differs** (both have it, but not alike), **Missing on Windows**, **Missing on macOS**, or **Platform-specific** (follows from the operating system and needs no port).
- Code references are file paths plus a symbol, constant or string to search for, not line numbers: line numbers rot with the next commit. All facts were checked against the code at version 0.23.1 (commit `d685286`) and updated for 0.24.0.
- A few facts could not be verified from this repository (they live in a third-party crate) and are marked *unverified*.

## Contents

1. [The differences that matter most](#the-differences-that-matter-most)
2. [Feature comparison](#feature-comparison)
3. [Memory and performance](#memory-and-performance)
4. [macOS only since 0.24.0](#macos-only-since-0240)
5. [Porting checklist for Windows](#porting-checklist-for-windows)
6. [Documentation that no longer matches the code](#documentation-that-no-longer-matches-the-code)

## The differences that matter most

1. **Memory work exists only on macOS.** Version 0.23.1 cut the macOS app from 850 MB to under 60 MB. The two causes found there do not occur on Windows, but Windows has never been measured, and it reads whole log files into memory and keeps a hidden WebView2 alive. See [Memory and performance](#memory-and-performance).
2. **Per-meter folding is macOS only.** The ⌄ button on the per-model, credit and unlimited-meter rows, the capsules on the ACTIVITY line and the persisted `collapsedMeters` have no Windows counterpart.
3. **No terminal integration on Windows.** macOS writes `snapshot.json` for the iTerm2 status-bar plugin; Windows writes nothing equivalent.
4. **Different safety nets.** Windows has CI for its core, its app and its release; macOS has no CI at all, and its build, DMG and release are by hand. Windows has no environment override for the updater, which macOS uses to test updates locally.
5. **DeepSeek and the Settings window are macOS only.** Version 0.24.0 added DeepSeek as a third provider (balance, spending and a forecast from an API key), a Settings window with rebindable shortcuts and per-provider polling, and a shorter menu-bar menu. Windows has none of it yet. See [macOS only since 0.24.0](#macos-only-since-0240).

## Feature comparison

### Data sources

| Feature | macOS | Windows | Notes |
|---|---|---|---|
| Claude login token | Keychain item `Claude Code-credentials`; falls back to `~/.claude/.credentials.json`. Needs a one-time Keychain permission (`macos/Limita/Data/ClaudeLiveClient.swift`, `Claude Code-credentials`) | `%USERPROFILE%\.claude\.credentials.json` only. The Keychain code is not compiled in (`windows/core/src/claude_live.rs`, `platform_credentials`) | **Platform-specific.** Claude Code keeps the login in a file on Windows. If it ever moves to the Credential Manager, Windows needs a reader. |
| Token handling | Never stored or refreshed; an expired `expiresAt` gives "login expired … open Claude Code to renew it" | Same | **Same** (`ClaudeLiveClient.swift`, `claude_live.rs`) |
| Claude usage API | `GET api.anthropic.com/api/oauth/usage`, header `anthropic-beta: oauth-2025-04-20`, 20 s timeout | Same | **Same** |
| Plan name | `GET /api/oauth/profile` in parallel; falls back to the login's plan; Max with a `_20x` or "ultra" tier is **Ultra** (`ClaudeLiveClient.swift`, `planName`) | Same, falls back to `subscriptionType` and `rateLimitTier` in the credentials file (`claude_live.rs`) | **Same** |
| Per-model weekly limit (Fable), weekly share, usage credits, cloud session credits | Parsed from the usage response; cloud credits are the internal key `iguana_necktie` (`ClaudeLiveClient.swift`) | Same keys (`claude_live.rs`, `iguana_necktie`) | **Same** |
| Claude status-line cache | `~/Library/Application Support/Limita/claude-status.json`; stale after 30 min (`macos/Limita/Data/ClaudeLimitsReader.swift`) | `%APPDATA%\Limita\claude-status.json`; stale after 30 min (`windows/core/src/claude_cache.rs`) | **Same** format and rules. |
| Status-line hook command | The app binary itself: `'<Limita exe>' '--capture-claude-status' ['--' '<previous command>']`, run by `/bin/sh` (`macos/Limita/Data/ClaudeStatusLine.swift`, `macos/Limita/App/LimitaApp.swift`) | The sidecar `limita-cli.exe --capture-claude-status`; a previous status line is kept in `wrapped-statusline.json` and run through Git Bash, or `cmd` without it (`windows/core/src/statusline.rs`, `wrapped_command_in`, `git_bash`; `windows/cli/src/main.rs`) | **Differs.** A Windows GUI executable has no usable stdout, hence the separate console binary. Both wrap rather than replace and keep `settings.json.limita-backup`. |
| Hook self-repair | At launch, only when running from `/Applications` or `~/Applications` (`ClaudeStatusLine.swift`) | At launch, only when running from a stable folder, not `target\` (`statusline.rs`, `repair_if_needed`, `is_running_from_stable_location`) | **Same** idea. |
| Codex rate limits, local | Newest `rollout-*.jsonl` under `~/.codex/sessions/**` and `~/.codex/archived_sessions/`, read backwards in 64 KiB chunks (`macos/Limita/Data/CodexLimitsReader.swift`, `macos/Limita/Data/TailLineReader.swift`) | Same layout and chunk size (`windows/core/src/codex_reader.rs`, `windows/core/src/tail.rs`) | **Same.** Windows keeps reading older files until one holds `rate_limits`; see [Memory and performance](#memory-and-performance). |
| Codex rate limits, live | `codex app-server`, JSON-RPC over stdio, `account/rateLimits/read`, 20 s (`macos/Limita/Data/CodexLiveClient.swift`) | Same (`windows/core/src/codex_live.rs`) | **Same** protocol. |
| Finding the Codex CLI | `LIMITA_CODEX_CLI`, then a fixed list of folders (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.bun/bin`, `~/.volta/bin`, `/usr/bin`, `/bin`) | `LIMITA_CODEX_CLI`, then `windows/core/src/locator.rs`; an npm `.cmd` shim is replaced by its native `codex.exe` | **Platform-specific.** |
| Codex child process | Terminated after the 20 s timeout | Killed with its whole process tree through a job object; `CREATE_NO_WINDOW` (`codex_live.rs`) | **Platform-specific.** |
| DeepSeek balance | `GET https://api.deepseek.com/user/balance` with the user's API key, every 5 min by default; the main currency is the one with the most money, others are listed (`macos/Limita/Data/DeepSeekClient.swift`) | Absent | **Missing on Windows.** |
| DeepSeek spending and forecast | Limita's own history of the balance: drops are spending, rises are top-ups; spent today and this month, average per day over a week, days left, bar against the last top-up (`macos/Limita/Data/BalanceLedger.swift`, `summarize`) | Absent | **Missing on Windows.** |
| DeepSeek API key | Login Keychain, generic password `com.limita.app.deepseek`; checked with DeepSeek before it is stored, removed on Disconnect (`macos/Limita/Data/KeychainStore.swift`) | Absent | **Missing on Windows.** The natural place is the Credential Manager, never `settings.json`. |
| Global reset trackers | `codex-reset.com/api/forecast`, `claude-resets.com/api/resets`, 15 min, at most one request per minute per service (`macos/Limita/Data/ResetFeed.swift`, `macos/Limita/Data/ResetWatcher.swift`, `pollInterval`) | Same URLs and interval (`windows/core/src/resets.rs`, `POLL_INTERVAL`, `CODEX_URL`, `CLAUDE_URL`) | **Same.** |
| Environment overrides for testing | `LIMITA_CLAUDE_API`, `LIMITA_CODEX_CLI`, `LIMITA_DEEPSEEK_API`, `LIMITA_RESET_FEED_CODEX`, `LIMITA_RESET_FEED_CLAUDE`, `LIMITA_UPDATE_FEED`, `LIMITA_UPDATE_INSTALL` | The first four (the reset feeds also accept `file://`), plus `CLAUDE_CODE_GIT_BASH_PATH` | **Differs.** No `LIMITA_UPDATE_*` on Windows (see Updates). |
| Fake backends for tests | `scripts/fake-api.py` serves a fake Claude API, a fake `codex app-server` and a fake DeepSeek balance (`ds-normal`, `ds-low`, `ds-empty`, `ds-multi`; no key needed); with any `LIMITA_*` API variable set, macOS also switches to a separate UserDefaults suite, `com.limita.fake`, and its own Keychain item (`macos/Limita/Data/ServiceSettings.swift`) | The same two variables point at the fake servers (`windows/core/src/claude_live.rs`, `windows/core/src/codex_live.rs`), but settings and files stay where they are; the script's instructions are written for macOS | **Differs.** A Windows run against the fakes would touch the real `%APPDATA%\Limita`. |

### Polling and errors

| Feature | macOS | Windows | Notes |
|---|---|---|---|
| Local sources (Codex logs, Claude cache) | Every 60 s (`macos/Limita/Data/LimitsStore.swift`, `localInterval`) | Every 60 s (`windows/core/src/store.rs`, `LOCAL_INTERVAL`) | **Same.** |
| Live sources | Claude 3 min, Codex 5 min, DeepSeek 5 min by default, each changeable in Settings from 1 to 30 min (`LimitsStore.swift`, `liveInterval`, `liveIntervalChoices`; saved as `liveIntervals`); due when older than the interval minus 30 s | Claude 3 min, Codex 5 min, fixed (`store.rs`, `live_interval`) | **Differs.** Windows has no setting. |
| 429 backoff (Claude) | `max(min(5 min · 2^(n−1), 30 min), min(Retry-After, 2 h))` (`LimitsStore.swift`, `rateLimitPause`) | Same formula (`store.rs`, `rate_limit_pause`) | **Same.** A 429 pause also holds back a manual Refresh on both. |
| Reset trackers' 429 | Same function, minimum 60 s between requests | Same | **Same.** |
| Update check | At launch, then every 3 h; can be turned off in Settings, with a Check Now button (`AppUpdater.swift`, `autoCheck`) | At launch, then every 3 h, always (`windows/app/src-tauri/src/updater.rs`) | **Differs.** |
| Panel opened | Re-reads local sources if the last read is older than 15 s | Same (`windows/app/src-tauri/src/panel.rs`) | **Same.** |
| Stale data | 30 min for both services; shown as STALE DATA, dimmed (dot 0.4, meter 0.55) | Same numbers in the dashboard; the tray dot uses 0.45 (`windows/app/src-tauri/src/tray_icon.rs`) | **Differs** slightly. |
| Wrong system clock | A window past `resetsAt` shows 0 % and "window reset" | Same | **Same.** No clock-skew check on either. |
| Sleep, wake and network change | Not handled specially; the next 60 s tick catches up | Same | **Same.** |

### Dashboard and other surfaces

| Feature | macOS | Windows | Notes |
|---|---|---|---|
| Dashboard layout, rows, thresholds, ∞ meter, used/left wording | `macos/Limita/UI/ExpandedView.swift` | Rendered from `windows/core/src/view.rs`, drawn by `windows/app/src/main.ts` | **Same.** The Windows webview only draws what the Rust view model produces, so the wording is unit-tested there. |
| Folding rows (⌄ button, capsules on the ACTIVITY line) | Per-model rows, credit rows and the unlimited 5-hour row fold into capsules; state persisted in `collapsedMeters` (`ExpandedView.swift`, `foldedMeters`; `macos/Limita/Data/ServiceSettings.swift`) | Absent. The only chevron is the ACTIVITY toggle | **Missing on Windows.** The README says "On macOS" for this. |
| Hide the menu-bar or tray icon | A header button hides the icon until quit (`ExpandedView.swift`, `showsMenuBarIcon`); not persisted | Absent | **Missing on Windows.** Low value there: Windows lets the user hide tray icons itself. |
| Header buttons | Update ⤓, hover-pill toggle, pin, hide icon, Settings ⚙, refresh | Update ⤓, hover-pill toggle, pin, refresh | **Differs** by the hide-icon and Settings buttons. |
| DeepSeek column | BALANCE LEFT meter (share of the last top-up, money beside the bar, days left under it) and tiles: spent today, this month, per day, alert threshold, topped up and granted, other currencies (`ExpandedView.swift`, `balanceMeter`, `balanceRows`); the pill shows the amount, e.g. ¥86.40 | Absent | **Missing on Windows.** |
| Low-balance notification | Once per drop to or below the user's threshold, and once when DeepSeek starts rejecting calls; re-armed when the balance recovers (`LimitsStore.swift`, `announceBalance`) | Absent | **Missing on Windows.** |
| Settings window | General, Providers, Shortcuts, Updates tabs; opened from the menu (⌘,), the header ⚙, the connect prompt and `limita://settings[/tab]` (`macos/Limita/UI/SettingsView.swift`, `SettingsWindowController.swift`) | Absent: settings live in the tray menu and the header | **Missing on Windows.** |
| Closing the dashboard | Click outside, hotkey, menu-bar icon | Click outside, hotkey, tray icon, **Esc** (needs the webview to hold focus, so not in the non-focusable floating window) | **Differs.** |
| Hover pill trigger | Cursor within 3 pt of the top edge of any screen, 0.3 s dwell, hides 0.7 s after leaving (`macos/Limita/UI/PanelLayout.swift`, `triggerHeight`; `macos/Limita/UI/BezelPanelController.swift`, `dwellDelay`, `hideDelay`) | Cursor on the top pixel row, in the middle 28 %–75 % of the screen's width, 300 ms dwell, 80 ms polling, hides 700 ms after leaving (`windows/app/src-tauri/src/placement.rs`, `TRIGGER_FROM`, `TRIGGER_TO`; `windows/app/src-tauri/src/panel.rs`, `DWELL`, `HIDE_DELAY`, `POLL`) | **Differs.** Windows avoids the corners (menus, window buttons); macOS avoids the notch. |
| Notch | Camera housing plus 80 pt each side is left alone (`PanelLayout.swift`, `notchClearance`) | n/a | **Platform-specific.** |
| Full-screen apps | Panel level `.statusBar`, behaviour `.fullScreenAuxiliary`; shows in full-screen Spaces | Pill is suppressed over full-screen and borderless-full-screen windows and games (`windows/app/src-tauri/src/platform.rs`, `foreground_is_fullscreen`, `SHQueryUserNotificationState`) | **Platform-specific.** |
| Placement | Under the menu bar, avoiding the notch | Hangs from the work-area top, 6 px gap; the dashboard can open next to the tray icon on any taskbar edge (`placement.rs`) | **Platform-specific.** |
| Floating window | ⌃⌥P, menu check item, header pin. Origin saved as `floatingWindowOrigin` on every drag; non-activating `NSPanel`, all Spaces | Ctrl+Alt+P, tray check item, header pin. Position saved as `floatingPosition` (physical pixels); not focusable | **Same** behaviour, different storage. Both re-open on launch, also at login. |
| Activity panel | `macos/Limita/UI/ActivityView.swift`, `macos/Limita/Data/ActivityStore.swift` | `windows/core/src/activity.rs`, `windows/app/src/main.ts` | **Same** periods, tiles and merge rule (per-field maximum, so history only grows). Both scan only while the panel is expanded. |
| Activity scan throttle | `refresh(ifOlderThan: 60)` when the dashboard appears | Scans on webview start, entering dashboard mode, the Refresh button, and the toggle and period buttons; no 60 s throttle | **Differs.** Cheap on both thanks to the size and mtime cache. |
| `activity.json` | `~/Library/Application Support/Limita/activity.json` | `%APPDATA%\Limita\activity.json`, same format | **Same.** |
| Prime-time badge, schedule | Claude Mon–Fri 05:00–11:00 America/Los_Angeles; Codex Mon–Fri 12:00–18:00 UTC (`macos/Limita/Models/PrimeTime.swift`) | Same; DST rule written by hand (`windows/core/src/prime_time.rs`) | **Same.** |
| Prime-time badge, position | Centered on the panel, whatever the widths of the titles and buttons; the panel widens to keep it clear of both (`ExpandedView.swift`, `headerWidth`) | Centered on the panel by a three-column grid (`windows/app/src/styles.css`, `header`) | **Same.** |
| Prime-time badge, drawing | 196 frames of 78 px cut once into separate 78×78 bitmaps, played by a SwiftUI `TimelineView` at 24 fps (`ExpandedView.swift`, `PrimeTimeSprite`, `cutFrames`) | One element with the whole sheet as a CSS background, two `steps(14)` animations (`windows/app/src/styles.css`, `.burning-gauge`) | **Platform-specific.** Both use the shared `prime-time.webp`. |
| Limit-reset lines | 48 h; banked resets until used; credit line links to the tracker (`macos/Limita/Models/ResetEvent.swift`, `shownFor`) | Same (`windows/core/src/resets.rs`, `SHOWN_FOR`) | **Same.** |
| Reset detection | Global resets, banked resets, early weekly reset (old reset ≥ 30 min away, new one 1 h to just under a week later, usage down ≥ 5 points), new Codex banked credit; first launch only records | Same rules (`ResetWatcher.swift`, `isEarlyWeeklyReset`; `resets.rs`) | **Same.** |
| Reset notifications | `UNUserNotificationCenter`, permission asked the first time something is announced; **clicking opens the dashboard** (`macos/Limita/App/ResetNotifier.swift`) | Windows toast through `tauri-plugin-notification` (`windows/app/src-tauri/src/lib.rs`); **no click handler** in this repository | **Differs.** A comment in `lib.rs` says a click "starts Limita again"; that is *unverified*. |
| Update button ⤓ | Green button; the first time per launch it spells out "LIMITA x.y.z IS OUT · CLICK TO UPDATE" for 8 s; spinner while installing; failures in the tooltip | Same UX (`main.ts`) | **Same.** |

### Menu-bar menu and tray menu

| Item | macOS (right-click the menu-bar icon) | Windows (right-click the tray icon) | Notes |
|---|---|---|---|
| Show Limits | Hint of the dashboard shortcut, whatever it is set to, if it registered | Ctrl+Alt+L hint, if the hotkey registered | **Same.** |
| Refresh | ⌘R while the menu is open | No shortcut | **Same** action. |
| Settings… | ⌘, opens the Settings window | **Absent** | **Missing on Windows.** |
| Hover Pill | Moved to Settings → General (and the header button) | **Absent**: only the header button and Ctrl+Alt+H | **Differs.** Neither menu has it now. |
| Floating Window | Moved to Settings → General (and the header pin) | Check item, Ctrl+Alt+P hint | **Differs.** macOS 0.24.0 shortened the menu to Show Limits, Refresh, Settings and Quit. |
| Reset Notifications | Moved to Settings → General | Check item | **Differs.** |
| Connect or Disconnect Claude Code, Codex, DeepSeek | Moved to Settings → Providers; the setup message is shown there | Title flips with the state for Claude Code and Codex; the setup message opens in the dashboard | **Differs.** |
| Launch at Login | **Absent** | Check item, state read from the autostart plugin | **Missing on macOS.** |
| Quit | ⌘Q | No shortcut | **Same.** |
| Left click on the icon | Toggles the dashboard under the icon (or at the pinned spot) | Toggles the dashboard next to the icon; a click within 400 ms of a blur-hide is ignored | **Same.** |
| Right click | Opens the menu (also ⌃-click); a non-floating dashboard closes first | Opens the menu | **Same.** |
| Icon | Template image, 18 pt | 32 px glyph tinted white or black from the `SystemUsesLightTheme` registry value, with a traffic-light dot in the corner (`windows/app/src-tauri/src/tray_icon.rs`) | **Platform-specific.** macOS has no coloured dot in the menu bar. |
| Tooltip | None | "Limita", then one line per service (`view.rs`) | **Missing on macOS** (not needed there). |
| Source | `macos/Limita/App/AppDelegate.swift` | `windows/app/src-tauri/src/tray.rs` | |

### Hotkeys, launch and updates

| Feature | macOS | Windows | Notes |
|---|---|---|---|
| Global hotkeys | ⌃⌥L dashboard, ⌃⌥H hover pill, ⌃⌥P floating window by default; each can be rebound or turned off in Settings → Shortcuts, and a key another app holds is reported there; Carbon `RegisterEventHotKey`, no Accessibility permission (`macos/Limita/App/GlobalHotKey.swift`, `HotKeyCenter`; saved as `hotKeys`) | Ctrl+Alt+L, Ctrl+Alt+H, Ctrl+Alt+P, fixed; Win32 `RegisterHotKey` on its own thread (`platform.rs`, `register_hotkeys`) | **Differs.** A refused key is skipped silently on Windows, which never surfaces the H result. |
| Launch at login, switch | None in the app. The user adds Limita in System Settings → Login Items by hand | Tray check item through `tauri-plugin-autostart`, off by default, passes `--autostart` | **Differs.** The registry or Run-key mechanism is inside the plugin and is *unverified* here. |
| Launch at login, behaviour | A login launch is detected from the AppleEvent (`AppDelegate.swift`, `launchedAsLoginItem`): the app waits in the menu bar unless floating mode is on | `--autostart` does the same (`lib.rs`, `AUTOSTART_FLAG`) | **Same.** Launched by hand, both show the dashboard after 0.5 s. |
| Second launch | `applicationShouldHandleReopen` shows the dashboard | `tauri-plugin-single-instance` shows the dashboard | **Same.** |
| Launch flags and URL | `--show` forces the dashboard; `limita://dashboard` (the iTerm2 plugin uses it); `limita://settings` or `limita://settings/providers` opens Settings on a tab | No flag and no URL scheme; running `Limita.exe` again opens the dashboard (see Second launch) | **Differs.** The URL scheme exists for the iTerm2 plugin, which Windows lacks. |
| First-launch service detection | Claude if the `claude` CLI or `~/.claude` exists, or a Limita hook is installed; Codex likewise; no Keychain access (`macos/Limita/Data/ServiceSettings.swift`) | Same (`windows/core/src/settings.rs`, `windows/core/src/store.rs`) | **Same.** Detection never installs the hook. |
| Update source | github.com, not the API: `releases/latest` redirects to the tag, then `Limita-<version>.dmg` and `.dmg.sig` under `releases/download/<tag>/`; offered only when the signature is there; drafts and prereleases are never "latest" (`macos/Limita/Data/AppUpdater.swift`, `latestReleaseFromWeb`). The API, limited to 60 anonymous requests an hour per IP, is used only for `LIMITA_UPDATE_FEED` | `releases/latest/download/latest.json`, built by the release workflow, `windows-x86_64` entry only (`windows/app/src-tauri/tauri.conf.json`, `endpoints`) | **Differs** in format; neither depends on the API's rate limit since 0.24.1. |
| Signature | Ed25519 over the whole DMG, key embedded in the app, checked with CryptoKit | Minisign key embedded in `tauri.conf.json` (`pubkey`), checked by Tauri's updater | **Differs.** Different keys and tools; both private keys are outside the repository. |
| Install | Mount with `hdiutil`, check bundle id and version, copy with `ditto`, then a detached script waits for quit, moves the old app to `<app>.previous`, copies the new one in, strips quarantine, reopens; on failure it puts the old one back. In a read-only place or on the DMG it opens the release page instead | NSIS installer in passive mode (`tauri.conf.json`, `installMode`), which reopens Limita | **Platform-specific.** |
| Automatic update checks | Can be turned off in Settings → Updates (`autoUpdateCheck`), with Check Now and the last result | Always on | **Differs.** |
| Update testing | `LIMITA_UPDATE_FEED=<url>` and `LIMITA_UPDATE_INSTALL=1` | No override | **Missing on Windows.** |

### Settings and files

| Setting | macOS (UserDefaults, domain `com.limita.app`) | Windows (`%APPDATA%\Limita\settings.json`) | Notes |
|---|---|---|---|
| Connected services | `enabledServices` (list; detected on first launch) | `enabledServices` | **Same.** |
| Hover pill | `hoverPillEnabled` (default on) | `hoverPill` (absent means on) | **Same.** |
| Floating window | `floatingWindowEnabled` (off) | `floating` (off) | **Same.** |
| Floating position | `floatingWindowOrigin`, `[x, y]` doubles in points | `floatingPosition`, `[x, y]` physical pixels | **Differs** in unit. |
| Folded rows | `collapsedMeters` (set of `service.NAME`) | none | **Missing on Windows.** |
| Polling intervals | `liveIntervals` (seconds per service, only where changed) | none | **Missing on Windows.** |
| Global shortcuts | `hotKeys` (JSON, only changed actions; `null` turns one off) | none | **Missing on Windows.** |
| Automatic update checks | `autoUpdateCheck` (on) | none | **Missing on Windows.** |
| DeepSeek alert | `deepseekLowBalance` (amount, absent means off), `deepseekBalanceAlerts` (on) | none | **Missing on Windows.** |
| DeepSeek API key | Keychain, never in UserDefaults | none | **Missing on Windows.** |
| Reset notifications | `resetNotificationsEnabled` (on) | `resetNotifications` (absent means on) | **Same.** |
| Activity panel | `activityExpanded` (off), `activityPeriod` (`all`) | `activityExpanded`, `activityPeriod` | **Same.** |
| Reset memory (what was already seen) | UserDefaults key `resetWatcher`, JSON | `%APPDATA%\Limita\resets.json` | **Differs** in storage, same content. |
| Hidden menu-bar icon | Not persisted; the icon is back on every launch | n/a | |
| Files outside settings | `claude-status.json`, `activity.json`, `deepseek-balance.json`, `snapshot.json` (deleted on quit) in `~/Library/Application Support/Limita/` | `claude-status.json`, `activity.json`, `wrapped-statusline.json`, `resets.json` in `%APPDATA%\Limita\` | **Differs** by `snapshot.json` and `wrapped-statusline.json`. |
| Written outside Limita's folder | `~/.claude/settings.json` (hook), `~/.claude/settings.json.limita-backup`; `$TMPDIR/limita-update-*` and `<app>.previous` during an update | `~/.claude/settings.json`, `.limita-backup`; `%TEMP%\limita-dump-*` from `limita-cli --dump` | **Same** for the hook. |
| Logs | `os.Logger`, subsystem `com.limita.app` (`log show …`) | None to a file; `limita-cli --dump` prints a diagnostic | **Differs.** |
| Source | `ServiceSettings.swift`, `ResetWatcher.swift`, `ActivityStore.swift` | `windows/core/src/settings.rs` (`Stored`), `resets.rs` | |

### Terminal integration and command-line helpers

| Feature | macOS | Windows | Notes |
|---|---|---|---|
| iTerm2 status bar | `snapshot.json` after every refresh, with a `balance` object for DeepSeek (`macos/Limita/Data/TerminalSnapshot.swift`) and the plugin `macos/integrations/iterm2/limita.py`, which shows it as "DeepSeek ¥86.40" | Nothing | **Missing on Windows.** A Windows Terminal or VS Code equivalent has not been designed; at minimum the same `snapshot.json` could be written. |
| Hook entry point | `--capture-claude-status [-- '<cmd>']` on the app binary | `--capture-claude-status` on `limita-cli.exe` | **Differs** (see Data sources). Neither has a `--status-line` flag. |
| Diagnostics | None | `limita-cli --dump` (what Limita finds, one forced refresh, the tooltip and view model), `--remove-hook` (`windows/cli/src/main.rs`) | **Missing on macOS.** |

### Packaging, tests and CI

| Feature | macOS | Windows | Notes |
|---|---|---|---|
| Project files | `macos/project.yml` (XcodeGen), generated `Limita.xcodeproj`, `macos/Package.swift` for `swift test` | Cargo workspace `windows/Cargo.toml`, Tauri app `windows/app/src-tauri/` | **Platform-specific.** |
| Version | `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` | `windows/Cargo.toml`, `windows/app/src-tauri/tauri.conf.json`, `windows/app/package.json` | **Differs.** `windows-release.yml` checks the tag against `tauri.conf.json` and `project.yml` only, not `Cargo.toml` or `package.json`. |
| Installer | Drag-to-install DMG, `macos/scripts/make-dmg.sh`; the update signature by `macos/scripts/sign-update.sh` | NSIS per-user installer, no administrator rights; `limita-cli` bundled as a sidecar by `windows/app/scripts/sidecar.mjs` | **Platform-specific.** |
| Code signing | Not notarized, no Developer ID; documented Open Anyway and `xattr` workarounds | No Authenticode signature; SmartScreen warns. The updater signature is separate and present | **Same** state. |
| Architectures | Whatever Xcode builds | x64 only | **Windows gap**: no ARM64 build. |
| Fonts and artwork | `assets/shared/` copied by `scripts/sync-assets.sh` | Same script; CI runs `--check` | **Same.** |
| Unit tests | 112 XCTest tests in two files (`macos/Tests/LimitaTests/LimitaTests.swift`, `DeepSeekTests.swift`) | About 101 Rust tests: 93 in `windows/core`, 8 in the app crate (`placement.rs`, `tray_icon.rs`), none in `limita-cli` or the frontend | **Differs.** Windows leaves `panel.rs`, `platform.rs`, `tray.rs`, `updater.rs` and `lib.rs` untested. |
| CI | None | `.github/workflows/windows.yml` (core tests, asset check, clippy, installer build) and `windows-release.yml` (version check, `latest.json`, upload) | **Missing on macOS.** The release and the DMG are made by hand; `windows-release.yml` waits for the hand-made release. |

## Memory and performance

Commit `ea24b0b` ("Cut Limita's memory from 850 MB to under 60 MB", pull request #36) fixed two things on macOS only. Neither fix exists on Windows. For each: what the problem was, whether Windows has it, and what a port would need. Nothing here has been measured on Windows; the verdicts come from reading the code.

| # | macOS problem and fix | Windows status | What a port needs |
|---|---|---|---|
| 1 | **Activity scan kept every parsed line.** `forEachLine` in `ActivityReader` parsed each matching line of about 2 GB of CLI logs with `JSONSerialization` and no autorelease pool, so every parsed object lived until the scan ended: a 3 GB peak, and hundreds of MB kept by the allocator afterwards. Fix: an `autoreleasepool` per line, peak under 40 MB (`macos/Limita/Data/ActivityReader.swift`) | **Not affected.** `for_each_line` parses each line into a local `serde_json::Value` that Rust drops at the end of the iteration; the callbacks keep only small typed values (`Event`, `Days`). No custom allocator is set (`windows/core/src/activity.rs`) | Nothing. Whether the system allocator returns freed memory to the OS can only be measured. |
| 2 | **Prime-time badge decoded the whole sprite sheet per frame.** The 196 frames were cut with `CGImage.cropping`; ImageIO decodes lazily, so each cropped frame decoded its own copy of the 1092×1092 sheet when drawn: about 450 MB. Fix: `cutFrames` draws each frame into its own 78×78 bitmap, about 6 MB in all (`macos/Limita/UI/ExpandedView.swift`) | **Not affected, as far as the code shows.** The badge is one element with `background: url("/prime-time.webp") … / 364px 364px` and `steps(14)` animations; there is no per-frame image or crop (`windows/app/src/styles.css`, `.burning-gauge`). That Chromium keeps a single decoded copy of the sheet is an inference | Nothing. Optionally measure the WebView2 renderer with the badge shown and hidden. |

Where Windows differs from macOS in ways that could matter for memory or disk use. These are risks to measure, not known problems:

| Risk | Where | What to measure, and the fix if it matters |
|---|---|---|
| **Whole files are read into memory.** `refresh` calls `std::fs::read` on every new or changed log, so the scan peak is about the size of the largest transcript, not the 2 GB total. macOS memory-maps the same files (`Data(contentsOf:options: .mappedIfSafe)`) | `windows/core/src/activity.rs` (`refresh`); `macos/Limita/Data/ActivityReader.swift` | Largest file under `~/.claude/projects` and `~/.codex/sessions`; peak private bytes of `limita.exe` during the first scan with an empty cache. Fix: `memmap2`, or a buffered line-by-line read. |
| **The webview is created hidden and never destroyed.** The `panel` window is declared with `visible: false` and only hidden afterwards, so the WebView2 processes stay resident for the app's lifetime. The page empties its DOM when hidden. macOS is native SwiftUI and has no such cost | `windows/app/src-tauri/tauri.conf.json` (`visible`); `windows/app/src-tauri/src/panel.rs` (`hide`); `windows/app/src/main.ts` (`replaceChildren`) | Idle working set of `limita.exe` plus all `msedgewebview2.exe` children a few minutes after the dashboard was closed. Fix: create the window on demand; larger, since sizing, the pill and the floating mode share one window. |
| **The Codex reader stats every rollout each minute**, and when the newest files hold no `rate_limits` it reads them to the beginning before moving on. Memory stays bounded (64 KiB chunks), disk reads may not | `windows/core/src/codex_reader.rs`, `windows/core/src/tail.rs`; the macOS reader has the same shape (`CodexLimitsReader.swift`) | Time and bytes read per minute on a machine with thousands of rollouts. Fix: remember the newest file known to hold a snapshot. |
| **`activity.json` is read, merged and rewritten in full on every scan**, and the active session's log always has a new mtime, so it is re-read each time the dashboard opens. macOS does the same merge | `activity.rs`; `ActivityStore.swift` | Likely fine. Worth a look only if scans show up in a profile. |

Already equal: the unchanged-file cache keyed by size and mtime, the scan only while the activity panel is open, 60 s polling and the small reset-tracker state. Windows has no `setInterval` or animation-frame loop in the frontend, and its background threads sleep.

## macOS only since 0.24.0

Version 0.24.0 added these on macOS; the Windows port has not started. The rows in the tables above say what each piece does. What a Windows port needs beyond the UI:

- **Key storage.** The Windows Credential Manager, so the key is never written to `settings.json`. The key is checked with DeepSeek before it is stored and removed on Disconnect.
- **Balance history.** A new file beside `activity.json` in `%APPDATA%\Limita\`, written atomically, since the history cannot be rebuilt. The rules are in `BalanceLedger.swift` and its tests in `macos/Tests/LimitaTests/DeepSeekTests.swift`: only changes are kept, one sample per hour after a day, 90 days, a new currency starts over.
- **Provider model.** Windows hard-codes two services in `windows/core/src/model.rs`, `store.rs`, `settings.rs` and `view.rs`. macOS added `Service.Kind` (`limits` or `balance`), an optional `balance` on the snapshot, and a refresh loop over every connected service instead of two hand-written branches; the same shape fits the Rust store.
- **Notifications.** The low-balance alert reuses the reset-notification path (`lib.rs`), with its own setting.
- **Settings window.** A second Tauri window with the same four tabs. The tray menu should shrink the same way (Show Limits, Refresh, Settings, Quit), so the platforms stay alike. Rebindable shortcuts need `UnregisterHotKey` and a recorder; polling intervals and the update-check switch are new settings in `settings.json`.

## Porting checklist for Windows

Ordered by impact. Items marked *measure* come first because the answer decides how much work follows.

1. **Measure memory** (*measure*). Idle and first-scan working set on a machine with a large `~/.claude` and `~/.codex`; the three risks in the table above. Then, if needed, memory-map or stream log files, and create the webview on demand.
2. **Per-meter folding.** The ⌄ button, the capsules on the ACTIVITY line and a persisted `foldedMeters` (or `collapsedMeters`) setting in `settings.json`. Logic in `windows/core/src/view.rs`, drawing in `windows/app/src/main.ts`.
3. **Reset-notification click.** Make a toast click open the dashboard, as on macOS; today it is not handled in this repository.
4. **Terminal integration.** Write the same `snapshot.json` (or a documented equivalent) and decide which Windows terminal gets a plugin.
5. **A Settings window and a shorter tray menu**, as on macOS since 0.24.0: toggles, connecting providers, rebindable shortcuts, polling intervals and the update-check switch move out of the tray menu.
6. **Updater test overrides**, equivalent to `LIMITA_UPDATE_FEED` and `LIMITA_UPDATE_INSTALL`, so an update can be tried without a release.
7. **Test the glue.** `panel.rs`, `platform.rs`, `tray.rs`, `updater.rs` and `lib.rs` have no tests; so far every regression there has needed a manual Windows run.
8. **Version check for `Cargo.toml` and `package.json`** in `windows-release.yml`, which compares only `tauri.conf.json` and `project.yml`.
9. **ARM64 build** of the installer.
10. **DeepSeek** as a third provider (see [macOS only since 0.24.0](#macos-only-since-0240)).
11. **Hide the tray icon from the dashboard** (macOS has a header button). Low priority, and probably not worth porting: Windows manages tray icons itself.

Not a Windows task, but found on the way: macOS has no CI. A workflow that runs `swift test` on every pull request would close the largest process gap between the platforms.

## Documentation that no longer matches the code

Small mismatches found while comparing that still need a decision; fixed ones are removed.

- `windows/cli/src/main.rs` says the uninstaller runs `--remove-hook`, but `tauri.conf.json` has no uninstall hook; the README treats it as a manual step. After an uninstall `limita-cli.exe` is probably gone as well (*inferred*), so the manual step may no longer work.

