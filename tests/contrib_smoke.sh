#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /var/tmp/fleet-contrib-test-XXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0 N=0
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }

mkdir -p "$TMP/bin" "$TMP/work trees"
cat >"$TMP/bin/fleet" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2 $3" = "worktree list --json" ] || exit 2
cat "$AUDIT_ROWS"
EOF
chmod +x "$TMP/bin/fleet"
export PATH="$TMP/bin:$PATH"
export AUDIT_ROWS="$TMP/rows.json"

make_repo(){
  local repo="$1"
  git init -q --initial-branch=internal "$repo"
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name test
  echo base >"$repo/tracked"
  git -C "$repo" add tracked
  git -C "$repo" commit -qm base
}
make_repo "$TMP/clean repo"
make_repo "$TMP/risky repo"
git -C "$TMP/clean repo" worktree add -q -b clean-branch "$TMP/work trees/clean" internal
git -C "$TMP/risky repo" worktree add -q -b risky-branch "$TMP/work trees/risky" internal

rows(){
  python3 - "$AUDIT_ROWS" "$@" <<'PY'
import json,sys
out=[]
for value in sys.argv[2:]:
    ident,path,branch=value.split("|",2)
    out.append({"id":int(ident),"status":"done","worktree":path,"worktree_branch":branch})
json.dump(out,open(sys.argv[1],"w"))
PY
}
AUDIT="$ROOT/contrib/worktree-audit.sh"

rows "1|$TMP/work trees/clean|clean-branch"
"$AUDIT" >"$TMP/out1"; rc=$?
if [ "$rc" = 0 ] && grep -q '^clean$' "$TMP/out1" && grep -q 'task 1 .*ahead=0 .*dirty=0' "$TMP/out1"; then
  ok "clean merged worktree is clean and exits 0"
else no "clean classification (rc=$rc)"; fi

echo ahead >"$TMP/work trees/risky/ahead"
git -C "$TMP/work trees/risky" add ahead
git -C "$TMP/work trees/risky" commit -qm ahead
rows "2|$TMP/work trees/risky|risky-branch"
"$AUDIT" >"$TMP/out2"; rc=$?
if [ "$rc" = 1 ] && grep -q 'task 2 .*ahead=1 .*dirty=0' "$TMP/out2"; then
  ok "one unmerged commit is risky and exits 1"
else no "ahead classification (rc=$rc)"; fi

echo dirty >>"$TMP/work trees/clean/tracked"
rows "3|$TMP/work trees/clean|clean-branch"
"$AUDIT" >"$TMP/out3"; rc=$?
if [ "$rc" = 1 ] && grep -q 'task 3 .*ahead=0 .*dirty=1' "$TMP/out3"; then
  ok "uncommitted change is risky"
else no "dirty classification (rc=$rc)"; fi

rows "4|$TMP/does not exist|gone"
"$AUDIT" >"$TMP/out4"; rc=$?
if [ "$rc" = 0 ] && grep -A1 '^stale$' "$TMP/out4" | grep -q 'task 4'; then
  ok "missing worktree is stale and exits 0"
else no "stale classification (rc=$rc)"; fi

git -C "$TMP/risky repo" worktree add -q -b broken-branch "$TMP/work trees/broken" internal
rm -rf "$TMP/risky repo"
rows "5|$TMP/work trees/broken|broken-branch"
"$AUDIT" >"$TMP/out5"; rc=$?
if [ "$rc" = 1 ] && grep -A1 '^risky$' "$TMP/out5" | grep -q 'task 5'; then
  ok "unresolvable git metadata is risky without crashing"
else no "broken repository classification (rc=$rc)"; fi

rows "1|$TMP/work trees/clean|clean-branch" "4|$TMP/does not exist|gone" "5|$TMP/work trees/broken|broken-branch"
"$AUDIT" --json >"$TMP/out6.json"; rc=$?
if [ "$rc" = 1 ] && python3 -m json.tool "$TMP/out6.json" >/dev/null \
 && python3 - "$TMP/out6.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); s=d["summary"]
assert (s["risky"],s["clean"],s["stale"]) == (2,0,1)
PY
then ok "JSON parses and section counts match human classifications"
else no "JSON output/counts (rc=$rc)"; fi

# ---------------------------------------------------------------------------
# contrib/notify-lark.py
#
# Every case drives the real ledger through the real CLI -- no hand-inserted
# event rows. A notifier tested against events a test wrote itself only proves
# the test and the script agree on a format; the point here is that the shapes
# `fleet` actually emits are the shapes this reads.
#
# --fleet-bin is passed explicitly rather than relying on PATH: the worktree
# cases above put a fake `fleet` first on PATH that answers only
# `worktree list --json`. (Task wrappers are unaffected -- launch() embeds an
# absolute path to the CLI, bin/fleet:1142.)
#
# The send backend is a stub for every case. Nothing here may put a real
# message in front of a human.
# ---------------------------------------------------------------------------

NL_HOME="$TMP/nl"
mkdir -p "$NL_HOME"
FLEET_BIN="$ROOT/bin/fleet"
NOTIFY="$ROOT/contrib/notify-lark.py"
NL_STATE="$NL_HOME/notify.state"
NL_CONF="$NL_HOME/notify.json"
export FAKE_CALLS="$NL_HOME/backend-calls.log"

cat >"$NL_HOME/fake-lark" <<'EOF'
#!/usr/bin/env bash
# Records one line per invocation, so "was the backend called at all" is a
# question the tests can answer, not assume.
{ printf '=== call:'; printf ' %q' "$@"; printf '\n'; } >>"$FAKE_CALLS"
[ -n "${FAKE_FAIL:-}" ] && { echo "stub backend refused" >&2; exit 7; }
echo '{"ok":true}'
EOF
chmod +x "$NL_HOME/fake-lark"

fl(){ FLEET_HOME="$NL_HOME" "$FLEET_BIN" "$@"; }
nl(){
  FLEET_HOME="$NL_HOME" python3 "$NOTIFY" \
    --fleet-bin "$FLEET_BIN" --lark-bin "$NL_HOME/fake-lark" \
    --state "$NL_STATE" --config "$NL_CONF" "$@"
}
wm(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$NL_STATE" "$1"; }
backend_calls(){ [ -f "$FAKE_CALLS" ] && grep -c '^=== call:' "$FAKE_CALLS" || echo 0; }

fl init >/dev/null
printf 'echo hi\n' >"$NL_HOME/spec_ok.sh"
printf 'echo boom >&2\nexit 3\n' >"$NL_HOME/spec_fail.sh"
printf 'sleep 8\n' >"$NL_HOME/spec_sleep.sh"
NT1=$(fl add "top --json 与屏幕共用行查询" --channel shell --spec "$NL_HOME/spec_ok.sh")
NT2=$(fl add "22e 是无牙用例" --channel shell --spec "$NL_HOME/spec_ok.sh")
NC1=$(fl claim add "$NT1" "top --json 与屏幕共用同一行查询" --evidence bin/fleet:3560)
NC2=$(fl claim add "$NT2" "22e 这条用例是无牙的" --evidence tests/mutations.tsv:22)

# 8. A first run against an unknown ledger starts from the tip. Replaying the
#    whole backlog on install is how a new channel gets muted on day one.
nl >"$NL_HOME/o0" 2>"$NL_HOME/e0"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$NL_HOME/o0" ] && grep -q 'from event' "$NL_HOME/e0" \
   && [ "$(wm event_watermark)" != "0" ]; then
  ok "notify: first run adopts the tip and pushes no backlog"
else no "notify: bootstrap (rc=$rc out='$(cat "$NL_HOME/o0")')"; fi

# 1. No increment: no output at all, exit 0, watermark untouched. This runs
#    once a minute; even a heartbeat line would bury the real ones.
BEFORE_EV=$(wm event_watermark); BEFORE_DEC=$(wm decision_watermark)
nl >"$NL_HOME/o1" 2>"$NL_HOME/e1"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$NL_HOME/o1" ] && [ ! -s "$NL_HOME/e1" ] \
   && [ "$(wm event_watermark)" = "$BEFORE_EV" ] \
   && [ "$(wm decision_watermark)" = "$BEFORE_DEC" ]; then
  ok "notify: no increment is silent, exit 0, watermark unchanged"
else no "notify: empty run (rc=$rc out='$(cat "$NL_HOME/o1")' err='$(cat "$NL_HOME/e1")')"; fi

# 2. A claim reaching a verdict names both ids: the claim to look up and the
#    task it belongs to.
fl claim verify "$NC1" --status confirmed --by 0 >/dev/null
fl claim verify "$NC2" --status refuted --by 0 >/dev/null
nl >"$NL_HOME/o2" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] \
   && grep -q "verified.*task $NT1 · claim $NC1" "$NL_HOME/o2" \
   && grep -q "refuted.*task $NT2 · claim $NC2" "$NL_HOME/o2" \
   && grep -q '共用同一行查询' "$NL_HOME/o2"; then
  ok "notify: a verified/refuted claim carries claim id, task id and text"
