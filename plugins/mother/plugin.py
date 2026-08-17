#!/usr/bin/env python3
"""Halen Mother — out-of-process discipline enforcer.

Mother keeps you off the apps and websites you told her to keep you off,
and she does not negotiate during your focus hours. Everything is local:
no network, no accounts, no telemetry. She watches two surfaces —

  A. blocklisted **apps**   — from the host's `app.focused` events
  B. blocklisted **sites**  — the active browser tab, read over AppleScript

— and enforces them with escalating, deterministic consequences:

  * soft       — a stern notification, logged. Nothing is closed.
  * hardcore   — inside focus hours she quits the app / closes the tab,
                 no override. Outside focus hours she confronts first and
                 lets you bail to a real task, but quits if you ignore her.
  * lockdown   — always immediate. No prompt, no override, ever.

The privileged macOS work splits two ways, exactly like the other Halen
plugins: notifications and modal prompts are proxied through the host over
JSON-RPC (`ui/toast`, `ui/prompt`); quitting an app or closing a tab is done
by Mother's own `osascript` subprocess — a subprocess the plugin spawns
itself, not a host capability. Mother holds no macOS entitlements of her own.

Config + state live under
  ~/Library/Application Support/Halen/com.halen.mother/
as plain JSON you can read and edit. `config.json` is seeded with sane
defaults on first run; `state.json` is Mother's local ledger of every
violation and every override you talked her into.

Protocol: JSON-RPC 2.0, newline-delimited. stdin = host -> plugin,
stdout = plugin -> host, stderr = log (forwarded into Halen's unified log).
"""
import sys
import os
import json
import time
import subprocess
import threading
import itertools
from datetime import datetime

# --- JSON-RPC plumbing (shared shape with the other Halen plugins) ----------

_ids = itertools.count(1)
_ids_lock = threading.Lock()
_out_lock = threading.Lock()
_pending = {}
_pending_lock = threading.Lock()
_stop = threading.Event()


def _send(msg):
    line = json.dumps(msg) + "\n"
    with _out_lock:
        sys.stdout.write(line)
        sys.stdout.flush()


def _log(text):
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def call(method, params, timeout=180):
    """Send a request to the host and block until the response arrives."""
    with _ids_lock:
        rid = next(_ids)
    event = threading.Event()
    slot = {}
    with _pending_lock:
        _pending[rid] = (event, slot)
    _send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    if not event.wait(timeout):
        with _pending_lock:
            _pending.pop(rid, None)
        raise TimeoutError(f"{method} timed out")
    if "error" in slot:
        raise RuntimeError(f"{method}: {slot['error']}")
    return slot.get("result")


def _resolve(msg):
    with _pending_lock:
        entry = _pending.pop(msg.get("id"), None)
    if not entry:
        return
    event, slot = entry
    if "error" in msg:
        slot["error"] = msg["error"]
    else:
        slot["result"] = msg.get("result")
    event.set()


# --- storage -----------------------------------------------------------------

SUPPORT_DIR = os.path.expanduser(
    "~/Library/Application Support/Halen/com.halen.mother"
)
CONFIG_PATH = os.path.join(SUPPORT_DIR, "config.json")
STATE_PATH = os.path.join(SUPPORT_DIR, "state.json")

# Browsers Mother can read the front tab of, by bundle id. Each entry is the
# AppleScript application name plus the dialect for "the front tab". Safari
# says "current tab"; the Chromium family and Arc say "active tab".
BROWSERS = {
    "com.apple.Safari":          ("Safari", "current tab"),
    "com.apple.SafariTechnologyPreview": ("Safari Technology Preview", "current tab"),
    "com.google.Chrome":         ("Google Chrome", "active tab"),
    "com.google.Chrome.canary":  ("Google Chrome Canary", "active tab"),
    "com.brave.Browser":         ("Brave Browser", "active tab"),
    "com.microsoft.edgemac":     ("Microsoft Edge", "active tab"),
    "com.vivaldi.Vivaldi":       ("Vivaldi", "active tab"),
    "company.thebrowser.Browser": ("Arc", "active tab"),
}

