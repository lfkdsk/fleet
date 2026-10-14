#!/usr/bin/env bash
# P19: commander is a channel task; daemon cold-starts bounded, fenced rounds.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
PASS=0 FAIL=0 N=0
SCRATCH=()
cleanup(){ cd "$ROOT" || true; for p in "${SCRATCH[@]}"; do rm -rf "$p"; done; }
trap cleanup EXIT
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }
new_home(){
  FLEET_HOME="$(mktemp -d /var/tmp/fleet-p19-test-XXXXXX)"
  SCRATCH+=("$FLEET_HOME"); export FLEET_HOME
  fleet init >/dev/null
  P19_REPO="$FLEET_HOME/target"
  mkdir -p "$P19_REPO"
  git -C "$P19_REPO" init -q
  git -C "$P19_REPO" config user.email p19@example.test
  git -C "$P19_REPO" config user.name p19
  printf 'p19 fixture\n' >"$P19_REPO/input.txt"
  git -C "$P19_REPO" add input.txt
  git -C "$P19_REPO" commit -qm fixture
  # Every implicit cwd in this legacy suite is now a disposable repository.
  # Commander-created workers may create branches/worktrees without touching
  # the source checkout that contains bin/fleet and these tests.
  cd "$P19_REPO"
}
sql(){ sqlite3 -cmd '.timeout 10000' "$FLEET_HOME/fleet.db" "$1"; }
wait_terminal(){ local id="$1" i s; for i in $(seq 1 100); do s=$(sql "SELECT status FROM task WHERE id=$id"); case "$s" in done|failed|cancelled) return 0;; esac; sleep .05; done; return 1; }
finish_as_wrapper(){
  local tid="$1" rc="$2" attempt="$3"
  setsid python3 - "$ROOT/bin/fleet" "$FLEET_HOME/fleet.db" "$tid" "$rc" "$attempt" <<'PY'
import os, sqlite3, sys
fleet, db, tid, rc, attempt = sys.argv[1:]
raw = open(f"/proc/{os.getpid()}/stat").read()
starttime = int(raw[raw.rfind(")") + 2:].split()[19])
conn = sqlite3.connect(db)
conn.execute(
    "UPDATE task SET pid=?,pid_starttime=? WHERE id=? AND attempt_id=?",
    (os.getpid(), starttime, int(tid), attempt),
)
conn.execute(
    "UPDATE attempt SET pid=?,pid_starttime=? WHERE attempt_id=?",
    (os.getpid(), starttime, attempt),
)
conn.commit()
os.execv(fleet, [fleet, "_finish", tid, rc, "--attempt", attempt])
PY
}
poll(){ fleet daemon run --once >/dev/null; }
install_driver(){ local mode="$1" path="$FLEET_HOME/commander-driver.sh"; sed "s/__P19_MODE__/$mode/" "$ROOT/tests/p19_driver.sh" >"$path"; chmod +x "$path"; export FLEET_COMMANDER_SHELL_SCRIPT="$path"; }

# A. Empty enabled goal creates and starts exactly one commander, with lease.
new_home; install_driver review
# Exercise scheduling before start_ready as well: this is the window where
# the lease prevents a second scheduler from creating the same round.
GAP=$(fleet goal add "A-preclaim")
fleet autonomy enable "$GAP" --channel shell --cooldown 0 >/dev/null
python3 - "$ROOT/bin/fleet" <<'PY'
import importlib.machinery,importlib.util,sys
loader=importlib.machinery.SourceFileLoader('fleet_p19',sys.argv[1])
spec=importlib.util.spec_from_loader(loader.name,loader)
f=importlib.util.module_from_spec(spec); loader.exec_module(f)
c=f.db_connect(); f.schedule_autonomy(c,f.load_channels())
PY
preclaim=$(sql "SELECT COUNT(*) FROM lease WHERE resource='commander:goal-$GAP'")
new_home; install_driver slow
GA=$(fleet goal add "A")
fleet autonomy enable "$GA" --channel shell --cooldown 0 >/dev/null
poll
ta=$(sql "SELECT id FROM task WHERE goal_id=$GA AND role='commander'")
if [ "$preclaim" = 1 ] && [ "$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GA AND role='commander'")" = 1 ] && [ "$(sql "SELECT COUNT(*) FROM lease WHERE resource='commander:goal-$GA'")" = 1 ] && [ "$(sql "SELECT status FROM task WHERE id=$ta")" = running ]; then ok "A: one commander starts and owns the goal lease"; else no "A: one commander starts and owns the goal lease (preclaim=$preclaim)"; fi
wait_terminal "$ta" || true

