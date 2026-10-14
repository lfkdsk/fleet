#!/usr/bin/env bash
# Commander execution cwd, private worktrees, pinned baselines, and non-Git lease.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
PASS=0 FAIL=0 N=0
SCRATCH=()
cleanup(){ cd "$ROOT" || true; for p in "${SCRATCH[@]}"; do rm -rf "$p"; done; }
trap cleanup EXIT
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }
sql(){ sqlite3 -cmd '.timeout 10000' "$FLEET_HOME/fleet.db" "$1"; }
wait_status(){
  local id="$1" want="$2" i
  for i in $(seq 1 150); do
    [ "$(sql "SELECT status FROM task WHERE id=$id")" = "$want" ] && return 0
    sleep .04
  done
  return 1
}
poll_from(){ (cd "$1" && fleet daemon run --once >/dev/null); }
new_home(){
  FLEET_HOME="$(mktemp -d /var/tmp/fleet-commander-execution-XXXXXX)"
  SCRATCH+=("$FLEET_HOME"); export FLEET_HOME
  fleet init >/dev/null
  ELSEWHERE="$FLEET_HOME/elsewhere"; mkdir -p "$ELSEWHERE"
}
new_repo(){
  REPO="$FLEET_HOME/repo"; mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email commander@example.test
  git -C "$REPO" config user.name commander
  printf 'original\n' >"$REPO/original.txt"
  git -C "$REPO" add original.txt
  git -C "$REPO" commit -qm original
}
driver(){
  local mode="$1" path
  path="$FLEET_HOME/driver-$mode.sh"
  sed "s/__P19_MODE__/$mode/" "$ROOT/tests/p19_driver.sh" >"$path"
  chmod +x "$path"
  export FLEET_COMMANDER_SHELL_SCRIPT="$path"
}

if python3 "$ROOT/tests/test_commander_execution.py" >/dev/null 2>&1; then
  ok "Python proposal and base_task fences pass"
else
  no "Python proposal and base_task fences"
fi

# A. A persisted cwd wins over the poller's cwd. Git candidates freeze HEAD at
# apply time and later launch in separate private worktrees, leaving origin put.
new_home; new_repo; driver pwdtwo
G=$(fleet goal add "persisted cwd and pin")
INITIAL=$(git -C "$REPO" rev-parse HEAD)
# A finished worker in another directory must not become the next commander's
# target merely because it is the goal's latest worker.
printf 'true\n' >"$FLEET_HOME/prior.sh"
PRIOR=$(fleet add "prior elsewhere" --channel shell --cwd "$ELSEWHERE" \
  --spec "$FLEET_HOME/prior.sh" --goal "$G")
fleet run "$PRIOR" >/dev/null; wait_status "$PRIOR" done || true
(cd "$REPO" && fleet autonomy enable "$G" --channel shell --cooldown 0 >/dev/null)
poll_from "$ELSEWHERE"
C=$(sql "SELECT id FROM task WHERE goal_id=$G AND role='commander'")
wait_status "$C" done || true
mapfile -t W < <(sql "SELECT id FROM task WHERE parent_id=$C ORDER BY id")
printf 'later\n' >"$REPO/later.txt"
git -C "$REPO" add later.txt
git -C "$REPO" commit -qm later
MOVED=$(git -C "$REPO" rev-parse HEAD)
poll_from "$ELSEWHERE"
wait_status "${W[0]}" done || true; wait_status "${W[1]}" done || true
python3 - "$FLEET_HOME/fleet.db" "$REPO" "$INITIAL" "$MOVED" "${W[0]}" "${W[1]}" \
  >"$FLEET_HOME/assert-a" <<'PY'
import pathlib,sqlite3,subprocess,sys
db,repo,initial,moved,w1,w2=sys.argv[1:]
c=sqlite3.connect(db); c.row_factory=sqlite3.Row
rows=[c.execute('SELECT * FROM task WHERE id=?',(int(i),)).fetchone() for i in (w1,w2)]
assert all(r['cwd']==str(pathlib.Path(repo).resolve()) for r in rows), rows
assert all(r['worktree'] and r['worktree_branch'] and r['base_commit']==initial for r in rows), rows
assert rows[0]['worktree'] != rows[1]['worktree']
for r in rows:
    actual=pathlib.Path(r['out_path']).read_text().strip().splitlines()[0]
    assert actual==r['worktree'], (actual,r['worktree'])
    head=subprocess.check_output(['git','-C',r['worktree'],'rev-parse','HEAD'],text=True).strip()
    assert head==initial and not (pathlib.Path(r['worktree'])/'later.txt').exists()
