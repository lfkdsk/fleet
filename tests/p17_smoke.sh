#!/usr/bin/env bash
# P17: the claim_refuted -> enqueue_fix handoff.
#
# The bug this suite pins: the rule existed and had never once produced a
# usable fix. Over a week of 362 tasks and 55 refuted claims it fired zero
# times, because the fixer it dispatched could not do the work --
#   - the spec carried the claim and its evidence but not the REASON it was
#     refuted (the note lives on the claim.verify event, not the claim row),
#   - no worktree and no base were passed, so the fixer started from the
#     repo HEAD and edited code that was never the refuted deliverable,
#   - parent_id was set only `if session_id`, a field most channels never
#     set, so task.parent_id was empty ledger-wide and no fix could be
#     traced to its source,
#   - the loop ran per CLAIM, so two refutations on one task dispatched two
#     fixers into the same worktree in the same round.
# The commander hand-wrote every fix spec instead.
#
# Every case here runs on the shell channel against a throwaway git repo in
# an isolated FLEET_HOME: zero model quota, no contact with ~/.fleet.
# Assertions are on file CONTENT, commit SHAs, row counts and uniqueness --
# "the string appeared in the spec" is not evidence that the handoff works.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p17-test-XXXX)"
export PATH="$ROOT/bin:$PATH"
unset _FLEET_LOCK_FD

PASS=0
FAIL=0
N=0
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }

cleanup(){ fleet daemon stop >/dev/null 2>&1 || true; rm -rf "$FLEET_HOME"; }
trap cleanup EXIT

fleet init >/dev/null
DB="$FLEET_HOME/fleet.db"

field(){ fleet show "$1" | awk -v f="$2" '$1==f":"{print $2}'; }
wait_status(){
  local id="$1" want="$2" i
  for i in $(seq 1 150); do
    [ "$(field "$id" status)" = "$want" ] && return 0
    sleep 0.2
  done
  return 1
}

q(){ python3 -c "import sqlite3,sys;print(sqlite3.connect('$DB').execute(sys.argv[1]).fetchone()[0])" "$1"; }

# A fresh goal + a claim_refuted rule, printed as the goal id. Each case gets
# its own goal so a firing in one never satisfies another's dedup key.
new_goal(){ # new_goal <name> [acceptance]
  local g
  if [ $# -ge 2 ]; then g=$(fleet goal add "$1" --acceptance "$2"); else g=$(fleet goal add "$1"); fi
  printf '[{"on":"claim_refuted","do":"enqueue_fix"}]\n' > "$FLEET_HOME/rules-$g.json"
  fleet plan set "$g" --rules "$FLEET_HOME/rules-$g.json" --rationale "auto fix" >/dev/null
  echo "$g"
}

# A throwaway repo per case: cases assert the ORIGIN repo is untouched, and a
# shared repo would let one case's commit satisfy another's assertion.
new_repo(){ # new_repo <name> -> path
  local r="$FLEET_HOME/$1"
  mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t
  git -C "$r" config user.name t
  printf 'base\n' > "$r/f.txt"
  git -C "$r" add -A
  git -C "$r" commit -qm base
  echo "$r"
}

# The source task's script: make a commit that exists ONLY on its worktree
# branch, so "did the fixer get the refuted code" has a file-content answer.
printf 'printf %%s\\\\n uniq-content > uniq.txt\ngit add -A\ngit -c user.email=t@t.t -c user.name=t commit -qm work\n' \
  > "$FLEET_HOME/spec_work.sh"
printf 'echo hi\n' > "$FLEET_HOME/spec_echo.sh"

fix_of(){ # fix_of <source-task-id> -> the fixer's task id, or empty
  python3 -c "import sqlite3,sys
r=sqlite3.connect('$DB').execute('SELECT id FROM task WHERE parent_id=? ORDER BY id',(int(sys.argv[1]),)).fetchall()
print(r[0][0] if r else '')" "$1"
}
n_fix(){ # n_fix <source-task-id> -> how many fixers exist for it
  python3 -c "import sqlite3,sys
print(sqlite3.connect('$DB').execute('SELECT COUNT(*) FROM task WHERE parent_id=?',(int(sys.argv[1]),)).fetchone()[0])" "$1"
}

# Run a source task to completion in its own worktree, refute claims on it.
run_source(){ # run_source <goal> <repo> <title> -> task id
  local t
  t=$(fleet add "$3" --channel shell --worktree --cwd "$2" --spec "$FLEET_HOME/spec_work.sh" --goal "$1")
  fleet daemon run --once >/dev/null 2>&1
  wait_status "$t" done || { echo "run_source: task $t never finished" >&2; return 1; }
  echo "$t"
}

# --- A. the fixer works on the refuted code, and nothing upstream moves ----
#
# The pre-P17 fixer had no worktree and no base: it started from the repo
# HEAD, which never contained the source task's commit. So the whole point is
# a file-content assertion inside the fixer's worktree.
GA=$(new_goal gA)
RA=$(new_repo repoA)
TA=$(run_source "$GA" "$RA" "A source")
A_HEAD_BEFORE=$(git -C "$RA" rev-parse HEAD)
A_TIP=$(git -C "$RA" rev-parse "fleet/task-$TA")
CA=$(fleet claim add "$TA" "uniq.txt says the right thing" --evidence "uniq.txt:1")
fleet claim verify "$CA" --status refuted --note "it does not: the file reads uniq-content" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FA=$(fix_of "$TA")
# Launch it so the worktree actually materialises; the fix spec is a shell
# script only in the sense that shell.sh runs it -- it is prose, so it exits
# non-zero. The worktree is what this case reads.
fleet daemon run --once >/dev/null 2>&1
for i in $(seq 1 60); do [ -d "$FLEET_HOME/worktrees/task-$FA" ] && break; sleep 0.2; done
A_WT="$FLEET_HOME/worktrees/task-$FA"
A_CONTENT=$(cat "$A_WT/uniq.txt" 2>/dev/null || echo MISSING)
A_HEAD_AFTER=$(git -C "$RA" rev-parse HEAD)
A_SRC_DIRT=$(git -C "$FLEET_HOME/worktrees/task-$TA" status --porcelain -uall 2>/dev/null | wc -l)
A_SRC_TIP=$(git -C "$RA" rev-parse "fleet/task-$TA")
if [ "$A_CONTENT" = "uniq-content" ] && [ "$A_HEAD_BEFORE" = "$A_HEAD_AFTER" ] \
   && [ "$A_SRC_DIRT" = "0" ] && [ "$A_TIP" = "$A_SRC_TIP" ]; then
  ok "A: fixer's worktree holds the refuted commit's content; origin repo and source worktree untouched"
else
  no "A: fixer worktree content=$A_CONTENT head $A_HEAD_BEFORE->$A_HEAD_AFTER src_dirt=$A_SRC_DIRT tip $A_TIP->$A_SRC_TIP"
fi

# --- B. the pin does not follow the upstream branch ------------------------
#
# base_task names a BRANCH, which keeps moving; base_commit pins CONTENT. A
# commit landing on the source branch after the fix was enqueued must not
# change what the fix reads.
GB=$(new_goal gB)
RB=$(new_repo repoB)
TB=$(run_source "$GB" "$RB" "B source")
CB=$(fleet claim add "$TB" "b claim" --evidence "uniq.txt:1")
fleet claim verify "$CB" --status refuted --note "b note" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FB=$(fix_of "$TB")
B_PIN=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute('SELECT base_commit FROM task WHERE id=$FB').fetchone()[0])")
# Upstream moves AFTER the fix is queued but BEFORE it launches.
B_WTSRC="$FLEET_HOME/worktrees/task-$TB"
printf 'later\n' > "$B_WTSRC/later.txt"
git -C "$B_WTSRC" add -A
git -C "$B_WTSRC" -c user.email=t@t.t -c user.name=t commit -qm later
B_NEWTIP=$(git -C "$RB" rev-parse "fleet/task-$TB")
fleet daemon run --once >/dev/null 2>&1
for i in $(seq 1 60); do [ -d "$FLEET_HOME/worktrees/task-$FB" ] && break; sleep 0.2; done
B_FIXHEAD=$(git -C "$FLEET_HOME/worktrees/task-$FB" rev-parse HEAD 2>/dev/null || echo NONE)
B_HASLATER=$([ -e "$FLEET_HOME/worktrees/task-$FB/later.txt" ] && echo yes || echo no)
if [ "$B_FIXHEAD" = "$B_PIN" ] && [ "$B_PIN" != "$B_NEWTIP" ] && [ "$B_HASLATER" = "no" ]; then
  ok "B: fixer starts at the pinned commit, not the branch tip that moved after enqueue"
else
  no "B: fix HEAD=$B_FIXHEAD pin=$B_PIN newtip=$B_NEWTIP later.txt=$B_HASLATER"
fi