# B. Two candidates become two children and one round event, transactionally.
new_home; install_driver two
GB=$(fleet goal add "B")
fleet autonomy enable "$GB" --channel shell --cooldown 0 >/dev/null; poll
tb=$(sql "SELECT id FROM task WHERE goal_id=$GB AND role='commander'"); wait_terminal "$tb"
b=$(python3 - "$FLEET_HOME/fleet.db" "$tb" <<'PY'
import json,sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.row_factory=sqlite3.Row; tid=int(sys.argv[2])
w=list(c.execute("select * from task where role='worker' order by id")); r=c.execute("select payload from event where kind='commander.round'").fetchone()
assert len(w)==2 and all(x['parent_id']==tid and x['goal_id']==1 for x in w)
assert all('Problem' in open(x['spec_path']).read() and 'Verification' in open(x['spec_path']).read() for x in w)
assert json.loads(r['payload'])['created']==[w[0]['id'],w[1]['id']]
print('ok')
PY
)
[ "$b" = ok ] && ok "B: two candidates apply as child workers and round.created" || no "B: two candidates apply ($b)"

# C. Worker completion wakes round 2; review_ready/no input stays idle.
poll
for w in $(sql "SELECT id FROM task WHERE goal_id=$GB AND role='worker' ORDER BY id"); do wait_terminal "$w"; done
install_driver review; poll
tc=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$GB AND role='commander'"); wait_terminal "$tc"
for _ in 1 2 3 4 5; do poll; done
if [ "$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GB AND role='commander'")" = 2 ] && [ "$(sql "SELECT json_extract(autonomy,'$.last_next_wake') FROM goal WHERE id=$GB")" = review_ready ]; then ok "C: worker completion wakes round 2; review_ready stays asleep"; else no "C: review_ready convergence"; fi

# D. A plan revision changed after construction makes a late result stale/done.
new_home; install_driver review
GD=$(fleet goal add "D"); td=$(fleet add --role commander --goal "$GD" --channel shell --spec "$FLEET_COMMANDER_SHELL_SCRIPT")
printf '[]\n' >"$FLEET_HOME/rules"; fleet plan set "$GD" --rules "$FLEET_HOME/rules" --rationale newer >/dev/null
fleet run "$td" >/dev/null; wait_terminal "$td"
if [ "$(sql "SELECT status FROM task WHERE id=$td")" = done ] && [ "$(sql "SELECT COUNT(*) FROM event WHERE kind='commander.rejected' AND json_extract(payload,'$.reason')='stale'")" = 1 ] && [ "$(sql "SELECT COUNT(*) FROM task WHERE role='worker'")" = 0 ]; then ok "D: superseded plan rejects stale proposal without harming goal"; else no "D: stale proposal rejection"; fi

# E. Invalid JSON retries exactly three times, then stops visibly.
new_home; install_driver bad
GE=$(fleet goal add "E"); fleet autonomy enable "$GE" --channel shell --cooldown 0 >/dev/null
for _ in 1 2 3 4 5 6; do poll; sleep .1; done
te=$(sql "SELECT id FROM task WHERE goal_id=$GE AND role='commander'"); wait_terminal "$te" || true; poll; be=$(fleet brief)
if [ "$(sql "SELECT attempt||':'||status FROM task WHERE id=$te")" = "3:failed" ] && [ "$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GE AND role='commander'")" = 1 ] && printf '%s' "$be" | grep -q 'attempts exhausted'; then ok "E: bad JSON exhausts three attempts and brief explains the stop"; else no "E: bounded invalid-output retry"; fi

# F. Repeated dedup key in a later applied round is skipped.
new_home; install_driver one
GF=$(fleet goal add "F"); fleet autonomy enable "$GF" --channel shell --cooldown 0 >/dev/null; poll
tf=$(sql "SELECT id FROM task WHERE goal_id=$GF AND role='commander'"); wait_terminal "$tf"; poll
wf=$(sql "SELECT id FROM task WHERE goal_id=$GF AND role='worker'"); wait_terminal "$wf"; poll
tf2=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$GF AND role='commander'"); wait_terminal "$tf2"
bf=$(fleet brief)
if [ "$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GF AND role='worker'")" = 1 ] \
   && [ "$(sql "SELECT COUNT(*) FROM event WHERE kind='commander.round' AND json_array_length(json_extract(payload,'$.skipped'))=1")" = 1 ] \
   && [[ "$bf" == *"candidate skipped: dedup"* ]] \
   && [[ "$bf" != *"candidate blocked: dedup"* ]]; then
  ok "F: cross-round dedup is reported as a completed skip, not an environment block"
else no "F: cross-round dedup/brief ($bf)"; fi

# G. needs_user gates scheduling; resolving it creates the next round.
new_home; install_driver review
GG=$(fleet goal add "G"); dg=$(fleet decide "pick scope" --goal "$GG" --needs-user)
fleet autonomy enable "$GG" --channel shell --cooldown 0 >/dev/null; poll
g0=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GG"); gr=$(sql "SELECT json_extract(autonomy,'$.last_reason') FROM goal WHERE id=$GG")
fleet decisions resolve "$dg" >/dev/null; poll; g1=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GG AND role='commander'")
if [ "$g0" = 0 ] && [[ "$gr" == needs_user* ]] && [ "$g1" = 1 ]; then ok "G: unresolved decision pauses, resolve wakes commander"; else no "G: needs_user gate ($g0/$gr/$g1)"; fi

