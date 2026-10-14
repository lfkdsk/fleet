#!/usr/bin/env bash
# A task is not finished while a process it launched is still alive.  This
# suite uses a shell-backed fake agent channel so it exercises the real Fleet
# launcher/session/wrapper path without spending model quota.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-detached-child-test-XXXX)"
unset _FLEET_LOCK_FD

PASS=0 FAIL=0 N=0
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }
field(){ fleet show "$1" | awk -v f="$2" '$1==f":"{print $2}'; }
sql(){ sqlite3 -cmd '.timeout 10000' "$FLEET_HOME/fleet.db" "$1"; }
wait_field(){
  local id="$1" key="$2" want="$3" i got
  for i in $(seq 1 100); do
    got=$(field "$id" "$key")
    [ "$got" = "$want" ] && return 0
    sleep 0.05
  done
  return 1
}
cleanup(){
  local child id pid_file
  for pid_file in detached.pid setsid.pid session.pid orphan-adapter.pids orphan-child.pids bystander.pid multi.pids timeout.pid nonzero.pid commander-tail.pids review-tail.pid unreadable-tail.pid unreadable-commander.pid; do
    while read -r child; do
      [ -z "$child" ] || kill "$child" 2>/dev/null || true
    done 2>/dev/null < "$FLEET_HOME/$pid_file" || true
  done
  while read -r id; do
    [ -z "$id" ] || fleet cancel "$id" >/dev/null 2>&1 || true
  done < <(sql "SELECT id FROM task WHERE status IN ('queued','running')" 2>/dev/null)
  rm -rf "$FLEET_HOME"
}
trap cleanup EXIT

fleet init >/dev/null
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as src:
    channels = json.load(src)
channels["channels"]["fake-detached"] = {
    "adapter": "shell.sh", "family": "none",
}
with open(path, "w") as dst:
    json.dump(channels, dst, indent=2)
PY

printf '%s\n' \
  'read -r _ < "$1"' > "$FLEET_HOME/background-self-exit.sh"
printf '%s\n' \
  'export FLEET_BACKGROUND_TEST_SECRET=fleet-secret-never-store-1683' \
  'mkfifo "$FLEET_HOME/detached.release"' \
  'printf -v long_arg "%*s" 400 ""' \
  'long_arg=${long_arg// /x}' \
  'nohup bash "$FLEET_HOME/background-self-exit.sh" "$FLEET_HOME/detached.release" fleet-bg-diagnostic Bearer ARGVBEARER1683 --jwt ARGVJWT1683 --token=ARGVTOKEN1683 --api-key ARGVAPI1683 --password=ARGVPASS1683 "https://x.test/cb?token=ARGVQT1683&key=ARGVQK1683&secret=ARGVQS1683&password=ARGVQP1683" sk-ARGVKEY1683 "$long_arg" </dev/null >/dev/null 2>&1 &' \
  'echo $! > "$FLEET_HOME/detached.pid"' \
  'exit 0' > "$FLEET_HOME/detach.sh"
printf '%s\n' 'echo started > "$FLEET_HOME/waiter.started"' \
  > "$FLEET_HOME/waiter.sh"
printf '%s\n' 'echo started > "$FLEET_HOME/orphan-waiter.started"' \
  > "$FLEET_HOME/orphan-waiter.sh"
printf '%s\n' \
  'setsid sleep 60 </dev/null >/dev/null 2>&1 &' \
  'echo $! > "$FLEET_HOME/setsid.pid"' \
  'exit 0' > "$FLEET_HOME/setsid.sh"
printf '%s\n' \
  'env -u FLEET_ATTEMPT sleep 60 </dev/null >/dev/null 2>&1 &' \
  'echo $! > "$FLEET_HOME/session.pid"' \
  'exit 0' > "$FLEET_HOME/session.sh"
printf '%s\n' \
  'echo $$ >> "$FLEET_HOME/orphan-adapter.pids"' \
  'printf x >> "$FLEET_HOME/orphan.starts"' \
  'nohup sleep 60 </dev/null >/dev/null 2>&1 &' \
  'echo $! >> "$FLEET_HOME/orphan-child.pids"' \
  'exec sleep 60' > "$FLEET_HOME/orphan.sh"
printf '%s\n' \
  'nohup python3 -c "import time; time.sleep(60)" fleet-bg-first </dev/null >/dev/null 2>&1 &' \
  'echo $! >> "$FLEET_HOME/multi.pids"' \
  'nohup python3 -c "import time; time.sleep(60)" fleet-bg-second </dev/null >/dev/null 2>&1 &' \
  'echo $! >> "$FLEET_HOME/multi.pids"' \
  'exit 0' > "$FLEET_HOME/multi.sh"
printf '%s\n' \
  'nohup sleep 60 </dev/null >/dev/null 2>&1 &' \
  'echo $! > "$FLEET_HOME/timeout.pid"' \
  'exit 0' > "$FLEET_HOME/timeout.sh"
printf '%s\n' \
  'mkfifo "$FLEET_HOME/nonzero.release"' \
  'nohup bash "$FLEET_HOME/background-self-exit.sh" "$FLEET_HOME/nonzero.release" fleet-bg-nonzero </dev/null >/dev/null 2>&1 &' \
  'echo $! > "$FLEET_HOME/nonzero.pid"' \
  'exit 7' > "$FLEET_HOME/nonzero.sh"
cat > "$FLEET_HOME/commander-tail.sh" <<'SH'
#!/usr/bin/env bash
set -u
count_file="$FLEET_HOME/commander-tail.count"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "$count" -eq 1 ]; then
  printf 'not json\n'
else
  python3 - "$0" <<'PY'
import json
import re
import sys

prompt = open(sys.argv[1]).read()
number = lambda pattern: int(re.search(pattern, prompt).group(1))
proposal = {
    "goal_id": number(r'"id": (\d+)'),
    "based_on_plan_revision": number(r'"revision": (\d+)'),
    "through_event_id": number(r'"through_event_id": (\d+)'),
    "proposed_tasks": [{
        "channel": "fake-detached",
        "title": "background commander worker",
        "problem": "printf applied > \"$FLEET_HOME/commander-worker.started\"",
        "evidence": "commander.round and child task",
        "expected_artifact": "commander worker marker",
        "verification": "inspect the child task and marker",
        "dedup_key": "background-commander-worker",
        "scope": "isolated detached-child test home",
    }],
    "decisions": [],
    "next_wake": {"reason": "waiting_for_tasks"},
}
print(json.dumps(proposal))
PY
fi
release="$FLEET_HOME/commander-tail-$count.release"
mkfifo "$release"
nohup bash "$FLEET_HOME/background-self-exit.sh" "$release" \
  "fleet-bg-commander-$count" </dev/null >/dev/null 2>&1 &
echo $! >> "$FLEET_HOME/commander-tail.pids"
exit 0
SH
printf '%s\n' \
  'mkfifo "$FLEET_HOME/review-tail.release"' \
  'nohup bash "$FLEET_HOME/background-self-exit.sh" "$FLEET_HOME/review-tail.release" fleet-bg-empty-review </dev/null >/dev/null 2>&1 &' \
  'echo $! > "$FLEET_HOME/review-tail.pid"' \
  'exit 0' > "$FLEET_HOME/review-tail.sh"
printf '%s\n' 'printf target-output\n' > "$FLEET_HOME/review-target.sh"
printf '%s\n' 'printf started > "$FLEET_HOME/review-dependent.started"' \
  > "$FLEET_HOME/review-dependent.sh"
cat > "$FLEET_HOME/unreadable-tail.sh" <<'SH'
#!/usr/bin/env bash
set -u
rm -rf "$FLEET_RUN_DIR/out.md"
mkdir "$FLEET_RUN_DIR/out.md"
mkfifo "$FLEET_HOME/unreadable-tail.release"
nohup bash "$FLEET_HOME/background-self-exit.sh" \
  "$FLEET_HOME/unreadable-tail.release" fleet-bg-unreadable \
  </dev/null >/dev/null 2>&1 &
echo $! > "$FLEET_HOME/unreadable-tail.pid"
exit 0
SH
printf '%s\n' 'printf started > "$FLEET_HOME/unreadable-peer.started"' \
  > "$FLEET_HOME/unreadable-peer.sh"
cat > "$FLEET_HOME/unreadable-commander.sh" <<'SH'
#!/usr/bin/env bash
set -u
python3 - "$0" <<'PY'
import json
import re
import sys

prompt = open(sys.argv[1]).read()
number = lambda pattern: int(re.search(pattern, prompt).group(1))
print(json.dumps({
    "goal_id": number(r'"id": (\d+)'),
    "based_on_plan_revision": number(r'"revision": (\d+)'),
    "through_event_id": number(r'"through_event_id": (\d+)'),
    "proposed_tasks": [{
        "channel": "fake-detached",
        "title": "must not apply unreadable commander proposal",
        "problem": "printf applied > \"$FLEET_HOME/unreadable-commander-worker.started\"",
        "evidence": "no commander.round and no child task",
        "expected_artifact": "no worker marker",
        "verification": "inspect commander events and children",
        "dedup_key": "unreadable-commander-worker",
        "scope": "isolated detached-child test home",
    }],
    "decisions": [],
    "next_wake": {"reason": "waiting_for_tasks"},
}))
PY
rm -rf "$FLEET_RUN_DIR/out.md"
mkdir "$FLEET_RUN_DIR/out.md"
mkfifo "$FLEET_HOME/unreadable-commander.release"
nohup bash "$FLEET_HOME/background-self-exit.sh" \
  "$FLEET_HOME/unreadable-commander.release" fleet-bg-unreadable-commander \
  </dev/null >/dev/null 2>&1 &
echo $! > "$FLEET_HOME/unreadable-commander.pid"
exit 0
SH

G1=$(fleet goal add "background diagnostics stay credential-free")
T1=$(fleet add "fake agent leaves nohup child" --channel fake-detached \
  --goal "$G1" --lease detached-child-resource --no-preamble \
  --spec "$FLEET_HOME/detach.sh")
T2=$(fleet add "same lease waiter" --channel fake-detached \
  --goal "$G1" --dep "$T1" --lease detached-child-resource --no-preamble \
  --spec "$FLEET_HOME/waiter.sh")
fleet run "$T1" >/dev/null

child=""
for _ in $(seq 1 100); do
  child=$(cat "$FLEET_HOME/detached.pid" 2>/dev/null || true)
  bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T1 AND kind='task.background'" 2>/dev/null)
  [ -n "$child" ] && [ "${bg:-0}" -ge 1 ] && break
  case "$(field "$T1" status)" in done|failed|cancelled) break ;; esac
  sleep 0.05
