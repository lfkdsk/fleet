#!/usr/bin/env python3
"""Publish a compact fleet activity snapshot for Switchboard."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unicodedata


def width(s):
    return sum(0 if unicodedata.combining(c) else
               2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def clip(s, limit):
    out = []
    used = 0
    for c in str(s):
        n = 0 if unicodedata.combining(c) else \
            2 if unicodedata.east_asian_width(c) in "WF" else 1
        if used + n > limit:
            break
        out.append(c)
        used += n
    return "".join(out)


def age(seconds):
    if seconds is None:
        return "idle -"
    seconds = max(0, int(seconds))
    if seconds < 60:
        return f"idle {seconds}s"
    if seconds < 3600:
        return f"idle {seconds // 60}m"
    if seconds < 86400:
        return f"idle {seconds // 3600}h"
    return f"idle {seconds // 86400}d"


def read_snapshot():
    if not sys.stdin.isatty():
        raw = sys.stdin.read()
        if raw.strip():
            return json.loads(raw)
    try:
        proc = subprocess.run(
            ["fleet", "top", "--once", "--json"], capture_output=True,
            text=True, timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"fleet invocation failed: {exc}") from exc
    if proc.returncode:
        raise RuntimeError(
            f"fleet exited {proc.returncode}: {proc.stderr.strip() or 'no error text'}"
        )
    return json.loads(proc.stdout)


def make_payload(src):
    daemon = src["daemon"]
    counts = src["counts"]
    if daemon["running"]:
        state = "daemon running"
        if daemon.get("stalled_s") is not None:
            state = "daemon stalled"
    else:
        state = "daemon stopped"
    rows = [{
        "text": clip(f"{state} · running {counts['running']}/{counts['max_parallel']} "
                     f"· queued {counts['queued']}", 48),
        "status": clip("stalled" if daemon.get("stalled_s") is not None else state, 24),
        "hot": bool(daemon.get("stalled_s") is not None or
                    (not daemon["running"] and counts["queued"])),
    }]
    rank = {"running": 0, "running?": 0, "queued": 1}
    tasks = sorted((t for t in src.get("tasks", []) if t["status"] in rank),
                   key=lambda t: (rank[t["status"]], t["id"]))
    for task in tasks[:4]:
        text = f"{task['id']} {task['channel']} {task.get('title') or ''}"
        rows.append({"text": clip(text, 48),
                     "status": clip(age(task.get("idle_s")), 24),
                     "hot": bool(task.get("stalled"))})
    return {"label": "fleet", "at": int(src["at"]) * 1000, "rows": rows}


def main():
    directory = Path(os.environ.get(
        "SWITCHBOARD_ACTIVITY_DIR", str(Path.home() / ".switchboard/activity.d")
    ))
    if not directory.is_dir():
        return 0
    try:
        payload = make_payload(read_snapshot())
        data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
    except (KeyError, TypeError, ValueError, RuntimeError) as exc:
        print(f"publish-activity: {exc}", file=sys.stderr)
        return 1
    if len(data) > 1200:
        print(f"publish-activity: payload is {len(data)} bytes (limit 1200)", file=sys.stderr)
        return 1
    tmp = None
    try:
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".fleet.",
                                         delete=False) as fh:
            tmp = Path(fh.name)
            fh.write(data)
        os.replace(tmp, directory / "fleet.json")
    except OSError as exc:
        print(f"publish-activity: write failed: {exc}", file=sys.stderr)
        if tmp is not None:
            try:
                tmp.unlink()
            except OSError:
                pass
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