# H. Hard crash after first insert rolls apply back; replay creates once.
new_home; install_driver two
GH=$(fleet goal add "H"); th=$(fleet add --role commander --goal "$GH" --channel shell --spec "$FLEET_COMMANDER_SHELL_SCRIPT")
bash "$FLEET_HOME/runs/$th/prompt.md" >"$FLEET_HOME/runs/$th/out.md"
sql "UPDATE task SET status='running',attempt=1,attempt_id='h-attempt',started_at=strftime('%s','now')-20,pid=NULL,lease='commander:goal-$GH',commander_lease_generation=1; INSERT INTO lease(resource,holder,acquired_at,expires_at,generation) VALUES('commander:goal-$GH','$th',strftime('%s','now'),strftime('%s','now')+3600,1)"
FLEET_COMMANDER_CRASH_AFTER_FIRST_TASK=1 finish_as_wrapper "$th" 0 h-attempt >/dev/null 2>&1
rh=$?; after_crash=$(sql "SELECT COUNT(*) FROM task WHERE role='worker'")
FLEET_ORPHAN_GRACE_S=0 fleet daemon run --once >/dev/null
wait_terminal "$th"
hstatus=$(sql "SELECT status||':'||attempt FROM task WHERE id=$th")
hworkers=$(sql "SELECT COUNT(*) FROM task WHERE role='worker'")
hrounds=$(sql "SELECT COUNT(*) FROM event WHERE kind='commander.round'")
if [ "$rh" = 86 ] && [ "$after_crash" = 0 ] && [ "$hworkers" = 2 ] && [ "$hrounds" = 1 ] && [ "$hstatus" = done:1 ]; then ok "H: daemon restart replays rolled-back apply without duplicates"; else no "H: atomic crash recovery (rc=$rh after=$after_crash status=$hstatus workers=$hworkers rounds=$hrounds)"; fi

# I. Two independent once-daemons racing yield one commander (lock or lease).
new_home; install_driver review
GI=$(fleet goal add "I"); fleet autonomy enable "$GI" --channel shell --cooldown 0 >/dev/null
fleet daemon run --once >"$FLEET_HOME/i1" 2>&1 & pi1=$!
fleet daemon run --once >"$FLEET_HOME/i2" 2>&1 & pi2=$!
wait $pi1; ri1=$?; wait $pi2; ri2=$?
if [ "$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GI AND role='commander'")" = 1 ] && { [ "$ri1" != 0 ] || [ "$ri2" != 0 ]; }; then ok "I: concurrent once-daemons produce one commander"; else no "I: concurrent daemon fencing ($ri1/$ri2)"; fi

# J. max_rounds=2 prevents a third round and records the exact reason.
new_home; install_driver review
GJ=$(fleet goal add "J"); fleet autonomy enable "$GJ" --channel shell --max-rounds 2 --cooldown 0 >/dev/null
poll; tj1=$(sql "SELECT MAX(id) FROM task WHERE role='commander'"); wait_terminal "$tj1"
fleet decide "new info" --goal "$GJ" >/dev/null; poll; tj2=$(sql "SELECT MAX(id) FROM task WHERE role='commander'"); wait_terminal "$tj2"
fleet decide "newer info" --goal "$GJ" >/dev/null; poll
if [ "$(sql "SELECT COUNT(*) FROM task WHERE role='commander'")" = 2 ] && [ "$(sql "SELECT json_extract(autonomy,'$.last_reason') FROM goal WHERE id=$GJ")" = "rounds exhausted" ]; then ok "J: max_rounds=2 blocks round 3"; else no "J: round cap"; fi

# K. Oversized summaries and 200 blocked events still produce <=48 KiB prompt.
new_home; install_driver review
GK=$(fleet goal add "K"); wk=$(fleet add "noise" --channel shell --goal "$GK" --spec "$FLEET_COMMANDER_SHELL_SCRIPT")
python3 - "$FLEET_HOME/fleet.db" "$wk" <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); tid=int(sys.argv[2])
c.execute("insert into artifact(task_id,path,summary,ts) values(?,?,?,?)",(tid,'/tmp/huge','Z'*60000,int(time.time())))
for _ in range(200): c.execute("insert into event(ts,task_id,kind,payload) values(?,?,?,?)",(int(time.time()),tid,'task.blocked','{"reason":"dep"}'))
c.commit()
PY
tk=$(fleet add --role commander --goal "$GK" --channel shell --spec "$FLEET_COMMANDER_SHELL_SCRIPT"); pk="$FLEET_HOME/runs/$tk/prompt.md"
if [ "$(wc -c <"$pk")" -le 49152 ] && grep -q '已截断' "$pk" && grep -q 'task.blocked x200' "$pk"; then ok "K: prompt cap and folded blocked-event count are visible"; else no "K: bounded prompt ($(wc -c <"$pk"))"; fi

