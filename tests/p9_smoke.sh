#!/usr/bin/env bash
# fleet P9 smoke tests: `fleet top` read-only monitor, resolved_model/agent
# ledger columns, prompt_extra channel notes, display-width layout, and
# stall detection. Zero model quota: shell channel only.
#
# The core of this suite is cases 3/4/5: they prove the monitor cannot move
# the ledger -- not by convention, but by construction (mode=ro URI, no
# writer calls, dead-pid tasks displayed as 'running?' rather than reaped).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p9-test-XXXX)"
SCRATCH=()
cleanup(){ rm -rf "$FLEET_HOME" "${SCRATCH[@]}"; }
trap cleanup EXIT
export PATH="$ROOT/bin:$PATH"

PASS=0
FAIL=0
N=0

ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }

field(){ fleet show "$1" | awk -v f="$2" '$1==f":"{print $2}'; }

wait_status(){
  local id="$1" want="$2" i got
  for i in $(seq 1 150); do
    got=$(field "$id" status)
    [ "$got" = "$want" ] && return 0
    sleep 0.2
  done
  return 1
}

fleet init >/dev/null
printf 'true\n' > "$FLEET_HOME/spec_true.sh"
printf 'echo hi\n' > "$FLEET_HOME/spec_hi.sh"

# 1. --once output has the header bar, a task row, and the footer bar
T1=$(fleet add "p9 one" --channel shell --no-preamble --spec "$FLEET_HOME/spec_true.sh")
out1=$(fleet top --once)
if printf '%s\n' "$out1" | grep -q "fleet  daemon" \
   && printf '%s\n' "$out1" | grep -q "p9 one" \
   && printf '%s\n' "$out1" | grep -q "^budget"; then
  ok "top --once: header, task row and footer all present"
else
  no "top --once: header, task row and footer all present"
fi

# 2. non-tty bare `fleet top` degrades to one screen and exits (never hangs)
if timeout 10 fleet top < /dev/null > "$FLEET_HOME/once2.out" 2>&1; then
  ok "non-tty bare top degrades to one screen and exits 0"
else
  no "non-tty bare top degrades to one screen and exits 0"
fi

# 3. read-only: fleet.db mtime and PRAGMA data_version are unchanged across
#    a --once run (data_version is read on ONE held connection, so a commit
#    by any other connection would bump it)
M3=$(python3 - "$FLEET_HOME/fleet.db" <<'PY'
import os, sqlite3, subprocess, sys
db = sys.argv[1]
w = sqlite3.connect(db)
v1 = w.execute("PRAGMA data_version").fetchone()[0]
m1 = os.stat(db).st_mtime_ns
r = subprocess.run(["fleet", "top", "--once"], capture_output=True, text=True)
v2 = w.execute("PRAGMA data_version").fetchone()[0]
m2 = os.stat(db).st_mtime_ns
assert r.returncode == 0, r.stderr
assert v1 == v2, (v1, v2)
assert m1 == m2, (m1, m2)
print("ok")
PY
)
if [ "$M3" = "ok" ]; then
  ok "top --once leaves mtime and data_version untouched"
else
  no "top --once leaves mtime and data_version untouched ($M3)"
fi

# 4. read-only is mechanical, not polite: a chmod 444 db still renders.
#    Runs in its own FLEET_HOME: a ro open against a 444 WAL db creates
#    read-only -shm/-wal files, which would poison every later WRITER in the
#    same home (the monitor itself never writes -- only its leftovers could).
#    4b: a DELETE-journal-mode db at 444 renders too -- and this is the case
#    that distinguishes a real ro open from a writable one: a writable
#    connection runs PRAGMA journal_mode=WAL, which must WRITE to convert a
#    DELETE-mode db and so fails on a read-only file.
W4="$(mktemp -d /var/tmp/fleet-p9-ro-XXXX)"; SCRATCH+=("$W4")
(
  export FLEET_HOME="$W4"
  fleet init >/dev/null
  printf 'true\n' > "$W4/spec.sh"
  fleet add "ro 任务" --channel shell --no-preamble --spec "$W4/spec.sh" >/dev/null
  chmod 444 "$FLEET_HOME/fleet.db"
  fleet top --once > /dev/null 2>"$W4/e4"
  echo "rc=$?"
) > "$W4/result"
m4a=$(cat "$W4/result")
DEL="$(mktemp -d /var/tmp/fleet-p9-del-XXXX)"; SCRATCH+=("$DEL")
python3 - "$DEL/fleet.db" "$ROOT/schema.sql" <<'PY'
import sqlite3, sys, time
db, schema = sys.argv[1], sys.argv[2]
c = sqlite3.connect(db)
c.executescript(open(schema).read())
c.execute("PRAGMA journal_mode=DELETE")
c.execute(
    "INSERT INTO task(title,channel,family,status,cwd,created_at) "
    "VALUES('delmode','shell','none','queued','/tmp',?)",
    (int(time.time()),),
)
c.commit()
PY
chmod 444 "$DEL/fleet.db"
if FLEET_HOME="$DEL" fleet top --once > /dev/null 2>"$DEL/e4b"; then
  m4b=ok
else
  m4b="rc=$? ($(head -1 "$DEL/e4b"))"
fi
chmod 644 "$DEL/fleet.db"
if [ "$m4a" = "rc=0" ] && [ "$m4b" = ok ]; then
  ok "top --once renders with the db file chmod 444 (WAL and DELETE mode)"
else
  no "top --once renders with the db file chmod 444 (wal=$m4a del=$m4b)"
fi

# 5. a 'running' task whose wrapper is dead shows as 'running?' and is NOT
#    reaped: top never writes, so the ledger must still say running after.
GHOST_CWD="$(mktemp -d /var/tmp/fleet-p9-ghost-XXXX)"; SCRATCH+=("$GHOST_CWD")
G=$(python3 - "$FLEET_HOME/fleet.db" "$GHOST_CWD" <<'PY'
import sqlite3, subprocess, sys, time
db, cwd = sys.argv[1], sys.argv[2]
p = subprocess.Popen(["sleep", "1"])
p.wait()
c = sqlite3.connect(db)
cur = c.execute(
    "INSERT INTO task(title,channel,family,status,cwd,created_at,started_at,pid) "
    "VALUES('ghost 任务','shell','none','running',?,?,?,?)",
    (cwd, int(time.time()) - 9999, int(time.time()) - 9999, p.pid),
)
c.commit()
print(cur.lastrowid)
PY
)
out5=$(FLEET_ORPHAN_GRACE_S=1 fleet top --once)
st5=$(field "$G" status)
if printf '%s\n' "$out5" | grep -q "running?" && [ "$st5" = running ]; then
  ok "dead-pid running task shows 'running?' and stays running (no reap)"
else
  no "dead-pid running task shows 'running?' and stays running (got status=$st5)"
fi

# 6. EMPTY marker on a task that exited 0 with no output
E=$(fleet add "silent 成功" --channel shell --no-preamble --spec "$FLEET_HOME/spec_true.sh")
fleet run "$E" >/dev/null
wait_status "$E" done
if fleet top --once | grep -E "^ *$E .*EMPTY"; then
  ok "EMPTY marker shown on an exit-0-no-output task"
else
  no "EMPTY marker shown on an exit-0-no-output task"
fi

# 7. daemon stopped with queued work: the header names it
out7=$(fleet top --once | head -1)
if printf '%s\n' "$out7" | grep -q stopped && printf '%s\n' "$out7" | grep -q queued; then
  ok "header flags a stopped daemon with queued tasks"
else
  no "header flags a stopped daemon with queued tasks (got: $out7)"
fi

# 8. footer: unverified claims and needs_user decisions
fleet claim add "$T1" "claim-marker-8" --evidence "ev-8 file:1" >/dev/null
fleet decide "decision-marker-8?" --needs-user >/dev/null
out8=$(fleet top --once | tail -3)
if printf '%s\n' "$out8" | grep -q "claims" \
   && printf '%s\n' "$out8" | grep -q "unverified" \
   && printf '%s\n' "$out8" | grep -q "NEEDS YOU"; then
  ok "footer shows unverified claims and NEEDS YOU decisions"
else
  no "footer shows unverified claims and NEEDS YOU decisions (got: $out8)"
fi

# 9. uninitialized FLEET_HOME: friendly error, non-zero, no traceback
FRESH="$(mktemp -d /var/tmp/fleet-p9-fresh-XXXX)"; SCRATCH+=("$FRESH")
FLEET_HOME="$FRESH" fleet top --once >"$FRESH/o9" 2>"$FRESH/e9"
rc9=$?
if [ "$rc9" != 0 ] && [ -s "$FRESH/e9" ] && ! grep -q Traceback "$FRESH/e9"; then
  ok "uninit home: friendly error, exit non-zero, no traceback"
else
  no "uninit home: friendly error, exit non-zero, no traceback (rc=$rc9)"
fi

# 10. --interval is accepted and ignored under --once (fast exit); a non-tty
#     `fleet top --interval N` still degrades to one screen
t0=$(date +%s%N)
fleet top --once --interval 5 >/dev/null
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
if [ "$ms" -lt 3000 ] && timeout 10 fleet top --interval 1 < /dev/null >/dev/null; then
  ok "--interval accepted, ignored with --once, non-tty still degrades"
