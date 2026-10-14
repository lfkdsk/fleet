#!/usr/bin/env bash
# Focused mutation proof: the execution tests must kill removed safety guards.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /var/tmp/fleet-commander-mutation-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0 N=0
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }

copy_tree(){
  local dst="$1"
  mkdir -p "$dst"
  cp -a "$ROOT/bin" "$ROOT/adapters" "$ROOT/templates" "$ROOT/tests" \
    "$ROOT/channels.json" "$ROOT/schema.sql" "$dst/"
}

# Removing the worktree flag makes real workers run in the user's checkout.
M1="$TMP/no-worktree"; copy_tree "$M1"
python3 - "$M1/bin/fleet" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old='worktree=execution["worktree"]'
assert s.count(old)==1, s.count(old)
p.write_text(s.replace(old, 'worktree=False'))
PY
bash "$M1/tests/commander_execution_smoke.sh" >"$TMP/m1.out" 2>&1
RC=$?
if [ "$RC" != 0 ] && grep -q 'persisted cwd / worktree / pin' "$TMP/m1.out"; then
  ok "removing private-worktree application is killed by the execution smoke"
else
  no "private-worktree mutation survived (rc=$RC)"
fi

# Re-resolving from the target HEAD instead of the selected upstream loses the
# preceding round's unique commit; the helper-level baseline assertion kills it.
M2="$TMP/no-upstream-pin"; copy_tree "$M2"
python3 - "$M2/bin/fleet" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
old='base_commit = baseline["branch_tip"]'
assert s.count(old)==1, s.count(old)
p.write_text(s.replace(old, 'base_commit = target["head"]'))
PY
python3 "$M2/tests/test_commander_execution.py" >"$TMP/m2.out" 2>&1
RC=$?
if [ "$RC" != 0 ] \
   && grep -q 'test_valid_base_task_pins_declared_branch_tip_and_deliverable.*FAIL' "$TMP/m2.out"; then
  ok "removing the selected upstream pin is killed by the baseline unit test"
else
  no "upstream-pin mutation survived (rc=$RC)"
fi

echo ---
echo "passed $PASS / $N"
[ "$FAIL" = 0 ]