# L. Manual commander without autonomy uses the same apply path.
new_home; install_driver one
GL=$(fleet goal add "L"); tl=$(fleet add --role commander --goal "$GL" --channel shell --spec "$FLEET_COMMANDER_SHELL_SCRIPT")
fleet run "$tl" >/dev/null; wait_terminal "$tl"
if [ "$(sql "SELECT COUNT(*) FROM task WHERE role='worker' AND parent_id=$tl")" = 1 ] && [ "$(sql "SELECT COUNT(*) FROM event WHERE kind='commander.round' AND task_id=$tl")" = 1 ]; then ok "L: manual commander follows the production apply path"; else no "L: manual commander apply"; fi

# M. A pre-P19 ledger gains columns, preserving old task role=worker.
new_home
python3 - "$FLEET_HOME/fleet.db" <<'PY'
import sqlite3,sys
p=sys.argv[1]; c=sqlite3.connect(p)
c.execute('alter table task drop column commander_through_event_id')
c.execute('alter table task drop column commander_plan_revision')
c.execute('alter table task drop column role')
c.execute('alter table goal drop column autonomy')
c.execute("insert into goal(id,statement,created_at) values(3,'old goal',1)")
c.execute("insert into task(id,title,channel,family,status,cwd,created_at) values(7,'old','shell','none','done','/tmp',1)")
c.commit()
PY
fleet init >/dev/null
old_read=$(fleet --json status --all)
if [ "$(sql "SELECT role FROM task WHERE id=7")" = worker ] && [ "$(sql "SELECT autonomy IS NULL FROM goal WHERE id=3")" = 1 ] && printf '%s' "$old_read" | grep -q '"id": 7'; then ok "M: init migrates old ledgers and defaults old tasks to worker"; else no "M: old ledger migration"; fi

# N. Six-round offline chain, 30 polls: bounded, unique keys, no lease residue.
new_home; install_driver chain
GN=$(fleet goal add "N"); fleet autonomy enable "$GN" --channel shell --max-rounds 6 --cooldown 0 >/dev/null
for _ in $(seq 1 30); do poll; sleep .08; done
rn=$(sql "SELECT COUNT(*) FROM event WHERE kind='commander.round'")
un=$(sql "SELECT COUNT(DISTINCT json_extract(value,'$.dedup_key')) FROM event,json_each(json_extract(payload,'$.proposed')) WHERE kind='commander.round'")
wn=$(sql "SELECT COUNT(*) FROM task WHERE role='worker'"); ln=$(sql "SELECT COUNT(*) FROM lease WHERE resource='commander:goal-$GN'")
if [ "$rn" = 6 ] && [ "$un" = "$wn" ] && [ "$ln" = 0 ]; then ok "N: 30-poll soak caps rounds, keeps keys unique, releases lease"; else no "N: offline soak (rounds=$rn unique=$un workers=$wn leases=$ln)"; fi

# O. Failed commander tasks consume rounds and two consecutive failures pause
# even when fresh goal events keep arriving; re-enable explicitly resets it.
new_home; install_driver bad
GO=$(fleet goal add "O"); fleet autonomy enable "$GO" --channel shell --max-rounds 5 --max-failures 2 --cooldown 0 >/dev/null
for target in 1 2; do
  for _ in $(seq 1 100); do
    poll; sleep .04
    [ "$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GO AND role='commander' AND status='failed'")" -ge "$target" ] && break
  done
  fleet decide "new input after failed commander $target" --goal "$GO" >/dev/null
done
for _ in 1 2 3 4 5; do poll; done
ocount=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GO AND role='commander'")
orounds=$(sql "SELECT json_extract(autonomy,'$.rounds_used') FROM goal WHERE id=$GO")
ofailures=$(sql "SELECT json_extract(autonomy,'$.consecutive_failures') FROM goal WHERE id=$GO")
oreason=$(sql "SELECT json_extract(autonomy,'$.last_reason') FROM goal WHERE id=$GO")
fleet autonomy enable "$GO" --channel shell --max-rounds 5 --max-failures 2 --cooldown 0 >/dev/null
poll
oafter=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GO AND role='commander'")
if [ "$ocount:$orounds:$ofailures:$oafter" = "2:2:2:3" ] && [[ "$oreason" == *consecutive* ]]; then ok "O: failed rounds count, consecutive failure pause, and re-enable reset"; else no "O: failed-round circuit breaker ($ocount/$orounds/$ofailures/$oreason/$oafter)"; fi