else
  no "--interval accepted, ignored with --once, non-tty still degrades (ms=$ms)"
fi

# 11. a very narrow terminal truncates instead of crashing
if COLUMNS=40 fleet top --once > /dev/null 2>"$FRESH/e11"; then
  ok "COLUMNS=40: no crash"
else
  no "COLUMNS=40: no crash ($(head -1 "$FRESH/e11"))"
fi

# 12. resolved_model/resolved_agent: stamped at launch from the same variables
#     the adapter got; a later channels.json edit must not change history.
#     Runs in its own FLEET_HOME with a stub channel on the shell adapter.
STUB="$(mktemp -d /var/tmp/fleet-p9-stub-XXXX)"; SCRATCH+=("$STUB")
(
  export FLEET_HOME="$STUB"
  fleet init >/dev/null
  python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["model_families"]["stub/*"] = "stubfam"
d["channels"]["stub"] = {
    "adapter": "shell.sh", "model": "stub/alpha",
    "models": ["stub/alpha", "stub/beta"], "agent": "reviewer",
}
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
  printf 'true\n' > "$STUB/spec.sh"
  S1=$(fleet add "stub default" --channel stub --no-preamble --spec "$STUB/spec.sh")
  S2=$(fleet add "stub override" --channel stub --model stub/beta --no-preamble --spec "$STUB/spec.sh")
  fleet run "$S1" >/dev/null; fleet run "$S2" >/dev/null
  wait_status "$S1" done
  wait_status "$S2" done
  rm1=$(field "$S1" resolved_model); ra1=$(field "$S1" resolved_agent)
  rm2=$(field "$S2" resolved_model)
  st12=$(fleet status --all)
  # rewrite the channel default AFTER launch: history must not move
  python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"]["stub"]["model"] = "stub/gamma"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
  rm1b=$(field "$S1" resolved_model)
  st12b=$(fleet status --all)
  top12=$(fleet top --once)
  if [ "$rm1" = "stub/alpha" ] && [ "$ra1" = "reviewer" ] \
     && [ "$rm2" = "stub/beta" ] \
     && printf '%s\n' "$st12" | grep -q "alpha@reviewer" \
     && printf '%s\n' "$st12" | grep -q "beta@reviewer" \
     && [ "$rm1b" = "stub/alpha" ] \
     && printf '%s\n' "$st12b" | grep -q "alpha@reviewer" \
     && printf '%s\n' "$top12" | grep -q "alpha@reviewer"; then
    echo ok
  else
    echo "rm1=$rm1 ra1=$ra1 rm2=$rm2 rm1b=$rm1b"
  fi
) > "$STUB/result"
M12=$(cat "$STUB/result")
if [ "$M12" = ok ]; then
  ok "resolved_model/agent stamped at launch; config drift leaves history put"
else
  no "resolved_model/agent stamped at launch; config drift leaves history put ($M12)"
fi

