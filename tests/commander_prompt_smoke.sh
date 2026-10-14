#!/usr/bin/env bash
# Commander prompt contract: always parseable JSON, always <=48 KiB, and the
# protocol core always intact no matter how big the ledger behind it is.
#
# Before this suite the prompt was clipped as bytes at 48 KiB: a 60 KB
# acceptance clause pushed response_example, through_event_id and the
# unresolved needs_user gate off the end, and left the body cut mid-string so
# it did not parse. p19 K only checked the size and the presence of 已截断,
# both of which the broken prompt satisfied. Every case here parses the body
# as JSON and reads values out of it (tests/commander_prompt_check.py).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
CHECK="$ROOT/tests/commander_prompt_check.py"
PASS=0 FAIL=0 N=0
SCRATCH=()
cleanup(){ for p in "${SCRATCH[@]}"; do rm -rf "$p"; done; }
trap cleanup EXIT
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }
new_home(){ FLEET_HOME="$(mktemp -d /var/tmp/fleet-cprompt-XXXXXX)"; SCRATCH+=("$FLEET_HOME"); export FLEET_HOME; fleet init >/dev/null; }
sql(){ sqlite3 -cmd '.timeout 10000' "$FLEET_HOME/fleet.db" "$1"; }
# One-line driver, so the wrapper is negligible except in case F.
small_driver(){ local p="$FLEET_HOME/driver.sh"; printf '#!/usr/bin/env bash\nprintf FLEET_DRIVER_MARK\n' >"$p"; chmod +x "$p"; echo "$p"; }
# Every case asserts against the values the ledger actually holds, not
# hardcoded numbers: a construction that reports a stale watermark would
# otherwise pass.
watermark(){ sql "SELECT COALESCE(MAX(e.id),0) FROM event e LEFT JOIN task t ON e.task_id=t.id WHERE e.goal_id=$1 OR t.goal_id=$1"; }
# `fleet add` writes events of its own, and commander_construction freezes the
# watermark before that insert. So the expected watermark and revision are read
# BEFORE the enqueue -- reading them after would compare the prompt against a
# ledger that moved on, and the mismatch would look like a construction bug.
snapshot(){ WM=$(watermark "$1"); RV=$(revision "$1"); }
revision(){ sql "SELECT COALESCE((SELECT revision FROM plan WHERE goal_id=$1 ORDER BY revision DESC LIMIT 1),0)"; }
run_check(){ local out; out=$(python3 "$CHECK" "$@" 2>&1); [ "$out" = ok ] || { echo "$out"; return 1; }; }

# A. A small goal produces parseable JSON and claims no truncation.
new_home
GA=$(fleet goal add "small goal" --acceptance "tests pass")
DA=$(small_driver)
snapshot "$GA"
TA=$(fleet add --role commander --goal "$GA" --channel shell --spec "$DA")
PA="$FLEET_HOME/runs/$TA/prompt.md"
if msg=$(run_check clean "$PA" "$GA" "$RV" "$WM"); then
  ok "A: a small ledger yields parseable JSON with no truncation claimed"
else no "A: clean prompt ($msg)"; fi

# B. Giant UTF-8 goal + acceptance + plan (60k chars each, multi-byte) must not
# displace the protocol core -- the original failure, in its own case.
new_home
GB=$(fleet goal add "B")
python3 - "$FLEET_HOME/fleet.db" "$GB" <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); g=int(sys.argv[2])
# Multi-byte on purpose: a byte-slice truncation splits these characters and
# the strict UTF-8 decode in the checker catches it.
big=lambda tag: tag+"。测试"*20000
c.execute("update goal set statement=?,acceptance=?,approval_gates=? where id=?",
          (big("STMT"),big("ACC"),big("GATE"),g))
c.execute("insert into plan(goal_id,revision,rationale,dag,rules,created_at) values(?,?,?,?,?,?)",
          (g,7,big("RAT"),big("DAG"),big("RULES"),int(time.time())))
c.commit()
PY
DB=$(small_driver)
snapshot "$GB"
TB=$(fleet add --role commander --goal "$GB" --channel shell --spec "$DB")
PB="$FLEET_HOME/runs/$TB/prompt.md"
if msg=$(run_check giant "$PB" "$GB" "$RV" "$WM" "ACC"); then
  ok "B: 60k-char UTF-8 goal/acceptance/plan keeps the protocol core intact"
