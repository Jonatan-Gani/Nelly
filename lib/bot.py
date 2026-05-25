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
    typical phone widths. Wider data is reformatted as vertical cards
    (title line + indented key:value pairs) instead of horizontal
    tables.
  - No emoji. Status is conveyed with plain words ("running", "failed")
    and text markers like [OK] / [WARN] / [FAIL].

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
- Responses are sent with parse_mode=HTML; all user-controlled content
  is HTML-escaped via html.escape().
- Responses are truncated to 3800 chars (Telegram limit is 4096).

Python stdlib only — no pip install.
"""

from __future__ import annotations

import html
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
from typing import Any, Callable, Iterable

NELLY_ROOT = Path(os.environ["NELLY_ROOT"]).resolve()
BOT_DIR    = NELLY_ROOT / "bot"
TOKEN_PATH = BOT_DIR / ".token"
CONFIG_PATH = BOT_DIR / "config.json"
LOG_PATH   = BOT_DIR / "bot.log"
NELLY_BIN  = NELLY_ROOT / "bin" / "nelly"

API_BASE     = "https://api.telegram.org"
POLL_TIMEOUT = 30
RESP_TRUNCATE = 3800
NELLY_CMD_TIMEOUT = 60
RATE_LIMIT_WINDOW = 60
RATE_LIMIT_MAX    = 30

# Target maximum line length inside <pre> blocks. ~38 fits comfortably on a
# portrait phone in Telegram's monospace font.
MOBILE_WIDTH = 38

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

# ---------------------------------------------------------------------------
# Telegram HTTP
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
        tg(token, "sendMessage", chat_id=chat_id, text=text,
           parse_mode="HTML", disable_web_page_preview="true")
    except Exception as e:
        log.warning("sendMessage failed (chat_id=%s): %s", chat_id, e)
        try:
            tg(token, "sendMessage", chat_id=chat_id,
               text=re.sub(r"<[^>]+>", "", text),
               disable_web_page_preview="true")
        except Exception:
            pass

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
# value compactors — keep every cell inside MOBILE_WIDTH
# ---------------------------------------------------------------------------

def short_image(img: str) -> str:
    """`hello:f453b0b880ef` -> `hello:f453b0b8`. Digest form collapses to
    `image@...`. Always returns at most ~22 chars."""
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
    """ISO timestamp -> 'YYYY-MM-DD HH:MM' (16 chars). Blank ts -> '-'."""
    if not ts: return "-"
    m = re.match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})", ts)
    return f"{m.group(1)} {m.group(2)}" if m else ts

def trunc(s: str, n: int) -> str:
    """Trim to at most n chars; suffix `...` if anything was cut."""
    if s is None: return ""
    s = str(s)
    return s if len(s) <= n else s[: max(0, n - 3)] + "..."

# ---------------------------------------------------------------------------
# layout primitives
# ---------------------------------------------------------------------------

def card(title: str, pairs: Iterable[tuple[str, Any]]) -> str:
    """One vertical card. Returns plain text (caller wraps in <pre>).

        title
          key1:   value1
          key2:   value2

    Empty / None / 'n/a' values are dropped. Keys are padded so all
    colons line up.
    """
    valid = [(str(k), str(v)) for k, v in pairs
             if v not in (None, "", "n/a")]
    out = [title]
    if valid:
        kw = max(len(k) for k, _ in valid)
        for k, v in valid:
            out.append(f"  {k+':':<{kw+2}}{v}")
    return "\n".join(out)

def kv(pairs: Iterable[tuple[str, Any]], *, key_width: int | None = None) -> str:
    """Aligned `key : value` lines (no title)."""
    valid = [(str(k), str(v)) for k, v in pairs
             if v not in (None, "", "n/a")]
    if not valid: return ""
    width = key_width or max(len(k) for k, _ in valid)
    return "\n".join(f"{k:<{width}} : {v}" for k, v in valid)

def narrow_table(rows: list[list[str]], headers: list[str] | None = None,
                 gutter: str = "  ") -> str:
    """Aligned table for cases where the data fits in MOBILE_WIDTH."""
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
    """Bold header outside <pre>, body inside <pre>. Hidden if body empty."""
    if not body:
        return ""
    return f"{b(title)}\n{pre(body)}"

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

# ---------------------------------------------------------------------------
# command handlers
# ---------------------------------------------------------------------------

# ---- /help, /id ------------------------------------------------------------

HELP_READ = """\
/list             deployments
/status   <n>     one deployment
/ps               containers
/stats            cpu/mem/pids
/logs     <n>     last cron output
/cron     <n>     schedules
/explain  <n>     summary
/doctor   <n>     pre-flight check
/events   <n>     docker events
/releases <n>     deploy history
/release  <n>     release manifest
/metrics  <n>     run stats
/id               your user id"""

HELP_WRITE = """\
/start_dep        <n>
/stop_dep         <n>
/restart_dep      <n>
/runnow           <n> <app>
/deploy           <n>
/rollback         <n>
/release_restore  <n> <id>"""

def cmd_help(_args, allow_writes, **_) -> str:
    parts = [b("Nelly bot"), "", section("Read-only", HELP_READ)]
    if allow_writes:
        parts += ["", section("Write", HELP_WRITE)]
    return "\n".join(p for p in parts if p)

def cmd_id(_args, _aw, *, user_id: int = 0, **_) -> str:
    return f"{b('Your Telegram user id')}\n{pre(str(user_id))}"

# ---- /list, /ps, /stats — vertical cards ----------------------------------

def cmd_list(_args, _aw, **_) -> str:
    rc, raw = run_nelly("list", json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b('Deployments')}\n{pre('(none)')}"
    cards = []
    for d in items:
        name  = trunc(d.get("deployment", "?"), 22)
        state = d.get("state", "?")
        cards.append(card(
            f"{name}  ({state})",
            [("apps",  d.get("apps", 0)),
             ("image", short_image(d.get("image", "")))],
        ))
    return section("Deployments", "\n\n".join(cards))

def cmd_ps(_args, _aw, **_) -> str:
    rc, raw = run_nelly("ps", json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b('Containers')}\n{pre('(none running)')}"
    cards = []
    for c in items:
        labels = c.get("Labels", "")
        deployment = next(
            (kv_str.split("=", 1)[1] for kv_str in labels.split(",")
             if kv_str.startswith("nelly.deployment=")),
            c.get("Names", "?"),
        )
        # Status looks like "Up 2 hours (healthy)" — trim if needed.
        status = trunc(c.get("Status", ""), 30)
        cards.append(card(
            trunc(deployment, 22),
            [("status", status),
             ("image",  short_image(c.get("Image", "")))],
        ))
    return section("Containers", "\n\n".join(cards))

def cmd_stats(_args, _aw, **_) -> str:
    rc, raw = run_nelly("stats", json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b('Live stats')}\n{pre('(no running containers)')}"
    cards = []
    for s in items:
        cards.append(card(
            trunc(s.get("Name", "?"), 22),
            [("cpu",  s.get("CPUPerc", "?")),
             ("mem",  s.get("MemPerc", "?")),
             ("size", trunc(s.get("MemUsage", "?"), 30)),
             ("pids", s.get("PIDs", "?"))],
        ))
    return section("Live stats", "\n\n".join(cards))

# ---- /status ---------------------------------------------------------------

def _one_name(args):
    if not args: return None, "needs a deployment name"
    n = safe_name(args[0])
    if not n: return None, f"invalid name: {esc(args[0])!r}"
    return n, None

def cmd_status(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("status", n, json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        d = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)

    out = [b(f"{n}  ({d.get('state','?')})"), ""]

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
        # Cards per app — schedule + entrypoint are often too wide combined
        # for a table at ~38 chars, so vertical layout wins.
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

    return "\n".join(out)

# ---- /cron, /metrics — vertical cards per app -----------------------------

def cmd_cron(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("cron", n, json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b(f'{n} - schedules')}\n{pre('(no apps)')}"

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
    return section(f"{n} - schedules", "\n\n".join(cards))

def cmd_metrics(args, _aw, **_) -> str:
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
        return f"{b(f'{n} - metrics{label}')}\n{pre('(no runs yet)')}"

    cards = []
    for s in items:
        runs = s.get("runs", 0)
        ok   = s.get("success", 0)
        fl   = s.get("failed", 0)
        status = "[OK]" if fl == 0 else ("[WARN]" if ok > fl else "[FAIL]")
        title = f"{trunc(s.get('app', '?'), 20)}  {status}"
        # Compact two-up rows inside the card.
        line_counts = f"runs:{runs:>3}   ok:{ok:>3}   fail:{fl:>3}"
        avg = s.get("avg_dur_s", 0)
        p95 = s.get("p95_dur_s", 0) or 0
        line_dur    = f"avg: {avg:>3}s   p95: {p95:>3}s"
        last_ts = fmt_ts(s.get("last_ts", "") or "")
        last_rc = s.get("last_rc", "?")
        line_last   = f"last: {last_ts}  rc={last_rc}"
        body = "\n".join([title, "  " + line_counts, "  " + line_dur, "  " + line_last])
        cards.append(body)
    return section(f"{n} - metrics{label}", "\n\n".join(cards))

# ---- /releases — narrow table (rows are short) ----------------------------

def cmd_releases(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("release", "list", n, json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b(f'{n} - releases')}\n{pre('(no releases yet)')}"
    recent = list(reversed(items))[:10]
    rows = [
        [r.get("release_id", "?"),
         fmt_ts(r.get("finalized_at") or r.get("created_at", "")),
         r.get("outcome", "?")]
        for r in recent
    ]
    body = narrow_table(rows, headers=["ID", "WHEN", "OUTCOME"])
    out = [section(f"{n} - releases", body)]
    if len(items) > 10:
        out.append(i_(f"(showing 10 of {len(items)} - /release <id> for one)"))
    return "\n".join(out)

# ---- /release — single card ------------------------------------------------

def cmd_release(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    if len(args) >= 2:
        if not REL_ID_RE.match(args[1]):
            return f"invalid release id: {esc(args[1])!r}"
        rc, raw = run_nelly("release", "show", n, args[1], json_output=True)
    else:
        rc, raw = run_nelly("release", "show", n, json_output=True)
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
        # Wrap note text to MOBILE_WIDTH so long notes don't blow the column.
        import textwrap
        wrapped = "\n".join(textwrap.wrap(note, width=MOBILE_WIDTH)) or note
        out += ["", section("Note", wrapped)]
    return "\n".join(out)

# ---- /doctor, /explain, /events, /logs ------------------------------------

def cmd_doctor(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("doctor", n)
    clean = re.sub(r"\x1b\[[0-9;]*m", "", raw or "")
    clean = clean.replace("  ✓ ", "  [OK]   ")
    clean = clean.replace("  ! ", "  [WARN] ")
    clean = clean.replace("  ✗ ", "  [FAIL] ")
    return f"{b(f'{n} - pre-flight check')}\n{pre(clean.rstrip() or '(no output)')}"

def cmd_explain(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("explain", n)
    clean = re.sub(r"\x1b\[[0-9;]*m", "", raw or "").rstrip()
    if rc != 0: return fmt_err(rc, clean)
    return f"{b(f'{n} - summary')}\n{pre(clean or '(no output)')}"

def cmd_events(args, _aw, **_) -> str:
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
             # Compact format: "HH:MM:SS  action"
             "--format", "{{.TimeNano}}|{{.Action}}"],
            timeout=15
        ).decode("utf-8", errors="replace")
    except Exception as e:
        return f"docker events failed: {esc(e)}"
    # Reformat nano timestamps to HH:MM and trim actions to 20 chars
    lines = []
    for raw_line in out.splitlines():
        if "|" not in raw_line: continue
        ts_ns, action = raw_line.split("|", 1)
        try:
            import datetime
            t = datetime.datetime.utcfromtimestamp(int(ts_ns) / 1e9).strftime("%H:%M:%S")
        except Exception:
            t = "??:??:??"
        lines.append(f"{t}  {trunc(action, 26)}")
    body = "\n".join(lines) or "(no events)"
    return f"{b(f'{n} - events (last hr)')}\n{pre(body)}"

def cmd_logs(args, _aw, **_) -> str:
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
        return f"{b(f'{n} / {app}')}\n{pre(tail.rstrip() or '(empty)')}"

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
    return f"{b(n)}\n\n" + "\n\n".join(chunks)

# ---- write commands -------------------------------------------------------

def cmd_start_dep(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("start", n)
    return f"{b(n)} started" if rc == 0 else fmt_err(rc, raw)

def cmd_stop_dep(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("stop", n)
    return f"{b(n)} stopped" if rc == 0 else fmt_err(rc, raw)

def cmd_restart_dep(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("restart", n)
    return f"{b(n)} restarted" if rc == 0 else fmt_err(rc, raw)

def cmd_runnow(args, _aw, **_) -> str:
    if len(args) < 2:
        return "usage: /runnow &lt;name&gt; &lt;app&gt;"
    n = safe_name(args[0])
    a = safe_name(args[1])
    if not n or not a: return "invalid name(s)"
    rc, raw = run_nelly("run-now", n, a)
    tail = (raw or "(no output)").rstrip()[-1500:]
    if rc == 0:
        return f"{b(f'{n} / {a}')}  ran\n{pre(tail)}"
    return fmt_err(rc, raw)

def cmd_deploy(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("deploy", n, "--wait-healthy", "60", "--auto-rollback")
    tail = "\n".join((raw or "").splitlines()[-15:]).rstrip() or "(no output)"
    label = f"{n}  deploy {'OK' if rc == 0 else 'FAILED (exit ' + str(rc) + ')'}"
    return f"{b(label)}\n{pre(tail)}"

def cmd_rollback(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("rollback", n)
    tail = (raw or "").rstrip()[-1500:] or "(no output)"
    if rc == 0:
        return f"{b(n)} rolled back\n{pre(tail)}"
    return fmt_err(rc, raw)

def cmd_release_restore(args, _aw, **_) -> str:
    if len(args) < 2:
        return "usage: /release_restore &lt;name&gt; &lt;rel_id&gt;"
    n = safe_name(args[0])
    if not n: return f"invalid name: {esc(args[0])!r}"
    if not REL_ID_RE.match(args[1]):
        return f"invalid release id: {esc(args[1])!r}"
    rc, raw = run_nelly("release", "restore", n, args[1])
    tail = "\n".join((raw or "").splitlines()[-10:]).rstrip() or "(no output)"
    if rc == 0:
        return f"{b(n)} restored to {code(args[1])}\n{pre(tail)}"
    return fmt_err(rc, raw)

# ---- command table --------------------------------------------------------

COMMANDS: dict[str, tuple[Callable, bool]] = {
    "help":        (cmd_help, False),
    "start":       (cmd_help, False),
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
    "start_dep":      (cmd_start_dep,    True),
    "stop_dep":       (cmd_stop_dep,     True),
    "restart_dep":    (cmd_restart_dep,  True),
    "runnow":         (cmd_runnow,       True),
    "deploy":         (cmd_deploy,       True),
    "rollback":       (cmd_rollback,     True),
    "release_restore":(cmd_release_restore, True),
}

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

def handle_update(token: str, cfg: dict, update: dict) -> None:
    msg = update.get("message") or update.get("edited_message")
    if not msg:
        return
    user = msg.get("from") or {}
    user_id = user.get("id")
    chat_id = (msg.get("chat") or {}).get("id")
    text    = msg.get("text") or ""

    if user_id not in cfg["allowed_users"]:
        log.warning("DENIED user=%s username=%s text=%r",
                    user_id, user.get("username"), text[:120])
        return

    if rate_limited(user_id):
        log.warning("RATE-LIMITED user=%s", user_id)
        send_message(token, chat_id, f"{b('rate limit')}  please slow down")
        return

    parts = text.strip().split()
    if not parts or not parts[0].startswith("/"):
        return
    cmd_raw = parts[0][1:].lower().split("@", 1)[0]
    args = parts[1:]

    handler_entry = COMMANDS.get(cmd_raw)
    if not handler_entry:
        log.info("UNKNOWN user=%s cmd=%s", user_id, cmd_raw)
        send_message(token, chat_id, f"unknown command: {code('/' + cmd_raw)}  try {code('/help')}")
        return
    handler, needs_writes = handler_entry
    if needs_writes and not cfg.get("allow_writes", False):
        log.info("WRITES-DISABLED user=%s cmd=%s", user_id, cmd_raw)
        send_message(token, chat_id,
            f"{b('writes disabled')}  set {code('allow_writes: true')} in {code('bot/config.json')}")
        return

    log.info("RUN user=%s cmd=%s args=%s", user_id, cmd_raw, args)
    try:
        reply = handler(args, cfg.get("allow_writes", False), user_id=user_id)
    except Exception as e:
        log.exception("handler crashed: %s", e)
        reply = f"{b('internal error')}\n{pre(str(e))}"

    if reply:
        send_message(token, chat_id, reply)

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
