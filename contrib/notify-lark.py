#!/usr/bin/env python3
"""Push fleet's increment to Lark, so being away from the keyboard is allowed.

Runs from a timer. Silence is the normal outcome: most minutes have nothing
worth a phone buzz, and a channel that buzzes for everything gets muted, which
costs more than never having built it.

WHAT IS WORTH A BUZZ

Not `task.done`. An exit code of 0 means the process ended, nothing more -- by
this repo's own acceptance discipline a finished task still owes a diff review,
a re-run, a mutation check and a cross-family review before anyone believes it.
Pushing on done means pushing "finished but unbelieved", many times a day.

Three classes go out instead:

  1. a claim reaching a verdict     -- `claim.verify` (confirmed | refuted)
  2. a NEW decision wanting a human -- decision.needs_user, still unresolved
  3. the queue in trouble           -- final failure, review-empty, stalled

WATERMARKS

Two, both ours, both in our own state file. `fleet since <watermark>` with an
explicit argument is read-only with respect to the ledger's watermark table:
cmd_since sets `advance = args.watermark is None` and only calls wm_set when
that is true (bin/fleet:2807, bin/fleet:2905). Omitting the argument would
consume the *commander's* increment -- events it then never sees.

Decisions are tracked by decision id, not by event id, because two of the three
code paths that create a needs_user decision emit no `decision.add` event:
_block_task (bin/fleet:1219) and _rule_decision (bin/fleet:3867) insert the row
directly. Those are exactly the decisions nobody typed a command to create, so
keying on the event stream would drop the ones most likely to go unnoticed.

CAVEAT, DELIBERATE

contrib/README.md's rule is that these scripts only ever read the ledger,
because "several read-looking subcommands are actually writers". `fleet since`
is one of them: cmd_since calls reap_orphans (bin/fleet:2803), which settles
orphaned tasks and writes task.orphaned events. This script uses the CLI anyway
-- it is the interface the spec names, and it resolves spilled payloads
(spill_load, bin/fleet:745) that a raw sqlite reader would hand back as
{"_spill": ...} pointers. The write it triggers is one the daemon performs on
every poll regardless. Recorded rather than silently resolved.

USAGE

    notify-lark.py                 # dry run: print the message, send nothing
    notify-lark.py --send          # really send; needs a target in the config

Config (JSON, default ~/.config/fleet-contrib/notify-lark.json):

    {"chat_id": "oc_..."}      or      {"user_id": "ou_..."}
"""
import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

DEFAULT_MAX_LINES = 12
TEXT_WIDTH = 72          # display columns for the free-text tail of a line
QUESTION_WIDTH = 96      # a decision's question is the point of the line

# Sort key prefix per class. A truncated message must never be the one that
# dropped the item asking for a human, so urgency orders the groups and the
# fold eats the tail.
PRI_NEEDS_USER, PRI_TROUBLE, PRI_CLAIM = 0, 1, 2

LABELS = {
    "needs_user": ("\U0001f534", "NEEDS YOU"),
    "failed":     ("\U0001f4a5", "failed"),
    "stalled":    ("\U0001f40c", "stalled"),
    "verified":   ("\u2705", "verified"),
    "refuted":    ("\u274c", "refuted"),
}
LABEL_W = max(len(text) for _, text in LABELS.values())


class Fail(Exception):
    """Anything that must end the run non-zero with the watermark untouched."""


def dwidth(s: str) -> int:
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def dclip(s: str, limit: int) -> str:
    s = " ".join((s or "").split())
    if dwidth(s) <= limit:
        return s
    out, w = [], 0
    for c in s:
        cw = 2 if unicodedata.east_asian_width(c) in "WF" else 1
        if w + cw > limit - 1:
            break
        out.append(c)
        w += cw
    return "".join(out) + "\u2026"


def fleet_home() -> str:
    return str(Path(os.environ.get("FLEET_HOME") or (Path.home() / ".fleet")))


def run_fleet(fleet_cmd, *args):
    cmd = list(fleet_cmd) + ["--json"] + list(args)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as e:
        raise Fail(f"cannot run {cmd[0]}: {e}")
    if p.returncode != 0:
        raise Fail(
            f"{' '.join(cmd)} exited {p.returncode}: "
            f"{(p.stderr or p.stdout).strip()[:400]}"
        )
    try:
        return json.loads(p.stdout)
    except ValueError as e:
        raise Fail(f"{' '.join(cmd)} did not print JSON: {e}")


def load_state(path: Path, home: str):
    """Return (event_wm, decision_wm), or None when there is no usable state.

    A watermark counts event ids in one specific ledger. Carrying one across a
    FLEET_HOME switch would either replay a stranger's history or skip real
    events, so a recorded home that no longer matches is treated as no state.
    """
    try:
        d = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(d, dict) or d.get("fleet_home") != home:
        return None
    try:
        return int(d["event_watermark"]), int(d["decision_watermark"])
    except (KeyError, TypeError, ValueError):
        return None


