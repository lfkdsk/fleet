#!/usr/bin/env python3
"""Stop hook: don't let a turn end while fleet still needs the commander.

Two things can be pending when a turn wants to end, and neither used to stop it.

**An unanswered question.** fleet's subagents file decisions with needs_user=1
when they hit something only the human can settle. Nothing surfaced them: they
sat in the ledger until a `fleet brief` happened to be run, and `fleet top`
clips the question text to one terminal line. This hook blocks the Stop once
per newly-seen decision id, which is what makes Claude turn them into
AskUserQuestion cards.

**Work in flight that nothing is watching.** fleet never calls back: `_finish`
writes the ledger and returns, so the only bridge from a settling task to this
harness is a background `fleet wait` whose *exit* the harness notices. If the
turn ends with tasks running and no such wait armed,
nobody is woken when they settle and the whole line stalls until the user
types. This hook blocks that Stop too, naming the unwatched tasks and the
command that would watch them.

"No such wait armed" is checked against /proc, not assumed: a wait whose parent
is gone was reparented when the shell Claude Code launched it in died,
so the harness already saw that background command end and the exit this wait
is heading for will wake nobody. An orphan watcher therefore does not count as
an armed wait.

Both fire at most a bounded number of times -- decisions once per id per
session, the awake gate MAX_AWAKE_BLOCKS times per unwatched set. A Stop hook
that can block forever is a wedged session, and "arm a wait" is advice a
commander may legitimately refuse (handing back to the user, tasks owned by
another session).

Fires once per id *per session*. The state file below records what each
session has already been surfaced, so an unanswered decision does not nag on
every turn -- but a decision is not swallowed by whichever session happened to
Stop first. (The first version kept one machine-wide seen-list: session A's
Stop marked B's decisions as shown, A got a card for a question it had no
context for, and B never got one. Both symptoms, one bug.)

Scoped by cwd. Stop passes the session's cwd on stdin; a task or decision
belongs to the session whose cwd contains, or is contained by, the cwd of the
task that raised it (via the task directly, or any task of its goal). A task
running *inside another task's worktree* -- which is what every `--review-of`
task does -- resolves through to that task's cwd first, or cross-family reviews
would belong to no session at all and be silently dropped here. A decision with
no task and no goal has no home and is shown everywhere. No cwd on stdin means
no filter, which is how the tests drive it.

Reads the ledger with mode=ro: a hook on the Stop path must not be able to write
the ledger, reap orphans, or advance a watermark. That rules out shelling out to
the fleet CLI, several of whose read-looking commands are writers.
"""
import json
import os
import sqlite3
import sys
import time
from pathlib import Path

STATE = Path(os.environ.get("FLEET_SURFACE_STATE") or
             (Path.home() / ".claude" / "hooks" / ".fleet-needs-you-seen.json"))
MAX_SHOWN = 4          # AskUserQuestion takes at most 4 questions
QUESTION_CLIP = 400    # enough to decide on; the full text is one command away
MAX_TASKS_SHOWN = 6    # the awake block names tasks, it does not paginate them
# Consecutive Stops the awake gate may block for one unchanged set of unwatched
# tasks. Reset as soon as the set changes or someone arms a wait.
MAX_AWAKE_BLOCKS = 3
# Reserved key inside the state file: session ids are opaque strings from the
# harness, so a leading underscore keeps this out of their namespace.
AWAKE_KEY = "_awake"
# Parent process names that mean "a shell is still holding this wait", i.e.
# something whose exit the harness can still notice.
SHELL_COMMS = ("bash", "sh", "zsh", "dash", "ksh", "fish")


