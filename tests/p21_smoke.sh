#!/usr/bin/env bash
# C0/P21: attempt identity, stale-callback fencing, isolated run files,
# legacy migration, and expiring/generation-fenced commander leases.
# Shell tasks and direct SQLite fixtures only; no model executable is called.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
unset _FLEET_LOCK_FD
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS
unset FLEET_TASK_ID FLEET_ATTEMPT FLEET_RUN_DIR FLEET_SB_MCP_CMD

PASS=0 FAIL=0 N=0
SCRATCH=()
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }
cleanup(){
  fleet daemon stop >/dev/null 2>&1 || true
  local p
  for p in "${SCRATCH[@]}"; do rm -rf "$p"; done
}
trap cleanup EXIT

new_home(){
  fleet daemon stop >/dev/null 2>&1 || true
  FLEET_HOME="$(mktemp -d /var/tmp/fleet-p21-test-XXXXXX)"
  SCRATCH+=("$FLEET_HOME")
  export FLEET_HOME
  fleet init >/dev/null
  DB="$FLEET_HOME/fleet.db"
}
sql(){ sqlite3 -cmd '.timeout 10000' "$DB" "$1"; }
field(){ fleet show "$1" | awk -v f="$2" '$1==f ":"{print $2}'; }
wait_status(){
  local tid="$1" wanted="$2" i
  for i in $(seq 1 200); do
    [ "$(field "$tid" status)" = "$wanted" ] && return 0
    sleep .05
  done
  return 1
}
rpc_call(){
  local tid="$1" attempt="$2" tool="$3" params="$4"
  python3 -c 'import json,sys
print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
 "params":{"name":sys.argv[1],"arguments":json.loads(sys.argv[2])}}))' \
    "$tool" "$params" | FLEET_TASK_ID="$tid" FLEET_ATTEMPT="$attempt" \
    "$ROOT/bin/fleet-mcp" 2>/dev/null
}

# A/B/C/F. A real two-attempt shell task supplies the identities and files.
new_home
cat >"$FLEET_HOME/retry.sh" <<'SH'
if [ ! -e "$FLEET_HOME/first-finished" ]; then
  touch "$FLEET_HOME/first-finished"
  echo first-output
  echo first-log >&2
  sleep 1
  exit 7
fi
echo second-output
echo second-log >&2
sleep 5
SH
T=$(fleet add "A-F retry" --channel shell --spec "$FLEET_HOME/retry.sh" --max-attempts 2)
fleet run "$T" >/dev/null
wait_status "$T" running || true
OLD=$(field "$T" attempt_id)
OLD_DIR=$(field "$T" run_dir)
OLD_CLAIM=$(rpc_call "$T" "$OLD" fleet_claim \
  '{"claim":"attempt-one-claim","evidence":"attempt one"}')
wait_status "$T" queued || true
fleet run "$T" >/dev/null
wait_status "$T" running || true
NEW=$(field "$T" attempt_id)
NEW_DIR=$(field "$T" run_dir)
fleet _finish "$T" 0 --attempt "$OLD" >"$FLEET_HOME/stale.err" 2>&1
STALE_RC=$?
STALE_STATE=$(sql "SELECT status||':'||attempt_id FROM task WHERE id=$T")
STALE_EVENTS=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T AND kind='attempt.stale' AND json_extract(payload,'$.supplied')='$OLD'")
if [ "$STALE_RC" = 16 ] && [ "$STALE_STATE" = "running:$NEW" ] \
   && [ "$STALE_EVENTS" = 1 ]; then
  ok "A: an old wrapper callback is rejected and logged without settling the new attempt"
else
  no "A: stale rc=$STALE_RC state=$STALE_STATE events=$STALE_EVENTS"
fi

LATE=$(rpc_call "$T" "$OLD" fleet_claim \
  '{"claim":"late-old-claim","evidence":"late"}')
LATE_ARTIFACT=$(rpc_call "$T" "$OLD" fleet_artifact \
  "{\"path\":\"$FLEET_HOME/retry.sh\",\"summary\":\"late\"}")