# P. Only created/dedup-skipped keys persist across rounds. Candidates skipped
# solely by max_new_tasks remain eligible and one advances on the next round.
new_home; install_driver three
GP=$(fleet goal add "P"); fleet autonomy enable "$GP" --channel shell --max-rounds 3 --max-new-tasks 1 --cooldown 0 >/dev/null
poll; tp1=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$GP AND role='commander'"); wait_terminal "$tp1"
poll; wp1=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$GP AND role='worker'"); wait_terminal "$wp1"
poll; tp2=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$GP AND role='commander'"); wait_terminal "$tp2"
p=$(python3 - "$FLEET_HOME/fleet.db" <<'PY'
import json,sqlite3,sys
c=sqlite3.connect(sys.argv[1])
rounds=[json.loads(r[0]) for r in c.execute(
    "select payload from event where kind='commander.round' order by id")]
assert len(rounds)==2
assert rounds[0]['created_keys']==['alpha']
assert [x['reason'] for x in rounds[0]['skipped']]==['max_new_tasks','max_new_tasks']
assert rounds[1]['created_keys']==['beta']
assert [(x['dedup_key'],x['reason']) for x in rounds[1]['skipped']]==[
    ('alpha','dedup'),('gamma','max_new_tasks')]
assert c.execute("select count(*) from task where role='worker'").fetchone()[0]==2
print('ok')
PY
)
[ "$p" = ok ] && ok "P: transiently skipped candidates remain eligible next round" || no "P: retry skipped candidates ($p)"

# Q. A task_done->enqueue_review rule must not review the COMMANDER's own
# rounds. The commander's deliverable is a JSON proposal the daemon already
# validates, but the rule saw a done task with
# no review_of and dispatched a review of it -- which the enqueue gate refused,
# which wrote a needs_user decision, which schedule_autonomy treats as a pause.
# Every round hit it, so no goal ever reached round two.
#
# The rule here uses channel "auto" deliberately: it is the case a same-family
# refusal cannot explain away. auto WOULD find a legal reviewer for the
# commander (its channel is family=none), so if anything still reviewed
# commander rounds, a review task would exist. Only the role filter stops it.
#
# The channel table is REPLACED, not extended, and the rule names qgpt in
# with.prefer -- belt and braces, because the failure this guards against was
# not a wrong assertion, it was a real bill. `fleet init` seeds channels.json
# from the shipped registry, so the original "add qgpt to whatever is there"
# fixture left several unrelated channels in the candidate set; auto
# picked codex (gpt-5.6-sol) for a `printf` worker, 3/3, and each timeout left
# a live paid process running. A test must not be able to reach a real model
# even if the picker regresses again: nothing here has an adapter other than
# shell.sh, so the worst case is a fake reviewer, not a charge.
new_home; install_driver chain
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"] = {
    "shell": {"adapter": "shell.sh", "family": "none"},
    "qgpt": {"adapter": "shell.sh", "model": "GPT-5.5", "models": ["GPT-5.5"]},
}
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
# qgpt is named in prefer AND probed: prefer alone would carry the pick today,
# but the probe row keeps the case honest against the never-probed exclusion
# rather than resting on the one clause that bypasses it.
python3 - "$FLEET_HOME/fleet.db" <<'PY'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT OR REPLACE INTO model_probe(channel,model,ok,checked_at,note)"
          " VALUES('qgpt','GPT-5.5',1,?,'p19 fixture')", (int(time.time()),))
c.commit()
PY
GQ=$(fleet goal add "Q")
printf '[{"on":"task_done","do":"enqueue_review","with":{"channel":"auto","prefer":["qgpt"]}}]\n' >"$FLEET_HOME/rulesQ"
fleet plan set "$GQ" --rules "$FLEET_HOME/rulesQ" --rationale "auto review every done task" >/dev/null
fleet autonomy enable "$GQ" --channel shell --max-rounds 3 --cooldown 0 >/dev/null
for _ in $(seq 1 40); do
  poll; sleep .08
  [ "$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GQ AND role='commander'")" -ge 2 ] && break
done
for t in $(sql "SELECT id FROM task WHERE goal_id=$GQ"); do wait_terminal "$t" || true; done
poll
qcmd=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GQ AND role='commander'")
qcmd_rev=$(sql "SELECT COUNT(*) FROM task WHERE review_of IN (SELECT id FROM task WHERE goal_id=$GQ AND role='commander')")
qwork_rev=$(sql "SELECT COUNT(*) FROM task WHERE review_of IN (SELECT id FROM task WHERE goal_id=$GQ AND role='worker')")
qdec=$(sql "SELECT COUNT(*) FROM decision WHERE goal_id=$GQ AND needs_user=1")
qreason=$(sql "SELECT json_extract(autonomy,'\$.last_reason') FROM goal WHERE id=$GQ")
# Every review this case produced went to qgpt. Without this, a picker that
# reached past the fixture would still pass -- which is exactly how the codex
# incident hid: the case measured "a review exists", never which channel paid
# for it.
qbad=$(sql "SELECT COUNT(*) FROM task WHERE review_of IS NOT NULL AND channel<>'qgpt'")
# qwork_rev>=1 is not decoration: without it a rule that fired for nothing at
# all would pass this case just as well as the fix does.
if [ "$qcmd" -ge 2 ] && [ "$qcmd_rev" = 0 ] && [ "$qwork_rev" -ge 1 ] && [ "$qdec" = 0 ] \
   && [ "$qbad" = 0 ] && [[ "$qreason" != needs_user* ]]; then
  ok "Q: rules review workers but never commander rounds, so autonomy keeps its rounds"
