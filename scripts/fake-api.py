#!/usr/bin/env python3
"""Fake Claude usage API, Codex app server and DeepSeek balance API, for trying plans you do not have.

All responses are made up. To run Limita against them:

    scripts/fake-api.py serve &
    CFFIXED_USER_HOME=$(mktemp -d) LIMITA_CLAUDE_API=http://127.0.0.1:8377/ultra \
    LIMITA_CODEX_CLI=$PWD/scripts/fake-api.py LIMITA_FAKE_CODEX=pro \
    LIMITA_DEEPSEEK_API=http://127.0.0.1:8377/ds-normal \
    path/to/Limita.app/Contents/MacOS/Limita

With either variable set the app keeps its settings in `com.limita.fake`; run `defaults
delete com.limita.fake` between plans, or it takes the change for a limit reset. The
throwaway home does the same for its files. The path after the port picks the Claude plan and `LIMITA_FAKE_CODEX` the Codex one;
the keys of CLAUDE and CODEX below list them, and DEEPSEEK the DeepSeek balances. Each
balance request spends a little, so the dashboard has spending to show; a DeepSeek
key of "bad" is rejected with a 401. The app calls this script as `codex app-server`,
so it answers on stdio too.
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


FIVE_HOURS, WEEK, MONTH = 300, 10080, 43200
CODEX = {
    # Free has no 5-hour or weekly limit, only one 30-day window, and no credits.
    "free": dict(codex("free", codex_window(55, MONTH, 400 * HOUR), None), credits={"hasCredits": False, "unlimited": False, "balance": None}),
    "plus": codex("plus", codex_window(9, FIVE_HOURS, 4 * HOUR), codex_window(28, WEEK, 90 * HOUR)),
    "pro100": codex("prolite", codex_window(41, WEEK, 72 * HOUR), None),
    "pro": codex("pro", None, codex_window(19, WEEK, 120 * HOUR)),
    "pro-near-limit": codex("pro", codex_window(95, WEEK, 12 * HOUR), None),
    "team": codex("team", codex_window(34, WEEK, 48 * HOUR), None),
}


# Starting balances per currency, and what each request spends of the first one.
DEEPSEEK = {
    "ds-normal": {"available": True, "balances": [("CNY", 86.40, 10.00)], "spend": 0.37},
    "ds-low": {"available": True, "balances": [("CNY", 4.20, 0.00)], "spend": 0.12},
    "ds-empty": {"available": False, "balances": [("CNY", 0.00, 0.00)], "spend": 0},
    "ds-multi": {"available": True, "balances": [("USD", 12.50, 0.00), ("CNY", 3.00, 3.00)], "spend": 0.05},
}
deepseek_spent = {}


def deepseek_balance(plan):
    config = DEEPSEEK[plan]
    spent = deepseek_spent.get(plan, 0)
    deepseek_spent[plan] = spent + config["spend"]
    infos = []
    for index, (currency, total, granted) in enumerate(config["balances"]):
        total = max(total - (spent if index == 0 else 0), 0)
        granted = min(granted, total)
        infos.append({
            "currency": currency,
            "total_balance": f"{total:.2f}",
            "granted_balance": f"{granted:.2f}",
            "topped_up_balance": f"{total - granted:.2f}",
        })
    return {"is_available": config["available"], "balance_infos": infos}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        _, plan, *rest = self.path.split("/", 2)
        if plan in DEEPSEEK and "".join(rest) == "user/balance":
            if self.headers.get("Authorization") == "Bearer bad":
                self.send_error(401)
                return
            self.reply(deepseek_balance(plan))
            return
        body = {"api/oauth/usage": "usage", "api/oauth/profile": "profile"}.get("".join(rest))
        if plan not in CLAUDE or body is None:
            self.send_error(404)
            return
        self.reply(CLAUDE[plan][body])

    def reply(self, payload):
        data = json.dumps(payload).encode()
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