LATE_SEND=$(rpc_call "$T" "$OLD" fleet_send \
  '{"to":"commander","topic":"late-send","body":"late"}')
LATE_SPAWN=$(rpc_call "$T" "$OLD" fleet_spawn \
  '{"title":"late spawn","rationale":"late"}')
LATE_NOTE=$(rpc_call "$T" "$OLD" fleet_note \
  '{"finding":"late note","evidence":"late"}')
CURRENT=$(rpc_call "$T" "$NEW" fleet_claim \
  '{"claim":"attempt-two-claim","evidence":"current"}')
CURRENT_ARTIFACT=$(rpc_call "$T" "$NEW" fleet_artifact \
  "{\"path\":\"$FLEET_HOME/retry.sh\",\"summary\":\"current\"}")
CURRENT_SEND=$(rpc_call "$T" "$NEW" fleet_send \
  '{"to":"commander","topic":"current-send","body":"current"}')
CURRENT_SPAWN=$(rpc_call "$T" "$NEW" fleet_spawn \
  '{"title":"current spawn","rationale":"current"}')
CURRENT_NOTE=$(rpc_call "$T" "$NEW" fleet_note \
  '{"finding":"current note","evidence":"current"}')
wait_status "$T" done || true
DEFAULT_CLAIMS=$(fleet --json claim list --task "$T")
ALL_CLAIMS=$(fleet --json claim list --task "$T" --all)
B_RESULT=$(python3 - "$LATE" "$LATE_ARTIFACT" "$LATE_SEND" "$LATE_SPAWN" "$LATE_NOTE" \
  "$CURRENT" "$CURRENT_ARTIFACT" "$CURRENT_SEND" "$CURRENT_SPAWN" "$CURRENT_NOTE" \
  "$DEFAULT_CLAIMS" "$ALL_CLAIMS" "$OLD" "$NEW" "$DB" "$T" <<'PY'
import json,sqlite3,sys
stale=list(map(json.loads,sys.argv[1:6]))
current=list(map(json.loads,sys.argv[6:11]))
default,all_rows=map(json.loads,sys.argv[11:13])
old,new,db,tid=sys.argv[13:]
assert all(x['result'].get('isError') is True for x in stale), stale
assert all(not x['result'].get('isError') for x in current), current
d=[(x['claim'],x['attempt_id']) for x in default]
a=[(x['claim'],x['attempt_id']) for x in all_rows]
assert d==[('attempt-two-claim',new)], d
assert a==[('attempt-one-claim',old),('attempt-two-claim',new)], a
c=sqlite3.connect(db)
artifacts=c.execute('SELECT attempt_id FROM artifact WHERE task_id=?',(tid,)).fetchall()
messages=c.execute("SELECT attempt_id FROM message WHERE from_agent=? ORDER BY id",
                   ('task-'+tid,)).fetchall()
assert artifacts==[(new,)], artifacts
assert messages==[(new,),(new,),(new,)], messages
print('ok')
PY
)
if [ "$B_RESULT" = ok ]; then
  ok "B: stale MCP writes are rejected; current writes carry provenance and claim list is scoped"
else
  no "B: stale/current MCP write or claim-list isolation failed"
fi

SHOW=$(fleet show "$T")
DIGEST=$(fleet digest "$T")
TAIL=$(fleet tail "$T" -n 20)
C_ROWS=$(sql "SELECT COUNT(*)||':'||COUNT(DISTINCT run_dir) FROM attempt WHERE task_id=$T")
if [ "$OLD_DIR" != "$NEW_DIR" ] \
   && [ -f "$OLD_DIR/out.md" ] && [ -f "$NEW_DIR/out.md" ] \
   && grep -q first-output "$OLD_DIR/out.md" \
   && [[ "$SHOW" == *"run_dir: $NEW_DIR"* ]] \
   && [[ "$DIGEST" == *second-output* ]] && [[ "$DIGEST" != *first-output* ]] \
   && [[ "$TAIL" == *second-log* ]] && [ "$C_ROWS" = 2:2 ]; then
  ok "C: each attempt has its own directory and show/digest/tail select the latest"