def save_state(path: Path, home: str, event_wm: int, decision_wm: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = json.dumps({
        "fleet_home": home,
        "event_watermark": event_wm,
        "decision_watermark": decision_wm,
    }, ensure_ascii=False, indent=2) + "\n"
    # Atomic: a timer-driven writer that is killed mid-write would otherwise
    # leave unparseable state, which reads as "no state" and re-bootstraps.
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".notify-lark.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(body)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def collect(fleet_cmd, event_wm, decision_wm):
    """Read one increment. Returns (items, new_event_wm, new_decision_wm)."""
    since = run_fleet(fleet_cmd, "since", str(event_wm))
    events = since.get("events") or []
    new_event_wm = int(since.get("watermark", event_wm))

    decisions = run_fleet(fleet_cmd, "decisions")
    new_decision_wm = max([int(d["id"]) for d in decisions] or [decision_wm])

    items = []

    for d in decisions:
        if int(d["id"]) <= decision_wm:
            continue
        if not d.get("needs_user") or d.get("resolved_at") is not None:
            continue
        ref = f"decision {d['id']}"
        if d.get("task_id"):
            ref += f" \u00b7 task {d['task_id']}"
        items.append({
            "pri": PRI_NEEDS_USER, "sort": int(d["id"]), "kind": "needs_user",
            "ref": ref, "text": dclip(d.get("question") or "", QUESTION_WIDTH),
        })

    for e in events:
        kind = e.get("kind")
        payload = e.get("payload") or {}
        if not isinstance(payload, dict):
            payload = {}
        tid = e.get("task_id")

        if kind == "claim.verify":
            # The ledger's vocabulary is confirmed|refuted (bin/fleet:5424);
            # anything else is a status this script has not been taught.
            status = payload.get("status")
            if status not in ("confirmed", "refuted"):
                continue
            cid = payload.get("claim_id")
            items.append({
                "pri": PRI_CLAIM, "sort": int(e["id"]),
                "kind": "verified" if status == "confirmed" else "refuted",
                "ref": f"task {tid} \u00b7 claim {cid}",
                "claim_id": cid,
            })
        elif kind == "task.finish" and payload.get("exit_code"):
            # task.retry carries the non-final failures; a task.finish with a
            # non-zero code has spent its attempts.
            items.append({
                "pri": PRI_TROUBLE, "sort": int(e["id"]), "kind": "failed",
                "ref": f"task {tid}", "task_id": tid,
                "note": f"exit {payload['exit_code']}",
            })
        elif kind == "task.review_empty":
            # Marked failed while reporting exit_code 0 (bin/fleet:2175), so
            # the exit-code test above cannot see it.
            items.append({
                "pri": PRI_TROUBLE, "sort": int(e["id"]), "kind": "failed",
                "ref": f"task {tid}", "task_id": tid,
                "note": f"review of {payload.get('review_of')} produced no claims",
            })
        elif kind == "task.stalled":
            items.append({
                "pri": PRI_TROUBLE, "sort": int(e["id"]), "kind": "stalled",
                "ref": f"task {tid}", "task_id": tid,
                "note": f"idle {payload.get('idle_s')}s",
            })

    items.sort(key=lambda i: (i["pri"], i["sort"]))
    return items, new_event_wm, new_decision_wm


def enrich(fleet_cmd, items) -> None:
    """Fill in claim texts and task titles for the items that will be shown.

    Called after truncation: a burst of 200 failures must not become 200
    subprocesses to look up titles nobody will read.
    """
    if any(i.get("claim_id") for i in items):
        claims = {int(c["id"]): c for c in run_fleet(fleet_cmd, "claim", "list")}
        for i in items:
            if i.get("claim_id") is not None:
                c = claims.get(int(i["claim_id"]))
                i["text"] = dclip(c["claim"] if c else "", TEXT_WIDTH)

    titles = {}
    for i in items:
        tid = i.get("task_id")
        if tid is None:
            continue
        if tid not in titles:
            try:
                titles[tid] = run_fleet(fleet_cmd, "show", str(tid)).get("title") or ""
            except Fail:
                titles[tid] = ""
        i["text"] = dclip(f"{titles[tid]}  ({i['note']})", TEXT_WIDTH)


def render(items, total) -> str:
    head = f"fleet \u00b7 {total} \u6761\u65b0\u7ed3\u8bba"
    lines = []
    for i in items:
        emoji, label = LABELS[i["kind"]]
        lines.append(
            f"{emoji} {label.ljust(LABEL_W)}  {i['ref']}  {i.get('text', '')}".rstrip()
        )
    dropped = total - len(items)
    if dropped > 0:
        lines.append(f"\u2026+{dropped} \u6761")
    return "\n".join([head] + lines)


def load_config(path: Path):
    try:
        text = path.read_text()
    except OSError:
        return None, f"no config file at {path}"
    try:
        cfg = json.loads(text)
    except ValueError as e:
        return None, f"{path} is not valid JSON: {e}"
    if not isinstance(cfg, dict):
        return None, f"{path} must hold a JSON object"
    return cfg, None


def target_of(cfg):
    """The --chat-id / --user-id pair lark-cli needs, or (None, reason)."""
    if cfg.get("chat_id"):
        return ["--chat-id", str(cfg["chat_id"])], None
    if cfg.get("user_id"):
        return ["--user-id", str(cfg["user_id"])], None
    return None, "config names no chat_id or user_id"


def send(lark_cmd, target, text, key):
    """One attempt. No retry loop: a send that keeps failing must not turn a
    per-minute timer into a per-minute storm, and the caller leaves the
    watermark alone so the next tick tries again."""
    cmd = list(lark_cmd) + ["im", "+messages-send"] + list(target) + [
        "--text", text, "--idempotency-key", key[:50],
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as e:
        return 1, f"cannot run {cmd[0]}: {e}"
    if p.returncode != 0:
        return p.returncode, (p.stderr or p.stdout).strip()[:800]
    return 0, ""


def main(argv=None) -> int:
    default_state = Path(
        os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local" / "state")
    ) / "fleet-contrib" / "notify-lark.json"
    default_config = Path(
        os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")
    ) / "fleet-contrib" / "notify-lark.json"

    ap = argparse.ArgumentParser(
        description="push fleet's increment to Lark (dry run unless --send)"
    )
    ap.add_argument("--send", action="store_true",
                    help="really send; requires a target in the config")
    ap.add_argument("--dry-run", action="store_true",
                    help="the default: print the message, send nothing")
    ap.add_argument("--config", type=Path,
                    default=Path(os.environ.get("FLEET_NOTIFY_CONFIG") or default_config))
    ap.add_argument("--state", type=Path,
                    default=Path(os.environ.get("FLEET_NOTIFY_STATE") or default_state))
    ap.add_argument("--max-lines", type=int, default=DEFAULT_MAX_LINES)
    ap.add_argument("--fleet-bin", default=os.environ.get("FLEET_NOTIFY_FLEET") or "fleet")
    ap.add_argument("--lark-bin", default=os.environ.get("FLEET_NOTIFY_LARK") or "lark-cli")
    args = ap.parse_args(argv)

    if args.send and args.dry_run:
        print("notify-lark: --send and --dry-run are mutually exclusive", file=sys.stderr)
        return 2
    if args.max_lines < 1:
        print("notify-lark: --max-lines must be >= 1", file=sys.stderr)
        return 2

    fleet_cmd = shlex.split(args.fleet_bin)
    lark_cmd = shlex.split(args.lark_bin)

    # Resolved before anything else runs, so that a --send with nowhere to send
    # cannot reach the backend by any path: no ledger read, no message built.
    target = None
    if args.send:
        cfg, err = load_config(args.config)
        if cfg is None:
            print(f"notify-lark: --send refused: {err}", file=sys.stderr)
            return 2
        target, err = target_of(cfg)
        if target is None:
            print(f"notify-lark: --send refused: {err}", file=sys.stderr)
            return 2

    home = fleet_home()
    try:
        state = load_state(args.state, home)
        if state is None:
            # First run against this ledger. Start from the tip: installing a
            # notifier must not page anyone about the last three weeks.
            _, tip_ev, tip_dec = collect(fleet_cmd, 0, 0)
            save_state(args.state, home, tip_ev, tip_dec)
            print(
                f"notify-lark: watching {home} from event {tip_ev} / decision "
                f"{tip_dec}; nothing sent for the backlog",
                file=sys.stderr,
            )
            return 0

        event_wm, decision_wm = state
        items, new_event_wm, new_decision_wm = collect(fleet_cmd, event_wm, decision_wm)

        # Silence is the common case and it must be complete: this runs once a
        # minute, and a heartbeat line would bury the real ones in any log.
        if not items:
            return 0

        total = len(items)
        shown = items if total <= args.max_lines else items[: args.max_lines - 1]
        enrich(fleet_cmd, shown)
        text = render(shown, total)
    except Fail as e:
        print(f"notify-lark: {e}", file=sys.stderr)
        return 1

    if not args.send:
        print(text)
        if target is None:
            print("notify-lark: dry run; nothing was sent", file=sys.stderr)
        return 0

    # Same range replays the same key, so the retry after a failure that the
    # server actually accepted does not post the message twice.
    key = f"fleet-notify-{event_wm}-{new_event_wm}-{decision_wm}-{new_decision_wm}"
    rc, err = send(lark_cmd, target, text, key)
    if rc != 0:
        print(f"notify-lark: send failed (backend rc={rc}): {err}", file=sys.stderr)
        # Always 1, never the backend's own code: exit 2 is reserved for
        # "refused to run", and a backend that happens to exit 2 must not be
        # mistaken for a misconfigured target.
        #
        # Watermark untouched on purpose: repeating a message is recoverable,
        # dropping the one that said a claim was refuted is not.
        return 1

    save_state(args.state, home, new_event_wm, new_decision_wm)
    return 0


if __name__ == "__main__":
    sys.exit(main())
