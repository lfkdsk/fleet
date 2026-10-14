#!/usr/bin/env bash
# fleet P3 daemon + rule-engine smoke tests. Zero model quota: shell only.
#
# The 43 cases include enqueue_fix and gate_touched so every rule-engine
# behavior has coverage. Cases 20-26 cover `with.channel: "auto"`: the reviewer
# channel is resolved per firing against the reviewed task's family, since no
# fixed channel can review a goal that mixes families. Cases 27-30 cover which
# channel auto is allowed to SPEND:
# never-probed excluded unless preferred, recency not name as the fallback
# order, and an all-unprobed ledger escalating instead of guessing.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-daemon-test-XXXX)"
trap 'rm -rf "$FLEET_HOME"' EXIT
export PATH="$ROOT/bin:$PATH"
unset FLEET_TASK_ID FLEET_ATTEMPT FLEET_RUN_DIR FLEET_SB_MCP_CMD

PASS=0
FAIL=0
N=0

ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }

field(){ fleet show "$1" | awk -v f="$2" '$1==f":"{print $2}'; }
hfield(){ FLEET_HOME="$1" fleet show "$2" | awk -v f="$3" '$1==f":"{print $2}'; }

wait_status(){
  local id="$1" want="$2" i got
  for i in $(seq 1 150); do
    got=$(field "$id" status)
    [ "$got" = "$want" ] && return 0
    sleep 0.2
  done
  return 1
}

wait_home_status(){
  local home="$1" id="$2" want="$3" i got
  for i in $(seq 1 150); do
    got=$(hfield "$home" "$id" status)
    [ "$got" = "$want" ] && return 0
    sleep 0.2
  done
  return 1
}

wait_while(){
  # wait until task <id> leaves status <from> (or timeout)
  local id="$1" from="$2" i got
  for i in $(seq 1 150); do
    got=$(field "$id" status)
    [ "$got" != "$from" ] && return 0
    sleep 0.2
  done
  return 1
}

fleet init >/dev/null
printf 'echo hi\n'        > "$FLEET_HOME/spec_echo.sh"
printf 'exit 3\n'         > "$FLEET_HOME/spec_fail.sh"
printf 'sleep 5\n'        > "$FLEET_HOME/spec_sleep5.sh"
printf 'sleep 10\n'       > "$FLEET_HOME/spec_sleep10.sh"
printf 'sleep 300\n'      > "$FLEET_HOME/spec_sleep300.sh"

# 1. start -> pidfile + live process + status running; stop -> process gone
fleet daemon start --interval 1 >/dev/null
pf="$FLEET_HOME/fleetd.pid"
pid1=""
if [ -f "$pf" ]; then
  pid1=$(cat "$pf")
  kill -0 "$pid1" 2>/dev/null || pid1=""
fi
st1=$(fleet daemon status 2>/dev/null | awk '{print $1}')
fleet daemon stop >/dev/null
gone=1
kill -0 "$pid1" 2>/dev/null && gone=0
if [ -n "$pid1" ] && [ "$st1" = "running" ] && [ "$gone" = "1" ]; then
  ok "daemon start/status/stop lifecycle"
else
  no "daemon start/status/stop lifecycle (pid=$pid1 st=$st1 gone=$gone)"
fi

# 2. single instance: second start fails non-zero, pidfile untouched
fleet daemon start --interval 1 >/dev/null
pf1=$(cat "$FLEET_HOME/fleetd.pid")
fleet daemon start --interval 1 >/dev/null 2>"$FLEET_HOME/err2"
rc2=$?
pf2=$(cat "$FLEET_HOME/fleetd.pid")
if [ "$rc2" != "0" ] && [ "$pf1" = "$pf2" ]; then
  ok "single instance: second start rejected, pidfile unchanged"
else
  no "single instance: second start rejected, pidfile unchanged (rc=$rc2)"
fi

# 3. auto-start: enqueue only, the daemon runs the task to done by itself
T3=$(fleet add "auto task" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
if wait_status "$T3" done; then
  ok "auto-start: daemon ran enqueued task to done"
else
  no "auto-start: daemon ran enqueued task to done"
fi

# 4. daemon respects max_parallel (2 of 4 sleepers running at once)
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["max_parallel"] = 2
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
P1=$(fleet add "par 1" --channel shell --spec "$FLEET_HOME/spec_sleep5.sh")
P2=$(fleet add "par 2" --channel shell --spec "$FLEET_HOME/spec_sleep5.sh")
P3=$(fleet add "par 3" --channel shell --spec "$FLEET_HOME/spec_sleep5.sh")
P4=$(fleet add "par 4" --channel shell --spec "$FLEET_HOME/spec_sleep5.sh")
saw_two=""
for i in $(seq 1 60); do
  r=0
  for p in "$P1" "$P2" "$P3" "$P4"; do
    [ "$(field "$p" status)" = "running" ] && r=$((r+1))
  done
  if [ "$r" = "2" ]; then
    q=0
    for p in "$P1" "$P2" "$P3" "$P4"; do
      [ "$(field "$p" status)" = "queued" ] && q=$((q+1))
    done
    [ "$q" = "2" ] && saw_two=1
    break
  fi
  [ "$r" -gt "2" ] && break
  sleep 0.3
done
for p in "$P1" "$P2" "$P3" "$P4"; do
  fleet cancel "$p" >/dev/null 2>&1 || true
done
if [ -n "$saw_two" ]; then
  ok "max_parallel: exactly 2 running, 2 queued"
else
  no "max_parallel: exactly 2 running, 2 queued"
fi

# 5. daemon respects deps: B stays queued until A is done
A5=$(fleet add "dep A" --channel shell --spec "$FLEET_HOME/spec_sleep5.sh")
B5=$(fleet add "dep B" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --dep "$A5")
sleep 1
b_held=""
[ "$(field "$B5" status)" = "queued" ] && [ "$(field "$A5" status)" = "running" ] && b_held=1
if [ -n "$b_held" ] && wait_status "$A5" done && wait_status "$B5" done; then
  ok "deps: B held until A done, then launched"
else
  no "deps: B held until A done, then launched"
fi

# 6. daemon respects lease mutex: never both running, both eventually done
L1=$(fleet add "lease 1" --channel shell --spec "$FLEET_HOME/spec_sleep5.sh" --lease resL)
L2=$(fleet add "lease 2" --channel shell --spec "$FLEET_HOME/spec_sleep5.sh" --lease resL)
bad6=""
for i in $(seq 1 120); do
  s1=$(field "$L1" status)
  s2=$(field "$L2" status)
  if [ "$s1" = "running" ] && [ "$s2" = "running" ]; then
    bad6=1
    break
  fi
  t1=0; t2=0
  case "$s1" in done|failed|cancelled) t1=1;; esac
  case "$s2" in done|failed|cancelled) t2=1;; esac
  if [ "$t1" = "1" ] && [ "$t2" = "1" ]; then
    break
  fi
  sleep 0.3
done
lease_left=$(fleet lease list | grep -c resL || true)
s1=$(field "$L1" status)
s2=$(field "$L2" status)
if [ -z "$bad6" ] && [ "$s1" = "done" ] && [ "$s2" = "done" ] && [ "$lease_left" = "0" ]; then
  ok "lease mutex: never concurrent, both done, lease released"
else
  no "lease mutex: never concurrent, both done, lease released (bad=$bad6 $s1/$s2 lease=$lease_left)"
fi