else no "notify: claim verdict lines (rc=$rc)"; printf '%s\n' "$(cat "$NL_HOME/o2")"; fi

# 3. A decision waiting on the human.
ND1=$(fl decide "要不要在 staging 真跑验收" --needs-user --verdict conflict)
nl >"$NL_HOME/o3" 2>/dev/null
if grep -q "NEEDS YOU.*decision $ND1" "$NL_HOME/o3" \
   && grep -q 'staging 真跑验收' "$NL_HOME/o3"; then
  ok "notify: a needs_user decision surfaces as NEEDS YOU with its id"
else no "notify: needs_user line"; printf '%s\n' "$(cat "$NL_HOME/o3")"; fi

# 3b. NEEDS YOU sorts above the claim verdicts, so the fold in case 7 can only
#     ever eat the least urgent tail.
if [ "$(grep -n 'NEEDS YOU' "$NL_HOME/o3" | cut -d: -f1)" = "2" ]; then
  ok "notify: NEEDS YOU sorts first, above claim verdicts"
else no "notify: urgency ordering"; fi

# 9. The spec's central rule: done is not the trigger. A task that exits 0 has
#    only proved its process ended.
NTD=$(fl add "会成功的任务" --channel shell --spec "$NL_HOME/spec_ok.sh")
fl run "$NTD" >/dev/null 2>&1; fl wait "$NTD" --timeout 30 >/dev/null 2>&1
before=$(nl 2>/dev/null | head -1)
after=$(nl 2>/dev/null | head -1)
if [ "$(fl --json show "$NTD" | python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])')" = done ] \
   && [ "$before" = "$after" ]; then
  ok "notify: a task reaching done adds nothing to the message"
else no "notify: done must not notify (before='$before' after='$after')"; fi

# 10. Class 3, both halves, from real runs rather than synthesized events.
NTF=$(fl add "会失败的任务" --channel shell --spec "$NL_HOME/spec_fail.sh")
fl run "$NTF" >/dev/null 2>&1; fl wait "$NTF" --timeout 30 >/dev/null 2>&1
NTS=$(fl add "会卡住的任务" --channel shell --spec "$NL_HOME/spec_sleep.sh")
fl run "$NTS" >/dev/null 2>&1
sleep 2
fl status --stall 0 >/dev/null 2>&1
nl >"$NL_HOME/o10" 2>/dev/null
if grep -q "failed.*task $NTF" "$NL_HOME/o10" && grep -q 'exit 3' "$NL_HOME/o10"; then
  ok "notify: a task that spent its attempts reports as failed"
else no "notify: failed line"; printf '%s\n' "$(cat "$NL_HOME/o10")"; fi
if grep -q "stalled.*task $NTS" "$NL_HOME/o10"; then
  ok "notify: a stalled task reports as stalled"
else no "notify: stalled line"; printf '%s\n' "$(cat "$NL_HOME/o10")"; fi
fl cancel "$NTS" >/dev/null 2>&1

# 4. --send with nowhere to send: exit 2, and the backend is never reached by
#    any path -- not even to be told the message was empty.
rm -f "$FAKE_CALLS"
nl --send >/dev/null 2>"$NL_HOME/e4"; rc=$?
calls_nocfg=$(backend_calls)
echo '{"note":"deliberately names no target"}' >"$NL_CONF"
nl --send >/dev/null 2>>"$NL_HOME/e4"; rc2=$?
calls_notarget=$(backend_calls)
if [ "$rc" = 2 ] && [ "$rc2" = 2 ] \
   && [ "$calls_nocfg" = 0 ] && [ "$calls_notarget" = 0 ] \
   && grep -q 'no config file' "$NL_HOME/e4" \
   && grep -q 'no chat_id or user_id' "$NL_HOME/e4"; then
  ok "notify: --send without a target exits 2 and never calls the backend"
else no "notify: send refusal (rc=$rc/$rc2 calls=$calls_nocfg/$calls_notarget)"; fi

# 5. A failed send must not eat the increment. Repeating a message is
#    recoverable; dropping the one that said a claim was refuted is not.
echo '{"chat_id":"oc_stub_target"}' >"$NL_CONF"
EV5=$(wm event_watermark); DEC5=$(wm decision_watermark)
FAKE_FAIL=1 nl --send >/dev/null 2>"$NL_HOME/e5"; rc=$?
nl >"$NL_HOME/o5" 2>/dev/null
if [ "$rc" != 0 ] && [ "$rc" != 2 ] \
   && [ "$(wm event_watermark)" = "$EV5" ] \
   && [ "$(wm decision_watermark)" = "$DEC5" ] \
   && grep -q 'send failed' "$NL_HOME/e5" \
   && grep -q "claim $NC1" "$NL_HOME/o5"; then
  ok "notify: a failed send leaves the watermark, so the events come back"
else no "notify: send failure (rc=$rc wm=$(wm event_watermark) want=$EV5)"; fi

# 5b. The retry reuses the idempotency key, so the failure mode where the
#     server accepted the message and only the response was lost does not
#     post it twice.
rm -f "$FAKE_CALLS"
FAKE_FAIL=1 nl --send >/dev/null 2>&1
key_fail=$(grep -o 'fleet-notify-[0-9-]*' "$FAKE_CALLS" | tail -1)
nl --send >/dev/null 2>&1; rc=$?
key_ok=$(grep -o 'fleet-notify-[0-9-]*' "$FAKE_CALLS" | tail -1)
if [ "$rc" = 0 ] && [ -n "$key_fail" ] && [ "$key_fail" = "$key_ok" ]; then
  ok "notify: the retry after a failed send reuses the idempotency key"
else no "notify: idempotency key (rc=$rc fail='$key_fail' ok='$key_ok')"; fi

# 6. A successful send advances the watermark; the next run is silent. (The
#    send happened in 5b -- this checks what it left behind.)
nl >"$NL_HOME/o6" 2>"$NL_HOME/e6"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$NL_HOME/o6" ] && [ ! -s "$NL_HOME/e6" ] \
   && [ "$(wm event_watermark)" != "$EV5" ]; then
  ok "notify: a successful send advances the watermark and quiets the next run"
else no "notify: post-send silence (rc=$rc out='$(cat "$NL_HOME/o6")')"; fi

# 7. Twenty verdicts in one round are one message, not twenty, and the message
#    has a ceiling.
for i in $(seq 1 20); do
  fl claim add "$NT1" "批量结论 $i 号，这条刻意写得很长很长很长很长很长很长很长很长很长很长很长很长" >/dev/null
done
fl claim verify --all-unverified --status confirmed --by 0 >/dev/null
rm -f "$FAKE_CALLS"
nl --send >/dev/null 2>&1; rc=$?
sent=$(backend_calls)
if [ "$rc" = 0 ] && [ "$sent" = 1 ]; then
  ok "notify: twenty verdicts in one round go out as a single message"
else no "notify: one message per round (rc=$rc calls=$sent)"; fi