DEFAULT_CONFIG = {
    "_comment": (
        "Mother's local rulebook. Edit freely; she reloads it whenever the "
        "file changes. enforcement: 'off' | 'soft' | 'hardcore' | 'lockdown' "
        "(an unrecognized value is treated as 'soft', never escalated). "
        "focusHours.days use 0=Mon ... 6=Sun. Times are local 24h 'HH:MM'."
    ),
    "enforcement": "hardcore",
    # Seconds a blocklisted app may hold focus before Mother acts. A short
    # grace forgives an accidental ⌘-Tab; it is not a loophole.
    "graceSeconds": 6,
    # How often Mother re-reads the front browser tab while a browser is front.
    "sitePollSeconds": 3,
    # When she does confront you (hardcore, outside focus hours), how long the
    # modal waits before she treats silence as "I'm staying" and quits anyway.
    "confrontTimeoutSeconds": 45,
    # Outside focus hours in hardcore mode an override buys you this long.
    "overrideMinutes": 5,
    "focusHours": [
        {"days": [0, 1, 2, 3, 4], "start": "09:00", "end": "18:00"}
    ],
    # Default blocklist is pure-distraction apps only. Work-critical chat apps
    # (Slack, Discord) are deliberately NOT here: quitting an Electron chat app
    # can discard a half-typed message, and a fresh install must never lose the
    # user's data before they've opted in. Add them yourself if you want them.
    "blockedApps": [
        {"bundleId": "ru.keepcoder.Telegram", "name": "Telegram"},
        {"bundleId": "com.zhiliaoapp.musically", "name": "TikTok"},
        {"bundleId": "com.netflix.Netflix", "name": "Netflix"},
        {"bundleId": "com.valvesoftware.steam", "name": "Steam"},
        {"bundleId": "com.reddit.reddit", "name": "Reddit"}
    ],
    "blockedSites": [
        "x.com", "twitter.com", "reddit.com", "youtube.com", "tiktok.com",
        "instagram.com", "facebook.com", "netflix.com", "news.ycombinator.com"
    ]
}

_config_lock = threading.Lock()
_config = dict(DEFAULT_CONFIG)
_config_mtime = 0.0

_state_lock = threading.Lock()
_state = {}


def _ensure_dir():
    os.makedirs(SUPPORT_DIR, exist_ok=True)


def load_config():
    """Read config.json, seeding defaults on first run. Cheap to call often;
    only re-parses when the file's mtime moves."""
    global _config, _config_mtime
    try:
        mtime = os.path.getmtime(CONFIG_PATH)
    except OSError:
        _ensure_dir()
        with open(CONFIG_PATH, "w") as f:
            json.dump(DEFAULT_CONFIG, f, indent=2)
        with _config_lock:
            _config = dict(DEFAULT_CONFIG)
            _config_mtime = os.path.getmtime(CONFIG_PATH)
        _log("mother: seeded default config.json")
        return
    if mtime == _config_mtime:
        return
    try:
        with open(CONFIG_PATH) as f:
            loaded = json.load(f)
    except (OSError, ValueError) as exc:
        _log(f"mother: config unreadable, keeping last good copy ({exc})")
        return
    merged = dict(DEFAULT_CONFIG)
    merged.update({k: v for k, v in loaded.items() if v is not None})
    with _config_lock:
        _config = merged
        _config_mtime = mtime
    _log(f"mother: loaded config — enforcement={merged.get('enforcement')}, "
         f"{len(merged.get('blockedApps', []))} app(s), "
         f"{len(merged.get('blockedSites', []))} site(s)")


def cfg(key):
    with _config_lock:
        return _config.get(key, DEFAULT_CONFIG.get(key))


def load_state():
    global _state
    try:
        with open(STATE_PATH) as f:
            _state = json.load(f)
    except (OSError, ValueError):
        _state = {"installedAt": time.time(), "violations": [],
                  "overrides": 0, "totalQuits": 0, "totalTabsClosed": 0}
        save_state()


def save_state():
    _ensure_dir()
    tmp = STATE_PATH + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(_state, f, indent=2)
        os.replace(tmp, STATE_PATH)
    except OSError as exc:
        _log(f"mother: could not persist state ({exc})")