else
  no "C: dirs='$OLD_DIR'/'$NEW_DIR' rows=$C_ROWS"
fi

fleet _finish "$T" 0 >"$FLEET_HOME/unsigned.err" 2>&1
UNSIGNED_RC=$?
UNSIGNED_EVENTS=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T AND kind='attempt.stale' AND json_extract(payload,'$.supplied') IS NULL")
if [ "$UNSIGNED_RC" = 16 ] && [ "$(field "$T" status)" = done ] \
   && [ "$UNSIGNED_EVENTS" = 1 ]; then
  ok "F: an unsigned legacy callback is rejected and recorded"
else
  no "F: unsigned rc=$UNSIGNED_RC events=$UNSIGNED_EVENTS status=$(field "$T" status)"
fi

# D. Restarting the scheduler does not mint a new identity for a live wrapper.
new_home
printf 'sleep 8\necho survived-restart\n' >"$FLEET_HOME/slow.sh"
TD=$(fleet add "D restart" --channel shell --spec "$FLEET_HOME/slow.sh")
fleet daemon start --interval 1 >/dev/null
wait_status "$TD" running || true
D_BEFORE=$(field "$TD" attempt_id)
fleet daemon stop >/dev/null
fleet daemon start --interval 1 >/dev/null
sleep .3
D_AFTER=$(field "$TD" attempt_id)
D_STATE=$(field "$TD" status)
D_ROWS=$(sql "SELECT COUNT(*) FROM attempt WHERE task_id=$TD")
fleet daemon stop >/dev/null
fleet cancel "$TD" >/dev/null 2>&1 || true
if [ -n "$D_BEFORE" ] && [ "$D_BEFORE" = "$D_AFTER" ] \
   && [ "$D_STATE" = running ] && [ "$D_ROWS" = 1 ]; then
  ok "D: daemon restart preserves the identity of an in-flight attempt"
else
  no "D: before=$D_BEFORE after=$D_AFTER state=$D_STATE rows=$D_ROWS"
fi

# E. Simulate a retry winning between Popen and the launcher's PID writeback.
new_home
printf 'echo pid-race\n' >"$FLEET_HOME/pid.sh"
TE=$(fleet add "E pid fence" --channel shell --spec "$FLEET_HOME/pid.sh")
E_RESULT=$(python3 - "$ROOT/bin/fleet" "$DB" "$TE" <<'PY'
import importlib.machinery,importlib.util,os,sqlite3,sys
from unittest.mock import patch
path,db,tid=sys.argv[1],sys.argv[2],int(sys.argv[3])
spec=importlib.util.spec_from_loader('fleet_p21_pid',importlib.machinery.SourceFileLoader('fleet_p21_pid',path))
fleet=importlib.util.module_from_spec(spec); spec.loader.exec_module(fleet)
conn=fleet.db_connect(); task=conn.execute('SELECT * FROM task WHERE id=?',(tid,)).fetchone()
chans=fleet.load_channels()
class Proc: pid=123456
def fake_popen(*args,**kwargs):
    conn.execute("UPDATE task SET attempt_id='replacement',pid=456 WHERE id=?",(tid,))
    conn.commit()
    return Proc()
with patch.object(fleet.subprocess,'Popen',fake_popen):
    started,_=fleet.launch(conn,task,chans['channels']['shell'],chans)
row=conn.execute('SELECT attempt_id,pid FROM task WHERE id=?',(tid,)).fetchone()
old=conn.execute('SELECT pid FROM attempt WHERE task_id=?',(tid,)).fetchone()
root=fleet.task_root(task)
assert started and tuple(row)==('replacement',456), tuple(row)
assert old['pid']==123456, old['pid']
assert not (root/'wrapper.pid').exists()
print('ok')
PY
)
if [ "$E_RESULT" = ok ]; then
  ok "E: a late PID write is fenced from a replacement attempt"
else
  no "E: late PID write result=$E_RESULT"
fi

