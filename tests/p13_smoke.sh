#!/usr/bin/env bash
# fleet P13 smoke tests: --dep-base worktree baselines, batch commander ops
# (claim verify / goal close / decisions resolve), and /var/tmp/fleet
# list/prune. Zero model quota: shell channel + throwaway git repos.
#
# C2  --dep alone orders execution; --dep-base makes the dep's worktree
#     branch the baseline. Pre-fix every worktree branched from the repo
#     HEAD, so a fix task silently started from a base that predated the
#     fix it built on (P11/P12b both paid for this).
# C3  the commander hand-UPDATE-d the ledger to handle a round's twenty-odd
#     claims, which wrote no claim.verify events. claim verify is now
#     batch; goal close and decisions resolve close the other two gaps.
# B   task TMPDIRs are kept on purpose and never auto-deleted, so the tree
#     grows with every test run; tmp list/prune make it visible and
#     manually reclaimable, never silent.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p13-test-XXXX)"
export PATH="$ROOT/bin:$PATH"
unset _FLEET_LOCK_FD

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

cleanup(){
  fleet daemon stop >/dev/null 2>&1 || true
  # Remove this suite's scratch hash dir and any fake hash dirs it made, so
  # the shared /var/tmp/fleet does not accumulate test residue.
  # UNKNOWN_HASH_DIR too: case 18 only removes it on the success path, so a
  # red run used to leave it in the shared tree for good.
  # :- because the trap is armed before these are assigned, and `set -u` would
  # turn an early failure into an unbound-variable error inside cleanup.
  rm -rf "${SELF_HASH_DIR:-}" "${FAKE_HASH_DIR:-}" "${UNKNOWN_HASH_DIR:-}" 2>/dev/null || true
  rm -rf "$FLEET_HOME"
}
trap cleanup EXIT

fleet init >/dev/null
printf 'echo hi\n' > "$FLEET_HOME/spec_echo.sh"
printf 'sleep 15\n' > "$FLEET_HOME/spec_sleep.sh"

# A throwaway git repo plays the "user's repository".
REPO="$FLEET_HOME/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'original\n' > "$REPO/same.txt"
git -C "$REPO" add same.txt
git -C "$REPO" commit -qm base
printf 'echo A > same.txt\n' > "$FLEET_HOME/specA.sh"
printf 'echo B > same.txt\n' > "$FLEET_HOME/specB.sh"

# The hash dir this ledger's tasks scratch under.
SELF_HASH=$(python3 -c "import hashlib,pathlib,os;print(hashlib.sha256(str(pathlib.Path(os.environ['FLEET_HOME']).resolve()).encode()).hexdigest()[:12])")
SELF_HASH_DIR="/var/tmp/fleet/$SELF_HASH"
# The two fake hash dirs live in /var/tmp/fleet, which is machine-wide (one
# TMP_ROOT for every ledger), and `fleet tmp prune` walks all of it. Fixed
# names therefore collide between concurrent runs -- and the collision is
# invisible: copy A creates its orphan, copy B's prune sweeps it, copy A then
# reports "0 orphan" and case 18 goes red for a reason nothing in its own
# output explains. Seen under tests/run-all.sh and under the mutation runner,
# green every time when run alone. The suite's FLEET_HOME is a mktemp, so its
# random suffix is the one thing here that is already unique per run.
UNIQ="${FLEET_HOME##*-}"
FAKE_HASH_DIR="/var/tmp/fleet/p13fake$UNIQ"
UNKNOWN_HASH_DIR="/var/tmp/fleet/p13unknown$UNIQ"

# --- C2: --dep-base -------------------------------------------------------

# 1. a worktree dep's changes ARE the baseline: B's worktree contains A's
#    edit, and the repo HEAD is untouched.
TA=$(fleet add "c2 A" --channel shell --worktree --cwd "$REPO" --spec "$FLEET_HOME/specA.sh")
fleet run "$TA" >/dev/null
wait_status "$TA" done
TB=$(fleet add "c2 B" --channel shell --worktree --cwd "$REPO" \
      --dep "$TA:base" --spec "$FLEET_HOME/specB.sh")