assert subprocess.check_output(['git','-C',repo,'rev-parse','HEAD'],text=True).strip()==moved
assert not subprocess.check_output(['git','-C',repo,'status','--porcelain','-uall'],text=True)
print('ok')
PY
A=$(cat "$FLEET_HOME/assert-a")
[ "$A" = ok ] && ok "persisted cwd survives polling elsewhere; two workers use distinct worktrees pinned before HEAD moved" || no "persisted cwd / worktree / pin ($A)"

# B. A later round can explicitly inherit the preceding worker's unique commit.
new_home; new_repo; driver commit
G=$(fleet goal add "cross-round baseline")
fleet autonomy enable "$G" --channel shell --cwd "$REPO" --cooldown 0 >/dev/null
poll_from "$ELSEWHERE"; C1=$(sql "SELECT id FROM task WHERE goal_id=$G AND role='commander'"); wait_status "$C1" done || true
W1=$(sql "SELECT id FROM task WHERE goal_id=$G AND role='worker'")
poll_from "$ELSEWHERE"; wait_status "$W1" done || true
UPSTREAM_BRANCH=$(sql "SELECT worktree_branch FROM task WHERE id=$W1")
UPSTREAM=$(git -C "$REPO" rev-parse "$UPSTREAM_BRANCH")
export FLEET_TEST_BASE_TASK="$W1"; driver base
poll_from "$ELSEWHERE"; C2=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$G AND role='commander'"); wait_status "$C2" done || true
W2=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$G AND role='worker'")
PROMPT2=$(sql "SELECT spec_path FROM task WHERE id=$C2")
if [ "$(sql "SELECT base_task||':'||base_commit FROM task WHERE id=$W2")" = "$W1:$UPSTREAM" ] \
   && grep -q "\"base_task\": $W1" "$PROMPT2"; then
  poll_from "$ELSEWHERE"; wait_status "$W2" done || true
  if [ -f "$FLEET_HOME/worktrees/task-$W2/upstream.txt" ] \
     && [ "$(git -C "$FLEET_HOME/worktrees/task-$W2" rev-parse HEAD)" = "$UPSTREAM" ]; then
    ok "base_task pins a prior round's clean worktree commit and carries its unique file"
  else no "base_task worker did not start from upstream commit"; fi
else no "base_task lineage/prompt availability missing"; fi
unset FLEET_TEST_BASE_TASK

# C. Manual commanders honor explicit cwd, then configured cwd, then caller cwd.
new_home; new_repo; driver review
PLAIN="$FLEET_HOME/manual-caller"; mkdir -p "$PLAIN"
G=$(fleet goal add "manual cwd")
T1=$(cd "$PLAIN" && fleet add --role commander --goal "$G" --channel shell \
  --cwd "$REPO" --spec "$FLEET_COMMANDER_SHELL_SCRIPT")
fleet autonomy enable "$G" --channel shell --cwd "$REPO" --cooldown 0 >/dev/null
T2=$(cd "$PLAIN" && fleet add --role commander --goal "$G" --channel shell \
  --spec "$FLEET_COMMANDER_SHELL_SCRIPT")
G2=$(fleet goal add "manual caller cwd")
T3=$(cd "$PLAIN" && fleet add --role commander --goal "$G2" --channel shell \
  --spec "$FLEET_COMMANDER_SHELL_SCRIPT")
if [ "$(sql "SELECT cwd FROM task WHERE id=$T1")" = "$REPO" ] \
   && [ "$(sql "SELECT cwd FROM task WHERE id=$T2")" = "$REPO" ] \
   && [ "$(sql "SELECT cwd FROM task WHERE id=$T3")" = "$PLAIN" ]; then
  ok "manual commander cwd precedence is explicit, configured, then caller"
else no "manual commander cwd precedence"; fi