else no "B: giant goal ($msg)"; fi
# The same construction is what a model channel gets: no driver, same contract.
snapshot "$GB"
TB2=$(fleet add --role commander --goal "$GB" --channel claude-p)
if msg=$(run_check giant "$FLEET_HOME/runs/$TB2/prompt.md" "$GB" "$RV" "$WM" "ACC"); then
  ok "B2: an unwrapped model-channel prompt honours the same contract"
else no "B2: unwrapped giant prompt ($msg)"; fi

# C. 400 unresolved needs_user decisions with huge questions: existence, the
# exact total, bounded ids and the ledger query must all survive.
new_home
GC=$(fleet goal add "C")
python3 - "$FLEET_HOME/fleet.db" "$GC" <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); g=int(sys.argv[2]); t=int(time.time())
for i in range(400):
    c.execute("insert into decision(goal_id,question,evidence,needs_user,ts)"
              " values(?,?,?,1,?)",(g,f"Q{i} "+"决策"*400,"E"*2000,t))
c.commit()
PY
NC=$(sql "SELECT COUNT(*) FROM decision WHERE goal_id=$GC AND needs_user=1 AND resolved_at IS NULL")
DC=$(small_driver)
snapshot "$GC"
TC=$(fleet add --role commander --goal "$GC" --channel shell --spec "$DC")
if msg=$(run_check needsuser "$FLEET_HOME/runs/$TC/prompt.md" "$GC" "$RV" "$WM" "$NC"); then
  ok "C: 400 needs_user decisions keep existence, total, ids and a query ($NC)"
else no "C: needs_user under flood ($msg)"; fi

# D. 3000 folded events across 300 tasks: after_event_id, coverage and the
# omitted count stay exact and a pointer reproduces the full fold.
new_home
GD=$(fleet goal add "D")
python3 - "$FLEET_HOME/fleet.db" "$GD" <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); g=int(sys.argv[2]); t=int(time.time())
for i in range(300):
    cur=c.execute("insert into task(title,goal_id,channel,family,status,cwd,created_at,role)"
                  " values(?,?,'shell','none','done','/tmp',?, 'worker')",(f"t{i}",g,t))
    tid=cur.lastrowid
    for _ in range(10):
        c.execute("insert into event(ts,task_id,kind,payload) values(?,?,'task.blocked',?)",
                  (t,tid,'{"reason":"dep"}'))
c.commit()
PY
ED=$(sql "SELECT COUNT(*) FROM event e LEFT JOIN task t ON e.task_id=t.id WHERE e.goal_id=$GD OR t.goal_id=$GD")
DD=$(small_driver)
snapshot "$GD"
TD=$(fleet add --role commander --goal "$GD" --channel shell --spec "$DD")
if msg=$(run_check folded "$FLEET_HOME/runs/$TD/prompt.md" "$GD" "$RV" "$WM" 0 "$ED"); then
  ok "D: $ED events over 300 tasks keep the increment window and omission counts"
else no "D: folded increment ($msg)"; fi

# D2. An incremental round: after_event_id must be the previous watermark, not 0.
prev=$(watermark "$GD")
python3 - "$FLEET_HOME/fleet.db" "$GD" "$prev" <<'PY'
import json,sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); g=int(sys.argv[2]); prev=int(sys.argv[3])
c.execute("update goal set autonomy=? where id=?",
          (json.dumps({"last_through_event_id":prev}),g))
tid=c.execute("select id from task where goal_id=? order by id limit 1",(g,)).fetchone()[0]
for _ in range(40):
    c.execute("insert into event(ts,task_id,kind,payload) values(?,?,'task.blocked',?)",
              (int(time.time()),tid,'{"reason":"dep"}'))