def record(kind, target, action):
    """Append a violation to the local ledger (last 500 kept)."""
    with _state_lock:
        _state.setdefault("violations", []).append({
            "ts": time.time(),
            "iso": datetime.now().isoformat(timespec="seconds"),
            "kind": kind, "target": target, "action": action,
        })
        _state["violations"] = _state["violations"][-500:]
        if action == "quit":
            _state["totalQuits"] = _state.get("totalQuits", 0) + 1
        elif action == "closed-tab":
            _state["totalTabsClosed"] = _state.get("totalTabsClosed", 0) + 1
        elif action == "override":
            _state["overrides"] = _state.get("overrides", 0) + 1
        save_state()


# --- schedule ----------------------------------------------------------------

def _parse_hm(s):
    try:
        h, m = s.split(":")
        return int(h) * 60 + int(m)
    except (ValueError, AttributeError):
        return None


def in_focus_hours(now=None):
    """True if the current local time falls inside any configured focus window.
    An entry whose end <= start is treated as spanning midnight."""
    lt = time.localtime(now if now is not None else time.time())
    minute_of_day = lt.tm_hour * 60 + lt.tm_min
    weekday = lt.tm_wday  # Monday == 0
    for window in cfg("focusHours") or []:
        days = window.get("days", [0, 1, 2, 3, 4, 5, 6])
        if weekday not in days:
            continue
        start = _parse_hm(window.get("start", "00:00"))
        end = _parse_hm(window.get("end", "23:59"))
        if start is None or end is None:
            continue
        if start <= end:
            if start <= minute_of_day < end:
                return True
        else:  # wraps past midnight
            if minute_of_day >= start or minute_of_day < end:
                return True
    return False


def current_mode():
    """The effective strictness right now, folding the schedule in.

    Returns one of: 'off', 'warn', 'enforce-no-override', 'enforce-override'.
    """
    enforcement = (cfg("enforcement") or "hardcore").strip().lower()
    if enforcement in ("off", "disabled", "none"):
        return "off"
    if enforcement == "soft":
        return "warn"
    if enforcement == "lockdown":
        return "enforce-no-override"
    if enforcement == "hardcore":
        # relentless during focus hours, negotiable (with friction) outside
        return "enforce-no-override" if in_focus_hours() else "enforce-override"
    # Unrecognized value (typo, unexpected string). Fail SAFE — to the least
    # destructive mode — never silently escalate to hardcore and start quitting
    # apps the user never opted into blocking. A config mistake must not be a
    # data-loss event.
    _log(f"mother: unknown enforcement {enforcement!r}; falling back to 'warn'")
    return "warn"


# --- AppleScript helpers (Mother's own subprocess; no host capability) -------

def _as(s):
    """Escape a Python string for safe embedding inside an AppleScript "..."
    string literal. App names come from the user's config.json; a stray quote
    would otherwise break out of the literal (and at worst inject script)."""
    return str(s).replace("\\", "\\\\").replace('"', '\\"')


def _osascript(script, timeout=10):
    try:
        out = subprocess.run(
            ["/usr/bin/osascript", "-e", script],
            capture_output=True, text=True, timeout=timeout)
        if out.returncode != 0:
            return None, (out.stderr or "").strip()
        return out.stdout.strip(), None
    except Exception as exc:  # noqa: BLE401 — subprocess can fail many ways
        return None, str(exc)


def front_app_bundle():
    """Bundle id of the frontmost app, read directly (defends the grace check
    against a stale `app.focused` event)."""
    script = (
        'tell application "System Events" to get bundle identifier of '
        'first application process whose frontmost is true'
    )
    out, _ = _osascript(script, timeout=5)
    return out or None


def quit_app(bundle_id, app_name):
    """Ask the app to quit gracefully (it may still prompt to save work)."""
    out, err = _osascript(f'tell application id "{_as(bundle_id)}" to quit')
    if err:
        # Fall back to name-based quit for apps that dislike id addressing.
        _osascript(f'tell application "{_as(app_name)}" to quit')
    _log(f"mother: quit {app_name} ({bundle_id})")


