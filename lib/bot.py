#!/usr/bin/env python3
"""
lib/bot.py — Telegram bot daemon for Nelly.

Security model
--------------
- Token loaded from <nelly_root>/bot/.token (mode 0600). Never logged.
- Allowed user IDs come from <nelly_root>/bot/config.json (allowed_users).
  Anyone not on the list is *silently ignored* — the bot does not respond,
  which avoids confirming the bot exists to a wrong audience.
- Every incoming message is logged to <nelly_root>/bot/bot.log with
  timestamp, user id, command, and outcome.
- Commands are dispatched via a hard-coded allow-list mapping each
  command to (handler, allow_when_read_only). Write commands are gated
  behind config.allow_writes.
- Arguments are validated against strict regex patterns before being
  passed to `nelly` via subprocess.run([...], shell=False). No string
  interpolation reaches a shell.
- Per-user rate limiting: at most N commands per window.
- Responses are truncated to 3800 chars (Telegram limit is 4096).

This script uses only the Python standard library — no pip install.
"""

from __future__ import annotations

import json
import logging
import os
import re
import signal
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from collections import deque
from pathlib import Path
from typing import Any, Callable

NELLY_ROOT = Path(os.environ["NELLY_ROOT"]).resolve()
BOT_DIR    = NELLY_ROOT / "bot"
TOKEN_PATH = BOT_DIR / ".token"
CONFIG_PATH = BOT_DIR / "config.json"
LOG_PATH   = BOT_DIR / "bot.log"
NELLY_BIN  = NELLY_ROOT / "bin" / "nelly"

API_BASE   = "https://api.telegram.org"
POLL_TIMEOUT = 30                 # seconds for long-poll
RESP_TRUNCATE = 3800              # chars
NELLY_CMD_TIMEOUT = 60            # seconds for any nelly invocation
RATE_LIMIT_WINDOW = 60            # seconds
RATE_LIMIT_MAX    = 30            # commands per window per user

# ---------------------------------------------------------------------------
# logging — append-only audit log + stderr
# ---------------------------------------------------------------------------

BOT_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH, mode="a", encoding="utf-8"),
        logging.StreamHandler(sys.stderr),
    ],
    level=logging.INFO,
)
log = logging.getLogger("nelly-bot")

# ---------------------------------------------------------------------------
# config + token loading (re-read on each poll cycle so edits take effect)
# ---------------------------------------------------------------------------

def load_token() -> str:
    try:
        token = TOKEN_PATH.read_text().strip()
    except FileNotFoundError:
        die("token not found — run: nelly bot setup")
    if not re.match(r"^\d+:[A-Za-z0-9_-]{30,}$", token):
        die(f"token at {TOKEN_PATH} does not look like a Telegram bot token")
    return token

def load_config() -> dict:
    try:
        cfg = json.loads(CONFIG_PATH.read_text())
    except FileNotFoundError:
        die("config not found — run: nelly bot setup")
    except json.JSONDecodeError as e:
        die(f"config.json is not valid JSON: {e}")
    cfg.setdefault("allowed_users", [])
    cfg.setdefault("allow_writes", False)
    cfg.setdefault("notify_chat_id", None)
    if not isinstance(cfg["allowed_users"], list) or not all(isinstance(u, int) for u in cfg["allowed_users"]):
        die("config.allowed_users must be a list of integers")
    return cfg

def die(msg: str) -> None:
    log.error(msg)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Telegram HTTP helpers
# ---------------------------------------------------------------------------

def tg(token: str, method: str, **params: Any) -> dict:
    url = f"{API_BASE}/bot{token}/{method}"
    data = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None}).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=POLL_TIMEOUT + 10) as resp:
        return json.loads(resp.read().decode("utf-8"))

def send_message(token: str, chat_id: int, text: str) -> None:
    text = text[:RESP_TRUNCATE]
    try:
        tg(token, "sendMessage", chat_id=chat_id, text=text, disable_web_page_preview="true")
    except Exception as e:
        log.warning("sendMessage failed (chat_id=%s): %s", chat_id, e)

# ---------------------------------------------------------------------------
# argument validation — strict, no shell escape needed
# ---------------------------------------------------------------------------

NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")   # deployment / app names
TAG_RE  = re.compile(r"^[A-Za-z0-9_-]{1,32}$")

def safe_name(s: str) -> str | None:
    return s if NAME_RE.match(s) else None