# 13. migration: a pre-P9 ledger keeps its data and gains the columns,
#     idempotently (re-init must not fail)
OLD="$(mktemp -d /var/tmp/fleet-p9-old-XXXX)"; SCRATCH+=("$OLD")
python3 - "$OLD/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("""CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT)""")
c.execute("""CREATE TABLE goal(
  id INTEGER PRIMARY KEY, statement TEXT NOT NULL, acceptance TEXT,
  approval_gates TEXT, budget_cap INTEGER,
  status TEXT NOT NULL DEFAULT 'open',
  created_by TEXT DEFAULT 'user', created_at INTEGER NOT NULL)""")
c.execute("""CREATE TABLE task(
  id INTEGER PRIMARY KEY, goal_id INTEGER, parent_id INTEGER,
  title TEXT NOT NULL, spec_path TEXT,
  channel TEXT NOT NULL, family TEXT NOT NULL, model TEXT,
  status TEXT NOT NULL DEFAULT 'queued', cwd TEXT NOT NULL,
  deps TEXT NOT NULL DEFAULT '', lease TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  attempt INTEGER NOT NULL DEFAULT 0, max_attempts INTEGER NOT NULL DEFAULT 1,
  pid INTEGER, session_id TEXT, exit_code INTEGER,
  run_dir TEXT, out_path TEXT, log_path TEXT,
  review_of INTEGER, lens TEXT, timeout_s INTEGER,
  created_at INTEGER NOT NULL, started_at INTEGER, ended_at INTEGER,
  verdict TEXT, verdict_by TEXT, worktree TEXT, worktree_branch TEXT)""")
c.execute(
    "INSERT INTO task(id,title,channel,family,status,cwd,created_at) "
    "VALUES(7,'old task','shell','none','done','/tmp',12345)")
c.commit()
PY
FLEET_HOME="$OLD" fleet init >/dev/null 2>"$OLD/init1.err"
FLEET_HOME="$OLD" fleet init >/dev/null 2>"$OLD/init2.err"
M13=$(python3 - "$OLD/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
cols = {r[1] for r in c.execute("PRAGMA table_info(task)")}
assert "resolved_model" in cols and "resolved_agent" in cols, cols
assert "worktree" in cols and "worktree_branch" in cols, cols
gcols = {r[1] for r in c.execute("PRAGMA table_info(goal)")}
assert "context" in gcols, gcols
row = c.execute(
    "SELECT id,title,status,resolved_model,resolved_agent FROM task WHERE id=7"
).fetchone()
assert row == (7, "old task", "done", None, None), row
print("ok")
PY
)
if [ "$M13" = ok ] && [ ! -s "$OLD/init1.err" ] && [ ! -s "$OLD/init2.err" ]; then
  ok "init migrates a pre-P9 ledger in place, data intact, idempotently"
else
  no "init migrates a pre-P9 ledger in place, data intact, idempotently ($M13)"
fi

# 14. CJK titles: columns align by display width, not character count, and a
#     long CJK title is clipped to the terminal width without being sliced
#     into a half character (a char-count clip would overflow the width)
AL="$(mktemp -d /var/tmp/fleet-p9-align-XXXX)"; SCRATCH+=("$AL")
(
  export FLEET_HOME="$AL"
  fleet init >/dev/null
  printf 'true\n' > "$AL/s.sh"
  fleet add "alpha" --channel shell --no-preamble --spec "$AL/s.sh" >/dev/null
  fleet add "中文标题任务" --channel shell --no-preamble --spec "$AL/s.sh" >/dev/null
  fleet add "混合mixed标题" --channel shell --no-preamble --spec "$AL/s.sh" >/dev/null
  fleet add "中文长标题中文长标题中文长标题中文长标题中文长标题" \
    --channel shell --no-preamble --spec "$AL/s.sh" >/dev/null
  fleet run --ready >/dev/null
  fleet top --once > "$AL/out.txt"
  COLUMNS=50 fleet top --once > "$AL/out50.txt"
)
M14=$(python3 - "$AL/out.txt" "$AL/out50.txt" <<'PY'
import re, sys, unicodedata
def w(s):
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1
               for c in s)
titles = ["alpha", "中文标题任务", "混合mixed标题"]
starts = set()
for line in open(sys.argv[1]):
    for t in titles:
        i = line.find(t)
        if i >= 0:
            starts.add(w(line[:i]))
assert len(starts) == 1, f"title column misaligned: {starts}"
# every line of the COLUMNS=50 screen fits in 50 display columns, and the
# long CJK title was clipped (not wrapped, not overflowing)
lines = [l.rstrip("\n") for l in open(sys.argv[2])]
assert lines, "empty screen"
over = [(w(l), l) for l in lines if w(l) > 50]
assert not over, f"lines overflow 50 display cols: {over}"
# Located by id, not by title text: how many CJK chars survive the clip is a
# function of the column layout (adding TOOK cost the title five columns), and
# pinning that count turns a clipping assertion into a layout snapshot. What
# must hold is that the row is present, clipped, and inside the width.
long_rows = [l for l in lines if re.match(r"^4\s", l)]
assert long_rows, "long-title row missing"
assert "中文长" in long_rows[0], f"long title dropped: {long_rows[0]!r}"
assert "中文长标题中文长标题" not in long_rows[0], \
    f"long title not clipped: {long_rows[0]!r}"
assert w(long_rows[0]) <= 50, long_rows[0]
print("ok")
PY
)
if [ "$M14" = ok ]; then
  ok "CJK rows align by display width and clip to the terminal width"
else
  no "CJK rows align by display width and clip to the terminal width ($M14)"
fi

# 15. non-tty output carries no ANSI escapes (clean text for pipes/remote)
if grep -qP '\x1b' "$AL/out.txt"; then
  no "non-tty top output has no ANSI escapes"
else
  ok "non-tty top output has no ANSI escapes"
fi

# 16. idle takes the NEWEST signal: a task whose log is stale but which keeps
#     writing files in its cwd is not stalled
mkdir -p "$FLEET_HOME/cwdA" "$FLEET_HOME/cwdB"
cat > "$FLEET_HOME/spec_fresh.sh" <<'EOF'
for i in $(seq 1 90); do touch fresh.txt; sleep 1; done
EOF
printf 'sleep 90\n' > "$FLEET_HOME/spec_stale.sh"
A=$(fleet add "fresh 任务" --channel shell --cwd "$FLEET_HOME/cwdA" --spec "$FLEET_HOME/spec_fresh.sh")
B=$(fleet add "stale 任务" --channel shell --cwd "$FLEET_HOME/cwdB" --spec "$FLEET_HOME/spec_stale.sh")
fleet run "$A" >/dev/null
sleep 4
rowA=$(fleet status --all --stall 2 | awk -v i="$A" '$1==i')
# status prints one space-free token `run=<age>,idle=<age>` for running tasks;
# take the idle half (the stall judgement is about progress, not runtime).
idleA=$(printf '%s\n' "$rowA" | awk '{print $6}' | sed -E 's/.*idle=//')
ev16=$(python3 - "$FLEET_HOME/fleet.db" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute(
    "SELECT COUNT(*) FROM event WHERE kind='task.stalled'").fetchone()[0])
PY
)
if printf '%s\n' "$rowA" | grep -q " running " \
   && ! printf '%s\n' "$rowA" | grep -q " !" \
   && printf '%s' "$idleA" | grep -qE '^[0-9]+s$' \
   && [ "${idleA%s}" -lt 5 ] && [ "$ev16" = 0 ]; then
  ok "stale log + fresh cwd file: idle is small, no stall mark, no event"
else
  no "stale log + fresh cwd file: idle is small, no stall mark, no event (row='$rowA' events=$ev16)"
fi

# 17. all signals stale: ' !' mark and exactly one task.stalled event (once
#     per episode), and the task's status is NOT touched -- no auto-kill
fleet run "$B" >/dev/null
sleep 3
rowB1=$(fleet status --all --stall 1 | awk -v i="$B" '$1==i')
ev17a=$(python3 - "$FLEET_HOME/fleet.db" "$B" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute(
    "SELECT COUNT(*) FROM event WHERE kind='task.stalled' AND task_id=?",
    (int(sys.argv[2]),)).fetchone()[0])
PY
)
fleet status --all --stall 1 >/dev/null
ev17b=$(python3 - "$FLEET_HOME/fleet.db" "$B" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute(
    "SELECT COUNT(*) FROM event WHERE kind='task.stalled' AND task_id=?",
    (int(sys.argv[2]),)).fetchone()[0])
PY
)
st17=$(field "$B" status)
rowA2=$(fleet status --all --stall 1 | awk -v i="$A" '$1==i')
if printf '%s\n' "$rowB1" | grep -q " !" \
   && [ "$ev17a" = 1 ] && [ "$ev17b" = 1 ] \
   && [ "$st17" = running ] \
   && ! printf '%s\n' "$rowA2" | grep -q " !"; then
  ok "all-stale task: ' !', one task.stalled event, status untouched"
else
  no "all-stale task: ' !', one task.stalled event, status untouched (ev=$ev17a/$ev17b st=$st17)"
fi
fleet cancel "$A" >/dev/null 2>&1 || true
fleet cancel "$B" >/dev/null 2>&1 || true

# 18. prompt_extra: spliced after the preamble under a separator; missing
#     field -> no separator; shell (family=none) never injected even if set
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["channels"]["notes-fixture"] = {
    "adapter": "shell.sh", "model": "gpt-5.6-sol",
    "prompt_extra": "Follow the documented workflow.",
}
d["channels"]["plain-fixture"] = {
    "adapter": "shell.sh", "model": "gpt-5.6-sol",
}
json.dump(d, open(p, "w"), indent=2)
PY
printf 'SPEC-MARKER-18\n' > "$FLEET_HOME/spec18.md"
SPEC18_MAIN="$FLEET_HOME/spec18.md"
R=$(fleet add "channel notes" --channel notes-fixture --spec "$FLEET_HOME/spec18.md")
PR="$FLEET_HOME/runs/$R/prompt.md"
l_pre=$(grep -n "^# Fleet task $R:" "$PR" | head -1 | cut -d: -f1)
l_notes=$(grep -n -- "--- channel notes ---" "$PR" | head -1 | cut -d: -f1)
l_spec=$(grep -n "SPEC-MARKER-18" "$PR" | head -1 | cut -d: -f1)
X=$(fleet add "plain channel" --channel plain-fixture --spec "$FLEET_HOME/spec18.md")
PX="$FLEET_HOME/runs/$X/prompt.md"
if [ -n "$l_pre" ] && [ -n "$l_notes" ] && [ -n "$l_spec" ] \
   && [ "$l_pre" -lt "$l_notes" ] && [ "$l_notes" -lt "$l_spec" ] \
   && grep -q "workflow" "$PR" \
   && ! grep -q -- "--- channel notes ---" "$PX"; then
  m18a=ok
else
  m18a="pre=$l_pre notes=$l_notes spec=$l_spec"
fi
NOTES="$(mktemp -d /var/tmp/fleet-p9-notes-XXXX)"; SCRATCH+=("$NOTES")
(
  export FLEET_HOME="$NOTES"
  fleet init >/dev/null
  python3 - "$NOTES/channels.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"]["shell"]["prompt_extra"] = "SHELL-NOTES-MARKER-18"
d["model_families"]["stub/*"] = "stubfam"
d["channels"]["stub"] = {
    "adapter": "shell.sh", "model": "stub/alpha",
    "prompt_extra": "STUB-NOTES-MARKER-18",
}
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
  SH=$(fleet add "shell no notes" --channel shell --spec "$SPEC18_MAIN")
  ST=$(fleet add "stub notes" --channel stub --spec "$SPEC18_MAIN")
  PSH="$NOTES/runs/$SH/prompt.md"
  PST="$NOTES/runs/$ST/prompt.md"
  st_pre=$(grep -n "^# Fleet task $ST:" "$PST" | head -1 | cut -d: -f1)
  st_notes=$(grep -n -- "--- channel notes ---" "$PST" | head -1 | cut -d: -f1)
  st_spec=$(grep -n "SPEC-MARKER-18" "$PST" | head -1 | cut -d: -f1)
  if ! grep -q "SHELL-NOTES-MARKER-18" "$PSH" \
     && grep -q "STUB-NOTES-MARKER-18" "$PST" \
     && [ -n "$st_pre" ] && [ -n "$st_notes" ] && [ -n "$st_spec" ] \
     && [ "$st_pre" -lt "$st_notes" ] && [ "$st_notes" -lt "$st_spec" ]; then
    echo ok
  else
    echo "shell-injected=$? pre=$st_pre notes=$st_notes spec=$st_spec"
  fi
) > "$NOTES/result"
m18b=$(cat "$NOTES/result")
if [ "$m18a" = ok ] && [ "$m18b" = ok ]; then
  ok "prompt_extra: position right, absent field silent, shell never injected"
else
  no "prompt_extra: position right, absent field silent, shell never injected (a=$m18a b=$m18b)"
fi
fleet cancel "$R" >/dev/null 2>&1 || true
fleet cancel "$X" >/dev/null 2>&1 || true

# 19. C4: top --once's only directory side effects are the -wal/-shm
#     sidecars (a mode=ro open creates them; immutable=1 would suppress
#     them but stale the snapshot). Snapshot the dir, run --once, assert
#     only -wal/-shm were added and fleet.db's mtime is unchanged -- the
#     "zero side effects" promise replaced by an enumerated, tested one.
#     No sqlite connection is held while top runs: a held writer creates
#     -wal/-shm itself, which would mask top's own side effects (and made
#     the immutable=1 mutation toothless).
SE="$(mktemp -d /var/tmp/fleet-p9-se-XXXX)"; SCRATCH+=("$SE")
M19=$(python3 - "$SE" <<'PY'
import os, sqlite3, subprocess, sys
se = sys.argv[1]
env = dict(os.environ, FLEET_HOME=se)
subprocess.run(["fleet", "init"], env=env, check=True, capture_output=True)
db = os.path.join(se, "fleet.db")
def listing():
    return sorted(f for f in os.listdir(se) if f != "fleet.db")
# Directory enumeration + mtime: no connection held, so the only new files
# are top's own.
before = listing()
m1 = os.stat(db).st_mtime_ns
r = subprocess.run(["fleet", "top", "--once"], env=env, capture_output=True, text=True)
assert r.returncode == 0, r.stderr
m2 = os.stat(db).st_mtime_ns
after = listing()
added = sorted(set(after) - set(before))
assert m1 == m2, (m1, m2)
# exactly the two accepted sidecars, no more, no less: a mode=ro open
# creates -shm (WAL index) and -wal; immutable=1 would suppress both, and
# any other new file is an unenumerated side effect.
assert added == ["fleet.db-shm", "fleet.db-wal"], added
# data_version is unchanged too. A held connection across a second --once
# run: a commit by any connection bumps it, so a write by top would show.
w = sqlite3.connect(db)
v1 = w.execute("PRAGMA data_version").fetchone()[0]
r = subprocess.run(["fleet", "top", "--once"], env=env, capture_output=True, text=True)
assert r.returncode == 0, r.stderr
v2 = w.execute("PRAGMA data_version").fetchone()[0]
w.close()
assert v1 == v2, (v1, v2)
print("ok")
PY
)
if [ "$M19" = ok ]; then
  ok "top --once: only -wal/-shm sidecars, db mtime/data_version unchanged"
else
  no "top --once side-effect enumeration ($M19)"
fi

# 20. A: a FLEET_HOME containing '?' and '#' must not break the ro URI --
#     the path is percent-encoded, so top --once renders instead of dying
#     with "not initialized" (an unencoded URI truncates at '?' and reads
#     '#' as a fragment, so the db path is silently wrong).
WEIRD_BASE="$(mktemp -d /var/tmp/fleet-p9-weird-XXXX)"; SCRATCH+=("$WEIRD_BASE")
WEIRD="$WEIRD_BASE/home?#dir"
mkdir -p "$WEIRD"
M20=$(python3 - "$WEIRD" <<'PY'
import os, subprocess, sys
weird = sys.argv[1]
env = dict(os.environ, FLEET_HOME=weird)
r0 = subprocess.run(["fleet", "init"], env=env, capture_output=True, text=True)
assert r0.returncode == 0, r0.stderr
r = subprocess.run(["fleet", "top", "--once"], env=env, capture_output=True, text=True)
assert r.returncode == 0, (r.returncode, r.stderr)
assert "fleet" in r.stdout, r.stdout[:200]
print("ok")
PY
)
if [ "$M20" = ok ]; then
  ok "FLEET_HOME with ?/#: top --once renders (URI percent-encoded)"
else
  no "FLEET_HOME with ?/# top --once ($M20)"
fi

# 21. project-agnostic: no concrete project names anywhere in the tree.
PAT="${FLEET_FORBIDDEN_NAMES:-Acme""Corp|acme""-internal}"
if grep -rIn -E "$PAT" "$ROOT" --exclude-dir=.git --exclude-dir=docs; then
  no "project-agnostic: no concrete project names"
else
  ok "project-agnostic: no concrete project names"
fi

# 22. JSON is deliberately a one-shot format.
if fleet top --json >"$FLEET_HOME/j22.out" 2>"$FLEET_HOME/j22.err"; then
  no "top --json without --once exits 2"
elif [ "$?" -eq 2 ] && grep -q -- '--json requires --once' "$FLEET_HOME/j22.err"; then
  ok "top --json without --once exits 2"
else
  no "top --json without --once exits 2"
fi

# JSON cases use a small isolated ledger so global counts are exact.
JH="$(mktemp -d /var/tmp/fleet-p9-json-XXXX)"; SCRATCH+=("$JH")
mkdir -p "$JH/a" "$JH/b"
FLEET_HOME="$JH" fleet init >/dev/null
JQ=$(FLEET_HOME="$JH" fleet add "排队任务" --channel shell --cwd "$JH/a" \
  --no-preamble --spec "$FLEET_HOME/spec_true.sh")
JR=$(FLEET_HOME="$JH" fleet add "运行任务" --channel shell --cwd "$JH/b" \
  --no-preamble --spec "$FLEET_HOME/spec_true.sh")
python3 - "$JH/fleet.db" "$JR" <<'PY'
import sqlite3, sys, time
db, tid = sys.argv[1], int(sys.argv[2])
c = sqlite3.connect(db)
c.execute("UPDATE task SET status='running',pid=?,started_at=? WHERE id=?",
          (99999999, int(time.time()) - 300, tid))
c.commit()
PY
FLEET_HOME="$JH" fleet top --once --json >"$JH/all.json"

# 23. Shape, counts and both live task ids.
if python3 -m json.tool "$JH/all.json" >/dev/null && \
   python3 - "$JH/all.json" "$JQ" "$JR" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["counts"]["running"] == 1 and d["counts"]["queued"] == 1
assert {int(sys.argv[2]), int(sys.argv[3])} <= {t["id"] for t in d["tasks"]}
PY
then ok "top JSON parses and reports exact live counts and ids"
else no "top JSON parses and reports exact live counts and ids"
fi

# 24. --cwd scopes the shared row population.
if FLEET_HOME="$JH" fleet top --once --json --cwd "$JH/a" | \
   python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["tasks"]) == 1 and d["tasks"][0]["title"] == "排队任务"'
then ok "top JSON --cwd returns only tasks under that directory"
else no "top JSON --cwd returns only tasks under that directory"
fi

# 25. JSON monitoring cannot mutate the ledger.
before=$(sha256sum "$JH/fleet.db" | awk '{print $1}')
if FLEET_HOME="$JH" fleet top --once --json >/dev/null; then json_ro_ok=1
else json_ro_ok=0
fi
after=$(sha256sum "$JH/fleet.db" | awk '{print $1}')
if [ "$json_ro_ok" -eq 1 ] && [ "$before" = "$after" ]; then ok "top JSON leaves fleet.db byte-identical"
else no "top JSON leaves fleet.db byte-identical"
fi

# 26. A dead wrapper remains visible as the display-layer running? state.
if python3 - "$JH/all.json" "$JR" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert next(t for t in d["tasks"] if t["id"] == int(sys.argv[2]))["status"] == "running?"
PY
then ok "top JSON preserves running? for a dead wrapper"
else no "top JSON preserves running? for a dead wrapper"
fi

# 27. A missing activity directory is the opt-in-off switch.
MISS="$JH/no-such-activity-dir"
if SWITCHBOARD_ACTIVITY_DIR="$MISS" "$ROOT/contrib/publish-activity.py" && [ ! -e "$MISS" ]; then
  ok "publisher does nothing when activity directory is absent"
else no "publisher does nothing when activity directory is absent"
fi

# 28. Existing directory receives a bounded, valid snapshot.
PUB="$JH/activity"
mkdir "$PUB"
if FLEET_HOME="$JH" SWITCHBOARD_ACTIVITY_DIR="$PUB" \
     "$ROOT/contrib/publish-activity.py" </dev/null && \
   python3 - "$PUB/fleet.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
assert d["label"] == "fleet" and isinstance(d["at"], int)
assert isinstance(d["rows"], list) and len(d["rows"]) <= 5
assert os.path.getsize(sys.argv[1]) < 1200
PY
then ok "publisher writes valid bounded fleet activity"
else no "publisher writes valid bounded fleet activity"
fi

# 29. Even a 200-task stdin snapshot stays capped at five rows and 1200 bytes.
rm -f "$PUB/fleet.json"
if python3 - <<'PY' | SWITCHBOARD_ACTIVITY_DIR="$PUB" "$ROOT/contrib/publish-activity.py"
import json
tasks = [{"id": i, "status": "running", "channel": "cursor",
          "idle_s": 300, "stalled": False, "title": "长标题" * 100}
         for i in range(200)]
print(json.dumps({"at": 1756800000,
 "daemon": {"running": True, "pid": 1, "code_stale": False, "stalled_s": None},
 "counts": {"running": 200, "queued": 0, "max_parallel": 16}, "tasks": tasks}))
PY
then publish_many_ok=1
else publish_many_ok=0
fi
if [ "$publish_many_ok" -eq 1 ] && python3 - "$PUB/fleet.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
assert len(d["rows"]) <= 5 and os.path.getsize(sys.argv[1]) < 1200
PY
then ok "publisher caps a 200-task stdin snapshot"
else no "publisher caps a 200-task stdin snapshot"
fi

# NEEDS YOU cases use an isolated ledger so counts and the empty state are exact.
DH="$(mktemp -d /var/tmp/fleet-p9-decisions-XXXX)"; SCRATCH+=("$DH")
FLEET_HOME="$DH" fleet init >/dev/null
for i in $(seq 1 10); do
  FLEET_HOME="$DH" fleet decide "question-$i" --needs-user >/dev/null
done
COLUMNS=80 FLEET_HOME="$DH" fleet top --once >"$DH/ten.out"

# 30. Detail stays capped at three, but the overflow count is the real total.
detail_count=$(grep -c '^NEEDS YOU  decision ' "$DH/ten.out" || true)
if [ "$detail_count" -eq 3 ] && grep -q '^NEEDS YOU  +7 more$' "$DH/ten.out" && \
   ! grep -q '^NEEDS YOU  +1 more$' "$DH/ten.out"; then
  ok "top NEEDS YOU shows three details and the true +7 overflow"
else no "top NEEDS YOU shows three details and the true +7 overflow"
fi

# 31. Exactly three pending decisions need no overflow row.
python3 - "$DH/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("DELETE FROM decision WHERE id > 3")
c.commit()
PY
COLUMNS=80 FLEET_HOME="$DH" fleet top --once >"$DH/three.out"
if [ "$(grep -c '^NEEDS YOU  decision ' "$DH/three.out" || true)" -eq 3 ] && \
   ! grep -q '^NEEDS YOU  +[0-9]' "$DH/three.out"; then
  ok "top NEEDS YOU omits overflow at exactly three decisions"
else no "top NEEDS YOU omits overflow at exactly three decisions"
fi

# 32. A long unspaced CJK question occupies two display-safe lines and clips.
python3 - "$DH/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("DELETE FROM decision"); c.commit()
PY
long_cjk=$(python3 -c 'print("汉" * 300)')
FLEET_HOME="$DH" fleet decide "$long_cjk" --needs-user >/dev/null
COLUMNS=80 FLEET_HOME="$DH" fleet top --once >"$DH/cjk.out"
if python3 - "$DH/cjk.out" <<'PY'
import sys, unicodedata
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
i = next(i for i, line in enumerate(lines) if line.startswith("NEEDS YOU  decision "))
shown = lines[i:i + 2]
def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)
assert len(shown) == 2 and shown[1].startswith(" " * 11) and shown[1].endswith("...")
assert all(width(line) <= 80 for line in shown)
assert all(line.encode("utf-8").decode("utf-8") == line for line in shown)
PY
then ok "top NEEDS YOU wraps long CJK to two display-safe lines"
else no "top NEEDS YOU wraps long CJK to two display-safe lines"
fi

# 33. The full-text hint follows pending decisions and vanishes with them.
if grep -q '^fleet decisions --needs-user  # 看全文$' "$DH/cjk.out"; then hint_present=1
else hint_present=0
fi
python3 - "$DH/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("DELETE FROM decision"); c.commit()
PY
COLUMNS=80 FLEET_HOME="$DH" fleet top --once >"$DH/none.out"
if [ "$hint_present" -eq 1 ] && ! grep -q 'fleet decisions --needs-user' "$DH/none.out"; then
  ok "top NEEDS YOU shows the full-text hint only when pending"
else no "top NEEDS YOU shows the full-text hint only when pending"
fi

# 34. Text monitoring leaves both the database and any WAL byte-identical.
if python3 - "$DH" <<'PY'
import hashlib, os, sqlite3, subprocess, sys
home = sys.argv[1]
db = home + "/fleet.db"
c = sqlite3.connect(db)
c.execute("PRAGMA wal_autocheckpoint=0")
c.execute("UPDATE meta SET v=v WHERE k=(SELECT k FROM meta LIMIT 1)")
c.commit()
paths = (db, db + "-wal")
assert all(os.path.exists(path) for path in paths)
def hashes():
    return [hashlib.sha256(open(path, "rb").read()).hexdigest() for path in paths]
before = hashes()
env = dict(os.environ, FLEET_HOME=home, COLUMNS="80")
r = subprocess.run(["fleet", "top", "--once"], env=env,
                   stdout=subprocess.DEVNULL)
after = hashes()
assert r.returncode == 0 and before == after, (r.returncode, before, after)
c.close()
PY
then
  ok "top NEEDS YOU leaves fleet.db and WAL byte-identical"
else no "top NEEDS YOU leaves fleet.db and WAL byte-identical"
fi

# 35. A group holding both live and finished rows rules them apart: a done row
#     and a running one read alike at a glance, and only the live ones are the
#     commander's problem. The rule sits after the last live row, never before
#     the first row.
SEP_A="$FLEET_HOME/sep-a"
mkdir -p "$SEP_A"
# left queued on purpose: queued is live, and never running it keeps the case
# free of timing.
SA1=$(fleet add "sep live" --channel shell --no-preamble --cwd "$SEP_A" \
        --spec "$FLEET_HOME/spec_hi.sh")
# two finished rows, not one: the boundary is between the groups, so a rule
# per terminal row is the obvious way to get this wrong and one row cannot
# tell the two apart.
for s in "sep ended one" "sep ended two"; do
  SA=$(fleet add "$s" --channel shell --no-preamble --cwd "$SEP_A" \
         --spec "$FLEET_HOME/spec_hi.sh")
  fleet run "$SA" >/dev/null
  wait_status "$SA" done || true
done
COLUMNS=80 fleet top --once --cwd "$SEP_A" > "$FLEET_HOME/sep_a.out"
live_n=$(grep -n "sep live" "$FLEET_HOME/sep_a.out" | cut -d: -f1)
rule_c=$(grep -c -- "── ended " "$FLEET_HOME/sep_a.out")
rule_n=$(grep -n -- "── ended " "$FLEET_HOME/sep_a.out" | head -1 | cut -d: -f1)
end_n=$(grep -n "sep ended one" "$FLEET_HOME/sep_a.out" | cut -d: -f1)
if [ "$rule_c" = "1" ] && [ -n "$live_n" ] && [ -n "$end_n" ] \
   && [ "$live_n" -lt "$rule_n" ] && [ "$rule_n" -lt "$end_n" ]; then
  ok "top draws exactly one rule, between the live rows and the finished ones"
else
  no "top draws one rule between live and finished (live=$live_n rules=$rule_c first=$rule_n ended=$end_n)"
fi

# 36. A group with nothing live gets no rule: a separator with no rows above it
#     reads as a broken header, and the whole point is marking a boundary that
#     actually exists.
SEP_B="$FLEET_HOME/sep-b"
mkdir -p "$SEP_B"
SB1=$(fleet add "sep only ended" --channel shell --no-preamble --cwd "$SEP_B" \
        --spec "$FLEET_HOME/spec_hi.sh")
fleet run "$SB1" >/dev/null
wait_status "$SB1" done || true
COLUMNS=80 fleet top --once --cwd "$SEP_B" > "$FLEET_HOME/sep_b.out"
if grep -q "sep only ended" "$FLEET_HOME/sep_b.out" \
   && ! grep -- "── ended " "$FLEET_HOME/sep_b.out" >/dev/null; then
  ok "top draws no rule in a group whose rows are all finished"
else
  no "top draws no rule in a group whose rows are all finished"
fi

# 37-43. "what is it doing right now" comes from the CLI session log, never
#     from the newest file / process / stdout guess. Each case plants a
#     running ledger row plus (when needed) a fake transcript under a
#     sandbox HOME, so we do not touch the real ~/.claude or ~/.codex.
DOING_LEDGER="$(mktemp -d /var/tmp/fleet-p9-doing-XXXX)"; SCRATCH+=("$DOING_LEDGER")
DOING_HOME="$(mktemp -d /var/tmp/fleet-p9-dhome-XXXX)"; SCRATCH+=("$DOING_HOME")
FLEET_HOME="$DOING_LEDGER" fleet init >/dev/null
python3 - "$DOING_LEDGER/fleet.db" "$DOING_HOME" <<'PY'
import json, os, sqlite3, sys, time
db, home = sys.argv[1], sys.argv[2]
now = int(time.time())

def slug(cwd):
    # Real Claude convention: both '/' and '.' become '-'. The production
    # matcher globs by this suffix; constructing it here is how we plant
    # the fixture, not how top is allowed to look it up.
    return "".join("-" if c in "/." else c for c in os.path.realpath(cwd))

def add(title, cwd, pid):
    os.makedirs(cwd, exist_ok=True)
    c = sqlite3.connect(db)
    cur = c.execute(
        "INSERT INTO task(title,channel,family,status,cwd,created_at,started_at,pid) "
        "VALUES(?,?,?,?,?,?,?,?)",
        (title, "shell", "none", "running", cwd, now, now, pid),
    )
    c.commit()
    tid = cur.lastrowid
    c.close()
    return tid

def write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for row in rows:
            if isinstance(row, str):
                f.write(row)
                if not row.endswith("\n"):
                    f.write("\n")
            else:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")

def claude_msg(tools, usage=None):
    content = []
    for i, spec in enumerate(tools):
        if isinstance(spec, str):
            name, extra = spec, {}
        else:
            name, extra = spec[0], spec[1]
        content.append({"type": "tool_use", "name": name, "id": str(i), "input": extra})
    msg = {"role": "assistant", "content": content, "model": "claude-opus"}
    if usage:
        msg["usage"] = usage
    return {"type": "assistant", "message": msg}

def marker(tid):
    # Real transcripts start with the preamble; ownership matches this
    # byte string, not cwd. Planted so cases 37-42 still bind after the
    # picker stopped treating "newest jsonl in this slug" as identity.
    return {"type": "user", "message": {
        "role": "user",
        "content": f"You are running as fleet task `{tid}`",
    }}

ids = {}
good = os.path.join(home, "good")
bad_root = os.path.join(home, "bad")
os.makedirs(good)
os.makedirs(bad_root)

# 37. Claude: 3 Bash + 1 Task, cwd without a '.' so a slash-only slug
#     still happens to match -- case 41 is the dotted one.
claude_cwd = os.path.join(good, "claude-cwd")
ids["claude"] = add("doing claude", claude_cwd, 91000037)
write_jsonl(
    os.path.join(home, ".claude", "projects", slug(claude_cwd), "sess.jsonl"),
    [
        marker(ids["claude"]),
        claude_msg(["Bash"], {"input_tokens": 100, "output_tokens": 50}),
        claude_msg(["Bash"]),
        claude_msg(
            ["Bash", ("Task", {"description": "go", "subagent_type": "explore"})],
            {"input_tokens": 200, "output_tokens": 80},
        ),
    ],
)

# 38. Codex rollout: two custom_tool_call + token_count, cwd in session_meta.
codex_cwd = os.path.join(good, "codex-cwd")
ids["codex"] = add("doing codex", codex_cwd, 91000038)
day = time.strftime("%Y/%m/%d")
write_jsonl(
    os.path.join(home, ".codex", "sessions", day, "rollout-doing.jsonl"),
    [
        {"payload": {"type": "session_meta", "cwd": os.path.realpath(codex_cwd)}},
        {"payload": {"type": "message", "role": "user",
                     "content": [{"text": f"You are running as fleet task `{ids['codex']}`"}]}},
        {"payload": {"type": "custom_tool_call", "name": "exec"}},
        {"payload": {"type": "custom_tool_call", "name": "exec"}},
        {"payload": {"type": "token_count",
                     "info": {"total_token_usage": {"total_tokens": 12345}}}},
    ],
)

# 39. Running, but no session file at all.
none_cwd = os.path.join(good, "none-cwd")
ids["none"] = add("doing none", none_cwd, 91000039)

# 40. Bad JSON / half line only -- isolated under bad/ so a crash here
#     cannot paint cases 37-39/41-42 red. The preamble string is planted
#     so the unique-owner picker still selects this file; feeding it is
#     what must not crash (and what doing-bad-json-raises mutates).
bad_cwd = os.path.join(bad_root, "bad-cwd")
ids["bad"] = add("doing badjson", bad_cwd, 91000040)
broken = os.path.join(home, ".claude", "projects", slug(bad_cwd), "broken.jsonl")
os.makedirs(os.path.dirname(broken), exist_ok=True)
with open(broken, "w") as f:
    f.write(f"You are running as fleet task `{ids['bad']}`\n")
    f.write("this is not json\n")
    f.write("{not-json-either\n")
    f.write('{"incomplete": true')  # half line, no trailing newline

# 41. cwd contains '.': ~/.fleet/worktrees/task-N style. Unique tool name
#     so a slash-only slug miss is visible even if case 37 still matches.
dot_cwd = os.path.join(good, ".fleet", "worktrees", "task-41")
ids["dot"] = add("doing dotted", dot_cwd, 91000041)
write_jsonl(
    os.path.join(home, ".claude", "projects", slug(dot_cwd), "sess.jsonl"),
    [marker(ids["dot"]), claude_msg(["GlobHit"])],
)

open(os.path.join(home, "ids.json"), "w").write(json.dumps(ids))
PY

doing_env() {
  # HOME sandbox is the only place session files exist; FLEET_HOME is the
  # isolated ledger. COLUMNS keeps the doing line from clipping.
  HOME="$DOING_HOME" FLEET_HOME="$DOING_LEDGER" COLUMNS=200 "$@"
}

doing_env fleet top --once --cwd "$DOING_HOME/good" > "$DOING_LEDGER/doing.out" 2>"$DOING_LEDGER/doing.err"
rc_doing=$?
doing_env fleet top --once --cwd "$DOING_HOME/bad" > "$DOING_LEDGER/doing_bad.out" 2>"$DOING_LEDGER/doing_bad.err"
rc_bad=$?
doing_env fleet top --once --cwd "$DOING_HOME/good" --no-doing > "$DOING_LEDGER/doing_off.out" 2>/dev/null
doing_env fleet top --once --json --cwd "$DOING_HOME/good" > "$DOING_LEDGER/doing.json" 2>/dev/null

line_after() {
  # The doing line is the one immediately under the title row.
  awk -v t="$1" 'index($0, t){getline; print; exit}' "$DOING_LEDGER/doing.out"
}

claude_line=$(line_after "doing claude")
codex_line=$(line_after "doing codex")
none_line=$(line_after "doing none")
bad_line=$(awk -v t="doing badjson" 'index($0, t){getline; print; exit}' "$DOING_LEDGER/doing_bad.out")
dot_line=$(line_after "doing dotted")

if [ "$rc_doing" = 0 ] && printf '%s\n' "$claude_line" | grep -q "Bash ×3" \
   && printf '%s\n' "$claude_line" | grep -q "Task ×1" \
   && printf '%s\n' "$claude_line" | grep -q "subagent"; then
  ok "top session line counts Claude tools and Task subagents"
else
  no "top session line counts Claude tools and Task subagents (rc=$rc_doing line='$claude_line' err=$(head -1 "$DOING_LEDGER/doing.err"))"
fi

if [ "$rc_doing" = 0 ] && printf '%s\n' "$codex_line" | grep -q "exec ×2" \
   && printf '%s\n' "$codex_line" | grep -q "tok"; then
  ok "top session line counts Codex tools and tokens"
else
  no "top session line counts Codex tools and tokens (line='$codex_line')"
fi

if [ "$rc_doing" = 0 ] && grep -q "doing none" "$DOING_LEDGER/doing.out" \
   && ! printf '%s\n' "$none_line" | grep -q "↳" \
   && ! printf '%s\n' "$none_line" | grep -q "×"; then
  ok "top prints no doing line when the task has no session log"
else
  no "top prints no doing line when the task has no session log (line='$none_line')"
fi

if [ "$rc_bad" = 0 ] && ! grep -q Traceback "$DOING_LEDGER/doing_bad.err" \
   && grep -q "doing badjson" "$DOING_LEDGER/doing_bad.out" \
   && ! printf '%s\n' "$bad_line" | grep -q "×"; then
  ok "top survives a bad JSON / half-line session and prints no doing line"
else
  no "top survives a bad JSON / half-line session and prints no doing line (rc=$rc_bad line='$bad_line' err=$(head -1 "$DOING_LEDGER/doing_bad.err"))"
fi

if [ "$rc_doing" = 0 ] && printf '%s\n' "$dot_line" | grep -q "GlobHit ×1"; then
  ok "top matches a Claude project slug when cwd contains a dot"
else
  no "top matches a Claude project slug when cwd contains a dot (line='$dot_line')"
fi

if python3 - "$DOING_LEDGER/doing.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
by = {t["title"]: t for t in d["tasks"]}
c = by["doing claude"]
assert c["doing"] and "Bash" in c["doing"] and "subagent" in c["doing"]
assert c["tools"]["Bash"] == 3 and c["tools"]["Task"] == 1
assert c["subagents"] == 1
assert c["tokens"] == 430
x = by["doing codex"]
assert x["tools"]["exec"] == 2 and x["tokens"] == 12345
n = by["doing none"]
assert n["doing"] is None and n["tools"] is None and n["subagents"] is None
print("ok")
PY
then ok "top JSON exposes tools, subagents and tokens alongside the doing text"
else no "top JSON exposes tools, subagents and tokens alongside the doing text"
fi

if grep -q "doing claude" "$DOING_LEDGER/doing_off.out" \
   && ! grep -q "Bash ×3" "$DOING_LEDGER/doing_off.out" \
   && ! grep -q "GlobHit" "$DOING_LEDGER/doing_off.out"; then
  ok "--no-doing drops the session line and keeps the rows"
else
  no "--no-doing drops the session line and keeps the rows"
fi

# 44-46. Same-cwd concurrent tasks must not inherit each other's session.
#     Appended after 242's doing cases (do not renumber 37-43). Isolated
#     ledger+HOME so a miss here cannot paint 37-43 red.
OWN_LEDGER="$(mktemp -d /var/tmp/fleet-p9-own-XXXX)"; SCRATCH+=("$OWN_LEDGER")
OWN_HOME="$(mktemp -d /var/tmp/fleet-p9-ohome-XXXX)"; SCRATCH+=("$OWN_HOME")
FLEET_HOME="$OWN_LEDGER" fleet init >/dev/null
python3 - "$OWN_LEDGER/fleet.db" "$OWN_HOME" <<'PY'
import json, os, sqlite3, sys, time
db, home = sys.argv[1], sys.argv[2]
now = int(time.time())

def slug(cwd):
    return "".join("-" if c in "/." else c for c in os.path.realpath(cwd))

def add(title, cwd, pid, channel, family):
    os.makedirs(cwd, exist_ok=True)
    c = sqlite3.connect(db)
    cur = c.execute(
        "INSERT INTO task(title,channel,family,status,cwd,created_at,started_at,pid) "
        "VALUES(?,?,?,?,?,?,?,?)",
        (title, channel, family, "running", cwd, now, now, pid),
    )
    c.commit()
    tid = cur.lastrowid
    c.close()
    return tid

def write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

def claude_msg(tools):
    content = [{"type": "tool_use", "name": n, "id": str(i), "input": {}}
               for i, n in enumerate(tools)]
    return {"type": "assistant",
            "message": {"role": "assistant", "content": content}}

def marker(tid):
    return {"type": "user", "message": {
        "role": "user",
        "content": f"You are running as fleet task `{tid}`",
    }}

# 44. Two claude-p tasks, same cwd, two jsonl files with distinct tools
#     and distinct preamble ids. Newest file is twin-b (written last);
#     a cwd-newest picker would paint both rows GlobTwin.
shared = os.path.join(home, "shared")
os.makedirs(shared, exist_ok=True)
tid_a = add("doing twin-a", shared, 91000044, "claude-p", "claude")
tid_b = add("doing twin-b", shared, 91000045, "claude-p", "claude")
proj = os.path.join(home, ".claude", "projects", slug(shared))
write_jsonl(os.path.join(proj, "twin-a.jsonl"),
            [marker(tid_a), claude_msg(["ReadTwin"])])
write_jsonl(os.path.join(proj, "twin-b.jsonl"),
            [marker(tid_b), claude_msg(["GlobTwin"])])

# 45. Same cwd, a session file exists, but neither transcript names a
#     task. Ownership is unclear -- both rows must omit the doing line.
amb = os.path.join(home, "amb")
os.makedirs(amb, exist_ok=True)
add("doing amb-a", amb, 91000046, "claude-p", "claude")
add("doing amb-b", amb, 91000047, "claude-p", "claude")
write_jsonl(
    os.path.join(home, ".claude", "projects", slug(amb), "orphan.jsonl"),
    [claude_msg(["AmbTool"])],
)

# 46. claude-p task, only a Codex rollout in that cwd. Kind veto: do
#     not print run_terminal_command (a Codex tool) on a Claude row.
mis = os.path.join(home, "mis")
os.makedirs(mis, exist_ok=True)
tid_m = add("doing mismatch", mis, 91000048, "claude-p", "claude")
day = time.strftime("%Y/%m/%d")
write_jsonl(
    os.path.join(home, ".codex", "sessions", day, "rollout-mismatch.jsonl"),
    [
        {"payload": {"type": "session_meta", "cwd": os.path.realpath(mis)}},
        {"payload": {"type": "message", "role": "user",
                     "content": [{"text": f"You are running as fleet task `{tid_m}`"}]}},
        {"payload": {"type": "custom_tool_call", "name": "run_terminal_command"}},
        {"payload": {"type": "custom_tool_call", "name": "run_terminal_command"}},
    ],
)
PY

own_env() {
  HOME="$OWN_HOME" FLEET_HOME="$OWN_LEDGER" COLUMNS=200 "$@"
}
own_env fleet top --once --cwd "$OWN_HOME" > "$OWN_LEDGER/own.out" 2>"$OWN_LEDGER/own.err"
rc_own=$?

own_after() {
  awk -v t="$1" 'index($0, t){getline; print; exit}' "$OWN_LEDGER/own.out"
}
twin_a=$(own_after "doing twin-a")
twin_b=$(own_after "doing twin-b")
amb_a=$(own_after "doing amb-a")
amb_b=$(own_after "doing amb-b")
mis_line=$(own_after "doing mismatch")

if [ "$rc_own" = 0 ] && printf '%s\n' "$twin_a" | grep -q "ReadTwin ×1" \
   && ! printf '%s\n' "$twin_a" | grep -q "GlobTwin" \
   && printf '%s\n' "$twin_b" | grep -q "GlobTwin ×1" \
   && ! printf '%s\n' "$twin_b" | grep -q "ReadTwin"; then
  ok "top binds each same-cwd session to its own task, not the newest jsonl"
else
  no "top binds each same-cwd session to its own task, not the newest jsonl (rc=$rc_own a='$twin_a' b='$twin_b' err=$(head -1 "$OWN_LEDGER/own.err"))"
fi

if [ "$rc_own" = 0 ] && grep -q "doing amb-a" "$OWN_LEDGER/own.out" \
   && grep -q "doing amb-b" "$OWN_LEDGER/own.out" \
   && ! printf '%s\n' "$amb_a" | grep -q "↳" \
   && ! printf '%s\n' "$amb_a" | grep -q "×" \
   && ! printf '%s\n' "$amb_a" | grep -q "AmbTool" \
   && ! printf '%s\n' "$amb_b" | grep -q "↳" \
   && ! printf '%s\n' "$amb_b" | grep -q "×" \
   && ! printf '%s\n' "$amb_b" | grep -q "AmbTool"; then
  ok "top omits the doing line when same-cwd session ownership is unclear"
else
  no "top omits the doing line when same-cwd session ownership is unclear (a='$amb_a' b='$amb_b')"
fi

if [ "$rc_own" = 0 ] && grep -q "doing mismatch" "$OWN_LEDGER/own.out" \
   && ! printf '%s\n' "$mis_line" | grep -q "run_terminal_command" \
   && ! printf '%s\n' "$mis_line" | grep -q "↳" \
   && ! printf '%s\n' "$mis_line" | grep -q "×"; then
  ok "top does not attribute a Codex session to a claude-p task"
else
  no "top does not attribute a Codex session to a claude-p task (line='$mis_line')"
fi

# ---------------------------------------------------------------------------
# brief's PROBE line: a model_probe row has no shelf life of its own, and the
# enqueue gate (check_model_probed) only refuses on "the last probe FAILED".
# A day-old `ok` may outlive the available quota, admit a task, and then fail
# without claims. brief is where stale probes get named, so these cases pin the
# line's shape.
#
# The rows are written straight into model_probe rather than by `fleet probe`:
# a real probe spends model quota (this suite is shell-only by contract) and
# cannot produce a timestamp in the past.
probe_rows(){
  # each arg is "channel:hours-ago"; replaces the whole table. A channel may
  # be named twice (one row per model, as a real probe writes).
  local a ch h i=0
  sqlite3 "$FLEET_HOME/fleet.db" "DELETE FROM model_probe"
  for a in "$@"; do
    ch="${a%%:*}"; h="${a##*:}"; i=$((i+1))
    sqlite3 "$FLEET_HOME/fleet.db" \
      "INSERT INTO model_probe(channel,model,ok,checked_at,note)
       VALUES('$ch','m$i-$ch',1,strftime('%s','now') - $h*3600,'ok')"
  done
}

# 41. Fresh records print nothing at all. 11h sits just under the 12h default,
#     so a threshold compared the wrong way round lands here.
probe_rows cursor:11 codex:1 claude-p:0
if ! fleet brief --all | grep -q "^PROBE"; then
  ok "brief: no PROBE line while every probe record is inside the window"
else
  no "brief: no PROBE line while every probe record is inside the window ($(fleet brief --all | grep '^PROBE'))"
fi

# 42. One expired record names the channel, its age, and the command to run.
probe_rows cursor:21 codex:1
p42=$(fleet brief --all | grep "^PROBE" || true)
if printf '%s\n' "$p42" | grep -q "cursor(21h)" \
   && printf '%s\n' "$p42" | grep -q "fleet probe" \
   && ! printf '%s\n' "$p42" | grep -q "codex"; then
  ok "brief: PROBE names the expired channel, its age and the fix"
else
  no "brief: PROBE names the expired channel, its age and the fix ('$p42')"
fi

# 43. Four expired channels: three by name plus a count, like INBOX. The line
#     is a nudge, not a report -- an unbounded list would push the sections
#     under it off a terminal.
probe_rows cursor:21 codex:20 claude-p:19 grok:18
p43=$(fleet brief --all | grep "^PROBE" || true)
if printf '%s\n' "$p43" | grep -q "cursor(21h) codex(20h) claude-p(19h) +1 more" \
   && ! printf '%s\n' "$p43" | grep -q "grok("; then
  ok "brief: PROBE lists 3 channels and folds the rest into +N more"
else
  no "brief: PROBE lists 3 channels and folds the rest into +N more ('$p43')"
fi

# 44. family=none channels (shell) run no model, so no probe of theirs can go
#     stale -- a row for one is fixture residue, not a finding.
probe_rows shell:99 cursor:21
p44=$(fleet brief --all | grep "^PROBE" || true)
if printf '%s\n' "$p44" | grep -q "cursor(21h)" \
   && ! printf '%s\n' "$p44" | grep -q "shell"; then
  ok "brief: PROBE skips family=none channels, which run no model"
else
  no "brief: PROBE skips family=none channels, which run no model ('$p44')"
fi

# 45. FLEET_PROBE_STALE_H moves the threshold (env only, no CLI flag: the
#     shelf life is a property of the record, not of one invocation).
probe_rows cursor:2
p45a=$(FLEET_PROBE_STALE_H=1 fleet brief --all | grep "^PROBE" || true)
p45b=$(FLEET_PROBE_STALE_H=48 fleet brief --all | grep "^PROBE" || true)
if printf '%s\n' "$p45a" | grep -q "cursor(2h)" && [ -z "$p45b" ]; then
  ok "brief: FLEET_PROBE_STALE_H overrides the 12h default both ways"
else
  no "brief: FLEET_PROBE_STALE_H overrides the default (h=1:'$p45a' h=48:'$p45b')"
fi

# 46. A channel carries one row per model; `fleet probe <channel>` rewrites
#     them all in one pass, so only the newest one dates the channel. An old
#     row left behind by a model that has since been dropped from the registry
#     would otherwise report a channel probed minutes ago as stale.
probe_rows cursor:99 cursor:1
if ! fleet brief --all | grep -q "^PROBE"; then
  ok "brief: PROBE dates a channel by its newest row, not its oldest"
else
  no "brief: PROBE dates a channel by its newest row ($(fleet brief --all | grep '^PROBE'))"
fi

# 47. The enqueue gate is deliberately NOT taught about staleness: probing for
#     real at enqueue costs a round trip and a slice of the quota being spent,
#     and stale-but-ok is absence of evidence, not evidence of failure. An
#     expired ok must still enqueue; only a FAILED record is refused. Both
#     halves are asserted, or "it enqueued" would prove nothing about the gate
#     being wired up at all.
probe_rows cursor:99
sqlite3 "$FLEET_HOME/fleet.db" \
  "UPDATE model_probe SET model='claude-opus-5-thinking-max' WHERE channel='cursor'"
T46=$(fleet add "p9 stale enqueue" --channel cursor --no-preamble \
        --spec "$FLEET_HOME/spec_true.sh" 2>&1) && rc46=0 || rc46=$?
sqlite3 "$FLEET_HOME/fleet.db" "UPDATE model_probe SET ok=0, note='quota' WHERE channel='cursor'"
T46b=$(fleet add "p9 failed enqueue" --channel cursor --no-preamble \
         --spec "$FLEET_HOME/spec_true.sh" 2>&1) && rc46b=0 || rc46b=$?
if [ "$rc46" = 0 ] && [ "$rc46b" != 0 ] \
   && printf '%s\n' "$T46b" | grep -q "failed its last probe"; then
  ok "enqueue refuses a failed probe and ignores a merely expired one"
else
  no "enqueue refuses a failed probe and ignores a merely expired one (stale rc=$rc46 '$T46'; failed rc=$rc46b '$T46b')"
fi
fleet cancel "$T46" >/dev/null 2>&1 || true
sqlite3 "$FLEET_HOME/fleet.db" "DELETE FROM model_probe"

# 48. `fleet top` must stay in curses watch mode on a terminfo entry that lacks
#     civis (hide-cursor). switchboard's web pty hardcodes TERM=xterm-color,
#     where curs_set(0) returns ERR; unguarded, that error escaped _top_curses,
#     cmd_top's `except curses.error` caught it, and the TUI silently degraded
#     to a single plain-text screen -- indistinguishable from `--once`, and the
#     user only sees "it printed once". Both a civis-less and a civis-bearing
#     entry are asserted, so a "fix" that skips curses everywhere cannot pass.
top_pty_alive(){
  TERM="$1" python3 - "$ROOT/bin/fleet" <<'PYEOF'
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], ["fleet", "top", "--interval", "1"])
t0 = time.time()
while time.time() - t0 < 2.0:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            if not os.read(fd, 65536):
                break
        except OSError:
            break
alive = os.waitpid(pid, os.WNOHANG) == (0, 0)
if alive:
    os.kill(pid, 9)
    os.waitpid(pid, 0)
sys.exit(0 if alive else 1)
PYEOF
}
if ! infocmp xterm-color >/dev/null 2>&1; then
  ok "top watch mode vs civis-less terminfo (no xterm-color entry here)"
else
  top_pty_alive xterm-color    && A48=1 || A48=0
  top_pty_alive xterm-256color && B48=1 || B48=0
  if [ "$A48" = 1 ] && [ "$B48" = 1 ]; then
    ok "top stays in watch mode on a terminfo entry without civis"
  else
    no "top stays in watch mode on a terminfo entry without civis (xterm-color alive=$A48, xterm-256color alive=$B48)"
  fi
fi

# 49. TOOK is runtime, IDLE is silence. They are trivially confusable -- on a
#     just-finished task both read the same -- so the fixture pulls them apart:
#     a row that ran for ~2h and exited 1m ago must show TOOK=1h59m, IDLE=1m.
#     Asserting only one of them, or asserting on a fresh task, would let an
#     implementation that simply re-prints idle pass. A queued row never
#     started, so it has no runtime at all and must say so rather than "0s".
T49=$(fleet add "p9 took ran long" --channel shell --no-preamble \
        --spec "$FLEET_HOME/spec_true.sh")
T49Q=$(fleet add "p9 took never ran" --channel shell --no-preamble \
         --spec "$FLEET_HOME/spec_true.sh")
sqlite3 "$FLEET_HOME/fleet.db" "
  UPDATE task SET status='done', started_at=strftime('%s','now')-7200,
                  ended_at=strftime('%s','now')-60 WHERE id=$T49;
  UPDATE task SET status='queued', started_at=NULL, ended_at=NULL WHERE id=$T49Q;"
j49=$(fleet top --once --json)
t49=$(printf '%s' "$j49" | python3 -c "
import json,sys
d={t['id']: t for t in json.load(sys.stdin)['tasks']}
r=d.get($T49, {}); q=d.get($T49Q, {})
print(r.get('took_s'), r.get('idle_s'), q.get('took_s', 'MISSING'))")
txt49=$(fleet top --once | grep -E "^$T49 " || true)
hdr49=$(fleet top --once | grep -c "TOOK" || true)
# took_s within a second of 7140 (the fixture races the clock by <1s), idle
# unset for a terminal row, queued task's runtime null, and the human column
# rendered as 1h59m -- not 0s, not the idle value.
if printf '%s' "$t49" | grep -qE "^(713[89]|714[01]) None None$" \
   && [ "$hdr49" != 0 ] && printf '%s' "$txt49" | grep -q "1h59m"; then
  ok "top: TOOK reports runtime, distinct from IDLE, absent for a queued row"
else
  no "top: TOOK reports runtime, distinct from IDLE, absent for a queued row (json='$t49' hdr=$hdr49 row='$txt49')"
fi
fleet cancel "$T49Q" >/dev/null 2>&1 || true
sqlite3 "$FLEET_HOME/fleet.db" "DELETE FROM task WHERE id IN ($T49, $T49Q)"

# 56. Claude adapters write below the OAuth or credential-free API config
# home. Keep reading the legacy user directory too, but prove both relocated
# paths are first-class doing sources rather than silently blanking the monitor.
RELOC_LEDGER="$(mktemp -d /var/tmp/fleet-p9-reloc-XXXX)"; SCRATCH+=("$RELOC_LEDGER")
RELOC_HOME="$(mktemp -d /var/tmp/fleet-p9-rhome-XXXX)"; SCRATCH+=("$RELOC_HOME")
FLEET_HOME="$RELOC_LEDGER" fleet init >/dev/null
RELOC_ID=$(python3 - "$RELOC_LEDGER/fleet.db" "$RELOC_LEDGER" <<'PY'
import json, os, sqlite3, sys, time
db, fleet_home = sys.argv[1:]
cwd = os.path.join(fleet_home, "worktrees", "task-5000")
os.makedirs(cwd)
conn = sqlite3.connect(db)
cur = conn.execute(
    "INSERT INTO task(title,channel,family,status,cwd,worktree,created_at,started_at,pid) "
    "VALUES(?,?,?,?,?,?,?,?,?)",
    ("doing relocated claude", "claude-p", "claude", "running", cwd, cwd,
     int(time.time()), int(time.time()), 91000050),
)
tid = cur.lastrowid
conn.commit()
slug = "".join("-" if c in "/." else c for c in os.path.realpath(cwd))
project = os.path.join(fleet_home, "claude-home", "projects", slug)
os.makedirs(project)
rows = [
    {"type": "user", "cwd": cwd, "message": {"role": "user",
     "content": f"You are running as fleet task `{tid}`"}},
    {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "name": "RelocatedRead", "id": "1", "input": {}}
    ]}},
]
with open(os.path.join(project, "relocated.jsonl"), "w") as out:
    for row in rows:
        out.write(json.dumps(row) + "\n")
print(tid)
PY
)
reloc_out=$(HOME="$RELOC_HOME" FLEET_HOME="$RELOC_LEDGER" COLUMNS=200 \
  fleet top --once --cwd "$RELOC_LEDGER/worktrees/task-5000")
reloc_line=$(printf '%s\n' "$reloc_out" | \
  awk 'index($0, "doing relocated claude"){getline; print; exit}')
if printf '%s\n' "$reloc_line" | grep -q "RelocatedRead ×1"; then
  ok "top reads Claude doing data from relocated CLAUDE_CONFIG_DIR"
else
  no "top reads Claude doing data from relocated CLAUDE_CONFIG_DIR (task=$RELOC_ID line='$reloc_line')"
fi

API_ID=$(python3 - "$RELOC_LEDGER/fleet.db" "$RELOC_LEDGER" <<'PY'
import json, os, sqlite3, sys, time
db, fleet_home = sys.argv[1:]
cwd = os.path.join(fleet_home, "worktrees", "task-5001")
os.makedirs(cwd)
conn = sqlite3.connect(db)
cur = conn.execute(
    "INSERT INTO task(title,channel,family,status,cwd,worktree,created_at,started_at,pid) "
    "VALUES(?,?,?,?,?,?,?,?,?)",
    ("doing relocated API", "magpie", "claude", "running", cwd, cwd,
     int(time.time()), int(time.time()), 91000051),
)
tid = cur.lastrowid
conn.commit()
slug = "".join("-" if c in "/." else c for c in os.path.realpath(cwd))
project = os.path.join(fleet_home, "claude-api-home", "projects", slug)
os.makedirs(project)
rows = [
    {"type": "user", "cwd": cwd, "message": {"role": "user",
     "content": f"You are running as fleet task `{tid}`"}},
    {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "name": "ApiRead", "id": "1", "input": {}}
    ]}},
]
with open(os.path.join(project, "relocated.jsonl"), "w") as out:
    for row in rows:
        out.write(json.dumps(row) + "\n")
print(tid)
PY
)
api_reloc_out=$(HOME="$RELOC_HOME" FLEET_HOME="$RELOC_LEDGER" COLUMNS=200 \
  fleet top --once --cwd "$RELOC_LEDGER/worktrees/task-5001")
api_reloc_line=$(printf '%s\n' "$api_reloc_out" | \
  awk 'index($0, "doing relocated API"){getline; print; exit}')
if printf '%s\n' "$api_reloc_line" | grep -q "ApiRead ×1"; then
  ok "top reads Claude doing data from credential-free API config home"
else
  no "top misses credential-free API doing data (task=$API_ID line='$api_reloc_line')"
fi

echo "---"
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = 0 ]
