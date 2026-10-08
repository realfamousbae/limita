#!/usr/bin/env python3
"""Limita in iTerm2: a status-bar component with each connected service's 5-hour and
weekly limits, shown while Claude Code or Codex runs in the session (a knob turns that
off). A click on it opens the Limita dashboard.

The Limita app writes what its dashboard shows to `snapshot.json` and removes it on
quit; this script only reads that file and formats it by the app's rules. See README.md
next to it.
"""

import asyncio
import datetime
import json
import os

SNAPSHOT = os.path.expanduser("~/Library/Application Support/Limita/snapshot.json")
IDENTIFIER = "com.limita.iterm2"
DASHBOARD_URL = "limita://dashboard"
WINDOW_SEPARATOR = " · "
SERVICE_SEPARATOR = "  │  "
AI_CLIS = {"claude", "codex"}
ONLY_WHILE_RUNNING = "only_while_ai_cli_runs"


# MARK: - Reading, by the rules in LimitData.swift


def load(path=SNAPSHOT):
    """The services the app tracks, or None when the app has not written anything."""
    try:
        with open(path, encoding="utf-8") as file:
            return json.load(file).get("services", [])
    except (OSError, ValueError):
        return None


def parse_date(text):
    if not text:
        return None
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


def display_percent(window, now):
    """An expired window has started over at zero."""
    resets_at = parse_date(window.get("resetsAt"))
    if resets_at and resets_at <= now:
        return 0.0
    return float(window.get("usedPercent", 0))


def shown_percent(window, meaning, now):
    used = display_percent(window, now)
    shown = 100 - used if meaning == "left" else used
    return min(max(shown, 0), 100)


def level(used):
    if used >= 90:
        return "critical"
    if used >= 70:
        return "warning"
    return "normal"


def is_stale(entry, now):
    """Decided here, not by the app, so a file left by a crashed app goes stale too."""
    if entry.get("status") == "stale":
        return True
    captured = parse_date(entry.get("capturedAt"))
    stale_after = entry.get("staleAfter")
    return bool(captured and stale_after and (now - captured).total_seconds() > stale_after)


def headline(entry):
    """The 5-hour window, or the weekly one only when the plan has no 5-hour limit."""
    if entry.get("fiveHour"):
        return entry["fiveHour"]
    if entry.get("hasNoFiveHourLimit") and entry.get("sevenDay"):
        return entry["sevenDay"]
    return None


# MARK: - Status bar

DOTS = {"normal": "🟢", "warning": "🟡", "critical": "🔴"}


def service_text(entry, now, weekly=True):
    """"🟢 Claude 5h 52% · 7d 49% used". The dot follows the headline window, as in the app."""
    main = headline(entry)
    if not main:
        return f"{entry['name']} 5h —"
    windows = []
    if not entry.get("hasNoFiveHourLimit"):
        windows.append(("5h", entry.get("fiveHour")))
    if weekly or entry.get("hasNoFiveHourLimit"):
        windows.append(("7d", entry.get("sevenDay")))
    parts = []
    for label, window in windows:
        percent = f"{shown_percent(window, entry['meaning'], now):.0f}%" if window else "—"
        parts.append(f"{label} {percent}")
    dot = DOTS[level(display_percent(main, now))]
    stale = " (stale)" if is_stale(entry, now) else ""
    return f"{dot} {entry['name']} {WINDOW_SEPARATOR.join(parts)} {entry['meaning']}{stale}"


def status_variants(services, now):
    """Longest first; iTerm2 shows the longest one that fits."""
    if services is None:
        return ["Limita: not running"]
    if not services:
        return ["Limita: connect a service"]
    return [
        SERVICE_SEPARATOR.join(service_text(entry, now, weekly) for entry in services)
        for weekly in (True, False)
    ]


# MARK: - Which program runs in the session


def runs_ai_cli(job_name, command_line):
    """Claude Code or Codex in the foreground: the native builds run as `claude` and
    `codex`; npm installs run as `node /…/bin/claude`, so the first two words of the
    command line count too. Later words do not: `vim claude.md` is not Claude Code."""
    names = [job_name or ""] + (command_line or "").split()[:2]
    return any(os.path.basename(name).lstrip("-").lower() in AI_CLIS for name in names)


def status_for_session(services, now, job_name, command_line, only_while_running=True):
    if only_while_running and not runs_ai_cli(job_name, command_line):
        return [""]
    return status_variants(services, now)


# MARK: - iTerm2


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc)


def running_app(process_list):
    """The bundle of the running Limita, from `ps -axo comm=` output. Sent to that copy
    directly: with an older copy also installed, macOS may route the URL to the wrong one."""
    suffix = ".app/Contents/MacOS/Limita"
    for line in process_list.splitlines():
        line = line.strip()
        if line.endswith(suffix) and os.path.basename(line[: -len("/Contents/MacOS/Limita")]) == "Limita.app":
            return line[: -len("/Contents/MacOS/Limita")]
    return None


async def run(*command):
    process = await asyncio.create_subprocess_exec(*command, stdout=asyncio.subprocess.PIPE)
    output, _ = await process.communicate()
    return output.decode(errors="replace")


async def open_dashboard(session_id):
    app = running_app(await run("/bin/ps", "-axo", "comm="))
    if app:
        # -g: the panel opens without taking focus from the terminal.
        await run("/usr/bin/open", "-g", "-a", app, DASHBOARD_URL)


async def main(connection):
    component = iterm2.StatusBarComponent(
        short_description="Limita",
        detailed_description="Claude Code and Codex limits from the Limita app. Click for the dashboard.",
        knobs=[iterm2.CheckboxKnob("Only while Claude Code or Codex runs", True, ONLY_WHILE_RUNNING)],
        exemplar="🟢 Claude 5h 52% · 7d 49% used  │  🟢 Codex 5h 80% · 7d 64% left",
        update_cadence=30,
        identifier=IDENTIFIER,
    )

    # The references make iTerm2 call this again as soon as the foreground program changes.
    @iterm2.StatusBarRPC
    async def limita_status(
        knobs,
        job_name=iterm2.Reference("jobName?"),
        command_line=iterm2.Reference("commandLine?"),
    ):
        only = knobs.get(ONLY_WHILE_RUNNING, True) if isinstance(knobs, dict) else True
        return status_for_session(load(), now_utc(), job_name, command_line, only)

    await component.async_register(connection, limita_status, onclick=open_dashboard)


if __name__ == "__main__":
    import iterm2

    iterm2.run_forever(main)