else
  no "Q: commander rounds exempt from enqueue_review (rounds=$qcmd cmd_reviews=$qcmd_rev worker_reviews=$qwork_rev decisions=$qdec off_fixture=$qbad reason=$qreason)"
fi

# R. A commander-proposed Reviewer carries a typed review_of edge.  The
# existing create_task gate rejects the same-family candidate, while an
# opposite-family candidate is created with task.review_of intact and gets the
# mechanically constructed branch/claim review checklist after the commander's
# own task spec.  The mixed created/skipped result remains visible in brief.
# Shell adapters keep this test offline; their declared model families still
# run the same cross-family checks as production model channels.
new_home; install_driver review-candidates
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["channels"]={
    "shell": {"adapter": "shell.sh", "family": "none"},
    "review-gpt": {"adapter": "shell.sh", "model": "GPT-5.5",
                   "models": ["GPT-5.5"]},
    "review-claude": {"adapter": "shell.sh", "model": "claude-opus",
                      "models": ["claude-opus"]},
}
json.dump(d,open(p,'w'),indent=2)
PY
GR=$(fleet goal add "R")
WR=$(fleet add "review target" --channel review-gpt --goal "$GR" \
  --cwd "$P19_REPO" --spec "$FLEET_COMMANDER_SHELL_SCRIPT" \
  --worktree --no-preamble)
fleet run "$WR" >/dev/null; wait_terminal "$WR"
FLEET_TASK_ID= FLEET_ATTEMPT= fleet claim add "$WR" "review-claim-marker" \
  --evidence "review-evidence-marker:1" >/dev/null
export FLEET_TEST_REVIEW_OF="$WR"
fleet autonomy enable "$GR" --channel shell --cwd "$P19_REPO" \
  --max-rounds 1 --cooldown 0 >/dev/null
poll; TR=$(sql "SELECT id FROM task WHERE goal_id=$GR AND role='commander'")
wait_terminal "$TR"
RBRIEF=$(fleet brief)
r=$(python3 - "$FLEET_HOME/fleet.db" "$WR" "$P19_REPO" <<'PY'
import json,pathlib,sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.row_factory=sqlite3.Row; source=int(sys.argv[2])
workers=list(c.execute("select * from task where role='worker' order by id"))
created=[w for w in workers if w['id'] != source]
assert len(created)==1,[(w['id'],w['channel'],w['review_of']) for w in workers]
assert created[0]['channel']=='review-claude' and created[0]['review_of']==source
reviewed=c.execute('select * from task where id=?',(source,)).fetchone()
assert created[0]['cwd']==str(pathlib.Path(sys.argv[3]).resolve())
assert created[0]['cwd'] != reviewed['worktree']
prompt=pathlib.Path(created[0]['spec_path']).read_text()
assert '## Problem\nprintf worker' in prompt
assert f"- branch: {reviewed['worktree_branch']}" in prompt
assert 'review-claim-marker' in prompt and 'review-evidence-marker:1' in prompt
assert prompt.index('## Problem') < prompt.index(f'Review task {source}:')
payload=json.loads(c.execute(
    "select payload from event where kind='commander.round'").fetchone()[0])
assert payload['created']==[created[0]['id']]
assert payload['proposed'][0]['review_of']==source
assert payload['proposed'][1]['review_of']==source
assert len(payload['skipped'])==1
skip=payload['skipped'][0]
assert skip['dedup_key']=='review-same'
assert 'cross-family violation' in skip['reason'] and f'task {source}' in skip['reason']
print('ok')
PY
)
if [ "$r" = ok ] && [[ "$RBRIEF" == *"waiting_for_tasks (+1 proposal rejected)"* ]] \
   && [[ "$RBRIEF" == *"1 proposal rejected in last round"* ]]; then
  ok "R: review_of keeps intent plus branch/claims, and brief counts the same-family rejection"
else
  no "R: commander review_of construction/brief (check=$r brief=$RBRIEF)"
fi

# S. Every enqueue-gate refusal is a first-class event with the candidate
# identity and the same exit-code meaning as `fleet add`.  The latest-round
# count is visible on both brief and status, and the next commander receives
# the exact rejection as protocol input instead of having to infer it from a
# folded `commander.round` line.  A failed model probe exercises the bad-channel
# path independently of the same-family review case above.
new_home; install_driver review-same
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["channels"]={
    "shell": {"adapter": "shell.sh", "family": "none"},
    "review-gpt": {"adapter": "shell.sh", "model": "GPT-5.5",
                   "models": ["GPT-5.5"]},
    "review-claude": {"adapter": "shell.sh", "model": "claude-opus",
                      "models": ["claude-opus"]},
}
json.dump(d,open(p,'w'),indent=2)
PY
GS=$(fleet goal add "S")
WS=$(fleet add "review target" --channel review-gpt --goal "$GS" \
  --cwd "$P19_REPO" --spec "$FLEET_COMMANDER_SHELL_SCRIPT" \
  --worktree --no-preamble)