done
fleet daemon run --once >/dev/null 2>&1
status_active=$(fleet status --all)
brief_active=$(fleet brief --all)
json_active=$(fleet --json status --all)
show_active=$(fleet show "$T1")
show_json_active=$(fleet --json show "$T1")
wait_active=$(fleet wait --any --ids "$T1" --timeout 5 2>&1)
wait_active_rc=$?
wait_default=$(fleet wait --ids "$T1" --timeout 5 2>&1)
wait_default_rc=$?
commander_prompt=$(PYTHONDONTWRITEBYTECODE=1 ROOT="$ROOT" G1="$G1" \
  python3 -B - <<'PY'
import importlib.machinery, importlib.util
import os
path = os.path.join(os.environ["ROOT"], "bin", "fleet")
loader = importlib.machinery.SourceFileLoader("fleet_detached_prompt", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
fleet = importlib.util.module_from_spec(spec)
loader.exec_module(fleet)
conn = fleet.db_connect()
goal = conn.execute("SELECT * FROM goal WHERE id=?", (int(os.environ["G1"]),)).fetchone()
print(fleet.commander_construction(
    conn, goal, cwd=os.environ["ROOT"]
)[1])
PY
)
holder=$(sql "SELECT holder FROM lease WHERE resource='detached-child-resource'")
event_pids=$(sql "SELECT json_extract(payload,'$.pids') FROM event WHERE task_id=$T1 AND kind='task.background' ORDER BY id DESC LIMIT 1")
event_cmd=$(sql "SELECT json_extract(value,'$.cmdline') FROM event,json_each(event.payload,'$.processes') WHERE task_id=$T1 AND kind='task.background' AND json_extract(value,'$.pid')=$child ORDER BY event.id DESC LIMIT 1")
event_cmd_truncated=$(sql "SELECT json_extract(value,'$.cmdline_truncated') FROM event,json_each(event.payload,'$.processes') WHERE task_id=$T1 AND kind='task.background' AND json_extract(value,'$.pid')=$child ORDER BY event.id DESC LIMIT 1")
event_exit_active=$(sql "SELECT COALESCE(CAST(json_extract(value,'$.exited_at') AS TEXT),'null') FROM event,json_each(event.payload,'$.processes') WHERE task_id=$T1 AND kind='task.background' AND json_extract(value,'$.pid')=$child ORDER BY event.id DESC LIMIT 1")
stored_payloads=$(PYTHONDONTWRITEBYTECODE=1 ROOT="$ROOT" T1="$T1" \
  python3 -B - <<'PY'
import importlib.machinery, importlib.util
import os
path = os.path.join(os.environ["ROOT"], "bin", "fleet")
loader = importlib.machinery.SourceFileLoader("fleet_detached_payloads", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
fleet = importlib.util.module_from_spec(spec)
loader.exec_module(fleet)
conn = fleet.db_connect()
for row in conn.execute("SELECT payload FROM event WHERE task_id=? ORDER BY id",
                        (int(os.environ["T1"]),)):
    print(fleet.spill_load(row["payload"] or ""))
PY
)
active_diagnostics="$event_pids $event_cmd $stored_payloads $status_active $brief_active $json_active $show_active $show_json_active $wait_active $wait_default $commander_prompt"
if [ -n "$child" ] && kill -0 "$child" 2>/dev/null \
   && [ "$(field "$T1" status)" = running ] \
   && [ "$(field "$T2" status)" = queued ] \
   && [ "$holder" = "$T1" ] \
   && [ ! -e "$FLEET_HOME/waiter.started" ] \
   && printf '%s\n' "$event_pids" | grep -q "$child" \
   && printf '%s\n' "$event_cmd" | grep -q 'fleet-bg-diagnostic' \
   && printf '%s\n' "$event_cmd" | grep -q '…\[truncated\]$' \
   && [ "${#event_cmd}" -le 240 ] \
   && [ "$event_cmd_truncated" = 1 ] \
   && [ "$event_exit_active" = null ] \
   && ! printf '%s\n' "$active_diagnostics" | grep -q 'fleet-secret-never-store-1683' \
   && ! printf '%s\n' "$active_diagnostics" | grep -Eq 'ARGV[A-Z]+1683|sk-ARGVKEY1683' \
   && printf '%s\n' "$active_diagnostics" | grep -q '\[REDACTED\]' \
   && printf '%s\n' "$status_active" | grep -q "^$T1 .*running(adapter-done,1-background).*BACKGROUND-PIDS=$child.*BACKGROUND-CMDS=.*fleet-bg-diagnostic.*BACKGROUND-EXITED-AT=.*null" \
   && printf '%s\n' "$brief_active" | grep -q "$T1 running(adapter-done,1-background).*background pids=$child.*cmds=.*fleet-bg-diagnostic.*exited_at=.*null" \
   && [ "$wait_active_rc" = 125 ] \
   && [ "$wait_default_rc" = 125 ] \
   && printf '%s\n' "$wait_active" | grep -q "^task $T1: adapter exited; 1 background processes alive: .*pid $child .*fleet-bg-diagnostic.*Confirm intent before killing.*fleet show $T1" \
   && printf '%s\n' "$wait_default" | grep -q "^task $T1: adapter exited; 1 background processes alive: .*pid $child .*fleet-bg-diagnostic.*Confirm intent before killing.*fleet show $T1" \
   && printf '%s\n' "$show_active" | grep -q "background_process:.*\"pid\":$child.*\"cmdline\":\".*fleet-bg-diagnostic.*\"exited_at\":null" \
   && JSON_ACTIVE="$json_active" SHOW_JSON_ACTIVE="$show_json_active" T1="$T1" CHILD="$child" python3 -c 'import json,os; rows=json.loads(os.environ["JSON_ACTIVE"]); shown=json.loads(os.environ["SHOW_JSON_ACTIVE"]); t=next(x for x in rows if x["id"]==int(os.environ["T1"])); p=t["background_processes"][0]; assert t["status"]=="running" and t["background_pids"]==[int(os.environ["CHILD"])] and p["pid"]==int(os.environ["CHILD"]) and "fleet-bg-diagnostic" in p["cmdline"] and p["cmdline_truncated"] is True and len(p["cmdline"]) <= 240 and p["exited_at"] is None and t["background_exited_at"] is None; assert shown["background_processes"]==t["background_processes"] and shown["background_exited_at"] is None'; then
  ok "live child keeps task/lease; persisted/displayed cmdline hides env and argv credentials"
else
  no "live child diagnostics (child=$child t1=$(field "$T1" status) t2=$(field "$T2" status) holder=$holder event=$event_pids cmd='$event_cmd' truncated=$event_cmd_truncated exit=$event_exit_active wait=$wait_active_rc/'$wait_active' default=$wait_default_rc/'$wait_default' status='$status_active' brief='$brief_active' show='$show_active')"
fi

printf 'done\n' > "$FLEET_HOME/detached.release"
if [ "$(field "$T1" status)" = running ]; then
  for _ in $(seq 1 100); do
    fleet daemon run --once >/dev/null 2>&1
    case "$(field "$T1" status)" in done|failed|cancelled) break ;; esac
    sleep 0.05
  done
fi
lease_after=held
for _ in $(seq 1 100); do
  lease_after=$(sql "SELECT COALESCE((SELECT holder FROM lease WHERE resource='detached-child-resource'),'')")
  [ -z "$lease_after" ] && break
  sleep 0.05
done
if [ "$(field "$T1" status)" = done ]; then
  wait_field "$T2" status done || true
fi
finish_reason=$(sql "SELECT payload FROM event WHERE task_id=$T1 AND kind='task.finish' ORDER BY id DESC LIMIT 1")
success_attempt=$(sql "SELECT status||':'||exit_code FROM attempt WHERE task_id=$T1 ORDER BY generation DESC LIMIT 1")
success_timeout=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T1 AND kind='task.timeout'")
status_settled=$(fleet status --all)
brief_settled=$(fleet brief --all)
show_settled=$(fleet show "$T1")
json_settled=$(fleet --json status --all)
show_json_settled=$(fleet --json show "$T1")
settled_payloads=$(PYTHONDONTWRITEBYTECODE=1 ROOT="$ROOT" T1="$T1" \
  python3 -B - <<'PY'
import importlib.machinery, importlib.util
import os
path = os.path.join(os.environ["ROOT"], "bin", "fleet")
loader = importlib.machinery.SourceFileLoader("fleet_detached_settled", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
fleet = importlib.util.module_from_spec(spec)
loader.exec_module(fleet)
conn = fleet.db_connect()
for row in conn.execute("SELECT payload FROM event WHERE task_id=? ORDER BY id",
                        (int(os.environ["T1"]),)):
    print(fleet.spill_load(row["payload"] or ""))
PY
)
event_exit_settled=$(sql "SELECT json_extract(value,'$.exited_at') FROM event,json_each(event.payload,'$.processes') WHERE task_id=$T1 AND kind='task.background' AND json_extract(value,'$.pid')=$child ORDER BY event.id DESC LIMIT 1")
background_exited_at=$(sql "SELECT json_extract(payload,'$.exited_at') FROM event WHERE task_id=$T1 AND kind='task.background' ORDER BY id DESC LIMIT 1")
finish_exited_at=$(sql "SELECT json_extract(payload,'$.background_exited_at') FROM event WHERE task_id=$T1 AND kind='task.finish' ORDER BY id DESC LIMIT 1")
exit_stamp_ok=""
case "$event_exit_settled" in
  ''|*[!0-9]*) ;;
  *) [ "$event_exit_settled" -gt 0 ] && exit_stamp_ok=1 ;;
esac
if [ "$(field "$T1" status)" = done ] \
   && [ "$(field "$T1" exit_code)" = 0 ] \
   && [ "$success_attempt" = "done:0" ] \
   && [ "$success_timeout" = 0 ] \
   && [ -z "$lease_after" ] \
   && [ "$(field "$T2" status)" = done ] \
   && [ -e "$FLEET_HOME/waiter.started" ] \
   && [ -n "$exit_stamp_ok" ] \
   && [ "$event_exit_settled" = "$background_exited_at" ] \
   && [ "$event_exit_settled" = "$finish_exited_at" ] \
   && printf '%s\n' "$status_settled" | grep -q "^$T1 .*done!background.*BACKGROUND-PIDS=$child.*BACKGROUND-CMDS=.*fleet-bg-diagnostic.*BACKGROUND-EXITED-AT=.*$event_exit_settled" \
   && printf '%s\n' "$brief_settled" | grep -q "BACKGROUND COMPLETIONS" \
   && printf '%s\n' "$brief_settled" | grep -q "$T1 done!background.*cmds=.*fleet-bg-diagnostic.*exited_at=.*$event_exit_settled" \
   && printf '%s\n' "$show_settled" | grep -q "background_process:.*\"pid\":$child.*fleet-bg-diagnostic.*\"exited_at\":$event_exit_settled" \
   && printf '%s\n' "$show_settled" | grep -q "^background_exited_at: $event_exit_settled$" \
   && JSON_SETTLED="$json_settled" SHOW_JSON_SETTLED="$show_json_settled" T1="$T1" CHILD="$child" EXITED="$event_exit_settled" python3 -c 'import json,os; t=next(x for x in json.loads(os.environ["JSON_SETTLED"]) if x["id"]==int(os.environ["T1"])); shown=json.loads(os.environ["SHOW_JSON_SETTLED"]); p=t["background_processes"][0]; assert t["status"]=="done" and t["exit_code"]==0 and p["pid"]==int(os.environ["CHILD"]) and p["exited_at"]==int(os.environ["EXITED"]) and t["background_exited_at"]==int(os.environ["EXITED"]); assert shown["background_processes"]==t["background_processes"] and shown["background_exited_at"]==int(os.environ["EXITED"])' \
   && printf '%s\n' "$finish_reason" | grep -q 'background processes exited after successful adapter' \
   && printf '%s\n' "$finish_reason" | grep -q 'fleet-bg-diagnostic' \
   && ! printf '%s\n' "$settled_payloads $status_settled $brief_settled $show_settled $json_settled $show_json_settled" | grep -Eq 'ARGV[A-Z]+1683|sk-ARGVKEY1683'; then
  ok "successful adapter plus self-exiting child settles done and admits its dependent waiter"