# G. Re-init preserves terminal legacy history, but a pre-C0 running task gets
# a fresh unguessable identity plus an attempt-history row.  Literal legacy
# never authenticates; the pre-C0 wrapper's ONE unsigned callback is admitted
# (unsigned_ok, spent on use) so an upgrade under load settles in-flight tasks
# instead of orphaning them; a second unsigned callback is fenced.
new_home
TG=$(fleet add "G legacy" --channel shell)
CG=$(fleet claim add "$TG" "old claim" --evidence "old evidence")
TR=$(fleet add "G running legacy" --channel shell)
python3 - "$DB" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute('DROP TABLE attempt')
c.execute('ALTER TABLE task DROP COLUMN attempt_id')
c.execute('ALTER TABLE task DROP COLUMN commander_lease_generation')
c.execute('ALTER TABLE claim DROP COLUMN attempt_id')
c.execute('ALTER TABLE artifact DROP COLUMN attempt_id')
c.execute('ALTER TABLE message DROP COLUMN attempt_id')
c.execute('ALTER TABLE lease DROP COLUMN generation')
c.execute("UPDATE task SET status='running',attempt=1,started_at=1 WHERE title='G running legacy'")
c.commit()
PY
fleet init >/dev/null
G_SHOW=$(fleet show "$TG")
G_ROW=$(sql "SELECT task.attempt_id||':'||claim.attempt_id FROM task JOIN claim ON claim.task_id=task.id WHERE task.id=$TG AND claim.id=$CG")
G_DEFAULT=$(fleet --json claim list --task "$TG" | python3 -c '
import json,sys
rows=json.load(sys.stdin)
print("ok" if [(r["claim"],r["attempt_id"]) for r in rows]==[("old claim","legacy")] else "no")')
G_RUNNING=$(field "$TR" attempt_id)
G_ATTEMPTS=$(sql "SELECT COUNT(*) FROM attempt WHERE task_id=$TR AND attempt_id='$G_RUNNING' AND status='running'")
fleet _finish "$TR" 0 --attempt legacy >"$FLEET_HOME/legacy-finish.err" 2>&1
G_LEGACY_RC=$?
G_OK_BEFORE=$(sql "SELECT unsigned_ok FROM attempt WHERE attempt_id='$G_RUNNING'")
# A bystander (this shell: not the migrated wrapper pid) cannot spend the permit.
fleet _finish "$TR" 0 >"$FLEET_HOME/unsigned-foreign.err" 2>&1
G_FOREIGN_RC=$?
G_OK_FOREIGN=$(sql "SELECT unsigned_ok FROM attempt WHERE attempt_id='$G_RUNNING'")
# The migrated wrapper execs `fleet _finish`, so the caller pid is the pid
# migration copied into attempt.pid: emulate with a bash that binds and execs.
DB="$DB" TR="$TR" G_RUNNING="$G_RUNNING" setsid bash -c '
  birth=$(python3 -c "raw=open(\"/proc/$$/stat\").read(); print(raw[raw.rfind(\")\")+2:].split()[19])")
  sqlite3 -cmd ".timeout 10000" "$DB" "UPDATE task SET pid=$$,pid_starttime=$birth WHERE id=$TR AND attempt_id='"'"'$G_RUNNING'"'"'; UPDATE attempt SET pid=$$,pid_starttime=$birth WHERE attempt_id='"'"'$G_RUNNING'"'"'"
  exec fleet _finish "$TR" 0' >"$FLEET_HOME/unsigned-finish.err" 2>&1
G_UNSIGNED_RC=$?
G_STATUS=$(field "$TR" status)
G_OK_AFTER=$(sql "SELECT unsigned_ok FROM attempt WHERE attempt_id='$G_RUNNING'")
G_ADMITTED=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$TR AND kind='attempt.unsigned_migrated_finish'")
fleet _finish "$TR" 0 >"$FLEET_HOME/unsigned-finish-2.err" 2>&1
G_UNSIGNED2_RC=$?
G_STALE=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$TR AND kind='attempt.stale'")
if [[ "$G_SHOW" == *"title: G legacy"* ]] && [ "$G_ROW" = legacy:legacy ] \
   && [ "$G_DEFAULT" = ok ] \
   && [ "$G_RUNNING" != legacy ] && [ "$G_ATTEMPTS" = 1 ] \
   && [ "$G_LEGACY_RC" = 16 ] && [ "$G_OK_BEFORE" = 1 ] \
   && [ "$G_FOREIGN_RC" = 16 ] && [ "$G_OK_FOREIGN" = 1 ] \
   && [ "$G_UNSIGNED_RC" = 0 ] && [ "$G_STATUS" = done ] \
   && [ "$G_OK_AFTER" = 0 ] && [ "$G_ADMITTED" = 1 ] \
   && [ "$G_UNSIGNED2_RC" = 16 ] && [ "$G_STALE" = 3 ]; then
  ok "G: migration preserves history, mints a running UUID, rejects legacy and foreign-pid unsigned, admits the wrapper's one unsigned finish"
else
  no "G: legacy row=$G_ROW default=$G_DEFAULT running=$G_RUNNING attempts=$G_ATTEMPTS rc=$G_LEGACY_RC/$G_FOREIGN_RC/$G_UNSIGNED_RC/$G_UNSIGNED2_RC status=$G_STATUS ok=$G_OK_BEFORE/$G_OK_FOREIGN/$G_OK_AFTER admitted=$G_ADMITTED stale=$G_STALE"
fi

# G2. A signed (post-C0) running attempt never admits an unsigned callback:
# unsigned_ok is 0 for everything launch() mints, only migration sets it. The
# caller pid is bound to attempt.pid so the pid check is not what rejects here.
TJ=$(fleet add "G2 signed running" --channel shell)
J_ID=$(python3 -c 'import uuid;print(uuid.uuid4().hex)')
sql "UPDATE task SET status='running',attempt=1,attempt_id='$J_ID',started_at=strftime('%s','now') WHERE id=$TJ"
sql "INSERT INTO attempt(attempt_id,task_id,generation,status,run_dir,out_path,log_path,started_at) VALUES('$J_ID',$TJ,1,'running','/nonexistent','/nonexistent/out.md','/nonexistent/log.txt',1)"
DB="$DB" TJ="$TJ" J_ID="$J_ID" setsid bash -c '
  birth=$(python3 -c "raw=open(\"/proc/$$/stat\").read(); print(raw[raw.rfind(\")\")+2:].split()[19])")
  sqlite3 -cmd ".timeout 10000" "$DB" "UPDATE task SET pid=$$,pid_starttime=$birth WHERE id=$TJ AND attempt_id='"'"'$J_ID'"'"'; UPDATE attempt SET pid=$$,pid_starttime=$birth WHERE attempt_id='"'"'$J_ID'"'"'"
  exec fleet _finish "$TJ" 0' >"$FLEET_HOME/unsigned-signed.err" 2>&1
J_RC=$?
J_STATUS=$(field "$TJ" status)
J_ADMITTED=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$TJ AND kind='attempt.unsigned_migrated_finish'")
if [ "$J_RC" = 16 ] && [ "$J_STATUS" = running ] && [ "$J_ADMITTED" = 0 ]; then
  ok "G2: a signed running attempt rejects an unsigned finish"
else
  no "G2: rc=$J_RC status=$J_STATUS admitted=$J_ADMITTED"
fi

# H. An expired commander lease is replaced with a higher generation.  The
# old owner's late callback cannot apply or delete the new lease; a newer plan
# revision is also present when that callback arrives.
new_home
cat >"$FLEET_HOME/commander.sh" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
GH=$(fleet goal add "H lease")
export FLEET_COMMANDER_SHELL_SCRIPT="$FLEET_HOME/commander.sh"
fleet autonomy enable "$GH" --channel shell --cwd "$FLEET_HOME" \
  --max-rounds 3 --cooldown 0 >/dev/null
FLEET_COMMANDER_LEASE_S=1 fleet daemon run --once >/dev/null
TH1=$(sql "SELECT id FROM task WHERE goal_id=$GH AND role='commander' ORDER BY id LIMIT 1")
wait_status "$TH1" running || true
OLD_ATTEMPT=$(field "$TH1" attempt_id)
OLD_PID=$(field "$TH1" pid)
printf '[]\n' >"$FLEET_HOME/rules.json"
fleet plan set "$GH" --rules "$FLEET_HOME/rules.json" --rationale newer >/dev/null
sleep 2
FLEET_COMMANDER_LEASE_S=1 fleet daemon run --once >/dev/null
TH2=$(sql "SELECT id FROM task WHERE goal_id=$GH AND role='commander' ORDER BY id DESC LIMIT 1")
NEW_PID=$(field "$TH2" pid)
kill -TERM -- "-$OLD_PID" 2>/dev/null || true
fleet _finish "$TH1" 0 --attempt "$OLD_ATTEMPT" >/dev/null 2>&1
H_RC=$?
H_STATE=$(sql "SELECT (SELECT generation FROM lease WHERE resource='commander:goal-$GH')||':'||(SELECT commander_lease_generation FROM task WHERE id=$TH1)||':'||(SELECT commander_lease_generation FROM task WHERE id=$TH2)||':'||(SELECT holder FROM lease WHERE resource='commander:goal-$GH')")
H_REJECT=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$TH1 AND kind='commander.rejected' AND json_extract(payload,'$.reason')='stale'")
H_STALE=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$TH1 AND kind='attempt.stale'")
H_WORKERS=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$GH AND role='worker'")
if [ "$TH2" != "$TH1" ] && [ "$H_RC" = 16 ] \
   && [ "$H_STATE" = "2:1:2:$TH2" ] && [ "$H_REJECT" = 1 ] \
   && [ "$H_STALE" = 1 ] \
   && [ "$H_WORKERS" = 0 ] && [ "$(field "$TH1" status)" = done ]; then
  ok "H: expired commander lease advances generation and the old apply is rejected"
else
  no "H: old/new=$TH1/$TH2 rc=$H_RC state=$H_STATE rejected=$H_REJECT stale=$H_STALE workers=$H_WORKERS"
fi
fleet cancel "$TH2" >/dev/null 2>&1 || kill -TERM -- "-$NEW_PID" 2>/dev/null || true

# I. The public literal `legacy` is never a write credential.  Finish, all MCP
# write tools, and both worker-aware CLI write paths refuse it and emit a
# reason=legacy audit event without inserting provenance rows.
new_home
TI=$(fleet add "I reject legacy token" --channel shell)
sql "UPDATE task SET status='running',attempt=1,attempt_id='legacy',started_at=strftime('%s','now') WHERE id=$TI"
printf 'artifact-i\n' >"$FLEET_HOME/artifact-i.txt"
fleet _finish "$TI" 0 --attempt legacy >/dev/null 2>&1; I_FINISH=$?
I_CLAIM=$(rpc_call "$TI" legacy fleet_claim \
  '{"claim":"legacy-mcp","evidence":"must fail"}')
I_ARTIFACT=$(rpc_call "$TI" legacy fleet_artifact \
  "{\"path\":\"$FLEET_HOME/artifact-i.txt\"}")
I_SEND=$(rpc_call "$TI" legacy fleet_send \
  '{"to":"commander","body":"must fail"}')
I_INBOX=$(rpc_call "$TI" legacy fleet_inbox '{}')
I_SPAWN=$(rpc_call "$TI" legacy fleet_spawn \
  '{"title":"must fail","rationale":"legacy"}')
I_NOTE=$(rpc_call "$TI" legacy fleet_note \
  '{"finding":"must fail","evidence":"legacy"}')
FLEET_TASK_ID="$TI" FLEET_ATTEMPT=legacy fleet claim add "$TI" cli-legacy \
  --evidence nope >/dev/null 2>&1; I_CLI_CLAIM=$?
FLEET_TASK_ID="$TI" FLEET_ATTEMPT=legacy fleet artifact add "$TI" \
  --path "$FLEET_HOME/artifact-i.txt" >/dev/null 2>&1; I_CLI_ARTIFACT=$?
I_RESULT=$(python3 - "$I_FINISH" "$I_CLAIM" "$I_ARTIFACT" "$I_SEND" \
  "$I_INBOX" "$I_SPAWN" "$I_NOTE" "$I_CLI_CLAIM" "$I_CLI_ARTIFACT" \
  "$DB" "$TI" <<'PY'
import json,sqlite3,sys
finish=int(sys.argv[1]); mcp=list(map(json.loads,sys.argv[2:8]))
cli=list(map(int,sys.argv[8:10])); db,tid=sys.argv[10:]
assert finish==16 and cli==[16,16], (finish,cli)
assert all(x['result'].get('isError') is True for x in mcp), mcp
c=sqlite3.connect(db)
assert c.execute('SELECT COUNT(*) FROM claim WHERE task_id=?',(tid,)).fetchone()[0]==0
assert c.execute('SELECT COUNT(*) FROM artifact WHERE task_id=?',(tid,)).fetchone()[0]==0
assert c.execute("SELECT COUNT(*) FROM message WHERE from_agent=?",('task-'+tid,)).fetchone()[0]==0
assert c.execute("SELECT COUNT(*) FROM event WHERE task_id=? AND kind='attempt.stale' AND json_extract(payload,'$.reason')='legacy'",(tid,)).fetchone()[0]==9
assert c.execute('SELECT status FROM task WHERE id=?',(tid,)).fetchone()[0]=='running'
print('ok')
PY
)
if [ "$I_RESULT" = ok ]; then
  ok "I: literal legacy is rejected by finish, every MCP writer, and CLI claim/artifact"
else
  no "I: legacy write fencing failed ($I_RESULT)"
fi

# J. Switchboard remote prompt/output names include the attempt, so two live
# generations cannot overwrite or remove one another's scratch files.
J_DRY=$(FLEET_ADAPTER_DRYRUN=1 FLEET_ATTEMPT=attempt-J-uuid \
  FLEET_SB_NODE=node-j FLEET_SB_REMOTE_CMD=cat FLEET_SB_MCP_CMD=cb \
  bash "$ROOT/adapters/switchboard.sh" 77 "$FLEET_HOME/artifact-i.txt" /tmp \
  "$FLEET_HOME/j.out" "$FLEET_HOME/j.log")
if [[ "$J_DRY" == *"/tmp/fleet-task-77-attempt-attempt-J-uuid-prompt.md"* ]] \
   && [[ "$J_DRY" == *"/tmp/fleet-task-77-attempt-attempt-J-uuid-out.md"* ]]; then
  ok "J: switchboard remote scratch paths include the attempt identity"
else
  no "J: switchboard attempt paths missing ($J_DRY)"
fi

# K. CLI claim/artifact validation and INSERT execute under BEGIN IMMEDIATE.
TK=$(fleet add "K CLI transaction" --channel shell)
sql "UPDATE task SET attempt=1,attempt_id='cli-current' WHERE id=$TK"
K_RESULT=$(python3 - "$ROOT/bin/fleet" "$DB" "$TK" "$FLEET_HOME/artifact-i.txt" <<'PY'
import contextlib,importlib.machinery,importlib.util,io,sqlite3,sys,types
path,db,tid,artifact=sys.argv[1:]
loader=importlib.machinery.SourceFileLoader('fleet_p21_cli_tx',path)
spec=importlib.util.spec_from_loader(loader.name,loader)
fleet=importlib.util.module_from_spec(spec); loader.exec_module(fleet)
class Probe(sqlite3.Connection):
    saw_select=False
    begin=None
    def execute(self, sql, params=()):
        if sql.startswith('BEGIN'):
            self.begin=sql
        if sql.startswith('SELECT * FROM task'):
            assert self.in_transaction, sql
            self.saw_select=True
        return super().execute(sql,params)
def run(fn,args):
    conn=sqlite3.connect(db,factory=Probe); conn.row_factory=sqlite3.Row
    old=fleet.db_connect; fleet.db_connect=lambda: conn
    try:
        with contextlib.redirect_stdout(io.StringIO()): fn(args)
        assert conn.begin=='BEGIN IMMEDIATE', conn.begin
        assert conn.saw_select
    finally: fleet.db_connect=old; conn.close()
run(fleet.cmd_claim_add,types.SimpleNamespace(task_id=int(tid),claim='tx',evidence='tx'))
run(fleet.cmd_artifact_add,types.SimpleNamespace(task_id=int(tid),path=artifact,kind='file',summary='tx'))
print('ok')
PY
)
if [ "$K_RESULT" = ok ]; then
  ok "K: CLI claim/artifact validate and insert under one immediate transaction"
else
  no "K: CLI transaction fence missing ($K_RESULT)"
fi

# L. A pre-attempt running row with attempt_id NULL is settled atomically:
# NULL-safe matching changes the state before releasing its lease/logging.
new_home
TL=$(fleet add "L null orphan" --channel shell --lease p21-null-orphan --max-attempts 2)
sql "UPDATE task SET status='running',attempt=1,attempt_id=NULL,pid=NULL,started_at=1 WHERE id=$TL; INSERT INTO lease(resource,holder,acquired_at,expires_at) VALUES('p21-null-orphan',CAST($TL AS TEXT),1,NULL)"
FLEET_ORPHAN_GRACE_S=0 fleet status --all >/dev/null
L_STATE=$(sql "SELECT status||':'||exit_code FROM task WHERE id=$TL")
L_LEASE=$(sql "SELECT COUNT(*) FROM lease WHERE resource='p21-null-orphan'")
L_EVENT=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$TL AND kind='task.orphaned'")
TM=$(fleet add "L zero-row rollback" --channel shell --lease p21-zero-row --max-attempts 2)
sql "UPDATE task SET status='running',attempt=1,attempt_id=NULL,pid=NULL,started_at=1 WHERE id=$TM; INSERT INTO lease(resource,holder,acquired_at,expires_at) VALUES('p21-zero-row',CAST($TM AS TEXT),1,NULL)"
L_ZERO=$(python3 - "$ROOT/bin/fleet" "$DB" "$TM" <<'PY'
import importlib.machinery,importlib.util,sqlite3,sys
path,db,tid=sys.argv[1:]
loader=importlib.machinery.SourceFileLoader('fleet_p21_orphan_tx',path)
spec=importlib.util.spec_from_loader(loader.name,loader)
fleet=importlib.util.module_from_spec(spec); loader.exec_module(fleet)
class NoMatch:
    rowcount=0
class Probe(sqlite3.Connection):
    def execute(self, sql, params=()):
        if sql.startswith("UPDATE task SET status='queued'") and str(params[1])==tid:
            return NoMatch()
        return super().execute(sql,params)
conn=sqlite3.connect(db,factory=Probe); conn.row_factory=sqlite3.Row
fleet.ORPHAN_GRACE_S=0
fleet.reap_orphans(conn)
row=conn.execute('SELECT status FROM task WHERE id=?',(tid,)).fetchone()
lease=conn.execute("SELECT COUNT(*) FROM lease WHERE resource='p21-zero-row'").fetchone()[0]
events=conn.execute("SELECT COUNT(*) FROM event WHERE task_id=? AND kind='task.orphaned'",(tid,)).fetchone()[0]
assert row['status']=='running' and lease==1 and events==0, (dict(row),lease,events)
print('ok')
PY
)
if [ "$L_STATE" = "queued:-1" ] && [ "$L_LEASE" = 0 ] \
   && [ "$L_EVENT" = 1 ] && [ "$L_ZERO" = ok ]; then
  ok "L: NULL orphan settles atomically and a zero-row update rolls everything back"
else
  no "L: NULL orphan state=$L_STATE lease=$L_LEASE event=$L_EVENT zero=$L_ZERO"
fi

echo "---"
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = 0 ]
