#!/usr/bin/env bash
# Focused guard-removal mutation checks for C control. Kept separate from the
# shared mutation manifest while the parallel C tasks are being integrated.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Put the executable in a temporary bin/ below a linked repository fixture:
# bin/fleet derives ROOT from its own path, so a bare /var/tmp copy would fail
# only because it cannot find schema.sql and would give the mutation false teeth.
TMP="$(mktemp -d /var/tmp/fleet-control-mutations-XXXXXX)"
mkdir "$TMP/bin"
ln -s "$ROOT/bin/fleet_checks.py" "$TMP/bin/fleet_checks.py"
for entry in schema.sql channels.json adapters templates; do
  ln -s "$ROOT/$entry" "$TMP/$entry"
done
trap 'rm -rf "$TMP"' EXIT

mutate_and_expect_failure(){
  local name="$1" old="$2" new="$3" expected="$4" mutant="$TMP/bin/fleet"
  python3 - "$ROOT/bin/fleet" "$mutant" "$old" "$new" <<'PY'
from pathlib import Path
import sys
src, dst, old, new = sys.argv[1:]
text = Path(src).read_text()
if text.count(old) != 1:
    raise SystemExit(f"mutation anchor count {text.count(old)} != 1: {old!r}")
Path(dst).write_text(text.replace(old, new, 1))
PY
  chmod +x "$mutant"
  set +e
  FLEET_UNDER_TEST="$mutant" PYTHONDONTWRITEBYTECODE=1 \
    python3 "$ROOT/tests/commander_control_test.py" >"$TMP/$name.log" 2>&1
  local rc=$?
  set -e
  if [ "$rc" = 0 ]; then
    echo "not ok - mutation survived: $name"
    sed -n '1,160p' "$TMP/$name.log"
    return 1
  fi
  if ! grep -q '^FAILED' "$TMP/$name.log" \
     || ! grep -q "$expected .* FAIL" "$TMP/$name.log"; then
    echo "not ok - mutation missed its expected assertion: $name"
    sed -n '1,160p' "$TMP/$name.log"
    return 1
  fi
  echo "ok - mutation killed: $name"
}

mutate_and_expect_failure goal-budget-guard \
  'if goal and goal["budget_cap"] is not None:' \
  'if False and goal and goal["budget_cap"] is not None:' \
  'test_budget_one_blocks_multiple_candidates_and_deduplicates'
mutate_and_expect_failure policy-generation-guard \
  'if frozen != current:' \
  'if False and frozen != current:' \
  'test_disable_running_and_disable_enable_reject_old_callback'