else
  no "background settlement diagnostics (t1=$(field "$T1" status)/$(field "$T1" exit_code) attempt=$success_attempt timeout=$success_timeout lease=$lease_after t2=$(field "$T2" status) exit=$event_exit_settled/$background_exited_at/$finish_exited_at finish=$finish_reason status='$status_settled' brief='$brief_settled' show='$show_settled')"
fi

T3=$(fleet add "fake agent leaves setsid child" --channel fake-detached \
  --lease detached-setsid-resource --no-preamble --spec "$FLEET_HOME/setsid.sh")
fleet run "$T3" >/dev/null
setsid_child=""
for _ in $(seq 1 100); do
  setsid_child=$(cat "$FLEET_HOME/setsid.pid" 2>/dev/null || true)
  bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T3 AND kind='task.background'" 2>/dev/null)
  [ -n "$setsid_child" ] && [ "${bg:-0}" -ge 1 ] && break
  case "$(field "$T3" status)" in done|failed|cancelled) break ;; esac
  sleep 0.05
done
wrapper=$(field "$T3" pid)
child_sid=$(ps -o sid= -p "$setsid_child" 2>/dev/null | tr -d ' ')
fleet cancel "$T3" >/dev/null 2>&1 || true
setsid_gone=""
for _ in $(seq 1 100); do
  if ! kill -0 "$setsid_child" 2>/dev/null; then
    setsid_gone=1
    break
  fi
  sleep 0.05
done
if [ -n "$setsid_child" ] && [ "$child_sid" = "$setsid_child" ] \
   && [ "$child_sid" != "$wrapper" ] \
   && [ "$(field "$T3" status)" = cancelled ] \
   && [ -n "$setsid_gone" ]; then
  ok "attempt tag detects and cancel stops a child that escaped the task session"
else
  no "setsid child handling (child=$setsid_child child_sid=$child_sid wrapper=$wrapper status=$(field "$T3" status) gone=$setsid_gone)"
fi

# The session anchor is independent of the inherited attempt tag. This child
# deliberately drops FLEET_ATTEMPT but stays in the wrapper's session. The
# marker must pin process birth identities so the child remains attributable
# after the wrapper/session leader exits.
T4=$(fleet add "session-only child" --channel fake-detached \
  --lease detached-session-resource --no-preamble --spec "$FLEET_HOME/session.sh")
fleet run "$T4" >/dev/null
session_child=""
for _ in $(seq 1 100); do
  session_child=$(cat "$FLEET_HOME/session.pid" 2>/dev/null || true)
  bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T4 AND kind='task.background'" 2>/dev/null)
  [ -n "$session_child" ] && [ "${bg:-0}" -ge 1 ] && break
  case "$(field "$T4" status)" in done|failed|cancelled) break ;; esac
  sleep 0.05
done
session_wrapper=$(field "$T4" pid)
session_sid=$(ps -o sid= -p "$session_child" 2>/dev/null | tr -d ' ')
session_child_birth=$(python3 - "$session_child" <<'PY'
from pathlib import Path
import sys
raw = Path(f"/proc/{sys.argv[1]}/stat").read_text()
print(raw[raw.rfind(")") + 2:].split()[19])
PY
)
wrapper_birth=$(sql "SELECT pid_starttime FROM task WHERE id=$T4" 2>/dev/null || true)
attempt_birth=$(sql "SELECT pid_starttime FROM attempt WHERE task_id=$T4 ORDER BY generation DESC LIMIT 1" 2>/dev/null || true)
session_tag=$(tr '\0' '\n' <"/proc/$session_child/environ" 2>/dev/null | grep '^FLEET_ATTEMPT=' || true)
fleet daemon run --once >/dev/null 2>&1
session_holder=$(sql "SELECT holder FROM lease WHERE resource='detached-session-resource'")
session_processes=$(sql "SELECT json_extract(payload,'$.processes') FROM event WHERE task_id=$T4 AND kind='task.background' ORDER BY id DESC LIMIT 1")
session_pinned_birth=$(sql "SELECT json_extract(value,'$.starttime') FROM event,json_each(event.payload,'$.processes') WHERE task_id=$T4 AND kind='task.background' AND json_extract(value,'$.pid')=$session_child ORDER BY event.id DESC LIMIT 1")
if [ -n "$session_child" ] && kill -0 "$session_child" 2>/dev/null \
   && [ "$session_sid" = "$session_wrapper" ] \
   && [ -z "$session_tag" ] \
   && [ -n "$wrapper_birth" ] && [ "$wrapper_birth" = "$attempt_birth" ] \
   && [ "$session_pinned_birth" = "$session_child_birth" ] \
   && [ "$(field "$T4" status)" = running ] \
   && [ "$session_holder" = "$T4" ] \
   && printf '%s\n' "$session_processes" | grep -q "$session_child"; then
  fleet cancel "$T4" >/dev/null 2>&1 || true
  session_gone=""
  for _ in $(seq 1 100); do
    if ! kill -0 "$session_child" 2>/dev/null; then
      session_gone=1
      break
    fi
    sleep 0.05
  done
  if [ -n "$session_gone" ]; then
    ok "session anchor pins a tagless child's birth identity and cancel stops it"
  else
    no "session-only cancel left child alive (child=$session_child processes=$session_processes)"
  fi
else
  no "session-only anchor (child=$session_child sid=$session_sid wrapper=$session_wrapper tag=$session_tag birth=$wrapper_birth/$attempt_birth child_birth=$session_child_birth/$session_pinned_birth status=$(field "$T4" status) holder=$session_holder processes=$session_processes)"
  fleet cancel "$T4" >/dev/null 2>&1 || true
fi

# Kill only the wrapper before it can call _finish. Both the adapter and its
# nohup child survive with attempt tags. Orphan recovery must create the same
# durable marker as _finish, retain the lease, and never launch attempt 2.
T5=$(fleet add "killed wrapper leaves child" --channel fake-detached \
  --lease detached-orphan-resource --max-attempts 2 --no-preamble \
  --spec "$FLEET_HOME/orphan.sh")
T6=$(fleet add "same orphan lease waiter" --channel fake-detached \
  --lease detached-orphan-resource --no-preamble \
  --spec "$FLEET_HOME/orphan-waiter.sh")
fleet run "$T5" >/dev/null
orphan_wrapper=""
orphan_child=""
for _ in $(seq 1 100); do
  orphan_wrapper=$(field "$T5" pid)
  orphan_child=$(tail -1 "$FLEET_HOME/orphan-child.pids" 2>/dev/null || true)
  [ -n "$orphan_wrapper" ] && [ -n "$orphan_child" ] && break
  sleep 0.05
done
orphan_kernel_birth=$(python3 - "$orphan_wrapper" <<'PY'
from pathlib import Path
import sys
raw = Path(f"/proc/{sys.argv[1]}/stat").read_text()
print(raw[raw.rfind(")") + 2:].split()[19])
PY
)
orphan_task_birth=$(sql "SELECT pid_starttime FROM task WHERE id=$T5")
orphan_attempt_birth=$(sql "SELECT pid_starttime FROM attempt WHERE task_id=$T5 ORDER BY generation DESC LIMIT 1")
kill -9 "$orphan_wrapper" 2>/dev/null || true
for _ in $(seq 1 100); do
  [ ! -e "/proc/$orphan_wrapper" ] && break
  state=$(awk '{print $3}' "/proc/$orphan_wrapper/stat" 2>/dev/null || true)
  [ "$state" = Z ] && break
  sleep 0.05
done
sql "UPDATE task SET started_at=started_at-60 WHERE id=$T5"
FLEET_ORPHAN_GRACE_S=0 fleet daemon run --once >/dev/null 2>&1
orphan_holder=$(sql "SELECT holder FROM lease WHERE resource='detached-orphan-resource'")
orphan_attempt=$(field "$T5" attempt)
orphan_rows=$(sql "SELECT COUNT(*) FROM attempt WHERE task_id=$T5")
orphan_starts=$(wc -c <"$FLEET_HOME/orphan.starts" 2>/dev/null || echo 0)
orphan_bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T5 AND kind='task.background'")
orphan_pinned_birth=$(sql "SELECT json_extract(value,'$.starttime') FROM event,json_each(event.payload,'$.processes') WHERE task_id=$T5 AND kind='task.background' AND json_extract(value,'$.pid')=$orphan_child ORDER BY event.id DESC LIMIT 1")
if [ -n "$orphan_child" ] && kill -0 "$orphan_child" 2>/dev/null \
   && [ "$orphan_task_birth" = "$orphan_kernel_birth" ] \
   && [ "$orphan_attempt_birth" = "$orphan_kernel_birth" ] \
   && [ -n "$orphan_pinned_birth" ] \
   && [ "$(field "$T5" status)" = running ] \
   && [ "$(field "$T6" status)" = queued ] \
   && [ ! -e "$FLEET_HOME/orphan-waiter.started" ] \
   && [ "$orphan_holder" = "$T5" ] \
   && [ "$orphan_attempt" = 1 ] && [ "$orphan_rows" = 1 ] \
   && [ "$orphan_starts" = 1 ] && [ "$orphan_bg" -ge 1 ]; then
  ok "orphan scan marks surviving work, keeps its lease, and suppresses max-attempt retry"
else
  no "orphan scan (child=$orphan_child birth=$orphan_kernel_birth/$orphan_task_birth/$orphan_attempt_birth pinned=$orphan_pinned_birth status=$(field "$T5" status) waiter=$(field "$T6" status)/$(test -e "$FLEET_HOME/orphan-waiter.started" && echo started || echo idle) holder=$orphan_holder attempt=$orphan_attempt rows=$orphan_rows starts=$orphan_starts background=$orphan_bg)"
fi
fleet cancel "$T5" >/dev/null 2>&1 || true
fleet cancel "$T6" >/dev/null 2>&1 || true

