#!/usr/bin/env bash
# fleet P10 smoke tests: TMPDIR namespaced by FLEET_HOME (parallelization
# prerequisite), run-all.sh + mutate.sh --jobs/--check-only, schema-behind
# refusal (exit 11, no traceback; columns after the first on a line too),
# die()-cannot-kill-daemon (unknown channel in rules), crash-loop visibility
# (daemon.poll_error events + stalled status/brief), pid-NULL orphan reaping
# + lease-leak fixes, launch() rollback on non-OSError spawn failures, and
# claim_refuted escalation when the fix channel is gone.
# Zero model quota: shell channel only.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p10-test-XXXX)"
export PATH="$ROOT/bin:$PATH"
# A parent fleet process may leak its internal lock fd into this suite's
# environment; `fleet daemon start` would then "inherit" a stale fd and fail
# to acquire the lock. Tests run in a clean environment, so drop it.
unset _FLEET_LOCK_FD

PASS=0
FAIL=0
N=0

ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }

field(){ fleet show "$1" | awk -v f="$2" '$1==f":"{print $2}'; }

SCRATCH=()
cleanup(){ fleet daemon stop >/dev/null 2>&1 || true; rm -rf "$FLEET_HOME" "${SCRATCH[@]}"; }
trap cleanup EXIT

fleet init >/dev/null
printf 'echo "$TMPDIR"\n'  > "$FLEET_HOME/spec_tmpdir.sh"
printf 'echo hi\n'         > "$FLEET_HOME/spec_echo.sh"

# 1. TMPDIR is namespaced by FLEET_HOME: task 1 in two different ledgers
#    must get different scratch dirs (pre-P10 both were /var/tmp/fleet/1).
H1="$(mktemp -d /var/tmp/fleet-p10-h1-XXXX)"; SCRATCH+=("$H1")
H2="$(mktemp -d /var/tmp/fleet-p10-h2-XXXX)"; SCRATCH+=("$H2")
FLEET_HOME="$H1" fleet init >/dev/null
FLEET_HOME="$H2" fleet init >/dev/null
A1=$(FLEET_HOME="$H1" fleet add "a1" --channel shell --spec "$FLEET_HOME/spec_tmpdir.sh")
A2=$(FLEET_HOME="$H2" fleet add "a2" --channel shell --spec "$FLEET_HOME/spec_tmpdir.sh")
FLEET_HOME="$H1" fleet run "$A1" >/dev/null
FLEET_HOME="$H2" fleet run "$A2" >/dev/null
sleep 1
D1=$(FLEET_HOME="$H1" fleet digest "$A1" | tr -d '\n')
D2=$(FLEET_HOME="$H2" fleet digest "$A2" | tr -d '\n')
exp1="/var/tmp/fleet/$(python3 -c 'import hashlib;print(hashlib.sha256(b"'"$H1"'").hexdigest()[:12])')/$A1/attempt-1"
exp2="/var/tmp/fleet/$(python3 -c 'import hashlib;print(hashlib.sha256(b"'"$H2"'").hexdigest()[:12])')/$A2/attempt-1"
if [ "$A1" = "$A2" ] && [ "$D1" = "$exp1" ] && [ "$D2" = "$exp2" ] && [ "$D1" != "$D2" ]; then
  ok "TMPDIR namespaced by FLEET_HOME: same task id, different ledgers"
else
  no "TMPDIR namespaced by FLEET_HOME (ids=$A1/$A2 d1=$D1 d2=$D2 exp1=$exp1 exp2=$exp2)"
fi

# 2. run-all.sh: --jobs 4 and --jobs 1 produce the same sorted summary.
#    Mechanics only, on stub suites in a fake repo (running the real suites
#    here would recurse: p10_smoke is one of them).
FAKE="$FLEET_HOME/fake"
mkdir -p "$FAKE/tests"
cp "$ROOT/tests/run-all.sh" "$FAKE/tests/"
for s in aaa bbb ccc; do
  cat > "$FAKE/tests/${s}_smoke.sh" <<EOF