# 7b. Same increment, rendered rather than sent, so the fold is inspectable.
#     (Re-verifying is not possible -- the claims are confirmed now -- so the
#     message is rebuilt by rewinding this script's own watermark.)
python3 - "$NL_STATE" "$EV5" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["event_watermark"]=int(sys.argv[2])
json.dump(d,open(p,"w"))
PY
nl >"$NL_HOME/o7" 2>/dev/null
body=$(grep -c '^' "$NL_HOME/o7")
bytes=$(wc -c <"$NL_HOME/o7")
if [ "$body" -le 13 ] && [ "$bytes" -lt 4096 ] \
   && grep -q '^…+[0-9]* 条$' "$NL_HOME/o7" \
   && [ "$(head -1 "$NL_HOME/o7" | grep -c '^fleet · [0-9]* 条')" = 1 ]; then
  ok "notify: an oversized round folds to a capped message plus '+N 条'"
else no "notify: fold (lines=$body bytes=$bytes)"; printf '%s\n' "$(cat "$NL_HOME/o7")"; fi

# 11. The commander's watermark is the whole point of keeping our own: a
#     notifier that consumed it would silently eat what the commander must see.
fl since >/dev/null
CWM=$(sqlite3 "$NL_HOME/fleet.db" "SELECT value FROM watermark WHERE consumer='default' AND scope='all'")
for _ in 1 2 3; do nl >/dev/null 2>&1; done
CWM2=$(sqlite3 "$NL_HOME/fleet.db" "SELECT value FROM watermark WHERE consumer='default' AND scope='all'")
if [ -n "$CWM" ] && [ "$CWM" = "$CWM2" ]; then
  ok "notify: repeated runs never advance the commander's watermark"
else no "notify: commander watermark moved ($CWM -> $CWM2)"; fi

# 12. A watermark counts event ids in one ledger. Reusing it against another
#     would skip real events or replay a stranger's history.
OTHER="$TMP/nl-other"; mkdir -p "$OTHER"
FLEET_HOME="$OTHER" "$FLEET_BIN" init >/dev/null
FLEET_HOME="$OTHER" python3 "$NOTIFY" --fleet-bin "$FLEET_BIN" \
  --lark-bin "$NL_HOME/fake-lark" --state "$NL_STATE" --config "$NL_CONF" \
  >"$NL_HOME/o12" 2>"$NL_HOME/e12"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$NL_HOME/o12" ] && grep -q 'from event' "$NL_HOME/e12" \
   && [ "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['fleet_home'])" "$NL_STATE")" = "$OTHER" ]; then
  ok "notify: state recorded against another ledger is not reused"
else no "notify: ledger identity guard (rc=$rc err='$(cat "$NL_HOME/e12")')"; fi

# ---------------------------------------------------------------------------
# contrib/surface-decisions.py
#
# The state override keeps this suite away from the real Stop-hook state in
# ~/.claude/hooks. Each invocation also gets an isolated ledger.
# ---------------------------------------------------------------------------

SURFACE="$ROOT/contrib/surface-decisions.py"
SD_HOME="$TMP/surface"
SD_STATE="$TMP/surface-state/seen.json"
mkdir -p "$SD_HOME"
# </dev/null on every call: the hook reads stdin (Stop passes JSON there),
# and without it the suite blocks forever whenever it is run with an open
# stdin -- a background shell, a CI runner, a pipeline.
sd(){ FLEET_HOME="$SD_HOME" FLEET_SURFACE_STATE="$SD_STATE" python3 "$SURFACE" </dev/null; }
sd_decide(){ FLEET_HOME="$SD_HOME" "$FLEET_BIN" decide "$1" --needs-user; }

MISSING_HOME="$TMP/no-such-ledger"
FLEET_HOME="$MISSING_HOME" FLEET_SURFACE_STATE="$SD_STATE" python3 "$SURFACE" \
  </dev/null >"$TMP/sd1" 2>"$TMP/sd1e"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/sd1" ] && [ ! -s "$TMP/sd1e" ]; then
  ok "surface: missing ledger is silent and exits 0"
else no "surface: missing ledger (rc=$rc)"; fi

FLEET_HOME="$SD_HOME" "$FLEET_BIN" init >/dev/null
sd >"$TMP/sd2" 2>"$TMP/sd2e"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/sd2" ] && [ ! -s "$TMP/sd2e" ]; then
  ok "surface: no unresolved needs-user decisions is silent"
else no "surface: empty decision set (rc=$rc)"; fi

SD1=$(sd_decide "first unanswered question")
sd >"$TMP/sd3" 2>"$TMP/sd3e"; rc=$?
if [ "$rc" = 0 ] && python3 -m json.tool "$TMP/sd3" >/dev/null \
   && python3 - "$TMP/sd3" "$SD1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["decision"] == "block" and f"decision {sys.argv[2]}:" in d["reason"]
PY
then ok "surface: one fresh decision emits a valid block JSON naming its id"
else no "surface: first decision (rc=$rc out='$(cat "$TMP/sd3")')"; fi

sd >"$TMP/sd4" 2>"$TMP/sd4e"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/sd4" ] && [ ! -s "$TMP/sd4e" ]; then
  ok "surface: a surfaced decision is shown only once"
else no "surface: one-shot state (rc=$rc out='$(cat "$TMP/sd4")')"; fi

SD2=$(sd_decide "second unanswered question")
SD3=$(sd_decide "third unanswered question")
sd >/dev/null 2>&1
SD4=$(sd_decide "fourth and newly added question")
sd >"$TMP/sd5" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && python3 - "$TMP/sd5" "$SD1" "$SD2" "$SD3" "$SD4" <<'PY'
import json,re,sys
r=json.load(open(sys.argv[1]))["reason"]
assert "fleet has 1 unanswered decision(s)" in r
assert f"decision {sys.argv[5]}:" in r
assert all(f"decision {old}:" not in r for old in sys.argv[2:5])
PY
then ok "surface: after three seen ids only one newly added decision is counted"
else no "surface: incremental count (rc=$rc out='$(cat "$TMP/sd5")')"; fi

for i in $(seq 1 6); do sd_decide "overflow question $i" >/dev/null; done
sd >"$TMP/sd6" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && python3 - "$TMP/sd6" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["reason"]
details=[line for line in r.splitlines() if line.startswith("  decision ")]
assert len(details) == 4, details
assert "fleet has 6 unanswered decision(s)" in r
assert "(+2 more --" in r
PY
then ok "surface: overflow shows four details and the true remaining count"
else no "surface: overflow cap/count (rc=$rc out='$(cat "$TMP/sd6")')"; fi

# Keep a read transaction open while adding a row so fleet.db-wal exists and
# both database files can be hashed, rather than treating a missing WAL as a
# stand-in for immutability.
KEEP_READY="$TMP/keeper-ready"; KEEP_STOP="$TMP/keeper-stop"
python3 - "$SD_HOME/fleet.db" "$KEEP_READY" "$KEEP_STOP" <<'PY' &
import pathlib,sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); c.execute("BEGIN"); c.execute("SELECT count(*) FROM decision").fetchone()
pathlib.Path(sys.argv[2]).touch()
while not pathlib.Path(sys.argv[3]).exists(): time.sleep(.02)
c.close()
PY
KEEP_PID=$!
while [ ! -e "$KEEP_READY" ]; do sleep .02; done
sd_decide "readonly hash question" >/dev/null
before_db=$(sha256sum "$SD_HOME/fleet.db" | cut -d' ' -f1)
before_wal=$(sha256sum "$SD_HOME/fleet.db-wal" | cut -d' ' -f1)
sd >"$TMP/sd7" 2>/dev/null; rc=$?
after_db=$(sha256sum "$SD_HOME/fleet.db" | cut -d' ' -f1)
after_wal=$(sha256sum "$SD_HOME/fleet.db-wal" | cut -d' ' -f1)
touch "$KEEP_STOP"; wait "$KEEP_PID"
if [ "$rc" = 0 ] && [ "$before_db" = "$after_db" ] && [ "$before_wal" = "$after_wal" ]; then
  ok "surface: read-only query leaves fleet.db and fleet.db-wal hashes unchanged"
