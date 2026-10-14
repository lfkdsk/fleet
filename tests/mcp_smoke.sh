#!/usr/bin/env bash
# fleet P2 smoke tests. Cases 1-14 and 16 drive bin/fleet-mcp over raw
# JSON-RPC (one freshly spawned server per call) and cost zero model quota.
# Case 15 runs a real channel only when FLEET_E2E_CHANNEL is explicitly set.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-mcp-test-XXXX)"
export PATH="$ROOT/bin:$PATH"
cleanup(){
  # A real agent may honor an installed stop hook by starting the daemon. It
  # serves only this temporary ledger; stop it before removing that ledger so
  # the smoke test never leaves a detached process behind.
  fleet daemon stop >/dev/null 2>&1 || true
  rm -rf "$FLEET_HOME"
}
trap cleanup EXIT

PASS=0
FAIL=0
N=0

ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }

field(){ fleet show "$1" | awk -v f="$2" '$1==f":"{print $2}'; }

wait_done(){
  local id="$1" i got
  for i in $(seq 1 1500); do
    got=$(field "$id" status)
    [ "$got" = "done" ] && return 0
    [ "$got" = "failed" ] && return 1
    sleep 0.2
  done
  return 1
}

# Raw JSON-RPC: one request in, one response line out. The server is
# stateless across connections (all state lives in the ledger), so a fresh
# process per call keeps id correlation trivial. `rpc` sends a protocol
# method (initialize/tools/list); `call` invokes a tool via tools/call.
rpc() {
  python3 -c 'import json,sys
print(json.dumps({"jsonrpc":"2.0","id":1,"method":sys.argv[1],"params":json.loads(sys.argv[2])}))' "$1" "$2" \
    | FLEET_HOME="$FLEET_HOME" FLEET_TASK_ID="$T" "$ROOT/bin/fleet-mcp" 2>>"$FLEET_HOME/mcp.err"
}
call() {
  python3 -c 'import json,sys
print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":sys.argv[1],"arguments":json.loads(sys.argv[2])}}))' "$1" "$2" \
    | FLEET_HOME="$FLEET_HOME" FLEET_TASK_ID="$T" FLEET_ATTEMPT="$T_ATTEMPT" \
      "$ROOT/bin/fleet-mcp" 2>>"$FLEET_HOME/mcp.err"
}
rpc_as() {
  local tid="$1"; shift
  python3 -c 'import json,sys
print(json.dumps({"jsonrpc":"2.0","id":1,"method":sys.argv[1],"params":json.loads(sys.argv[2])}))' "$1" "$2" \
    | FLEET_HOME="$FLEET_HOME" FLEET_TASK_ID="$tid" FLEET_ATTEMPT="$T_ATTEMPT" \
      "$ROOT/bin/fleet-mcp" 2>>"$FLEET_HOME/mcp.err"
}
call_as() {
  local tid="$1"; shift
  python3 -c 'import json,sys
print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":sys.argv[1],"arguments":json.loads(sys.argv[2])}}))' "$1" "$2" \
    | FLEET_HOME="$FLEET_HOME" FLEET_TASK_ID="$tid" "$ROOT/bin/fleet-mcp" 2>>"$FLEET_HOME/mcp.err"
}
call_attempt_as() {
  local tid="$1" attempt="$2"; shift 2
  python3 -c 'import json,sys
print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":sys.argv[1],"arguments":json.loads(sys.argv[2])}}))' "$1" "$2" \
    | FLEET_HOME="$FLEET_HOME" FLEET_TASK_ID="$tid" FLEET_ATTEMPT="$attempt" \
      "$ROOT/bin/fleet-mcp" 2>>"$FLEET_HOME/mcp.err"
}

# Pull a field out of a JSON-RPC response. jpath resp.result.content.0.text
# returns the tool payload as a JSON string; jpayload parses that payload.
jpath() {
  python3 -c '
import json,sys
d=json.loads(sys.argv[1])
for k in sys.argv[2].split("."):
    d = d[int(k)] if k.isdigit() else d[k]
print(d if isinstance(d,str) else json.dumps(d,ensure_ascii=False))' "$1" "$2"
}
jpayload() {
  python3 -c 'import json,sys
print(json.dumps(json.loads(json.loads(sys.argv[1])["result"]["content"][0]["text"]),ensure_ascii=False))' "$1"
}

