# Limita in iTerm2

A status-bar component with each service's 5-hour and weekly limits:

```
🟢 Claude 5h 52% · 7d 49% used  │  🟢 Codex 5h 80% · 7d 64% left
```

When space is short only the 5-hour limits are shown. A click opens the Limita
dashboard, as **⌃⌥L** does from any app.

The Limita app must be running: it writes what the dashboard shows to
`~/Library/Application Support/Limita/snapshot.json`, and this script reads that file.

## Install

1. In iTerm2, open **Settings → General → Magic** and turn on **Enable Python API**.
2. Copy the script into iTerm2's AutoLaunch folder:

   ```bash
   mkdir -p ~/Library/Application\ Support/iTerm2/Scripts/AutoLaunch
   cp limita.py ~/Library/Application\ Support/iTerm2/Scripts/AutoLaunch/
   ```

3. Start it once from the **Scripts → AutoLaunch → limita.py** menu, or restart iTerm2.
   The first run asks to download iTerm2's Python runtime. With a script in AutoLaunch,
   iTerm2 no longer opens a window at startup unless **Settings → General → Startup →
   Always open at least one terminal window at startup** is on.
4. **Settings → Profiles → Session**: turn on **Status bar enabled**, click
   **Configure Status Bar** and drag **Limita** into **Active Components**.

## Look

In **Configure Status Bar → Advanced…**:

- **Font**: pick the font of your terminal profile (**Profiles → Text**) to match it.
- **Centred**: choose the **Tight packing** layout, then put a **Spring** on each side
  of Limita.