else no "surface: ledger hashes changed (db=$before_db/$after_db wal=$before_wal/$after_wal)"; fi

sd_decide "must not repeat when state cannot be saved" >/dev/null
FLEET_HOME="$SD_HOME" FLEET_SURFACE_STATE="/proc/fleet-surface-state/seen.json" \
  python3 "$SURFACE" </dev/null >"$TMP/sd8" 2>"$TMP/sd8e"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/sd8" ] && [ ! -s "$TMP/sd8e" ]; then
  ok "surface: unwritable state suppresses block and exits 0"
else no "surface: unwritable state (rc=$rc out='$(cat "$TMP/sd8")')"; fi

SPECIAL_ID=$(sd_decide $'quote "here"\n第二行中文')
sd >"$TMP/sd9" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && python3 -m json.tool "$TMP/sd9" >/dev/null \
   && python3 - "$TMP/sd9" "$SPECIAL_ID" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["reason"]
assert f"decision {sys.argv[2]}:" in r and 'quote "here"' in r and "第二行中文" in r
PY
then ok "surface: quotes, newlines and Chinese remain valid JSON"
else no "surface: special question JSON (rc=$rc out='$(cat "$TMP/sd9")')"; fi


# --- cwd scoping and per-session seen state -------------------------------
# Stop passes {"session_id","cwd"} on stdin. A decision belongs to sessions
# whose cwd contains or is contained by its task's cwd; the seen-list is per
# session so the first session to Stop cannot swallow another session's card.
# Fresh ledger: the cases above filed a dozen task-less decisions, which are
# homeless and therefore shown everywhere -- on that ledger a scoped decision
# would sit past the 4-card cap and the assertions below could not see it.
SD_HOME2="$TMP/surface2"; mkdir -p "$SD_HOME2"
FLEET_HOME="$SD_HOME2" "$FLEET_BIN" init >/dev/null
SD_STATE2="$TMP/surface-state/scoped.json"
sdin(){ printf '%s' "$1" | FLEET_HOME="$SD_HOME2" FLEET_SURFACE_STATE="$SD_STATE2" python3 "$SURFACE"; }
mkdir -p "$TMP/proj-a/sub" "$TMP/proj-b"
printf 'exit 0\n' > "$TMP/spec_sd.sh"
TA=$(FLEET_HOME="$SD_HOME2" "$FLEET_BIN" add "scoped task" --channel shell --spec "$TMP/spec_sd.sh" --cwd "$TMP/proj-a")
SDA=$(FLEET_HOME="$SD_HOME2" "$FLEET_BIN" decide "question raised inside proj-a" --needs-user --task "$TA")

sdin "{\"session_id\":\"s1\",\"cwd\":\"$TMP/proj-b\"}" >"$TMP/sd10" 2>"$TMP/sd10e"; rc=$?
if [ "$rc" = 0 ] && ! grep -q "decision $SDA:" "$TMP/sd10" && [ ! -s "$TMP/sd10e" ]; then
  ok "surface: a session in another cwd does not see proj-a's decision"
else no "surface: cwd mismatch leaked (rc=$rc out='$(cat "$TMP/sd10")')"; fi

sdin "{\"session_id\":\"s1\",\"cwd\":\"$TMP/proj-a\"}" >"$TMP/sd11" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && grep -q "decision $SDA:" "$TMP/sd11"; then
  ok "surface: the session whose cwd matches gets the card"
else no "surface: cwd match (rc=$rc out='$(cat "$TMP/sd11")')"; fi

sdin "{\"session_id\":\"s1\",\"cwd\":\"$TMP/proj-a\"}" >"$TMP/sd12" 2>/dev/null; rc=$?
sdin "{\"session_id\":\"s2\",\"cwd\":\"$TMP/proj-a/sub\"}" >"$TMP/sd13" 2>/dev/null; rc2=$?
# sd12 is not empty any more: the decision is seen, so the awake gate below
# takes over and blocks on the still-queued fixture task. What this case is
# about is that no *decision* is surfaced to s1 a second time.
if [ "$rc" = 0 ] && ! grep -q "decision $SDA:" "$TMP/sd12" && [ "$rc2" = 0 ] && grep -q "decision $SDA:" "$TMP/sd13"; then
  ok "surface: seen is per session -- s1 gets no repeat decision, s2 (child cwd) still gets it"
else no "surface: per-session seen (s1='$(cat "$TMP/sd12")' s2='$(cat "$TMP/sd13")')"; fi

TB=$(FLEET_HOME="$SD_HOME2" "$FLEET_BIN" add "parent task" --channel shell --spec "$TMP/spec_sd.sh" --cwd "$TMP/proj-a/sub")
SDB=$(FLEET_HOME="$SD_HOME2" "$FLEET_BIN" decide "raised in a subdirectory" --needs-user --task "$TB")
sdin "{\"session_id\":\"s3\",\"cwd\":\"$TMP/proj-a\"}" >"$TMP/sd14" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && grep -q "decision $SDB:" "$TMP/sd14"; then
  ok "surface: a session in the parent cwd sees a decision raised in a subdirectory"
else no "surface: parent-cwd containment (rc=$rc out='$(cat "$TMP/sd14")')"; fi

SDG=$(FLEET_HOME="$SD_HOME2" "$FLEET_BIN" decide "homeless question, no task no goal" --needs-user)
sdin "{\"session_id\":\"s4\",\"cwd\":\"$TMP/proj-b\"}" >"$TMP/sd15" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && grep -q "decision $SDG:" "$TMP/sd15" && ! grep -q "decision $SDA:" "$TMP/sd15"; then
  ok "surface: a decision with no task and no goal is shown everywhere; scoped ones still filtered"
else no "surface: homeless decision (rc=$rc out='$(cat "$TMP/sd15")')"; fi

printf '[%s, %s, %s]' "$SDA" "$SDB" "$SDG" > "$SD_STATE2"
sdin "{\"session_id\":\"s5\",\"cwd\":\"$TMP/proj-a\"}" >"$TMP/sd16" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && grep -q "decision $SDA:" "$TMP/sd16" && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d,dict) and 's5' in d" "$SD_STATE2"; then
  ok "surface: a legacy flat seen-list is discarded, not inherited, and the file is rewritten per session"
else no "surface: legacy state (rc=$rc out='$(cat "$TMP/sd16")' state='$(cat "$SD_STATE2")')"; fi

# --- the awake gate: in-flight work with nothing watching it ---------------
#
# fleet never calls back (`_finish` writes the ledger and returns), so a turn
# that ends with tasks in flight and no live `fleet wait` armed strands them
# until the user next types. These cases drive the /proc side with real
# processes: a stub would only prove the parser, and the two things that
# actually went wrong in the field -- an orphaned wait, a wait on another
# ledger -- are both facts about the process table.

SD_HOME3="$TMP/surface3"; mkdir -p "$SD_HOME3" "$TMP/proj-c" "$TMP/proj-d" "$TMP/proj-e" "$TMP/wt-own"
FLEET_HOME="$SD_HOME3" "$FLEET_BIN" init >/dev/null
SD_STATE3="$TMP/surface-state/awake.json"
aw(){ printf '{"session_id":"%s","cwd":"%s"}' "$1" "$2" \
  | FLEET_HOME="$SD_HOME3" FLEET_SURFACE_STATE="$SD_STATE3" python3 "$SURFACE"; }
# The orphan cases below have to find their own wait in a global process table,
# and the mutation runner runs several copies of this suite at once -- with
# identical ledgers, identical task ids and identical argv. Identity, not a
# magic number: a candidate counts only if its own FLEET_HOME is this run's.
# (A `$$`-derived --timeout was the first fix; pids are sequential and one run
# consumes more of them than the modulus, so two runs spaced by a multiple of
# it collide deterministically -- cross-family review of fcdd403, F8.)
UNIQ=20000
find_wait(){  # $1 = task id -> pid of the wait for THIS suite's ledger, or ""
  local pid
  for pid in $(pgrep -f "fleet wait --ids $1 --timeout $UNIQ" 2>/dev/null); do
    if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
       | grep -qx "FLEET_HOME=$SD_HOME3"; then echo "$pid"; return; fi
  done
}
AW1=$(FLEET_HOME="$SD_HOME3" "$FLEET_BIN" add "in flight" --channel shell --spec "$TMP/spec_sd.sh" --cwd "$TMP/proj-c")