def read_front_tab(app_name, tab_phrase):
    script = f'tell application "{_as(app_name)}" to get URL of {tab_phrase} of front window'
    out, err = _osascript(script, timeout=6)
    if err or not out:
        return None
    return out


def close_front_tab(app_name, tab_phrase):
    script = f'tell application "{_as(app_name)}" to close {tab_phrase} of front window'
    _osascript(script, timeout=6)


# --- matching ----------------------------------------------------------------

def host_of(url):
    """Extract a lowercase host from a URL without importing urllib quirks."""
    u = url.strip().lower()
    for scheme in ("https://", "http://", "ftp://", "file://", "about:"):
        if u.startswith(scheme):
            u = u[len(scheme):]
            break
    u = u.split("/", 1)[0].split("?", 1)[0].split("#", 1)[0]
    if "@" in u:
        u = u.rsplit("@", 1)[1]
    return u.split(":", 1)[0]


def site_blocked(url):
    """Return the matching blocklist entry, or None. A rule matches the host
    itself and any subdomain of it (reddit.com blocks www.reddit.com)."""
    host = host_of(url)
    if not host:
        return None
    for rule in cfg("blockedSites") or []:
        r = rule.strip().lower().lstrip(".")
        if not r:
            continue
        if host == r or host.endswith("." + r):
            return rule
    return None


def app_blocked(bundle_id):
    for entry in cfg("blockedApps") or []:
        if entry.get("bundleId") == bundle_id:
            return entry.get("name") or bundle_id
    return None


# --- override passes ---------------------------------------------------------

_pass_lock = threading.Lock()
_app_pass = {}     # bundle_id -> epoch the pass expires
_site_pass = {}    # host     -> epoch the pass expires


def has_pass(table, key):
    with _pass_lock:
        until = table.get(key, 0)
        if until > time.time():
            return True
        table.pop(key, None)
        return False


def grant_pass(table, key):
    with _pass_lock:
        table[key] = time.time() + (cfg("overrideMinutes") or 5) * 60


# --- app enforcement ---------------------------------------------------------

_current_bundle = None
_current_lock = threading.Lock()
_app_timers = {}   # bundle_id -> Timer (one pending grace check per app)
_app_busy = set()  # bundle ids currently being confronted, to avoid stacking
# Only one ui/prompt confrontation on screen at a time. The host presenter is
# single-slot: opening a second prompt dismisses the first and resolves it with
# a null action — which on the app path means an *unintended quit*. The app and
# site enforcement threads can fire concurrently, so they share this lock.
_confront_lock = threading.Lock()


def on_app_focused(bundle_id, app_name):
    global _current_bundle
    with _current_lock:
        _current_bundle = bundle_id
    # Drive the browser poller: start when a browser takes focus, idle otherwise.
    browser_focus_changed(bundle_id)

    name = app_blocked(bundle_id)
    if not name:
        return
    if has_pass(_app_pass, bundle_id):
        return
    with _current_lock:
        if bundle_id in _app_busy or bundle_id in _app_timers:
            return
        grace = max(0, int(cfg("graceSeconds") or 0))
        timer = threading.Timer(grace, _grace_elapsed, args=(bundle_id, name))
        timer.daemon = True
        _app_timers[bundle_id] = timer
        timer.start()


def _grace_elapsed(bundle_id, name):
    with _current_lock:
        _app_timers.pop(bundle_id, None)
    # Only act if the blocked app is *still* frontmost — verified live, not from
    # a possibly-stale focus event. ⌘-Tabbing away within the grace is forgiven.
    if front_app_bundle() != bundle_id:
        return
    if has_pass(_app_pass, bundle_id):
        return
    with _current_lock:
        if bundle_id in _app_busy:
            return
        _app_busy.add(bundle_id)
    try:
        enforce_app(bundle_id, name)
    finally:
        with _current_lock:
            _app_busy.discard(bundle_id)