#!/usr/bin/env bash
echo "ok 1 - $s"; echo "---"; echo "passed 1 / 1"
EOF
done
r4=$(bash "$FAKE/tests/run-all.sh" --jobs 4); rc4=$?
r1=$(bash "$FAKE/tests/run-all.sh" --jobs 1); rc1=$?
if [ "$rc4" = "0" ] && [ "$rc1" = "0" ] && [ "$r4" = "$r1" ] \
   && [ "$(printf '%s\n' "$r4" | wc -l | tr -d ' ')" = "6" ] \
   && printf '%s\n' "$r4" | grep -q "py-default/aaa_smoke passed 1 / 1" \
   && printf '%s\n' "$r4" | grep -q "py3.14/aaa_smoke passed 1 / 1" \
   && printf '%s\n' "$r4" | head -1 | grep -q "py-default/aaa_smoke"; then
  ok "run-all.sh --jobs 4 == --jobs 1, sorted summary, all pass"
else
  no "run-all.sh --jobs 4 == --jobs 1 (rc4=$rc4 rc1=$rc1 r4='$r4')"
fi

# 3. run-all.sh: one failing suite fails the whole run and lists the red case.
cat > "$FAKE/tests/ccc_smoke.sh" <<'EOF'
#!/usr/bin/env bash
echo "not ok 1 - ccc boom"; echo "---"; echo "passed 0 / 1"; exit 1
EOF
r3=$(bash "$FAKE/tests/run-all.sh" --jobs 4 2>&1); rc3=$?
if [ "$rc3" != "0" ] && printf '%s\n' "$r3" | grep -q "ccc_smoke FAILED" \
   && printf '%s\n' "$r3" | grep -q "not ok 1 - ccc boom"; then
  ok "run-all.sh: failing suite fails the run, red case listed"
else
  no "run-all.sh: failing suite fails the run (rc=$rc3 out='$r3')"
fi

# 4. mutate.sh --check-only: every mutation in the real manifest still matches.
if "$ROOT/tests/mutate.sh" --check-only >"$FLEET_HOME/check.out" 2>&1; then
  if grep -q "APPLIES" "$FLEET_HOME/check.out" && ! grep -q "INERT" "$FLEET_HOME/check.out"; then
    ok "mutate.sh --check-only: real manifest all APPLIES"
  else
    no "mutate.sh --check-only: real manifest all APPLIES ($(cat "$FLEET_HOME/check.out"))"
  fi
else
  no "mutate.sh --check-only: real manifest all APPLIES (rc=$?)"
fi

# 5. mutate.sh --check-only: a sed that matches nothing is INERT, non-zero exit.
printf 'bogus\tbin/fleet\ts|this-string-does-not-exist-anywhere-xyz|x|\tsmoke\t1\n' \
  > "$FLEET_HOME/bogus.tsv"
if FLEET_MUTATIONS="$FLEET_HOME/bogus.tsv" "$ROOT/tests/mutate.sh" --check-only \
     >"$FLEET_HOME/bogus.out" 2>&1; then
  no "mutate.sh --check-only: bogus mutation is INERT (rc=0)"
elif grep -q "bogus  INERT" "$FLEET_HOME/bogus.out"; then
  ok "mutate.sh --check-only: bogus mutation reported INERT, non-zero exit"
else
  no "mutate.sh --check-only: bogus mutation reported INERT ($(cat "$FLEET_HOME/bogus.out"))"
fi

# 6. schema behind: a ledger missing goal.context gets one actionable line and
#    exit 11 (no traceback); `fleet init` (idempotent) makes the command work.
OLD="$(mktemp -d /var/tmp/fleet-p10-old-XXXX)"; SCRATCH+=("$OLD")
FLEET_HOME="$OLD" fleet init >/dev/null
python3 - "$OLD/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
# Rebuild goal the way a pre-P8 ledger really looked: PK kept, no context
# column (a CTAS rebuild would drop the PK and break FKs from task).
c.execute("""CREATE TABLE goal_old(
  id INTEGER PRIMARY KEY, statement TEXT NOT NULL, acceptance TEXT,
  approval_gates TEXT, budget_cap INTEGER,
  status TEXT NOT NULL DEFAULT 'open',
  created_by TEXT DEFAULT 'user', created_at INTEGER NOT NULL)""")