aw a1 "$TMP/proj-c" >"$TMP/aw1" 2>"$TMP/aw1e"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/aw1e" ] && python3 - "$TMP/aw1" "$AW1" <<'AWPY'
import json,sys
d=json.load(open(sys.argv[1])); r=d["reason"]
assert d["decision"]=="block"
assert f"task {sys.argv[2]} queued(shell)" in r, r
assert f"fleet wait --any --ids {sys.argv[2]} " in r, r
assert "daemon is not running" in r, r
AWPY
then ok "awake: an unwatched in-flight task blocks, naming it, the wait to arm and the stopped daemon"
else no "awake: unwatched task (rc=$rc out='$(cat "$TMP/aw1")')"; fi

aw a2 "$TMP/proj-e" >"$TMP/aw2" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/aw2" ]; then
  ok "awake: a session in an unrelated cwd is not told about it"
else no "awake: cwd scoping leaked (rc=$rc out='$(cat "$TMP/aw2")')"; fi

FLEET_HOME="$SD_HOME3" "$FLEET_BIN" wait --ids "$AW1" --timeout 20 >/dev/null 2>&1 &
WPID=$!
sleep 0.6
aw a3 "$TMP/proj-c" >"$TMP/aw3" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/aw3" ]; then
  ok "awake: a live wait naming the task suppresses the block"
else no "awake: live watcher ignored (rc=$rc out='$(cat "$TMP/aw3")')"; fi
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# setsid --fork detaches it, so its parent is gone and it is adopted by init
# or (here) systemd --user. Such a wait can keep polling even though its exit
# reaches nobody.
FLEET_HOME="$SD_HOME3" setsid --fork "$FLEET_BIN" wait --ids "$AW1" --timeout "$UNIQ" >/dev/null 2>&1
OPID=""
for _ in $(seq 1 60); do
  OPID=$(find_wait "$AW1")
  [ -n "$OPID" ] && break
  sleep 0.25
done
aw a4 "$TMP/proj-c" >"$TMP/aw4" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ -n "$OPID" ] && grep -q "task $AW1 queued" "$TMP/aw4"; then
  ok "awake: an orphaned wait does not count as a watcher"
else no "awake: orphan counted (rc=$rc pid='$OPID' out='$(cat "$TMP/aw4")')"; fi
[ -n "$OPID" ] && kill "$OPID" 2>/dev/null

SD_HOME4="$TMP/surface4"; mkdir -p "$SD_HOME4"
FLEET_HOME="$SD_HOME4" "$FLEET_BIN" init >/dev/null
FLEET_HOME="$SD_HOME4" "$FLEET_BIN" wait --ids "$AW1" --timeout 20 >/dev/null 2>&1 &
WPID2=$!
sleep 0.6
aw a5 "$TMP/proj-c" >"$TMP/aw5" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && grep -q "task $AW1 queued" "$TMP/aw5"; then
  ok "awake: a wait on another FLEET_HOME does not count, id collision or not"
else no "awake: foreign-ledger watcher counted (rc=$rc out='$(cat "$TMP/aw5")')"; fi
kill "$WPID2" 2>/dev/null; wait "$WPID2" 2>/dev/null

for i in 1 2 3; do aw a6 "$TMP/proj-c" >"$TMP/aw6_$i" 2>/dev/null; done
aw a6 "$TMP/proj-c" >"$TMP/aw6_4" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ -s "$TMP/aw6_1" ] && [ -s "$TMP/aw6_3" ] && [ ! -s "$TMP/aw6_4" ]; then
  ok "awake: the same unwatched set blocks three times, then lets the session sleep"
else no "awake: cap (1='$(cat "$TMP/aw6_1")' 3='$(cat "$TMP/aw6_3")' 4='$(cat "$TMP/aw6_4")')"; fi

# A --review-of task runs inside the reviewed task's worktree, so its cwd is
# under ~/.fleet/worktrees and belongs to no session until it is followed
# through to the owner's cwd.
OWNER=$(FLEET_HOME="$SD_HOME3" "$FLEET_BIN" add "owner" --channel shell --spec "$TMP/spec_sd.sh" --cwd "$TMP/proj-d")
python3 - "$SD_HOME3/fleet.db" "$OWNER" "$TMP/wt-own" <<'WTPY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute("UPDATE task SET worktree=? WHERE id=?",(sys.argv[3],int(sys.argv[2]))); c.commit()
WTPY
REV=$(FLEET_HOME="$SD_HOME3" "$FLEET_BIN" add "review" --channel shell --spec "$TMP/spec_sd.sh" --cwd "$TMP/wt-own")
aw a7 "$TMP/proj-d" >"$TMP/aw7" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && grep -q "task $REV queued" "$TMP/aw7" && grep -q "task $OWNER queued" "$TMP/aw7"; then
  ok "awake: a task running in another task's worktree is attributed to that task's cwd"
else no "awake: worktree attribution (rc=$rc out='$(cat "$TMP/aw7")')"; fi

# A wait with no --ids snapshots the queued/running set once at startup, so a
# task enqueued afterwards is not in its list. One second of daylight: the
# comparison is on whole seconds.
FLEET_HOME="$SD_HOME3" "$FLEET_BIN" wait --timeout 20 >/dev/null 2>&1 &
WPID3=$!
sleep 1.4
LATE=$(FLEET_HOME="$SD_HOME3" "$FLEET_BIN" add "enqueued later" --channel shell --spec "$TMP/spec_sd.sh" --cwd "$TMP/proj-c")
aw a8 "$TMP/proj-c" >"$TMP/aw8" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && grep -q "task $LATE queued" "$TMP/aw8" && ! grep -q "task $AW1 queued" "$TMP/aw8"; then
  ok "awake: a no-ids wait covers what existed when it started, not what came later"
else no "awake: no-ids snapshot (rc=$rc out='$(cat "$TMP/aw8")')"; fi
kill "$WPID3" 2>/dev/null; wait "$WPID3" 2>/dev/null

# --- decisions folded into "(+N more)" must come back ----------------------
SD_HOME5="$TMP/surface5"; mkdir -p "$SD_HOME5"
FLEET_HOME="$SD_HOME5" "$FLEET_BIN" init >/dev/null
SD_STATE5="$TMP/surface-state/overflow.json"
of(){ printf '%s' '{"session_id":"o1"}' \
  | FLEET_HOME="$SD_HOME5" FLEET_SURFACE_STATE="$SD_STATE5" python3 "$SURFACE"; }
for i in 1 2 3 4 5 6; do
  OF6=$(FLEET_HOME="$SD_HOME5" "$FLEET_BIN" decide "overflow question $i" --needs-user)
done
of >"$TMP/of1" 2>/dev/null
of >"$TMP/of2" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && grep -q "(+2 more" "$TMP/of1" && grep -q "decision $OF6:" "$TMP/of2"; then
  ok "surface: ids folded into (+N more) are not marked seen and come back next Stop"
else no "surface: overflow seen-marking (rc=$rc first='$(cat "$TMP/of1")' second='$(cat "$TMP/of2")')"; fi

# --- contrib/wiring/install.sh ---------------------------------------------
#
# The glue used to exist only as prose in contrib/README.md, which is why the
# two timers it described had never been installed on the machine it was
# written on. These cases drive the installer against a temp $HOME with a
# recording stand-in for systemctl: what is asserted is that a dry run really
# is inert, that --apply merges into settings.json instead of overwriting it,
# and that running it twice is a no-op.

