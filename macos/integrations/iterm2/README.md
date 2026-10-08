# Limita in iTerm2

`limita.py` adds a **Limita** component to iTerm2's status bar with each connected
service's 5-hour and weekly limits, shown while Claude Code or Codex is the foreground
program of the session (iTerm2's `jobName` and `commandLine` variables); a click opens the
Limita dashboard. In other sessions it hides the whole status bar for that session only
(`async_set_profile_properties`), so the bar takes no room. Installation and setup are in the
[main README](../../../README.md#iterm2). Each release also carries the script as
`limita.py`.

The Limita app writes what the dashboard shows to
`~/Library/Application Support/Limita/snapshot.json` and removes it on quit; the script
only reads that file. A click sends `limita://dashboard` to the running copy of the app.