# D. Re-enable preserves cwd unless explicit; live work prevents explicit move.
fleet autonomy enable "$G" --channel shell --cooldown 0 >/dev/null
KEEP=$(sql "SELECT json_extract(autonomy,'$.cwd') FROM goal WHERE id=$G")
fleet add "live" --channel shell --cwd "$REPO" --spec "$FLEET_HOME/driver-review.sh" --goal "$G" >/dev/null
CHANGE=$(fleet autonomy enable "$G" --channel shell --cwd "$PLAIN" --cooldown 0 2>&1); RC=$?
if [ "$KEEP" = "$REPO" ] && [ "$RC" != 0 ] && [[ "$CHANGE" == *queued/running* ]]; then
  ok "re-enable preserves cwd and refuses an explicit change while goal work is live"
else no "re-enable cwd guard (keep=$KEEP rc=$RC out=$CHANGE)"; fi

# E. Legacy enabled state without cwd pauses explicitly; a vanished configured
# directory is also visible rather than guessed from the polling daemon.
new_home; driver review
G=$(fleet goal add "legacy state")
sql "UPDATE goal SET autonomy='{\"enabled\":true,\"channel\":\"shell\",\"rounds_used\":0,\"max_rounds\":2}' WHERE id=$G"
poll_from "$ELSEWHERE"
COUNT=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$G")
REASON=$(sql "SELECT json_extract(autonomy,'$.last_reason') FROM goal WHERE id=$G")
OLD_ENABLE=$(fleet autonomy enable "$G" --channel shell 2>&1); OLD_RC=$?
G2=$(fleet goal add "missing directory"); MISSING="$FLEET_HOME/will-vanish"; mkdir "$MISSING"
fleet autonomy enable "$G2" --channel shell --cwd "$MISSING" --cooldown 0 >/dev/null
rmdir "$MISSING"; poll_from "$ELSEWHERE"
REASON2=$(sql "SELECT json_extract(autonomy,'$.last_reason') FROM goal WHERE id=$G2")
BAD=$(fleet autonomy enable "$G2" --channel shell --cwd "$FLEET_HOME/never-there" 2>&1); BADRC=$?
if [ "$COUNT" = 0 ] && [[ "$REASON" == *re-run*--cwd* ]] \
   && [ "$OLD_RC" != 0 ] && [[ "$OLD_ENABLE" == *explicit*--cwd* ]] \
   && [[ "$REASON2" == *does\ not\ exist* ]] && [ "$BADRC" != 0 ] \
   && [[ "$BAD" == *does\ not\ exist* ]]; then
  ok "legacy missing cwd pauses, vanished cwd blocks, and enable rejects a missing directory"
else no "legacy/missing cwd guard (count=$COUNT old=$REASON missing=$REASON2 enable=$BADRC:$BAD)"; fi

# F. Non-Git candidates remain usable, but every C-dispatched worker for the
# same canonical directory shares one lease even across goals.
new_home; driver slowworker
PLAIN="$FLEET_HOME/plain"; mkdir -p "$PLAIN/sub"
G1=$(fleet goal add "plain one"); G2=$(fleet goal add "plain two")
fleet autonomy enable "$G1" --channel shell --cwd "$PLAIN" --max-rounds 1 --cooldown 0 >/dev/null
fleet autonomy enable "$G2" --channel shell --cwd "$PLAIN/sub/.." --max-rounds 1 --cooldown 0 >/dev/null
poll_from "$ELSEWHERE"
for c in $(sql "SELECT id FROM task WHERE role='commander' ORDER BY id"); do wait_status "$c" done || true; done
mapfile -t PW < <(sql "SELECT id FROM task WHERE role='worker' ORDER BY id")
poll_from "$ELSEWHERE"
RUNNING=$(sql "SELECT COUNT(*) FROM task WHERE role='worker' AND status='running'")
QUEUED=$(sql "SELECT COUNT(*) FROM task WHERE role='worker' AND status='queued'")
LEASES=$(sql "SELECT COUNT(DISTINCT lease) FROM task WHERE role='worker' AND lease IS NOT NULL")
SPEC=$(sql "SELECT spec_path FROM task WHERE id=${PW[0]}")
wait_status "${PW[0]}" done || wait_status "${PW[1]}" done || true
poll_from "$ELSEWHERE"
wait_status "${PW[0]}" done || true; wait_status "${PW[1]}" done || true
if [ "$RUNNING:$QUEUED:$LEASES" = "1:1:1" ] \
   && [ "$(sql "SELECT COUNT(*) FROM task WHERE role='worker' AND worktree_branch IS NULL")" = 2 ] \
   && grep -q "no Git version isolation" "$SPEC"; then
  ok "non-Git workers share a canonical cross-goal lease and state the lack of version isolation"