INS="$ROOT/contrib/wiring/install.sh"
IH="$TMP/inst-home"; mkdir -p "$IH"
cat >"$TMP/bin/fake-systemctl" <<'FSC'
#!/usr/bin/env bash
echo "$*" >> "$SYSTEMCTL_LOG"
FSC
chmod +x "$TMP/bin/fake-systemctl"
export SYSTEMCTL_LOG="$TMP/systemctl.log"
: > "$SYSTEMCTL_LOG"
ins(){ HOME="$IH" XDG_CONFIG_HOME="$IH/.config" \
  FLEET_WIRING_SYSTEMCTL="$TMP/bin/fake-systemctl" bash "$INS" "$@"; }

ins >"$TMP/in1" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$IH/.claude/settings.json" ] && [ ! -d "$IH/.config/systemd" ] \
   && [ ! -s "$SYSTEMCTL_LOG" ] && grep -q "dry run" "$TMP/in1"; then
  ok "wiring: a dry run writes no file, creates no unit and calls no systemctl"
else no "wiring: dry run was not inert (rc=$rc out='$(cat "$TMP/in1")')"; fi

mkdir -p "$IH/.claude"
printf '{"permissions":{"allow":["Bash(ls:*)"]},"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"true"}]}]}}' \
  >"$IH/.claude/settings.json"
ins --apply --only stop-hook >"$TMP/in2" 2>&1; rc=$?
if [ "$rc" = 0 ] && python3 - "$IH/.claude/settings.json" "$ROOT" <<'INPY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["permissions"]["allow"] == ["Bash(ls:*)"], d          # unrelated keys survive
assert "PreToolUse" in d["hooks"], d                            # other hooks survive
cmds=[h["command"] for g in d["hooks"]["Stop"] for h in g["hooks"]]
assert cmds == [f"python3 {sys.argv[2]}/contrib/surface-decisions.py"], cmds
INPY
then ok "wiring: --apply merges the Stop hook in, keeping other hooks and settings"
else no "wiring: hook merge (rc=$rc out='$(cat "$TMP/in2")')"; fi

before=$(sha256sum <"$IH/.claude/settings.json")
ins --apply --only stop-hook >"$TMP/in3" 2>&1; rc=$?
after=$(sha256sum <"$IH/.claude/settings.json")
if [ "$rc" = 0 ] && [ "$before" = "$after" ] && grep -q "^= Stop hook already points" "$TMP/in3" \
   && [ "$(ls "$IH/.claude/" | grep -c 'settings.json.bak-')" = 1 ]; then
  ok "wiring: re-running --apply is a no-op, not a second hook and not a second backup"
else no "wiring: idempotence (rc=$rc out='$(cat "$TMP/in3")' baks=$(ls "$IH/.claude/"))"; fi

printf 'not json at all' >"$IH/.claude/settings.json"
ins --apply --only stop-hook >"$TMP/in4" 2>&1; rc=$?
if [ "$rc" != 0 ] && [ "$(cat "$IH/.claude/settings.json")" = "not json at all" ] \
   && grep -q "left alone" "$TMP/in4"; then
  ok "wiring: settings.json that does not parse is reported and never rewritten"
else no "wiring: unparseable settings (rc=$rc out='$(cat "$TMP/in4")')"; fi

: > "$SYSTEMCTL_LOG"
ins --apply --only notify >"$TMP/in5" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ -f "$IH/.config/systemd/user/fleet-notify-lark.timer" ] \
   && ! grep -q "enable" "$SYSTEMCTL_LOG" && grep -q "names no chat_id" "$TMP/in5" \
   && grep -q "$ROOT/contrib/notify-lark.py" "$IH/.config/systemd/user/fleet-notify-lark.service"; then
  ok "wiring: notify units land with @CONTRIB@ rendered, but the timer stays off without a target"
else no "wiring: notify without target (rc=$rc out='$(cat "$TMP/in5")' log='$(cat "$SYSTEMCTL_LOG")')"; fi

python3 -c "import json,sys; json.dump({'chat_id':'oc_x'},open(sys.argv[1],'w'))" \
  "$IH/.config/fleet-contrib/notify-lark.json"
: > "$SYSTEMCTL_LOG"
ins --apply --only notify >"$TMP/in6" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -q "enable --now fleet-notify-lark.timer" "$SYSTEMCTL_LOG"; then
  ok "wiring: once the config names a target the timer is enabled"
else no "wiring: notify with target (rc=$rc out='$(cat "$TMP/in6")' log='$(cat "$SYSTEMCTL_LOG")')"; fi

# --- the daemon as a persistent systemd user service ------------------------
#
# `fleet daemon start` used to launch a one-shot background process: whoever
# stopped it, a crash, or a reboot left it gone, and `stop` wrote no log so the
# cause was unrecoverable. The wiring now installs a Restart=always user unit.
# These cases assert the dry run lists the unit, --apply enables it through
# the recorder, a missing/failing systemctl is reported rather than fatal, and
# the template ships no hardcoded home path.

# D1: a dry run names the unit and the enable it would run, but writes nothing
#     and calls no systemctl.
: > "$SYSTEMCTL_LOG"
rm -f "$IH/.config/systemd/user/fleet-daemon.service"
ins --only daemon >"$TMP/ind1" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$IH/.config/systemd/user/fleet-daemon.service" ] \
   && [ ! -s "$SYSTEMCTL_LOG" ] \
   && grep -q "would write .*fleet-daemon.service" "$TMP/ind1" \
   && grep -q "enable --now fleet-daemon.service" "$TMP/ind1" \
   && grep -q "fleet daemon stop" "$TMP/ind1"; then
  ok "wiring: daemon dry run lists the unit, the enable, and the stop=restart note"
else no "wiring: daemon dry run (rc=$rc out='$(cat "$TMP/ind1")' log='$(cat "$SYSTEMCTL_LOG")')"; fi

# D2: --apply writes the rendered unit and runs `enable --now`; the rendered
#     ExecStart points at THIS repo's bin/fleet and carries no hardcoded home.
: > "$SYSTEMCTL_LOG"
ins --apply --only daemon >"$TMP/ind2" 2>&1; rc=$?
DUNIT="$IH/.config/systemd/user/fleet-daemon.service"
if [ "$rc" = 0 ] && [ -f "$DUNIT" ] \
   && grep -q -- "--user enable --now fleet-daemon.service" "$SYSTEMCTL_LOG" \
   && grep -qF "$ROOT/bin/fleet" "$DUNIT" \
   && grep -q "Restart=always" "$DUNIT" && grep -q "WantedBy=default.target" "$DUNIT" \
   && ! grep -qE "/home/[a-z]+|/Users/|$HOME" "$ROOT/contrib/wiring/fleet-daemon.service"; then
  ok "wiring: --apply installs the daemon unit rendered to this repo and enables it"
else no "wiring: daemon apply (rc=$rc out='$(cat "$TMP/ind2")' log='$(cat "$SYSTEMCTL_LOG")')"; fi

# D3: the template in the repo contains no concrete user/home path at all --
#     every path is a specifier (%h) or the install-time @REPO@ marker.
if ! grep -qE "/home/|/Users/|/root/" "$ROOT/contrib/wiring/fleet-daemon.service" \
   && grep -q "@REPO@/bin/fleet" "$ROOT/contrib/wiring/fleet-daemon.service" \
   && grep -q "FLEET_HOME=%h/.fleet" "$ROOT/contrib/wiring/fleet-daemon.service"; then
  ok "wiring: daemon template ships no hardcoded user path (only %h and @REPO@)"
else no "wiring: daemon template hardcodes a path ($(grep -nE '/home/|/Users/|/root/' "$ROOT/contrib/wiring/fleet-daemon.service"))"; fi

# D4: re-running --apply is a no-op: the unit already renders identically.
before=$(sha256sum <"$DUNIT")
: > "$SYSTEMCTL_LOG"
ins --apply --only daemon >"$TMP/ind4" 2>&1; rc=$?
after=$(sha256sum <"$DUNIT")
if [ "$rc" = 0 ] && [ "$before" = "$after" ] && grep -q "^= .*fleet-daemon.service" "$TMP/ind4"; then
  ok "wiring: daemon unit re-apply is a no-op (=, not a rewrite)"