# A process with a recycled numeric SID is not owned unless its birth identity
# matches the recorded wrapper. Exercise both attribution and signalling with
# kill calls mocked; legacy NULL identities must fail closed as well.
setsid sleep 60 </dev/null >/dev/null 2>&1 &
bystander=$!
echo "$bystander" > "$FLEET_HOME/bystander.pid"
bystander_birth=$(python3 - "$bystander" <<'PY'
from pathlib import Path
import sys
raw = Path(f"/proc/{sys.argv[1]}/stat").read_text()
print(raw[raw.rfind(")") + 2:].split()[19])
PY
)
reuse_result=$(PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/bin/fleet" "$bystander" "$bystander_birth" <<'PY'
import importlib.machinery, importlib.util
import signal, sys
from unittest.mock import patch
loader = importlib.machinery.SourceFileLoader("fleet_detached_reuse", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
fleet = importlib.util.module_from_spec(spec)
loader.exec_module(fleet)
pid, birth = int(sys.argv[2]), int(sys.argv[3])
task = {"id": 987654, "pid": pid, "pid_starttime": birth + 1,
        "attempt_id": "not-the-bystander"}
legacy = dict(task, pid_starttime=None)
stale_marker = {"processes": [{"pid": pid, "starttime": birth + 1}]}
killed = []
with patch.object(fleet.os, "killpg", lambda p, s: killed.append(("pg", p, s))), \
     patch.object(fleet.os, "kill", lambda p, s: killed.append(("pid", p, s))):
    found = fleet._task_live_processes(task)
    legacy_found = fleet._task_live_processes(legacy)
    marker_found = fleet._task_live_processes(task, background=stale_marker)
    fleet._signal_task_processes(task, signal.SIGTERM)
    fleet._signal_task_processes(task, signal.SIGKILL, background=stale_marker)
assert pid not in found, found
assert pid not in legacy_found, legacy_found
assert pid not in marker_found, marker_found
assert killed == [], killed
print("ok")
PY
)
if [ "$reuse_result" = ok ] && kill -0 "$bystander" 2>/dev/null; then
  ok "recycled SID mismatch and legacy NULL identity neither attribute nor signal a bystander"
else
  no "recycled SID detection/signalling (result=$reuse_result alive=$(kill -0 "$bystander" 2>/dev/null && echo yes || echo no))"
fi

# A marker-backed task pointed at that recycled SID must settle instead of
# holding its lease forever. A legacy row without starttime takes the bounded
# ordinary-orphan path instead of trusting a naked live PID.
T7=$(fleet add "recycled SID marker" --channel fake-detached \
  --lease detached-recycled-resource --no-preamble --spec "$FLEET_HOME/waiter.sh")
T8=$(fleet add "legacy null wrapper identity" --channel fake-detached \
  --lease detached-legacy-resource --no-preamble --spec "$FLEET_HOME/waiter.sh")
has_birth=$(sql "SELECT COUNT(*) FROM pragma_table_info('task') WHERE name='pid_starttime'" 2>/dev/null || echo 0)
if [ "$has_birth" = 1 ]; then
  mkdir -p "$FLEET_HOME/reuse-fixture"
  sql "UPDATE task SET status='running',attempt=1,attempt_id='reuse-fixture',pid=$bystander,pid_starttime=$((bystander_birth+1)),started_at=strftime('%s','now')-60,run_dir='$FLEET_HOME/reuse-fixture',out_path='$FLEET_HOME/reuse-fixture/out',log_path='$FLEET_HOME/reuse-fixture/log' WHERE id=$T7;
INSERT INTO attempt(attempt_id,task_id,generation,status,pid,pid_starttime,run_dir,out_path,log_path,started_at) VALUES('reuse-fixture',$T7,1,'running',$bystander,$((bystander_birth+1)),'$FLEET_HOME/reuse-fixture','$FLEET_HOME/reuse-fixture/out','$FLEET_HOME/reuse-fixture/log',strftime('%s','now')-60);
INSERT INTO lease(resource,holder,acquired_at) VALUES('detached-recycled-resource','$T7',strftime('%s','now'));
INSERT INTO event(ts,task_id,kind,payload) VALUES(strftime('%s','now'),$T7,'task.background',json_object('attempt_id','reuse-fixture','pids',json_array($bystander),'adapter_exit_code',0));
UPDATE task SET status='running',attempt=1,attempt_id='legacy-null-fixture',pid=$bystander,pid_starttime=NULL,started_at=strftime('%s','now')-60,run_dir='$FLEET_HOME/reuse-fixture',out_path='$FLEET_HOME/reuse-fixture/out2',log_path='$FLEET_HOME/reuse-fixture/log2' WHERE id=$T8;
INSERT INTO attempt(attempt_id,task_id,generation,status,pid,pid_starttime,run_dir,out_path,log_path,started_at) VALUES('legacy-null-fixture',$T8,1,'running',$bystander,NULL,'$FLEET_HOME/reuse-fixture','$FLEET_HOME/reuse-fixture/out2','$FLEET_HOME/reuse-fixture/log2',strftime('%s','now')-60);
INSERT INTO lease(resource,holder,acquired_at) VALUES('detached-legacy-resource','$T8',strftime('%s','now'));"
  FLEET_ORPHAN_GRACE_S=0 fleet status --all >/dev/null 2>&1
fi
reuse_lease=$(sql "SELECT COUNT(*) FROM lease WHERE resource='detached-recycled-resource'" 2>/dev/null || echo 1)
legacy_lease=$(sql "SELECT COUNT(*) FROM lease WHERE resource='detached-legacy-resource'" 2>/dev/null || echo 1)
if [ "$has_birth" = 1 ] \
   && [ "$(field "$T7" status)" = done ] && [ "$(field "$T7" exit_code)" = 0 ] \
   && [ "$(field "$T8" status)" = failed ] && [ "$(field "$T8" exit_code)" = -1 ] \
   && [ "$reuse_lease" = 0 ] && [ "$legacy_lease" = 0 ] \
   && kill -0 "$bystander" 2>/dev/null; then
  ok "recycled and legacy wrapper identities cannot hold leases after real work is gone"
else
  no "recycled/legacy reap (schema=$has_birth t7=$(field "$T7" status)/$(field "$T7" exit_code)/$reuse_lease t8=$(field "$T8" status)/$(field "$T8" exit_code)/$legacy_lease bystander=$(kill -0 "$bystander" 2>/dev/null && echo alive || echo dead))"
fi
kill "$bystander" 2>/dev/null || true

# Schema migration is deliberately NULL-preserving: an old numeric pid has no
# trustworthy birth identity to invent. Re-init adds both columns idempotently
# while preserving task/attempt history; the bounded legacy path above proves
# those NULL values cannot wedge a lease.
T9=$(fleet add "pre-starttime schema row" --channel fake-detached \
  --no-preamble --spec "$FLEET_HOME/waiter.sh")
fleet run "$T9" >/dev/null
wait_field "$T9" status done || true
sql "ALTER TABLE task DROP COLUMN pid_starttime; ALTER TABLE attempt DROP COLUMN pid_starttime;"
fleet init >/dev/null 2>&1
fleet init >/dev/null 2>&1
task_birth_col=$(sql "SELECT COUNT(*) FROM pragma_table_info('task') WHERE name='pid_starttime'")
attempt_birth_col=$(sql "SELECT COUNT(*) FROM pragma_table_info('attempt') WHERE name='pid_starttime'")
migrated_task=$(sql "SELECT title||':'||status||':'||(pid_starttime IS NULL) FROM task WHERE id=$T9")
migrated_attempt=$(sql "SELECT status||':'||(pid_starttime IS NULL) FROM attempt WHERE task_id=$T9")
if [ "$task_birth_col" = 1 ] && [ "$attempt_birth_col" = 1 ] \
   && [ "$migrated_task" = "pre-starttime schema row:done:1" ] \
   && [ "$migrated_attempt" = "done:1" ]; then
  ok "init adds nullable starttime fences to legacy task/attempt rows idempotently"
else
  no "starttime schema migration (columns=$task_birth_col/$attempt_birth_col task=$migrated_task attempt=$migrated_attempt)"
fi

# Multiple children can disappear in different daemon polls. Each identity's
# first exit observation must survive later full snapshots; the first exit
# alone must not settle the task while the second child is still alive.
T10=$(fleet add "two background children" --channel fake-detached \
  --lease detached-multi-resource --no-preamble --spec "$FLEET_HOME/multi.sh")
fleet run "$T10" >/dev/null
multi_first="" multi_second=""
multi_pids=()
for _ in $(seq 1 100); do
  mapfile -t multi_pids < "$FLEET_HOME/multi.pids" 2>/dev/null || true
  if [ "${#multi_pids[@]}" -ge 2 ]; then
    multi_first="${multi_pids[0]}"
    multi_second="${multi_pids[1]}"
  fi
  multi_count=$(sql "SELECT COALESCE(json_array_length(json_extract(payload,'$.processes')),0) FROM event WHERE task_id=$T10 AND kind='task.background' ORDER BY id DESC LIMIT 1" 2>/dev/null || echo 0)
  [ -n "$multi_first" ] && [ -n "$multi_second" ] \
    && [ "${multi_count:-0}" -ge 2 ] && break
  sleep 0.05
done
multi_initial_cmds=$(sql "SELECT group_concat(json_extract(value,'$.cmdline'),'|') FROM event,json_each(event.payload,'$.processes') WHERE task_id=$T10 AND kind='task.background' AND event.id=(SELECT MAX(id) FROM event WHERE task_id=$T10 AND kind='task.background')")
kill "$multi_first" 2>/dev/null || true
multi_first_exit="" multi_second_partial="" multi_active=""
for _ in $(seq 1 100); do
  fleet daemon run --once >/dev/null 2>&1
  multi_first_exit=$(sql "SELECT json_extract(value,'$.exited_at') FROM event,json_each(event.payload,'$.processes') WHERE task_id=$T10 AND kind='task.background' AND json_extract(value,'$.pid')=$multi_first ORDER BY event.id DESC LIMIT 1" 2>/dev/null || true)
  multi_second_partial=$(sql "SELECT COALESCE(CAST(json_extract(value,'$.exited_at') AS TEXT),'null') FROM event,json_each(event.payload,'$.processes') WHERE task_id=$T10 AND kind='task.background' AND json_extract(value,'$.pid')=$multi_second ORDER BY event.id DESC LIMIT 1" 2>/dev/null || true)
  multi_active=$(sql "SELECT json_extract(payload,'$.active_pids') FROM event WHERE task_id=$T10 AND kind='task.background' ORDER BY id DESC LIMIT 1" 2>/dev/null || true)
  [ -n "$multi_first_exit" ] && [ "$multi_second_partial" = null ] \
    && [ "$multi_active" = "[$multi_second]" ] && break
  sleep 0.05
done
multi_status_partial=$(field "$T10" status)
multi_holder_partial=$(sql "SELECT holder FROM lease WHERE resource='detached-multi-resource'")
kill "$multi_second" 2>/dev/null || true
for _ in $(seq 1 100); do
  fleet daemon run --once >/dev/null 2>&1
  case "$(field "$T10" status)" in done|failed|cancelled) break ;; esac
  sleep 0.05
done
multi_first_final=$(sql "SELECT json_extract(value,'$.exited_at') FROM event,json_each(event.payload,'$.processes') WHERE task_id=$T10 AND kind='task.background' AND json_extract(value,'$.pid')=$multi_first ORDER BY event.id DESC LIMIT 1")
multi_second_final=$(sql "SELECT json_extract(value,'$.exited_at') FROM event,json_each(event.payload,'$.processes') WHERE task_id=$T10 AND kind='task.background' AND json_extract(value,'$.pid')=$multi_second ORDER BY event.id DESC LIMIT 1")
multi_final_at=$(sql "SELECT json_extract(payload,'$.exited_at') FROM event WHERE task_id=$T10 AND kind='task.background' ORDER BY id DESC LIMIT 1")
multi_events=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T10 AND kind='task.background'")
multi_holder_final=$(sql "SELECT COUNT(*) FROM lease WHERE resource='detached-multi-resource'")
if printf '%s\n' "$multi_initial_cmds" | grep -q 'fleet-bg-first' \
   && printf '%s\n' "$multi_initial_cmds" | grep -q 'fleet-bg-second' \
   && [ -n "$multi_first_exit" ] \
   && [ "$multi_second_partial" = null ] \
   && [ "$multi_active" = "[$multi_second]" ] \
   && [ "$multi_status_partial" = running ] \
   && [ "$multi_holder_partial" = "$T10" ] \
   && [ "$(field "$T10" status)" = done ] \
   && [ "$(field "$T10" exit_code)" = 0 ] \
   && [ "$multi_first_final" = "$multi_first_exit" ] \
   && [ -n "$multi_second_final" ] \
   && [ "$multi_second_final" = "$multi_final_at" ] \
   && [ "$multi_events" -ge 3 ] \
   && [ "$multi_holder_final" = 0 ]; then
  ok "multi-process snapshots retain each cmdline and first exit observation until final settlement"
