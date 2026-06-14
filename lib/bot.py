#!/usr/bin/env python3
"""
lib/bot.py — Telegram bot daemon for Nelly.

Output convention
-----------------
Every response is designed to fit a phone screen in portrait mode:

  - Bold headers live OUTSIDE <pre> blocks.
  - All tabular / key-value content lives INSIDE <pre> blocks (monospace,
    so columns line up identically on every Telegram client).
  - Lines are kept to ~38 characters or less so they don't wrap on
    typical phone widths.
  - Status is conveyed with colored dots on header/list lines
    (🟢 ok / 🟡 warn / 🔴 fail / ⚪ off); numeric content stays inside
    <pre> blocks with no emoji so monospace columns line up identically
    on every Telegram client.
  - Layout is menu-first: /start is a slim main menu (verdict + only the
    deployments needing attention + buttons), the full command reference
    lives in /help, and every screen carries a "Menu" button so there is
    always a clear way back. Most messages have an inline keyboard with
    the obvious next actions so the user rarely has to type commands.

Security model
--------------
- Token loaded from <nelly_root>/bot/.token (mode 0600). Never logged.
- Allowed user IDs come from <nelly_root>/bot/config.json (allowed_users).
  Anyone not on the list is silently ignored — for both message and
  callback_query updates.
- Every incoming update is logged to <nelly_root>/bot/bot.log with
  timestamp, user id, command, and outcome.
- Commands are dispatched via a hard-coded allow-list mapping each
  command to (handler, allow_when_read_only). Write commands and write
  button taps are both gated behind config.allow_writes.
- Destructive button taps (stop / restart / deploy / restore) require a
  second confirming tap; typed write commands run immediately.
- Callback data carries a short opcode + validated args; the same
  COMMANDS table is used for text and button-driven invocation, so
  there's no separate "secret" code path.
- Arguments are validated against strict regex patterns before being
  passed to `nelly` via subprocess.run([...], shell=False). No string
  interpolation reaches a shell.
- Per-user rate limiting: at most N commands per window (counts both
  typed commands and button taps).
- Responses are sent with parse_mode=HTML; all user-controlled content
  is HTML-escaped via html.escape().
- Responses are truncated to 3800 chars (Telegram limit is 4096).

Python stdlib only — no pip install.
"""

from __future__ import annotations

import datetime
import html
import json
import logging
import os
import re
import signal
import socket
import subprocess
import sys
import textwrap
import time
import urllib.parse
import urllib.request
from collections import deque
from pathlib import Path
from typing import Any, Callable, Iterable

NELLY_ROOT = Path(os.environ["NELLY_ROOT"]).resolve()
BOT_DIR    = NELLY_ROOT / "bot"
TOKEN_PATH = BOT_DIR / ".token"
CONFIG_PATH = BOT_DIR / "config.json"
LOG_PATH   = BOT_DIR / "bot.log"
NELLY_BIN  = NELLY_ROOT / "bin" / "nelly"
HOST_NAME  = socket.gethostname()

API_BASE     = "https://api.telegram.org"
POLL_TIMEOUT = 30
RESP_TRUNCATE = 3800
NELLY_CMD_TIMEOUT = 60
RATE_LIMIT_WINDOW = 60
RATE_LIMIT_MAX    = 30
MOBILE_WIDTH = 38
CB_MAX = 64                # Telegram callback_data byte limit

# ---------------------------------------------------------------------------
# logging
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
# config + token loading
# ---------------------------------------------------------------------------

def die(msg: str) -> None:
    log.error(msg)
    sys.exit(1)

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

def try_reload_config(current: dict) -> dict:
    """Poll-loop config reload that never kills the daemon: on a bad or
    mid-edit config.json, keep the last-good config and warn instead of
    die()ing (which would SystemExit straight past the loop's handler)."""
    try:
        return load_config()
    except SystemExit:
        log.warning("config reload failed; keeping last-good config — fix %s", CONFIG_PATH)
        return current

# ---------------------------------------------------------------------------
# Telegram HTTP
# ---------------------------------------------------------------------------

def tg(token: str, method: str, **params: Any) -> dict:
    url = f"{API_BASE}/bot{token}/{method}"
    data = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None}).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=POLL_TIMEOUT + 10) as resp:
        return json.loads(resp.read().decode("utf-8"))

def send_message(token: str, chat_id: int, text: str,
                 keyboard: list | None = None) -> None:
    text = text[:RESP_TRUNCATE]
    params: dict[str, Any] = {
        "chat_id": chat_id, "text": text,
        "parse_mode": "HTML", "disable_web_page_preview": "true",
    }
    if keyboard:
        params["reply_markup"] = json.dumps({"inline_keyboard": keyboard})
    try:
        tg(token, "sendMessage", **params)
    except Exception as e:
        log.warning("sendMessage failed (chat_id=%s): %s", chat_id, e)
        try:
            # Last-ditch plaintext: drop tags AND decode entities so the user
            # doesn't see leftover &lt; / &amp; from the HTML-escaped content.
            tg(token, "sendMessage", chat_id=chat_id,
               text=html.unescape(re.sub(r"<[^>]+>", "", text)),
               disable_web_page_preview="true")
        except Exception:
            pass

def answer_callback(token: str, cb_id: str, text: str | None = None) -> None:
    try:
        tg(token, "answerCallbackQuery", callback_query_id=cb_id,
           text=(text[:200] if text else None))
    except Exception as e:
        log.warning("answerCallbackQuery failed: %s", e)