c.execute("INSERT INTO goal_old SELECT id,statement,acceptance,approval_gates,"
          "budget_cap,status,created_by,created_at FROM goal")
c.execute("DROP TABLE goal")
c.execute("ALTER TABLE goal_old RENAME TO goal")
c.commit()
PY
FLEET_HOME="$OLD" fleet goal add "behind" 2>"$FLEET_HOME/old.err"
rc6=$?
FLEET_HOME="$OLD" fleet init >/dev/null 2>&1
G6=$(FLEET_HOME="$OLD" fleet goal add "fixed")
if [ "$rc6" = "11" ] \
   && grep -qF "ledger schema is behind this build; run \`fleet init\` (idempotent)" "$FLEET_HOME/old.err" \
   && ! grep -q "Traceback" "$FLEET_HOME/old.err" \
   && [ -n "$G6" ]; then
  ok "schema behind: exit 11 + one-line hint, no traceback; init fixes"
else
  no "schema behind: exit 11 + hint, init fixes (rc=$rc6 err=$(cat "$FLEET_HOME/old.err") g6=$G6)"
fi

# 7. any other sqlite failure reaching the top is one human line, exit 12,
#    never a traceback.
CORRUPT="$(mktemp -d /var/tmp/fleet-p10-corrupt-XXXX)"; SCRATCH+=("$CORRUPT")
FLEET_HOME="$CORRUPT" fleet init >/dev/null
printf 'this is not a database' > "$CORRUPT/fleet.db"
FLEET_HOME="$CORRUPT" fleet status 2>"$FLEET_HOME/corrupt.err"
rc7=$?
if [ "$rc7" = "12" ] \
   && grep -q "fleet: database error:" "$FLEET_HOME/corrupt.err" \
   && [ "$(wc -l < "$FLEET_HOME/corrupt.err")" = "1" ] \
   && ! grep -q "Traceback" "$FLEET_HOME/corrupt.err"; then
  ok "sqlite failure at top: one line, exit 12, no traceback"
else
  no "sqlite failure at top: one line, exit 12 (rc=$rc7 err=$(cat "$FLEET_HOME/corrupt.err"))"
fi

# 8. plan set refuses a rule whose with.channel names no channel (exit 10).
G8=$(fleet goal add "g8")
cat > "$FLEET_HOME/rules8.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"nope"}}]
EOF
fleet plan set "$G8" --rules "$FLEET_HOME/rules8.json" --rationale x 2>"$FLEET_HOME/p8.err"
rc8=$?
if [ "$rc8" = "10" ] && grep -q "unknown channel 'nope'" "$FLEET_HOME/p8.err"; then
  ok "plan set: unknown with.channel refused with exit 10"
else
  no "plan set: unknown with.channel refused with exit 10 (rc=$rc8 err=$(cat "$FLEET_HOME/p8.err"))"
fi

# 9. a bad-channel rule that bypassed validation (written straight into the
#    plan table) must NOT kill the daemon: the round completes, a needs-user
#    decision is written, no review task is born.
G9=$(fleet goal add "g9")
T9=$(fleet add "r9 task" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --goal "$G9")
python3 - "$FLEET_HOME/fleet.db" "$T9" "$G9" <<'PY'
import sqlite3, sys, time
db, t, g = sys.argv[1:]
c = sqlite3.connect(db)
c.execute("UPDATE task SET status='done' WHERE id=?", (t,))
c.execute("INSERT INTO plan(goal_id,revision,rules,rationale,created_at) "
          "VALUES(?,?,?,?,?)",
          (g, 1, '[{"on":"task_done","do":"enqueue_review",'
           '"with":{"channel":"nope"}}]', "bypassed", int(time.time())))