def safe_tag(s: str) -> str | None:
    return s if TAG_RE.match(s) else None

# ---------------------------------------------------------------------------
# command handlers — each returns a string to send back
# ---------------------------------------------------------------------------

def run_nelly(*args: str, env: dict | None = None) -> tuple[int, str]:
    """Run `nelly <args>` with shell=False; return (rc, combined output)."""
    e = os.environ.copy()
    e["NELLY_OUTPUT"] = "human"
    e["NELLY_YES"] = "1"
    if env:
        e.update(env)
    try:
        r = subprocess.run(
            [str(NELLY_BIN), *args],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=NELLY_CMD_TIMEOUT,
            env=e,
            check=False,
        )
        return r.returncode, r.stdout.decode("utf-8", errors="replace")
    except subprocess.TimeoutExpired:
        return 124, f"timeout after {NELLY_CMD_TIMEOUT}s"

def fmt(rc: int, out: str) -> str:
    out = out.rstrip()
    if rc == 0:
        return f"```\n{out or '(no output)'}\n```"
    return f"⚠️ exited {rc}\n```\n{out or '(no output)'}\n```"

# ---- read-only commands ----------------------------------------------------

def cmd_help(_args: list[str], _allow_writes: bool) -> str:
    lines = [
        "*Nelly bot* — available commands:",
        "",
        "Read-only:",
        "  /list                          list deployments",
        "  /status <name>                 status for one deployment",
        "  /ps                            running nelly containers",
        "  /stats                         live cpu/mem/pids",
        "  /logs <name> [app]             last 30 lines",
        "  /cron <name>                   what's scheduled",
        "  /explain <name>                plain-English summary",
        "  /doctor <name>                 pre-flight check",
        "  /events <name>                 recent docker events",
        "  /releases <name>               recent deploy history",
        "  /release  <name> [rel_id]      release manifest (default: latest)",
        "  /metrics  <name> [app|since]   per-app run stats",
    ]
    if _allow_writes:
        lines += [
            "",
            "Lifecycle (writes enabled):",
            "  /start_dep <name>",
            "  /stop_dep <name>",
            "  /restart_dep <name>",
            "  /runnow <name> <app>",
            "  /deploy <name>",
            "  /rollback <name>",
            "  /release_restore <name> <rel_id>     revert to a release (config+image)",
        ]
    lines += ["", "  /id                            print your Telegram user id"]
    return "\n".join(lines)

def cmd_id(_args: list[str], _aw: bool, *, user_id: int = 0) -> str:
    return f"your Telegram user id: `{user_id}`"

def cmd_list(_args: list[str], _aw: bool) -> str:
    rc, out = run_nelly("list")
    return fmt(rc, out)

def cmd_ps(_args: list[str], _aw: bool) -> str:
    rc, out = run_nelly("ps")
    return fmt(rc, out)

def cmd_stats(_args: list[str], _aw: bool) -> str:
    rc, out = run_nelly("stats")
    return fmt(rc, out)

def _one_name(args: list[str]) -> tuple[str | None, str | None]:
    if not args:
        return None, "usage: needs a deployment name"
    n = safe_name(args[0])
    if not n:
        return None, f"invalid deployment name: {args[0]!r}"
    return n, None