# ---------------------------------------------------------------------------
# HTML helpers
# ---------------------------------------------------------------------------

def esc(s: Any) -> str:
    return html.escape("" if s is None else str(s), quote=False)

def b(s: Any)    -> str: return f"<b>{esc(s)}</b>"
def i_(s: Any)   -> str: return f"<i>{esc(s)}</i>"
def code(s: Any) -> str: return f"<code>{esc(s)}</code>"
def pre(s: Any)  -> str: return f"<pre>{esc(s)}</pre>"

# ---------------------------------------------------------------------------
# compactors
# ---------------------------------------------------------------------------

def short_image(img: str) -> str:
    if not img or img in ("(none)", "(not built)"):
        return img or "(none)"
    if "@" in img:
        return img.split("@")[0] + "@..."
    if ":" in img:
        name, tag = img.split(":", 1)
        if len(tag) > 10:
            tag = tag[:10]
        return f"{name}:{tag}"
    return img

def fmt_ts(ts: str) -> str:
    if not ts: return "-"
    m = re.match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})", ts)
    return f"{m.group(1)} {m.group(2)}" if m else ts

def trunc(s: str, n: int) -> str:
    if s is None: return ""
    s = str(s)
    return s if len(s) <= n else s[: max(0, n - 3)] + "..."

def state_dot(state: str) -> str:
    """Colored status dot for a deployment state."""
    return {
        "running":    "🟢",
        "unhealthy":  "🟡",
        "restarting": "🟡",
        "exited":     "🔴",
        "dead":       "🔴",
        "absent":     "⚪",
    }.get(state, "⚫")

# ---------------------------------------------------------------------------
# layout primitives
# ---------------------------------------------------------------------------

def card(title: str, pairs: Iterable[tuple[str, Any]]) -> str:
    valid = [(str(k), str(v)) for k, v in pairs
             if v not in (None, "", "n/a")]
    out = [title]
    if valid:
        kw = max(len(k) for k, _ in valid)
        for k, v in valid:
            out.append(f"  {k+':':<{kw+2}}{v}")
    return "\n".join(out)

def kv(pairs: Iterable[tuple[str, Any]], *, key_width: int | None = None) -> str:
    valid = [(str(k), str(v)) for k, v in pairs
             if v not in (None, "", "n/a")]
    if not valid: return ""
    width = key_width or max(len(k) for k, _ in valid)
    return "\n".join(f"{k:<{width}} : {v}" for k, v in valid)

def narrow_table(rows: list[list[str]], headers: list[str] | None = None,
                 gutter: str = "  ") -> str:
    str_rows = [[str(c) if c is not None else "" for c in row] for row in rows]
    all_rows = [list(headers)] + str_rows if headers else str_rows
    if not all_rows: return ""
    n_cols = max(len(r) for r in all_rows)
    for r in all_rows:
        r += [""] * (n_cols - len(r))
    widths = [max(len(r[c]) for r in all_rows) for c in range(n_cols)]
    return "\n".join(
        gutter.join(c.ljust(w) for c, w in zip(r, widths)).rstrip()
        for r in all_rows
    )

def section(title: str, body: str) -> str:
    if not body:
        return ""
    return f"{b(title)}\n{pre(body)}"

# ---------------------------------------------------------------------------
# inline keyboards
# ---------------------------------------------------------------------------

def _btn(label: str, data: str) -> dict | None:
    """Build one button if callback_data fits in 64 bytes; else drop it."""
    if len(data.encode("utf-8")) > CB_MAX:
        log.warning("dropping button (cb_data too long): %s", data)
        return None
    return {"text": label, "callback_data": data}

def kbd(*rows: list[tuple[str, str]]) -> list[list[dict]]:
    """Build an inline_keyboard from (label, callback_data) tuples.
    Empty rows and dropped buttons are filtered out."""
    out = []
    for row in rows:
        btns = [_btn(label, data) for label, data in row]
        btns = [b for b in btns if b is not None]
        if btns:
            out.append(btns)
    return out

# Button rows we reuse across commands.

def kbd_for_deployment(n: str, allow_writes: bool) -> list[list[tuple[str, str]]]:
    """The standard action keyboard for a single deployment, 2 buttons wide.
    Destructive actions route through a confirmation step (cf|<op>|...).
    Always ends with a nav row so there's a clear way back."""
    rows = [
        [("Logs",     f"lg|{n}"), ("Metrics",  f"m|{n}")],
        [("Cron",     f"c|{n}"),  ("Releases", f"rs|{n}")],
        [("Doctor",   f"d|{n}"),  ("Refresh",  f"s|{n}")],
    ]
    if allow_writes:
        rows += [
            [("Restart", f"cf|re|{n}"), ("Stop", f"cf|st|{n}")],
            [("Deploy",  f"cf|dp|{n}")],
        ]
    rows.append([("« Menu", "start"), ("Deployments", "ls")])
    return rows

# ---------------------------------------------------------------------------
# arg validation
# ---------------------------------------------------------------------------

NAME_RE   = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")
REL_ID_RE = re.compile(r"^r-\d{4,}$")

def safe_name(s: str) -> str | None:
    return s if NAME_RE.match(s) else None

# ---------------------------------------------------------------------------
# `nelly` runner
# ---------------------------------------------------------------------------