c.commit()
PY
fleet daemon run --once >"$FLEET_HOME/d9.out" 2>&1
rc9=$?
M9=$(python3 - "$FLEET_HOME/fleet.db" "$G9" "$T9" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
g, t = sys.argv[2:]
d = c.execute("SELECT COUNT(*) FROM decision WHERE goal_id=? AND needs_user=1",
              (g,)).fetchone()[0]
rv = c.execute("SELECT COUNT(*) FROM task WHERE review_of=?", (t,)).fetchone()[0]
print(f"d={d} rv={rv}")
PY
)
if [ "$rc9" = "0" ] && [ "$M9" = "d=1 rv=0" ] \
   && ! grep -q "Traceback" "$FLEET_HOME/d9.out"; then
  ok "bad-channel rule: daemon survives, decision written, no review task"
else
  no "bad-channel rule: daemon survives, decision written (rc=$rc9 $M9)"
fi

# 10-12. crash-loop visibility: a broken channels.json crashes every poll;
#    the daemon must record daemon.poll_error events, `daemon status` must
#    show stalled with a non-zero exit, and `fleet brief` must say so too.
fleet daemon start --interval 1 >/dev/null
sleep 2
echo '{broken json' > "$FLEET_HOME/channels.json"
sleep 5
st10=$(fleet daemon status 2>&1); rc10=$?
b10=$(fleet brief | head -1)
ev10=$(python3 - "$FLEET_HOME/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("SELECT COUNT(*) FROM event WHERE kind='daemon.poll_error'"
                ).fetchone()[0])
PY
)
if [ "$rc10" != "0" ] && printf '%s\n' "$st10" | grep -q "stalled: last successful poll" \
   && printf '%s\n' "$b10" | grep -q "stalled: last successful poll" \
   && [ "$ev10" -ge 1 ]; then
  ok "crash loop: poll_error event, stalled status (non-zero) and brief"
else
  no "crash loop: poll_error event, stalled status (rc=$rc10 ev=$ev10 st='$st10' brief='$b10')"
fi

# 11. dedup: the same crash every second must not flood the event stream --
#     first occurrence plus every 10th, so after ~12 crashed rounds there
#     are at most a handful of events.
sleep 8
ev11=$(python3 - "$FLEET_HOME/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("SELECT COUNT(*) FROM event WHERE kind='daemon.poll_error'"
                ).fetchone()[0])
PY
)
if [ "$ev11" -ge 1 ] && [ "$ev11" -le 3 ]; then
  ok "poll_error dedup: $ev11 event(s) for a persistent crash, not a flood"
else
  no "poll_error dedup: $ev11 events for a persistent crash"
fi

# 12. recovery: fix channels.json, the daemon polls again, status is healthy.
cp "$ROOT/channels.json" "$FLEET_HOME/channels.json"
sleep 3
fleet daemon status >/dev/null 2>&1
rc12=$?
if [ "$rc12" = "0" ]; then
  ok "recovery: status healthy after channels.json fixed"
else
  no "recovery: status healthy after channels.json fixed (rc=$rc12)"
fi
fleet daemon stop >/dev/null

# 13. pid-NULL orphan: a 'running' task whose pid was never recorded (launch
#     crashed between the 'running' stamp and the pid write) is reaped past
#     the grace window, and its lease is released.
T13=$(fleet add "orph13" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --lease res13)
python3 - "$FLEET_HOME/fleet.db" "$T13" <<'PY'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
t = sys.argv[2]
c.execute("UPDATE task SET status='running', started_at=?, pid=NULL WHERE id=?",
          (int(time.time()) - 100, t))
c.execute("INSERT INTO lease(resource,holder,acquired_at,expires_at) "
          "VALUES(?,?,?,NULL)", ("res13", t, int(time.time())))
c.commit()
PY
FLEET_ORPHAN_GRACE_S=1 fleet status --all >/dev/null
st13=$(field "$T13" status)
lk13=$(fleet lease list | grep -c res13 || true)
ev13=$(fleet since --raw 0 | grep -c "task.orphaned" || true)
if [ "$st13" = "queued" ] && [ "$lk13" = "0" ] && [ "$ev13" -ge 1 ]; then
  ok "pid-NULL orphan reaped past grace, lease released, event logged"