fleet init >/dev/null

# Dep tasks are created before the main task so --dep rows exist at enqueue.
D1=$(fleet add "dep one" --channel shell --no-preamble)
fleet artifact add "$D1" --path /etc/hostname --summary "dep-one-summary-marker" >/dev/null
D2=$(fleet add "dep two" --channel shell --no-preamble)
python3 -c 'import sys; open(sys.argv[1],"w").write("x"*10000)' "$(field "$D2" out_path)"

T=$(fleet add "mcp main" --channel shell --no-preamble --dep "$D1" --dep "$D2")
# MCP writes are worker callbacks, so give this protocol fixture a live,
# authenticated attempt without launching a model or shell adapter.
T_ATTEMPT=mcp-smoke-attempt
sqlite3 "$FLEET_HOME/fleet.db" "UPDATE task SET status='running',attempt=1,attempt_id='$T_ATTEMPT' WHERE id=$T"

# 1. initialize handshake: protocolVersion echoed, serverInfo.name == fleet;
#    plus the protocol defaults and unknown-method error code.
R=$(rpc initialize '{"protocolVersion":"2025-06-18"}')
V=$(jpath "$R" result.protocolVersion)
NAME=$(jpath "$R" result.serverInfo.name)
RDEF=$(rpc initialize '{}')
VDEF=$(jpath "$RDEF" result.protocolVersion)
RUNK=$(rpc_as "$T" "no/such/method" '{}')
CODE=$(jpath "$RUNK" error.code)
if [ "$V" = "2025-06-18" ] && [ "$NAME" = "fleet" ] \
   && [ "$VDEF" = "2025-06-18" ] && [ "$CODE" = "-32601" ]; then
  ok "initialize: version echoed, default version, unknown method -32601"
else
  no "initialize: V=$V NAME=$NAME VDEF=$VDEF CODE=$CODE"
fi