c.commit()
PY
newev=$(sql "SELECT COUNT(*) FROM event e LEFT JOIN task t ON e.task_id=t.id WHERE e.id>$prev AND (e.goal_id=$GD OR t.goal_id=$GD)")
snapshot "$GD"
TD2=$(fleet add --role commander --goal "$GD" --channel shell --spec "$DD")
if msg=$(run_check folded "$FLEET_HOME/runs/$TD2/prompt.md" "$GD" "$RV" "$WM" "$prev" "$newev"); then
  ok "D2: an incremental round reports after_event_id=$prev and $newev new events"
else no "D2: incremental window ($msg)"; fi

# E. 200 artifacts with 60k-char summaries plus refuted claims and mail: none
# of that may push the core out, and dropped artifacts keep a ledger query.
new_home
GE=$(fleet goal add "E")
python3 - "$FLEET_HOME/fleet.db" "$GE" <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); g=int(sys.argv[2]); t=int(time.time())
for i in range(20):
    cur=c.execute("insert into task(title,goal_id,channel,family,status,cwd,created_at,role)"
                  " values(?,?,'shell','none','done','/tmp',?, 'worker')",("T"*400+str(i),g,t))
    tid=cur.lastrowid
    for j in range(10):
        c.execute("insert into artifact(task_id,path,summary,ts) values(?,?,?,?)",
                  (tid,f"/tmp/huge-{i}-{j}-"+"p"*300,"Z"*60000,t))
    c.execute("insert into claim(task_id,claim,evidence,status,ts) values(?,?,?, 'refuted',?)",
              (tid,"C"*40000,"E"*40000,t))
    c.execute("insert into message(from_agent,to_agent,topic,body,ts)"
              " values(?, 'commander','note',?,?)",(f"task-{tid}","M"*40000,t))
c.commit()
PY
DE=$(small_driver)
snapshot "$GE"
TE=$(fleet add --role commander --goal "$GE" --channel shell --spec "$DE")
if msg=$(run_check artifacts "$FLEET_HOME/runs/$TE/prompt.md" "$GE" "$RV" "$WM" 60000); then
  ok "E: 200 oversized artifacts, refuted claims and mail leave the core intact"
else no "E: artifact flood ($msg)"; fi

# F. Shell driver wrapping: a large-but-affordable driver keeps its script and
# the JSON body whole; a driver that would eat the body's floor is refused,
# with no task row and no half-written script left behind.
new_home
GF=$(fleet goal add "F")
python3 - "$FLEET_HOME/fleet.db" "$GF" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute("update goal set acceptance=? where id=?",("大"*30000,int(sys.argv[2]))); c.commit()
PY
BIG="$FLEET_HOME/big-driver.sh"
{ printf '#!/usr/bin/env bash\n'; printf '# FLEET_PAD_%06d filler comment line to grow this driver\n' $(seq 1 300); printf 'printf FLEET_DRIVER_MARK\n'; } >"$BIG"
chmod +x "$BIG"
snapshot "$GF"
TF=$(fleet add --role commander --goal "$GF" --channel shell --spec "$BIG")
PF="$FLEET_HOME/runs/$TF/prompt.md"
f1=fail
run_check wrapped "$PF" "$GF" "$RV" "$WM" FLEET_DRIVER_MARK >/dev/null 2>&1 && f1=ok
# The wrapped prompt must still be an executable script whose driver runs.
fout=$(bash "$PF" 2>&1)
HUGE="$FLEET_HOME/huge-driver.sh"
python3 - "$HUGE" <<'PY'
import sys
# ~60 KB of driver: more than the whole prompt budget, so it cannot be wrapped
# at any detail level. The point is that this is refused rather than cut.
with open(sys.argv[1],"w") as fh:
    fh.write("#!/usr/bin/env bash\n")
    for i in range(1000):
        fh.write(f"# FLEET_PAD_{i:06d} " + "x"*50 + "\n")
    fh.write("printf FLEET_DRIVER_MARK\n")
PY
before=$(sql "SELECT COUNT(*) FROM task")
err=$(fleet add --role commander --goal "$GF" --channel shell --spec "$HUGE" 2>&1); rcf=$?
after=$(sql "SELECT COUNT(*) FROM task")
if [ "$f1" = ok ] && [ "$fout" = FLEET_DRIVER_MARK ] && [ "$rcf" != 0 ] \
   && [ "$before" = "$after" ] && printf '%s' "$err" | grep -q 'shrink the driver'; then
  ok "F: a large driver wraps a whole prompt; an oversized one is refused (rc=$rcf)"