else no "wiring: daemon idempotence (rc=$rc out='$(cat "$TMP/ind4")')"; fi

# D5: no systemctl on PATH is reported with '!', not fatal -- the unit file is
#     still the durable artifact. FLEET_WIRING_SYSTEMCTL points at nothing.
rm -f "$DUNIT"
HOME="$IH" XDG_CONFIG_HOME="$IH/.config" FLEET_WIRING_SYSTEMCTL="fleet-no-such-systemctl-xyz" \
  bash "$INS" --apply --only daemon >"$TMP/ind5" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ -f "$DUNIT" ] && grep -q "^! .*no systemctl" "$TMP/ind5"; then
  ok "wiring: daemon enable without systemctl is a non-fatal '!' and still writes the unit"
else no "wiring: daemon no-systemctl (rc=$rc out='$(cat "$TMP/ind5")')"; fi

# D6: a failing systemctl (user bus absent / enable refused) is likewise '!'
#     and non-fatal for the daemon part.
cat >"$TMP/bin/fail-systemctl" <<'FSC'
#!/usr/bin/env bash
echo "$*" >> "$SYSTEMCTL_LOG"
exit 1
FSC
chmod +x "$TMP/bin/fail-systemctl"
rm -f "$DUNIT"
: > "$SYSTEMCTL_LOG"
HOME="$IH" XDG_CONFIG_HOME="$IH/.config" FLEET_WIRING_SYSTEMCTL="$TMP/bin/fail-systemctl" \
  bash "$INS" --apply --only daemon >"$TMP/ind6" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ -f "$DUNIT" ] \
   && grep -q -- "--user enable --now fleet-daemon.service" "$SYSTEMCTL_LOG" \
   && grep -q "^! .*enable --now fleet-daemon.service" "$TMP/ind6"; then
  ok "wiring: a failed daemon enable is reported '!' and non-fatal"
else no "wiring: daemon enable failure (rc=$rc out='$(cat "$TMP/ind6")' log='$(cat "$SYSTEMCTL_LOG")')"; fi

# --- paths the installer does not get to constrain -------------------------
# A checkout path can contain a space (breaks the shell command the harness
# runs) or an '&' (means "the whole match" in a sed replacement, so the unit
# used to end up pointing at a literal @CONTRIB@). Both found by cross-family
# review of 258caad; neither was reachable from the cases above, which all run
# out of a tame $ROOT.
# The path carries every character that has bitten this renderer: & (sed's
# "whole match" and bash 5.2's too), a space (systemd word-splits ExecStart),
# a single quote (systemd: "Unbalanced quoting ... unit will not be started")
# and % (a unit specifier, quoted or not).
ODD="$TMP/odd & dir 'q' 100%x"
mkdir -p "$ODD"
cp -r "$ROOT/contrib" "$ODD/contrib"
IH2="$TMP/inst-home2"; mkdir -p "$IH2"
: > "$SYSTEMCTL_LOG"
HOME="$IH2" XDG_CONFIG_HOME="$IH2/.config" FLEET_WIRING_SYSTEMCTL="$TMP/bin/fake-systemctl" \
  bash "$ODD/contrib/wiring/install.sh" --apply --only stop-hook,activity >"$TMP/in7" 2>&1; rc=$?
UNIT2="$IH2/.config/systemd/user/fleet-activity.service"
# Bound to the two things that actually decide whether this works -- systemd's
# own parser, and the argv the unit expands to -- not to the presence of a
# substring. Grepping the path out of the file passed happily on a unit
# systemd refuses to start, which is how the previous round shipped a broken
# renderer behind a green suite (cross-family review of fcdd403, F9).
SDV_OUT="$TMP/sdverify.txt"
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "$UNIT2" >"$SDV_OUT" 2>&1
  grep -i "fleet-activity" "$SDV_OUT" > "$TMP/sdverify.mine" || : > "$TMP/sdverify.mine"
else
  echo "systemd-analyze absent" > "$TMP/sdverify.mine"   # nothing to complain
fi
if [ "$rc" = 0 ] && [ ! -s "$TMP/sdverify.mine" -o -n "$(grep -c absent "$TMP/sdverify.mine")" ] \
   && ! grep -qi "fatal error\|Unbalanced\|bad unit file" "$TMP/sdverify.mine" \
   && python3 - "$IH2/.claude/settings.json" "$ODD/contrib" "$UNIT2" <<'ODDPY'
import json, shlex, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for g in d["hooks"]["Stop"] for h in g["hooks"]]
want = "python3 " + shlex.quote(f"{sys.argv[2]}/surface-decisions.py")
assert cmds == [want], (cmds, want)
# the hook command is handed to a shell: it has to survive one
assert shlex.split(cmds[0]) == ["python3", f"{sys.argv[2]}/surface-decisions.py"], shlex.split(cmds[0])
# the unit is handed to systemd: %% is its escape for a literal %, and the
# quoting rules are close enough to shlex's for the characters at issue
exe = [l.split("=", 1)[1].strip() for l in open(sys.argv[3]) if l.startswith("ExecStart=")]
assert len(exe) == 1, exe
assert "%%" in exe[0], exe[0]      # % is a specifier; systemd's escape is %%
argv = shlex.split(exe[0].replace("%%", "%"))
assert argv == ["/usr/bin/env", "python3", f"{sys.argv[2]}/publish-activity.py"], argv
ODDPY
then
  ok "wiring: a path with space/&/quote/% survives the hook command, systemd's parser and the argv"
else no "wiring: odd path (rc=$rc unit='$(grep ExecStart "$UNIT2" 2>/dev/null)' sdverify='$(cat "$TMP/sdverify.mine" 2>/dev/null)')"; fi

printf '{"hooks":{"Stop":{"not":"a list"}}}' >"$IH2/.claude/settings.json"
ins2(){ HOME="$IH2" XDG_CONFIG_HOME="$IH2/.config" \
  FLEET_WIRING_SYSTEMCTL="$TMP/bin/fake-systemctl" bash "$INS" "$@"; }
ins2 --apply --only stop-hook >"$TMP/in8" 2>&1; rc=$?
if [ "$rc" != 0 ] && [ "$(cat "$IH2/.claude/settings.json")" = '{"hooks":{"Stop":{"not":"a list"}}}' ] \
   && grep -q "left alone" "$TMP/in8"; then
  ok "wiring: valid JSON of the wrong shape is refused, not tracebacked through"
else no "wiring: bad-shape settings (rc=$rc out='$(cat "$TMP/in8")' file='$(cat "$IH2/.claude/settings.json")')"; fi

# --- the same-second window a no-ids wait cannot cover ---------------------
# Both clocks are whole seconds, so a wait that started at 100.10 and a task
# created at 100.90 both read as 100; >= would call that covered. Driven
# directly because the window is a fraction of a second wide.
if python3 - "$ROOT/contrib/surface-decisions.py" <<'TIEPY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location("sd",sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# The ambiguous second resolves to "covered": a stable false block burns the
# whole cap and then leaves the gate silent, which is worse than one missed
# wake in a window that needs the wait to be armed before the task existed.
assert m._watcher_of(100, 7, [(99, None, 100.4)]) == 99      # tie: fail open
assert m._watcher_of(100, 7, [(99, None, 99.9)]) is None     # started first: not covered
assert m._watcher_of(100, 7, [(99, None, 101)]) == 99        # started later: covered
assert m._watcher_of(100, 7, [(99, None, None)]) == 99       # unknown start: fail open
assert m._watcher_of(None, 7, [(99, None, 100)]) == 99       # unknown task time: fail open
assert m._watcher_of(100, 7, [(99, {7}, 100)]) == 99         # --ids never needs the clock
# and the start clock itself has to be accurate, or "armed right after the
# enqueue" reads as "armed before it" -- the btime+ticks form was up to 1.7s
# early, which is what made the strict comparison a stable false block.
import os, subprocess, time
t0 = time.time(); pr = subprocess.Popen(["sleep", "5"]); time.sleep(0.2)
got = m._proc_start_epoch(pr.pid, m._boot_epoch()); pr.kill(); pr.wait()
assert got is not None and abs(got - t0) < 0.2, (got, t0, got - t0)
TIEPY
then ok "awake: the ambiguous second fails open, and the start clock is accurate to the ms"
else no "awake: same-second tie"; fi