# 7. daemon respects budget: second task blocked, then launched after quota reset
used=$(fleet channels | awk '$1=="shell"{split($4,a,"/"); print a[1]}')
fleet budget set shell "$(date +%Y-%m)" "$((used+1))" >/dev/null
BG1=$(fleet add "budget 1" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
BG2=$(fleet add "budget 2" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
blocked7=""
for i in $(seq 1 60); do
  if [ "$(field "$BG1" status)" = "done" ] && [ "$(field "$BG2" status)" = "queued" ]; then
    blocked7=1
    break
  fi
  sleep 0.3
done
# "BG1 done and BG2 queued" can be observed before the poll that evaluates
# BG2 against the exhausted budget has run, so the blocked event may land a
# moment after blocked7 is set (P18 made it exactly one event, which took
# away the retries that used to hide the window). Wait for the event, then
# lift the quota.
blocked7ev=""
for i in $(seq 1 50); do
  if [ "$(fleet since --raw 0 | grep -c " task.blocked $BG2 .*\"reason\": \"budget\"")" -ge 1 ]; then
    blocked7ev=1
    break
  fi
  sleep 0.2
done
fleet budget set shell "$(date +%Y-%m)" 1000000 >/dev/null
if [ -n "$blocked7" ] && [ -n "$blocked7ev" ] \
   && wait_status "$BG2" done; then
  ok "budget: blocked while exhausted, launched after reset"
else
  no "budget: blocked while exhausted, launched after reset (blocked=$blocked7)"
fi

# 8. auto-retry: a --max-attempts 2 failure is relaunched with no manual run
R8=$(fleet add "retry task" --channel shell --spec "$FLEET_HOME/spec_fail.sh" --max-attempts 2)
ok8=""
for i in $(seq 1 100); do
  if [ "$(field "$R8" status)" = "failed" ] && [ "$(field "$R8" attempt)" = "2" ]; then
    ok8=1
    break
  fi
  sleep 0.3
done
if [ -n "$ok8" ]; then
  ok "auto-retry: daemon relaunched the requeued task"
else
  no "auto-retry: daemon relaunched the requeued task"
fi

# 9. timeout enforcement: sleep 300 with timeout_s=2 is killed, failed/-2, event
T9=$(fleet add "timeout task" --channel shell --spec "$FLEET_HOME/spec_sleep300.sh" --timeout 2)
ok9=""
for i in $(seq 1 60); do
  if [ "$(field "$T9" status)" = "failed" ] && [ "$(field "$T9" exit_code)" = "-2" ]; then
    ok9=1
    break
  fi
  sleep 0.3
done
attempt9=$(sqlite3 "$FLEET_HOME/fleet.db" \
  "SELECT status||':'||exit_code FROM attempt WHERE task_id=$T9")
if [ -n "$ok9" ] && [ "$attempt9" = "failed:-2" ] \
   && fleet since --raw 0 | grep -q "task.timeout"; then
  ok "timeout: task and attempt failed/-2, task.timeout event"
else
  no "timeout: task and attempt failed/-2, task.timeout event (ok9=$ok9 attempt=$attempt9)"
fi

# 10. graceful stop: a running task is NOT killed and settles on its own
G10=$(fleet add "grace task" --channel shell --spec "$FLEET_HOME/spec_sleep10.sh")
running10=""
for i in $(seq 1 50); do
  [ "$(field "$G10" status)" = "running" ] && running10=1 && break
  sleep 0.3
done
gpid=$(field "$G10" pid)
fleet daemon stop >/dev/null
sleep 0.5
task_alive=1
kill -0 "$gpid" 2>/dev/null || task_alive=0
if [ -n "$running10" ] && [ "$task_alive" = "1" ] && wait_status "$G10" done; then
  ok "graceful stop: running task survives and settles itself"
else
  no "graceful stop: running task survives and settles itself (running=$running10 alive=$task_alive)"
fi

# 11. daemon reaps orphans (SIGKILLed wrapper -> failed, lease released)
FLEET_ORPHAN_GRACE_S=1 fleet daemon start --interval 1 >/dev/null
O11=$(fleet add "orphan" --channel shell --spec "$FLEET_HOME/spec_sleep300.sh" --lease orphan-res)
for i in $(seq 1 50); do
  [ "$(field "$O11" status)" = "running" ] && break
  sleep 0.3
done
opid=$(cat "$FLEET_HOME/runs/$O11/wrapper.pid" 2>/dev/null || echo 0)
kill -9 -"$opid" 2>/dev/null || kill -9 "$opid" 2>/dev/null || true
ok11=""
for i in $(seq 1 60); do
  st=$(field "$O11" status)
  if [ "$st" = "failed" ]; then
    ok11=1
    break
  fi
  sleep 0.3
done
lease_left=$(fleet lease list | grep -c orphan-res || true)
fleet daemon stop >/dev/null
if [ -n "$ok11" ] && [ "$lease_left" = "0" ] \
   && fleet since --raw 0 | grep -q "task.orphaned"; then
  ok "orphan reaped by daemon: failed, lease released, event"
else
  no "orphan reaped by daemon: failed, lease released, event (ok11=$ok11 lease=$lease_left)"
fi

# 12. run --once: one poll round then exit
T12=$(fleet add "once task" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
if fleet daemon run --once >/dev/null 2>&1 && wait_status "$T12" done; then
  ok "run --once: one round, exits, task done"
else
  no "run --once: one round, exits, task done"
fi

# 13. rule enqueue_review: done shell task auto-enqueues a review task
G13=$(fleet goal add "g13")
cat > "$FLEET_HOME/rules13.json" <<'EOF'
[{"on":"task_done","match":{"lens":null},"do":"enqueue_review","with":{"channel":"shell","lens":"correctness"}}]
EOF
fleet plan set "$G13" --rules "$FLEET_HOME/rules13.json" --rationale "auto review" >/dev/null
T13=$(fleet add "r13 task" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --goal "$G13")
fleet daemon run --once >/dev/null 2>&1
wait_status "$T13" done
fleet daemon run --once >/dev/null 2>&1
RV=$(fleet --json status --all | python3 -c '
import json, sys
rows = json.load(sys.stdin)
rv = [r for r in rows if r["review_of"] == '"$T13"']
assert len(rv) == 1, rv
print(rv[0]["id"])')
if [ -n "$RV" ]; then
  ok "enqueue_review: review task enqueued with review_of=$T13"
else
  no "enqueue_review: review task enqueued"
fi

# 14. cross-family conflict: same-family review channel -> no task, decision(needs_user=1)
G14=$(fleet goal add "g14")
cat > "$FLEET_HOME/rules14.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"cursor"}}]
EOF
fleet plan set "$G14" --rules "$FLEET_HOME/rules14.json" --rationale "conflict probe" >/dev/null
T14=$(fleet add "r14 cursor" --channel cursor --goal "$G14")
python3 -c "import sqlite3; c=sqlite3.connect('$FLEET_HOME/fleet.db'); c.execute(\"UPDATE task SET status='done' WHERE id=$T14\"); c.commit()"
fleet daemon run --once >/dev/null 2>&1
M14=$(python3 - "$FLEET_HOME/fleet.db" "$T14" "$G14" <<'EOF'
import sqlite3, sys
db, t14, g14 = sys.argv[1:]
c = sqlite3.connect(db)
rv = c.execute("SELECT COUNT(*) FROM task WHERE review_of=?", (t14,)).fetchone()[0]
d = c.execute("SELECT COUNT(*) FROM decision WHERE goal_id=? AND needs_user=1", (g14,)).fetchone()[0]
assert rv == 0, rv
assert d >= 1, d
print("ok")
EOF
)
if [ "$M14" = "ok" ]; then
  ok "cross-family conflict: no review task, decision(needs_user=1) written"
else
  no "cross-family conflict: no review task, decision(needs_user=1) written ($M14)"
fi

# 15. idempotency: repeated evaluation enqueues the review exactly once
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
cnt15=$(fleet --json status --all | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len([r for r in rows if r["review_of"] == '"$T13"']))')
if [ "$cnt15" = "1" ]; then
  ok "idempotency: review enqueued exactly once across repeated evals"
else
  no "idempotency: review enqueued exactly once across repeated evals (got $cnt15)"
fi

# 16. attempts_exhausted -> decision(needs_user=1)
G16=$(fleet goal add "g16")
cat > "$FLEET_HOME/rules16.json" <<'EOF'
[{"on":"attempts_exhausted","do":"escalate","with":{}}]
EOF
fleet plan set "$G16" --rules "$FLEET_HOME/rules16.json" --rationale "escalate" >/dev/null
T16=$(fleet add "r16 fail" --channel shell --spec "$FLEET_HOME/spec_fail.sh" --goal "$G16" --max-attempts 2)
dec16=""
for i in $(seq 1 40); do
  fleet daemon run --once >/dev/null 2>&1
  dec16=$(fleet --json decisions --goal "$G16" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
  [ "$dec16" != "0" ] && break
  sleep 0.5
done
if [ "$dec16" != "0" ] && [ -n "$dec16" ]; then
  ok "attempts_exhausted: decision(needs_user=1) written"
else
  no "attempts_exhausted: decision(needs_user=1) written (dec=$dec16)"
fi

# 17. enqueue_fix: refuted claim enqueues a fix on the original channel.
#     P17 changed two of this case's assertions, both deliberately:
#
#     a. parent_id used to be asserted None when the source task had no
#        session_id, because the code read `parent = tid if session_id`. That
#        was the bug, not the contract: most channels never set session_id,
#        so task.parent_id was NULL across the entire ledger and no fix could
#        be traced back to the work that caused it. The source task IS the
#        parent now, session or no session -- so both inputs (with and
#        without session_id) are still exercised below, and both must give
#        parent_id == the source task id.
#     b. the second source task was refuted while it was still RUNNING, and
#        the old code enqueued a fix anyway -- against a deliverable that did
#        not exist yet. A fix is now built only from a settled task, so this
#        case asserts the wait first, then finishes the source and asserts
#        the fix appears.
G17=$(fleet goal add "g17")
cat > "$FLEET_HOME/rules17.json" <<'EOF'
[{"on":"claim_refuted","do":"enqueue_fix","with":{}}]
EOF
fleet plan set "$G17" --rules "$FLEET_HOME/rules17.json" --rationale "fix loop" >/dev/null
T17=$(fleet add "r17 orig" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --goal "$G17")
fleet daemon run --once >/dev/null 2>&1
wait_status "$T17" done
CID=$(fleet claim add "$T17" "the sky is green" --evidence "spec:1")
fleet claim verify "$CID" --status refuted --note "it is blue; see photo" >/dev/null
fleet daemon run --once >/dev/null 2>&1
M17A=$(python3 - "$FLEET_HOME/fleet.db" "$G17" "$T17" <<'EOF'
import json, sqlite3, sys
db, g, t = sys.argv[1:]
c = sqlite3.connect(db)
c.row_factory = sqlite3.Row
fix = c.execute("SELECT * FROM task WHERE goal_id=? AND title LIKE 'fix:%' ORDER BY id LIMIT 1", (g,)).fetchone()
assert fix is not None, "no fix task"
assert fix["channel"] == "shell", fix["channel"]
spec = open(fix["spec_path"]).read()
assert "the sky is green" in spec, spec
# The refutation's reason, not just the claim: the whole point of the fix.
assert "it is blue; see photo" in spec, spec
src = c.execute("SELECT session_id FROM task WHERE id=?", (t,)).fetchone()
assert src["session_id"] is None, src["session_id"]
assert fix["parent_id"] == int(t), (fix["parent_id"], t)
print("ok")
EOF
)
# second original task WITH a session_id: same parent_id contract, and the
# fix waits until the source settles.
T17B=$(fleet add "r17 orig2" --channel shell --spec "$FLEET_HOME/spec_sleep300.sh" --goal "$G17")
fleet daemon run --once >/dev/null 2>&1
python3 -c "import sqlite3; c=sqlite3.connect('$FLEET_HOME/fleet.db'); c.execute(\"UPDATE task SET session_id='sess-Y' WHERE id=$T17B\"); c.commit()"
CID2=$(fleet claim add "$T17B" "second claim" --evidence "spec:2")
fleet claim verify "$CID2" --status refuted --note "not shown by the evidence" >/dev/null
fleet daemon run --once >/dev/null 2>&1
M17WAIT=$(python3 -c "import sqlite3
print(sqlite3.connect('$FLEET_HOME/fleet.db').execute('SELECT COUNT(*) FROM task WHERE parent_id=$T17B').fetchone()[0])")
fleet cancel "$T17B" >/dev/null 2>&1 || true
wait_status "$T17B" cancelled || true
fleet daemon run --once >/dev/null 2>&1
M17B=$(python3 - "$FLEET_HOME/fleet.db" "$T17B" <<'EOF'
import sqlite3, sys
db, t = sys.argv[1:]
c = sqlite3.connect(db)
fix = c.execute("SELECT parent_id FROM task WHERE parent_id=? ORDER BY id LIMIT 1", (t,)).fetchone()
assert fix is not None, "no fix task with parent_id"
print("ok")
EOF
)
if [ "$M17A" = "ok" ] && [ "$M17WAIT" = "0" ] && [ "$M17B" = "ok" ]; then
  ok "enqueue_fix: fix on original channel, claim+note in spec, parent_id is the source with or without session_id, and waits for the source to settle"
else
  no "enqueue_fix: (A=$M17A during-run-fixers=$M17WAIT B=$M17B)"
fi

# 18. gate_touched: a task changing a glob-matched path in a git repo fires a
#     gate decision, and the goal stops auto-enqueueing anything afterwards
G18=$(fleet goal add "g18")
cat > "$FLEET_HOME/rules18.json" <<'EOF'
[
  {"on":"task_done","do":"enqueue_review","with":{"channel":"shell"}},
  {"on":"gate_touched","match":{"glob":"*/prod/*"},"do":"gate","with":{}}
]
EOF
fleet plan set "$G18" --rules "$FLEET_HOME/rules18.json" --rationale "gated goal" >/dev/null
mkdir -p "$FLEET_HOME/gr/sub"
git init -q "$FLEET_HOME/gr"
git -C "$FLEET_HOME/gr" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'mkdir -p sub/prod; echo x > sub/prod/x.txt\n' > "$FLEET_HOME/spec_gate.sh"
T18=$(fleet add "gated task" --channel shell --spec "$FLEET_HOME/spec_gate.sh" --goal "$G18" --cwd "$FLEET_HOME/gr")
fleet daemon run --once >/dev/null 2>&1
wait_status "$T18" done
fleet daemon run --once >/dev/null 2>&1
gate_dec=$(fleet --json decisions --goal "$G18" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len([r for r in rows if r["verdict"] == "gate" and r["needs_user"] == 1]))')
# a second task finishing after the gate must NOT get a review
T18B=$(fleet add "post gate" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --goal "$G18" --cwd "$FLEET_HOME/gr")
fleet daemon run --once >/dev/null 2>&1
wait_status "$T18B" done
fleet daemon run --once >/dev/null 2>&1
rev18=$(fleet --json status --all | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len([r for r in rows if r["review_of"] in ('"$T18"', '"$T18B"')]))')
if [ "$gate_dec" != "0" ] && [ -n "$gate_dec" ] && [ "$rev18" = "1" ]; then
  ok "gate_touched: gate decision, goal frozen (only pre-gate review exists)"
else
  no "gate_touched: gate decision, goal frozen (gate=$gate_dec reviews=$rev18)"
fi

# A channel deleted while a task sits queued used to print to fleetd.log and
# nothing else, so the ledger looked healthy while the task rotted forever.
# The blocked event and the needs-user decision are what make it visible; a
# mutation of the reason string showed nothing was asserting on them.
printf 'echo hi\n' > "$FLEET_HOME/spec_uc.sh"
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"]["doomed"] = {"adapter": "shell.sh", "family": "none"}
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
UC=$(fleet add "channel vanishes" --channel doomed --spec "$FLEET_HOME/spec_uc.sh")
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["channels"].pop("doomed", None)
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
fleet daemon run --once >/dev/null 2>&1
uc_st=$(field "$UC" status)
# match the reason field itself, not the human-readable error text that also
# contains the phrase: a mutation of the reason alone must turn this red.
uc_ev=$(fleet since --raw 0 | grep -c "task.blocked $UC .*\"reason\": \"unknown channel\"" || true)
uc_dec=$(fleet --json decisions | python3 -c '
import json,sys; print(len([r for r in json.load(sys.stdin) if r["task_id"]=='"$UC"']))')
if [ "$uc_st" = "queued" ] && [ "$uc_ev" -ge 1 ] && [ "$uc_dec" -ge 1 ]; then
  ok "a vanished channel blocks the task with an event and a decision"
else
  no "a vanished channel blocks the task with an event and a decision (st=$uc_st ev=$uc_ev dec=$uc_dec)"
fi

# 20. enqueue_review with channel "auto": the reviewer channel is resolved per
#     firing against the family of the task being reviewed. A plan cannot name
#     one channel once a goal mixes families -- whichever it names is the same
#     family as one of the workers, and that enqueue is refused.
#
# Channels are built here rather than borrowed from the shipped registry: this
# case asserts WHICH family auto lands on, and a registry edit elsewhere would
# silently retarget the assertion (the same reason p12's B5 builds its own).
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"] = {
    "shell": {"adapter": "shell.sh", "family": "none"},
    "agrok": {"adapter": "shell.sh", "model": "grok-4.6",
              "models": ["grok-4.6"]},
    "agpt": {"adapter": "shell.sh", "model": "GPT-5.5", "models": ["GPT-5.5"]},
    "aclaude": {"adapter": "shell.sh", "model": "claude-opus-5",
                "models": ["claude-opus-5"]},
}
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
G20=$(fleet goal add "g20")
cat > "$FLEET_HOME/rules20.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"auto","prefer":["agpt","aclaude"]}}]
EOF
fleet plan set "$G20" --rules "$FLEET_HOME/rules20.json" --rationale "auto reviewer" >/dev/null
T20S=$(fleet add "r20 grok worker" --channel agrok --goal "$G20")
T20G=$(fleet add "r20 gpt worker" --channel agpt --goal "$G20")
python3 -c "import sqlite3; c=sqlite3.connect('$FLEET_HOME/fleet.db'); c.execute(\"UPDATE task SET status='done' WHERE id IN ($T20S,$T20G)\"); c.commit()"
fleet daemon run --once >/dev/null 2>&1
M20=$(python3 - "$FLEET_HOME/fleet.db" "$T20S" "$T20G" <<'EOF'
import json, sqlite3, sys
db, grok_src, gpt_src = sys.argv[1:]
c = sqlite3.connect(db); c.row_factory = sqlite3.Row
def review(of):
    rows = c.execute("SELECT * FROM task WHERE review_of=?", (of,)).fetchall()
    assert len(rows) == 1, (of, [dict(r) for r in rows])
    return rows[0]
# prefer puts agpt first, so the grok worker's review lands in the gpt family.
rs = review(grok_src)
assert rs["family"] == "gpt", dict(rs)
assert rs["channel"] == "agpt", dict(rs)
# The SAME rule, same poll: the gpt worker cannot go to agpt, so auto skips it
# and lands outside the gpt family. This is the whole point -- one fixed
# channel could not have served both workers.
rg = review(gpt_src)
assert rg["family"] != "gpt", dict(rg)
assert rg["channel"] == "aclaude", dict(rg)
# No decision: auto resolving a channel is not an escalation.
assert c.execute("SELECT COUNT(*) FROM decision WHERE goal_id=(SELECT goal_id "
                 "FROM task WHERE id=?)", (grok_src,)).fetchone()[0] == 0
# The chosen channel is in the ledger. A review whose channel is nowhere in
# the rule text is otherwise untraceable.
fired = [json.loads(r[0]) for r in c.execute(
    "SELECT payload FROM event WHERE kind='rule.fired' AND task_id=?", (grok_src,))]
assert len(fired) == 1 and fired[0]["auto_channel"] == "agpt", fired
# agpt was first in prefer and eligible, so nothing was passed over. The gpt
# worker's firing is where the skip is recorded, and its reason is the
# invariant itself.
firedg = [json.loads(r[0]) for r in c.execute(
    "SELECT payload FROM event WHERE kind='rule.fired' AND task_id=?", (gpt_src,))]
assert len(firedg) == 1 and firedg[0]["auto_channel"] == "aclaude", firedg
why = {x["channel"]: x["reason"] for x in firedg[0]["auto_rejected"]}
assert "same family as the reviewed task (gpt)" in why.get("agpt", ""), why
print("ok")
EOF
)
if [ "$M20" = "ok" ]; then
  ok "channel auto: reviewer family follows the reviewed task, both directions, one rule"
else
  no "channel auto: cross-family pick ($M20)"
fi

# 21. A channel whose probe record has expired is not chosen by auto. The
#     enqueue gate deliberately tolerates a stale-but-ok record (absence of
#     evidence is not evidence of failure), but CHOOSING among channels is
#     exactly where a channel nobody has checked recently should lose.
python3 - "$FLEET_HOME/fleet.db" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
# agpt: probed 100h ago. FLEET_PROBE_STALE_H defaults to 12.
c.execute("INSERT INTO model_probe(channel,model,ok,checked_at,note) "
          "VALUES('agpt','GPT-5.5',1,?,'old but ok')",
          (int(time.time()) - 100 * 3600,))
c.commit()
EOF
G21=$(fleet goal add "g21")
cat > "$FLEET_HOME/rules21.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"auto","prefer":["agpt","aclaude"]}}]
EOF
fleet plan set "$G21" --rules "$FLEET_HOME/rules21.json" --rationale "stale probe" >/dev/null
T21=$(fleet add "r21 grok worker" --channel agrok --goal "$G21")
python3 -c "import sqlite3; c=sqlite3.connect('$FLEET_HOME/fleet.db'); c.execute(\"UPDATE task SET status='done' WHERE id=$T21\"); c.commit()"
fleet daemon run --once >/dev/null 2>&1
M21=$(python3 - "$FLEET_HOME/fleet.db" "$T21" <<'EOF'
import json, sqlite3, sys
db, src = sys.argv[1:]
c = sqlite3.connect(db); c.row_factory = sqlite3.Row
rows = c.execute("SELECT * FROM task WHERE review_of=?", (src,)).fetchall()
assert len(rows) == 1, [dict(r) for r in rows]
# agpt is first in prefer and a different family, and it would have been
# chosen in case 20 -- only the expired probe moves the pick to aclaude.
assert rows[0]["channel"] == "aclaude", dict(rows[0])
fired = [json.loads(r[0]) for r in c.execute(
    "SELECT payload FROM event WHERE kind='rule.fired' AND task_id=?", (src,))]
assert len(fired) == 1, fired
why = {x["channel"]: x["reason"] for x in fired[0]["auto_rejected"]}
assert "stale" in why.get("agpt", ""), why
print("ok")
EOF
)
if [ "$M21" = "ok" ]; then
  ok "channel auto: an expired probe record disqualifies a channel"
else
  no "channel auto: stale probe skipped ($M21)"
fi

# 22. Nothing eligible: auto escalates ONCE, with the per-channel reason. A
#     decision every poll would bury the operator, and the fixes (probe a
#     channel, raise a quota, add a family) are human actions anyway.
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
# Only same-family and family=none candidates remain.
d["channels"] = {
    "shell": {"adapter": "shell.sh", "family": "none"},
    "agrok": {"adapter": "shell.sh", "model": "grok-4.6",
              "models": ["grok-4.6"]},
    "agrok2": {"adapter": "shell.sh", "model": "grok-4.5",
               "models": ["grok-4.5"]},
}
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
G22=$(fleet goal add "g22")
cat > "$FLEET_HOME/rules22.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"family":"other"}}]
EOF
fleet plan set "$G22" --rules "$FLEET_HOME/rules22.json" --rationale "no reviewer" >/dev/null
T22=$(fleet add "r22 grok worker" --channel agrok --goal "$G22")
python3 -c "import sqlite3; c=sqlite3.connect('$FLEET_HOME/fleet.db'); c.execute(\"UPDATE task SET status='done' WHERE id=$T22\"); c.commit()"
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
M22=$(python3 - "$FLEET_HOME/fleet.db" "$T22" "$G22" <<'EOF'
import json, sqlite3, sys
db, src, goal = sys.argv[1:]
c = sqlite3.connect(db); c.row_factory = sqlite3.Row
assert c.execute("SELECT COUNT(*) FROM task WHERE review_of=?",
                 (src,)).fetchone()[0] == 0
# Three polls, one decision: the firing is recorded, so it does not repeat.
d = c.execute("SELECT * FROM decision WHERE goal_id=? AND needs_user=1",
              (goal,)).fetchall()
assert len(d) == 1, [dict(x) for x in d]
q = d[0]["question"]
# The reason per channel, and what to do about it -- not just "no channel".
assert "agrok2" in q and "same family" in q, q
assert "with.channel" in q, q
fired = [json.loads(r[0]) for r in c.execute(
    "SELECT payload FROM event WHERE kind='rule.fired' AND task_id=?", (src,))]
assert len(fired) == 1 and fired[0]["skipped"] == "auto-no-channel", fired
# The per-channel reasons are in the EVENT too, not only in the decision:
# resolving the decision must not erase the audit trail of what was rejected.
why = {x["channel"]: x["reason"] for x in fired[0]["auto_rejected"]}
assert "same family" in why.get("agrok2", ""), why
assert "not a reviewer" in why.get("shell", ""), why
print("ok")
EOF
)
if [ "$M22" = "ok" ]; then
  ok "channel auto: no eligible channel escalates once with per-channel reasons"
else
  no "channel auto: escalate once ($M22)"
fi

# 23. A rule naming a FIXED same-family channel is a plan bug, not a channel
#     bug, and it recurs every round until the plan changes. The decision has
#     to say so and name the fix; the bare "cross-family violation" line sent
#     operators to channels.json, where nothing was wrong.
G23=$(fleet goal add "g23")
cat > "$FLEET_HOME/rules23.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"agrok2"}}]
EOF
fleet plan set "$G23" --rules "$FLEET_HOME/rules23.json" --rationale "same family" >/dev/null
T23=$(fleet add "r23 grok worker" --channel agrok --goal "$G23")
python3 -c "import sqlite3; c=sqlite3.connect('$FLEET_HOME/fleet.db'); c.execute(\"UPDATE task SET status='done' WHERE id=$T23\"); c.commit()"
fleet daemon run --once >/dev/null 2>&1
M23=$(python3 - "$FLEET_HOME/fleet.db" "$T23" "$G23" <<'EOF'
import sqlite3, sys
db, src, goal = sys.argv[1:]
c = sqlite3.connect(db); c.row_factory = sqlite3.Row
assert c.execute("SELECT COUNT(*) FROM task WHERE review_of=?",
                 (src,)).fetchone()[0] == 0
d = c.execute("SELECT * FROM decision WHERE goal_id=?", (goal,)).fetchall()
assert len(d) == 1, [dict(x) for x in d]
q = d[0]["question"]
assert "misconfigured" in q, q
assert '"auto"' in q, q                      # the actual fix
assert "cross-family violation" in q, q      # and the underlying refusal
print("ok")
EOF
)
if [ "$M23" = "ok" ]; then
  ok "a fixed same-family review channel is reported as a rule bug with the fix"
else
  no "same-family decision names the rule and the fix ($M23)"
fi

# 24. `auto` is not a channel name, and plan set must not accept it where it
#     would never be resolved -- nor a with.prefer entry that is not a channel
#     (a name that orders nothing reads as "auto ignored my preference").
cat > "$FLEET_HOME/rules24a.json" <<'EOF'
[{"on":"claim_refuted","do":"enqueue_fix","with":{"channel":"auto"}}]
EOF
fleet plan set "$G23" --rules "$FLEET_HOME/rules24a.json" --rationale bad \
  >/dev/null 2>"$FLEET_HOME/e24a"; rc24a=$?
cat > "$FLEET_HOME/rules24b.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"auto","prefer":["nope"]}}]
EOF
fleet plan set "$G23" --rules "$FLEET_HOME/rules24b.json" --rationale bad \
  >/dev/null 2>"$FLEET_HOME/e24b"; rc24b=$?
if [ "$rc24a" = 10 ] && grep -q "only supported for 'enqueue_review'" "$FLEET_HOME/e24a" \
   && [ "$rc24b" = 10 ] && grep -q "unknown channel 'nope'" "$FLEET_HOME/e24b"; then
  ok "plan set: 'auto' rejected outside enqueue_review, unknown prefer rejected"
else
  no "plan set: auto/prefer validation (rc=$rc24a/$rc24b)"
fi

# 25. A rule naming a REMOTE channel is refused by the same invariant (an
#     unverifiable family cannot certify anyone), but it is a different plan
#     bug from same-family and needs different advice. The refusal is a
#     CrossFamilyError subclass, so the same-family branch would have caught
#     it and told the operator to "name a channel in another family" -- which
#     fixes nothing: this source task is grok and the channel is gpt, already
#     a different family. Only "runs remotely" may appear.
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
# remote_cmd is properly wired ($FLEET_MODEL inside single quotes), so the
# enqueue reaches the review block instead of dying on RemoteModelIgnoredError
# -- the remote-reviewer refusal is what this case measures.
d["channels"]["agpt-remote"] = {
    "adapter": "ssh.sh", "ssh_host": "h.invalid", "model": "GPT-5.5",
    "models": ["GPT-5.5"],
    "remote_cmd": "sh -c 'codex exec - -m \"$FLEET_MODEL\"'",
}
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
G25=$(fleet goal add "g25")
cat > "$FLEET_HOME/rules25.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"agpt-remote"}}]
EOF
fleet plan set "$G25" --rules "$FLEET_HOME/rules25.json" --rationale "remote reviewer" >/dev/null
T25=$(fleet add "r25 grok worker" --channel agrok --goal "$G25")
python3 -c "import sqlite3; c=sqlite3.connect('$FLEET_HOME/fleet.db'); c.execute(\"UPDATE task SET status='done' WHERE id=$T25\"); c.commit()"
fleet daemon run --once >/dev/null 2>&1
M25=$(python3 - "$FLEET_HOME/fleet.db" "$T25" "$G25" <<'EOF'
import sqlite3, sys
db, src, goal = sys.argv[1:]
c = sqlite3.connect(db); c.row_factory = sqlite3.Row
assert c.execute("SELECT COUNT(*) FROM task WHERE review_of=?",
                 (src,)).fetchone()[0] == 0
d = c.execute("SELECT * FROM decision WHERE goal_id=?", (goal,)).fetchall()
assert len(d) == 1, [dict(x) for x in d]
q = d[0]["question"]
assert "runs remotely" in q, q
assert "may run work but never review it" in q, q
assert "LOCAL" in q, q                        # the actual fix
# The same-family wording must NOT appear: the source is grok and the channel
# is gpt, so "pick another family" is advice for a problem that is not here.
assert "same family" not in q, q
assert "cross-family violation" not in q, q
print("ok")
EOF
)
if [ "$M25" = "ok" ]; then
  ok "a remote review channel is reported as remote, not as same-family"
else
  no "remote reviewer decision wording ($M25)"
fi

# 26. with.family is the spelling variant of channel "auto", so plan set gives
#     it the same two checks. The daemon reads exactly one value ("other") and
#     only on the enqueue_review branch: a family NAME, or family:other on
#     another action, is read by nothing. Accepting either writes a plan whose
#     reviewer setting silently does nothing.
cat > "$FLEET_HOME/rules26a.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"family":"gpt"}}]
EOF
fleet plan set "$G23" --rules "$FLEET_HOME/rules26a.json" --rationale bad \
  >/dev/null 2>"$FLEET_HOME/e26a"; rc26a=$?
cat > "$FLEET_HOME/rules26b.json" <<'EOF'
[{"on":"claim_refuted","do":"enqueue_fix","with":{"family":"other"}}]
EOF
fleet plan set "$G23" --rules "$FLEET_HOME/rules26b.json" --rationale bad \
  >/dev/null 2>"$FLEET_HOME/e26b"; rc26b=$?
if [ "$rc26a" = 10 ] && grep -q 'with.family only accepts' "$FLEET_HOME/e26a" \
   && [ "$rc26b" = 10 ] \
   && grep -q "only supported for 'enqueue_review'" "$FLEET_HOME/e26b"; then
  ok "plan set: with.family rejects a family name and non-review actions"
else
  no "plan set: with.family validation (rc=$rc26a/$rc26b)"
fi

# 27. auto never spends a NEVER-PROBED channel unless a human named it (task
#     444). This is the codex incident: p19 case Q injected one fake reviewer
#     into a registry-seeded channels.json, auto walked names lexically, and a
#     real paid model reviewed a `printf` worker. The enqueue gate treats "no
#     probe record" as absence of evidence and lets work through; auto is
#     choosing to spend on its own initiative, and there the same absence has
#     to disqualify. Every channel here is shell.sh -- what makes `areal`
#     stand for a real channel is only that nothing probed it.
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"] = {
    "shell": {"adapter": "shell.sh", "family": "none"},
    "agrok": {"adapter": "shell.sh", "model": "grok-4.6",
              "models": ["grok-4.6"]},
    # Sorts BEFORE aprobed, and is listed in models -- under the old lexical
    # walk it won on both counts. Never probed, so it must lose now.
    "areal": {"adapter": "shell.sh", "model": "GPT-5.5", "models": ["GPT-5.5"]},
    "aprobed": {"adapter": "shell.sh", "model": "claude-opus-5",
                "models": ["claude-opus-5"]},
}
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
python3 - "$FLEET_HOME/fleet.db" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT OR REPLACE INTO model_probe(channel,model,ok,checked_at,note)"
          " VALUES('aprobed','claude-opus-5',1,?,'fresh')", (int(time.time()),))
c.commit()
EOF
G27=$(fleet goal add "g27")
cat > "$FLEET_HOME/rules27.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"auto"}}]
EOF
fleet plan set "$G27" --rules "$FLEET_HOME/rules27.json" --rationale "unprobed" >/dev/null
T27=$(fleet add "r27 grok worker" --channel agrok --goal "$G27")
# A second worker in aprobed's OWN family, same rule, same poll. For it the
# probed channel is disqualified as same-family, so areal is the only
# candidate left -- and it must be REFUSED, not spent. Without this task the
# case would pass on ordering alone (aprobed is fresher, so it wins whether or
# not the never-probed rule exists) and would not test the exclusion at all.
T27C=$(fleet add "r27 claude worker" --channel aprobed --goal "$G27")
python3 -c "import sqlite3; c=sqlite3.connect('$FLEET_HOME/fleet.db'); c.execute(\"UPDATE task SET status='done' WHERE id IN ($T27,$T27C)\"); c.commit()"
fleet daemon run --once >/dev/null 2>&1
M27=$(python3 - "$FLEET_HOME/fleet.db" "$T27" "$T27C" <<'EOF'
import json, sqlite3, sys
db, src, csrc = sys.argv[1:]
c = sqlite3.connect(db); c.row_factory = sqlite3.Row
rows = c.execute("SELECT * FROM task WHERE review_of=?", (src,)).fetchall()
assert len(rows) == 1, [dict(r) for r in rows]
assert rows[0]["channel"] == "aprobed", dict(rows[0])
fired = [json.loads(r[0]) for r in c.execute(
    "SELECT payload FROM event WHERE kind='rule.fired' AND task_id=?", (src,))]
assert len(fired) == 1 and fired[0]["auto_channel"] == "aprobed", fired
# The claude worker: areal was the last channel standing and was still not
# spent. Nothing anywhere in this goal ran on it.
assert c.execute("SELECT COUNT(*) FROM task WHERE review_of=?",
                 (csrc,)).fetchone()[0] == 0
assert c.execute("SELECT COUNT(*) FROM task WHERE channel='areal'"
                 ).fetchone()[0] == 0
firedc = [json.loads(r[0]) for r in c.execute(
    "SELECT payload FROM event WHERE kind='rule.fired' AND task_id=?", (csrc,))]
assert len(firedc) == 1 and firedc[0]["skipped"] == "auto-no-channel", firedc
# The reason is auditable and actionable, not just "skipped".
why = {x["channel"]: x["reason"] for x in firedc[0]["auto_rejected"]}
assert "never been probed" in why.get("areal", ""), why
assert "fleet probe areal" in why.get("areal", ""), why
print("ok")
EOF
)
if [ "$M27" = "ok" ]; then
  ok "channel auto: a never-probed channel loses to a probed one, and is refused rather than spent as a last resort"
else
  no "channel auto: unprobed excluded ($M27)"
fi

# 28. with.prefer is the one clause that lifts the never-probed exclusion:
#     naming a channel is a human vouching for it, the same as
#     `fleet add --channel`. Without this, prefer would be advice auto could
#     silently drop on a fresh ledger -- and every rule in the repo's own docs
#     names channels that way.
G28=$(fleet goal add "g28")
cat > "$FLEET_HOME/rules28.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"auto","prefer":["areal"]}}]
EOF
fleet plan set "$G28" --rules "$FLEET_HOME/rules28.json" --rationale "prefer unprobed" >/dev/null
T28=$(fleet add "r28 grok worker" --channel agrok --goal "$G28")
python3 -c "import sqlite3; c=sqlite3.connect('$FLEET_HOME/fleet.db'); c.execute(\"UPDATE task SET status='done' WHERE id=$T28\"); c.commit()"
fleet daemon run --once >/dev/null 2>&1
M28=$(python3 - "$FLEET_HOME/fleet.db" "$T28" <<'EOF'
import sqlite3, sys
db, src = sys.argv[1:]
c = sqlite3.connect(db); c.row_factory = sqlite3.Row
rows = c.execute("SELECT * FROM task WHERE review_of=?", (src,)).fetchall()
assert len(rows) == 1, [dict(r) for r in rows]
# areal is never probed and aprobed is fresh: only prefer explains this pick.
assert rows[0]["channel"] == "areal", dict(rows[0])
print("ok")
EOF
)
if [ "$M28" = "ok" ]; then
  ok "channel auto: with.prefer vouches for an unprobed channel"
else
  no "channel auto: prefer bypasses the probe rule ($M28)"
fi

# 29. Two eligible channels, neither preferred: the fallback order is LAST
#     SUCCESSFUL PROBE, newest first -- not the name. Lexical order made which
#     model auto spends a function of its spelling, so adding a channel called
#     `aaa-expensive` retargeted every existing rule. `zfresh` sorts last and
#     must still win on a fresher probe.
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"] = {
    "shell": {"adapter": "shell.sh", "family": "none"},
    "agrok": {"adapter": "shell.sh", "model": "grok-4.6",
              "models": ["grok-4.6"]},
    "aolder": {"adapter": "shell.sh", "model": "GPT-5.5", "models": ["GPT-5.5"]},
    "zfresh": {"adapter": "shell.sh", "model": "claude-opus-5",
               "models": ["claude-opus-5"]},
}
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
python3 - "$FLEET_HOME/fleet.db" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1]); n = int(time.time())
# Both inside FLEET_PROBE_STALE_H (12h): the stale clause must not be what
# decides this case -- only recency ordering.
c.execute("INSERT OR REPLACE INTO model_probe(channel,model,ok,checked_at,note)"
          " VALUES('aolder','GPT-5.5',1,?,'6h ago')", (n - 6 * 3600,))
c.execute("INSERT OR REPLACE INTO model_probe(channel,model,ok,checked_at,note)"
          " VALUES('zfresh','claude-opus-5',1,?,'minutes ago')", (n - 300,))
c.commit()
EOF
G29=$(fleet goal add "g29")
cat > "$FLEET_HOME/rules29.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"auto"}}]
EOF
fleet plan set "$G29" --rules "$FLEET_HOME/rules29.json" --rationale "recency" >/dev/null
T29=$(fleet add "r29 grok worker" --channel agrok --goal "$G29")
python3 -c "import sqlite3; c=sqlite3.connect('$FLEET_HOME/fleet.db'); c.execute(\"UPDATE task SET status='done' WHERE id=$T29\"); c.commit()"
fleet daemon run --once >/dev/null 2>&1
M29=$(python3 - "$FLEET_HOME/fleet.db" "$T29" <<'EOF'
import sqlite3, sys
db, src = sys.argv[1:]
c = sqlite3.connect(db); c.row_factory = sqlite3.Row
rows = c.execute("SELECT * FROM task WHERE review_of=?", (src,)).fetchall()
assert len(rows) == 1, [dict(r) for r in rows]
# aolder sorts first and is perfectly eligible; only recency moves the pick.
assert rows[0]["channel"] == "zfresh", dict(rows[0])
print("ok")
EOF
)
if [ "$M29" = "ok" ]; then
  ok "channel auto: unpreferred candidates are ordered by probe recency, not name"
else
  no "channel auto: recency ordering ($M29)"
fi

# 30. Nothing probed at all: auto escalates once rather than picking whatever
#     sorts first. The old code's answer to a fresh ledger was "spend
#     something"; the answer has to be "ask a human", and exactly once -- the
#     fix (run `fleet probe`) is a human action, so re-deciding every poll
#     would bury the operator. Same escalation contract as case 22, different
#     cause.
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"] = {
    "shell": {"adapter": "shell.sh", "family": "none"},
    "agrok": {"adapter": "shell.sh", "model": "grok-4.6",
              "models": ["grok-4.6"]},
    "bnever": {"adapter": "shell.sh", "model": "GPT-5.5", "models": ["GPT-5.5"]},
    "cnever": {"adapter": "shell.sh", "model": "claude-opus-5",
               "models": ["claude-opus-5"]},
}
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
python3 -c "import sqlite3; c=sqlite3.connect('$FLEET_HOME/fleet.db'); c.execute('DELETE FROM model_probe'); c.commit()"
G30=$(fleet goal add "g30")
cat > "$FLEET_HOME/rules30.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"auto"}}]
EOF
fleet plan set "$G30" --rules "$FLEET_HOME/rules30.json" --rationale "fresh ledger" >/dev/null
T30=$(fleet add "r30 grok worker" --channel agrok --goal "$G30")
python3 -c "import sqlite3; c=sqlite3.connect('$FLEET_HOME/fleet.db'); c.execute(\"UPDATE task SET status='done' WHERE id=$T30\"); c.commit()"
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
M30=$(python3 - "$FLEET_HOME/fleet.db" "$T30" "$G30" <<'EOF'
import json, sqlite3, sys
db, src, goal = sys.argv[1:]
c = sqlite3.connect(db); c.row_factory = sqlite3.Row
# The point of the case: nothing was spent.
assert c.execute("SELECT COUNT(*) FROM task WHERE review_of=?",
                 (src,)).fetchone()[0] == 0
d = c.execute("SELECT * FROM decision WHERE goal_id=? AND needs_user=1",
              (goal,)).fetchall()
assert len(d) == 1, [dict(x) for x in d]           # three polls, one decision
q = d[0]["question"]
assert "never been probed" in q, q
assert "fleet probe" in q, q                        # what the human should do
fired = [json.loads(r[0]) for r in c.execute(
    "SELECT payload FROM event WHERE kind='rule.fired' AND task_id=?", (src,))]
assert len(fired) == 1 and fired[0]["skipped"] == "auto-no-channel", fired
why = {x["channel"]: x["reason"] for x in fired[0]["auto_rejected"]}
assert "never been probed" in why.get("bnever", ""), why
assert "never been probed" in why.get("cnever", ""), why
print("ok")
EOF
)
if [ "$M30" = "ok" ]; then
  ok "channel auto: an all-unprobed ledger escalates once instead of spending"