def _log(msg: str, *, warn: bool = False) -> None:
    """Abnormal silent exits only -- never the routine 'nothing to show'.

    warn=True also puts the line on stderr, and is only for failures that take
    the *whole* gate out: the log file is write-only in practice -- nobody
    opens it until they already suspect the hook, and suspecting it requires
    noticing that a gate stopped firing, which is indistinguishable from a
    gate with nothing to report. Recovered states (a reset streak, a state
    file rewritten) stay quiet; they did their job.
    """
    try:
        with open(str(STATE) + ".log", "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass
    if warn:
        try:
            sys.stderr.write(f"fleet-hook warning: {msg}\n")
        except Exception:
            pass


def _under(a: str, b: str) -> bool:
    """a is b, or inside b, or b is inside a."""
    a = a.rstrip("/"); b = b.rstrip("/")
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")


def _fleet_home() -> Path:
    return Path(os.environ.get("FLEET_HOME") or (Path.home() / ".fleet"))


def _human_age(secs: int) -> str:
    if secs < 90:
        return f"{secs}s"
    if secs < 5400:
        return f"{secs // 60}m"
    return f"{secs // 3600}h{(secs % 3600) // 60:02d}m"


# --- /proc: who is watching -------------------------------------------------
#
# Everything below reads /proc and nothing else. It is a fact about this
# machine's process table, not about the ledger, so it stays out of the SQL.


def _proc_args(pid: int):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
    except Exception:
        return []


def _proc_ppid(pid: int):
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("PPid:"):
                    return int(line.split()[1])
    except Exception:
        pass
    return None


def _orphaned(pid: int) -> bool:
    """True if nothing the harness launched is still this process's parent.

    The obvious test -- ppid == 1 -- is wrong here: `systemd --user` can be a
    subreaper and adopt orphans itself, so a wait whose shell died may have a
    non-init parent. Naming init and systemd is not enough either: any process
    can call
    PR_SET_CHILD_SUBREAPER and adopt orphans under its own name, and a
    PR_SET_CHILD_SUBREAPER and adopt orphans under its own name.

    So the test is positive instead: a watcher counts only if a shell is still
    somewhere above it, since the background command the harness tracks is a
    shell. Anything else -- a subreaper of any name -- means the shell is gone
    and this wait's exit wakes nobody.

    Only the **direct** parent. The review of fcdd403 pointed out a real false
    positive -- a watcher wrapped in `timeout`/`stdbuf`/`env` has the wrapper as
    its parent and the shell one step up -- and walking the chain to fix it was
    tried and reverted: a subreaper is a genuine ancestor, so the walk strolls
    straight past the very PR_SET_CHILD_SUBREAPER case the positive test exists
    to catch (suite case 56 caught the regression immediately). Between "a
    wrapped watcher costs one capped block" and "a real orphan is mistaken for
    a watcher and the wake is lost", the first is the cheaper error, and
    nothing in fleet wraps its waits today.

    Also gone: accepting any parent whose argv merely contained
    ".claude/shell-snapshots/". Any process can put that string in its own argv
    for free, and it bought nothing -- the real wrapper is a `bash -c ...`, so
    its comm already matches.

    Known limits, stated rather than papered over: a subreaper that happens to
    be named like a shell fools this, and so does anything that re-execs into
    one. Both are hostile-or-exotic; the shape that actually happened (task
    176: wrapper died, systemd --user adopted it) is caught.
    """
    ppid = _proc_ppid(pid)
    if ppid is None or ppid <= 1:
        return True
    try:
        with open(f"/proc/{ppid}/comm") as f:
            comm = f.read().strip()
    except Exception:
        return True  # the parent went away between the two reads
    return comm not in SHELL_COMMS


# Returned by _proc_env when the environment could not be read at all, which
# is not the same answer as "the variable is not set" -- collapsing the two
# let a wait on another ledger be counted as watching the default one.
UNREADABLE = object()


def _proc_env(pid: int, key: str):
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            data = f.read()
    except Exception:
        return UNREADABLE
    for item in data.split(b"\0"):
        k, _, v = item.decode("utf-8", "replace").partition("=")
        if k == key:
            return v
    return None


def _boot_epoch():
    try:
        with open("/proc/stat") as f:
            for line in f:
                if line.startswith("btime "):
                    return int(line.split()[1])
    except Exception:
        pass
    return None


def _proc_start_epoch(pid: int, boot):
    """Wall-clock time this pid started, or None if it cannot be read.

    The mtime of /proc/<pid> is the process start, accurate to about a
    millisecond (measured). The obvious `btime + starttime/CLK_TCK` is not:
    /proc/stat's btime is a rounded second and the tick division truncates, so
    that form reads **systematically early** -- 1.05s to 1.56s in four
    consecutive measurements here, 1.713s in the cross-family review of
    fcdd403 that found it. Early is the dangerous direction: it makes a wait
    armed right after an enqueue look like it started *before* the task, so
    the standard "add, then arm" sequence is judged unwatched, every Stop,
    stably -- three false blocks and then the gate is off for that set.
    The old form stays as a fallback for kernels without the mtime behaviour.
    """
    try:
        return os.stat(f"/proc/{pid}").st_mtime
    except Exception:
        pass
    if boot is None:
        return None
    try:
        with open(f"/proc/{pid}/stat") as f:
            # comm can contain spaces and parentheses: everything before the
            # last ')' is pid+comm, and starttime is the 20th field after it.
            rest = f.read().rpartition(")")[2].split()
        return boot + int(rest[19]) / os.sysconf("SC_CLK_TCK")
    except Exception:
        return None


def watchers(home: Path):
    """Live `fleet wait` processes able to wake this harness, for this ledger.

    Returns (pid, ids-or-None, start-epoch-or-None) per watcher. Skipped:
    orphans (see _orphaned: the shell the harness was tracking is gone, so
    this exit wakes nobody) and waits pointed at another FLEET_HOME (the test
    suites leave those around, and their task ids collide with real ones).
    """
    boot = _boot_epoch()
    home_r = os.path.realpath(home)
    found = []
    try:
        entries = os.listdir("/proc")
    except Exception:
        return found
    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        args = _proc_args(pid)
        rest = None
        for i in range(len(args) - 1):
            # The shell wrapper Claude Code launches carries the same words
            # inside one `-c` string; only a real argv match counts.
            if os.path.basename(args[i]) == "fleet" and args[i + 1] == "wait":
                rest = args[i + 2:]
                break
        if rest is None:
            continue
        if _orphaned(pid):
            continue
        watched_home = _proc_env(pid, "FLEET_HOME")
        if watched_home is UNREADABLE:
            # Which ledger it watches is unknowable. Not counting it costs one
            # capped block; counting it wrongly costs a missed wake, which is
            # the failure this gate exists to prevent.
            continue
        if watched_home and os.path.realpath(watched_home) != home_r:
            continue
        if not watched_home and home_r != os.path.realpath(Path.home() / ".fleet"):
            continue
        ids = None
        if "--ids" in rest:
            ids = set()
            for tok in rest[rest.index("--ids") + 1:]:
                if not tok.isdigit():
                    break
                ids.add(int(tok))
        found.append((pid, ids, _proc_start_epoch(pid, boot)))
    return found


def _watcher_of(task_t0, tid: int, found):
    """The pid watching this task, or None.

    A wait with no --ids snapshots the queued/running set once at startup
    (bin/fleet cmd_wait), so it only covers tasks that already existed then;
    anything enqueued later is not in its list. When the start time cannot be
    read, treat it as covering rather than invent a block.

    The task side is whole seconds (the ledger stores ints) while the wait side
    is sub-second, so one second stays ambiguous: a task stamped 100 was really
    created somewhere in [100, 101). Two cross-family reviews disagreed about
    which way to resolve that, and the second one is right. Resolving to "not
    covered" looked like it cost one capped block; in fact the misjudgement is
    *stable* -- the same two numbers every Stop -- so it burns all three blocks
    and then the gate is silent for that set. Resolving to "covered" costs at
    most one missed wake, in a window that only opens if a no-ids wait was
    armed in the same second the task appeared, and armed-then-enqueued is the
    rare order. So: fail open. (--ids waits, which is what this hook tells you
    to arm, never reach this comparison.)
    """
    for pid, ids, start in found:
        if ids is None:
            if start is None or task_t0 is None or start >= task_t0:
                return pid
        elif tid in ids:
            return pid
    return None


def _daemon_pid(home: Path):
    """Live daemon pid for this ledger, or None. Same 'pidfile is a hint, the
    process is truth' rule bin/fleet uses."""
    try:
        pid = int((home / "fleetd.pid").read_text().strip())
        os.kill(pid, 0)
        return pid
    except Exception:
        return None


# --- ledger -----------------------------------------------------------------


def _resolve_homes(cwd, gid, worktrees, goal_cwds):
    """Every cwd a row could belong to, worktrees followed to their owner.

    A `--review-of` task runs *in the reviewed task's worktree*, so its cwd is
    ~/.fleet/worktrees/task-N, which is under no session's cwd. Follow it to
    the owning task's cwd. The walk runs to a fixed point rather than a fixed
    number of hops: a review of a review of a review is an ordinary shape here,
    and a hop budget just means a deep chain resolves to some worktree halfway
    up and gets dropped by the cwd filter -- the silent loss this resolution
    exists to prevent. The seen-set is what bounds it; only a genuine cycle
    stops the walk early.
    """
    if cwd:
        seen = set()
        while True:
            owner = worktrees.get(os.path.realpath(cwd))
            if owner is None or owner[0] in seen or not owner[1]:
                break
            seen.add(owner[0])
            cwd = owner[1]
        return [cwd]
    return list(goal_cwds.get(gid) or [])


def _read_ledger(db: Path):
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
    decisions = conn.execute(
        "SELECT d.id, d.question, t.cwd, d.goal_id FROM decision d "
        "LEFT JOIN task t ON t.id = d.task_id "
        "WHERE d.needs_user=1 AND d.resolved_at IS NULL ORDER BY d.id"
    ).fetchall()
    inflight = conn.execute(
        "SELECT id, status, channel, title, cwd, goal_id, "
        "COALESCE(started_at, created_at) t0 FROM task "
        "WHERE status IN ('queued','running') ORDER BY id"
    ).fetchall()
    # cwd -> (owner task id, owner cwd), so a task running inside another
    # task's worktree can be attributed to the repo that task came from.
    worktrees = {
        os.path.realpath(wt): (tid, cwd)
        for tid, cwd, wt in conn.execute(
            "SELECT id, cwd, worktree FROM task WHERE worktree IS NOT NULL"
        ).fetchall() if wt
    }
    goal_ids = {r[3] for r in decisions if r[2] is None and r[3] is not None}
    goal_ids |= {r[5] for r in inflight if r[4] is None and r[5] is not None}
    goal_cwds = {
        gid: [r[0] for r in conn.execute(
            "SELECT DISTINCT cwd FROM task WHERE goal_id=?", (gid,)
        ).fetchall() if r[0]]
        for gid in goal_ids
    }
    conn.close()
    return decisions, inflight, worktrees, goal_cwds


def _load_state():
    try:
        state = json.loads(STATE.read_text())
        # The first version stored one flat list for the whole machine -- the
        # exact bug this rewrite fixes. Discard it rather than inherit it.
        if not isinstance(state, dict):
            return {}
        return state
    except Exception:
        return {}


def _save_state(state) -> bool:
    try:
        STATE.parent.mkdir(parents=True, exist_ok=True)
        STATE.write_text(json.dumps(state))
        return True
    except Exception as e:
        _log(f"state write failed ({type(e).__name__}); not blocking, would repeat")
        return False


def _block(reason: str) -> None:
    print(json.dumps({"decision": "block", "reason": reason}))


# --- the two gates ----------------------------------------------------------


def gate_decisions(rows, state, session_key) -> bool:
    seen = set(state.get(session_key) or [])
    fresh = [r for r in rows if r[0] not in seen]
    if not fresh:
        return False

    shown = fresh[:MAX_SHOWN]
    lines = [
        f"  decision {rid}: {(q or '').strip()[:QUESTION_CLIP]}"
        for rid, q, _, _ in shown
    ]
    more = len(fresh) - len(shown)
    if more:
        lines.append(f"  (+{more} more -- see `fleet decisions --needs-user`)")

    reason = (
        f"fleet has {len(fresh)} unanswered decision(s) that need the user:\n"
        + "\n".join(lines)
        + "\n\nDo NOT paste these at the user. A decision is a subagent's "
        "question asked inside a task's context, and the user does not have "
        "that context -- pasted verbatim it reads as noise. First, for each: "
        "read the full row (question, verdict, evidence), find its source "
        "task, and check whether anything since then already settled it -- a "
        "cross-family review that confirmed or refuted the premise, a later "
        "commit, an artifact on disk. Stale, already-acted-on or moot ones get "
        "`fleet decisions resolve <id>` and a one-line mention, not a "
        "question. Only what is genuinely still open goes to AskUserQuestion: "
        "at most 4, each rewritten with the background the user needs, 2-4 "
        "concrete options, the recommended one first and labelled, and the "
        "cost of each spelled out. Record answers with `fleet decide`, then "
        "resolve. Fires once per id; will not repeat."
    )
    # Only what was actually named is marked seen. Marking the whole set here
    # meant the ids folded into "(+N more)" were never shown by anyone.
    state[session_key] = sorted(seen | {r[0] for r in shown})
    if not _save_state(state):
        return False
    _block(reason)
    return True


def unwatched_tasks(tasks, home: Path):
    """In-flight tasks with no live wait covering them.

    Scanning /proc is the expensive part of this hook; with nothing in flight
    there is nothing to attribute, so it never runs.
    """
    if not tasks:
        return []
    found = watchers(home)
    return [t for t in tasks if _watcher_of(t[6], t[0], found) is None]


def clear_awake(state, session_key) -> None:
    """Forget the block streak once the work is watched again.

    This runs before the decisions gate, not inside the awake gate. The awake
    gate returns early whenever the decisions gate blocked first, so a streak
    recorded before someone armed a wait used to survive that turn and the next
    unwatched stall got a short budget. Found by cross-family review of 258caad.
    """
    awake = state.get(AWAKE_KEY)
    if isinstance(awake, dict) and awake.pop(session_key, None) is not None:
        # Each Stop is a fresh process, so a reset that only happened in memory
        # is no reset at all -- the next Stop re-reads the old streak. Nothing
        # to do about an unwritable state file except say so.
        if not _save_state(state):
            _log(f"awake streak for {session_key} could not be reset on disk")


def gate_awake(unwatched, home: Path, state, session_key) -> bool:
    """Block if work is in flight under this cwd with nothing watching it."""
    if not unwatched:
        return False  # the streak reset lives in clear_awake, ahead of both gates
    awake = state.setdefault(AWAKE_KEY, {})
    if not isinstance(awake, dict):
        awake = state[AWAKE_KEY] = {}
    sig = ",".join(str(t[0]) for t in unwatched)
    prev = awake.get(session_key)
    if not isinstance(prev, dict):
        prev = {}
    # Every field here came off disk and can be any JSON at all. The old
    # `int(prev["n"])` raised ValueError on a string, and the top-level catch
    # swallowed it -- so a single corrupted state file silently switched this
    # gate off for that session, which is the exact failure mode the gate
    # exists to remove. Anything unparseable restarts the streak instead.
    n = 1
    if prev.get("sig") == sig:
        try:
            n = int(prev.get("n") or 0) + 1
        except (TypeError, ValueError):
            _log(f"awake streak for {session_key} was {prev.get('n')!r}; restarted")
    if n > MAX_AWAKE_BLOCKS:
        return False

    now = int(time.time())
    lines = []
    for tid, status, channel, title, _cwd, _gid, t0 in unwatched[:MAX_TASKS_SHOWN]:
        age = f" {_human_age(now - t0)}" if t0 else ""
        lines.append(f"  task {tid} {status}({channel or '-'}){age} "
                     f"{(title or '').strip()[:72]}")
    more = len(unwatched) - len(lines)
    if more:
        lines.append(f"  (+{more} more)")
    ids = " ".join(str(t[0]) for t in unwatched)

    warn = ""
    if any(t[1] == "queued" for t in unwatched) and _daemon_pid(home) is None:
        warn = ("\nThe daemon is not running, so the queued ones will not start "
                "at all: `fleet daemon start`.")
    reason = (
        f"fleet has {len(unwatched)} task(s) in flight here that nothing is "
        "watching:\n" + "\n".join(lines) + warn +
        "\n\nfleet never calls back -- `_finish` writes the ledger and returns "
        "without waking the session. The only thing that wakes it when a task "
        "settles is a background `fleet wait` exiting, and there is no live, "
        "non-orphaned one covering these. End the turn now and the work "
        "finishes unseen until the user next types.\n"
        f"Arm one in the background before you stop:\n"
        f"  fleet wait --any --ids {ids} --timeout 10800\n"
        "`--any` returns on the first settle, so re-arm for whatever is left "
        "when it fires, and say in one line what you will do then. If you are "
        "deliberately handing these to the user or to another session, say so "
        f"and stop -- this fires at most {MAX_AWAKE_BLOCKS} times per set."
    )
    awake[session_key] = {"sig": sig, "n": n}
    if not _save_state(state):
        return False
    _block(reason)
    return True


def main() -> None:
    session_key, session_cwd = "_nosession", None
    try:
        raw = sys.stdin.read()
        hook_in = json.loads(raw) if raw.strip() else {}
        if isinstance(hook_in, dict):
            session_key = str(hook_in.get("session_id") or "_nosession")
            cwd = hook_in.get("cwd")
            if isinstance(cwd, str) and cwd:
                session_cwd = os.path.realpath(cwd)
    except Exception:
        pass

    home = _fleet_home()
    db = home / "fleet.db"
    if not db.exists():
        return

    try:
        decisions, inflight, worktrees, goal_cwds = _read_ledger(db)
    except Exception as e:
        _log(f"ledger read failed ({type(e).__name__}: {e}); not blocking",
             warn=True)
        return  # a locked or moved ledger must never break the Stop path

    if session_cwd is not None:
        def mine(cwd, gid):
            homes = _resolve_homes(cwd, gid, worktrees, goal_cwds)
            # No home at all: shown everywhere, since nobody else will.
            return not homes or any(
                _under(os.path.realpath(h), session_cwd) for h in homes)
        decisions = [r for r in decisions if mine(r[2], r[3])]
        # A task always has a cwd, so an in-flight task with no session home is
        # another session's work, not everyone's: it is not surfaced here.
        inflight = [t for t in inflight if t[4] and mine(t[4], t[5])]

    state = _load_state()
    unwatched = unwatched_tasks(inflight, home)
    if not unwatched:
        clear_awake(state, session_key)
    if gate_decisions(decisions, state, session_key):
        return
    gate_awake(unwatched, home, state, session_key)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        # Swallowing is right -- a Stop hook must not take the session with it
        # -- but swallowing *silently* is how a plain NameError in this file
        # read as "the gate just never fires" for a whole test run.
        _log(f"unhandled {type(e).__name__}: {e}", warn=True)