fleet run "$WS" >/dev/null; wait_terminal "$WS"
export FLEET_TEST_REVIEW_OF="$WS"
fleet autonomy enable "$GS" --channel shell --cwd "$P19_REPO" \
  --max-rounds 3 --cooldown 0 >/dev/null
poll; CS1=$(sql "SELECT id FROM task WHERE goal_id=$GS AND role='commander'")
wait_terminal "$CS1"
SBRIEF=$(fleet brief); SSTATUS=$(fleet status --all --goal "$GS")
SSTATUS_JSON=$(fleet --json status --all --goal "$GS")
# The first policy rejection is new information, so one corrective round is
# schedulable even though no worker was created. Repeating the exact same
# candidate in that round must not schedule a third round.
poll
CS2=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$GS AND role='commander'")
SPROMPT=$(sql "SELECT spec_path FROM task WHERE id=$CS2")
wait_terminal "$CS2"
for _ in 1 2 3 4 5 6 7 8; do poll; done
SCMDS=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GS AND role='commander'")
s=$(python3 - "$FLEET_HOME/fleet.db" "$CS1" "$CS2" "$SPROMPT" <<'PY'
import json,sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.row_factory=sqlite3.Row
first,second=map(int,sys.argv[2:4])
events=list(c.execute(
    "select * from event where task_id=? and kind='proposal.rejected'",(first,)))
assert len(events)==1,events
event=json.loads(events[0]['payload'])
assert event['title']=='worker review-same'
assert event['channel']=='review-gpt' and event['review_of'] is not None
assert 'cross-family violation' in event['reason']
assert event['exit_code']==2 and 'fleet add exit 2' in event['exit_code_semantics']
assert event['rejection_class']=='policy' and event['repeated'] is False
repeated=list(c.execute(
    "select * from event where task_id=? and kind='proposal.rejected'",(second,)))
assert len(repeated)==1,repeated
repeat=json.loads(repeated[0]['payload'])
assert repeat['rejection_class']=='policy' and repeat['repeated'] is True
assert repeat['rejection_fingerprint']==event['rejection_fingerprint']
assert repeat['repeated_from_round']==first
assert c.execute("select count(*) from task where role='worker' and id!=?",
                 (event['review_of'],)).fetchone()[0]==0
text=open(sys.argv[4]).read()
begin=": <<'FLEET_COMMANDER_PROMPT'\n"
if begin in text:
    text=text.split(begin,1)[1].rsplit("FLEET_COMMANDER_PROMPT\n",1)[0]
prompt=json.loads(text)
feedback=prompt['previous_proposal_rejections']
assert feedback['round_task']==first and feedback['total']==1,feedback
assert feedback['items'][0]['event_id']==events[0]['id']
assert feedback['items'][0]['reason']==event['reason']
assert 'do not repeat' in feedback['instruction'].lower()
print('ok')
PY
)
SJSON_COUNT=$(printf '%s' "$SSTATUS_JSON" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(max(x["proposal_rejections"] for x in d))')
if [ "$s" = ok ] && [[ "$SBRIEF" == *"1 proposal rejected in last round"* ]] \
   && [[ "$SSTATUS" == *"PROPOSAL-REJECTED=1"* ]] \
   && [ "$SJSON_COUNT" = 1 ] \
   && [ "$CS2" -gt "$CS1" ] \
   && [ "$SCMDS" = 2 ]; then
  ok "S: same-family refusal wakes one correction; unchanged repeat backs off"
else
  no "S: rejection correction/backoff (check=$s first=$CS1 second=$CS2 commanders=$SCMDS brief='$SBRIEF' status='$SSTATUS')"
fi

# T. A channel whose latest probe failed is rejected with exit-6 semantics and
# gets exactly the same visibility/feedback treatment as a review invariant.
new_home; install_driver probe-failed
python3 - "$FLEET_HOME/channels.json" "$FLEET_HOME/fleet.db" <<'PY'
import json,sqlite3,sys,time
p,db=sys.argv[1:]; d=json.load(open(p))
d["channels"]={
    "shell": {"adapter": "shell.sh", "family": "none"},
    "review-claude": {"adapter": "shell.sh", "model": "claude-opus",
                      "models": ["claude-opus"]},
}
json.dump(d,open(p,'w'),indent=2)
c=sqlite3.connect(db)
c.execute("insert into model_probe(channel,model,ok,checked_at,note) "
          "values('review-claude','claude-opus',0,?,'credentials unavailable')",
          (int(time.time()),))
c.commit()
PY
GT=$(fleet goal add "T")
fleet autonomy enable "$GT" --channel shell --cwd "$P19_REPO" \
  --max-rounds 4 --cooldown 0 >/dev/null
poll; CT=$(sql "SELECT id FROM task WHERE goal_id=$GT AND role='commander'")
wait_terminal "$CT"
for _ in 1 2 3 4 5 6 7 8; do poll; done
t=$(python3 - "$FLEET_HOME/fleet.db" "$CT" <<'PY'
import json,sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.row_factory=sqlite3.Row
row=c.execute("select payload from event where task_id=? and kind='proposal.rejected'",
              (int(sys.argv[2]),)).fetchone()
assert row is not None
p=json.loads(row['payload'])
assert p['title']=='worker probe-failed' and p['channel']=='review-claude'
assert 'failed its last probe' in p['reason'] and 'credentials unavailable' in p['reason']
assert p['exit_code']==6 and 'fleet add exit 6' in p['exit_code_semantics']
assert p['rejection_class']=='channel_health' and p['repeated'] is False
assert c.execute("select count(*) from task where role='worker'").fetchone()[0]==0
assert c.execute("select count(*) from task where role='commander'").fetchone()[0]==1
assert c.execute("select count(*) from event where kind='proposal.rejected'").fetchone()[0]==1
state=json.loads(c.execute("select autonomy from goal where id=1").fetchone()[0])
assert state['rounds_used']==1 and state['max_rounds']==4,state
print('ok')
PY
)
if [ "$t" = ok ] && fleet brief | grep -q "1 proposal rejected in last round"; then
  ok "T: failed-probe rejection records exit 6 and stays at one of four rounds"
else
  no "T: failed-probe rejection classification/backoff (check=$t)"
fi

# U. Overlong candidate titles (71-char English, 48-char Chinese) are clipped
# instead of voiding the round; the commander.round event keeps both originals.
new_home; install_driver longtitle
GU=$(fleet goal add "U"); fleet autonomy enable "$GU" --channel shell --cooldown 0 >/dev/null
poll
tu=$(sql "SELECT id FROM task WHERE goal_id=$GU AND role='commander'"); wait_terminal "$tu"
u=$(python3 - "$FLEET_HOME/fleet.db" "$tu" <<'PY'
import json,sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.row_factory=sqlite3.Row; tid=int(sys.argv[2])
commander=c.execute("select status,attempt from task where id=?",(tid,)).fetchone()
assert commander['status']=='done' and commander['attempt']==1,(
    "commander must settle on round one: ",dict(commander))
rounds=list(c.execute(
    "select payload from event where task_id=? and kind='commander.round'",(tid,)))
assert len(rounds)==1, rounds
p=json.loads(rounds[0]['payload'])
assert len(p['created'])==2, p
workers=[dict(r) for r in c.execute(
    "select title from task where parent_id=? order by id",(tid,))]
en,cn=workers
assert len(en['title'])==40 and en['title'].endswith('…'),en
# Python len(str), not display width: 39 CJK chars + the marker == 40 chars.
assert len(cn['title'])==40 and cn['title'].endswith('…'),cn
assert all(ord(ch)>127 for ch in cn['title'][:-1]),cn
clips=p.get('title_clips')
assert clips and len(clips)==2, clips
by_key={x['dedup_key']:x for x in clips}
assert by_key['long-en']['original_title']=='E'*71
assert by_key['long-en']['original_chars']==71
assert by_key['long-cn']['original_title']=='超长标题'*12
assert by_key['long-cn']['original_chars']==48
assert by_key['long-en']['clipped_title']==en['title']
assert by_key['long-cn']['clipped_title']==cn['title']
rejected=c.execute(
    "select count(*) from event where task_id=? and kind='proposal.rejected'",
    (tid,)).fetchone()[0]
assert rejected==0, rejected
print('ok')
PY
)
[ "$u" = ok ] && ok "U: overlong EN/CJK titles are clipped to 40 chars and original titles ride the round event" || no "U: title truncation round ($u)"

# V. The title relaxation clips only titles: another genuinely invalid field
# still voids the whole proposal and burns the attempts.
new_home; install_driver longtitle-bad
GV=$(fleet goal add "V"); fleet autonomy enable "$GV" --channel shell --cooldown 0 >/dev/null
for _ in $(seq 1 8); do poll; sleep .05; done
tv=$(sql "SELECT id FROM task WHERE goal_id=$GV AND role='commander'"); wait_terminal "$tv" || true
vstatus=$(sql "SELECT status||':'||attempt FROM task WHERE id=$tv")
vworkers=$(sql "SELECT COUNT(*) FROM task WHERE role='worker'")
vrejects=$(sql "SELECT COUNT(*) FROM event WHERE kind='commander.rejected'")
vrounds=$(sql "SELECT COUNT(*) FROM event WHERE kind='commander.round'")
if [ "$vstatus" = failed:3 ] && [ "$vworkers" = 0 ] && [ "$vrejects" = 3 ] && [ "$vrounds" = 0 ]; then
  ok "V: non-title invalid fields still reject the whole proposal across 3 attempts"
else no "V: whole-proposal rejection ($vstatus workers=$vworkers rejects=$vrejects rounds=$vrounds)"; fi

echo ---
echo "passed $PASS / $N"
[ "$FAIL" = 0 ]


