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
- Responses are sent with parse_mode=HTML; all user-controlled content
  is HTML-escaped via html.escape().
- Responses are truncated to 3800 chars (Telegram limit is 4096).

Rendering: bold headers outside <pre>, structured content inside <pre>
so it renders in a monospace font and columns line up on every client.
No emoji — status descriptors are plain words like "running" / "failed"
or text markers like [OK] / [WARN] / [FAIL] in checklist views.

This script uses only the Python standard library — no pip install.
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
        tg(token, "sendMessage", chat_id=chat_id, text=text,
           parse_mode="HTML", disable_web_page_preview="true")
    except Exception as e:
        log.warning("sendMessage failed (chat_id=%s): %s", chat_id, e)
        # Fall back to plain text in case HTML rendering broke (e.g. on
        # bad markup); user still sees something.
        try:
            tg(token, "sendMessage", chat_id=chat_id,
               text=re.sub(r"<[^>]+>", "", text),
               disable_web_page_preview="true")
        except Exception:
            pass

# ---------------------------------------------------------------------------
# HTML formatting helpers
# ---------------------------------------------------------------------------

def esc(s: Any) -> str:
    """HTML-escape any user-controlled content."""
    return html.escape("" if s is None else str(s), quote=False)

def b(s: Any)    -> str: return f"<b>{esc(s)}</b>"
def i_(s: Any)   -> str: return f"<i>{esc(s)}</i>"
def code(s: Any) -> str: return f"<code>{esc(s)}</code>"
def pre(s: Any)  -> str: return f"<pre>{esc(s)}</pre>"

def short_image(img: str) -> str:
    """hello:f453b0b880ef → hello:f453b0b8  (fits on a phone screen)."""
    if not img or img in ("(none)", "(not built)"):
        return img or "(none)"
    if "@" in img:                # digest form: image@sha256:abc...
        return img.split("@")[0] + "@..."
    if ":" in img:
        name, tag = img.split(":", 1)
        if len(tag) > 12:
            return f"{name}:{tag[:10]}"
    return img

def fmt_ts(ts: str) -> str:
    """ISO timestamp → 'YYYY-MM-DD HH:MM' (drops seconds/TZ for compactness)."""
    if not ts: return "-"
    m = re.match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})", ts)
    return f"{m.group(1)} {m.group(2)}" if m else ts

def kv(pairs, key_width: int | None = None) -> str:
    """Render ``key : value`` lines, columns aligned. Caller wraps in pre()."""
    visible = [(str(k), str(v)) for k, v in pairs if v not in (None, "", "n/a")]
    if not visible:
        return ""
    width = key_width or max(len(k) for k, _ in visible)
    return "\n".join(f"{k:<{width}} : {v}" for k, v in visible)

def table(rows, headers=None, gutter: str = "  ") -> str:
    """Aligned table. ``rows`` is list of list-of-strings. Caller wraps in pre()."""
    str_rows = [[str(c) if c is not None else "" for c in row] for row in rows]
    if headers:
        all_rows = [list(headers)] + str_rows
    else:
        all_rows = str_rows
    if not all_rows: return ""
    n_cols = max(len(r) for r in all_rows)
    # Pad short rows to n_cols
    for r in all_rows:
        while len(r) < n_cols: r.append("")
    widths = [max(len(r[c]) for r in all_rows) for c in range(n_cols)]
    return "\n".join(gutter.join(c.ljust(w) for c, w in zip(r, widths)) for r in all_rows)

def section(title: str, content: str) -> str:
    """Bold section header + monospace body. Skips entirely if body is empty."""
    if not content:
        return ""
    return f"{b(title)}\n{pre(content)}"

# ---------------------------------------------------------------------------
# argument validation
# ---------------------------------------------------------------------------

NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")
TAG_RE  = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
REL_ID_RE = re.compile(r"^r-\d{4,}$")

def safe_name(s: str) -> str | None:
    return s if NAME_RE.match(s) else None

# ---------------------------------------------------------------------------
# `nelly` runner
# ---------------------------------------------------------------------------

def run_nelly(*args: str, json_output: bool = False) -> tuple[int, str]:
    """Run `nelly <args>` with shell=False; return (rc, combined output)."""
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
# command handlers — return HTML strings
# ---------------------------------------------------------------------------

# ---- help -----------------------------------------------------------------

