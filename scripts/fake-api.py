#!/usr/bin/env python3
"""Fake Claude usage API and Codex app server, for trying plans you do not have.

All responses are made up. To run Limita against them:

    scripts/fake-api.py serve &
    CFFIXED_USER_HOME=$(mktemp -d) LIMITA_CLAUDE_API=http://127.0.0.1:8377/ultra \
    LIMITA_CODEX_CLI=$PWD/scripts/fake-api.py LIMITA_FAKE_CODEX=pro \
    path/to/Limita.app/Contents/MacOS/Limita

With either variable set the app keeps its settings in `com.limita.fake`; run `defaults
delete com.limita.fake` between plans, or it takes the change for a limit reset. The
throwaway home does the same for its files. The path after the port picks the Claude plan and `LIMITA_FAKE_CODEX` the Codex one;
the keys of CLAUDE and CODEX below list them. The app calls this script as `codex
app-server`, so it answers on stdio too.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8377
HOUR = 3600


def iso(seconds):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + seconds))


def claude_window(used, seconds):
    return {"utilization": used, "resets_at": iso(seconds)}


def claude(subscription, tier, five_hour, seven_day):
    return {
        "profile": {"organization": {"organization_type": subscription, "rate_limit_tier": tier}},
        "usage": {"five_hour": five_hour, "seven_day": seven_day},
    }


CLAUDE = {
    "pro": claude("claude_pro", "default_claude_ai", claude_window(38, 2 * HOUR), claude_window(21, 90 * HOUR)),
    "max": claude("claude_max", "default_claude_max_5x", claude_window(74, 3 * HOUR), claude_window(46, 60 * HOUR)),
    # Keeps the temporary 5-hour limit until the account is verified.
    "ultra-unverified": claude("claude_max", "default_claude_max_20x", claude_window(12, 4 * HOUR), claude_window(9, 150 * HOUR)),
    "ultra": claude("claude_max", "default_claude_max_20x", None, claude_window(33, 110 * HOUR)),
    "ultra-near-limit": claude("claude_max", "default_claude_max_20x", None, claude_window(93, 20 * HOUR)),
    "team": claude("claude_team", "default_claude_max_5x", claude_window(5, HOUR), claude_window(17, 40 * HOUR)),
}


def codex_window(used, minutes, seconds):
    return {"usedPercent": used, "windowDurationMins": minutes, "resetsAt": int(time.time()) + seconds}


def codex(plan, primary, secondary):
    return {
        "primary": primary,
        "secondary": secondary,
        "credits": {"hasCredits": False, "unlimited": False, "balance": "0"},
        "planType": plan,
    }


FIVE_HOURS, WEEK = 300, 10080
CODEX = {
    "free": codex("free", codex_window(55, FIVE_HOURS, 3 * HOUR), codex_window(72, WEEK, 130 * HOUR)),
    "plus": codex("plus", codex_window(9, FIVE_HOURS, 4 * HOUR), codex_window(28, WEEK, 90 * HOUR)),
    "pro100": codex("prolite", codex_window(41, WEEK, 72 * HOUR), None),
    "pro": codex("pro", None, codex_window(19, WEEK, 120 * HOUR)),
    "pro-near-limit": codex("pro", codex_window(95, WEEK, 12 * HOUR), None),
    "team": codex("team", codex_window(34, WEEK, 48 * HOUR), None),
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        _, plan, *rest = self.path.split("/", 2)
        body = {"api/oauth/usage": "usage", "api/oauth/profile": "profile"}.get("".join(rest))
        if plan not in CLAUDE or body is None:
            self.send_error(404)
            return
        data = json.dumps(CLAUDE[plan][body]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def app_server():
    limits = CODEX[os.environ.get("LIMITA_FAKE_CODEX", "plus")]
    for line in sys.stdin:
        message = json.loads(line)
        if message.get("id") == 1:
            reply = {"id": 1, "result": {}}
        elif message.get("id") == 2:
            reply = {"id": 2, "result": {
                "rateLimits": limits,
                "rateLimitsByLimitId": {"codex": limits},
                "rateLimitResetCredits": {"availableCount": 1},
            }}
        else:
            continue
        print(json.dumps(reply), flush=True)


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "app-server":
        app_server()
    elif command == "serve":
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    else:
        sys.exit(__doc__)