# --- C. two refutations in one round are ONE batch -------------------------
GC=$(new_goal gC)
RC=$(new_repo repoC)
TC=$(run_source "$GC" "$RC" "C source")
CC1=$(fleet claim add "$TC" "c claim one" --evidence "e1")
CC2=$(fleet claim add "$TC" "c claim two" --evidence "e2")
fleet claim verify "$CC1" --status refuted --note "C-NOTE-ONE distinct" >/dev/null
fleet claim verify "$CC2" --status refuted --note "C-NOTE-TWO distinct" >/dev/null
fleet daemon run --once >/dev/null 2>&1
C_N=$(n_fix "$TC")
FC=$(fix_of "$TC")
C_SPEC=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute('SELECT spec_path FROM task WHERE id=$FC').fetchone()[0])")
C_OK=$(python3 - "$C_SPEC" "$CC1" "$CC2" <<'PY'
import sys
s = open(sys.argv[1]).read()
need = [f"### claim {sys.argv[2]}", f"### claim {sys.argv[3]}",
        "C-NOTE-ONE distinct", "C-NOTE-TWO distinct"]
missing = [n for n in need if n not in s]
print("ok" if not missing else "missing:" + ",".join(missing))
PY
)
if [ "$C_N" = "1" ] && [ "$C_OK" = "ok" ]; then
  ok "C: two refutations in one round produce exactly one fixer, whose spec carries both claim ids and both notes"
else
  no "C: fixers=$C_N spec=$C_OK"
fi

