#!/usr/bin/env bash
# fleet P8 smoke tests: project-context injection, fleet_note, the two
# silence fixes (status / brief-daemon), worktree-rooted reviews, and the
# stale-channels warning. Zero model quota: shell channel only, plus raw
# JSON-RPC for the MCP tool.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p8-test-XXXX)"
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

# Raw JSON-RPC against fleet-mcp, one fresh server per call (stateless across
# connections; all state lives in the ledger).
call_as() {
  local tid="$1" attempt; shift
  attempt=$(sqlite3 "$FLEET_HOME/fleet.db" "SELECT attempt_id FROM task WHERE id=$tid")
  python3 -c 'import json,sys
print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":sys.argv[1],"arguments":json.loads(sys.argv[2])}}))' "$1" "$2" \
    | FLEET_HOME="$FLEET_HOME" FLEET_TASK_ID="$tid" FLEET_ATTEMPT="$attempt" \
      "$ROOT/bin/fleet-mcp" 2>>"$FLEET_HOME/mcp.err"
}
jpath() {
  python3 -c '
import json,sys
d=json.loads(sys.argv[1])
for k in sys.argv[2].split("."):
    d = d[int(k)] if k.isdigit() else d[k]
print(d if isinstance(d,str) else json.dumps(d,ensure_ascii=False))' "$1" "$2"
}

fleet init >/dev/null
printf 'SPEC-BODY-MARKER\n' > "$FLEET_HOME/spec1.md"
printf 'echo hi\n' > "$FLEET_HOME/spec_echo.sh"

# 1. --context single file: spliced after the preamble, before the spec
printf '# CTX-MARKER-1\n' > "$FLEET_HOME/c1.md"
T1=$(fleet add "ctx one" --channel claude-p --context "$FLEET_HOME/c1.md" \
      --spec "$FLEET_HOME/spec1.md")
P1="$FLEET_HOME/runs/$T1/prompt.md"
l_pre=$(grep -n "^# Fleet task $T1:" "$P1" | head -1 | cut -d: -f1)
l_hdr=$(grep -n -- "--- context: c1.md ---" "$P1" | head -1 | cut -d: -f1)
l_ctx=$(grep -n "CTX-MARKER-1" "$P1" | head -1 | cut -d: -f1)
l_spec=$(grep -n "SPEC-BODY-MARKER" "$P1" | head -1 | cut -d: -f1)
if [ -n "$l_pre" ] && [ -n "$l_hdr" ] && [ -n "$l_ctx" ] && [ -n "$l_spec" ] \
   && [ "$l_pre" -lt "$l_hdr" ] && [ "$l_hdr" -lt "$l_ctx" ] \
   && [ "$l_ctx" -lt "$l_spec" ]; then
  ok "single context file lands between preamble and spec"
else
  no "single context file lands between preamble and spec (pre=$l_pre hdr=$l_hdr ctx=$l_ctx spec=$l_spec)"
fi
fleet cancel "$T1" >/dev/null 2>&1 || true

# 2. --context multiple files: given order, each with its own header
printf '# CTX-A\n' > "$FLEET_HOME/ca.md"
printf '# CTX-B\n' > "$FLEET_HOME/cb.md"
T2=$(fleet add "ctx two" --channel claude-p \
      --context "$FLEET_HOME/ca.md" --context "$FLEET_HOME/cb.md" \
      --spec "$FLEET_HOME/spec1.md")
P2="$FLEET_HOME/runs/$T2/prompt.md"
ha=$(grep -n -- "--- context: ca.md ---" "$P2" | head -1 | cut -d: -f1)
la=$(grep -n "CTX-A" "$P2" | head -1 | cut -d: -f1)
hb=$(grep -n -- "--- context: cb.md ---" "$P2" | head -1 | cut -d: -f1)
lb=$(grep -n "CTX-B" "$P2" | head -1 | cut -d: -f1)
if [ -n "$ha" ] && [ -n "$hb" ] && [ "$ha" -lt "$la" ] \
   && [ "$la" -lt "$hb" ] && [ "$hb" -lt "$lb" ]; then
  ok "multiple context files keep order, each headed"