else no "F: driver wrapping (wrapped=$f1 run='$fout' rc=$rcf tasks=$before/$after err='$err')"; fi

# G. Everything at once: giant goal AND 400 decisions AND 3000 events AND 200
# oversized artifacts in one goal. The contract is about the worst case, and
# each earlier case alone leaves the others room.
new_home
GG=$(fleet goal add "G")
python3 - "$FLEET_HOME/fleet.db" "$GG" <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); g=int(sys.argv[2]); t=int(time.time())
big=lambda tag: tag+"。测试"*20000
c.execute("update goal set statement=?,acceptance=?,approval_gates=? where id=?",
          (big("STMT"),big("ACC"),big("GATE"),g))
c.execute("insert into plan(goal_id,revision,rationale,dag,rules,created_at) values(?,?,?,?,?,?)",
          (g,3,big("RAT"),big("DAG"),big("RULES"),t))
for i in range(400):
    c.execute("insert into decision(goal_id,question,evidence,needs_user,ts)"
              " values(?,?,?,1,?)",(g,f"Q{i} "+"决策"*400,"E"*2000,t))
for i in range(300):
    cur=c.execute("insert into task(title,goal_id,channel,family,status,cwd,created_at,role)"
                  " values(?,?,'shell','none','done','/tmp',?, 'worker')",("T"*400+str(i),g,t))
    tid=cur.lastrowid
    for _ in range(10):
        c.execute("insert into event(ts,task_id,kind,payload) values(?,?,'task.blocked',?)",
                  (t,tid,'{"reason":"dep"}'))
    if i < 20:
        for j in range(10):
            c.execute("insert into artifact(task_id,path,summary,ts) values(?,?,?,?)",
                      (tid,f"/tmp/h-{i}-{j}","Z"*60000,t))
        c.execute("insert into message(from_agent,to_agent,topic,body,ts)"
                  " values(?, 'commander','note',?,?)",(f"task-{tid}","M"*40000,t))
c.commit()
PY
NG=$(sql "SELECT COUNT(*) FROM decision WHERE goal_id=$GG AND needs_user=1 AND resolved_at IS NULL")
EG=$(sql "SELECT COUNT(*) FROM event e LEFT JOIN task t ON e.task_id=t.id WHERE e.goal_id=$GG OR t.goal_id=$GG")
DG=$(small_driver)
snapshot "$GG"
TG=$(fleet add --role commander --goal "$GG" --channel shell --spec "$DG")
PG="$FLEET_HOME/runs/$TG/prompt.md"
g1=fail; g2=fail; g3=fail
run_check giant "$PG" "$GG" "$RV" "$WM" ACC >/dev/null 2>&1 && g1=ok
run_check needsuser "$PG" "$GG" "$RV" "$WM" "$NG" >/dev/null 2>&1 && g2=ok
run_check folded "$PG" "$GG" "$RV" "$WM" 0 "$EG" >/dev/null 2>&1 && g3=ok
if [ "$g1$g2$g3" = okokok ] && [ "$(wc -c <"$PG")" -le 49152 ]; then
  ok "G: giant goal + $NG decisions + $EG events + artifacts all hold at once"
else no "G: worst case (giant=$g1 needs_user=$g2 folded=$g3 bytes=$(wc -c <"$PG"))"; fi

# H. The prompt.md on disk is what the model reads, so assert the file itself:
# byte-exact size bound, strict UTF-8, and no stray marker outside the JSON.
if python3 - "$PG" >/dev/null <<'PY'
import json,sys
raw=open(sys.argv[1],'rb').read()
assert len(raw)<=49152, f"{len(raw)} bytes"
text=raw.decode('utf-8')            # strict: a split character fails here
body=text.split(": <<'FLEET_COMMANDER_PROMPT'\n",1)[1].rsplit("FLEET_COMMANDER_PROMPT\n",1)[0]
json.loads(body)
# The old failure appended a marker after the clipped JSON. Nothing may follow
# the object inside the heredoc.
assert body.rstrip().endswith('}'), repr(body[-80:])
print('ok')
PY
then ok "H: prompt.md on disk is <=49152 bytes, strict UTF-8, JSON to its last byte"
else no "H: on-disk prompt shape"; fi