HELP_READ = """\
/list                     deployments + state
/status   <n>             one deployment, full detail
/ps                       running nelly containers
/stats                    live cpu / memory / pids
/logs     <n> [app]       last cron output
/cron     <n>             what is scheduled
/explain  <n>             plain-English summary
/doctor   <n>             pre-flight check
/events   <n>             recent docker events
/releases <n>             deploy history
/release  <n> [id]        release manifest
/metrics  <n> [app|since] per-app run stats
/id                       your Telegram user id"""

HELP_WRITE = """\
/start_dep        <n>
/stop_dep         <n>
/restart_dep      <n>
/runnow           <n> <app>
/deploy           <n>
/rollback         <n>
/release_restore  <n> <id>"""

def cmd_help(_args, allow_writes, **_) -> str:
    parts = [
        b("Nelly bot"),
        "",
        section("Read-only commands", HELP_READ),
    ]
    if allow_writes:
        parts += ["", section("Write commands", HELP_WRITE)]
    return "\n".join(p for p in parts if p)

def cmd_id(_args, _aw, *, user_id: int = 0, **_) -> str:
    return f"{b('Your Telegram user id')}\n{pre(str(user_id))}"

# ---- read: list / ps / stats ----------------------------------------------

def cmd_list(_args, _aw, **_) -> str:
    rc, raw = run_nelly("list", json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b('Deployments')}\n{pre('(none)')}"
    rows = [
        [d.get("deployment", "?"),
         d.get("state", "?"),
         str(d.get("apps", 0)),
         short_image(d.get("image", ""))]
        for d in items
    ]
    return section(
        "Deployments",
        table(rows, headers=["NAME", "STATE", "APPS", "IMAGE"]),
    )

def cmd_ps(_args, _aw, **_) -> str:
    rc, raw = run_nelly("ps", json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b('Containers')}\n{pre('(none running)')}"
    rows = []
    for c in items:
        labels = c.get("Labels", "")
        deployment = next(
            (kv_str.split("=", 1)[1] for kv_str in labels.split(",")
             if kv_str.startswith("nelly.deployment=")),
            c.get("Names", "?"),
        )
        # Status looks like "Up 2 hours (healthy)" — keep it but trim if long.
        st = c.get("Status", "")
        if len(st) > 24: st = st[:23] + "…"
        rows.append([deployment, st, short_image(c.get("Image", ""))])
    return section(
        "Containers",
        table(rows, headers=["NAME", "STATUS", "IMAGE"]),
    )

def cmd_stats(_args, _aw, **_) -> str:
    rc, raw = run_nelly("stats", json_output=True)
    if rc != 0: return fmt_err(rc, raw)
    try:
        items = json.loads(raw)
    except Exception:
        return fmt_err(1, raw)
    if not items:
        return f"{b('Live stats')}\n{pre('(no running containers)')}"
    rows = [
        [s.get("Name", "?"),
         s.get("CPUPerc", "?"),
         s.get("MemPerc", "?"),
         s.get("MemUsage", "?"),
         s.get("PIDs", "?")]
        for s in items
    ]
    return section(
        "Live stats",
        table(rows, headers=["NAME", "CPU", "MEM%", "MEM", "PIDS"]),
    )

# ---- read: status / cron / explain / doctor / events ---------------------

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
        rows = [
            [s.get("app", "?"),
             s.get("schedule", "") or "(unscheduled)",
             s.get("entrypoint", "") or "-"]
            for s in scheds
        ]
        out += ["", section("Apps", table(rows, headers=["APP", "SCHEDULE", "ENTRYPOINT"]))]

    pinned = d.get("pinned") or {}
    if pinned:
        rows = [[k, v] for k, v in pinned.items()]
        out += ["", section("Pinned revisions", table(rows, headers=["APP", "REVISION"]))]

    return "\n".join(out)

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
        return f"{b(n)} — schedules\n{pre('(no apps)')}"

    rows = []
    for it in items:
        sched = it.get("schedule") or "(unscheduled)"
        ep    = it.get("entrypoint") or "-"
        desc  = it.get("description") or ""
        rows.append([it.get("app", "?"), sched, desc, ep])
    body = table(rows, headers=["APP", "SCHEDULE", "WHEN", "ENTRYPOINT"])

    # If any app has next_runs, append them as a sub-section per app.
    nexts = []
    for it in items:
        nrs = it.get("next_runs") or []
        if nrs:
            nexts.append(it.get("app", "?") + ":")
            for nxt in nrs[:3]:
                nexts.append(f"  {nxt}")
    out = [section(f"{n} — schedules", body)]
    if nexts:
        out += ["", section("Next runs", "\n".join(nexts))]
    return "\n".join(o for o in out if o)