else
  no "pid-NULL orphan reaped (st=$st13 lease=$lk13 ev=$ev13)"
fi

# 14. spawn failure after the 'running' stamp: the task must not stay running
#     and its lease must not leak.
T14=$(fleet add "lf14" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --lease res14)
FLEET_LAUNCH_FAIL=1 fleet run "$T14" >"$FLEET_HOME/lf14.out" 2>"$FLEET_HOME/lf14.err"
rc14=$?
st14=$(field "$T14" status)
lk14=$(fleet lease list | grep -c res14 || true)
if [ "$rc14" != "0" ] && [ "$st14" = "queued" ] && [ "$lk14" = "0" ] \
   && grep -q "simulated spawn failure" "$FLEET_HOME/lf14.err" \
   && ! grep -q "Traceback" "$FLEET_HOME/lf14.err"; then
  ok "spawn failure: task requeued, lease released, clean one-line error"
else
  no "spawn failure: task requeued, lease released (rc=$rc14 st=$st14 lease=$lk14 err=$(cat "$FLEET_HOME/lf14.err"))"
fi

# 15. schema check covers columns declared after the first on a line:
#     `worktree TEXT, worktree_branch TEXT,` shares a line in schema.sql, and
#     the old line-first-token parser never saw worktree_branch -- a ledger
#     missing it passed `fleet status` (rc0) and died later with rc12 on
#     `fleet add --worktree` instead of the schema-behind rc11.
OLD15="$(mktemp -d /var/tmp/fleet-p10-old15-XXXX)"; SCRATCH+=("$OLD15")
FLEET_HOME="$OLD15" fleet init >/dev/null
python3 - "$OLD15/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
# Rebuild task without worktree_branch. This raw connection has foreign_keys
# off, and a fresh ledger has no rows referencing task, so DROP is safe; CTAS
# keeps the data and the remaining columns.
cols = [r[1] for r in c.execute("PRAGMA table_info(task)")
        if r[1] != "worktree_branch"]
c.execute(f"CREATE TABLE task_old AS SELECT {','.join(cols)} FROM task")
c.execute("DROP TABLE task")
c.execute("ALTER TABLE task_old RENAME TO task")
c.commit()
PY
FLEET_HOME="$OLD15" fleet status --all 2>"$FLEET_HOME/old15.err"
rc15=$?
if [ "$rc15" = "11" ] \
   && grep -qF "ledger schema is behind this build; run \`fleet init\` (idempotent)" "$FLEET_HOME/old15.err" \
   && ! grep -q "Traceback" "$FLEET_HOME/old15.err"; then
  ok "schema behind: a non-first column on a line is checked too (rc11)"
else
  no "schema behind: non-first column checked (rc=$rc15 err=$(cat "$FLEET_HOME/old15.err"))"
fi

