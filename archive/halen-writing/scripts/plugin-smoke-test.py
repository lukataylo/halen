#!/usr/bin/env python3
"""Plugin JSON-RPC handshake smoke test — non-agentic, no model, no GUI.

For every bundled plugin under plugins/<id>/halen-plugin.json this spawns the
plugin process exactly as the host does (manifest `executable` + `args`), drives
the real NDJSON `initialize` -> response handshake, asserts a well-formed
JSON-RPC 2.0 response with no error, then closes stdin and confirms the process
exits cleanly. stdin is closed *before* sending `notifications/initialized`, so
a plugin that launches a GUI companion on initialized (Desktop Buddy) never
opens a window during the test.

    python3 scripts/plugin-smoke-test.py

Exit code is the number of plugins that failed (0 = all clean)."""
import json
import os
import subprocess
import sys
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGINS_DIR = os.path.join(ROOT, "plugins")

INIT = {
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "protocolVersion": "0.1",
        "hostInfo": {"name": "Halen", "version": "0.1.0"},
        "capabilities": {
            "inference": {"streaming": False, "tiers": ["small", "medium", "large"]},
            "ax": {"read": True, "write": True},
            "ui": {"toast": True},
        },
    },
}


def discover():
    out = []
    for name in sorted(os.listdir(PLUGINS_DIR)):
        pdir = os.path.join(PLUGINS_DIR, name)
        manifest = os.path.join(pdir, "halen-plugin.json")
        if os.path.isdir(pdir) and os.path.exists(manifest):
            out.append((name, pdir, json.load(open(manifest))))
    return out


def command(pdir, manifest):
    """Match the host's spawn: manifest `executable` + `args`, cwd = plugin dir.
    Falls back to `python3 plugin.py` for a manifest without those fields."""
    exe = manifest.get("executable")
    args = manifest.get("args") or ["plugin.py"]
    if not exe:
        exe, args = sys.executable, ["plugin.py"]
    return [exe, *args]


def run_one(name, pdir, manifest):
    cmd = command(pdir, manifest)
    p = subprocess.Popen(cmd, cwd=pdir, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    resp = [None]

    def reader():
        try:
            resp[0] = p.stdout.readline()
        except Exception:
            pass
    t = threading.Thread(target=reader, daemon=True)
    t.start()
    try:
        p.stdin.write((json.dumps(INIT) + "\n").encode())
        p.stdin.flush()
    except Exception as e:
        p.kill()
        return False, f"could not send initialize: {e}"
    t.join(timeout=20)
    if resp[0] is None:
        p.kill()
        err = (p.stderr.read(800) or b"").decode(errors="replace")
        return False, f"no initialize response within 20s. stderr: {err[:400]}"
    try:
        msg = json.loads(resp[0].decode(errors="replace").strip())
    except Exception as e:
        p.kill()
        return False, f"non-JSON response: {e}"

    problems = []
    if msg.get("jsonrpc") != "2.0":
        problems.append("missing jsonrpc 2.0")
    if msg.get("id") != 1:
        problems.append(f"id mismatch: {msg.get('id')}")
    if msg.get("error"):
        problems.append(f"error: {msg['error']}")
    if "result" not in msg and "error" not in msg:
        problems.append("no result/error field")

    try:
        p.stdin.close()
    except Exception:
        pass
    try:
        p.wait(timeout=8)
    except subprocess.TimeoutExpired:
        p.kill()
        problems.append("did not exit within 8s of stdin EOF")

    return (not problems), ("clean handshake + exit" if not problems else "; ".join(problems))


def main():
    plugins = discover()
    if not plugins:
        print("no plugins found"); return 1
    print(f"=== Plugin JSON-RPC handshake smoke test ({len(plugins)} plugins) ===")
    failures = 0
    for name, pdir, manifest in plugins:
        ok, detail = run_one(name, pdir, manifest)
        print(f"  [{'PASS' if ok else 'FAIL'}] {name:20s} {detail}")
        failures += 0 if ok else 1
    print(f"=== {len(plugins) - failures}/{len(plugins)} passed ===")
    return failures


if __name__ == "__main__":
    sys.exit(main())