def run_nelly(*args: str, json_output: bool = False) -> tuple[int, str]:
    e = os.environ.copy()
    e["NELLY_OUTPUT"] = "json" if json_output else "human"
    e["NELLY_YES"] = "1"
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

def fmt_err(rc: int, out: str) -> str:
    return f"{b('command failed')}  exit {rc}\n{pre(out[:1500].rstrip() or '(no output)')}"

# A handler returns either a plain HTML string or a (string, keyboard) tuple.
Response = str | tuple[str, list]

def _split_resp(resp: Response) -> tuple[str, list | None]:
    if isinstance(resp, tuple):
        return resp[0], (resp[1] if len(resp) > 1 else None)
    return resp, None

# ---------------------------------------------------------------------------
# /start — dashboard
# ---------------------------------------------------------------------------

_SEVERITY = {"exited": 0, "dead": 0, "unhealthy": 1, "restarting": 1, "absent": 2, "running": 3}

def cmd_start(_args, allow_writes, **_) -> Response:
    """Main menu. Kept deliberately short: a one-line health verdict, only the
    deployments that actually need attention, a single compact counts line, and
    a button menu. Healthy deployments stay out of the text — they're one tap
    away via their own button or the Deployments list. Worst-first ordering puts
    any problem at the top of both the text and the buttons."""
    rc, raw = run_nelly("list", json_output=True)
    items: list[dict] = []
    if rc == 0:
        try:
            items = json.loads(raw)
        except Exception:
            items = []
    items.sort(key=lambda d: (_SEVERITY.get(d.get("state", ""), 2), d.get("deployment", "")))

    n_total     = len(items)
    n_running   = sum(1 for d in items if d.get("state") == "running")
    n_unhealthy = sum(1 for d in items if d.get("state") in ("unhealthy", "restarting"))
    n_failed    = sum(1 for d in items if d.get("state") in ("exited", "dead"))
    n_absent    = sum(1 for d in items if d.get("state") == "absent")

    out = [b(f"Nelly · {HOST_NAME}")]

    if not n_total:
        out += ["", i_("No deployments yet."),
                i_("Run  nelly init <name>  on the host.")]
        return "\n".join(out), kbd([("Help", "help")])

    # One-line verdict.
    if n_failed or n_unhealthy:
        bits = []
        if n_failed:    bits.append(f"🔴 {n_failed} failed")
        if n_unhealthy: bits.append(f"🟡 {n_unhealthy} unhealthy")
        out.append("  ".join(bits))
    elif n_absent:
        out.append(f"⚪ {n_absent} not deployed")
    else:
        out.append("🟢 all healthy")

    # Only the deployments that need attention, named.
    trouble = [d for d in items
               if d.get("state") in ("exited", "dead", "unhealthy", "restarting")]
    if trouble:
        lines = [f"{state_dot(d.get('state',''))} {b(trunc(d.get('deployment','?'), 20))}"
                 f"  {esc(d.get('state',''))}"
                 for d in trouble]
        out += ["", b("Needs attention"), *lines]

    # One compact counts line instead of a multi-row summary block.
    out += ["", i_(f"{n_total} deployments · {n_running} running")]

    # Buttons: quick-access per deployment (worst-first, up to 8, 2 wide),
    # then a fixed nav menu.
    kbd_rows: list[list[tuple[str, str]]] = []
    row: list[tuple[str, str]] = []
    for d in items[:8]:
        name = d.get("deployment", "")
        if not name: continue
        row.append((trunc(name, 16), f"s|{name}"))
        if len(row) == 2:
            kbd_rows.append(row); row = []
    if row: kbd_rows.append(row)
    kbd_rows.append([("Deployments", "ls"), ("Live stats", "stats")])
    kbd_rows.append([("Refresh", "start"), ("Help", "help")])

    return "\n".join(out), kbd(*kbd_rows)

# ---------------------------------------------------------------------------
# /help
# ---------------------------------------------------------------------------

# <n> = deployment name.  Grouped so the list is scannable, not a wall.
HELP_READ = """\
Navigate
  /start            main menu
  /list             all deployments
  /status   <n>     one deployment

Monitor
  /ps               running containers
  /stats            cpu / mem / pids
  /logs     <n>     last cron output
  /metrics  <n>     run statistics
  /events   <n>     docker events

Inspect
  /cron     <n>     schedules
  /explain  <n>     plain summary
  /doctor   <n>     pre-flight check
  /releases <n>     deploy history
  /release  <n>     release manifest

System
  /update_check     upstream updates?
  /id               your user id"""

HELP_WRITE = """\
Deploy
  /deploy           <n>
  /rollback         <n>
  /release_restore  <n> <id>
  /update           apply updates

Lifecycle
  /start_dep        <n>
  /stop_dep         <n>
  /restart_dep      <n>
  /runnow           <n> <app>"""

def cmd_help(_args, allow_writes, **_) -> Response:
    parts = [
        b("Nelly bot · commands"),
        i_("Most screens have buttons — tap instead of typing."),
        "",
        section("Read-only", HELP_READ),
    ]
    if allow_writes:
        parts += ["", section("Write actions", HELP_WRITE)]
    else:
        parts += ["", i_("Write actions are off (allow_writes: false).")]
    return "\n".join(parts), kbd(
        [("« Menu", "start"), ("Deployments", "ls")],
    )