def cmd_explain(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("explain", n)
    clean = re.sub(r"\x1b\[[0-9;]*m", "", raw or "").rstrip()
    if rc != 0: return fmt_err(rc, clean)
    return f"{b(f'{n} — summary')}\n{pre(clean or '(no output)')}"

def cmd_doctor(args, _aw, **_) -> str:
    n, err = _one_name(args)
    if err: return err
    rc, raw = run_nelly("doctor", n)
    clean = re.sub(r"\x1b\[[0-9;]*m", "", raw or "")
    # Rewrite the ✓ / ! / ✗ markers to text labels for cleaner monospace
    # rendering across Telegram clients.
    clean = clean.replace("  ✓ ", "  [OK]   ")
    clean = clean.replace("  ! ", "  [WARN] ")
    clean = clean.replace("  ✗ ", "  [FAIL] ")
    return f"{b(f'{n} — pre-flight check')}\n{pre(clean.rstrip() or '(no output)')}"

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
             "--format", "{{.Time}}  {{.Action}}"],
            timeout=15
        ).decode("utf-8", errors="replace")
    except Exception as e:
        return f"docker events failed: {esc(e)}"
    return f"{b(f'{n} — events (last hour)')}\n{pre(out.rstrip() or '(no events)')}"

# ---- read: logs / metrics / releases --------------------------------------

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
            tail = subprocess.check_output(["tail", "-n", "10", str(f)], timeout=5).decode("utf-8", errors="replace")
        except Exception:
            continue
        if not tail.strip():
            continue
        chunks.append(section(f.stem, tail.rstrip()))
    if not chunks:
        return f"no log lines yet for {esc(n)}"
    return f"{b(n)}\n\n" + "\n\n".join(chunks)

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
        return f"{b(f'{n} — metrics{label}')}\n{pre('(no runs yet)')}"

    rows = []
    for s in items:
        runs = s.get("runs", 0)
        ok   = s.get("success", 0)
        fl   = s.get("failed", 0)
        status = "OK" if fl == 0 else ("WARN" if ok > fl else "FAIL")
        rows.append([
            s.get("app", "?"),
            f"[{status}]",
            str(runs),
            str(ok),
            str(fl),
            f"{s.get('avg_dur_s', 0)}s",
            f"{s.get('p95_dur_s', 0) or 0}s",
            str(s.get("last_rc", "?")),
            fmt_ts(s.get("last_ts", "") or ""),
        ])
    body = table(
        rows,
        headers=["APP", "STATUS", "RUNS", "OK", "FAIL", "AVG", "P95", "RC", "LAST"],
    )
    return section(f"{n} — metrics{label}", body)

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
        return f"{b(f'{n} — releases')}\n{pre('(no releases yet)')}"
    # Newest first; show last 10.
    recent = list(reversed(items))[:10]
    rows = [
        [r.get("release_id", "?"),
         fmt_ts(r.get("finalized_at") or r.get("created_at", "")),
         r.get("outcome", "?")]
        for r in recent
    ]
    body = table(rows, headers=["RELEASE", "WHEN", "OUTCOME"])
    out = [section(f"{n} — releases", body)]
    if len(items) > 10:
        out.append(i_(f"(showing 10 of {len(items)} — use /release for one)"))
    return "\n".join(out)

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
        ("duration",  f"{m.get('duration_seconds')}s" if m.get("duration_seconds") is not None else None),
        ("image",     short_image(m.get("image", "") or "")),
        ("actor",     m.get("actor", "")),
        ("health",    m.get("health_status", "")),
        ("wait_s",    m.get("wait_healthy_seconds")),
        ("previous",  m.get("previous_release_id", "")),
        ("rollback",  m.get("rollback_of", "")),
        ("auto_rolled_back", "yes" if m.get("auto_rollback_triggered") else None),
    ]
    out = [
        b(f"{n} — {rel_id}  ({outcome})"),
        "",
        pre(kv(pairs)),
    ]
    note = m.get("note") or ""
    if note:
        out += ["", section("Note", note)]
    return "\n".join(out)

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