def enforce_app(bundle_id, name):
    mode = current_mode()
    if mode == "off":
        return
    if mode == "warn":
        toast(f"{name} is on your blocklist",
              "Mother sees you. Logged — but she's letting it slide this time.")
        record("app", name, "warned")
        return

    if mode == "enforce-no-override":
        quit_app(bundle_id, name)
        record("app", name, "quit")
        toast(f"Mother closed {name}",
              "It's on your blocklist and you're in focus hours. "
              "Back to work.")
        return

    # enforce-override: confront, give one friction-laden way out. Serialize so
    # a concurrent site confrontation can't dismiss this prompt out from under
    # the user (a null action here = an unintended quit). If another prompt is
    # already up, skip leniently this cycle rather than quit blind.
    if not _confront_lock.acquire(blocking=False):
        _log(f"mother: a confrontation is already on screen; skipping {name} this cycle")
        return
    try:
        body = (f"{name} is on your blocklist. You're outside focus hours, so "
                f"Mother will let you decide — once.")
        try:
            # Guard against a non-positive / non-numeric misconfig: the popup's
            # host-side lifetime must stay positive and below our RPC wait.
            try:
                confront = float(cfg("confrontTimeoutSeconds"))
            except (TypeError, ValueError):
                confront = 45.0
            if confront <= 0:
                confront = 45.0
            result = call("ui/prompt", {
                "title": "Mother",
                "body": body,
                "actions": ["Close it", "Override (logged)"],
                # Dismiss the popup when the confront window elapses so it
                # doesn't linger on screen after Mother has already quit the
                # app; the +5 keeps our RPC wait just longer than that.
                "timeoutSeconds": confront,
            }, timeout=confront + 5)
            action = (result or {}).get("action")
        except Exception as exc:
            _log(f"mother: prompt failed, defaulting to enforce ({exc})")
            action = None

        if action == "Override (logged)":
            if confirm_override(name):
                grant_pass(_app_pass, bundle_id)
                record("app", name, "override")
                toast("Override granted",
                      f"{cfg('overrideMinutes') or 5} minutes on {name}. "
                      f"Mother wrote it down.")
                return
        # "Close it", dismissed, timed out, or override declined → enforce.
        quit_app(bundle_id, name)
        record("app", name, "quit")
    finally:
        _confront_lock.release()


def confirm_override(target):
    """Second gate. Override is never one click — that's the discipline."""
    try:
        result = call("ui/prompt", {
            "title": "Mother is watching",
            "body": (f"This override is recorded against you. "
                     f"Still want {cfg('overrideMinutes') or 5} minutes on "
                     f"{target}?"),
            "actions": ["No — close it", "Yes, I accept the cost"],
            "timeoutSeconds": 35,
        }, timeout=40)
        return (result or {}).get("action") == "Yes, I accept the cost"
    except Exception:
        return False


# --- site enforcement (browser tab poller) -----------------------------------

_browser_app = None          # (app_name, tab_phrase) currently front, or None
_browser_lock = threading.Lock()
_site_busy = set()
_site_last_enforced = {}     # host -> monotonic time Mother last acted on it
# A pinned or session-restored blocked tab would otherwise be closed *and*
# toasted every `sitePollSeconds` (default 3s) forever. Act on a given host at
# most once per this window so Mother doesn't spam Notification Center or fight
# the browser in a tight loop. She still re-closes it after the window if it's
# still there — she just doesn't do it three times a second.
_SITE_ENFORCE_COOLDOWN = 30.0


def browser_focus_changed(bundle_id):
    global _browser_app
    with _browser_lock:
        _browser_app = BROWSERS.get(bundle_id)


def site_poll_loop():
    """Single long-lived thread. It only touches AppleScript while a known
    browser is frontmost, so it's idle (and silent) the rest of the time."""
    while not _stop.is_set():
        with _browser_lock:
            browser = _browser_app
        interval = max(1, int(cfg("sitePollSeconds") or 3))
        if browser is None:
            _stop.wait(1.0)
            continue
        app_name, tab_phrase = browser
        try:
            check_front_tab(app_name, tab_phrase)
        except Exception as exc:
            _log(f"mother: tab check failed ({exc})")
        _stop.wait(interval)