def cmd_id(_args, _aw, *, user_id: int = 0, **_) -> str:
    return f"{b('Your Telegram user id')}\n{pre(str(user_id))}"

# ---------------------------------------------------------------------------
# /list, /ps, /stats
# ---------------------------------------------------------------------------

def cmd_list(_args, allow_writes, **_) -> Response:
    rc, raw = run_nelly("list", json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b('Deployments')}\n{i_('(none)')}", kbd([("« Menu", "start")])
    items.sort(key=lambda d: (_SEVERITY.get(d.get("state", ""), 2), d.get("deployment", "")))

    blocks = []
    for d in items:
        name  = trunc(d.get("deployment", "?"), 22)
        state = d.get("state", "?")
        apps  = d.get("apps", 0)
        img   = short_image(d.get("image", ""))
        blocks.append(
            f"{state_dot(state)} {b(name)}  {esc(state)}\n"
            f"{code(f'{apps} apps · {img}')}"
        )
    text = b("Deployments") + "\n\n" + "\n\n".join(blocks)

    # Buttons: one per deployment (up to 8), 2 wide.
    rows: list[list[tuple[str, str]]] = []
    row: list[tuple[str, str]] = []
    for d in items[:8]:
        name = d.get("deployment", "")
        if not name: continue
        row.append((trunc(name, 16), f"s|{name}"))
        if len(row) == 2:
            rows.append(row); row = []
    if row: rows.append(row)
    rows.append([("« Menu", "start"), ("Refresh", "ls")])
    return text, kbd(*rows)

def _ps_dot(status: str) -> str:
    """Status dot from a docker status string (e.g. 'Up 3h', 'Exited (0) …')."""
    if "unhealthy" in status:        return "🟡"
    if status.startswith("Up"):      return "🟢"
    if status.startswith(("Exited", "Dead")): return "🔴"
    return "⚪"

def cmd_ps(_args, _aw, **_) -> Response:
    rc, raw = run_nelly("ps", json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b('Containers')}\n{i_('(none running)')}", kbd([("« Menu", "start")])
    blocks = []
    for c in items:
        labels = c.get("Labels", "")
        deployment = next(
            (kv_str.split("=", 1)[1] for kv_str in labels.split(",")
             if kv_str.startswith("nelly.deployment=")),
            c.get("Names", "?"),
        )
        status = c.get("Status", "")
        blocks.append(
            f"{_ps_dot(status)} {b(trunc(deployment, 22))}\n"
            f"{code(trunc(status, 34))}\n"
            f"{code(short_image(c.get('Image', '')))}"
        )
    return b("Containers") + "\n\n" + "\n\n".join(blocks), kbd(
        [("« Menu", "start"), ("Refresh", "ps")],
    )

def cmd_stats(_args, _aw, **_) -> Response:
    rc, raw = run_nelly("stats", json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b('Live stats')}\n{i_('(no running containers)')}", kbd([("« Menu", "start")])
    blocks = []
    for s in items:
        cpu  = s.get("CPUPerc", "?")
        memp = s.get("MemPerc", "?")
        memu = trunc(s.get("MemUsage", "?"), 28)
        pids = s.get("PIDs", "?")
        blocks.append(
            f"{b(trunc(s.get('Name', '?'), 22))}\n"
            f"{code(f'cpu {cpu}  ·  mem {memp}')}\n"
            f"{code(f'{memu}  ·  pids {pids}')}"
        )
    return b("Live stats") + "\n\n" + "\n\n".join(blocks), kbd(
        [("« Menu", "start"), ("Refresh", "stats")],
    )

# ---------------------------------------------------------------------------
# /status
# ---------------------------------------------------------------------------

def _one_name(args):
    if not args: return None, "needs a deployment name"
    n = safe_name(args[0])
    if not n: return None, f"invalid name: {esc(args[0])!r}"
    return n, None