# I. The tightest rung, reached on purpose: 200k-char fields, 5000 decisions,
# 2500 80k-char artifacts and 10k events in one goal. This is the case that
# turns "the core always fits" from a claim into a measurement -- if the
# smallest rung could not hold the protocol, construction would raise here
# instead of emitting a prompt.
new_home
GI=$(fleet goal add "I")
python3 - "$FLEET_HOME/fleet.db" "$GI" <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); g=int(sys.argv[2]); t=int(time.time())
c.execute("update goal set statement=?,acceptance=?,approval_gates=? where id=?",
          ("哦"*200000,"啊"*200000,"呀"*200000,g))
c.execute("insert into plan(goal_id,revision,rationale,dag,rules,created_at) values(?,?,?,?,?,?)",
          (g,9,"哦"*200000,"啊"*200000,"呀"*200000,t))
for _ in range(5000):
    c.execute("insert into decision(goal_id,question,evidence,needs_user,ts)"
              " values(?,?,?,1,?)",(g,"问"*3000,"证"*3000,t))
for _ in range(500):
    cur=c.execute("insert into task(title,goal_id,channel,family,status,cwd,created_at,role)"
                  " values(?,?,'shell','none','done','/tmp',?, 'worker')",("题"*2000,g,t))
    tid=cur.lastrowid
    for _ in range(5):
        c.execute("insert into artifact(task_id,path,summary,ts) values(?,?,?,?)",
                  (tid,"路"*500,"要"*80000,t))
    for _ in range(20):
        c.execute("insert into event(ts,task_id,kind,payload) values(?,?,'task.blocked','{}')",(t,tid))
c.commit()
PY
NI=$(sql "SELECT COUNT(*) FROM decision WHERE goal_id=$GI AND needs_user=1 AND resolved_at IS NULL")
EI=$(sql "SELECT COUNT(*) FROM event e LEFT JOIN task t ON e.task_id=t.id WHERE e.goal_id=$GI OR t.goal_id=$GI")
DI=$(small_driver)
snapshot "$GI"
TI=$(fleet add --role commander --goal "$GI" --channel shell --spec "$DI"); rci=$?
PI="$FLEET_HOME/runs/$TI/prompt.md"
i1=fail; i2=fail
[ "$rci" = 0 ] && run_check needsuser "$PI" "$GI" "$RV" "$WM" "$NI" >/dev/null 2>&1 && i1=ok
[ "$rci" = 0 ] && run_check folded "$PI" "$GI" "$RV" "$WM" 0 "$EI" >/dev/null 2>&1 && i2=ok
if [ "$i1$i2" = okok ]; then
  ok "I: worst ledger yet ($NI decisions, $EI events, 200k-char fields) still fits"
else no "I: tightest rung (rc=$rci needs_user=$i1 folded=$i2 bytes=$(wc -c <"$PI" 2>/dev/null))"; fi

# J. Dict cardinality (2610). goal.autonomy is hand-editable JSON, and
# bounding only its values left the key COUNT and key LENGTH unbounded: a
# value that is a 1000-key dict of 200-char keys rendered ~570 KB at every
# rung including the tightest, so construction raised
# "commander prompt core does not fit" and the goal got no prompt at all.
new_home
GJ=$(fleet goal add "J" --acceptance "tests pass")
python3 - "$FLEET_HOME/fleet.db" "$GJ" <<'PY'
import json,sqlite3,sys
c=sqlite3.connect(sys.argv[1]); g=int(sys.argv[2])
# Under a protocol key, so it survives the non-protocol-key filter and really
# reaches _bounded_json: 1000 keys, each key itself 200 chars, each value 200.
c.execute("update goal set autonomy=? where id=?",(json.dumps({
    "channel": {("k"*200)+str(i): "v"*200 for i in range(1000)},
    "model": {"nested": {("n"*300)+str(i): i for i in range(1000)}},
}),g)); c.commit()
PY
DJ=$(small_driver)
snapshot "$GJ"
TJ=$(fleet add --role commander --goal "$GJ" --channel shell --spec "$DJ" 2>&1); rcj=$?
PJ="$FLEET_HOME/runs/$TJ/prompt.md"
if [ "$rcj" = 0 ] && msg=$(run_check dict "$PJ" "$GJ" "$RV" "$WM" 1000) \
   && [ "$(wc -c <"$PJ")" -le 49152 ]; then
  ok "J: a 1000-key autonomy dict is bounded; the prompt still fits ($(wc -c <"$PJ") bytes)"