else
  no "channel auto: all-unprobed escalation ($M30)"
fi

echo "---"

# 31-33. service-mode awareness in `daemon status`. The daemons in
#        this suite are hand-started in a temp ledger, and the box running the
#        suite has its own real fleet-daemon service -- a naive cgroup check
#        would misread every hand-started daemon as service-managed, because
#        processes launched by the real service share its cgroup. So the status
#        probe is driven with a recording fake (FLEET_DAEMON_SYSTEMCTL) and a
#        UNIQUE unit name (FLEET_DAEMON_UNIT): nothing about the ambient system
#        is allowed to decide the result. The probe prefers `systemctl show
#        <unit> -p MainPID` matching the live pid; when systemctl cannot
#        answer it says nothing (no cgroup fallback -- see case 33).
cat > "$FLEET_HOME/fake-ctl" <<'FCTL'
#!/usr/bin/env bash
# Stands in for `systemctl --user show <unit> -p MainPID --value`: prints
# $FAKE_MAINPID, exits $FAKE_RC.
echo "$FAKE_MAINPID"
exit "${FAKE_RC:-0}"
FCTL
chmod +x "$FLEET_HOME/fake-ctl"
DUNIT="fleet-daemon-test-$$"

fleet daemon start --interval 1 >/dev/null
DPID=$(cat "$FLEET_HOME/fleetd.pid")