def cmd_status(args, allow_writes, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("status", n, json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        d = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)

    state = d.get("state", "?")
    out = [f"{state_dot(state)} {b(n)}  {esc(state)}", ""]

    summary_pairs = [
        ("container", d.get("container", n)),
        ("started",   fmt_ts(d.get("started", ""))),
        ("image",     short_image(d.get("image", ""))),
    ]
    health = d.get("health", "")
    if health and health not in ("none", "n/a"):
        summary_pairs.append(("health", health))
    out.append(pre(kv(summary_pairs)))

    scheds = d.get("schedules") or []
    if scheds:
        app_cards = []
        for s in scheds:
            sched = s.get("schedule") or "(unscheduled)"
            ep    = s.get("entrypoint") or "-"
            app_cards.append(card(
                trunc(s.get("app", "?"), 22),
                [("schedule",   sched),
                 ("entrypoint", ep)],
            ))
        out += ["", section("Apps", "\n\n".join(app_cards))]

    pinned = d.get("pinned") or {}
    if pinned:
        lines = []
        kw = max(len(k) for k in pinned)
        for k, v in pinned.items():
            lines.append(f"{k:<{kw}}  {trunc(str(v), 22)}")
        out += ["", section("Pinned revisions", "\n".join(lines))]

    return "\n".join(out), kbd(*kbd_for_deployment(n, allow_writes))

# ---------------------------------------------------------------------------
# /cron, /metrics
# ---------------------------------------------------------------------------

def cmd_cron(args, _aw, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("cron", n, json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b(f'{n} - schedules')}\n{pre('(no apps)')}", kbd(
            [("Status", f"s|{n}"), ("« Menu", "start")],
        )

    cards = []
    for it in items:
        sched = it.get("schedule")   or "(unscheduled)"
        ep    = it.get("entrypoint") or "-"
        desc  = it.get("description") or ""
        pairs = [
            ("schedule",   sched),
            ("when",       desc),
            ("entrypoint", ep),
        ]
        for nxt in (it.get("next_runs") or [])[:3]:
            pairs.append(("next", nxt))
        cards.append(card(trunc(it.get("app", "?"), 22), pairs))
    return section(f"{n} - schedules", "\n\n".join(cards)), kbd(
        [("Status", f"s|{n}"), ("Metrics", f"m|{n}")],
        [("Refresh", f"c|{n}"), ("« Menu", "start")],
    )

def cmd_metrics(args, _aw, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    extra = []
    label = ""
    if len(args) >= 2:
        if re.match(r"^\d+[smhd]$", args[1]):
            extra = ["--since", args[1]]; label = f"  (last {args[1]})"
        else:
            app = safe_name(args[1])
            if not app: return f"invalid app/since arg: {esc(args[1])!r}"
            extra = ["--app", app]; label = f"  ({app})"
    rc, raw = run_nelly("metrics", n, *extra, json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b(f'{n} - metrics{label}')}\n{pre('(no runs yet)')}", kbd(
            [("Status", f"s|{n}"), ("Cron", f"c|{n}")],
            [("« Menu", "start")],
        )

    cards = []
    for s in items:
        runs = s.get("runs", 0)
        ok   = s.get("success", 0)
        fl   = s.get("failed", 0)
        status = "🟢" if fl == 0 else ("🟡" if ok > fl else "🔴")
        title = f"{status} {trunc(s.get('app', '?'), 20)}"
        line_counts = f"runs:{runs:>3}   ok:{ok:>3}   fail:{fl:>3}"
        avg = s.get("avg_dur_s", 0)
        p95 = s.get("p95_dur_s", 0) or 0
        line_dur    = f"avg: {avg:>3}s   p95: {p95:>3}s"
        last_ts = fmt_ts(s.get("last_ts", "") or "")
        last_rc = s.get("last_rc", "?")
        line_last   = f"last: {last_ts}  rc={last_rc}"
        body = "\n".join([title, "  " + line_counts, "  " + line_dur, "  " + line_last])
        cards.append(body)
    return section(f"{n} - metrics{label}", "\n\n".join(cards)), kbd(
        [("Status", f"s|{n}"), ("24h", f"m|{n}|24h")],
        [("Refresh", f"m|{n}"), ("« Menu", "start")],
    )

# ---------------------------------------------------------------------------
# /releases, /release
# ---------------------------------------------------------------------------

def cmd_releases(args, allow_writes, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("release", "list", n, json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b(f'{n} - releases')}\n{pre('(no releases yet)')}", kbd(
            [("Status", f"s|{n}"), ("« Menu", "start")],
        )
    recent = list(reversed(items))[:10]
    rows = [
        [r.get("release_id", "?"),
         fmt_ts(r.get("finalized_at") or r.get("created_at", "")),
         r.get("outcome", "?")]
        for r in recent
    ]
    body = narrow_table(rows, headers=["ID", "WHEN", "OUTCOME"])
    text = section(f"{n} - releases", body)
    if len(items) > 10:
        text += "\n" + i_(f"(showing 10 of {len(items)})")

    # Button per release (up to 6, rows of 2).
    kbd_rows = []
    row = []
    for r in recent[:6]:
        rid = r.get("release_id", "")
        if not rid: continue
        row.append((rid, f"r|{n}|{rid}"))
        if len(row) == 2:
            kbd_rows.append(row); row = []
    if row: kbd_rows.append(row)
    kbd_rows.append([("Status", f"s|{n}"), ("Refresh", f"rs|{n}")])
    kbd_rows.append([("« Menu", "start")])
    return text, kbd(*kbd_rows)

def cmd_release(args, allow_writes, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    rel_arg = args[1] if len(args) >= 2 else None
    if rel_arg and not REL_ID_RE.match(rel_arg):
        return f"invalid release id: {esc(rel_arg)!r}"
    cmd_args = ["release", "show", n] + ([rel_arg] if rel_arg else [])
    rc, raw = run_nelly(*cmd_args, json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        m = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    rel_id  = m.get("release_id", "?")
    outcome = m.get("outcome", "?")
    pairs = [
        ("created",   fmt_ts(m.get("created_at", ""))),
        ("finalized", fmt_ts(m.get("finalized_at", ""))),
        ("duration",  f"{m['duration_seconds']}s" if m.get("duration_seconds") is not None else None),
        ("image",     short_image(m.get("image", "") or "")),
        ("actor",     trunc(m.get("actor", ""), 26)),
        ("health",    m.get("health_status", "")),
        ("wait",      f"{m['wait_healthy_seconds']}s" if m.get("wait_healthy_seconds") is not None else None),
        ("previous",  m.get("previous_release_id", "")),
        ("rollback",  m.get("rollback_of", "")),
        ("rolled_back", "yes" if m.get("auto_rollback_triggered") else None),
    ]
    out = [
        b(f"{n} - {rel_id}  ({outcome})"),
        "",
        pre(kv(pairs)),
    ]
    note = m.get("note") or ""
    if note:
        wrapped = "\n".join(textwrap.wrap(note, width=MOBILE_WIDTH)) or note
        out += ["", section("Note", wrapped)]

    rows = [[("All releases", f"rs|{n}"), ("Status", f"s|{n}")]]
    if allow_writes:
        rows.append([("Restore this", f"cf|rr|{n}|{rel_id}")])
    rows.append([("« Menu", "start")])
    return "\n".join(out), kbd(*rows)

# ---------------------------------------------------------------------------
# /doctor, /explain, /events, /logs
# ---------------------------------------------------------------------------

def cmd_doctor(args, _aw, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("doctor", n)
    clean = re.sub(r"\x1b\[[0-9;]*m", "", raw or "")
    clean = clean.replace("  ✓ ", "  🟢 ")
    clean = clean.replace("  ! ", "  🟡 ")
    clean = clean.replace("  ✗ ", "  🔴 ")
    return (
        f"{b(f'{n} - pre-flight check')}\n{pre(clean.rstrip() or '(no output)')}",
        kbd([("Status", f"s|{n}"), ("Refresh", f"d|{n}")],
            [("« Menu", "start")]),
    )

def cmd_explain(args, _aw, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("explain", n)
    clean = re.sub(r"\x1b\[[0-9;]*m", "", raw or "").rstrip()
    if rc != 0: return fmt_err(rc, clean)
    return (
        f"{b(f'{n} - summary')}\n{pre(clean or '(no output)')}",
        kbd([("Status", f"s|{n}"), ("« Menu", "start")]),
    )

def cmd_events(args, _aw, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    container = subprocess.run(
        [str(NELLY_BIN), "get", n, ".container_name"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10, check=False
    ).stdout.decode().strip()
    if not container:
        return f"no container known for {esc(n)}"
    try:
        out = subprocess.check_output(
            ["docker", "events", "--since", "1h", "--until", "0s",
             "--filter", f"container={container}",
             "--format", "{{.TimeNano}}|{{.Action}}"],
            timeout=15
        ).decode("utf-8", errors="replace")
    except Exception as e:
        return f"docker events failed: {esc(e)}"
    lines = []
    for raw_line in out.splitlines():
        if "|" not in raw_line: continue
        ts_ns, action = raw_line.split("|", 1)
        try:
            t = datetime.datetime.utcfromtimestamp(int(ts_ns) / 1e9).strftime("%H:%M:%S")
        except Exception:
            t = "??:??:??"
        lines.append(f"{t}  {trunc(action, 26)}")
    body = "\n".join(lines) or "(no events)"
    return (
        f"{b(f'{n} - events (last hr)')}\n{pre(body)}",
        kbd([("Status", f"s|{n}"), ("« Menu", "start")]),
    )

def cmd_logs(args, _aw, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    log_path = NELLY_ROOT / "containers" / n / "logs" / "cron"
    if len(args) >= 2:
        app = safe_name(args[1])
        if not app: return f"invalid app name: {esc(args[1])!r}"
        f = log_path / f"{app}.log"
        if not f.is_file():
            return f"no log at {code(f.relative_to(NELLY_ROOT))}"
        try:
            tail = subprocess.check_output(["tail", "-n", "20", str(f)], timeout=5).decode("utf-8", errors="replace")
        except Exception as e:
            return f"failed to tail log: {esc(e)}"
        return (
            f"{b(f'{n} / {app}')}\n{pre(tail.rstrip() or '(empty)')}",
            kbd([("Status", f"s|{n}"), ("Refresh", f"lg|{n}|{app}")],
                [("« Menu", "start")]),
        )

    if not log_path.is_dir():
        return f"no logs yet for {esc(n)}"
    chunks = []
    for f in sorted(log_path.glob("*.log")):
        try:
            tail = subprocess.check_output(["tail", "-n", "8", str(f)], timeout=5).decode("utf-8", errors="replace")
        except Exception:
            continue
        if not tail.strip():
            continue
        chunks.append(section(f.stem, tail.rstrip()))
    if not chunks:
        return f"no log lines yet for {esc(n)}"
    return (
        f"{b(n)}\n\n" + "\n\n".join(chunks),
        kbd([("Status", f"s|{n}"), ("Refresh", f"lg|{n}")],
            [("« Menu", "start")]),
    )

# ---------------------------------------------------------------------------
# write commands
# ---------------------------------------------------------------------------

def cmd_start_dep(args, _aw, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("start", n)
    if rc == 0:
        return f"{b(n)} started", kbd([("Status", f"s|{n}")])
    return fmt_err(rc, raw)

def cmd_stop_dep(args, _aw, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("stop", n)
    if rc == 0:
        return f"{b(n)} stopped", kbd([("Start", f"sa|{n}"), ("Status", f"s|{n}")])
    return fmt_err(rc, raw)

def cmd_restart_dep(args, _aw, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("restart", n)
    if rc == 0:
        return f"{b(n)} restarted", kbd([("Status", f"s|{n}")])
    return fmt_err(rc, raw)

def cmd_runnow(args, _aw, **_) -> Response:
    if len(args) < 2:
        return "usage: /runnow &lt;name&gt; &lt;app&gt;"
    n = safe_name(args[0])
    a = safe_name(args[1])
    if not n or not a: return "invalid name(s)"
    rc, raw = run_nelly("run-now", n, a)
    tail = (raw or "(no output)").rstrip()[-1500:]
    if rc == 0:
        return (
            f"{b(f'{n} / {a}')}  ran\n{pre(tail)}",
            kbd([("Logs", f"lg|{n}|{a}"), ("Status", f"s|{n}")]),
        )
    return fmt_err(rc, raw)

def cmd_deploy(args, allow_writes, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("deploy", n, "--wait-healthy", "60", "--auto-rollback")
    tail = "\n".join((raw or "").splitlines()[-15:]).rstrip() or "(no output)"
    label = f"{n}  deploy {'OK' if rc == 0 else 'FAILED (exit ' + str(rc) + ')'}"
    rows = [[("Status", f"s|{n}"), ("Releases", f"rs|{n}")]]
    if rc != 0 and allow_writes:
        rows.append([("Logs", f"lg|{n}"), ("Doctor", f"d|{n}")])
    return f"{b(label)}\n{pre(tail)}", kbd(*rows)

def cmd_rollback(args, _aw, **_) -> Response:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("rollback", n)
    tail = (raw or "").rstrip()[-1500:] or "(no output)"
    if rc == 0:
        return (
            f"{b(n)} rolled back\n{pre(tail)}",
            kbd([("Status", f"s|{n}"), ("Releases", f"rs|{n}")]),
        )
    return fmt_err(rc, raw)

def cmd_update_check(_args, allow_writes, **_) -> Response:
    """Preview pending upstream commits (the polling timer's question, asked
    on demand). Read-only — we only do `git fetch` + log inspection. If
    writes are enabled, surface an Update button that routes through the
    standard two-tap confirm guard."""
    rc, raw = run_nelly("check-updates", "check")
    body = (raw or "").rstrip() or "(no output)"
    if rc == 0:
        return f"{b('up to date')}\n{pre(body[-1500:])}", kbd([("« Menu", "start")])
    if rc == 1:
        rows = []
        if allow_writes:
            rows.append([("Update now", "cf|up")])
        rows.append([("« Menu", "start"), ("Re-check", "uc")])
        return f"{b('updates available')}\n{pre(body[-1500:])}", kbd(*rows)
    return f"{b('check failed')}  exit {rc}\n{pre(body[-1500:])}"

def cmd_update(_args, _aw, **_) -> Response:
    """Apply the pending update via `nelly update`. The pipeline already
    fetches, smoke-tests, redeploys what needs redeploying, and aborts
    cleanly on a smoke failure — we just wrap its tail in HTML and surface
    a Status button when it succeeds."""
    rc, raw = run_nelly("update")
    tail = "\n".join((raw or "").splitlines()[-20:]).rstrip() or "(no output)"
    if rc == 0:
        return (
            f"{b('update OK')}\n{pre(tail)}",
            kbd([("« Menu", "start"), ("Deployments", "ls")]),
        )
    return fmt_err(rc, raw)

def cmd_release_restore(args, _aw, **_) -> Response:
    if len(args) < 2:
        return "usage: /release_restore &lt;name&gt; &lt;rel_id&gt;"
    n = safe_name(args[0])
    if not n: return f"invalid name: {esc(args[0])!r}"
    if not REL_ID_RE.match(args[1]):
        return f"invalid release id: {esc(args[1])!r}"
    rc, raw = run_nelly("release", "restore", n, args[1])
    tail = "\n".join((raw or "").splitlines()[-10:]).rstrip() or "(no output)"
    if rc == 0:
        return (
            f"{b(n)} restored to {code(args[1])}\n{pre(tail)}",
            kbd([("Status", f"s|{n}"), ("Releases", f"rs|{n}")]),
        )
    return fmt_err(rc, raw)

# ---------------------------------------------------------------------------
# confirmation guard for destructive button taps
# ---------------------------------------------------------------------------

# Opcodes that must not fire on a single tap. The keyboard offers
# "cf|<op>|<args>"; cmd_confirm renders a Yes/Cancel prompt whose Yes button
# carries the real "<op>|<args>" callback. Typed write commands are
# deliberate and skip this — only button taps are guarded.
CONFIRM_VERB: dict[str, str] = {
    "re": "restart",
    "st": "stop",
    "dp": "deploy",
    "rr": "restore",
    "up": "update",
}

def cmd_confirm(args, _aw, **_) -> Response:
    if not args:
        return b("nothing to confirm")
    op, op_args = args[0], args[1:]
    verb = CONFIRM_VERB.get(op)
    if not verb:
        return b("unknown action")
    name = op_args[0] if op_args else "?"
    detail = f"{verb}  {name}"
    if op == "rr" and len(op_args) >= 2:
        detail += f"\nto  {op_args[1]}"
    yes_data    = "|".join([op, *op_args])
    cancel_data = f"s|{name}" if safe_name(name) else "start"
    out = [b("Confirm"), "", pre(detail)]
    return "\n".join(out), kbd(
        [("Cancel", cancel_data), (f"Yes, {verb}", yes_data)],
    )

# ---------------------------------------------------------------------------
# command table
# ---------------------------------------------------------------------------

# Two indexes: long names (typed in chat) and short opcodes (callback_data).
# Same handler under each — the table is the only allow-list for both paths.

COMMANDS: dict[str, tuple[Callable, bool]] = {
    "help":        (cmd_help,    False),
    "start":       (cmd_start,   False),  # /start is dashboard, not help
    "confirm":     (cmd_confirm, False),  # two-tap guard; only reached via cf| buttons
    "id":          (cmd_id,      False),
    "list":        (cmd_list,    False),
    "ls":          (cmd_list,    False),
    "ps":          (cmd_ps,      False),
    "stats":       (cmd_stats,   False),
    "status":      (cmd_status,  False),
    "logs":        (cmd_logs,    False),
    "cron":        (cmd_cron,    False),
    "explain":     (cmd_explain, False),
    "doctor":      (cmd_doctor,  False),
    "events":      (cmd_events,  False),
    "releases":    (cmd_releases,False),
    "release":     (cmd_release, False),
    "metrics":     (cmd_metrics, False),
    "start_dep":      (cmd_start_dep,      True),
    "stop_dep":       (cmd_stop_dep,       True),
    "restart_dep":    (cmd_restart_dep,    True),
    "runnow":         (cmd_runnow,         True),
    "deploy":         (cmd_deploy,         True),
    "rollback":       (cmd_rollback,       True),
    "release_restore":(cmd_release_restore,True),
    "update_check":   (cmd_update_check,   False),
    "update":         (cmd_update,         True),
}

# Short opcodes used in callback_data (so the 64-byte budget isn't blown).
CB_ALIASES: dict[str, str] = {
    "cf": "confirm",
    "s":  "status",
    "ls": "list",
    "lg": "logs",
    "m":  "metrics",
    "c":  "cron",
    "rs": "releases",
    "r":  "release",
    "d":  "doctor",
    "e":  "explain",
    "ev": "events",
    "re": "restart_dep",
    "st": "stop_dep",
    "sa": "start_dep",
    "dp": "deploy",
    "rb": "rollback",
    "rr": "release_restore",
    "rn": "runnow",
    "uc": "update_check",
    "up": "update",
}

def resolve_cmd(token_str: str) -> str:
    return CB_ALIASES.get(token_str, token_str)

# ---------------------------------------------------------------------------
# rate limiting
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

def _dispatch(cfg: dict, cmd_raw: str, args: list[str], user_id: int) -> str | None:
    """Returns the rendered reply, or None if the caller should be silenced."""
    cmd_name = resolve_cmd(cmd_raw)
    entry = COMMANDS.get(cmd_name)
    if not entry:
        return f"unknown command: {code('/' + cmd_raw)}  try {code('/help')}"
    handler, needs_writes = entry
    if needs_writes and not cfg.get("allow_writes", False):
        return f"{b('writes disabled')}  set {code('allow_writes: true')} in {code('bot/config.json')}"
    try:
        resp = handler(args, cfg.get("allow_writes", False), user_id=user_id)
    except Exception as e:
        log.exception("handler crashed: %s", e)
        resp = f"{b('internal error')}\n{pre(str(e))}"
    return resp

def handle_message(token: str, cfg: dict, msg: dict) -> None:
    user    = msg.get("from") or {}
    user_id = user.get("id")
    chat_id = (msg.get("chat") or {}).get("id")
    text    = msg.get("text") or ""

    if user_id not in cfg["allowed_users"]:
        log.warning("DENIED user=%s username=%s text=%r",
                    user_id, user.get("username"), text[:120])
        return
    if rate_limited(user_id):
        send_message(token, chat_id, f"{b('rate limit')}  please slow down")
        return

    parts = text.strip().split()
    if not parts or not parts[0].startswith("/"):
        return
    cmd_raw = parts[0][1:].lower().split("@", 1)[0]
    args = parts[1:]
    log.info("MSG user=%s cmd=%s args=%s", user_id, cmd_raw, args)

    resp = _dispatch(cfg, cmd_raw, args, user_id)
    if not resp: return
    text_out, keyboard = _split_resp(resp)
    send_message(token, chat_id, text_out, keyboard=keyboard)

def handle_callback(token: str, cfg: dict, cb: dict) -> None:
    cb_id    = cb.get("id", "")
    data     = cb.get("data", "") or ""
    user     = cb.get("from") or {}
    user_id  = user.get("id")
    msg      = cb.get("message") or {}
    chat_id  = (msg.get("chat") or {}).get("id")

    if user_id not in cfg["allowed_users"]:
        log.warning("DENIED-CB user=%s username=%s data=%r",
                    user_id, user.get("username"), data[:120])
        answer_callback(token, cb_id, "not authorized")
        return
    if rate_limited(user_id):
        answer_callback(token, cb_id, "rate limit")
        return

    # Always acknowledge to dismiss the loading spinner.
    answer_callback(token, cb_id)

    parts = data.split("|")
    cmd_raw = parts[0]
    args = parts[1:]
    log.info("CB user=%s cmd=%s args=%s", user_id, cmd_raw, args)

    resp = _dispatch(cfg, cmd_raw, args, user_id)
    if not resp: return
    text_out, keyboard = _split_resp(resp)
    send_message(token, chat_id, text_out, keyboard=keyboard)

def handle_update(token: str, cfg: dict, update: dict) -> None:
    if "callback_query" in update:
        handle_callback(token, cfg, update["callback_query"])
        return
    msg = update.get("message") or update.get("edited_message")
    if msg:
        handle_message(token, cfg, msg)

def main() -> None:
    cfg = load_config()
    token = load_token()
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
            cfg = try_reload_config(cfg)
            resp = tg(token, "getUpdates",
                      offset=offset, timeout=POLL_TIMEOUT,
                      allowed_updates=json.dumps(["message", "callback_query"]))
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