else no "J: dict cardinality (rc=$rcj $msg ${TJ})"; fi

# K. The constraints text (2615). The daemon rejects proposals on rules the
# prompt never stated -- the 8000-char field cap and "decisions are nonempty"
# -- so the text is generated from the constants _validate_commander_proposal
# uses. The checker imports bin/fleet and compares against those constants,
# and runs the validator at and past the stated cap.
new_home
GK=$(fleet goal add "K" --acceptance "tests pass")
DK=$(small_driver)
snapshot "$GK"
TK=$(fleet add --role commander --goal "$GK" --channel shell --spec "$DK")
if msg=$(run_check constraints "$FLEET_HOME/runs/$TK/prompt.md" "$GK" "$RV" "$WM"); then
  ok "K: response_constraints states every rule the validator enforces, same numbers"
else no "K: constraints text ($msg)"; fi

# L. since.query is a command, not prose. Appending a parenthetical goal label
# makes the displayed text non-runnable because the label is not an argument.
# This case takes the string out of the prompt and actually runs it.
new_home
GL=$(fleet goal add "L" --acceptance "tests pass")
python3 - "$FLEET_HOME/fleet.db" "$GL" <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); g=int(sys.argv[2]); t=int(time.time())
for i in range(60):
    cur=c.execute("insert into task(title,goal_id,channel,family,status,cwd,created_at,role)"
                  " values(?,?,'shell','none','done','/tmp',?,'worker')",(f"t{i}",g,t))
    for _ in range(5):
        c.execute("insert into event(ts,task_id,kind,payload) values(?,?,'task.blocked','{}')",
                  (t,cur.lastrowid))
c.commit()
PY
snapshot "$GL"
# Unwrapped on purpose: this case pulls the query string back out of
# the file with a plain JSON parse, which is how a model channel reads it.
# The query itself does not depend on the channel.
TL=$(fleet add --role commander --goal "$GL" --channel claude-p)
PL="$FLEET_HOME/runs/$TL/prompt.md"
l1=fail
run_check sincecmd "$PL" "$GL" "$RV" "$WM" 0 >/dev/null 2>&1 && l1=ok
# Run the exact string the prompt carries. `fleet` is on PATH for this suite,
# so the command a reader would paste is the command that runs here.
QL=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["since"]["query"])' "$PL" 2>/dev/null)
qout=$([ -n "$QL" ] && $QL 2>&1); rcq=$?
# rc=0 is the contract; the output must also be the fold, not an argparse
# usage message -- and an empty QL must not pass as a rc=0 no-op.
if [ "$l1" = ok ] && [ -n "$QL" ] && [ "$rcq" = 0 ] \
   && printf '%s' "$qout" | grep -q '^watermark='; then
  ok "L: since.query ('$QL') runs with rc=0 and returns the fold"
else no "L: runnable since.query (check=$l1 rc=$rcq cmd='$QL' out='$(printf '%s' "$qout" | head -2)')"; fi

# M. The artifact total counts the goal, not the survivors (2617). With 500
# tasks the ladder keeps ~40 of them, and summing artifacts over the kept
# tasks reported ~200 of 2500 as the whole set: the single number telling the
# commander how much evidence it cannot see shrank along with the evidence.
new_home
GM=$(fleet goal add "M" --acceptance "tests pass")
python3 - "$FLEET_HOME/fleet.db" "$GM" <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); g=int(sys.argv[2]); t=int(time.time())
for i in range(500):
    cur=c.execute("insert into task(title,goal_id,channel,family,status,cwd,created_at,role)"
                  " values(?,?,'shell','none','done','/tmp',?,'worker')",(f"t{i}",g,t))
    for j in range(5):
        c.execute("insert into artifact(task_id,path,summary,ts) values(?,?,?,?)",
                  (cur.lastrowid,f"/tmp/a-{i}-{j}","s"*200,t))
