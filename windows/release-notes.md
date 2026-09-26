### Limita for Windows

The first Windows version of Limita: your **Claude Code** and **Codex** 5-hour and weekly limits, one glance from the tray.

- **Tray icon.** A dot on the icon follows the 5-hour limit: green, yellow from 70 % used (30 % left), red from 90 %; faded when the data is stale. Hover it for each service's numbers.
- **Dashboard.** Left-click the icon for both services side by side: 5-hour and 7-day meters, a countdown to each reset, balances and credits, and the reason whenever a live update fails. Click elsewhere or press **Esc** to close it.
- **Hover pill.** Rest the cursor at the top edge of any screen, anywhere along it, and a compact pill slides in; click it for the dashboard. It never takes keyboard focus and stays away from full-screen apps.
- **Menu.** Right-click the icon to connect or disconnect Claude Code and Codex, refresh, turn on **Launch at Login**, or quit.
- **Same numbers as on the Mac.** Claude shows what is used, Codex what is left; the same live sources, refresh intervals, colours and countdown.

### Install

1. Download `Limita_0.1.0_x64-setup.exe` and run it. It installs for your user only, no administrator rights needed.
2. The installer is not signed yet, so SmartScreen warns about it: choose **More info → Run anyway**.
3. Limita starts in the tray. If Windows tucks the icon under **^**, drag it onto the taskbar to keep it in sight.

Claude Code and Codex are picked up automatically if they are installed. Claude's live numbers need Claude Code to be signed in; after a long break, start Claude Code once to renew its login.

To check what Limita finds on your machine, run `"%LOCALAPPDATA%\Limita\limita-cli.exe" --dump` in a terminal. More in the [Windows README](https://github.com/realfamousbae/limita/blob/main/windows/README.md).