# Managed face: the fake reports THIS pid as the service's MainPID.
out_m=$(FLEET_DAEMON_SYSTEMCTL="$FLEET_HOME/fake-ctl" FLEET_DAEMON_UNIT="$DUNIT" \
        FAKE_MAINPID="$DPID" fleet daemon status 2>&1); rc_m=$?
# Unmanaged face: the fake reports MainPID 0 (service inactive), even though
# the process really sits under the ambient fleet-daemon.service cgroup.
out_u=$(FLEET_DAEMON_SYSTEMCTL="$FLEET_HOME/fake-ctl" FLEET_DAEMON_UNIT="$DUNIT" \
        FAKE_MAINPID="0" fleet daemon status 2>&1); rc_u=$?
# No-answer face: systemctl fails, with the DEFAULT unit name. When this suite
# itself runs inside the real fleet-daemon.service cgroup (a task launched by
# the daemon), the hand-started daemon shares that cgroup. A cgroup fallback
# would misreport it as managed, so no answer must mean unmanaged.
out_n=$(FLEET_DAEMON_SYSTEMCTL="$FLEET_HOME/fake-ctl" \
        FAKE_MAINPID="0" FAKE_RC="7" fleet daemon status 2>&1); rc_n=$?

fleet daemon stop >/dev/null