def cmd_status(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, out = run_nelly("status", n)
    return fmt(rc, out)

def cmd_logs(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    log_path = NELLY_ROOT / "containers" / n / "logs" / "cron"
    if len(args) >= 2:
        app = safe_name(args[1])
        if not app: return f"invalid app name: {args[1]!r}"
        f = log_path / f"{app}.log"
        if not f.is_file():
            return f"no log at {f.relative_to(NELLY_ROOT)}"
        try:
            tail = subprocess.check_output(["tail", "-n", "30", str(f)], timeout=5).decode("utf-8", errors="replace")
        except Exception as e:
            return f"failed to tail log: {e}"
        return f"```\n{tail or '(empty)'}\n```"
    # All apps' last 10 lines each
    if not log_path.is_dir():
        return f"no logs yet for {n}"
    out_lines = []
    for f in sorted(log_path.glob("*.log")):
        try:
            tail = subprocess.check_output(["tail", "-n", "10", str(f)], timeout=5).decode("utf-8", errors="replace")
        except Exception:
            continue
        out_lines.append(f"--- {f.name} ---\n{tail}")
    return "```\n" + ("\n".join(out_lines) or "(empty)") + "\n```"

def cmd_cron(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, out = run_nelly("cron", n)
    return fmt(rc, out)

def cmd_explain(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, out = run_nelly("explain", n)
    return fmt(rc, out)

def cmd_doctor(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, out = run_nelly("doctor", n)
    return fmt(rc, out)

def cmd_events(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    # `docker events` streams forever — use a short --since instead
    container = subprocess.run(
        [str(NELLY_BIN), "get", n, ".container_name"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10, check=False
    ).stdout.decode().strip()
    if not container:
        return f"no container known for {n}"
    try:
        out = subprocess.check_output(
            ["docker", "events", "--since", "1h", "--until", "0s",
             "--filter", f"container={container}",
             "--format", "{{.Time}}  {{.Action}}"],
            timeout=15
        ).decode("utf-8", errors="replace")
    except Exception as e:
        return f"docker events failed: {e}"
    return f"```\n{out or '(no events in last hour)'}\n```"

REL_ID_RE = re.compile(r"^r-\d{4,}$")

def cmd_releases(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, out = run_nelly("release", "list", n)
    return fmt(rc, out)

def cmd_release(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    if len(args) >= 2:
        if not REL_ID_RE.match(args[1]):
            return f"invalid release id: {args[1]!r}"
        rc, out = run_nelly("release", "show", n, args[1])
    else:
        rc, out = run_nelly("release", "show", n)
    return fmt(rc, out)

def cmd_metrics(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    extra: list[str] = []
    if len(args) >= 2:
        # second arg may be an app name OR a since string like "24h"
        if re.match(r"^\d+[smhd]$", args[1]):
            extra = ["--since", args[1]]
        else:
            app = safe_name(args[1])
            if not app: return f"invalid app/since arg: {args[1]!r}"
            extra = ["--app", app]
    rc, out = run_nelly("metrics", n, *extra)
    return fmt(rc, out)

def cmd_release_restore(args: list[str], _aw: bool) -> str:
    if len(args) < 2:
        return "usage: /release_restore <name> <rel_id>"
    n = safe_name(args[0])
    if not n: return f"invalid name: {args[0]!r}"
    if not REL_ID_RE.match(args[1]):
        return f"invalid release id: {args[1]!r}"
    rc, out = run_nelly("release", "restore", n, args[1])
    return fmt(rc, out)

# ---- write commands (only when allow_writes) -------------------------------

def cmd_start_dep(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, out = run_nelly("start", n)
    return fmt(rc, out)

def cmd_stop_dep(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, out = run_nelly("stop", n)
    return fmt(rc, out)

def cmd_restart_dep(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, out = run_nelly("restart", n)
    return fmt(rc, out)

def cmd_runnow(args: list[str], _aw: bool) -> str:
    if len(args) < 2:
        return "usage: /runnow <name> <app>"
    n = safe_name(args[0])
    a = safe_name(args[1])
    if not n or not a: return "invalid name(s)"
    rc, out = run_nelly("run-now", n, a)
    return fmt(rc, out)

def cmd_deploy(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, out = run_nelly("deploy", n, "--wait-healthy", "60", "--auto-rollback")
    return fmt(rc, out)

def cmd_rollback(args: list[str], _aw: bool) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, out = run_nelly("rollback", n)
    return fmt(rc, out)

# ---- command table ---------------------------------------------------------

# (handler, needs_writes)
COMMANDS: dict[str, tuple[Callable, bool]] = {
    "help":        (cmd_help, False),
    "start":       (cmd_help, False),   # /start is Telegram's onboarding; show help
    "id":          (cmd_id,    False),
    "list":        (cmd_list,  False),
    "ls":          (cmd_list,  False),
    "ps":          (cmd_ps,    False),
    "stats":       (cmd_stats, False),
    "status":      (cmd_status,False),
    "logs":        (cmd_logs,  False),
    "cron":        (cmd_cron,  False),
    "explain":     (cmd_explain,False),
    "doctor":      (cmd_doctor,False),
    "events":      (cmd_events,False),
    "releases":    (cmd_releases, False),
    "release":     (cmd_release,  False),
    "metrics":     (cmd_metrics,  False),
    # writes
    "start_dep":      (cmd_start_dep,    True),
    "stop_dep":       (cmd_stop_dep,     True),
    "restart_dep":    (cmd_restart_dep,  True),
    "runnow":         (cmd_runnow,       True),
    "deploy":         (cmd_deploy,       True),
    "rollback":       (cmd_rollback,     True),
    "release_restore":(cmd_release_restore, True),
}

# ---------------------------------------------------------------------------
# rate limiting — per user, sliding window
# ---------------------------------------------------------------------------

_rl: dict[int, deque] = {}

def rate_limited(user_id: int) -> bool:
    now = time.time()
    q = _rl.setdefault(user_id, deque())
    while q and now - q[0] > RATE_LIMIT_WINDOW:
        q.popleft()
    if len(q) >= RATE_LIMIT_MAX:
        return True
    q.append(now)
    return False

# ---------------------------------------------------------------------------
# main loop
# ---------------------------------------------------------------------------

_running = True
def _shutdown(*_):
    global _running
    log.info("shutdown signal received")
    _running = False

signal.signal(signal.SIGINT,  _shutdown)
signal.signal(signal.SIGTERM, _shutdown)

def handle_update(token: str, cfg: dict, update: dict) -> None:
    msg = update.get("message") or update.get("edited_message")
    if not msg:
        return
    user = msg.get("from") or {}
    user_id = user.get("id")
    chat_id = (msg.get("chat") or {}).get("id")
    text    = msg.get("text") or ""

    # Authorize. Silent drop on unknown users — never confirm the bot exists.
    if user_id not in cfg["allowed_users"]:
        log.warning("DENIED user=%s username=%s text=%r",
                    user_id, user.get("username"), text[:120])
        return

    if rate_limited(user_id):
        log.warning("RATE-LIMITED user=%s", user_id)
        send_message(token, chat_id, "rate limit: please slow down")
        return

    # Parse: /command arg1 arg2 ...  (optionally /command@botname)
    parts = text.strip().split()
    if not parts or not parts[0].startswith("/"):
        return
    cmd_raw = parts[0][1:].lower().split("@", 1)[0]
    args = parts[1:]

    handler_entry = COMMANDS.get(cmd_raw)
    if not handler_entry:
        log.info("UNKNOWN user=%s cmd=%s", user_id, cmd_raw)
        send_message(token, chat_id, f"unknown command: /{cmd_raw} (try /help)")
        return
    handler, needs_writes = handler_entry
    if needs_writes and not cfg.get("allow_writes", False):
        log.info("WRITES-DISABLED user=%s cmd=%s", user_id, cmd_raw)
        send_message(token, chat_id,
            "writes disabled — enable with `allow_writes: true` in bot/config.json")
        return

    log.info("RUN user=%s cmd=%s args=%s", user_id, cmd_raw, args)
    try:
        if cmd_raw == "id":
            reply = handler(args, cfg.get("allow_writes", False), user_id=user_id)
        else:
            reply = handler(args, cfg.get("allow_writes", False))
    except Exception as e:
        log.exception("handler crashed: %s", e)
        reply = f"⚠️ internal error: {e!s}"

    if reply:
        send_message(token, chat_id, reply)

def main() -> None:
    cfg = load_config()
    token = load_token()
    # Verify token works before we start polling
    try:
        me = tg(token, "getMe")
        if not me.get("ok"):
            die(f"getMe failed: {me}")
        log.info("connected as @%s (id=%s)", me["result"]["username"], me["result"]["id"])
    except Exception as e:
        die(f"could not connect to Telegram: {e}")

    offset: int | None = None
    while _running:
        try:
            cfg = load_config()
            resp = tg(token, "getUpdates",
                      offset=offset, timeout=POLL_TIMEOUT,
                      allowed_updates=json.dumps(["message"]))
            if not resp.get("ok"):
                log.warning("getUpdates returned !ok: %s", resp)
                time.sleep(2)
                continue
            for upd in resp.get("result", []):
                offset = upd["update_id"] + 1
                try:
                    handle_update(token, cfg, upd)
                except Exception as e:
                    log.exception("update handler error: %s", e)
        except urllib.error.URLError as e:
            log.warning("network error: %s — retrying in 5s", e)
            time.sleep(5)
        except KeyboardInterrupt:
            break
        except Exception as e:
            log.exception("poll loop error: %s — retrying in 5s", e)
            time.sleep(5)
    log.info("exiting cleanly")

if __name__ == "__main__":
    main()