else
  no "multiple context files keep order, each headed (ha=$ha la=$la hb=$hb lb=$lb)"
fi
fleet cancel "$T2" >/dev/null 2>&1 || true

# 3. goal --context: stored on the goal, applied to every task under it
printf '# GOAL-CTX-3\n' > "$FLEET_HOME/gc.md"
G3=$(fleet goal add "g3" --context "$FLEET_HOME/gc.md")
T3=$(fleet add "goal ctx" --channel shell --goal "$G3" \
      --spec "$FLEET_HOME/spec1.md")
if grep -q "GOAL-CTX-3" "$FLEET_HOME/runs/$T3/prompt.md" \
   && fleet --json goal list | python3 -c '
import json,sys
g=[x for x in json.load(sys.stdin) if x["id"]=='"$G3"']
assert g and g[0]["context"], g
print("ok")' >/dev/null; then
  ok "goal --context is stored and auto-applied"
else
  no "goal --context is stored and auto-applied"
fi

# 4. goal and task contexts merge: deduped, goal's first
printf '# SHARED-CTX-4\n' > "$FLEET_HOME/shared.md"
printf '# TASKONLY-4\n' > "$FLEET_HOME/taskonly.md"
G4=$(fleet goal add "g4" --context "$FLEET_HOME/shared.md")
T4=$(fleet add "merge ctx" --channel shell --goal "$G4" \
      --context "$FLEET_HOME/shared.md" --context "$FLEET_HOME/taskonly.md" \
      --spec "$FLEET_HOME/spec1.md")
P4="$FLEET_HOME/runs/$T4/prompt.md"
n_shared=$(grep -c -- "--- context: shared.md ---" "$P4")
l_shared=$(grep -n -- "--- context: shared.md ---" "$P4" | head -1 | cut -d: -f1)
l_taskonly=$(grep -n -- "--- context: taskonly.md ---" "$P4" | head -1 | cut -d: -f1)
if [ "$n_shared" = "1" ] && [ -n "$l_shared" ] && [ -n "$l_taskonly" ] \
   && [ "$l_shared" -lt "$l_taskonly" ]; then
  ok "goal+task contexts merge deduped, goal first"
else
  no "goal+task contexts merge deduped, goal first (n=$n_shared $l_shared/$l_taskonly)"
fi

# 5. a missing context file refuses the enqueue with exit 9; no task is born
fleet add "missing ctx" --channel shell --context "$FLEET_HOME/nope.md" \
  >/dev/null 2>"$FLEET_HOME/e5"
rc5=$?
fleet goal add "g5 missing" --context "$FLEET_HOME/nope.md" \
  >/dev/null 2>"$FLEET_HOME/e5g"