if [ "$rc_m" = 0 ] \
   && printf '%s\n' "$out_m" | grep -q "managed by fleet-daemon" \
   && printf '%s\n' "$out_m" | grep -q "stop.*only restarts\|only restarts it" \
   && printf '%s\n' "$out_m" | grep -q "systemctl --user stop fleet-daemon"; then
  ok "daemon status: a service-owned daemon says stop only restarts and names the real stop command"
else
  no "daemon status: managed face (rc=$rc_m out='$out_m')"
fi

if [ "$rc_u" = 0 ] && ! printf '%s\n' "$out_u" | grep -q "managed by fleet-daemon" \
   && [ "$(printf '%s\n' "$out_u" | awk '{print $1}')" = "running" ]; then
  ok "daemon status: a hand-started daemon (MainPID 0) is plain 'running' with no service note"
else
  no "daemon status: unmanaged face (rc=$rc_u out='$out_u')"
fi

if [ "$rc_n" = 0 ] && ! printf '%s\n' "$out_n" | grep -q "managed by fleet-daemon"; then
  ok "daemon status: with systemctl failing, no service note is claimed even inside the service cgroup"
else
  no "daemon status: no-answer fallback (rc=$rc_n out='$out_n')"
fi

# 34. attempts_exhausted ignores commander rounds. A commander round that
#     exhausts its attempts is already governed by _commander_exhausted ->
#     consecutive_failures -> schedule_autonomy's breaker, which a later
#     successful round clears. The rule escalating it a SECOND time writes a
#     needs_user decision, and an unresolved needs_user pauses the goal for
#     good: the driver kills the goal it drives, and the pause outlives the
#     recovery. This is the same exclusion the task_done branch already makes;
#     stale decisions must not keep a recovered goal frozen.
G34=$(fleet goal add "g34")
cat > "$FLEET_HOME/rules34.json" <<'EOF'
[{"on":"attempts_exhausted","do":"escalate","with":{}}]
EOF
fleet plan set "$G34" --rules "$FLEET_HOME/rules34.json" --rationale "escalate" >/dev/null
T34W=$(fleet add "r34 worker" --channel shell --spec "$FLEET_HOME/spec_fail.sh" --goal "$G34" --max-attempts 1)
T34C=$(fleet add "r34 commander" --channel shell --spec "$FLEET_HOME/spec_fail.sh" --goal "$G34" --max-attempts 1)
# Settle both as exhausted without running anything: the rule reads
# status/attempt/role, and role is the only difference between the two.
python3 - "$FLEET_HOME/fleet.db" "$T34W" "$T34C" <<'PY34'
import sqlite3, sys
db, worker, commander = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
c = sqlite3.connect(db)
for tid, role in ((worker, "worker"), (commander, "commander")):
    c.execute(
        "UPDATE task SET role=?,status='failed',exit_code=65,"
        "attempt=max_attempts,ended_at=strftime('%s','now') WHERE id=?",
        (role, tid),
    )