else no "non-Git serialization ($RUNNING/$QUEUED/$LEASES)"; fi

# G. Dirty Git input is rejected without modifying or committing it.
new_home; new_repo; driver one
G=$(fleet goal add "dirty input")
fleet autonomy enable "$G" --channel shell --cwd "$REPO" --cooldown 0 >/dev/null
printf 'user change\n' >"$REPO/uncommitted.txt"
BEFORE=$(git -C "$REPO" rev-parse HEAD)
poll_from "$ELSEWHERE"; C=$(sql "SELECT id FROM task WHERE role='commander'"); wait_status "$C" done || true
AFTER=$(git -C "$REPO" rev-parse HEAD)
WHY=$(sql "SELECT json_extract(payload,'$.skipped[0].reason') FROM event WHERE kind='commander.round'")
VISIBLE=$(sql "SELECT json_extract(autonomy,'$.last_reason') FROM goal WHERE id=$G")
if [ "$(sql "SELECT COUNT(*) FROM task WHERE role='worker'")" = 0 ] \
   && [ "$BEFORE" = "$AFTER" ] && [ -f "$REPO/uncommitted.txt" ] \
   && [[ "$WHY" == *uncommitted* ]] && [[ "$VISIBLE" == *uncommitted* ]]; then
  ok "dirty Git input blocks visibly without discard or automatic commit"
else no "dirty Git input guard (reason=$WHY)"; fi

# H. Filesystem-only repairs are new information: while dirty, every poll
# keeps the actionable reason; after the operator cleans it, the daemon emits
# one unblocked event and starts a fresh round without a synthetic user event.
BLOCKED1=$(fleet brief)
poll_from "$ELSEWHERE"
BLOCKED2=$(fleet brief)
git -C "$REPO" add uncommitted.txt
git -C "$REPO" commit -qm "operator resolves dirty input"
poll_from "$ELSEWHERE"
C2=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$G AND role='commander'")
wait_status "$C2" done || true
UNBLOCKED=$(sql "SELECT COUNT(*) FROM event WHERE goal_id=$G AND kind='autonomy.unblocked' AND json_extract(payload,'$.goal_id')=$G")
RECOVERED=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$G AND role='worker'")
if [ "$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$G AND role='commander'")" = 2 ] \
   && [ "$UNBLOCKED:$RECOVERED" = "1:1" ] \
   && [[ "$BLOCKED1" == *candidate\ blocked:*dirty_target* ]] \
   && [[ "$BLOCKED2" == *candidate\ blocked:*dirty_target* ]]; then
  ok "dirty candidate reason persists; cleanup emits autonomy.unblocked and starts a fresh round"
else
  no "dirty candidate recovery (unblocked=$UNBLOCKED workers=$RECOVERED)"
fi

# I. An overlong configured cwd is an ordinary validation error, not an
# uncaught os.stat ENAMETOOLONG traceback.
new_home; driver review
G=$(fleet goal add "overlong cwd")
LONG_CWD=$(python3 -c "print('/var/tmp/' + 'x' * 5000)")
LONG_OUT=$(fleet autonomy enable "$G" --channel shell --cwd "$LONG_CWD" 2>&1)
LONG_RC=$?
if [ "$LONG_RC" != 0 ] && [[ "$LONG_OUT" == *cannot\ be\ inspected* ]] \
   && [[ "$LONG_OUT" == *File\ name\ too\ long* ]] \
   && [[ "$LONG_OUT" != *Traceback* ]]; then
  ok "overlong autonomy cwd is rejected cleanly with its filesystem reason"
else
  no "overlong autonomy cwd rejection (rc=$LONG_RC out=$LONG_OUT)"
fi

echo ---
echo "passed $PASS / $N"
[ "$FAIL" = 0 ]
