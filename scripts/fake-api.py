#!/usr/bin/env python3
"""Fake provider usage and billing APIs and Codex app server.

All responses are made up. To run Limita against them:

    scripts/fake-api.py serve &
    CFFIXED_USER_HOME=$(mktemp -d) LIMITA_CLAUDE_API=http://127.0.0.1:8377/ultra \
    LIMITA_CODEX_CLI=$PWD/scripts/fake-api.py LIMITA_FAKE_CODEX=pro \
    LIMITA_DEEPSEEK_API=http://127.0.0.1:8377/ds-normal LIMITA_FAKE_PROVIDERS=1 \
    path/to/Limita.app/Contents/MacOS/Limita

With either variable set the app keeps its settings in `com.limita.fake`; run `defaults
delete com.limita.fake` between plans, or it takes the change for a limit reset. The
throwaway home does the same for its files. The path after the port picks the Claude plan and `LIMITA_FAKE_CODEX` the Codex one;
the keys of CLAUDE and CODEX below list them, and DEEPSEEK the DeepSeek balances. Each
balance request spends a little, so the dashboard has spending to show; a DeepSeek
key of "bad" is rejected with a 401. The app calls this script as `codex app-server`,
so it answers on stdio too.

Set LIMITA_FAKE_PROVIDERS=1 for the new cards. Use demo-management or demo for
OpenRouter, demo for Z.ai Coding Plan and OpenCode, and org_demo as the OpenCode
workspace. demo-partial omits OpenCode billing, demo-bad returns 401 and
demo-limited returns 429. The Qwen cards read the corresponding CLI-shaped fixture.

"""
import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, urlsplit
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


def demo_usage():
    today = datetime.now(timezone.utc).date()
    models = ("glm-5", "qwen3.6-plus", "deepseek-v4")
    return [
        (today - timedelta(days=age), model, round((index + 1) * 0.019 * ((age + index) % 5), 4))
        for age in range(1, 61)
        for index, model in enumerate(models)
        if (age + index) % 5
    ]


def provider_response(path, query, auth):
    if auth.endswith("demo-bad"):
        return 401, {"error": "bad demo credentials"}
    if auth.endswith("demo-limited"):
        return 429, {"error": "demo rate limit"}
    if path == "/providers/zai/api/monitor/usage/quota/limit":
        return 200, {"code": 200, "data": {"limits": [
            {"type": "TOKENS_LIMIT", "number": 5, "percentage": 29, "nextResetTime": int(time.time() + HOUR) * 1000},
            {"type": "TOKENS_LIMIT", "number": 7, "percentage": 41, "nextResetTime": int(time.time() + 60 * HOUR) * 1000},
            {"type": "TIME_LIMIT", "percentage": 13},
        ]}}
    if path == "/providers/zai/api/platform-charge-zai/business/accountBalance":
        return 200, {"code": 200, "data": {"totalBalance": "38.45"}}
    if path == "/providers/zai/api/platform-charge-zai/bill/day":
        period = query.get("billingPeriod", [""])[0]
        rows = [{"billingDate": day.isoformat(), "modelCode": model, "settlementAmount": str(cost)}
                for day, model, cost in demo_usage() if day.strftime("%Y-%m") == period]
        page = int(query.get("pageNum", ["1"])[0])
        size = int(query.get("pageSize", ["100"])[0])
        return 200, {"code": 200, "data": {"records": rows[(page - 1) * size:page * size], "total": len(rows)}}
    if path == "/providers/opencode/inference/go/v1/usage":
        return 200, {"usage": {name: {"status": "ok", "percent": value, "resetsAt": iso(reset)}
                                  for name, value, reset in [("rolling", 38, HOUR), ("weekly", 27, 48 * HOUR), ("monthly", 53, 400 * HOUR)]}}
    if path == "/providers/opencode/console/api/billing/status":
        return (403, {"error": "demo partial access"}) if auth.endswith("demo-partial") else (200, {"availableMicroCents": 1_737_000_000})
    if path == "/providers/opencode/console/api/v2/usage/export":
        return 200, "day,user,provider,model,cost_micro_cents\r\n" + "".join(
            f'{day},"Demo, User",opencode,{model},{round(cost * 100_000_000)}\r\n' for day, model, cost in demo_usage())
    if path == "/providers/opencode/console/auth/device/code":
        return 200, {"device_code": "demo-device", "user_code": "DEMO-1234", "verification_uri_complete": "/demo-opencode", "expires_in": 120, "interval": 1}
    if path == "/providers/opencode/console/auth/device/token":
        return 200, {"access_token": "demo-session", "refresh_token": "demo-refresh", "expires_in": 3600, "org_id": "org_demo"}
    if path == "/providers/openrouter/api/v1/key":
        return 200, {"data": {"is_management_key": auth.endswith("demo-management"), "usage_daily": 0.53,
                              "usage_weekly": 4.13, "usage_monthly": 15.73, "limit_remaining": 84.27}}
    if path == "/providers/openrouter/api/v1/credits":
        return (200, {"data": {"total_credits": 100, "total_usage": 15.73}}) if auth.endswith("demo-management") else (403, {})
    if path == "/providers/openrouter/api/v1/activity":
        if not auth.endswith("demo-management"):
            return 403, {}
        return 200, {"data": [{"date": (day.isoformat() + "T00:00:00Z"), "model": model, "usage": cost, "byok_usage_inference": 0.75}
                              for day, model, cost in demo_usage()[:80]]}
    if path == "/providers/qwen/coding-plan":
        return 200, {"per5Hour": {"percentage": .21}, "perWeek": {"percentage": .32}, "perBillMonth": {"percentage": .64}}
    if path == "/providers/qwen/token-plan":
        return 200, {"hasQuotaData": True, "per1MonthPercentage": .57}
    if path == "/providers/qwen/get-caller-identity":
        return 200, {"AccountId": "demo-account"}
    if path == "/providers/qwen/query-account-balance":
        return 200, {"Data": {"AvailableAmount": "31.90", "Currency": "USD"}}
    if path == "/providers/qwen/get-billing-trend":
        days = {}
        for day, model, cost in demo_usage():
            days.setdefault(day, []).append({"key": model, "amount": str(cost)})
        return 200, {"data": {"costTotals": {"currency": "USD"}, "resultByTime": [
            {"period": day.strftime("%Y%m%d"), "periodDetails": rows,
             "total": {"currency": "USD", "amount": str(sum(float(row["amount"]) for row in rows))}}
            for day, rows in days.items()
        ]}}
    return 404, {"error": "unknown fixture"}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/providers/"):
            self.provider_request()
            return
        if self.path == "/demo-opencode":
            self.reply("OpenCode demo sign-in complete. Return to Limita.")
            return
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

    def do_POST(self):
        if self.path.startswith("/providers/"):
            self.provider_request()
        else:
            self.send_error(404)

    def provider_request(self):
        url = urlsplit(self.path)
        size = int(self.headers.get("Content-Length", "0"))
        if size:
            self.rfile.read(size)
        status, response = provider_response(url.path, parse_qs(url.query), self.headers.get("Authorization", ""))
        self.reply(response, status)

    def reply(self, payload, status=200):
        is_text = isinstance(payload, str)
        data = (payload if is_text else json.dumps(payload)).encode()
        self.send_response(status)
        if status == 429:
            self.send_header("Retry-After", "15")
        self.send_header("Content-Type", "text/plain; charset=utf-8" if is_text else "application/json")
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