c.commit()
PY
AM=$(sql "SELECT COUNT(*) FROM artifact WHERE task_id IN (SELECT id FROM task WHERE goal_id=$GM)")
DM=$(small_driver)
snapshot "$GM"
TM=$(fleet add --role commander --goal "$GM" --channel shell --spec "$DM")
if [ "$AM" = 2500 ] && msg=$(run_check artifacttotal "$FLEET_HOME/runs/$TM/prompt.md" "$GM" "$RV" "$WM" "$AM"); then
  ok "M: 500 tasks / $AM artifacts report total=$AM even though most tasks were dropped"
else no "M: artifact total (ledger=$AM $msg)"; fi

# N. Integrated 385+389 contract on the p19 fixture shape: a real Git target,
# a completed Fleet worktree candidate, an unresolved human gate, and p19 K's
# 60k summary / 200-event load all coexist in one parseable <=48 KiB prompt.
new_home
PN_REPO="$FLEET_HOME/target"
mkdir -p "$PN_REPO"
git -C "$PN_REPO" init -q
git -C "$PN_REPO" config user.email p19@example.test
git -C "$PN_REPO" config user.name p19
printf 'p19 fixture\n' >"$PN_REPO/input.txt"
git -C "$PN_REPO" add input.txt
git -C "$PN_REPO" commit -qm fixture
GN=$(fleet goal add "N integrated execution prompt" --acceptance "tests pass")
DN=$(small_driver)
WN=$(fleet add "delivered baseline" --channel shell --goal "$GN" \
  --cwd "$PN_REPO" --spec "$DN" --worktree)
fleet run "$WN" >/dev/null
for _ in $(seq 1 100); do
  case "$(sql "SELECT status FROM task WHERE id=$WN")" in
    done|failed|cancelled) break;;
  esac
  sleep .05
done
fleet decide "operator approval required" --goal "$GN" --needs-user >/dev/null
python3 - "$FLEET_HOME/fleet.db" "$WN" <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); tid=int(sys.argv[2]); now=int(time.time())
c.execute("insert into artifact(task_id,path,summary,ts) values(?,?,?,?)",
          (tid,'/tmp/p19-huge','Z'*60000,now))
for _ in range(200):
    c.execute("insert into event(ts,task_id,kind,payload) values(?,?,?,?)",
              (now,tid,'task.blocked','{\"reason\":\"dep\"}'))
c.commit()
PY
snapshot "$GN"
PN="$FLEET_HOME/integrated-prompt.md"
python3 - "$ROOT/bin/fleet" "$GN" "$PN_REPO" "$DN" "$PN" <<'PY'
import importlib.machinery,importlib.util,pathlib,sys
fleet_path,goal_id,cwd,driver_path,prompt_path=sys.argv[1:]
loader=importlib.machinery.SourceFileLoader('fleet_prompt_integration',fleet_path)
spec=importlib.util.spec_from_loader(loader.name,loader)
fleet=importlib.util.module_from_spec(spec); loader.exec_module(fleet)
conn=fleet.db_connect()
goal=conn.execute("SELECT * FROM goal WHERE id=?",(int(goal_id),)).fetchone()
actual_cwd,body,_revision,_through=fleet.commander_construction(
    conn,goal,shell_driver=pathlib.Path(driver_path).read_text(),cwd=cwd)
assert actual_cwd==str(pathlib.Path(cwd).resolve()),(actual_cwd,cwd)
pathlib.Path(prompt_path).write_text(body)
conn.close()
PY
if msg=$(run_check integrated "$PN" "$GN" "$RV" "$WM" "$WN" "$PN_REPO"); then
  ok "N: p19-sized prompt retains execution target, base candidates, gate, schema and constraints"
else no "N: integrated execution prompt ($msg; bytes=$(wc -c <"$PN"))"; fi

echo "1..$N"
echo "---"
# tests/run-all.sh discovers every tests/*smoke*.sh and reads this exact line.
echo "passed $PASS / $N"
[ "$FAIL" = 0 ]