def check_front_tab(app_name, tab_phrase):
    url = read_front_tab(app_name, tab_phrase)
    if not url:
        return
    rule = site_blocked(url)
    if not rule:
        return
    host = host_of(url)
    if has_pass(_site_pass, host):
        return
    now = time.monotonic()
    with _browser_lock:
        if host in _site_busy:
            return
        # Per-host backoff so a persistent blocked tab isn't nuked + toasted
        # every poll. (The warn path also toasts, so this covers all modes.)
        if now - _site_last_enforced.get(host, 0.0) < _SITE_ENFORCE_COOLDOWN:
            return
        _site_busy.add(host)
        _site_last_enforced[host] = now
    try:
        enforce_site(app_name, tab_phrase, host, rule)
    finally:
        with _browser_lock:
            _site_busy.discard(host)


def enforce_site(app_name, tab_phrase, host, rule):
    mode = current_mode()
    if mode == "off":
        return
    if mode == "warn":
        toast(f"{rule} is on your blocklist",
              f"Mother sees the tab open in {app_name}. Logged.")
        record("site", host, "warned")
        return

    # Re-read the front tab right before closing it. The match that brought us
    # here came from an earlier poll; between then and now the user may have
    # switched tabs/windows, and `close current tab` acts on whatever is front
    # *now*. Only close if the front tab is still this blocked host — so we
    # never nuke a tab the user just navigated to. (TOCTOU guard.)
    fresh = read_front_tab(app_name, tab_phrase)
    if not fresh or host_of(fresh) != host:
        _log(f"mother: front tab changed before close ({host} no longer front), skipping")
        return

    # Sites are cheaper to undo than apps, so Mother closes the tab first and
    # explains after — even outside focus hours. An override re-opens nothing;
    # it just stops her nagging the same host for a few minutes.
    close_front_tab(app_name, tab_phrase)
    record("site", host, "closed-tab")

    if mode == "enforce-no-override":
        toast(f"Mother closed {host}",
              "It's blocked and you're in focus hours. Not today.")
        return

    # enforce-override (outside focus hours): offer a quiet pass so re-opening
    # it on purpose doesn't get the tab nuked again instantly. The tab is
    # already closed above; serialize only the override negotiation so it can't
    # collide with an app confrontation (single-slot host presenter). If one is
    # already up, just skip the offer this cycle.
    if not _confront_lock.acquire(blocking=False):
        return
    try:
        result = call("ui/prompt", {
            "title": "Mother",
            "body": (f"Closed {host} — it's on your blocklist. Outside focus "
                     f"hours you can buy {cfg('overrideMinutes') or 5} min."),
            "actions": ["Keep it blocked", "Override (logged)"],
            "timeoutSeconds": 35,
        }, timeout=40)
        if (result or {}).get("action") == "Override (logged)":
            grant_pass(_site_pass, host)
            record("site", host, "override")
            toast("Override granted",
                  f"{cfg('overrideMinutes') or 5} minutes on {host}. "
                  "Re-open the tab yourself.")
    except Exception as exc:
        _log(f"mother: site prompt failed ({exc})")
    finally:
        _confront_lock.release()


# --- ui helpers --------------------------------------------------------------

def toast(title, body):
    try:
        call("ui/toast", {"title": f"Mother — {title}", "body": body}, timeout=20)
    except Exception as exc:
        _log(f"mother: toast failed ({exc})")


# --- config watcher ----------------------------------------------------------

def config_watch_loop():
    while not _stop.wait(5):
        load_config()


# --- main loop ---------------------------------------------------------------

def main():
    load_config()
    load_state()
    started = False
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = msg.get("method")
        if method == "initialize":
            _send({"jsonrpc": "2.0", "id": msg["id"],
                   "result": {"capabilities": {}}})
        elif method == "notifications/initialized":
            if not started:
                started = True
                _log("mother: online. Discipline is in session.")
                for target in (site_poll_loop, config_watch_loop):
                    threading.Thread(target=target, daemon=True).start()
        elif method == "shutdown":
            _stop.set()
            _send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif method == "exit":
            _stop.set()
            break
        elif method == "event/app.focused":
            payload = (msg.get("params") or {}).get("payload") or {}
            bundle = payload.get("appBundleId")
            if bundle:
                on_app_focused(bundle, payload.get("appName") or bundle)
        elif method is None and "id" in msg:
            _resolve(msg)

    _stop.set()


if __name__ == "__main__":
    main()