c.commit()
PY34
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
esc34=$(fleet --json decisions --goal "$G34" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(" ".join(str(r["task_id"]) for r in rows))')
if [ "$esc34" = "$T34W" ]; then
  ok "attempts_exhausted: escalates the exhausted worker and not the commander round"
else
  no "attempts_exhausted: worker-only escalation (want '$T34W', got '$esc34')"
fi

# 35. gate_touched ignores commander rounds too. Same shape as case 34: a
#     commander round that leaves a change under the gated glob used to collect
#     a verdict='gate' needs_user decision of its own, and schedule_autonomy
#     pauses on ANY unresolved needs_user regardless of verdict -- so the
#     goal's own driver would freeze the goal. This is the last rule branch
#     that needs the worker-role filter.
G35=$(fleet goal add "g35")
cat > "$FLEET_HOME/rules35.json" <<'EOF'
[{"on":"gate_touched","match":{"glob":"*/prod/*"},"do":"gate","with":{}}]
EOF
fleet plan set "$G35" --rules "$FLEET_HOME/rules35.json" --rationale "gated" >/dev/null
mkdir -p "$FLEET_HOME/gr35"
git init -q "$FLEET_HOME/gr35"
git -C "$FLEET_HOME/gr35" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'mkdir -p sub/prod; echo x > sub/prod/x.txt\n' > "$FLEET_HOME/spec_gate35.sh"
T35W=$(fleet add "g35 worker" --channel shell --spec "$FLEET_HOME/spec_gate35.sh" --goal "$G35" --cwd "$FLEET_HOME/gr35")
T35C=$(fleet add "g35 commander" --channel shell --spec "$FLEET_HOME/spec_gate35.sh" --goal "$G35" --cwd "$FLEET_HOME/gr35")
fleet daemon run --once >/dev/null 2>&1
wait_status "$T35W" done
wait_status "$T35C" done
# Only the role differs; the gated change in the shared cwd is the same one.
python3 - "$FLEET_HOME/fleet.db" "$T35C" <<'PY35'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("UPDATE task SET role='commander' WHERE id=?", (int(sys.argv[2]),))
conn.commit()
PY35
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
gate35=$(fleet --json decisions --goal "$G35" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(" ".join(str(r["task_id"]) for r in rows if r["verdict"] == "gate"))')
if [ "$gate35" = "$T35W" ]; then
  ok "gate_touched gates the worker and not the commander round"
else
  no "gate_touched worker-only gating (want '$T35W', got '$gate35')"
fi

# 36. `daemon start` is a long-lived service boundary, not a child belonging
#     to the task/shell that happened to start it. In particular, a real agent
#     may start the daemon while carrying its own attempt identity. If fleetd
#     inherits that identity, detached-child accounting keeps the agent task
#     running!background forever (and fleetd hands stale worker context to
#     future commands). Keep the ledger selector, but scrub worker-scoped vars.
FLEET_TASK_ID=sentinel-task FLEET_ATTEMPT=sentinel-attempt \
FLEET_RUN_DIR=/sentinel/run FLEET_SB_MCP_CMD=sentinel-callback \
  fleet daemon start --interval 60 >/dev/null
DPID36=$(cat "$FLEET_HOME/fleetd.pid")
env36=$(tr '\0' '\n' <"/proc/$DPID36/environ" 2>/dev/null \
  | grep -E '^FLEET_(TASK_ID|ATTEMPT|RUN_DIR|SB_MCP_CMD)=' || true)
home36=$(tr '\0' '\n' <"/proc/$DPID36/environ" 2>/dev/null \
  | sed -n 's/^FLEET_HOME=//p')
fleet daemon stop >/dev/null
if [ -z "$env36" ] && [ "$home36" = "$FLEET_HOME" ]; then
  ok "daemon start scrubs inherited worker identity but keeps its ledger"
else
  no "daemon start worker identity (leaked='$env36' home='$home36')"
fi

# 37. A replacement daemon must upgrade the ledger before its first poll.
#     This is the exact cb2f120 predecessor shape: task/attempt lack the two
#     pid_starttime columns added by the new binary.  A terminal sentinel row
#     makes data preservation observable without letting the poll mutate it.
H37="$FLEET_HOME/old-schema-daemon"
FLEET_HOME="$H37" fleet init >/dev/null
T37=$(FLEET_HOME="$H37" fleet add "daemon migration sentinel" \
  --channel shell --spec "$FLEET_HOME/spec_echo.sh")
python3 - "$H37/fleet.db" "$T37" <<'PY37'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute(
    "UPDATE task SET status='done',priority=37,ended_at=98765 WHERE id=?",
    (int(sys.argv[2]),),
)
conn.execute("ALTER TABLE task DROP COLUMN pid_starttime")
conn.execute("ALTER TABLE attempt DROP COLUMN pid_starttime")
conn.commit()
PY37
# Model an old process that was already writing when systemd starts the new
# daemon.  Its BEGIN IMMEDIATE must commit before the migration acquires the
# same SQLite writer lock; the migration must then preserve that committed
# row.  A marker makes the ordering deterministic rather than timing-based.
python3 - "$H37/fleet.db" "$H37/writer.ready" <<'PY37' &
import pathlib, sqlite3, sys, time
conn = sqlite3.connect(sys.argv[1], timeout=15)
conn.execute("BEGIN IMMEDIATE")
conn.execute("INSERT OR REPLACE INTO meta(k,v) VALUES('writer37','committed')")
pathlib.Path(sys.argv[2]).write_text("ready\n")
time.sleep(1)
conn.commit()
PY37
writer37=$!
for _ in $(seq 1 100); do
  [ -f "$H37/writer.ready" ] && break
  sleep .02
done
out37=$(FLEET_HOME="$H37" fleet daemon run --once 2>&1)
rc37a=$?
wait "$writer37"
rc37w=$?
FLEET_HOME="$H37" fleet daemon run --once >/dev/null 2>&1
rc37b=$?
check37=$(python3 - "$H37/fleet.db" "$T37" <<'PY37'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
task_cols = {row[1] for row in conn.execute("PRAGMA table_info(task)")}
attempt_cols = {row[1] for row in conn.execute("PRAGMA table_info(attempt)")}
row = conn.execute(
    "SELECT id,title,status,priority,ended_at FROM task WHERE id=?",
    (int(sys.argv[2]),),
).fetchone()
writer = conn.execute(
    "SELECT v FROM meta WHERE k='writer37'"
).fetchone()
print(int("pid_starttime" in task_cols),
      int("pid_starttime" in attempt_cols), *row, writer[0], sep=":")
PY37
)
if [ "$rc37a" = 0 ] && [ "$rc37b" = 0 ] && [ "$rc37w" = 0 ] \
   && [ "$check37" = "1:1:$T37:daemon migration sentinel:done:37:98765:committed" ] \
   && ! printf '%s\n' "$out37" | grep -q "schema is behind"; then
  ok "daemon waits for an old writer, then migrates idempotently without changing task data"
else
  no "daemon old-schema migration (rc=$rc37a/$rc37b writer=$rc37w row='$check37' out='$out37')"
fi

# 38. An old wrapper may finish after the binary changes but before the new
#     daemon starts. _finish must migrate on its own; otherwise it exits 11
#     and leaves the signed attempt stuck running.
H38="$FLEET_HOME/old-schema-finish"
FLEET_HOME="$H38" fleet init >/dev/null
printf 'sleep 1; echo finish-after-migrate\n' >"$H38/slow.sh"
T38=$(FLEET_HOME="$H38" fleet add "finish migration sentinel" \
  --channel shell --spec "$H38/slow.sh")
FLEET_HOME="$H38" fleet run "$T38" >/dev/null
python3 - "$H38/fleet.db" <<'PY38'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("ALTER TABLE task DROP COLUMN pid_starttime")
conn.execute("ALTER TABLE attempt DROP COLUMN pid_starttime")
conn.commit()
PY38
state38=running
for _ in $(seq 1 60); do
  state38=$(python3 - "$H38/fleet.db" "$T38" <<'PY38'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
print(conn.execute("SELECT status FROM task WHERE id=?",
                   (int(sys.argv[2]),)).fetchone()[0])
PY38
)
  [ "$state38" = done ] && break
  sleep .1
done
check38=$(python3 - "$H38/fleet.db" "$T38" <<'PY38'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
task_cols = {row[1] for row in conn.execute("PRAGMA table_info(task)")}
attempt_cols = {row[1] for row in conn.execute("PRAGMA table_info(attempt)")}
row = conn.execute(
    "SELECT t.status,a.status,t.title FROM task t JOIN attempt a "
    "ON a.attempt_id=t.attempt_id WHERE t.id=?", (int(sys.argv[2]),),
).fetchone()
print(int("pid_starttime" in task_cols),
      int("pid_starttime" in attempt_cols), *row, sep=":")
PY38
)
if [ "$check38" = "1:1:done:done:finish migration sentinel" ] \
   && grep -q "finish-after-migrate" "$H38/runs/$T38/attempt-1/out.md"; then
  ok "_finish migrates an old schema and settles its signed attempt"
else
  no "_finish old-schema migration (state=$state38 row='$check38')"
fi

# 39. Two wrappers can reach _finish while a replacement daemon is starting.
#     Hold the old writer lock until /proc proves BOTH wrappers are in _finish,
#     start the daemon, then release them together.  All three migration
#     callers must serialize and both attempt fences must still settle.
H39="$FLEET_HOME/old-schema-race"
FLEET_HOME="$H39" fleet init >/dev/null
printf 'sleep 1; echo concurrent-finish\n' >"$H39/slow.sh"
T39A=$(FLEET_HOME="$H39" fleet add "concurrent finish A" \
  --channel shell --spec "$H39/slow.sh")
T39B=$(FLEET_HOME="$H39" fleet add "concurrent finish B" \
  --channel shell --spec "$H39/slow.sh")
FLEET_HOME="$H39" fleet run "$T39A" >/dev/null
FLEET_HOME="$H39" fleet run "$T39B" >/dev/null
read -r pid39a pid39b < <(python3 - "$H39/fleet.db" "$T39A" "$T39B" <<'PY39'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
ids = (int(sys.argv[2]), int(sys.argv[3]))
print(*(conn.execute("SELECT pid FROM task WHERE id=?", (tid,)).fetchone()[0]
        for tid in ids))
PY39
)
python3 - "$H39/fleet.db" <<'PY39'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("ALTER TABLE task DROP COLUMN pid_starttime")
conn.execute("ALTER TABLE attempt DROP COLUMN pid_starttime")
conn.commit()
PY39
python3 - "$H39/fleet.db" "$H39/writer.ready" "$H39/writer.release" <<'PY39' &
import pathlib, sqlite3, sys, time
conn = sqlite3.connect(sys.argv[1], timeout=15)
conn.execute("BEGIN IMMEDIATE")
pathlib.Path(sys.argv[2]).write_text("ready\n")
release = pathlib.Path(sys.argv[3])
for _ in range(500):
    if release.exists():
        break
    time.sleep(.02)
else:
    raise RuntimeError("timed out waiting to release writer lock")
conn.commit()
PY39
writer39=$!
for _ in $(seq 1 100); do
  [ -f "$H39/writer.ready" ] && break
  sleep .02
done
finish_waiting39=0
for _ in $(seq 1 150); do
  cmd39a=$(tr '\0' ' ' <"/proc/$pid39a/cmdline" 2>/dev/null || true)
  cmd39b=$(tr '\0' ' ' <"/proc/$pid39b/cmdline" 2>/dev/null || true)
  if printf '%s\n%s\n' "$cmd39a" "$cmd39b" \
       | grep -c ' _finish ' | grep -q '^2$'; then
    finish_waiting39=1
    break
  fi
  kill -0 "$pid39a" 2>/dev/null || break
  kill -0 "$pid39b" 2>/dev/null || break
  sleep .02
done
FLEET_HOME="$H39" fleet daemon run --once >"$H39/daemon.out" 2>&1 &
daemon39=$!
sleep .1
touch "$H39/writer.release"
wait "$writer39"
rc39w=$?
wait "$daemon39"
rc39d=$?
states39=running
for _ in $(seq 1 60); do
  states39=$(python3 - "$H39/fleet.db" "$T39A" "$T39B" <<'PY39'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
print(":".join(conn.execute("SELECT status FROM task WHERE id=?",
                            (int(tid),)).fetchone()[0] for tid in sys.argv[2:]))
PY39
)
  [ "$states39" = done:done ] && break
  sleep .1
done
check39=$(python3 - "$H39/fleet.db" "$T39A" "$T39B" <<'PY39'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
task_cols = {row[1] for row in conn.execute("PRAGMA table_info(task)")}
attempt_cols = {row[1] for row in conn.execute("PRAGMA table_info(attempt)")}
rows = [conn.execute(
    "SELECT t.status,a.status FROM task t JOIN attempt a "
    "ON a.attempt_id=t.attempt_id WHERE t.id=?", (int(tid),),
).fetchone() for tid in sys.argv[2:]]
print(int("pid_starttime" in task_cols),
      int("pid_starttime" in attempt_cols),
      *(value for row in rows for value in row), sep=":")
PY39
)
if [ "$finish_waiting39" = 1 ] && [ "$rc39w" = 0 ] && [ "$rc39d" = 0 ] \
   && [ "$check39" = "1:1:done:done:done:done" ]; then
  ok "daemon and concurrent _finish calls serialize one idempotent migration"
else
  no "concurrent migration (waiting=$finish_waiting39 rc=writer:$rc39w/daemon:$rc39d states=$states39 row='$check39')"
fi

# 40-43. A model-backed implementation task that returns rc=0 but produces no
# claims, no artifacts and no Git delta is empty work: fail it visibly so a
# queued --review-of dependent cannot start. Claims and commits are each valid
# deliverables and must not be caught by the guard. Output-only model work with
# no review path remains valid; the false-success problem is spending review on
# an empty implementation, not every zero-claim report task.
H40="$(mktemp -d /var/tmp/fleet-daemon-empty-worker-XXXX)"
FLEET_HOME="$H40" fleet init >/dev/null
python3 - "$H40/channels.json" <<'PY40'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc["channels"] = {
    "shell": {"adapter": "shell.sh", "family": "none"},
    "model-shell": {
        "adapter": "shell.sh",
        "model": "grok-4.6",
        "models": ["grok-4.6"],
    },
}
json.dump(doc, open(path, "w"), indent=2)
PY40
R40="$H40/repo"
git init -q "$R40"
git -C "$R40" config user.email t@t.t
git -C "$R40" config user.name t
printf 'base\n' >"$R40/file.txt"
git -C "$R40" add file.txt
git -C "$R40" commit -qm base
printf 'printf "I cannot do that.\\n"\n' >"$H40/empty-model.sh"
printf 'echo review-started > "$FLEET_HOME/review-started"\n' >"$H40/review-marker.sh"
W40=$(FLEET_HOME="$H40" fleet add "empty model worker" --channel model-shell \
  --cwd "$R40" --no-preamble --spec "$H40/empty-model.sh")
RV40=$(FLEET_HOME="$H40" fleet add "review of empty model worker" --channel shell \
  --review-of "$W40" --dep "$W40" --no-preamble --spec "$H40/review-marker.sh")
FLEET_HOME="$H40" fleet daemon run --once >/dev/null 2>&1
wait_home_status "$H40" "$W40" failed || true
FLEET_HOME="$H40" fleet daemon run --once >/dev/null 2>&1
worker_empty=$(sqlite3 "$H40/fleet.db" \
  "SELECT COUNT(*) FROM event WHERE task_id=$W40 AND kind='task.worker_empty'")
worker_decisions=$(sqlite3 "$H40/fleet.db" \
  "SELECT COUNT(*) FROM decision WHERE task_id=$W40 AND needs_user=1")
review_status=$(hfield "$H40" "$RV40" status)
review_visible=$(FLEET_HOME="$H40" fleet status --all | grep -c "^$RV40 queued!dep-failed " || true)
if [ "$(hfield "$H40" "$W40" status)" = failed ] \
   && [ "$worker_empty" -ge 1 ] && [ "$worker_decisions" -ge 1 ] \
   && [ "$review_status" = queued ] && [ "$review_visible" -ge 1 ] \
   && [ ! -e "$H40/review-started" ]; then
  ok "empty model worker fails visibly and does not admit its dependent review"
else
  no "empty worker guard (worker=$(hfield "$H40" "$W40" status) event=$worker_empty decision=$worker_decisions review=$review_status visible=$review_visible marker=$(test -e "$H40/review-started" && echo yes || echo no))"
fi

printf 'fleet claim add "$FLEET_TASK_ID" "claim-only ok" --evidence "command: claim-only ok" >/dev/null\nprintf "done\\n"\n' >"$H40/claim-only.sh"
C41=$(FLEET_HOME="$H40" fleet add "claim-only model worker" --channel model-shell \
  --cwd "$R40" --no-preamble --spec "$H40/claim-only.sh")
RV41=$(FLEET_HOME="$H40" fleet add "review of claim-only worker" --channel shell \
  --review-of "$C41" --dep "$C41" --no-preamble --spec "$H40/review-marker.sh")
FLEET_HOME="$H40" fleet daemon run --once >/dev/null 2>&1
if wait_home_status "$H40" "$C41" done \
   && [ "$(sqlite3 "$H40/fleet.db" "SELECT COUNT(*) FROM event WHERE task_id=$C41 AND kind='task.worker_empty'")" = 0 ]; then
  ok "claim-only model worker still completes"
else
  no "claim-only worker (status=$(hfield "$H40" "$C41" status))"
fi

printf 'printf "changed\\n" > committed.txt\ngit add committed.txt\ngit commit -qm commit-only\nprintf "done\\n"\n' >"$H40/commit-only.sh"
C42=$(FLEET_HOME="$H40" fleet add "commit-only model worker" --channel model-shell \
  --cwd "$R40" --no-preamble --spec "$H40/commit-only.sh")
RV42=$(FLEET_HOME="$H40" fleet add "review of commit-only worker" --channel shell \
  --review-of "$C42" --dep "$C42" --no-preamble --spec "$H40/review-marker.sh")
FLEET_HOME="$H40" fleet daemon run --once >/dev/null 2>&1
if wait_home_status "$H40" "$C42" done \
   && [ "$(sqlite3 "$H40/fleet.db" "SELECT COUNT(*) FROM event WHERE task_id=$C42 AND kind='task.worker_empty'")" = 0 ]; then
  ok "commit-only model worker still completes"
else
  no "commit-only worker (status=$(hfield "$H40" "$C42" status))"
fi

N43=$(FLEET_HOME="$H40" fleet add "output-only model worker without review" \
  --channel model-shell --cwd "$R40" --no-preamble --spec "$H40/empty-model.sh")
FLEET_HOME="$H40" fleet daemon run --once >/dev/null 2>&1
if wait_home_status "$H40" "$N43" done \
   && [ "$(sqlite3 "$H40/fleet.db" "SELECT COUNT(*) FROM event WHERE task_id=$N43 AND kind='task.worker_empty'")" = 0 ]; then
  ok "output-only model worker without a review path still completes"
else
  no "output-only no-review worker (status=$(hfield "$H40" "$N43" status))"
fi
rm -rf "$H40"

echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = "0" ]