# --- what the cross-family review of 258caad refuted ------------------------
# Five regressions, each with the reviewer's own reproduction. Named here
# because every one of them was outside the coverage of the cases above, which
# is the whole point of having another family look.

# C2: naming init and systemd is not enough. Any process can call
# PR_SET_CHILD_SUBREAPER and adopt orphans under its own name; the grandchild
# below is a real orphan whose parent reads as python3.
FLEET_HOME="$SD_HOME3" python3 -c "
import ctypes, os, sys, time
ctypes.CDLL('libc.so.6').prctl(36, 1, 0, 0, 0)   # PR_SET_CHILD_SUBREAPER
if os.fork() == 0:
    if os.fork() == 0:
        os.execvp(sys.argv[1], [sys.argv[1], 'wait', '--ids', sys.argv[2], '--timeout', sys.argv[3]])
    os._exit(0)                                   # middle parent leaves
time.sleep(30)                                    # stay adopting until killed
" "$FLEET_BIN" "$AW1" "$UNIQ" &
SRPID=$!
# Poll until the grandchild exists AND the middle parent has gone, i.e. the
# subreaper has actually adopted it. A fixed sleep raced under parallel load.
SRORPHAN=""; SRPARENT=""
for _ in $(seq 1 60); do
  SRORPHAN=$(find_wait "$AW1")
  if [ -n "$SRORPHAN" ]; then
    SRPARENT=$(cat "/proc/$(awk '/^PPid:/{print $2}' "/proc/$SRORPHAN/status" 2>/dev/null)/comm" 2>/dev/null)
    [ "$SRPARENT" = "python3" ] && break
  fi
  sleep 0.25
done
aw a9 "$TMP/proj-c" >"$TMP/aw9" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && [ "$SRPARENT" = "python3" ] && grep -q "task $AW1 queued" "$TMP/aw9"; then
  ok "awake: a wait adopted by an arbitrary subreaper is still an orphan"
else no "awake: subreaper orphan (rc=$rc parent='$SRPARENT' out='$(cat "$TMP/aw9")')"; fi
kill "$SRPID" 2>/dev/null; wait "$SRPID" 2>/dev/null
[ -n "$SRORPHAN" ] && kill "$SRORPHAN" 2>/dev/null

# C5, C6, and the shape of _proc_env: driven directly, because "another user's
# process" and "a six-deep worktree chain" are not things a smoke suite can
# conjure on demand.
if python3 - "$ROOT/contrib/surface-decisions.py" <<'UNITPY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("sd", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# C5: "cannot read the environment" must not read as "the variable is unset",
# or a wait on another ledger counts as watching the default one.
assert m._proc_env(1, "FLEET_HOME") is m.UNREADABLE          # pid 1 is root's
assert m._proc_env(os.getpid(), "NO_SUCH_VAR_XYZ") is None   # readable, unset

# C6: the walk is to a fixed point, not four hops. A review of a review of a
# review is an ordinary shape, and stopping halfway up returns a worktree that
# no session's cwd contains -- the silent loss this resolution exists to stop.
wts = {f"/w{i}": (i, f"/w{i+1}") for i in range(5)}
wts["/w5"] = (5, "/repo")
assert m._resolve_homes("/w0", None, wts, {}) == ["/repo"], m._resolve_homes("/w0", None, wts, {})
ring = {"/wa": (1, "/wb"), "/wb": (2, "/wa")}
assert m._resolve_homes("/wa", None, ring, {}) != [], "a cycle must still terminate"
UNITPY
then ok "awake: unreadable environ is not 'unset', and the worktree walk runs to a fixed point"
else no "awake: proc_env / deep chain"; fi

# C3: the streak is reset when the work is watched again -- including on the
# turns where the decisions gate blocks first and returns.
SD_HOME6="$TMP/surface6"; mkdir -p "$SD_HOME6" "$TMP/proj-f"
FLEET_HOME="$SD_HOME6" "$FLEET_BIN" init >/dev/null
SD_STATE6="$TMP/surface-state/reset.json"
rs(){ printf '{"session_id":"s9","cwd":"%s"}' "$TMP/proj-f" \
  | FLEET_HOME="$SD_HOME6" FLEET_SURFACE_STATE="$SD_STATE6" python3 "$SURFACE"; }
RT=$(FLEET_HOME="$SD_HOME6" "$FLEET_BIN" add "reset probe" --channel shell --spec "$TMP/spec_sd.sh" --cwd "$TMP/proj-f")
RD=$(FLEET_HOME="$SD_HOME6" "$FLEET_BIN" decide "a question that blocks first" --needs-user --task "$RT")
printf '{"_awake":{"s9":{"sig":"%s","n":3}}}' "$RT" >"$SD_STATE6"
FLEET_HOME="$SD_HOME6" "$FLEET_BIN" wait --ids "$RT" --timeout 20 >/dev/null 2>&1 &
WPID4=$!
sleep 0.6
rs >"$TMP/rs1" 2>/dev/null                       # decisions gate blocks and returns
kill "$WPID4" 2>/dev/null; wait "$WPID4" 2>/dev/null
sleep 0.3
rs >"$TMP/rs2" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && grep -q "decision" "$TMP/rs1" && grep -q "task $RT queued" "$TMP/rs2"; then
  ok "awake: a streak recorded before a watcher appeared is reset even on a decisions-gate turn"
else no "awake: streak reset (rc=$rc first='$(cat "$TMP/rs1")' second='$(cat "$TMP/rs2")')"; fi

# C8: state is JSON off disk and can hold anything. int("not-an-int") used to
# raise, the top-level catch swallowed it, and the gate went silently dead for
# that session -- silence being the exact thing it exists to remove.
# The decision has to stay marked seen, or the decisions gate blocks first and
# the awake gate never runs -- which is what this case is about.
printf '{"s9":[%s],"_awake":{"s9":{"sig":"%s","n":"not-an-int"}}}' "$RD" "$RT" >"$SD_STATE6"
rs >"$TMP/rs3" 2>"$TMP/rs3e"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/rs3e" ] && grep -q "task $RT queued" "$TMP/rs3"; then
  ok "awake: a corrupted streak counter restarts the streak instead of killing the gate"
else no "awake: corrupt streak (rc=$rc out='$(cat "$TMP/rs3")' err='$(cat "$TMP/rs3e")')"; fi

# The Stop hook is fail-open by design -- it must never take the session down
# -- but a hook that fails *quietly* is indistinguishable from a hook with
# nothing to report, which is how a plain NameError in this file once read as
# "the gate just never fires" for a whole test run. Fail-open stays; silence
# does not. Both halves are asserted: exit 0 (still open) AND a warning on
# stderr (no longer silent). Asserting only the warning would pass a hook that
# started hard-failing the session.
BADH="$TMP/badhome"
mkdir -p "$BADH"
printf 'not a database at all\n' > "$BADH/fleet.db"
FLEET_HOME="$BADH" python3 "$SURFACE" </dev/null >"$TMP/sh.out" 2>"$TMP/sh.err"
rcsh=$?
if [ "$rcsh" = 0 ] && ! [ -s "$TMP/sh.out" ] \
   && grep -q "fleet-hook warning:.*ledger read failed" "$TMP/sh.err"; then
  ok "hook: an unreadable ledger stays fail-open but says so on stderr"
else
  no "hook: an unreadable ledger stays fail-open but says so on stderr (rc=$rcsh out='$(cat "$TMP/sh.out")' err='$(cat "$TMP/sh.err")')"
fi

echo "passed $PASS / $N"
[ "$FAIL" = 0 ]