fleet run "$TB" >/dev/null
wait_status "$TB" done
WB=$(field "$TB" worktree)
if [ "$(cat "$WB/same.txt")" = "B" ] \
   && [ "$(cat "$REPO/same.txt")" = "original" ] \
   && fleet show "$TB" | grep -q "baseline: task-$TA:fleet/task-$TA"; then
  ok "C2: --dep ID:base bases B's worktree on A's branch tip (B on top of A)"
else
  no "C2: dep-base inheritance (B='$(cat "$WB/same.txt" 2>/dev/null)' repo='$(cat "$REPO/same.txt")')"
fi

# 2. the --dep-base flag form, single dep, works the same.
TC=$(fleet add "c2 C" --channel shell --worktree --cwd "$REPO" \
      --dep "$TB" --dep-base --spec "$FLEET_HOME/specA.sh")
fleet run "$TC" >/dev/null
wait_status "$TC" done
WC=$(field "$TC" worktree)
if [ "$(cat "$WC/same.txt")" = "A" ] \
   && fleet show "$TC" | grep -q "baseline: task-$TB:fleet/task-$TB"; then
  ok "C2: --dep-base flag with one dep bases on that dep's branch"
else
  no "C2: --dep-base flag (C='$(cat "$WC/same.txt" 2>/dev/null)')"
fi