# --- D. interleaved judgements, distinct notes, one of them spilled --------
#
# The note is matched by claim_id from the event payload. Taking "the source
# task's last claim.verify event" instead attaches one claim's refutation to
# both -- the fixer then reads a reason nobody gave for the claim it is shown
# against. The big note also has to survive spill_store/spill_load: past
# SPILL_BYTES the payload column holds a pointer, not the text.
GD=$(new_goal gD)
RD=$(new_repo repoD)
TD=$(run_source "$GD" "$RD" "D source")
CD1=$(fleet claim add "$TD" "d claim one" --evidence "e1")
CD2=$(fleet claim add "$TD" "d claim two" --evidence "e2")
BIG=$(python3 -c "print('D-BIG-HEAD ' + 'x'*5000 + ' D-BIG-TAIL')")
# Interleaved: claim 1 judged, then claim 2, then claim 1 AGAIN with its final
# note. The construction must use the LATEST judgement per claim.
fleet claim verify "$CD1" --status refuted --note "D-STALE-ONE superseded" >/dev/null
fleet claim verify "$CD2" --status refuted --note "$BIG" >/dev/null
python3 -c "import sqlite3;c=sqlite3.connect('$DB');c.execute(\"UPDATE claim SET status='unverified' WHERE id=$CD1\");c.commit()"
fleet claim verify "$CD1" --status refuted --note "D-FINAL-ONE small note" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FD=$(fix_of "$TD")
D_SPEC=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute('SELECT spec_path FROM task WHERE id=$FD').fetchone()[0])")
D_SPILLED=$(python3 -c "
import sqlite3
n=sum(1 for r in sqlite3.connect('$DB').execute(\"SELECT payload FROM event WHERE kind='claim.verify'\") if '_spill' in (r[0] or ''))
print(n)")
D_OK=$(python3 - "$D_SPEC" "$CD1" "$CD2" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
one, two = f"### claim {sys.argv[2]}", f"### claim {sys.argv[3]}"
bad = []
for h in (one, two):
    if h not in s: bad.append("no " + h)
if bad:
    print(";".join(bad)); raise SystemExit
# Split the spec into per-claim sections so "the note is under the RIGHT
# claim" is what gets checked, not "the note is somewhere in the file".
secs = {}
cur = None
for line in s.splitlines():
    m = re.match(r"### claim (\d+)$", line)
    if m: cur = m.group(1); secs[cur] = []
    elif cur: secs[cur].append(line)
s1 = "\n".join(secs.get(sys.argv[2], []))
s2 = "\n".join(secs.get(sys.argv[3], []))
if "D-FINAL-ONE small note" not in s1: bad.append("claim1 lacks its final note")
if "D-STALE-ONE" in s1: bad.append("claim1 kept the superseded note")
if "D-BIG-HEAD" in s1 or "D-BIG-TAIL" in s1: bad.append("claim2's note bled into claim1")
if "D-FINAL-ONE" in s2: bad.append("claim1's note bled into claim2")
if "D-BIG-HEAD" not in s2 or "D-BIG-TAIL" not in s2:
    bad.append("claim2's spilled note did not come back whole")
if s2.count("x" * 4000) != 1: bad.append("claim2's big note body is truncated")
print("ok" if not bad else ";".join(bad))
PY
)
if [ "$D_OK" = "ok" ] && [ "$D_SPILLED" -ge 1 ]; then
  ok "D: notes stay with their own claim (latest judgement wins) and a spilled note is unpacked whole"
else
  no "D: $D_OK (spilled events=$D_SPILLED)"
fi

# --- E. parent_id does not depend on session_id ----------------------------
#
# The old code read `parent = tid if session_id else None`. Most channels
# never set session_id, so task.parent_id was NULL across the whole ledger
# and no fix could be traced to the work that caused it.
GE=$(new_goal gE)
RE_=$(new_repo repoE)
TE=$(run_source "$GE" "$RE_" "E source")
E_SESS=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute('SELECT session_id FROM task WHERE id=$TE').fetchone()[0])")
CE=$(fleet claim add "$TE" "e claim" --evidence "e")
fleet claim verify "$CE" --status refuted --note "e note" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FE=$(python3 -c "import sqlite3
r=sqlite3.connect('$DB').execute(\"SELECT id,parent_id FROM task WHERE title LIKE 'fix: E source%'\").fetchone()
print(f'{r[0]} {r[1]}' if r else 'none none')")
E_PARENT=${FE##* }
if [ "$E_SESS" = "None" ] && [ "$E_PARENT" = "$TE" ]; then
  ok "E: source has no session_id, yet the fixer's parent_id is the source task"
else
  no "E: session_id=$E_SESS parent_id=$E_PARENT want=$TE"
fi

# --- F. a source that is not finished yet gets no fixer, and no firing -----
#
# ...and the firing must NOT be consumed: recording it here would mean the
# fix never happens once the task settles.
GF=$(new_goal gF)
RF=$(new_repo repoF)
printf 'sleep 6\n' > "$FLEET_HOME/spec_slow.sh"
TF=$(fleet add "F source" --channel shell --worktree --cwd "$RF" --spec "$FLEET_HOME/spec_slow.sh" --goal "$GF")
fleet daemon run --once >/dev/null 2>&1
for i in $(seq 1 60); do [ "$(field "$TF" status)" = running ] && break; sleep 0.2; done
CF=$(fleet claim add "$TF" "f claim" --evidence "e")
fleet claim verify "$CF" --status refuted --note "f note" >/dev/null
fleet daemon run --once >/dev/null 2>&1
F_MID=$(n_fix "$TF")
F_FIRED=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute(\"SELECT COUNT(*) FROM event WHERE kind='rule.fired' AND goal_id=$GF\").fetchone()[0])")
wait_status "$TF" done || true
fleet daemon run --once >/dev/null 2>&1
F_AFTER=$(n_fix "$TF")
if [ "$F_MID" = "0" ] && [ "$F_FIRED" = "0" ] && [ "$F_AFTER" = "1" ]; then
  ok "F: no fixer and no rule.fired while the source runs; the fix is dispatched once it settles"
else
  no "F: during=$F_MID fired=$F_FIRED after=$F_AFTER"
fi

# --- G. an indeterminate upstream blocks, visibly and recoverably ----------
#
# Three shapes. Each must produce: no fixer, a fix.blocked event, and exactly
# ONE needs-user decision no matter how many polls run. Falling back to the
# repo HEAD would fix code nobody refuted; committing the user's files to
# clean the tree is not ours to do.
g_case(){ # g_case <label> <dirty-command> -> "fixers fixblocked decisions"
  local label="$1" dirty="$2" g r t c
  g=$(new_goal "gG-$label")
  r=$(new_repo "repoG$label")
  t=$(run_source "$g" "$r" "G-$label source")
  c=$(fleet claim add "$t" "g claim $label" --evidence "e")
  fleet claim verify "$c" --status refuted --note "g note" >/dev/null
  WT="$FLEET_HOME/worktrees/task-$t" bash -c "$dirty"
  # Several polls: the dedup must hold across rounds, not just within one.
  fleet daemon run --once >/dev/null 2>&1
  fleet daemon run --once >/dev/null 2>&1
  fleet daemon run --once >/dev/null 2>&1
  python3 -c "import sqlite3
c=sqlite3.connect('$DB')
f=c.execute('SELECT COUNT(*) FROM task WHERE parent_id=?',($t,)).fetchone()[0]
b=c.execute(\"SELECT COUNT(*) FROM event WHERE kind='fix.blocked' AND task_id=?\",($t,)).fetchone()[0]
d=c.execute('SELECT COUNT(*) FROM decision WHERE task_id=? AND needs_user=1',($t,)).fetchone()[0]
print(f'{f} {b} {d} {$t} {$g}')"
}
G1=$(g_case modified 'printf changed > "$WT/f.txt"')
G2=$(g_case untracked 'printf new > "$WT/brand-new.txt"')
G3=$(g_case gone 'rm -rf "$WT"')
if [ "${G1% * *}" = "0 1 1" ] && [ "${G2% * *}" = "0 1 1" ] && [ "${G3% * *}" = "0 1 1" ]; then
  ok "G: uncommitted / untracked / missing worktree each block with one fix.blocked and exactly one decision across repeated polls"
else
  no "G: modified='$G1' untracked='$G2' gone='$G3' (want '0 1 1 ...' each)"
fi

# G recovery: clear the cause, and the next poll dispatches -- without a
# second decision. A block is a "not yet", not a verdict.
G1_T=$(echo "$G1" | awk '{print $4}')
G1_WT="$FLEET_HOME/worktrees/task-$G1_T"
git -C "$G1_WT" checkout -q -- f.txt
fleet daemon run --once >/dev/null 2>&1
G1_REC=$(python3 -c "import sqlite3
c=sqlite3.connect('$DB')
f=c.execute('SELECT COUNT(*) FROM task WHERE parent_id=?',($G1_T,)).fetchone()[0]
d=c.execute('SELECT COUNT(*) FROM decision WHERE task_id=? AND needs_user=1',($G1_T,)).fetchone()[0]
print(f'{f} {d}')")
if [ "$G1_REC" = "1 1" ]; then
  ok "G-recovery: cleaning the worktree dispatches the fix on the next poll, with no duplicate decision"
else
  no "G-recovery: fixers/decisions='$G1_REC' want '1 1'"
fi

# --- H. repeated polls and a daemon restart still leave exactly one fixer --
GH=$(new_goal gH)
RH=$(new_repo repoH)
TH=$(run_source "$GH" "$RH" "H source")
CH=$(fleet claim add "$TH" "h claim" --evidence "e")
fleet claim verify "$CH" --status refuted --note "h note" >/dev/null
for i in 1 2 3 4 5; do fleet daemon run --once >/dev/null 2>&1; done
fleet daemon start >/dev/null 2>&1
sleep 2
fleet daemon stop >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
H_N=$(n_fix "$TH")
H_BATCH=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute(\"SELECT COUNT(*) FROM event WHERE kind='fix.batch' AND goal_id=$GH\").fetchone()[0])")
if [ "$H_N" = "1" ] && [ "$H_BATCH" = "1" ]; then
  ok "H: eight evaluations plus a daemon start/stop leave exactly one fixer and one fix.batch"
else
  no "H: fixers=$H_N batches=$H_BATCH"
fi

# --- I. a non-git source runs in place and says it is not isolated ---------
GI=$(new_goal gI)
PLAIN="$FLEET_HOME/plaindir"
mkdir -p "$PLAIN"
TI=$(fleet add "I source" --channel shell --cwd "$PLAIN" --spec "$FLEET_HOME/spec_echo.sh" --goal "$GI")
fleet daemon run --once >/dev/null 2>&1
wait_status "$TI" done || true
CI=$(fleet claim add "$TI" "i claim" --evidence "e")
fleet claim verify "$CI" --status refuted --note "i note" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FI=$(fix_of "$TI")
I_ROW=$(python3 -c "import sqlite3
r=sqlite3.connect('$DB').execute('SELECT cwd,worktree_branch,base_commit,spec_path FROM task WHERE id=$FI').fetchone()
print(f'{r[0]}|{r[1]}|{r[2]}|{r[3]}')")
I_CWD=$(echo "$I_ROW" | cut -d'|' -f1)
I_WB=$(echo "$I_ROW" | cut -d'|' -f2)
I_BC=$(echo "$I_ROW" | cut -d'|' -f3)
I_SPEC=$(echo "$I_ROW" | cut -d'|' -f4)
I_SAYS=$(grep -c "no code version isolation" "$I_SPEC" || true)
if [ "$I_CWD" = "$PLAIN" ] && [ "$I_WB" = "None" ] && [ "$I_BC" = "None" ] && [ "$I_SAYS" -ge 1 ]; then
  ok "I: a non-git source's fix runs in the same cwd, with no worktree, and its spec states the lack of isolation"
else
  no "I: cwd=$I_CWD (want $PLAIN) branch=$I_WB base=$I_BC says_isolation=$I_SAYS"
fi

# --- J. a crash between enqueue and bookkeeping does not double-dispatch ---
#
# FLEET_FIX_FAULT=after-create os._exit()s the poll right after create_task
# and before rule.fired / fix.batch are written. Because all three are one
# transaction, the whole thing rolls back -- so the restart dispatches ONE
# fixer, not a second one on top of an orphan nothing recorded.
GJ=$(new_goal gJ)
RJ=$(new_repo repoJ)
TJ=$(run_source "$GJ" "$RJ" "J source")
CJ=$(fleet claim add "$TJ" "j claim" --evidence "e")
fleet claim verify "$CJ" --status refuted --note "j note" >/dev/null
FLEET_FIX_FAULT=after-create fleet daemon run --once >/dev/null 2>&1
J_RC=$?
J_MID=$(n_fix "$TJ")
J_MIDBATCH=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute(\"SELECT COUNT(*) FROM event WHERE kind='fix.batch' AND goal_id=$GJ\").fetchone()[0])")
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
J_AFTER=$(n_fix "$TJ")
J_BATCH=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute(\"SELECT COUNT(*) FROM event WHERE kind='fix.batch' AND goal_id=$GJ\").fetchone()[0])")
if [ "$J_RC" = "97" ] && [ "$J_MID" = "0" ] && [ "$J_MIDBATCH" = "0" ] \
   && [ "$J_AFTER" = "1" ] && [ "$J_BATCH" = "1" ]; then
  ok "J: a crash before the bookkeeping rolls the fixer back; the restart dispatches exactly one"
else
  no "J: crash rc=$J_RC mid=(fix $J_MID batch $J_MIDBATCH) after=(fix $J_AFTER batch $J_BATCH)"
fi

# --- K. a refutation arriving mid-fix waits for the next batch -------------
#
# A second fixer in parallel would edit the same worktree as the first.
GK=$(new_goal gK)
RK=$(new_repo repoK)
TK=$(run_source "$GK" "$RK" "K source")
CK1=$(fleet claim add "$TK" "k claim one" --evidence "e1")
fleet claim verify "$CK1" --status refuted --note "K-NOTE-ONE" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FK1=$(fix_of "$TK")
# Put the first fixer in flight, deterministically. `daemon run --once` both
# evaluates rules and launches, so the fixer it just enqueued is already
# running: racing it would have its own `_finish` overwrite this row a moment
# later. Wait for it to settle, then set the state the contract keys on --
# with a REAL live pid, because reap_orphans settles a running row whose
# process is gone and that would close the very window this case is about.
for i in $(seq 1 100); do
  case "$(field "$FK1" status)" in done|failed|cancelled) break ;; esac
  sleep 0.2
done
sleep 300 &
K_PID=$!
python3 -c "import sqlite3,time
c=sqlite3.connect('$DB')
c.execute(\"UPDATE task SET status='running', pid=?, started_at=?, ended_at=NULL WHERE id=$FK1\",
          ($K_PID, int(time.time())))
c.commit()"
K_INFLIGHT=$(field "$FK1" status)
# The follow-up refutation must queue behind it, not start a rival fixer on
# the same worktree.
CK2=$(fleet claim add "$TK" "k claim two" --evidence "e2")
fleet claim verify "$CK2" --status refuted --note "K-NOTE-TWO" >/dev/null
fleet daemon run --once >/dev/null 2>&1
K_MID=$(n_fix "$TK")
K_PENDING=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute(\"SELECT COUNT(*) FROM event WHERE kind='fix.pending' AND goal_id=$GK\").fetchone()[0])")
K_BRIEF=$(fleet brief 2>/dev/null | grep -c "条新驳斥待下一批" || true)
# Settle the first fixer, then the next round dispatches batch two -- with
# only the NEW claim: re-sending the settled one would have the fixer redo
# work it already did.
python3 -c "import sqlite3,time
c=sqlite3.connect('$DB')
c.execute(\"UPDATE task SET status='done', ended_at=?, pid=NULL WHERE id=$FK1\",(int(time.time()),))
c.commit()"
kill "$K_PID" 2>/dev/null || true
wait "$K_PID" 2>/dev/null || true
fleet daemon run --once >/dev/null 2>&1
K_AFTER=$(n_fix "$TK")
FK2=$(python3 -c "import sqlite3
r=sqlite3.connect('$DB').execute('SELECT id,spec_path FROM task WHERE parent_id=$TK ORDER BY id').fetchall()
print(f'{r[-1][0]}|{r[-1][1]}' if len(r)>1 else 'none|none')")
K_SPEC=$(echo "$FK2" | cut -d'|' -f2)
K_ONLY_NEW=$(python3 - "$K_SPEC" "$CK1" "$CK2" <<'PY'
import sys
spec, old_id, new_id = sys.argv[1], sys.argv[2], sys.argv[3]
try: s = open(spec).read()
except OSError: print("no-spec"); raise SystemExit
has_new = f"### claim {new_id}" in s
has_old = f"### claim {old_id}" in s
print("ok" if has_new and not has_old else f"new={has_new} old={has_old}")
PY
)
if [ "$K_INFLIGHT" = "running" ] && [ "$K_MID" = "1" ] && [ "$K_PENDING" = "1" ] \
   && [ "$K_BRIEF" -ge 1 ] && [ "$K_AFTER" = "2" ] && [ "$K_ONLY_NEW" = "ok" ]; then
  ok "K: a refutation during an in-flight fix records fix.pending and shows in brief; the next batch carries only the new claim"
else
  no "K: inflight=$K_INFLIGHT mid_fixers=$K_MID pending=$K_PENDING brief=$K_BRIEF after=$K_AFTER second_batch=$K_ONLY_NEW"
fi

# --- L. a failed source with an intact branch is still fixable -------------
#
# Contract 7: the deliverable, not the exit code, decides. Hanging a
# dependency that demands the source reach 'done' would strand every fix
# behind a task that never will.
GL=$(new_goal gL)
RL=$(new_repo repoL)
TL=$(run_source "$GL" "$RL" "L source")
L_TIP=$(git -C "$RL" rev-parse "fleet/task-$TL")
python3 -c "import sqlite3;c=sqlite3.connect('$DB');c.execute(\"UPDATE task SET status='failed', exit_code=1 WHERE id=$TL\");c.commit()"
CL=$(fleet claim add "$TL" "l claim" --evidence "e")
fleet claim verify "$CL" --status refuted --note "l note" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FL=$(fix_of "$TL")
L_BASE=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute('SELECT base_commit FROM task WHERE id=$FL').fetchone()[0] if '$FL' else 'none')")
# The column recording the tip is not the same claim as the worktree STARTING
# at the tip: launch it and read git, or a fix that ignores the pin and
# branches from HEAD passes this case with the right value in the wrong place.
fleet daemon run --once >/dev/null 2>&1
for i in $(seq 1 60); do [ -d "$FLEET_HOME/worktrees/task-$FL" ] && break; sleep 0.2; done
L_WTHEAD=$(git -C "$FLEET_HOME/worktrees/task-$FL" rev-parse HEAD 2>/dev/null || echo NONE)
L_REPOHEAD=$(git -C "$RL" rev-parse HEAD)
if [ -n "$FL" ] && [ "$L_BASE" = "$L_TIP" ] && [ "$L_WTHEAD" = "$L_TIP" ] \
   && [ "$L_TIP" != "$L_REPOHEAD" ]; then
  ok "L: a failed source with a live worktree branch still gets a fix, and that fix's worktree starts at the branch tip (not the repo HEAD)"
else
  no "L: fixer='$FL' base=$L_BASE wt_head=$L_WTHEAD tip=$L_TIP repo_head=$L_REPOHEAD"
fi

# --- M. a pre-P17 ledger upgrades in place ---------------------------------
#
# Old rows stay readable, the new column reads NULL, and --dep-base -- which
# uses base_task, a different mechanism -- behaves exactly as before.
M_HOME=$(mktemp -d /var/tmp/fleet-p17-old-XXXX)
(
  export FLEET_HOME="$M_HOME"
  fleet init >/dev/null
  MR="$M_HOME/repo"; mkdir -p "$MR"
  git -C "$MR" init -q; git -C "$MR" config user.email t@t.t; git -C "$MR" config user.name t
  printf 'base\n' > "$MR/f.txt"; git -C "$MR" add -A; git -C "$MR" commit -qm base
  printf 'echo hi\n' > "$M_HOME/s.sh"
  OLD=$(fleet add "old task" --channel shell --cwd "$MR" --spec "$M_HOME/s.sh")
  # Rewrite the task table without base_commit: a genuine pre-P17 ledger.
  # The replacement DDL is the real one with that column's definition cut
  # out, so the fixture keeps every type, default and PRIMARY KEY -- a table
  # rebuilt from bare column names would lose the rowid alias and fail for
  # reasons that have nothing to do with the migration.
  python3 - "$M_HOME/fleet.db" <<'PY'
import re, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
cols = [r[1] for r in c.execute("PRAGMA table_info(task)")]
assert "base_commit" in cols, "fixture is not a current ledger"
keep = [x for x in cols if x != "base_commit"]
ddl = c.execute("SELECT sql FROM sqlite_master WHERE name='task'").fetchone()[0]
body = ddl[ddl.index("(") + 1:ddl.rindex(")")]
body = re.sub(r"--[^\n]*", "", body)
parts = [p.strip() for p in body.split(",")]
parts = [p for p in parts if p and not p.startswith("base_commit")]
c.execute("ALTER TABLE task RENAME TO task_old")
c.execute("CREATE TABLE task(%s)" % ", ".join(parts))
c.execute("INSERT INTO task(%s) SELECT %s FROM task_old"
          % (",".join(keep), ",".join(keep)))
c.execute("DROP TABLE task_old")
c.commit()
assert "base_commit" not in [r[1] for r in c.execute("PRAGMA table_info(task)")]
PY
  BEFORE=$(python3 -c "import sqlite3;print('base_commit' in [r[1] for r in sqlite3.connect('$M_HOME/fleet.db').execute('PRAGMA table_info(task)')])")
  fleet init >/dev/null 2>&1
  AFTER=$(python3 -c "import sqlite3
c=sqlite3.connect('$M_HOME/fleet.db')
has='base_commit' in [r[1] for r in c.execute('PRAGMA table_info(task)')]
v=c.execute('SELECT base_commit FROM task WHERE id=$OLD').fetchone()[0]
t=c.execute('SELECT title FROM task WHERE id=$OLD').fetchone()[0]
print(f'{has} {v} {t}')")
  # --dep-base still works, and still sets base_task (not base_commit).
  DEP=$(fleet add "dep" --channel shell --worktree --cwd "$MR" --spec "$M_HOME/s.sh")
  fleet daemon run --once >/dev/null 2>&1
  for i in $(seq 1 100); do
    [ "$(fleet show "$DEP" | awk '$1=="status:"{print $2}')" = done ] && break; sleep 0.2
  done
  CHILD=$(fleet add "child" --channel shell --worktree --cwd "$MR" --spec "$M_HOME/s.sh" --dep "$DEP" --dep-base 2>&1)
  DEPROW=$(python3 -c "import sqlite3
r=sqlite3.connect('$M_HOME/fleet.db').execute('SELECT base_task,base_commit FROM task WHERE id=$CHILD').fetchone()
print(f'{r[0]} {r[1]}')" 2>/dev/null || echo "err err")
  echo "BEFORE=$BEFORE AFTER=$AFTER DEP=$DEPROW"
) > "$FLEET_HOME/m.out" 2>&1
M_LINE=$(grep '^BEFORE=' "$FLEET_HOME/m.out" || true)
rm -rf "$M_HOME"
# BEFORE=False   the fixture really was a pre-P17 ledger (no base_commit)
# AFTER=True     `fleet init` added the column
# None old task  the old row survived and reads NULL for the new column
# DEP=<id> None  --dep-base still sets base_task and leaves base_commit alone
if echo "$M_LINE" | grep -qE '^BEFORE=False AFTER=True None old task DEP=[0-9]+ None$'; then
  ok "M: a ledger without base_commit upgrades in place -- old rows readable, new column NULL, --dep-base unchanged"
else
  no "M: $M_LINE  (full output: $(tr '\n' ' ' < "$FLEET_HOME/m.out" | tail -c 400))"
fi

# --- N. a note that LOOKS like a spill pointer is quoted, not dereferenced --
#
# _fix_verify_events already spill-decodes the event payload, so v["note"] is
# the text. A second spill_load on it turns the note itself into a pointer:
# a refutation whose text is `{"_spill": "/some/path", "bytes": N}` -- exactly
# what a reviewer discussing this machinery would write -- gets replaced by
# that file's contents in the fixer's prompt. Any local file the daemon can
# read, quoted into an agent prompt by a note anyone can write.
GN=$(new_goal gN)
RN=$(new_repo repoN)
TN=$(run_source "$GN" "$RN" "N source")
printf 'N-SENTINEL-MUST-NOT-LEAK\n' > "$FLEET_HOME/n-secret.txt"
CN=$(fleet claim add "$TN" "n claim" --evidence "e")
N_NOTE="{\"_spill\": \"$FLEET_HOME/n-secret.txt\", \"bytes\": 24}"
fleet claim verify "$CN" --status refuted --note "$N_NOTE" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FN=$(fix_of "$TN")
N_SPEC=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute('SELECT spec_path FROM task WHERE id=$FN').fetchone()[0])")
N_LEAK=$(grep -c 'N-SENTINEL-MUST-NOT-LEAK' "$N_SPEC" || true)
N_VERBATIM=$(grep -cF "$N_NOTE" "$N_SPEC" || true)
if [ -n "$FN" ] && [ "$N_LEAK" = "0" ] && [ "$N_VERBATIM" -ge 1 ]; then
  ok "N: a note that parses as a spill pointer is quoted verbatim; the file it names is not read into the prompt"
else
  no "N: fixer='$FN' sentinel_hits=$N_LEAK verbatim_hits=$N_VERBATIM spec=$N_SPEC"
fi

# --- O. an enqueue that fails leaves no row, and no row per poll -----------
#
# create_task used to INSERT and only then read the goal's --context files.
# Delete one and it raised with the row already written; the rule branch did
# not catch that class, the poll loop's error logger committed the half-open
# transaction, and every subsequent poll added another queued fixer that
# nothing had a rule.fired or a fix.batch for.
GO=$(new_goal gO)
RO=$(new_repo repoO)
printf 'project context body\n' > "$FLEET_HOME/o-ctx.txt"
# A symlink, so the target can vanish while the path recorded on the goal
# stays exactly what it was at goal-add time.
ln -sf "$FLEET_HOME/o-ctx.txt" "$FLEET_HOME/o-ctx-link.txt"
python3 -c "import sqlite3
c=sqlite3.connect('$DB')
c.execute('UPDATE goal SET context=? WHERE id=$GO',('$FLEET_HOME/o-ctx-link.txt',))
c.commit()"
TO=$(run_source "$GO" "$RO" "O source")
CO=$(fleet claim add "$TO" "o claim" --evidence "e")
fleet claim verify "$CO" --status refuted --note "o note" >/dev/null
rm -f "$FLEET_HOME/o-ctx.txt"
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
O_STATE=$(python3 -c "import sqlite3
c=sqlite3.connect('$DB')
f=c.execute('SELECT COUNT(*) FROM task WHERE parent_id=$TO').fetchone()[0]
d=c.execute('SELECT COUNT(*) FROM decision WHERE task_id=$TO AND needs_user=1').fetchone()[0]
b=c.execute(\"SELECT COUNT(*) FROM event WHERE kind='fix.batch' AND goal_id=$GO\").fetchone()[0]
print(f'{f} {d} {b}')")
# The daemon must still be alive and evaluating: a fourth poll that dispatches
# nothing new is the difference between "handled" and "the loop is wedged".
fleet daemon run --once >/dev/null 2>&1
O_RC=$?
O_STILL=$(n_fix "$TO")
# Restore the context and the very next poll builds exactly one fixer.
printf 'project context body\n' > "$FLEET_HOME/o-ctx.txt"
fleet daemon run --once >/dev/null 2>&1
O_REC=$(n_fix "$TO")
O_RECSPEC=$(python3 -c "import sqlite3
r=sqlite3.connect('$DB').execute('SELECT spec_path FROM task WHERE parent_id=$TO ORDER BY id').fetchone()
print(r[0] if r else '')")
O_HASCTX=$(grep -c 'project context body' "$O_RECSPEC" 2>/dev/null || true)
if [ "$O_STATE" = "0 1 0" ] && [ "$O_RC" = "0" ] && [ "$O_STILL" = "0" ] \
   && [ "$O_REC" = "1" ] && [ "$O_HASCTX" -ge 1 ]; then
  ok "O: a failing enqueue leaves zero fixer rows across repeated polls, records one needs-user decision, and dispatches exactly one fixer once the cause is cleared"
else
  no "O: after3='$O_STATE' (want '0 1 0') poll4_rc=$O_RC still=$O_STILL recovered=$O_REC ctx_in_spec=$O_HASCTX"
fi

# --- O2. ANY exception after the INSERT rolls back, not just the known set --
#
# Moving the validations above the INSERT closes the one hole we found; the
# catch-all rollback is what stops the NEXT one -- a validation added below
# the INSERT, an sqlite error, a vanished template. Without it, whatever
# raises reaches the poll loop, whose error logger commits the half-open
# transaction: one leaked queued fixer per poll, forever, with no rule.fired
# and no fix.batch to show for it. FLEET_FIX_FAULT=after-insert raises inside
# create_task with the row already written, which is that exact window.
GO2=$(new_goal gO2)
RO2=$(new_repo repoO2)
TO2=$(run_source "$GO2" "$RO2" "O2 source")
CO2=$(fleet claim add "$TO2" "o2 claim" --evidence "e")
fleet claim verify "$CO2" --status refuted --note "o2 note" >/dev/null
FLEET_FIX_FAULT=after-insert fleet daemon run --once >/dev/null 2>&1
FLEET_FIX_FAULT=after-insert fleet daemon run --once >/dev/null 2>&1
FLEET_FIX_FAULT=after-insert fleet daemon run --once >/dev/null 2>&1
O2_STATE=$(python3 -c "import sqlite3
c=sqlite3.connect('$DB')
f=c.execute('SELECT COUNT(*) FROM task WHERE parent_id=$TO2').fetchone()[0]
d=c.execute('SELECT COUNT(*) FROM decision WHERE task_id=$TO2 AND needs_user=1').fetchone()[0]
b=c.execute(\"SELECT COUNT(*) FROM event WHERE kind='fix.batch' AND goal_id=$GO2\").fetchone()[0]
e=c.execute(\"SELECT COUNT(*) FROM event WHERE kind='rule.error' AND task_id=$TO2\").fetchone()[0]
print(f'{f} {d} {b} {e}')")
# Fault off: the fix dispatches normally, so the block really was a "not yet".
fleet daemon run --once >/dev/null 2>&1
O2_REC=$(n_fix "$TO2")
if [ "$O2_STATE" = "0 1 0 1" ] && [ "$O2_REC" = "1" ]; then
  ok "O2: an unexpected exception after the INSERT rolls the row back -- zero leaked fixers over three polls, one deduped decision and one rule.error, and the fix dispatches once the fault is cleared"
else
  no "O2: during_fault='$O2_STATE' (want '0 1 0 1') recovered=$O2_REC (want 1)"
fi

# --- P. batch 2 starts from batch 1's tip, not from the source's -----------
#
# The waiting rule (case K) keeps two fixers off one worktree, but batch 2 was
# still pinned to the SOURCE branch tip: fixer 1's committed correction was
# simply absent from fixer 2's baseline, so fixer 2 would fix code fixer 1 had
# already changed and, on merge, undo it. The assertion is file content in
# fixer 2's worktree, not a column value.
GP=$(new_goal gP)
RP=$(new_repo repoP)
TP=$(run_source "$GP" "$RP" "P source")
P_SRC_TIP=$(git -C "$RP" rev-parse "fleet/task-$TP")
CP1=$(fleet claim add "$TP" "p claim one" --evidence "e1")
fleet claim verify "$CP1" --status refuted --note "P-NOTE-ONE" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FP1=$(fix_of "$TP")
fleet daemon run --once >/dev/null 2>&1
for i in $(seq 1 60); do [ -d "$FLEET_HOME/worktrees/task-$FP1" ] && break; sleep 0.2; done
for i in $(seq 1 100); do
  case "$(field "$FP1" status)" in done|failed|cancelled) break ;; esac
  sleep 0.2
done
# Fixer 1 does what a fixer does: commits its correction on its own branch.
P_WT1="$FLEET_HOME/worktrees/task-$FP1"
printf 'the first batch fixed this\n' > "$P_WT1/first-fix.txt"
git -C "$P_WT1" add -A
git -C "$P_WT1" -c user.email=t@t.t -c user.name=t commit -qm first-fix
P_TIP1=$(git -C "$RP" rev-parse "fleet/task-$FP1")
python3 -c "import sqlite3,time
c=sqlite3.connect('$DB')
c.execute(\"UPDATE task SET status='done', ended_at=?, pid=NULL WHERE id=$FP1\",(int(time.time()),))
c.commit()"
CP2=$(fleet claim add "$TP" "p claim two" --evidence "e2")
fleet claim verify "$CP2" --status refuted --note "P-NOTE-TWO" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FP2=$(python3 -c "import sqlite3
r=sqlite3.connect('$DB').execute('SELECT id FROM task WHERE parent_id=$TP ORDER BY id').fetchall()
print(r[-1][0] if len(r)>1 else '')")
P_BASE=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute('SELECT base_commit FROM task WHERE id=$FP2').fetchone()[0])" 2>/dev/null || echo none)
P_EV=$(python3 -c "import sqlite3,json
c=sqlite3.connect('$DB')
rows=[json.loads(r[0]) for r in c.execute(\"SELECT payload FROM event WHERE kind='fix.batch' AND goal_id=$GP ORDER BY id\")]
p=rows[-1]
print(f\"{p.get('base_from')} {p.get('batch')}\")" 2>/dev/null || echo "none none")
fleet daemon run --once >/dev/null 2>&1
for i in $(seq 1 60); do [ -d "$FLEET_HOME/worktrees/task-$FP2" ] && break; sleep 0.2; done
P_HASFIX=$([ -e "$FLEET_HOME/worktrees/task-$FP2/first-fix.txt" ] && echo yes || echo no)
P_SPEC=$(python3 -c "import sqlite3;print(sqlite3.connect('$DB').execute('SELECT spec_path FROM task WHERE id=$FP2').fetchone()[0])" 2>/dev/null || echo /nonexistent)
P_SAYS=$(python3 - "$P_SPEC" "$FP1" <<'PY'
import sys
try: s = open(sys.argv[1]).read()
except OSError: print("no-spec"); raise SystemExit
bad = []
if "batch 2" not in s: bad.append("does not say batch 2")
if f"task {sys.argv[2]}" not in s: bad.append("does not name the previous fixer")
print("ok" if not bad else ";".join(bad))
PY
)
if [ "$P_BASE" = "$P_TIP1" ] && [ "$P_TIP1" != "$P_SRC_TIP" ] && [ "$P_HASFIX" = "yes" ] \
   && [ "$P_SAYS" = "ok" ] && [ "$P_EV" = "$FP1 2" ]; then
  ok "P: batch 2 branches from batch 1's tip -- its worktree carries batch 1's commit, its spec names the batch and the previous fixer, and fix.batch records base_from/batch"
else
  no "P: base=$P_BASE tip1=$P_TIP1 src_tip=$P_SRC_TIP first_fix_present=$P_HASFIX spec=$P_SAYS ev='$P_EV' (want '$FP1 2')"
fi

# --- Q. a dirty previous fixer blocks the next batch, and recovers ---------
#
# Same discipline as case G, one link further down the chain: if batch 1's
# worktree has uncommitted work, batch 2's baseline is indeterminate. It must
# block naming FIXER 1 -- not silently fall back to the source tip, which is
# exactly the bug case P pins.
GQ=$(new_goal gQ)
RQ=$(new_repo repoQ)
TQ=$(run_source "$GQ" "$RQ" "Q source")
CQ1=$(fleet claim add "$TQ" "q claim one" --evidence "e1")
fleet claim verify "$CQ1" --status refuted --note "Q-NOTE-ONE" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FQ1=$(fix_of "$TQ")
fleet daemon run --once >/dev/null 2>&1
for i in $(seq 1 60); do [ -d "$FLEET_HOME/worktrees/task-$FQ1" ] && break; sleep 0.2; done
for i in $(seq 1 100); do
  case "$(field "$FQ1" status)" in done|failed|cancelled) break ;; esac
  sleep 0.2
done
Q_WT1="$FLEET_HOME/worktrees/task-$FQ1"
printf 'half-done work nobody committed\n' > "$Q_WT1/scratch.txt"
python3 -c "import sqlite3,time
c=sqlite3.connect('$DB')
c.execute(\"UPDATE task SET status='done', ended_at=?, pid=NULL WHERE id=$FQ1\",(int(time.time()),))
c.commit()"
CQ2=$(fleet claim add "$TQ" "q claim two" --evidence "e2")
fleet claim verify "$CQ2" --status refuted --note "Q-NOTE-TWO" >/dev/null
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
Q_BLOCKED=$(python3 -c "import sqlite3
c=sqlite3.connect('$DB')
n=c.execute('SELECT COUNT(*) FROM task WHERE parent_id=$TQ').fetchone()[0]
d=[r[0] for r in c.execute(\"SELECT question FROM decision WHERE task_id=$TQ AND needs_user=1\")]
hit=[q for q in d if 'prev_fixer' in q and '$FQ1' in q]
print(f'{n} {len(d)} {len(hit)}')")
# Clean it up and the next poll dispatches batch 2 from the (now clean) tip.
rm -f "$Q_WT1/scratch.txt"
fleet daemon run --once >/dev/null 2>&1
Q_TIP1=$(git -C "$RQ" rev-parse "fleet/task-$FQ1")
Q_REC=$(python3 -c "import sqlite3
c=sqlite3.connect('$DB')
r=c.execute('SELECT id,base_commit FROM task WHERE parent_id=$TQ ORDER BY id').fetchall()
print(f'{len(r)} {r[-1][1]}')")
if [ "$Q_BLOCKED" = "1 1 1" ] && [ "$Q_REC" = "2 $Q_TIP1" ]; then
  ok "Q: an uncommitted previous fixer blocks the next batch with a decision naming that fixer; cleaning it dispatches batch 2 from its tip"
else
  no "Q: while_dirty='$Q_BLOCKED' (want '1 1 1') after_clean='$Q_REC' (want '2 $Q_TIP1')"
fi

# --- R. an archived previous fixer blocks the next batch --------------------
#
# One link further than case Q again: batch 1's fixer is not dirty, it is
# GONE. `fleet archive` moves a terminal fixer out while its source task stays
# (_archive_plan only refuses when the archived row is still REFERENCED, and a
# fixer references its source, not the other way round). The chain lookup then
# found no row, left prev_fixer=None, and fix_construction quietly based batch
# 2 on the SOURCE tip -- batch 1's commit dropped, no event, no decision. That
# is the same silent regression case P pins, reached through a different door,
# so it must block instead. Deleting the row directly is the archive's
# ledger-visible effect; the archive db itself is not what this case is about.
GR=$(new_goal gR)
RR=$(new_repo repoR)
TR=$(run_source "$GR" "$RR" "R source")
R_SRC_TIP=$(git -C "$RR" rev-parse "fleet/task-$TR")
CR1=$(fleet claim add "$TR" "r claim one" --evidence "e1")
fleet claim verify "$CR1" --status refuted --note "R-NOTE-ONE" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FR1=$(fix_of "$TR")
fleet daemon run --once >/dev/null 2>&1
for i in $(seq 1 60); do [ -d "$FLEET_HOME/worktrees/task-$FR1" ] && break; sleep 0.2; done
for i in $(seq 1 100); do
  case "$(field "$FR1" status)" in done|failed|cancelled) break ;; esac
  sleep 0.2
done
# Fixer 1 commits its correction, settles -- and is then archived away.
R_WT1="$FLEET_HOME/worktrees/task-$FR1"
printf 'the first batch fixed this\n' > "$R_WT1/first-fix.txt"
git -C "$R_WT1" add -A
git -C "$R_WT1" -c user.email=t@t.t -c user.name=t commit -qm first-fix
python3 -c "import sqlite3,time
c=sqlite3.connect('$DB')
c.execute(\"UPDATE task SET status='done', ended_at=?, pid=NULL WHERE id=$FR1\",(int(time.time()),))
c.execute('DELETE FROM attempt WHERE task_id=$FR1')
c.execute('DELETE FROM task WHERE id=$FR1')
c.commit()
assert c.execute('SELECT COUNT(*) FROM task WHERE id=$FR1').fetchone()[0] == 0"
CR2=$(fleet claim add "$TR" "r claim two" --evidence "e2")
fleet claim verify "$CR2" --status refuted --note "R-NOTE-TWO" >/dev/null
# Three polls: a block is deduped, so the second and third rounds must add
# neither a decision nor an event -- a per-second daemon would otherwise bury
# the one line the operator needs.
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
R_OUT=$(python3 -c "import sqlite3,json
c=sqlite3.connect('$DB')
# No new fixer: the deleted row is not counted, so a chained batch 2 would
# show up here as a row parented on the source.
n=c.execute('SELECT COUNT(*) FROM task WHERE parent_id=$TR').fetchone()[0]
ev=[json.loads(r[0]) for r in c.execute(
    \"SELECT payload FROM event WHERE kind='fix.blocked' AND task_id=$TR ORDER BY id\")]
miss=[p for p in ev if p.get('reason')=='prev_fixer_missing']
named=[p for p in miss if '$FR1' in (p.get('detail') or '')]
d=[r[0] for r in c.execute(
    \"SELECT question FROM decision WHERE task_id=$TR AND needs_user=1\")]
dm=[q for q in d if 'prev_fixer_missing' in q]
# The firing must NOT be consumed: restoring the row has to dispatch.
fired=[json.loads(r[0]) for r in c.execute(
    \"SELECT payload FROM event WHERE kind='rule.fired' AND goal_id=$GR\")]
f2=[p for p in fired if p.get('do')=='enqueue_fix' and int(p.get('max_event') or 0)>0]
print(f'{n} {len(ev)} {len(miss)} {len(named)} {len(d)} {len(dm)} {len(f2)}')")
# want: 0 new fixers beyond batch 1's (deleted, so 0 rows), exactly one
# fix.blocked with reason=prev_fixer_missing naming the vanished fixer,
# exactly one needs_user decision, and one firing (batch 1's) only.
if [ "$R_OUT" = "0 1 1 1 1 1 1" ]; then
  ok "R: an archived previous fixer blocks batch 2 -- one fix.blocked reason=prev_fixer_missing naming that fixer, one needs-user decision, no new fixer, stable over 3 polls"
else
  no "R: got '$R_OUT' want '0 1 1 1 1 1 1' (n_fix, n_blocked_ev, n_missing, n_named, n_dec, n_dec_missing, n_fired)"
fi

# --- S. a batch record that names no usable fixer blocks the same way -------
#
# The other door into the same hole: the row is fine, the RECORD is not. A
# fix.batch payload whose `fixer` is absent or not an id (a hand-edited
# ledger, a payload written by an older version) used to leave prev_fixer=None
# with the batch watermark still set -- so batch 2 re-branched off the source
# exactly as in case R. int(fixer) failing is not permission to guess.
GS=$(new_goal gS)
RS=$(new_repo repoS)
TS=$(run_source "$GS" "$RS" "S source")
CS1=$(fleet claim add "$TS" "s claim one" --evidence "e1")
fleet claim verify "$CS1" --status refuted --note "S-NOTE-ONE" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FS1=$(fix_of "$TS")
# Corrupt only the batch record's `fixer` field; the fixer row itself stays.
python3 -c "import sqlite3,json,time
c=sqlite3.connect('$DB')
r=c.execute(\"SELECT id,payload FROM event WHERE kind='fix.batch' AND goal_id=$GS ORDER BY id\").fetchall()
assert len(r)==1, r
p=json.loads(r[0][1]); assert p['fixer']==$FS1, p
p['fixer']='not-an-id'
c.execute('UPDATE event SET payload=? WHERE id=?',(json.dumps(p),r[0][0]))
c.execute(\"UPDATE task SET status='done', ended_at=?, pid=NULL WHERE id=$FS1\",(int(time.time()),))
c.commit()"
CS2=$(fleet claim add "$TS" "s claim two" --evidence "e2")
fleet claim verify "$CS2" --status refuted --note "S-NOTE-TWO" >/dev/null
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
S_OUT=$(python3 -c "import sqlite3,json
c=sqlite3.connect('$DB')
n=c.execute('SELECT COUNT(*) FROM task WHERE parent_id=$TS').fetchone()[0]
ev=[json.loads(r[0]) for r in c.execute(
    \"SELECT payload FROM event WHERE kind='fix.blocked' AND task_id=$TS ORDER BY id\")]
miss=[p for p in ev if p.get('reason')=='prev_fixer_missing']
d=[r[0] for r in c.execute(
    \"SELECT question FROM decision WHERE task_id=$TS AND needs_user=1\")]
print(f'{n} {len(miss)} {len(d)}')")
# want: still only batch 1's fixer, one prev_fixer_missing block, one decision
if [ "$S_OUT" = "1 1 1" ]; then
  ok "S: a fix.batch record whose fixer field is not an id blocks with prev_fixer_missing instead of re-branching batch 2 off the source"
else
  no "S: got '$S_OUT' want '1 1 1' (n_fix, n_missing_blocked, n_dec)"
fi


# --- T. an archived fixer's id reused by an unrelated task must not pass ----
#
# Review 375: task.id has no AUTOINCREMENT, so after `fleet archive` removes
# the highest-id fixer the next `fleet add` gets the same id. Looking the
# batch record's fixer up by number alone then finds a stranger and chains
# batch 2 off ITS branch. A fixer always has the source as parent_id; a row
# with that id but another parent is not the fixer.
GT=$(new_goal gT)
RT=$(new_repo repoT)
TT=$(run_source "$GT" "$RT" "T source")
CT1=$(fleet claim add "$TT" "t claim one" --evidence "e1")
fleet claim verify "$CT1" --status refuted --note "T-NOTE-ONE" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FT1=$(fix_of "$TT")
fleet daemon run --once >/dev/null 2>&1
for i in $(seq 1 100); do
  case "$(field "$FT1" status)" in done|failed|cancelled) break ;; esac
  sleep 0.2
done
python3 -c "import sqlite3,time
c=sqlite3.connect('$DB')
c.execute('DELETE FROM attempt WHERE task_id=$FT1')
c.execute('DELETE FROM task WHERE id=$FT1')
c.execute(\"INSERT INTO task(id,title,channel,family,status,cwd,created_at) VALUES($FT1,'stranger','shell','none','done','$RT',?)\",(int(time.time()),))
c.commit()"
CT2=$(fleet claim add "$TT" "t claim two" --evidence "e2")
fleet claim verify "$CT2" --status refuted --note "T-NOTE-TWO" >/dev/null
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
T_OUT=$(python3 -c "import sqlite3,json
c=sqlite3.connect('$DB')
n=c.execute('SELECT COUNT(*) FROM task WHERE parent_id=$TT').fetchone()[0]
ev=[json.loads(r[0]) for r in c.execute(
    \"SELECT payload FROM event WHERE kind='fix.blocked' AND task_id=$TT ORDER BY id\")]
miss=[p for p in ev if p.get('reason')=='prev_fixer_missing']
d=[r[0] for r in c.execute(
    \"SELECT question FROM decision WHERE task_id=$TT AND needs_user=1\")]
print(f'{n} {len(miss)} {len(d)}')")
if [ "$T_OUT" = "0 1 1" ]; then
  ok "T: a stranger task holding the archived fixer's id does not pass as the previous fixer -- batch 2 blocks with prev_fixer_missing"
else
  no "T: got '$T_OUT' want '0 1 1' (n_fix, n_missing_blocked, n_dec)"
fi

# --- U. a float fixer id in the batch record is not an id ------------------
#
# Review 375: int(41.5) is 41, a real row. The record's value must be an int.
GU=$(new_goal gU)
RU=$(new_repo repoU)
TU=$(run_source "$GU" "$RU" "U source")
CU1=$(fleet claim add "$TU" "u claim one" --evidence "e1")
fleet claim verify "$CU1" --status refuted --note "U-NOTE-ONE" >/dev/null
fleet daemon run --once >/dev/null 2>&1
FU1=$(fix_of "$TU")
python3 -c "import sqlite3,json,time
c=sqlite3.connect('$DB')
r=c.execute(\"SELECT id,payload FROM event WHERE kind='fix.batch' AND goal_id=$GU ORDER BY id\").fetchall()
p=json.loads(r[0][1]); assert p['fixer']==$FU1, p
p['fixer']=$FU1+0.5
c.execute('UPDATE event SET payload=? WHERE id=?',(json.dumps(p),r[0][0]))
c.execute(\"UPDATE task SET status='done', ended_at=?, pid=NULL WHERE id=$FU1\",(int(time.time()),))
c.commit()"
CU2=$(fleet claim add "$TU" "u claim two" --evidence "e2")
fleet claim verify "$CU2" --status refuted --note "U-NOTE-TWO" >/dev/null
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
U_OUT=$(python3 -c "import sqlite3,json
c=sqlite3.connect('$DB')
n=c.execute('SELECT COUNT(*) FROM task WHERE parent_id=$TU').fetchone()[0]
ev=[json.loads(r[0]) for r in c.execute(
    \"SELECT payload FROM event WHERE kind='fix.blocked' AND task_id=$TU ORDER BY id\")]
miss=[p for p in ev if p.get('reason')=='prev_fixer_missing']
print(f'{n} {len(miss)}')")
if [ "$U_OUT" = "1 1" ]; then
  ok "U: a float fixer id in the batch record blocks instead of truncating to a real row"
else
  no "U: got '$U_OUT' want '1 1' (n_fix, n_missing_blocked)"
fi

# --- V. a same-named STRANGER branch is refused, not adopted ---------------
#
# Task 401. `worktree add -b` fails when the branch name is taken, and the old
# fallback then checked that branch out -- so a leftover `fleet/task-<id>` from
# another ledger, or an id `archive` released and a new task reused, became this
# task's worktree while meta.json still recorded the repo HEAD as the base.
# `fleet diff` then reported the stranger's commits as this task's deliverable
# and the auto-fix chain branched from them. A collision must block visibly.
GV=$(new_goal gV)
RV=$(new_repo repoV)
TV=$(fleet add "V victim" --channel shell --worktree --cwd "$RV" \
       --spec "$FLEET_HOME/spec_work.sh" --goal "$GV")
# A stranger takes the name and commits on it, then releases the worktree the
# way a pruned/legacy leftover would: the ref survives, nothing checks it out.
git -C "$RV" worktree add -q -b "fleet/task-$TV" "$FLEET_HOME/stranger-V" HEAD
printf 'code nobody asked this task for\n' > "$FLEET_HOME/stranger-V/stranger.txt"
git -C "$FLEET_HOME/stranger-V" add -A
git -C "$FLEET_HOME/stranger-V" -c user.email=s@s.s -c user.name=s commit -qm stranger
V_STRANGER_TIP=$(git -C "$RV" rev-parse "fleet/task-$TV")
git -C "$RV" worktree remove --force "$FLEET_HOME/stranger-V"
# Two rounds: the block must be stable, and the decision must not be per-round
# spam.
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
V_OUT=$(python3 -c "import sqlite3
c=sqlite3.connect('$DB')
st,att,wt=c.execute('SELECT status,attempt,worktree FROM task WHERE id=$TV').fetchone()
ev=c.execute(\"SELECT COUNT(*) FROM event WHERE task_id=$TV AND kind='task.blocked' \"
             \"AND json_extract(payload,'\$.reason')='worktree'\").fetchone()[0]
de=c.execute(\"SELECT COUNT(*) FROM decision WHERE task_id=$TV AND needs_user=1 \"
             \"AND question LIKE 'worktree:%'\").fetchone()[0]
print(f'{st} {att} {\"wt\" if wt else \"nowt\"} {ev} {de}')")
V_ADOPTED=$([ -e "$FLEET_HOME/worktrees/task-$TV/stranger.txt" ] && echo yes || echo no)
V_TIP_MOVED=$([ "$(git -C "$RV" rev-parse "fleet/task-$TV")" = "$V_STRANGER_TIP" ] && echo no || echo yes)
# Clearing the stranger branch is all it takes: the next round starts clean and
# the diff contains this task's own work only.
git -C "$RV" branch -D "fleet/task-$TV" >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
wait_status "$TV" done >/dev/null 2>&1
V_DIFF=$(fleet diff "$TV" 2>&1)
V_AFTER=$(field "$TV" status)
V_DIFF_OK=$(printf '%s' "$V_DIFF" | grep -q "stranger.txt" && echo has-stranger || {
  printf '%s' "$V_DIFF" | grep -q "uniq.txt" && echo own-only || echo "unexpected:$V_DIFF"; })
if [ "$V_OUT" = "queued 0 nowt 2 1" ] && [ "$V_ADOPTED" = "no" ] \
   && [ "$V_TIP_MOVED" = "no" ] && [ "$V_AFTER" = "done" ] \
   && [ "$V_DIFF_OK" = "own-only" ]; then
  ok "V: a same-named stranger branch blocks the task (reason=worktree, one decision over two rounds, no worktree, stranger tip untouched); deleting it starts the task clean and its diff holds only its own work"
else
  no "V: state='$V_OUT' (want 'queued 0 nowt 2 1') adopted=$V_ADOPTED tip_moved=$V_TIP_MOVED after=$V_AFTER diff=$V_DIFF_OK"
fi

# --- W. a task's OWN leftover branch is still reused on the next attempt ----
#
# The other half of 401: refusing every existing branch would wedge the retry
# path the fallback was written for. A crash after `git worktree add` but before
# the row update leaves the branch (and possibly commits on it) with no
# registered worktree -- that IS this task's history, and attempt 2 must
# continue it from the SAME recorded base, not re-baseline onto the repo HEAD.
GW=$(new_goal gW)
RW=$(new_repo repoW)
TW=$(fleet add "W retry" --channel shell --worktree --cwd "$RW" \
       --spec "$FLEET_HOME/spec_work.sh" --goal "$GW" --max-attempts 3)
fleet daemon run --once >/dev/null 2>&1
wait_status "$TW" done >/dev/null 2>&1
W_BASE1=$(python3 -c "import json;print((json.load(open('$FLEET_HOME/runs/$TW/meta.json')).get('worktree') or {}).get('base',''))")
W_WT="$FLEET_HOME/worktrees/task-$TW"
W_OWN_TIP=$(git -C "$RW" rev-parse "fleet/task-$TW")
# The repo moves on after attempt 1: if attempt 2 re-baselined onto HEAD, the
# recorded base would change and `fleet diff` would silently re-scope.
printf 'upstream moved\n' > "$RW/moved.txt"
git -C "$RW" add -A
git -C "$RW" commit -qm moved
# The crash shape: directory gone and row NULLed, branch and its commit left.
rm -rf "$W_WT"
git -C "$RW" worktree prune
python3 -c "import sqlite3
c=sqlite3.connect('$DB')
c.execute(\"UPDATE task SET worktree=NULL, status='queued', pid=NULL WHERE id=$TW\")
c.commit()"
fleet daemon run --once >/dev/null 2>&1
wait_status "$TW" done >/dev/null 2>&1
W_BASE2=$(python3 -c "import json;print((json.load(open('$FLEET_HOME/runs/$TW/meta.json')).get('worktree') or {}).get('base',''))")
W_HEAD2=$(git -C "$W_WT" rev-parse HEAD 2>/dev/null || echo NONE)
W_BRANCH2=$(git -C "$W_WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo NONE)
W_KEPT=$([ -e "$W_WT/uniq.txt" ] && echo yes || echo no)
W_BLOCKED=$(python3 -c "import sqlite3
print(sqlite3.connect('$DB').execute(
  \"SELECT COUNT(*) FROM event WHERE task_id=$TW AND kind='task.blocked' \"
  \"AND json_extract(payload,'\$.reason')='worktree'\").fetchone()[0])")
if [ -n "$W_BASE1" ] && [ "$W_BASE1" = "$W_BASE2" ] \
   && [ "$W_BRANCH2" = "fleet/task-$TW" ] && [ "$W_HEAD2" = "$W_OWN_TIP" ] \
   && [ "$W_KEPT" = "yes" ] && [ "$W_BLOCKED" = "0" ]; then
  ok "W: attempt 2 reuses the task's own leftover branch and directory at its own tip, keeps meta.json's base unchanged even after the repo moved on, and blocks nothing"
else
  no "W: base $W_BASE1 -> $W_BASE2 branch=$W_BRANCH2 head=$W_HEAD2 own_tip=$W_OWN_TIP work_kept=$W_KEPT blocked=$W_BLOCKED"
fi

# --- X. an id released by `archive` and reused behaves exactly like case V ---
#
# Task ids have no AUTOINCREMENT, so `archive` releasing the tail of the table
# lets a NEW task be handed an old task's number while the old task's branch is
# still in the repo. The new task must not inherit it: same refusal as V, by the
# same ownership rule, with no special case for "the row is gone".
GX=$(new_goal gX)
RX=$(new_repo repoX)
TX=$(fleet add "X original" --channel shell --worktree --cwd "$RX" \
       --spec "$FLEET_HOME/spec_work.sh" --goal "$GX")
fleet daemon run --once >/dev/null 2>&1
wait_status "$TX" done >/dev/null 2>&1
X_OLD_TIP=$(git -C "$RX" rev-parse "fleet/task-$TX")
# Retire it the way archive does -- the row leaves the live ledger, the branch
# stays in the repo -- and hand the freed id to a new task.
rm -rf "$FLEET_HOME/worktrees/task-$TX"
git -C "$RX" worktree prune
python3 -c "import sqlite3
c=sqlite3.connect('$DB')
c.execute('PRAGMA foreign_keys=OFF')
for t in ('attempt','event','claim','review','artifact','decision'):
    try: c.execute(f'DELETE FROM {t} WHERE task_id=$TX')
    except sqlite3.Error: pass
c.execute('DELETE FROM task WHERE id=$TX')
c.commit()"
TX2=$(fleet add "X reuser" --channel shell --worktree --cwd "$RX" \
        --spec "$FLEET_HOME/spec_work.sh" --goal "$GX")
X_REUSED=$([ "$TX2" = "$TX" ] && echo yes || echo no)
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
X_OUT=$(python3 -c "import sqlite3
c=sqlite3.connect('$DB')
st,wt=c.execute('SELECT status,worktree FROM task WHERE id=$TX2').fetchone()
ev=c.execute(\"SELECT COUNT(*) FROM event WHERE task_id=$TX2 AND kind='task.blocked' \"
             \"AND json_extract(payload,'\$.reason')='worktree'\").fetchone()[0]
de=c.execute(\"SELECT COUNT(*) FROM decision WHERE task_id=$TX2 AND needs_user=1 \"
             \"AND question LIKE 'worktree:%'\").fetchone()[0]
print(f'{st} {\"wt\" if wt else \"nowt\"} {ev} {de}')")
X_TIP_HELD=$([ "$(git -C "$RX" rev-parse "fleet/task-$TX2")" = "$X_OLD_TIP" ] && echo yes || echo no)
if [ "$X_REUSED" = "yes" ] && [ "$X_OUT" = "queued nowt 2 1" ] \
   && [ "$X_TIP_HELD" = "yes" ]; then
  ok "X: a task handed an archived task's id refuses that id's leftover branch instead of adopting its commits -- same reason=worktree block and single decision as case V"
else
  no "X: id_reused=$X_REUSED state='$X_OUT' (want 'queued nowt 2 1') old_tip_intact=$X_TIP_HELD"
fi

# --- Y. a failed dep makes a queued task permanently unrunnable; the daemon
#       names it ONCE ------------------------------------------------------
#
# Task 521: `fleet add --dep` on an already-failed task used to enqueue fine,
# and the task sat in queued for hours -- deps_done reports "not done" every
# poll, but the block event only said reason=dep, indistinguishable from
# "waiting on a running dep". The daemon now logs reason=dep_terminal (with
# the dep id and the dep's state) once per block episode; log_blocked's
# episode dedup keeps a per-2s daemon from re-writing the same line forever.
GY=$(new_goal gY)
printf 'echo boom; exit 1\n' > "$FLEET_HOME/spec_fail_y.sh"
TYF=$(fleet add "Y fail" --channel shell --no-preamble \
        --spec "$FLEET_HOME/spec_fail_y.sh" --goal "$GY")
fleet daemon run --once >/dev/null 2>&1
for i in $(seq 1 100); do
  [ "$(field "$TYF" status)" = failed ] && break; sleep 0.2
done
TYC=$(fleet add "Y child" --channel shell --no-preamble \
        --spec "$FLEET_HOME/spec_echo.sh" --goal "$GY" --dep "$TYF" \
        --force-dep)
# Four poll rounds: the dep is terminal from the first one on.
for _ in 1 2 3 4; do fleet daemon run --once >/dev/null 2>&1; done
Y_OUT=$(python3 -c "import sqlite3,json
c=sqlite3.connect('$DB')
st=c.execute('SELECT status FROM task WHERE id=?',($TYC,)).fetchone()[0]
rows=list(c.execute(
    \"SELECT payload FROM event WHERE task_id=? AND kind='task.blocked' ORDER BY id\",
    ($TYC,)))
term=[json.loads(r[0]) for r in rows if json.loads(r[0]).get('reason')=='dep_terminal']
dep=[json.loads(r[0]) for r in rows if json.loads(r[0]).get('reason')=='dep']
dep_ok=all(int(p.get('dep'))==$TYF and p.get('state')=='failed' for p in term)
print(f'{st} {len(rows)} {len(term)} {len(dep)} {\"ok\" if dep_ok else \"bad\"}')")
# want: still queued; exactly one task.blocked event total; it is dep_terminal
# naming the failed dep; zero reason=dep events (a running/waiting dep and a
# dead dep must not look the same in the ledger).
if [ "$Y_OUT" = "queued 1 1 0 ok" ]; then
  ok "Y: a failed dep yields one dep_terminal block (names dep+failed state) over 4 polls, task stays queued, never reason=dep"
else
  no "Y: got '$Y_OUT' want 'queued 1 1 0 ok' (status, n_blocked, n_dep_terminal, n_dep, payload)"
fi

echo "passed $PASS / $N"
[ "$FAIL" = "0" ] || exit 1