# 16. spawn failure that is NOT an OSError: Popen raises ValueError for a bad
#     argv (embedded null byte). launch() must roll back status/started_at/
#     budget for ANY spawn failure -- the old OSError-only handler left a
#     zombie 'running' row and a debited budget.
T16=$(fleet add "vf16" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --lease res16)
# PYTHONDONTWRITEBYTECODE: importing bin/fleet must not leave a __pycache__
# next to the source (the suite runs against the real repo, not a temp copy).
M16=$(PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/bin/fleet" "$T16" "$FLEET_HOME" <<'PY'
from importlib.machinery import SourceFileLoader
import importlib.util
import os, sqlite3, sys
loader = SourceFileLoader("fleet_under_test", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
fleet = importlib.util.module_from_spec(spec); loader.exec_module(fleet)
tid = int(sys.argv[2])
conn = fleet.db_connect()
t = conn.execute("SELECT * FROM task WHERE id=?", (tid,)).fetchone()
chans = fleet.load_channels()
ch = chans["channels"][t["channel"]]
class FakePopen:
    def __init__(self, *a, **kw):
        raise ValueError("embedded null byte")
fleet.subprocess.Popen = FakePopen
raised = ""
try:
    fleet.try_start(conn, t, ch, explicit=True)
except ValueError as e:
    raised = str(e)
db = sqlite3.connect(os.path.join(sys.argv[3], "fleet.db"))
st, started = db.execute(
    "SELECT status, started_at FROM task WHERE id=?", (tid,)).fetchone()
used = db.execute(
    "SELECT used FROM budget WHERE channel=? AND period=?",
    (t["channel"], fleet.period_now())).fetchone()
lease = db.execute(
    "SELECT COUNT(*) FROM lease WHERE resource=? AND holder=?",
    (t["lease"], str(tid))).fetchone()[0]
ok = (raised == "embedded null byte" and st == "queued" and started is None
      and used is not None and used[0] == 0 and lease == 0)
print("ok" if ok else
      f"bad raised={raised!r} st={st} started={started} used={used} lease={lease}")
PY
)
if [ "$M16" = "ok" ]; then
  ok "non-OSError spawn failure: requeued, no budget debit, lease released"
else
  no "non-OSError spawn failure ($M16)"
fi

# 17. claim_refuted rule whose fix channel is gone: the daemon must not die
#     and must write a needs-user decision plus a rule.error event -- the old
#     path silently continued: no fix, no decision, no event.
G17=$(fleet goal add "g17")
T17=$(fleet add "refuted task" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --goal "$G17")
python3 - "$FLEET_HOME/fleet.db" "$T17" <<'PY'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO claim(task_id,claim,evidence,status,ts) VALUES(?,?,?,?,?)",
          (sys.argv[2], "claim-17", "ev-17 file:1", "refuted", int(time.time())))
c.commit()
PY
cat > "$FLEET_HOME/rules17.json" <<'EOF'
[{"on":"claim_refuted","do":"enqueue_fix"}]
EOF
fleet plan set "$G17" --rules "$FLEET_HOME/rules17.json" --rationale "auto fix" >/dev/null
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
del d["channels"]["shell"]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
# Sweep non-terminal tasks so start_ready has nothing to trip over once the
# shell channel is gone (the claim_refuted query itself ignores task status).
fleet --json status --all | python3 -c '
import json, subprocess, sys
for r in json.load(sys.stdin):
    if r["status"] not in ("done","failed","cancelled"):
        subprocess.run(["fleet","cancel",str(r["id"])],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)'
fleet daemon run --once >"$FLEET_HOME/d17.out" 2>&1
rc17=$?
M17=$(python3 - "$FLEET_HOME/fleet.db" "$G17" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
g = sys.argv[2]
d = c.execute("SELECT COUNT(*) FROM decision WHERE goal_id=? AND needs_user=1",
              (g,)).fetchone()[0]
fx = c.execute("SELECT COUNT(*) FROM task WHERE title LIKE 'fix:%' AND goal_id=?",
               (g,)).fetchone()[0]
ev = c.execute("SELECT COUNT(*) FROM event WHERE kind='rule.error' AND goal_id=?",
               (g,)).fetchone()[0]
print(f"d={d} fx={fx} ev={ev}")
PY
)
cp "$ROOT/channels.json" "$FLEET_HOME/channels.json"
if [ "$rc17" = "0" ] && [ "$M17" = "d=1 fx=0 ev=1" ] \
   && ! grep -q "Traceback" "$FLEET_HOME/d17.out"; then
  ok "claim_refuted with dead channel: decision + rule.error, daemon survives"
else
  no "claim_refuted with dead channel (rc=$rc17 $M17 out=$(cat "$FLEET_HOME/d17.out"))"
fi

# 18. project-agnostic: no concrete project names anywhere in the tree.
PAT="${FLEET_FORBIDDEN_NAMES:-Acme""Corp|acme""-internal}"
if grep -rIn -E "$PAT" "$ROOT" --exclude-dir=.git --exclude-dir=docs; then
  no "project-agnostic: no concrete project names"
else
  ok "project-agnostic: no concrete project names"
fi

echo "---"
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = "0" ]