# 3. a dep WITHOUT a worktree falls back to the repo HEAD and says so:
#    a task.base_fallback event, and show names the fallback.
TN=$(fleet add "c2 nowt" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$TN" >/dev/null
wait_status "$TN" done
TD=$(fleet add "c2 D" --channel shell --worktree --cwd "$REPO" \
      --dep "$TN:base" --spec "$FLEET_HOME/specB.sh")
fleet run "$TD" >/dev/null
wait_status "$TD" done
WD=$(field "$TD" worktree)
fb_event=$(sqlite3 "$FLEET_HOME/fleet.db" \
  "SELECT payload FROM event WHERE task_id=$TD AND kind='task.base_fallback'")
if [ "$(cat "$WD/same.txt")" = "B" ] \
   && printf '%s' "$fb_event" | grep -q "no worktree" \
   && fleet show "$TD" | grep -q "baseline: repo HEAD"; then
  ok "C2: dep without worktree falls back to HEAD with a base_fallback event"
else
  no "C2: no-worktree fallback (D='$(cat "$WD/same.txt" 2>/dev/null)' event='$fb_event')"
fi

# 4. two bases are refused at enqueue with exit 15 (auto-merge is the bug).
fleet add "c2 multi" --channel shell --worktree --cwd "$REPO" \
  --dep "$TA:base" --dep "$TB:base" --spec "$FLEET_HOME/specB.sh" \
  >"$FLEET_HOME/e4" 2>&1
rc4=$?
if [ "$rc4" = "15" ] && grep -qi "more than one dep base" "$FLEET_HOME/e4"; then
  ok "C2: multiple :base deps refused with exit 15"
else
  no "C2: multi-base refusal (rc=$rc4 out='$(cat "$FLEET_HOME/e4")')"
fi

# 5. --dep-base with several deps is refused (which one is the base?);
#    --dep-base without --worktree is refused (no worktree to base).
fleet add "c2 flagmulti" --channel shell --worktree --cwd "$REPO" \
  --dep "$TA" --dep "$TB" --dep-base --spec "$FLEET_HOME/specB.sh" \
  >"$FLEET_HOME/e5a" 2>&1
rc5a=$?
fleet add "c2 nowtbase" --channel shell --dep "$TA:base" \
  --spec "$FLEET_HOME/specB.sh" >"$FLEET_HOME/e5b" 2>&1
rc5b=$?
if [ "$rc5a" = "15" ] && [ "$rc5b" = "15" ]; then
  ok "C2: --dep-base with multiple deps, or without --worktree, refused (15)"
else
  no "C2: dep-base refusals (rc=$rc5a/$rc5b)"
fi

# 6. base_task is recorded on the row (show prints it) and in task.add.
if [ "$(field "$TB" base_task)" = "$TA" ] \
   && sqlite3 "$FLEET_HOME/fleet.db" \
      "SELECT payload FROM event WHERE task_id=$TB AND kind='task.add'" \
      | grep -q "\"base_task\": $TA"; then
  ok "C2: base_task recorded on the task row and task.add event"
else
  no "C2: base_task recording (row='$(field "$TB" base_task)')"
fi

# --- C3: batch commander ops ----------------------------------------------

# 7. claim verify --task: every unverified claim of the task, one event each,
#    --by/--note landed in every event.
T7=$(fleet add "c3 t7" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
for c in one two three; do
  fleet claim add "$T7" "claim $c" --evidence "spec:1" >/dev/null
done
fleet claim verify --task "$T7" --status confirmed --by "$TA" --note "batch round" \
  >"$FLEET_HOME/v7" 2>&1
rc7=$?
n_events=$(sqlite3 "$FLEET_HOME/fleet.db" \
  "SELECT COUNT(*) FROM event WHERE kind='claim.verify' AND json_extract(payload,'\$.by')=$TA")
n_note=$(sqlite3 "$FLEET_HOME/fleet.db" \
  "SELECT COUNT(*) FROM event WHERE kind='claim.verify' AND json_extract(payload,'\$.note')='batch round'")
n_unver=$(sqlite3 "$FLEET_HOME/fleet.db" \
  "SELECT COUNT(*) FROM claim WHERE task_id=$T7 AND status='unverified'")
if [ "$rc7" = "0" ] && [ "$(grep -c 'claim .* confirmed' "$FLEET_HOME/v7")" = "3" ] \
   && [ "$n_events" = "3" ] && [ "$n_note" = "3" ] && [ "$n_unver" = "0" ]; then
  ok "C3: claim verify --task verifies all, one event each, --by/--note in each"
else
  no "C3: batch verify --task (rc=$rc7 events=$n_events note=$n_note unver=$n_unver)"
fi

# 8. claim verify --all-unverified plus an explicit (already-verified) id in
#    one command: both end up confirmed, one event each.
T8=$(fleet add "c3 t8" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
C8=$(fleet claim add "$T8" "claim eight" --evidence "spec:1")
fleet claim verify "$C8" --status refuted --resolution rebutted >/dev/null
T8b=$(fleet add "c3 t8b" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
C8b=$(fleet claim add "$T8b" "claim 8b" --evidence "spec:1")
fleet claim verify "$C8" --all-unverified --status confirmed >"$FLEET_HOME/v8" 2>&1
rc8=$?
c8_status=$(sqlite3 "$FLEET_HOME/fleet.db" "SELECT status FROM claim WHERE id=$C8")
c8b_status=$(sqlite3 "$FLEET_HOME/fleet.db" "SELECT status FROM claim WHERE id=$C8b")
n_ev8=$(sqlite3 "$FLEET_HOME/fleet.db" \
  "SELECT COUNT(*) FROM event WHERE kind='claim.verify' AND json_extract(payload,'\$.status')='confirmed'")
if [ "$rc8" = "0" ] && [ "$c8_status" = "confirmed" ] && [ "$c8b_status" = "confirmed" ] \
   && [ "$n_ev8" -ge "2" ]; then
  ok "C3: claim verify --all-unverified + explicit id in one batch"
else
  no "C3: batch verify --all (rc=$rc8 c8=$c8_status c8b=$c8b_status events=$n_ev8)"
fi

# 9. an empty selection is an error, not a silent success.
fleet claim verify --task "$T8" --status confirmed >"$FLEET_HOME/e9" 2>&1
rc9=$?
if [ "$rc9" != "0" ] && grep -qi "no claims selected" "$FLEET_HOME/e9"; then
  ok "C3: claim verify with nothing selected errors, not silent success"
else
  no "C3: empty verify selection (rc=$rc9 out='$(cat "$FLEET_HOME/e9")')"
fi

# 10. goal close refuses while the goal has live tasks; --force closes and
#     the event records the force.
G10=$(fleet goal add "c3 goal ten")
T10=$(fleet add "c3 live" --channel shell --goal "$G10" \
       --spec "$FLEET_HOME/spec_sleep.sh")
fleet run "$T10" >/dev/null
for i in $(seq 1 50); do [ -n "$(field "$T10" pid)" ] && break; sleep 0.2; done
fleet goal close "$G10" >"$FLEET_HOME/g10" 2>&1
rc10=$?
fleet goal close "$G10" --force >"$FLEET_HOME/g10f" 2>&1
rc10f=$?
g_status=$(fleet --json goal list --all | python3 -c "import json,sys;print([g['status'] for g in json.load(sys.stdin) if g['id']==$G10][0])")
g_evt=$(sqlite3 "$FLEET_HOME/fleet.db" \
  "SELECT payload FROM event WHERE kind='goal.close' AND goal_id=$G10")
fleet cancel "$T10" >/dev/null 2>&1 || true
if [ "$rc10" != "0" ] && grep -qi "non-terminal" "$FLEET_HOME/g10" \
   && [ "$rc10f" = "0" ] && [ "$g_status" = "done" ] \
   && printf '%s' "$g_evt" | grep -q '"forced": true' \
   && printf '%s' "$g_evt" | grep -q "$T10"; then
  ok "C3: goal close refuses with live tasks; --force closes, event records it"
else
  no "C3: goal close (rc=$rc10/$rc10f status=$g_status evt='$g_evt')"
fi

# 11. goal list defaults to open only; --all shows the closed one too.
G11=$(fleet goal add "c3 goal eleven")
fleet goal close "$G11" >/dev/null
n_open=$(fleet goal list | wc -l | tr -d ' ')
n_all=$(fleet goal list --all | wc -l | tr -d ' ')
if [ "$n_open" = "0" ] && [ "$n_all" -ge "2" ]; then
  ok "C3: goal list shows open by default, --all shows closed"
else
  no "C3: goal list scoping (open=$n_open all=$n_all)"
fi

# 12. decisions resolve marks a needs_user decision handled; it drops out of
#     the --needs-user list and the event carries the note.
D12=$(fleet decide "c3 question" --needs-user)
fleet decisions resolve "$D12" --note "commander handled" >/dev/null
rc12=$?
n_needs=$(fleet --json decisions --needs-user | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")
d_evt=$(sqlite3 "$FLEET_HOME/fleet.db" \
  "SELECT payload FROM event WHERE kind='decision.resolve' AND json_extract(payload,'\$.decision_id')=$D12")
if [ "$rc12" = "0" ] && [ "$n_needs" = "0" ] \
   && printf '%s' "$d_evt" | grep -q "commander handled"; then
  ok "C3: decisions resolve marks handled, leaves --needs-user list, event has note"
else
  no "C3: decisions resolve (rc=$rc12 needs=$n_needs evt='$d_evt')"
fi

# 13. resolving twice is an error (the row keeps its first resolution).
fleet decisions resolve "$D12" >"$FLEET_HOME/e13" 2>&1
rc13=$?
if [ "$rc13" != "0" ] && grep -qi "already resolved" "$FLEET_HOME/e13"; then
  ok "C3: double resolve refused"
else
  no "C3: double resolve (rc=$rc13 out='$(cat "$FLEET_HOME/e13")')"
fi

# --- B: /var/tmp/fleet list/prune -----------------------------------------

# 14. launch writes a .home marker in the ledger's hash dir (the owner a
#     prune needs to tell live scratch from an orphan).
T14=$(fleet add "b marker" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$T14" >/dev/null
wait_status "$T14" done
if [ -f "$SELF_HASH_DIR/.home" ] \
   && [ "$(cat "$SELF_HASH_DIR/.home")" = "$FLEET_HOME" ]; then
  ok "B: launch writes .home marker naming the owning FLEET_HOME"
else
  no "B: .home marker (exists=$([ -f "$SELF_HASH_DIR/.home" ] && echo y || echo n))"
fi

# 15. tmp list marks this ledger's hash 'self'.
if fleet tmp list | grep -q "^$SELF_HASH .* self$"; then
  ok "B: tmp list marks the live ledger's hash as self"
else
  no "B: tmp list self marking"
fi

# 16. prune removes a terminal task's old scratch, never a live task's.
T16=$(fleet add "b old" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$T16" >/dev/null
wait_status "$T16" done
T16r=$(fleet add "b running" --channel shell --spec "$FLEET_HOME/spec_sleep.sh")
fleet run "$T16r" >/dev/null
for i in $(seq 1 50); do [ -n "$(field "$T16r" pid)" ] && break; sleep 0.2; done
T16q=$(fleet add "b queued" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
mkdir -p "$SELF_HASH_DIR/$T16q"   # a queued task has no scratch yet; fake one
find "$SELF_HASH_DIR/$T16" "$SELF_HASH_DIR/$T16r" "$SELF_HASH_DIR/$T16q" \
  -exec touch -d "10 days ago" {} +
fleet tmp prune --before 3 >"$FLEET_HOME/p16" 2>&1
rc16=$?
fleet cancel "$T16r" >/dev/null 2>&1 || true
if [ "$rc16" = "0" ] && grep -q "removed 1 task dir" "$FLEET_HOME/p16" \
   && [ ! -d "$SELF_HASH_DIR/$T16" ] \
   && [ -d "$SELF_HASH_DIR/$T16r" ] \
   && [ -d "$SELF_HASH_DIR/$T16q" ]; then
  ok "B: prune removes a terminal task's old scratch, keeps running/queued tasks'"
else
  no "B: prune terminal/live (rc=$rc16 out='$(cat "$FLEET_HOME/p16")' "
fi

# 17. --dry-run removes nothing.
T17=$(fleet add "b dry" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$T17" >/dev/null
wait_status "$T17" done
find "$SELF_HASH_DIR/$T17" -exec touch -d "10 days ago" {} +
before17=$(find "$SELF_HASH_DIR/$T17" 2>/dev/null | wc -l)
fleet tmp prune --before 3 --dry-run >"$FLEET_HOME/p17" 2>&1
after17=$(find "$SELF_HASH_DIR/$T17" 2>/dev/null | wc -l)
if grep -q "would remove" "$FLEET_HOME/p17" \
   && [ "$before17" = "$after17" ] && [ -d "$SELF_HASH_DIR/$T17" ]; then
  ok "B: --dry-run reports without deleting"
else
  no "B: dry-run (before=$before17 after=$after17 out='$(cat "$FLEET_HOME/p17")')"
fi
rm -rf "$SELF_HASH_DIR/$T17"

# 18. an orphan hash dir (marker's FLEET_HOME gone) is pruned whole; an
#     unknown one (no marker) is NEVER deleted.
mkdir -p "$FAKE_HASH_DIR/42"
printf '/nonexistent-fleet-home-p13-xyz\n' > "$FAKE_HASH_DIR/.home"
mkdir -p "$UNKNOWN_HASH_DIR/43"
touch -d "10 days ago" "$FAKE_HASH_DIR/42" "$FAKE_HASH_DIR/.home" "$FAKE_HASH_DIR" \
                    "$UNKNOWN_HASH_DIR/43" "$UNKNOWN_HASH_DIR"
fleet tmp prune --before 3 >"$FLEET_HOME/p18" 2>&1
rc18=$?
# The orphan COUNT is a machine-global number and cannot be asserted from here
# at all. prune walks the whole of /var/tmp/fleet, which is one tree for every
# ledger, so concurrent copies of this suite sweep each other's fixtures:
# measured across three runs, the same one-orphan fixture produced "2 orphan"
# (swept its own and a sibling's), "0 orphan" (its own was swept first, so its
# own prune found nothing left) and the expected "1 orphan". Even ">= 1" is
# therefore wrong.
# What the case is about survives per-directory, and that is what is asserted:
# a marked orphan is gone afterwards, a marker-less dir is still there. The
# second half is the safety-critical one and is what mutation
# tmp-prune-deletes-unknown reddens.
# The real fix is one line elsewhere -- TMP_ROOT is hardcoded at bin/fleet:2484
# and would isolate every suite if it honoured an env var -- but that is a
# bin/fleet change and needs a daemon restart, so it is noted, not taken here.
if [ "$rc18" = "0" ] \
   && [ ! -d "$FAKE_HASH_DIR" ] && [ -d "$UNKNOWN_HASH_DIR" ]; then
  ok "B: prune removes an orphan hash dir whole, never an unknown (marker-less) one"
  rm -rf "$UNKNOWN_HASH_DIR"
else
  no "B: orphan/unknown prune (rc=$rc18 out='$(cat "$FLEET_HOME/p18")')"
  rm -rf "$UNKNOWN_HASH_DIR"
fi

# 19. brief names the accumulation once over 1000 task dirs. (The count is
#     whatever the shared /var/tmp/fleet holds plus these; the hint just has
#     to appear, so the assertion is on the line shape, not the number.)
mkdir -p "$FAKE_HASH_DIR"
for i in $(seq 1 1005); do mkdir -p "$FAKE_HASH_DIR/$i"; done
if fleet brief --all 2>&1 | grep -qE "^tmp: [0-9]+\+ task dirs"; then
  ok "B: brief hints at tmp accumulation over 1000 dirs"
else
  no "B: brief tmp hint"
fi
rm -rf "$FAKE_HASH_DIR"

# 20. a long listing piped to a closed stdout dies cleanly -- no traceback,
#     no "Exception ignored" shutdown flush. Exit 141 (SIGPIPE) is the
#     conventional death of a writer whose reader went away; 0 also passes.
fleet tmp list 2>"$FLEET_HOME/e20" | head -1 >/dev/null
rc20=${PIPESTATUS[0]}
if { [ "$rc20" = "0" ] || [ "$rc20" = "141" ]; } \
   && ! grep -q "Traceback" "$FLEET_HOME/e20" \
   && ! grep -q "Exception ignored" "$FLEET_HOME/e20"; then
  ok "B: tmp list | head dies cleanly (rc=$rc20), no traceback or shutdown-flush error"
else
  no "B: BrokenPipeError handling (rc=$rc20 err='$(head -1 "$FLEET_HOME/e20")')"
fi

# 21. codex adapter passes --skip-git-repo-check: a task cwd is not always a
#     git repo, and without the flag codex refuses to run ("Not inside a
#     trusted directory") -- the defect found on the first real codex run.
printf 'x\n' > "$FLEET_HOME/p21.md"
d21=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MODEL=gpt-5.6-sol FLEET_HOME="$FLEET_HOME" \
  bash "$ROOT/adapters/codex.sh" 1 "$FLEET_HOME/p21.md" "$FLEET_HOME" \
  "$FLEET_HOME/o21" "$FLEET_HOME/l21" 2>/dev/null)
if printf '%s\n' "$d21" | grep -q -- "--skip-git-repo-check"; then
  ok "A: codex adapter passes --skip-git-repo-check (non-git cwd runs)"
else
  no "A: codex --skip-git-repo-check (dryrun='$d21')"
fi

# 22. a dep that is terminal-but-not-done (failed/cancelled/archived) can
#     never become runnable, so `fleet add` refuses it at enqueue (exit 17,
#     stderr names the dep and its state) instead of queueing a task that
#     waits forever with no explanation.
#     --force-dep admits it anyway; a dep that exists nowhere is refused even
#     with --force-dep (a typo cannot be waited into existence).
printf 'echo boom; exit 1\n' > "$FLEET_HOME/spec_fail.sh"
F22=$(fleet add "22 fail" --channel shell --no-preamble --spec "$FLEET_HOME/spec_fail.sh")
fleet run "$F22" >/dev/null
wait_status "$F22" failed || true
set +e
E22=$(fleet add "22 child-failed" --channel shell --no-preamble \
        --spec "$FLEET_HOME/spec_echo.sh" --dep "$F22" 2>&1)
RC22=$?
set -e
K22=$(fleet add "22 cancel" --channel shell --no-preamble --spec "$FLEET_HOME/spec_echo.sh")
fleet cancel "$K22" >/dev/null
set +e
E22C=$(fleet add "22 child-cancelled" --channel shell --no-preamble \
         --spec "$FLEET_HOME/spec_echo.sh" --dep "$K22" 2>&1)
RC22C=$?
E22M=$(fleet add "22 child-missing" --channel shell --no-preamble \
         --spec "$FLEET_HOME/spec_echo.sh" --dep 999999 --force-dep 2>&1)
RC22M=$?
set -e
# archived dep, in a ledger of its own so the archive moves none of this
# suite's rows:
AH22="$FLEET_HOME/arch-home"
FLEET_HOME="$AH22" fleet init >/dev/null
A22=$(FLEET_HOME="$AH22" fleet add "22 arch-done" --channel shell --no-preamble \
        --spec "$FLEET_HOME/spec_echo.sh")
FLEET_HOME="$AH22" fleet run "$A22" >/dev/null
for i in $(seq 1 100); do
  [ "$(FLEET_HOME="$AH22" field "$A22" status)" = done ] && break; sleep 0.2
done
FLEET_HOME="$AH22" fleet archive --before 2030-01-01 >/dev/null
set +e
E22A=$(FLEET_HOME="$AH22" fleet add "22 child-arch" --channel shell --no-preamble \
         --spec "$FLEET_HOME/spec_echo.sh" --dep "$A22" 2>&1)
RC22A=$?
# ...and --force-dep does not admit an archived dep either: its id may be
# reused by the task being created, making the new row depend on itself. An
# empty ledger must also render, not crash (status --all).
E22AF=$(FLEET_HOME="$AH22" fleet add "22 child-arch-forced" --channel shell \
         --no-preamble --spec "$FLEET_HOME/spec_echo.sh" --dep "$A22" --force-dep 2>&1)
RC22AF=$?
FLEET_HOME="$AH22" fleet status --all >/dev/null 2>&1
RC22E=$?
set -e
# --force-dep on the failed dep DOES enqueue (fixture for case 23):
FC22=$(fleet add "22 forced" --channel shell --no-preamble \
         --spec "$FLEET_HOME/spec_echo.sh" --dep "$F22" --force-dep)
if [ "$RC22" = 17 ] && printf '%s' "$E22" | grep -q "dep task $F22 is failed" \
 && printf '%s' "$E22" | grep -q -- "--force-dep" \
 && [ "$RC22C" = 17 ] && printf '%s' "$E22C" | grep -q "dep task $K22 is cancelled" \
 && [ "$RC22M" != 0 ] && printf '%s' "$E22M" | grep -q "not found" \
 && [ "$RC22A" = 17 ] && printf '%s' "$E22A" | grep -q "dep task $A22 is archived" \
 && [ "$RC22AF" = 17 ] && printf '%s' "$E22AF" | grep -q "even with --force-dep" \
 && [ "$RC22E" = 0 ] \
 && [ -n "$FC22" ] && [ "$(field "$FC22" status)" = queued ]; then
  ok "22: add refuses failed/cancelled/archived deps (17, names dep+state), --force-dep admits failed only, missing dep refused even forced, empty status renders"
else
  no "22: terminal-dep refusal (rc=$RC22/$RC22C/$RC22M/$RC22A/$RC22AF/empty=$RC22E; failed='$E22' cancelled='$E22C' missing='$E22M' arch='$E22A' archforced='$E22AF' forced='$(field "$FC22" status 2>/dev/null)')"
fi

# 23. the permanently-wedged queued task is VISIBLE: status/top print
#     queued!dep-failed, brief names it in flight and names the block reason,
#     and show's dep_status line names the dep's state. The marker comes from
#     the ledger, not from a daemon event, so it shows before any poll.
S23=$(fleet status --all)
B23=$(fleet brief)
T23=$(fleet top --once)
SH23=$(fleet show "$FC22")
if printf '%s\n' "$S23" | grep -qE "^$FC22 queued!dep-failed " \
 && printf '%s\n' "$T23" | grep -qE "^$FC22 +queued!dep-failed " \
 && printf '%s\n' "$B23" | grep -q "$FC22 queued!dep-failed(shell)" \
 && printf '%s\n' "$SH23" | grep -q "^dep_status: $F22=failed$" \
 && ! printf '%s\n' "$S23" | grep -qE "^$F22 queued"; then
  ok "23: status/top/brief mark queued!dep-failed; show dep_status names the failed dep"
else
  no "23: dep-failed visibility (status line: $(printf '%s\n' "$S23" | grep "^$FC22 " || echo MISSING); show: $(printf '%s\n' "$SH23" | grep dep_status || echo MISSING))"
fi

echo "---"
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = "0" ]