# 2. tools/list: exactly the seven tools, each with description + inputSchema
R=$(rpc tools/list '{}')
CHECK=$(python3 -c '
import json,sys
tools=json.loads(sys.argv[1])["result"]["tools"]
names=[t["name"] for t in tools]
expect={"fleet_task_get","fleet_claim","fleet_artifact","fleet_send","fleet_inbox","fleet_spawn","fleet_note"}
assert set(names)==expect, names
assert all(t["description"].strip() for t in tools)
assert all(t["inputSchema"] for t in tools)
print("ok")' "$R")
if [ "$CHECK" = "ok" ]; then
  ok "tools/list: seven tools with descriptions and schemas"
else
  no "tools/list: $CHECK"
fi

# 3. fleet_claim writes a row pinned to FLEET_TASK_ID
before=$(fleet --json claim list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
R=$(call fleet_claim '{"claim":"claim-marker","evidence":"ev-marker file:1"}')
CERR=$(jpath "$R" result.isError 2>/dev/null || echo "")
after=$(fleet --json claim list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
ROW=$(fleet --json claim list --task "$T")
if [ "$after" = "$((before+1))" ] && [ -z "$CERR" ] \
   && printf '%s' "$ROW" | grep -q '"claim": "claim-marker"' \
   && printf '%s' "$ROW" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert all(x["task_id"]=='"$T"' for x in r)'; then
  ok "fleet_claim: row written with task_id=FLEET_TASK_ID"
else
  no "fleet_claim: before=$before after=$after CERR=$CERR"
fi

# 4. blank evidence: isError AND zero new claim rows
before=$(fleet --json claim list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
R=$(call fleet_claim '{"claim":"no-evidence","evidence":"   "}')
ISERR=$(jpath "$R" result.isError 2>/dev/null || echo "")
after=$(fleet --json claim list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
if [ "$ISERR" = "true" ] && [ "$after" = "$before" ]; then
  ok "fleet_claim: blank evidence isError, no row written"
else
  no "fleet_claim: blank evidence ISERR=$ISERR before=$before after=$after"
fi

# 5. FLEET_TASK_ID pointing at a missing task: every write tool errors
W1=$(call_as 99999 fleet_claim '{"claim":"x","evidence":"y"}')
W2=$(call_as 99999 fleet_artifact '{"path":"/etc/hostname"}')
W3=$(call_as 99999 fleet_send '{"to":"commander","body":"x"}')
W4=$(call_as 99999 fleet_inbox '{}')
W5=$(call_as 99999 fleet_spawn '{"title":"x","rationale":"y"}')
if [ "$(jpath "$W1" result.isError 2>/dev/null)" = "true" ] \
   && [ "$(jpath "$W2" result.isError 2>/dev/null)" = "true" ] \
   && [ "$(jpath "$W3" result.isError 2>/dev/null)" = "true" ] \
   && [ "$(jpath "$W4" result.isError 2>/dev/null)" = "true" ] \
   && [ "$(jpath "$W5" result.isError 2>/dev/null)" = "true" ]; then
  ok "missing task: all write tools isError"
else
  no "missing task: some write tool did not error"
fi

# 6. fleet_artifact: server-computed sha256/bytes match sha256sum; bad path errors
printf 'artifact payload\n' > "$FLEET_HOME/art.bin"
WANT_HASH=$(sha256sum "$FLEET_HOME/art.bin" | awk '{print $1}')
WANT_BYTES=$(stat -c %s "$FLEET_HOME/art.bin")
R=$(call fleet_artifact "{\"path\":\"$FLEET_HOME/art.bin\",\"kind\":\"data\",\"summary\":\"s\"}")
P=$(jpayload "$R")
GOT_HASH=$(printf '%s' "$P" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')
GOT_BYTES=$(printf '%s' "$P" | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])')
RBAD=$(call fleet_artifact "{\"path\":\"$FLEET_HOME/nope.bin\"}")
BADERR=$(jpath "$RBAD" result.isError 2>/dev/null || echo "")
if [ "$GOT_HASH" = "$WANT_HASH" ] && [ "$GOT_BYTES" = "$WANT_BYTES" ] \
   && [ "$BADERR" = "true" ]; then
  ok "fleet_artifact: sha256/bytes server-computed, bad path isError"
else
  no "fleet_artifact: $GOT_HASH/$WANT_HASH $GOT_BYTES/$WANT_BYTES BADERR=$BADERR"
fi

# 7. fleet_send to commander: message row exists, from_agent == task-<id>
R=$(call fleet_send '{"to":"commander","body":"hello commander","topic":"ping"}')
MID=$(jpayload "$R" | python3 -c 'import json,sys; print(json.load(sys.stdin)["message_id"])')
ROW=$(fleet --json msg inbox --for commander 2>/dev/null | python3 -c '
import json,sys
rows=[r for r in json.load(sys.stdin) if r["id"]=='"$MID"']
assert rows, "message not found"
print(rows[0]["from_agent"], rows[0]["body"])')
if [ "$ROW" = "task-$T hello commander" ]; then
  ok "fleet_send: commander message from task-$T"
else
  no "fleet_send: got '$ROW'"
fi

# 8. fleet_send to a nonexistent task: isError
R=$(call fleet_send '{"to":"task-99999","body":"x"}')
if [ "$(jpath "$R" result.isError 2>/dev/null)" = "true" ]; then
  ok "fleet_send: task-99999 rejected"
else
  no "fleet_send: task-99999 rejected"
fi

# 9. fleet_inbox: first call returns unread, second is empty (read_at set)
fleet msg send --from commander --to "task-$T" "revise batch 1" --topic REVISE >/dev/null
R1=$(call fleet_inbox '{}')
HAS=$(jpayload "$R1" | python3 -c '
import json,sys
m=json.load(sys.stdin)["messages"]
assert any(x["topic"]=="REVISE" for x in m), m
print("ok")')
R2=$(call fleet_inbox '{}')
EMPTY=$(jpayload "$R2" | python3 -c '
import json,sys
m=json.load(sys.stdin)["messages"]
assert m==[], m
print("ok")')
if [ "$HAS" = "ok" ] && [ "$EMPTY" = "ok" ]; then
  ok "fleet_inbox: unread then empty (mark_read)"
else
  no "fleet_inbox: HAS=$HAS EMPTY=$EMPTY"
fi

# 10. fleet_task_get: own spec full text + dep summaries
R=$(call fleet_task_get '{}')
CHECK=$(jpayload "$R" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["id"]=='"$T"' and d["status"]=="running" and d["channel"]=="shell", d
assert d["attempt_id"]==sys.argv[1], d
assert "mcp main" in d["spec"], "spec missing"
deps={x["id"]:x for x in d["deps"]}
assert deps['"$D1"' ]["summary"]=="dep-one-summary-marker", deps
print("ok")' "$T_ATTEMPT")
if [ "$CHECK" = "ok" ]; then
  ok "fleet_task_get: spec full text and dep summary"
else
  no "fleet_task_get: $CHECK"
fi

# 11. dep summary is capped at SUMMARY_CAP (2000), never the full out.md
R=$(call fleet_task_get '{}')
CHECK=$(jpayload "$R" | python3 -c '
import json,sys
d=json.load(sys.stdin)
deps={x["id"]:x for x in d["deps"]}
s=deps['"$D2"' ]["summary"]
assert len(s)<=2000, len(s)
assert len(s)<10000, "full out.md leaked"
print("ok")')
if [ "$CHECK" = "ok" ]; then
  ok "fleet_task_get: dep summary capped at SUMMARY_CAP"
else
  no "fleet_task_get: $CHECK"
fi

# 12. fleet_spawn: message +1, task count unchanged (proposal only)
tasks_before=$(fleet --json status --all | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
msgs_before=$(fleet --json msg inbox --for commander 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
R=$(call fleet_spawn '{"title":"follow-up","rationale":"needed","channel":"shell"}')
P=$(jpayload "$R")
tasks_after=$(fleet --json status --all | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
msgs_after=$(fleet --json msg inbox --for commander 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
NOTE=$(printf '%s' "$P" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["enqueued"], d["note"])')
if [ "$tasks_after" = "$tasks_before" ] && [ "$msgs_after" = "$((msgs_before+1))" ] \
   && [ "$NOTE" = "False proposal only; the commander decides" ]; then
  ok "fleet_spawn: proposal recorded, no task created"
else
  no "fleet_spawn: tasks $tasks_before->$tasks_after msgs $msgs_before->$msgs_after note=$NOTE"
fi

# 13. preamble: injected by default at the front; --no-preamble skips; shell skips
A=$(fleet add "preamble check" --channel claude-p)
B=$(fleet add "no preamble" --channel claude-p --no-preamble)
C=$(fleet add "shell no preamble" --channel shell)
PA="$FLEET_HOME/runs/$A/prompt.md"
PB="$FLEET_HOME/runs/$B/prompt.md"
PC="$FLEET_HOME/runs/$C/prompt.md"
if head -1 "$PA" | grep -q "Fleet task $A" \
   && grep -q "preamble check" "$PA" \
   && ! grep -q "You are running as fleet task" "$PB" \
   && ! grep -q "You are running as fleet task" "$PC"; then
  ok "preamble: default front, --no-preamble off, shell off"
else
  no "preamble: injection mismatch"
fi
fleet cancel "$A" >/dev/null 2>&1 || true
fleet cancel "$B" >/dev/null 2>&1 || true

# 14. fleet proposals lists spawn proposals; --goal filters by the authoring
# task's goal in both output modes and excludes non-task senders.
G14A=$(fleet goal add "proposal goal A")
G14B=$(fleet goal add "proposal goal B")
T14A=$(fleet add "proposal author A" --channel shell --goal "$G14A")
T14B=$(fleet add "proposal author B" --channel shell --goal "$G14B")
A14A="mcp-14-$T14A"
A14B="mcp-14-$T14B"
sqlite3 "$FLEET_HOME/fleet.db" \
  "UPDATE task SET status='running',attempt=1,attempt_id='$A14A' WHERE id=$T14A;
   UPDATE task SET status='running',attempt=1,attempt_id='$A14B' WHERE id=$T14B"
call_attempt_as "$T14A" "$A14A" fleet_spawn \
  '{"title":"goal-a-14","rationale":"matching goal"}' >/dev/null
call_attempt_as "$T14B" "$A14B" fleet_spawn \
  '{"title":"goal-b-14","rationale":"other goal"}' >/dev/null
fleet msg send --from outside-14 --to commander --topic spawn-proposal \
  '{"title":"outside-14","rationale":"non-task identity"}' >/dev/null

P14_TEXT=$(fleet proposals --goal "$G14A")
P14_JSON=$(fleet --json proposals --goal "$G14A")
P14_TEXT_CHECK=$(python3 -c '
import sys
lines=[line for line in sys.argv[1].splitlines() if line]
assert len(lines)==1, lines
assert "task-'"$T14A"'" in lines[0], lines
assert "goal-a-14" in lines[0], lines
assert all(marker not in lines[0] for marker in ("goal-b-14","outside-14","follow-up")), lines
print("ok")' "$P14_TEXT")
P14_JSON_CHECK=$(printf '%s' "$P14_JSON" | python3 -c '
import json,sys
rows=json.load(sys.stdin)
assert len(rows)==1, rows
row=rows[0]
assert row["from_agent"]=="task-'"$T14A"'", row
assert json.loads(row["body"])["title"]=="goal-a-14", row
print("ok")')
if fleet proposals | grep -q "follow-up" \
   && fleet --json proposals | python3 -c '
import json,sys
rows=json.load(sys.stdin)
assert any(r["topic"]=="spawn-proposal" and "follow-up" in r["body"] for r in rows), rows
print("ok")' >/dev/null \
   && [ "$P14_TEXT_CHECK" = "ok" ] \
   && [ "$P14_JSON_CHECK" = "ok" ]; then
  ok "fleet proposals: spawn proposal listed, --goal filters text and JSON"
else
  no "fleet proposals: --goal mismatch (text=$P14_TEXT json=$P14_JSON text_check=$P14_TEXT_CHECK json_check=$P14_JSON_CHECK)"
fi

# 15. Optional real-channel E2E: a task reads a file and records a claim.
# The default suite never consumes online model quota.
# The running rows above are MCP-auth fixtures, not real work. Settle them
# before launching the live model so channel notes about workflow planning do
# not tempt the model to wait on unrelated synthetic tasks.
sqlite3 "$FLEET_HOME/fleet.db" \
  "UPDATE task SET status='done',ended_at=strftime('%s','now'),exit_code=0
   WHERE id IN ($T,$T14A,$T14B)"
printf 'the magic word is butterscotch\n' > "$FLEET_HOME/secret.txt"
cat > "$FLEET_HOME/spec15.md" <<EOF
Read the file $FLEET_HOME/secret.txt (it holds one line).
Call the fleet_claim tool once, with claim="read the secret file" and
evidence="$FLEET_HOME/secret.txt: <the exact line you read>".
Do not run fleet wait, fleet status, or any command that waits for tasks.
After the tool call returns, output exactly one line: DONE
EOF
if [ -z "${FLEET_E2E_CHANNEL:-}" ]; then
  N=$((N+1)); PASS=$((PASS+1))
  echo "ok $N - e2e claim through a real channel # SKIP no FLEET_E2E_CHANNEL"
else
  T15=$(fleet add "e2e claim" --channel "$FLEET_E2E_CHANNEL" \
    --spec "$FLEET_HOME/spec15.md" --no-preamble)
  fleet run "$T15" >/dev/null
  if wait_done "$T15" \
     && fleet --json claim list --task "$T15" | python3 -c '
import json,sys
rows=json.load(sys.stdin)
assert rows, "no claim rows"
assert all(r["evidence"].strip() for r in rows), rows
print("ok")' >/dev/null; then
    ok "e2e: real channel task done with a claim and evidence"
  else
    echo "--- task $T15 log tail ---" >&2
    tail -20 "$(field "$T15" log_path)" >&2 || true
    no "e2e: real channel task done with a claim and evidence"
  fi
fi

# 16. project-agnostic: no concrete project names anywhere in the tree.
#     Pattern assembled from pieces so this file does not self-match.
PAT="${FLEET_FORBIDDEN_NAMES:-Acme""Corp|acme""-internal}"
if grep -rIn -E "$PAT" "$ROOT" \
    --exclude-dir=.git \
    --exclude-dir=docs; then
  no "project-agnostic: no concrete project names"
else
  ok "project-agnostic: no concrete project names"
fi

echo "---"
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = "0" ]