else
  no "multi-process snapshots (pids=$multi_first/$multi_second cmds='$multi_initial_cmds' partial=$multi_first_exit/$multi_second_partial active=$multi_active status=$multi_status_partial holder=$multi_holder_partial final=$multi_first_final/$multi_second_final/$multi_final_at events=$multi_events end=$(field "$T10" status)/$(field "$T10" exit_code)/$multi_holder_final)"
fi

# Every supported credential spelling goes through the same metadata redactor.
# Exercise both rendered strings and argv-aware split values (including a value
# that itself contains whitespace, which a flat command-line regex cannot see).
redaction_result=$(PYTHONDONTWRITEBYTECODE=1 ROOT="$ROOT" python3 -B - <<'PY'
import importlib.machinery, importlib.util
import os
path = os.path.join(os.environ["ROOT"], "bin", "fleet")
loader = importlib.machinery.SourceFileLoader("fleet_detached_redaction", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
fleet = importlib.util.module_from_spec(spec)
loader.exec_module(fleet)
secrets = [
    "BearerSecret1683", "JwtSplit1683", "JwtEquals1683",
    "TokenSplit1683", "TokenEquals1683", "ApiSplit1683",
    "ApiEquals1683", "PassSplit1683", "PassEquals1683",
    "QueryToken1683", "QueryKey1683", "QuerySecret1683",
    "QueryPassword1683", "PrefixSecret1683",
]
rendered = (
    "Bearer BearerSecret1683 "
    "--jwt JwtSplit1683 --jwt=JwtEquals1683 "
    "--token TokenSplit1683 --token=TokenEquals1683 "
    "--api-key ApiSplit1683 --api-key=ApiEquals1683 "
    "--password PassSplit1683 --password=PassEquals1683 "
    "https://x.test/?token=QueryToken1683&key=QueryKey1683"
    "&secret=QuerySecret1683&password=QueryPassword1683 "
    "sk-PrefixSecret1683"
)
clean = fleet.redact_metadata_text(rendered, limit=None)
argv_clean = fleet._redact_cmdline_args([
    "cmd", "--password", "PassSplit1683 with whitespace",
    "Bearer", "BearerSecret1683", "--token=TokenEquals1683",
])
assert clean.count(fleet.REDACTED) >= 10, clean
assert fleet.REDACTED in argv_clean, argv_clean
assert "with whitespace" not in argv_clean, argv_clean
assert all(secret not in clean and secret not in argv_clean for secret in secrets)
assert fleet.redact_metadata_text("bearer of bad news", limit=None) == "bearer of bad news"
print("ok")
PY
)
if [ "$redaction_result" = ok ]; then
  ok "credential redactor covers Bearer, split/equals flags, query values, and key prefixes"
else
  no "credential redaction matrix ($redaction_result)"
fi

# Model sustained one-process churn without launching hundreds of children.
# The real merge/persistence helpers must retain the newest identity, cap every
# full snapshot, and roll exactly one marked tail row after the event limit.
T11=$(fleet add "bounded background churn fixture" --channel fake-detached \
  --no-preamble --spec "$FLEET_HOME/waiter.sh")
sql "UPDATE task SET attempt_id='bounded-background-attempt' WHERE id=$T11"
bounds_result=$(PYTHONDONTWRITEBYTECODE=1 ROOT="$ROOT" T11="$T11" \
  python3 -B - <<'PY'
import importlib.machinery, importlib.util
import json, os
path = os.path.join(os.environ["ROOT"], "bin", "fleet")
loader = importlib.machinery.SourceFileLoader("fleet_detached_bounds", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
fleet = importlib.util.module_from_spec(spec)
loader.exec_module(fleet)
conn = fleet.db_connect()
task = conn.execute("SELECT * FROM task WHERE id=?", (int(os.environ["T11"]),)).fetchone()
background = {
    "attempt_id": task["attempt_id"], "pids": [], "active_pids": [],
    "processes": [], "adapter_exit_code": 0, "reason": "churn fixture",
    "detected_at": 1, "exited_at": None,
}
iterations = fleet.BACKGROUND_SNAPSHOT_LIMIT * 4
base_pid = 700000
for index in range(iterations):
    live = [{
        "pid": base_pid + index, "starttime": 900000 + index,
        "cmdline": f"worker-{index}", "cmdline_truncated": False,
    }]
    background, changed = fleet._background_snapshot(
        background, live, 1000 + index
    )
    assert changed
    background = fleet._persist_task_background_snapshot(
        conn, task, background
    )
conn.commit()
rows = conn.execute(
    "SELECT payload FROM event WHERE task_id=? AND kind='task.background' "
    "ORDER BY id", (task["id"],)
).fetchall()
payloads = [json.loads(fleet.spill_load(row["payload"])) for row in rows]
latest = payloads[-1]
latest_pid = base_pid + iterations - 1
assert len(rows) == fleet.BACKGROUND_SNAPSHOT_LIMIT, len(rows)
assert all(len(item.get("processes") or []) <= fleet.BACKGROUND_PROCESS_LIMIT
           for item in payloads)
assert len(latest["processes"]) == fleet.BACKGROUND_PROCESS_LIMIT
assert latest_pid in latest["active_pids"]
assert any(item["pid"] == latest_pid for item in latest["processes"])
assert not any(item["pid"] == base_pid for item in latest["processes"])
assert latest["processes_truncated"] is True
assert latest["process_limit"] == fleet.BACKGROUND_PROCESS_LIMIT
assert latest["processes_omitted"] > 0
assert latest["snapshots_truncated"] is True
assert latest["snapshot_limit"] == fleet.BACKGROUND_SNAPSHOT_LIMIT
assert latest["snapshots_coalesced"] == iterations - fleet.BACKGROUND_SNAPSHOT_LIMIT
projection = fleet._background_projection(task, latest)
assert set(projection["background_truncation"]) == {"processes", "snapshots"}
assert "truncated=" in fleet._background_text(latest, task, brief=True)
print("ok")
PY
)
bounds_show=$(fleet show "$T11")
bounds_show_json=$(fleet --json show "$T11")
if [ "$bounds_result" = ok ] \
   && printf '%s\n' "$bounds_show" | grep -q '^background_truncation:.*"processes".*"snapshots"' \
   && BOUNDS_SHOW_JSON="$bounds_show_json" python3 -c 'import json,os; marker=json.loads(os.environ["BOUNDS_SHOW_JSON"])["background_truncation"]; assert set(marker)=={"processes","snapshots"}'; then
  ok "high churn caps per-attempt snapshots/processes and keeps a marked latest state"
else
  no "bounded high-churn snapshots ($bounds_result show='$bounds_show')"
fi
fleet cancel "$T11" >/dev/null 2>&1 || true

# A Fleet timeout is an explicit unsuccessful terminal condition. Even when the
# adapter itself returned zero, the still-live tail must be SIGKILLed and the
# existing failed/-2 result must win over background success settlement.
T12=$(fleet add "timed-out background child" --channel fake-detached \
  --lease detached-timeout-resource --timeout 1 --no-preamble \
  --spec "$FLEET_HOME/timeout.sh")
fleet run "$T12" >/dev/null
timeout_child=""
for _ in $(seq 1 100); do
  timeout_child=$(cat "$FLEET_HOME/timeout.pid" 2>/dev/null || true)
  timeout_bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T12 AND kind='task.background'" 2>/dev/null || echo 0)
  [ -n "$timeout_child" ] && [ "${timeout_bg:-0}" -ge 1 ] && break
  sleep 0.05
done
timeout_adapter=$(sql "SELECT json_extract(payload,'$.adapter_exit_code') FROM event WHERE task_id=$T12 AND kind='task.background' ORDER BY id DESC LIMIT 1")
sql "UPDATE task SET started_at=strftime('%s','now')-5 WHERE id=$T12"
fleet daemon run --once >/dev/null 2>&1
timeout_gone=""
for _ in $(seq 1 100); do
  timeout_state=$(awk '{print $3}' "/proc/$timeout_child/stat" 2>/dev/null || true)
  if [ -z "$timeout_state" ] || [ "$timeout_state" = Z ] || [ "$timeout_state" = X ]; then
    timeout_gone=1
    break
  fi
  sleep 0.05
done
timeout_events=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T12 AND kind='task.timeout'")
timeout_attempt=$(sql "SELECT status||':'||exit_code FROM attempt WHERE task_id=$T12 ORDER BY generation DESC LIMIT 1")
timeout_lease=$(sql "SELECT COUNT(*) FROM lease WHERE resource='detached-timeout-resource'")
if [ -n "$timeout_child" ] && [ "${timeout_bg:-0}" -ge 1 ] \
   && [ "$timeout_adapter" = 0 ] \
   && [ "$(field "$T12" status)" = failed ] \
   && [ "$(field "$T12" exit_code)" = -2 ] \
   && [ "$timeout_attempt" = "failed:-2" ] \
   && [ "$timeout_events" = 1 ] && [ "$timeout_lease" = 0 ] \
   && [ -n "$timeout_gone" ]; then
  ok "timeout-killed tail keeps the existing failed/-2 result despite adapter exit zero"
else
  no "background timeout (child=$timeout_child bg=$timeout_bg adapter=$timeout_adapter task=$(field "$T12" status)/$(field "$T12" exit_code) attempt=$timeout_attempt events=$timeout_events lease=$timeout_lease state=$timeout_state)"
fi

# A nonzero adapter remains unsuccessful after its tail exits by itself. The
# background marker retains the original rc for diagnosis, while the historical
# terminal code remains BACKGROUND_EXIT (-3).
T13=$(fleet add "nonzero adapter leaves background child" --channel fake-detached \
  --lease detached-nonzero-resource --no-preamble \
  --spec "$FLEET_HOME/nonzero.sh")
fleet run "$T13" >/dev/null
nonzero_child=""
for _ in $(seq 1 100); do
  nonzero_child=$(cat "$FLEET_HOME/nonzero.pid" 2>/dev/null || true)
  nonzero_bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T13 AND kind='task.background'" 2>/dev/null || echo 0)
  [ -n "$nonzero_child" ] && [ "${nonzero_bg:-0}" -ge 1 ] && break
  sleep 0.05
done
nonzero_adapter=$(sql "SELECT json_extract(payload,'$.adapter_exit_code') FROM event WHERE task_id=$T13 AND kind='task.background' ORDER BY id DESC LIMIT 1")
printf 'done\n' > "$FLEET_HOME/nonzero.release"
for _ in $(seq 1 100); do
  fleet daemon run --once >/dev/null 2>&1
  [ "$(field "$T13" status)" = failed ] && break
  sleep 0.05
done
nonzero_finish=$(sql "SELECT payload FROM event WHERE task_id=$T13 AND kind='task.finish' ORDER BY id DESC LIMIT 1")
nonzero_attempt=$(sql "SELECT status||':'||exit_code FROM attempt WHERE task_id=$T13 ORDER BY generation DESC LIMIT 1")
nonzero_timeout=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T13 AND kind='task.timeout'")
nonzero_lease=$(sql "SELECT COUNT(*) FROM lease WHERE resource='detached-nonzero-resource'")
if [ -n "$nonzero_child" ] && [ "${nonzero_bg:-0}" -ge 1 ] \
   && [ "$nonzero_adapter" = 7 ] \
   && [ "$(field "$T13" status)" = failed ] \
   && [ "$(field "$T13" exit_code)" = -3 ] \
   && [ "$nonzero_attempt" = "failed:-3" ] \
   && [ "$nonzero_timeout" = 0 ] && [ "$nonzero_lease" = 0 ] \
   && printf '%s\n' "$nonzero_finish" | grep -Eq '"adapter_exit_code":[[:space:]]*7' \
   && printf '%s\n' "$nonzero_finish" | grep -q 'background processes outlived adapter'; then
  ok "nonzero adapter plus self-exiting tail keeps the existing failed/-3 result"
else
  no "nonzero background settlement (child=$nonzero_child bg=$nonzero_bg adapter=$nonzero_adapter task=$(field "$T13" status)/$(field "$T13" exit_code) attempt=$nonzero_attempt timeout=$nonzero_timeout lease=$nonzero_lease finish=$nonzero_finish)"
fi

# A successful commander adapter is not finished merely by writing done: its
# proposal must traverse the same validation/apply path as a no-tail callback.
# Make attempt 1 invalid and attempt 2 valid so the regression also proves the
# background marker remains attempt-scoped and only one logical round is used.
mkdir -p "$FLEET_HOME/commander-cwd"
export FLEET_COMMANDER_SHELL_SCRIPT="$FLEET_HOME/commander-tail.sh"
saved_cwd=$PWD
cd "$FLEET_HOME/commander-cwd" || exit 1
G14=$(fleet goal add "background commander applies after retry")
fleet autonomy enable "$G14" --channel fake-detached --max-rounds 3 \
  --cooldown 0 >/dev/null
fleet daemon run --once >/dev/null
cd "$saved_cwd" || exit 1
C14=$(sql "SELECT id FROM task WHERE goal_id=$G14 AND role='commander'")
commander_first_child=""
for _ in $(seq 1 100); do
  commander_first_child=$(sed -n '1p' "$FLEET_HOME/commander-tail.pids" 2>/dev/null || true)
  commander_first_bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$C14 AND kind='task.background'" 2>/dev/null || echo 0)
  [ -n "$commander_first_child" ] && [ "${commander_first_bg:-0}" -ge 1 ] && break
  sleep 0.05
done
commander_first_attempt=$(sql "SELECT attempt_id FROM task WHERE id=$C14")
commander_before=$(sql "SELECT status||':'||attempt FROM task WHERE id=$C14")
commander_before_rounds=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$C14 AND kind='commander.round'")
commander_before_workers=$(sql "SELECT COUNT(*) FROM task WHERE parent_id=$C14")
printf 'done\n' > "$FLEET_HOME/commander-tail-1.release"
commander_second_child=""
for _ in $(seq 1 100); do
  fleet daemon run --once >/dev/null 2>&1
  commander_second_child=$(sed -n '2p' "$FLEET_HOME/commander-tail.pids" 2>/dev/null || true)
  commander_second_bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$C14 AND kind='task.background' AND json_extract(payload,'$.attempt_id')=(SELECT attempt_id FROM task WHERE id=$C14)" 2>/dev/null || echo 0)
  [ -n "$commander_second_child" ] && [ "${commander_second_bg:-0}" -ge 1 ] && break
  sleep 0.05
done
commander_second_attempt=$(sql "SELECT attempt_id FROM task WHERE id=$C14")
commander_retry_state=$(sql "SELECT status||':'||attempt FROM task WHERE id=$C14")
commander_attempt_one=$(sql "SELECT status||':'||exit_code FROM attempt WHERE task_id=$C14 AND generation=1")
commander_mid_rounds=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$C14 AND kind='commander.round'")
commander_mid_workers=$(sql "SELECT COUNT(*) FROM task WHERE parent_id=$C14")
printf 'done\n' > "$FLEET_HOME/commander-tail-2.release"
for _ in $(seq 1 100); do
  fleet daemon run --once >/dev/null 2>&1
  [ "$(field "$C14" status)" = done ] && break
  sleep 0.05
done
unset FLEET_COMMANDER_SHELL_SCRIPT
commander_attempts=$(sql "SELECT group_concat(status||':'||exit_code,'|') FROM (SELECT status,exit_code FROM attempt WHERE task_id=$C14 ORDER BY generation)")
commander_rounds=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$C14 AND kind='commander.round'")
commander_workers=$(sql "SELECT COUNT(*) FROM task WHERE parent_id=$C14 AND role='worker'")
commander_created=$(sql "SELECT json_array_length(json_extract(payload,'$.created')) FROM event WHERE task_id=$C14 AND kind='commander.round'")
commander_state=$(sql "SELECT json_extract(autonomy,'$.rounds_used')||':'||json_extract(autonomy,'$.consecutive_failures')||':'||json_extract(autonomy,'$.last_round_task')||':'||json_extract(autonomy,'$.last_reason')||':'||(json_extract(autonomy,'$.last_finished_at') IS NOT NULL) FROM goal WHERE id=$G14")
commander_lease=$(sql "SELECT COUNT(*) FROM lease WHERE resource='commander:goal-$G14'")
commander_finish=$(sql "SELECT payload FROM event WHERE task_id=$C14 AND kind='task.finish' ORDER BY id DESC LIMIT 1")
if [ -n "$commander_first_child" ] && [ -n "$commander_second_child" ] \
   && [ "$commander_before" = "running:1" ] \
   && [ "$commander_before_rounds:$commander_before_workers" = "0:0" ] \
   && [ "$commander_retry_state" = "running:2" ] \
   && [ "$commander_attempt_one" = "failed:65" ] \
   && [ "$commander_mid_rounds:$commander_mid_workers" = "0:0" ] \
   && [ "$commander_first_attempt" != "$commander_second_attempt" ] \
   && [ "$(field "$C14" status):$(field "$C14" exit_code)" = "done:0" ] \
   && [ "$commander_attempts" = "failed:65|done:0" ] \
   && [ "$commander_rounds:$commander_workers:$commander_created" = "1:1:1" ] \
   && [[ "$commander_state" == "1:0:$C14:waiting_for_tasks"*":1" ]] \
   && [ "$commander_lease" = 0 ] \
   && printf '%s\n' "$commander_finish" | grep -q 'background processes exited after successful adapter'; then
  ok "successful commander tails retry by attempt, then apply one proposal and one round"
else
  no "background commander settlement (children=$commander_first_child/$commander_second_child before=$commander_before/$commander_before_rounds/$commander_before_workers retry=$commander_retry_state/$commander_attempt_one/$commander_mid_rounds/$commander_mid_workers ids=$commander_first_attempt/$commander_second_attempt final=$(field "$C14" status)/$(field "$C14" exit_code) attempts=$commander_attempts round=$commander_rounds/$commander_workers/$commander_created autonomy=$commander_state lease=$commander_lease finish=$commander_finish)"
fi

# C3 must run after a successful review adapter's tail exits. The review has
# no claims and no output: it fails visibly and its ordinary --dep child must
# remain queued rather than treating the empty review as approval.
T15=$(fleet add "background review target" --channel fake-detached \
  --no-preamble --spec "$FLEET_HOME/review-target.sh")
fleet run "$T15" >/dev/null
wait_field "$T15" status done || true
R15=$(fleet add "empty review with background tail" --channel fake-detached \
  --review-of "$T15" --lease detached-review-resource --no-preamble \
  --spec "$FLEET_HOME/review-tail.sh")
D15=$(fleet add "must not pass empty review" --channel fake-detached \
  --dep "$R15" --no-preamble --spec "$FLEET_HOME/review-dependent.sh")
fleet run "$R15" >/dev/null
review_child=""
for _ in $(seq 1 100); do
  review_child=$(cat "$FLEET_HOME/review-tail.pid" 2>/dev/null || true)
  review_bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$R15 AND kind='task.background'" 2>/dev/null || echo 0)
  [ -n "$review_child" ] && [ "${review_bg:-0}" -ge 1 ] && break
  sleep 0.05
done
review_live=$(sql "SELECT status FROM task WHERE id=$R15")
review_dep_live=$(sql "SELECT status FROM task WHERE id=$D15")
printf 'done\n' > "$FLEET_HOME/review-tail.release"
for _ in $(seq 1 100); do
  fleet daemon run --once >/dev/null 2>&1
  case "$(field "$R15" status)" in done|failed|cancelled) break ;; esac
  sleep 0.05
done
fleet daemon run --once >/dev/null 2>&1
review_attempt=$(sql "SELECT status||':'||exit_code FROM attempt WHERE task_id=$R15 ORDER BY generation DESC LIMIT 1")
review_events=$(sql "SELECT (SELECT COUNT(*) FROM event WHERE task_id=$R15 AND kind='task.review_empty')||':'||(SELECT COUNT(*) FROM event WHERE task_id=$R15 AND kind='task.empty')||':'||(SELECT COUNT(*) FROM event WHERE task_id=$R15 AND kind='task.finish')")
review_claims=$(sql "SELECT COUNT(*) FROM claim WHERE task_id=$R15")
review_decisions=$(sql "SELECT COUNT(*) FROM decision WHERE task_id=$R15 AND needs_user=1")
review_dep=$(sql "SELECT status FROM task WHERE id=$D15")
review_lease=$(sql "SELECT COUNT(*) FROM lease WHERE resource='detached-review-resource'")
review_finish=$(sql "SELECT payload FROM event WHERE task_id=$R15 AND kind='task.finish' ORDER BY id DESC LIMIT 1")
if [ -n "$review_child" ] && [ "$review_live:$review_dep_live" = "running:queued" ] \
   && [ "$(field "$R15" status):$(field "$R15" exit_code)" = "failed:0" ] \
   && [ "$review_attempt" = "failed:0" ] \
   && [ "$review_events:$review_claims:$review_decisions" = "1:1:1:0:1" ] \
   && [ "$review_dep" = queued ] \
   && [ ! -e "$FLEET_HOME/review-dependent.started" ] \
   && [ "$review_lease" = 0 ] \
   && printf '%s\n' "$review_finish" | grep -q 'background processes exited after successful adapter'; then
  ok "zero-claim review tail fails C3 and cannot admit its dependent"
else
  no "background empty review (child=$review_child live=$review_live/$review_dep_live final=$(field "$R15" status)/$(field "$R15" exit_code) attempt=$review_attempt events=$review_events claims=$review_claims decisions=$review_decisions dep=$review_dep/$(test -e "$FLEET_HOME/review-dependent.started" && echo started || echo idle) lease=$review_lease finish=$review_finish)"
fi

# Review probe P5: a directory at out_path raises OSError. Settlement through
# the real daemon must finish every ledger row rather than commit only the task
# terminal write and task.finish event from the middle of the transaction.
G16=$(fleet goal add "unreadable worker output settles atomically")
T16=$(fleet add "synthetic unreadable worker tail" --channel fake-detached \
  --goal "$G16" --lease unreadable-worker-resource --no-preamble \
  --spec "$FLEET_HOME/review-target.sh")
run16="$FLEET_HOME/unreadable-worker-run"
mkdir -p "$run16/out.md"
attempt16="unreadable-worker-attempt"
sql "UPDATE task SET status='running',attempt=1,attempt_id='$attempt16',max_attempts=1,started_at=strftime('%s','now')-120,pid=NULL,pid_starttime=NULL,run_dir='$run16',out_path='$run16/out.md',log_path='$run16/log.txt' WHERE id=$T16;
INSERT INTO attempt(attempt_id,task_id,generation,status,pid,pid_starttime,run_dir,out_path,log_path,started_at) VALUES('$attempt16',$T16,1,'running',NULL,NULL,'$run16','$run16/out.md','$run16/log.txt',strftime('%s','now')-120);
INSERT INTO lease(resource,holder,acquired_at) VALUES('unreadable-worker-resource','$T16',strftime('%s','now')-120);
INSERT INTO event(ts,task_id,kind,payload) VALUES(strftime('%s','now'),$T16,'task.background',json_object('attempt_id','$attempt16','pids',json_array(),'active_pids',json_array(),'processes',json_array(),'adapter_exit_code',0,'exited_at',strftime('%s','now')-60));"
poll_errors_before16=$(sql "SELECT COUNT(*) FROM event WHERE kind='daemon.poll_error'")
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
unreadable_worker_attempt=$(sql "SELECT status||':'||COALESCE(exit_code,'NULL') FROM attempt WHERE task_id=$T16")
unreadable_worker_events=$(sql "SELECT (SELECT COUNT(*) FROM event WHERE task_id=$T16 AND kind='task.empty' AND json_extract(payload,'$.unreadable')=1 AND json_extract(payload,'$.error')='IsADirectoryError')||':'||(SELECT COUNT(*) FROM event WHERE task_id=$T16 AND kind='task.finish')")
poll_errors_after16=$(sql "SELECT COUNT(*) FROM event WHERE kind='daemon.poll_error'")
unreadable_worker_poll_errors=$((poll_errors_after16 - poll_errors_before16))
unreadable_worker_lease=$(sql "SELECT COUNT(*) FROM lease WHERE resource='unreadable-worker-resource'")
if [ "$(field "$T16" status):$(field "$T16" exit_code)" = "done:0" ] \
   && [ "$unreadable_worker_attempt" = "done:0" ] \
   && [ "$unreadable_worker_events" = "1:1" ] \
   && [ "$unreadable_worker_poll_errors:$unreadable_worker_lease" = "0:0" ]; then
  ok "unreadable worker output is diagnosed and settles task, attempt, and lease atomically"
else
  no "unreadable worker settlement (task=$(field "$T16" status)/$(field "$T16" exit_code) attempt=$unreadable_worker_attempt events=$unreadable_worker_events poll_errors=$unreadable_worker_poll_errors lease=$unreadable_worker_lease)"
fi
if [ "$(field "$T16" status)" = running ]; then
  rmdir "$run16/out.md" 2>/dev/null || true
  touch "$run16/out.md"
  fleet daemon run --once >/dev/null 2>&1
fi

# Review probe P6: the same OSError on a zero-claim review is empty output for
# diagnostics and still traverses C3. The failed review must retain its
# decision and keep its dependent queued while releasing its own lease.
T17=$(fleet add "unreadable review target" --channel fake-detached \
  --no-preamble --spec "$FLEET_HOME/review-target.sh")
fleet run "$T17" >/dev/null
wait_field "$T17" status done || true
R17=$(fleet add "synthetic unreadable empty review" --channel fake-detached \
  --review-of "$T17" --lease unreadable-review-resource --no-preamble \
  --spec "$FLEET_HOME/review-target.sh")
D17=$(fleet add "must not pass unreadable empty review" --channel fake-detached \
  --dep "$R17" --no-preamble --spec "$FLEET_HOME/review-dependent.sh")
run17="$FLEET_HOME/unreadable-review-run"
mkdir -p "$run17/out.md"
attempt17="unreadable-review-attempt"
sql "UPDATE task SET status='running',attempt=1,attempt_id='$attempt17',max_attempts=1,started_at=strftime('%s','now')-120,pid=NULL,pid_starttime=NULL,run_dir='$run17',out_path='$run17/out.md',log_path='$run17/log.txt' WHERE id=$R17;
INSERT INTO attempt(attempt_id,task_id,generation,status,pid,pid_starttime,run_dir,out_path,log_path,started_at) VALUES('$attempt17',$R17,1,'running',NULL,NULL,'$run17','$run17/out.md','$run17/log.txt',strftime('%s','now')-120);
INSERT INTO lease(resource,holder,acquired_at) VALUES('unreadable-review-resource','$R17',strftime('%s','now')-120);
INSERT INTO event(ts,task_id,kind,payload) VALUES(strftime('%s','now'),$R17,'task.background',json_object('attempt_id','$attempt17','pids',json_array(),'active_pids',json_array(),'processes',json_array(),'adapter_exit_code',0,'exited_at',strftime('%s','now')-60));"
poll_errors_before17=$(sql "SELECT COUNT(*) FROM event WHERE kind='daemon.poll_error'")
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
unreadable_review_attempt=$(sql "SELECT status||':'||COALESCE(exit_code,'NULL') FROM attempt WHERE task_id=$R17")
unreadable_review_events=$(sql "SELECT (SELECT COUNT(*) FROM event WHERE task_id=$R17 AND kind='task.review_empty')||':'||(SELECT COUNT(*) FROM event WHERE task_id=$R17 AND kind='task.empty' AND json_extract(payload,'$.unreadable')=1)||':'||(SELECT COUNT(*) FROM event WHERE task_id=$R17 AND kind='task.finish')")
unreadable_review_decisions=$(sql "SELECT COUNT(*) FROM decision WHERE task_id=$R17 AND needs_user=1")
unreadable_review_lease=$(sql "SELECT COUNT(*) FROM lease WHERE resource='unreadable-review-resource'")
unreadable_review_dep=$(sql "SELECT status FROM task WHERE id=$D17")
poll_errors_after17=$(sql "SELECT COUNT(*) FROM event WHERE kind='daemon.poll_error'")
unreadable_review_poll_errors=$((poll_errors_after17 - poll_errors_before17))
if [ "$(field "$R17" status):$(field "$R17" exit_code)" = "failed:0" ] \
   && [ "$unreadable_review_attempt" = "failed:0" ] \
   && [ "$unreadable_review_events:$unreadable_review_decisions" = "1:1:1:1" ] \
   && [ "$unreadable_review_lease:$unreadable_review_dep" = "0:queued" ] \
   && [ ! -e "$FLEET_HOME/review-dependent.started" ] \
   && [ "$unreadable_review_poll_errors" = 0 ]; then
  ok "unreadable zero-claim review output follows C3 and preserves its decision"
else
  no "unreadable review settlement (task=$(field "$R17" status)/$(field "$R17" exit_code) attempt=$unreadable_review_attempt events=$unreadable_review_events decisions=$unreadable_review_decisions lease=$unreadable_review_lease dep=$unreadable_review_dep/$(test -e "$FLEET_HOME/review-dependent.started" && echo started || echo idle) poll_errors=$unreadable_review_poll_errors)"
fi
if [ "$(field "$R17" status)" = running ]; then
  rmdir "$run17/out.md" 2>/dev/null || true
  touch "$run17/out.md"
  fleet daemon run --once >/dev/null 2>&1
fi

# Review probe P7: reproduce the failure through the complete wrapper path.
# The adapter itself replaces out.md with a directory and leaves a self-exiting
# tail. Once that tail exits, an independent peer must acquire the same lease.
G18=$(fleet goal add "natural unreadable output tail releases its lease")
T18=$(fleet add "adapter replaces output with a directory" \
  --channel fake-detached --goal "$G18" --lease unreadable-tail-resource \
  --no-preamble --spec "$FLEET_HOME/unreadable-tail.sh")
P18=$(fleet add "peer after unreadable output tail" --channel fake-detached \
  --goal "$G18" --lease unreadable-tail-resource --no-preamble \
  --spec "$FLEET_HOME/unreadable-peer.sh")
fleet run "$T18" >/dev/null
unreadable_child=""
for _ in $(seq 1 100); do
  unreadable_child=$(cat "$FLEET_HOME/unreadable-tail.pid" 2>/dev/null || true)
  unreadable_bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T18 AND kind='task.background'" 2>/dev/null || echo 0)
  [ -n "$unreadable_child" ] && [ "${unreadable_bg:-0}" -ge 1 ] && break
  sleep 0.05
done
unreadable_live=$(field "$T18" status)
unreadable_out=$(sql "SELECT out_path FROM task WHERE id=$T18")
poll_errors_before18=$(sql "SELECT COUNT(*) FROM event WHERE kind='daemon.poll_error'")
printf 'done\n' > "$FLEET_HOME/unreadable-tail.release"
for _ in $(seq 1 20); do
  fleet daemon run --once >/dev/null 2>&1
  [ "$(field "$T18" status)" = done ] \
    && [ -e "$FLEET_HOME/unreadable-peer.started" ] && break
  sleep 0.03
done
fleet run "$P18" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  fleet daemon run --once >/dev/null 2>&1
  [ "$(field "$P18" status)" = done ] && break
  sleep 0.03
done
unreadable_tail_attempt=$(sql "SELECT status||':'||COALESCE(exit_code,'NULL') FROM attempt WHERE task_id=$T18 ORDER BY generation DESC LIMIT 1")
unreadable_tail_empty=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T18 AND kind='task.empty' AND json_extract(payload,'$.unreadable')=1 AND json_extract(payload,'$.error')='IsADirectoryError'")
unreadable_tail_lease=$(sql "SELECT COUNT(*) FROM lease WHERE resource='unreadable-tail-resource'")
poll_errors_after18=$(sql "SELECT COUNT(*) FROM event WHERE kind='daemon.poll_error'")
unreadable_tail_poll_errors=$((poll_errors_after18 - poll_errors_before18))
if [ -n "$unreadable_child" ] && [ "$unreadable_live" = running ] \
   && [ -d "$unreadable_out" ] \
   && [ "$(field "$T18" status):$(field "$T18" exit_code)" = "done:0" ] \
   && [ "$unreadable_tail_attempt" = "done:0" ] \
   && [ "$unreadable_tail_empty:$unreadable_tail_lease" = "1:0" ] \
   && [ "$(field "$P18" status)" = done ] \
   && [ -e "$FLEET_HOME/unreadable-peer.started" ] \
   && [ "$unreadable_tail_poll_errors" = 0 ]; then
  ok "natural unreadable output tail settles completely and releases its peer lease"
else
  no "natural unreadable tail (child=$unreadable_child live=$unreadable_live out_dir=$(test -d "$unreadable_out" && echo yes || echo no) task=$(field "$T18" status)/$(field "$T18" exit_code) attempt=$unreadable_tail_attempt empty=$unreadable_tail_empty lease=$unreadable_tail_lease peer=$(field "$P18" status)/$(test -e "$FLEET_HOME/unreadable-peer.started" && echo started || echo idle) poll_errors=$unreadable_tail_poll_errors)"
fi
if [ "$(field "$T18" status)" = running ]; then
  rmdir "$unreadable_out" 2>/dev/null || true
  touch "$unreadable_out"
  fleet daemon run --once >/dev/null 2>&1
fi

# Hold a real writer transaction open while invoking the shared helper, then
# replace Path with a sentinel that rejects any read performed under that
# transaction. This pins the ordering independently of the OSError outcome.
G19=$(fleet goal add "successful output read precedes writer transaction")
T19=$(fleet add "transaction ordering sentinel" --channel fake-detached \
  --goal "$G19" --no-preamble --spec "$FLEET_HOME/review-target.sh")
run19="$FLEET_HOME/transaction-order-run"
mkdir -p "$run19"
attempt19="transaction-order-attempt"
sql "UPDATE task SET status='running',attempt=1,attempt_id='$attempt19',max_attempts=1,started_at=strftime('%s','now')-120,pid=NULL,pid_starttime=NULL,run_dir='$run19',out_path='$run19/out.md',log_path='$run19/log.txt' WHERE id=$T19;
INSERT INTO attempt(attempt_id,task_id,generation,status,pid,pid_starttime,run_dir,out_path,log_path,started_at) VALUES('$attempt19',$T19,1,'running',NULL,NULL,'$run19','$run19/out.md','$run19/log.txt',strftime('%s','now')-120);"
transaction_probe=$(ROOT="$ROOT" TXN_TASK="$T19" python3 -B - <<'PY' 2>&1
import importlib.machinery, importlib.util
import os

path = os.path.join(os.environ["ROOT"], "bin", "fleet")
loader = importlib.machinery.SourceFileLoader(
    "fleet_detached_transaction_probe", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
fleet = importlib.util.module_from_spec(spec)
loader.exec_module(fleet)
conn = fleet.db_connect()

class TransactionSentinelPath:
    def __init__(self, _path):
        pass

    def read_text(self, **_kwargs):
        if conn.in_transaction:
            raise RuntimeError("out.md read while SQLite writer transaction is active")
        raise IsADirectoryError(21, "Is a directory")

    def exists(self):
        if conn.in_transaction:
            raise RuntimeError("out.md probed while SQLite writer transaction is active")
        return True

fleet.Path = TransactionSentinelPath
conn.execute("BEGIN IMMEDIATE")
task = conn.execute(
    "SELECT * FROM task WHERE id=?", (int(os.environ["TXN_TASK"]),)
).fetchone()
fleet._settle_successful_adapter(conn, task)
print("read-outside-transaction")
PY
)
transaction_probe_rc=$?
transaction_attempt=$(sql "SELECT status||':'||COALESCE(exit_code,'NULL') FROM attempt WHERE task_id=$T19")
transaction_empty=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T19 AND kind='task.empty' AND json_extract(payload,'$.unreadable')=1")
if [ "$transaction_probe_rc" = 0 ] \
   && [ "$transaction_probe" = "read-outside-transaction" ] \
   && [ "$(field "$T19" status):$(field "$T19" exit_code)" = "done:0" ] \
   && [ "$transaction_attempt:$transaction_empty" = "done:0:1" ]; then
  ok "successful output is read outside the SQLite writer transaction"
else
  no "successful output transaction order (rc=$transaction_probe_rc output=$transaction_probe task=$(field "$T19" status)/$(field "$T19" exit_code) attempt=$transaction_attempt empty=$transaction_empty)"
fi

# An unreadable commander output is not an empty successful round. It follows
# the existing invalid_output rejection path and must not apply the otherwise
# valid proposal that was written before the adapter replaced out.md.
export FLEET_COMMANDER_SHELL_SCRIPT="$FLEET_HOME/unreadable-commander.sh"
saved_cwd=$PWD
cd "$FLEET_HOME/commander-cwd" || exit 1
G20=$(fleet goal add "unreadable commander proposal is rejected")
fleet autonomy enable "$G20" --channel fake-detached --max-rounds 1 \
  --cooldown 0 >/dev/null
fleet daemon run --once >/dev/null
cd "$saved_cwd" || exit 1
C20=$(sql "SELECT id FROM task WHERE goal_id=$G20 AND role='commander'")
unreadable_commander_child=""
for _ in $(seq 1 100); do
  unreadable_commander_child=$(cat "$FLEET_HOME/unreadable-commander.pid" 2>/dev/null || true)
  unreadable_commander_bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$C20 AND kind='task.background'" 2>/dev/null || echo 0)
  [ -n "$unreadable_commander_child" ] \
    && [ "${unreadable_commander_bg:-0}" -ge 1 ] && break
  sleep 0.05
done
sql "UPDATE task SET max_attempts=1 WHERE id=$C20"
poll_errors_before20=$(sql "SELECT COUNT(*) FROM event WHERE kind='daemon.poll_error'")
printf 'done\n' > "$FLEET_HOME/unreadable-commander.release"
for _ in $(seq 1 50); do
  fleet daemon run --once >/dev/null 2>&1
  [ "$(field "$C20" status)" = failed ] && break
  sleep 0.03
done
unset FLEET_COMMANDER_SHELL_SCRIPT
unreadable_commander_attempt=$(sql "SELECT status||':'||exit_code FROM attempt WHERE task_id=$C20 ORDER BY generation DESC LIMIT 1")
unreadable_commander_rejected=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$C20 AND kind='commander.rejected' AND json_extract(payload,'$.reason')='invalid_output'")
unreadable_commander_rounds=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$C20 AND kind='commander.round'")
unreadable_commander_workers=$(sql "SELECT COUNT(*) FROM task WHERE parent_id=$C20")
unreadable_commander_lease=$(sql "SELECT COUNT(*) FROM lease WHERE resource='commander:goal-$G20'")
unreadable_commander_out=$(sql "SELECT out_path FROM task WHERE id=$C20")
poll_errors_after20=$(sql "SELECT COUNT(*) FROM event WHERE kind='daemon.poll_error'")
unreadable_commander_poll_errors=$((poll_errors_after20 - poll_errors_before20))
if [ -n "$unreadable_commander_child" ] \
   && [ -d "$unreadable_commander_out" ] \
   && [ "$(field "$C20" status):$(field "$C20" exit_code)" = "failed:65" ] \
   && [ "$unreadable_commander_attempt" = "failed:65" ] \
   && [ "$unreadable_commander_rejected:$unreadable_commander_rounds:$unreadable_commander_workers" = "1:0:0" ] \
   && [ "$unreadable_commander_lease" = 0 ] \
   && [ ! -e "$FLEET_HOME/unreadable-commander-worker.started" ] \
   && [ "$unreadable_commander_poll_errors" = 0 ]; then
  ok "unreadable commander output is rejected without applying its proposal"
else
  no "unreadable commander settlement (child=$unreadable_commander_child out_dir=$(test -d "$unreadable_commander_out" && echo yes || echo no) task=$(field "$C20" status)/$(field "$C20" exit_code) attempt=$unreadable_commander_attempt rejected=$unreadable_commander_rejected rounds=$unreadable_commander_rounds workers=$unreadable_commander_workers lease=$unreadable_commander_lease marker=$(test -e "$FLEET_HOME/unreadable-commander-worker.started" && echo yes || echo no) poll_errors=$unreadable_commander_poll_errors)"
fi
if [ "$(field "$C20" status)" = running ]; then
  rmdir "$unreadable_commander_out" 2>/dev/null || true
  touch "$unreadable_commander_out"
  fleet daemon run --once >/dev/null 2>&1
fi

# A result file written by the adapter is not proof that the adapter exited.
# An in-band `_finish` from inside the still-running adapter must be rejected,
# must not create a background marker for the wrapper/adapter itself, and wait
# must keep ordinary running semantics instead of returning the background 125.
cat > "$FLEET_HOME/adapter-alive-result.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'result before adapter exits\n'
fleet _finish "$FLEET_TASK_ID" 0 --attempt "$FLEET_ATTEMPT" \
  >/dev/null 2>"$FLEET_HOME/adapter-alive-finish.err" \
  || echo "$?" > "$FLEET_HOME/adapter-alive-finish.rc"
mkfifo "$FLEET_HOME/adapter-alive.release"
read -r _ < "$FLEET_HOME/adapter-alive.release"
SH
T21=$(fleet add "adapter writes result then keeps running" \
  --channel fake-detached --no-preamble \
  --spec "$FLEET_HOME/adapter-alive-result.sh")
fleet run "$T21" >/dev/null
adapter_alive_status=""
for _ in $(seq 1 100); do
  adapter_alive_status=$(fleet status --all)
  [ -s "$FLEET_HOME/runs/$T21/attempt-1/out.md" ] \
    && [ -s "$FLEET_HOME/adapter-alive-finish.rc" ] \
    && printf '%s\n' "$adapter_alive_status" \
      | grep -q "^$T21 .*running(result-written,adapter-alive)" && break
  sleep 0.05
done
adapter_alive_wait=$(fleet wait --any --ids "$T21" --timeout 1 2>&1)
adapter_alive_wait_rc=$?
adapter_alive_bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T21 AND kind='task.background'")
adapter_alive_stale=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T21 AND kind='attempt.stale' AND json_extract(payload,'$.reason')='caller_not_wrapper'")
adapter_alive_bad_finish_rc=$(cat "$FLEET_HOME/adapter-alive-finish.rc" 2>/dev/null || true)
printf 'done\n' > "$FLEET_HOME/adapter-alive.release"
wait_field "$T21" status done || true
adapter_alive_final_bg=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$T21 AND kind='task.background'")
if [ "$(field "$T21" status):$(field "$T21" exit_code)" = "done:0" ] \
   && [ "$adapter_alive_bad_finish_rc" = 16 ] \
   && [ "$adapter_alive_wait_rc" = 124 ] \
   && [ "$adapter_alive_bg:$adapter_alive_final_bg" = "0:0" ] \
   && [ "$adapter_alive_stale" = 1 ] \
   && printf '%s\n' "$adapter_alive_status" \
      | grep -q "^$T21 .*running(result-written,adapter-alive)" \
   && ! printf '%s\n' "$adapter_alive_wait" | grep -q 'adapter exited'; then
  ok "adapter-written result while adapter is alive stays running and wait does not report background"
else
  no "adapter-alive result (task=$(field "$T21" status)/$(field "$T21" exit_code) finish_rc=$adapter_alive_bad_finish_rc wait=$adapter_alive_wait_rc/'$adapter_alive_wait' bg=$adapter_alive_bg/$adapter_alive_final_bg stale=$adapter_alive_stale status='$adapter_alive_status')"
fi

# Reobserving the same attempt with the same process identity is not new
# information. Keep one durable task.background row until the live set changes.
T22=$(fleet add "background snapshot dedupe fixture" \
  --channel fake-detached --no-preamble --spec "$FLEET_HOME/waiter.sh")
sql "UPDATE task SET attempt_id='dedupe-background-attempt' WHERE id=$T22"
dedupe_result=$(PYTHONDONTWRITEBYTECODE=1 ROOT="$ROOT" T22="$T22" \
  python3 -B - <<'PY'
import importlib.machinery, importlib.util
import os
path = os.path.join(os.environ["ROOT"], "bin", "fleet")
loader = importlib.machinery.SourceFileLoader("fleet_detached_dedupe", path)
spec = importlib.util.spec_from_loader(loader.name, loader)
fleet = importlib.util.module_from_spec(spec)
loader.exec_module(fleet)
conn = fleet.db_connect()
task = conn.execute("SELECT * FROM task WHERE id=?",
                    (int(os.environ["T22"]),)).fetchone()
processes = [{
    "pid": 812345, "starttime": 9012345,
    "cmdline": "same-background-process",
    "cmdline_truncated": False,
}]
for _ in range(3):
    fleet._record_task_background(
        conn, task, processes, 0,
        "adapter exited with background processes still alive",
    )
conn.commit()
count = conn.execute(
    "SELECT COUNT(*) FROM event WHERE task_id=? AND kind='task.background'",
    (task["id"],),
).fetchone()[0]
print(count)
PY
)
if [ "$dedupe_result" = 1 ]; then
  ok "unchanged background process snapshot is recorded once per attempt"
else
  no "background snapshot dedupe (events=$dedupe_result)"
fi
fleet cancel "$T22" >/dev/null 2>&1 || true

echo "passed $PASS / $N"
[ "$FAIL" -eq 0 ]