rc5g=$?
born=$(python3 -c "
import sqlite3
print(sqlite3.connect('$FLEET_HOME/fleet.db').execute(
  \"SELECT COUNT(*) FROM task WHERE title='missing ctx'\").fetchone()[0])")
if [ "$rc5" = "9" ] && [ "$rc5g" = "9" ] && [ "$born" = "0" ] \
   && grep -qi "context" "$FLEET_HOME/e5"; then
  ok "missing context file refused at enqueue, exit 9, no task created"
else
  no "missing context file refused at enqueue, exit 9, no task created (rc=$rc5 rcg=$rc5g born=$born)"
fi

# 6. a context file over CONTEXT_CAP is truncated with a visible marker
python3 -c 'import sys; open(sys.argv[1],"w").write("Z"*25000)' "$FLEET_HOME/big.md"
T6=$(fleet add "big ctx" --channel shell --context "$FLEET_HOME/big.md" \
      --spec "$FLEET_HOME/spec1.md")
P6="$FLEET_HOME/runs/$T6/prompt.md"
nz=$(awk '
  /^--- context: big.md ---$/ {in_big=1; next}
  /^--- context truncated at 20000 bytes ---$/ {in_big=0}
  in_big {for (i=1; i<=length($0); i++) if (substr($0,i,1)=="Z") n++}
  END {print n+0}
' "$P6")
if [ "$nz" = "20000" ] \
   && grep -q -- "--- context truncated at 20000 bytes ---" "$P6"; then
  ok "oversized context truncated at CONTEXT_CAP with a marker"
else
  no "oversized context truncated at CONTEXT_CAP with a marker (nz=$nz)"
fi

# 7. schema migration: a pre-P8 ledger keeps its data and gains goal.context,
#    and re-running init does not fail (idempotent)
OLD="$(mktemp -d /var/tmp/fleet-p8-old-XXXX)"; SCRATCH+=("$OLD")
python3 - "$OLD/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("""CREATE TABLE goal(
  id INTEGER PRIMARY KEY, statement TEXT NOT NULL, acceptance TEXT,
  approval_gates TEXT, budget_cap INTEGER,
  status TEXT NOT NULL DEFAULT 'open',
  created_by TEXT DEFAULT 'user', created_at INTEGER NOT NULL)""")
c.execute("INSERT INTO goal(id,statement,created_at) VALUES(3,'old goal',12345)")
c.commit()
PY
FLEET_HOME="$OLD" fleet init >/dev/null
FLEET_HOME="$OLD" fleet init >/dev/null
M7=$(python3 - "$OLD/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
cols = {r[1] for r in c.execute("PRAGMA table_info(goal)")}
assert "context" in cols, cols
row = c.execute("SELECT id,statement,status,context FROM goal WHERE id=3").fetchone()
assert row == (3, "old goal", "open", None), row
print("ok")
PY
)
if [ "$M7" = "ok" ]; then
  ok "init migrates a pre-P8 ledger in place, data intact, idempotently"
else
  no "init migrates a pre-P8 ledger in place, data intact, idempotently ($M7)"
fi

# 8. fleet_note records a note-proposal message; nothing is filed
T8=$(fleet add "note author" --channel shell --no-preamble)
sqlite3 "$FLEET_HOME/fleet.db" \
  "UPDATE task SET status='running',attempt=1,attempt_id='p8-$T8' WHERE id=$T8"
R=$(call_as "$T8" fleet_note '{"finding":"note-marker-8","evidence":"ev-8 file:1"}')
ISERR=$(jpath "$R" result.isError 2>/dev/null || echo "")
M8=$(fleet --json msg inbox --for commander | python3 -c '
import json,sys
rows=json.load(sys.stdin)
notes=[r for r in rows if r["topic"]=="note-proposal"]
assert notes, "no note-proposal rows"
assert any("note-marker-8" in r["body"] for r in notes), notes
print("ok")')
if [ -z "$ISERR" ] && [ "$M8" = "ok" ]; then
  ok "fleet_note: note-proposal message recorded"
else
  no "fleet_note: note-proposal message recorded (ISERR=$ISERR M8=$M8)"
fi

# 9. blank evidence: isError AND zero new rows
before=$(fleet --json msg inbox --for commander | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
R=$(call_as "$T8" fleet_note '{"finding":"no evidence","evidence":"  "}')
ISERR=$(jpath "$R" result.isError 2>/dev/null || echo "")
after=$(fleet --json msg inbox --for commander | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
if [ "$ISERR" = "true" ] && [ "$after" = "$before" ]; then
  ok "fleet_note: blank evidence isError, no row written"
else
  no "fleet_note: blank evidence ISERR=$ISERR before=$before after=$after"
fi

# 10. fleet_note writes NO files (cwd and FLEET_HOME stay untouched)
mkdir -p "$FLEET_HOME/notewatch"
M10=$(
  cd "$FLEET_HOME/notewatch" || exit 1
  before=$(find . -type f | sort)
  call_as "$T8" fleet_note '{"finding":"watch-marker-10","evidence":"ev-10 file:1"}' >/dev/null
  after=$(find . -type f | sort)
  if [ "$before" = "$after" ] && [ ! -e findings ] \
     && [ ! -e "$FLEET_HOME/findings" ]; then
    echo ok
  fi
)
if [ "$M10" = "ok" ]; then
  ok "fleet_note: no files created in cwd or FLEET_HOME"
else
  no "fleet_note: no files created in cwd or FLEET_HOME (M10=$M10)"
fi

# 11. fleet notes lists proposals; --goal filters by the authoring task's goal
T11=$(fleet add "goal note author" --channel shell --goal "$G3")
sqlite3 "$FLEET_HOME/fleet.db" \
  "UPDATE task SET status='running',attempt=1,attempt_id='p8-$T11' WHERE id=$T11"
call_as "$T11" fleet_note '{"finding":"goal-note-11","evidence":"ev-11 file:1"}' >/dev/null
if fleet notes | grep -q "note-marker-8" \
   && fleet --json notes | python3 -c '
import json,sys
rows=json.load(sys.stdin)
assert any(r["topic"]=="note-proposal" and "note-marker-8" in r["body"] for r in rows), rows
print("ok")' >/dev/null \
   && fleet notes --goal "$G3" | grep -q "goal-note-11" \
   && [ -z "$(fleet notes --goal 99999)" ]; then
  ok "fleet notes: lists proposals, --goal filters by author task goal"
else
  no "fleet notes: lists proposals, --goal filters by author task goal"
fi
fleet cancel "$T8" >/dev/null 2>&1 || true
fleet cancel "$T11" >/dev/null 2>&1 || true

# 12. status: nothing under cwd but live tasks elsewhere -> one hint line
#     (sweep first: earlier cases left queued tasks with other cwds)
fleet --json status --all | python3 -c '
import json, subprocess, sys
for r in json.load(sys.stdin):
    if r["status"] not in ("done","failed","cancelled"):
        subprocess.run(["fleet","cancel",str(r["id"])],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)'
mkdir -p "$FLEET_HOME/elsewhere" "$FLEET_HOME/here"
T12=$(fleet add "elsewhere task" --channel shell --cwd "$FLEET_HOME/elsewhere" \
       --spec "$FLEET_HOME/spec1.md")
out12=$(cd "$FLEET_HOME/here" && fleet status)
if printf '%s\n' "$out12" | grep -qF "no tasks under $FLEET_HOME/here; 1 elsewhere (--all)"; then
  ok "status: empty view names the tasks it is hiding"
else
  no "status: empty view names the tasks it is hiding (got: $out12)"
fi

# 13. status: nothing unterminated anywhere -> completely silent (default and
#     --all, the latter on a genuinely empty ledger)
fleet cancel "$T12" >/dev/null 2>&1 || true
out13=$(cd "$FLEET_HOME/here" && fleet status)
FRESH="$(mktemp -d /var/tmp/fleet-p8-fresh-XXXX)"; SCRATCH+=("$FRESH")
FLEET_HOME="$FRESH" fleet init >/dev/null
out13all=$(FLEET_HOME="$FRESH" fleet status --all)
if [ -z "$out13" ] && [ -z "$out13all" ]; then
  ok "status: truly nothing to show stays silent"
else
  no "status: truly nothing to show stays silent (def='$out13' all='$out13all')"
fi

# 14. brief: daemon state on the first line
b0=$(fleet brief | head -1)
fleet daemon start --interval 1 >/dev/null
pid14=$(cat "$FLEET_HOME/fleetd.pid")
b1=$(fleet brief | head -1)
fleet daemon stop >/dev/null
if [ "$b0" = "daemon: stopped" ] \
   && [ "$b1" = "daemon: running (pid $pid14)" ]; then
  ok "brief: daemon stopped/running on the first line"
else
  no "brief: daemon stopped/running on the first line (b0='$b0' b1='$b1')"
fi

# 15. brief: stopped with queued work says the queue is not advancing
T15=$(fleet add "stuck queued" --channel shell --cwd "$FLEET_HOME/elsewhere" \
       --spec "$FLEET_HOME/spec1.md")
b15=$(fleet brief | head -1)
fleet cancel "$T15" >/dev/null 2>&1 || true
if [ "$b15" = "daemon: stopped -- 1 queued tasks are not advancing" ]; then
  ok "brief: stopped daemon + queued tasks carries the not-advancing suffix"
else
  no "brief: stopped daemon + queued tasks carries the not-advancing suffix (got: $b15)"
fi

# 16. a rule-dispatched review of a --worktree task runs IN the worktree and
#     its spec carries the branch, the diff stat, and the task's claim list
G16=$(fleet goal add "g16")
cat > "$FLEET_HOME/rules16.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"shell"}}]
EOF
fleet plan set "$G16" --rules "$FLEET_HOME/rules16.json" --rationale "auto review" >/dev/null
REPO="$FLEET_HOME/repo16"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'original\n' > "$REPO/same.txt"
git -C "$REPO" add same.txt
git -C "$REPO" commit -qm base
printf 'echo reviewed >> same.txt\n' > "$FLEET_HOME/spec16.sh"
T16=$(fleet add "wt reviewed" --channel shell --worktree --cwd "$REPO" \
       --goal "$G16" --spec "$FLEET_HOME/spec16.sh")
fleet run "$T16" >/dev/null
wait_status "$T16" done
WT=$(field "$T16" worktree)
fleet claim add "$T16" "claim-marker-16" --evidence "ev-16 file:1" >/dev/null
fleet daemon run --once >/dev/null 2>&1
RV=$(fleet --json status --all | python3 -c '
import json,sys
rows=json.load(sys.stdin)
rv=[r for r in rows if r["review_of"]=='"$T16"']
assert len(rv)==1, rv
print(rv[0]["id"])')
PRV="$FLEET_HOME/runs/$RV/prompt.md"
if [ "$(field "$RV" cwd)" = "$WT" ] \
   && grep -q -- "fleet/task-$T16" "$PRV" \
   && grep -q "claim-marker-16" "$PRV" \
   && grep -q "same.txt" "$PRV"; then
  ok "review of a worktree task: cwd=worktree, spec has branch/diffstat/claims"
else
  no "review of a worktree task: cwd=worktree, spec has branch/diffstat/claims (cwd=$(field "$RV" cwd) wt=$WT)"
fi
fleet cancel "$RV" >/dev/null 2>&1 || true

# 17. stale runtime channels.json: warned on `fleet channels` and `fleet init`,
#     --sync fixes it with a backup that keeps the hand-edited values
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
del d["model_families"]
d["max_parallel"] = 7
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
fleet channels >/dev/null 2>"$FLEET_HOME/ch.err"
fleet init >/dev/null 2>"$FLEET_HOME/init.err"
sync_out=$(fleet channels --sync)
bak=$(ls "$FLEET_HOME"/channels.json.bak-* 2>/dev/null | head -1)
fleet channels >/dev/null 2>"$FLEET_HOME/ch2.err"
M17=$(python3 - "$bak" "$FLEET_HOME/channels.json" <<'PY'
import json, sys
old = json.load(open(sys.argv[1]))
new = json.load(open(sys.argv[2]))
assert old["max_parallel"] == 7, old
assert "model_families" not in old, old
assert "model_families" in new, new
assert new["max_parallel"] != 7, new
print("ok")
PY
)
if grep -qi "model_families" "$FLEET_HOME/ch.err" \
   && grep -qi "sync" "$FLEET_HOME/ch.err" \
   && grep -qi "sync" "$FLEET_HOME/init.err" \
   && [ -n "$bak" ] && [ "$M17" = "ok" ] \
   && [ ! -s "$FLEET_HOME/ch2.err" ]; then
  ok "stale channels warned; --sync backs up and updates; warning gone"
else
  no "stale channels warned; --sync backs up and updates; warning gone (M17=$M17 bak=$bak)"
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
