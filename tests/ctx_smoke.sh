#!/usr/bin/env bash
# fleet P3 context-convergence smoke tests. Zero model quota: shell only.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-ctx-test-XXXX)"
trap 'rm -rf "$FLEET_HOME"' EXIT
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

fleet init >/dev/null
printf 'echo hi\n' > "$FLEET_HOME/spec_echo.sh"

# 1. watermark is per-consumer: consumer A advancing must not hide events from B
T1=$(fleet add "wm task" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$T1" >/dev/null
wait_status "$T1" done
outA=$(FLEET_CONSUMER=alpha fleet since)
outB=$(FLEET_CONSUMER=beta fleet since)
outA2=$(FLEET_CONSUMER=alpha fleet since)
if printf '%s\n' "$outB" | grep -q "^$T1 " \
   && ! printf '%s\n' "$outA2" | grep -q "^$T1 "; then
  ok "watermark per-consumer: B still sees A's events"
else
  no "watermark per-consumer: B still sees A's events"
fi

# 2. old meta.commander_watermark is migrated into the watermark table, old key deleted
python3 - "$FLEET_HOME/fleet.db" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT OR REPLACE INTO meta(k,v) VALUES('commander_watermark','123')")
c.commit()
EOF
fleet init >/dev/null
M2=$(python3 - "$FLEET_HOME/fleet.db" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
wm = c.execute("SELECT value FROM watermark WHERE consumer='default' AND scope='all'").fetchone()
old = c.execute("SELECT v FROM meta WHERE k='commander_watermark'").fetchone()
assert wm == (123,), wm
assert old is None, old
print("ok")
EOF
)
if [ "$M2" = "ok" ]; then
  ok "legacy commander_watermark migrated and deleted"
else
  no "legacy commander_watermark migrated and deleted ($M2)"
fi

# 3. since folds by task: a task with 5+ events prints exactly 1 line
T3=$(fleet add "fold task" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$T3" >/dev/null
wait_status "$T3" done
fleet claim add "$T3" "fold claim" --evidence "spec:1" >/dev/null
fleet decide "fold decision" --task "$T3" >/dev/null
folded=$(fleet since --all 0 | grep -c "^$T3 ")
rawev=$(fleet since --raw 0 | grep -c " $T3 ")
if [ "$folded" = "1" ] && [ "$rawev" -ge 5 ]; then
  ok "since folds a 5+ event task into 1 line"
else
  no "since folds a 5+ event task into 1 line (folded=$folded raw=$rawev)"
fi

# 4. --raw restores per-event output (one line per event, nothing dropped)
db_events=$(python3 -c "import sqlite3; print(sqlite3.connect('$FLEET_HOME/fleet.db').execute('SELECT COUNT(*) FROM event').fetchone()[0])")
raw_lines=$(fleet since --raw 0 | grep -vc '^watermark=')
if [ "$raw_lines" = "$db_events" ]; then
  ok "--raw: one line per event, none dropped"
else
  no "--raw: one line per event, none dropped (raw=$raw_lines db=$db_events)"
fi

# 5. --max-lines truncates and prints the overflow hint as the last line
T5A=$(fleet add "cap a" --channel shell)
T5B=$(fleet add "cap b" --channel shell)
cap_out=$(fleet since 0 --max-lines 2)
cap_lines=$(printf '%s\n' "$cap_out" | grep -vc '^watermark=')
cap_last=$(printf '%s\n' "$cap_out" | grep -v '^watermark=' | tail -1)
if [ "$cap_lines" = "2" ] \
   && printf '%s\n' "$cap_last" | grep -q "另有" \
   && printf '%s\n' "$cap_last" | grep -q "用 --all"; then
  ok "--max-lines 2: truncated with overflow hint"
else
  no "--max-lines 2: truncated with overflow hint (lines=$cap_lines last=$cap_last)"
fi

# 6. cwd scoping: tasks outside cwd are hidden by default, shown with --all
mkdir -p "$FLEET_HOME/cwA" "$FLEET_HOME/cwB"
TA=$(fleet add "cwd A" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --cwd "$FLEET_HOME/cwA")
TB=$(fleet add "cwd B" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --cwd "$FLEET_HOME/cwB")
inB=$(cd "$FLEET_HOME/cwB" && fleet since 0)
inBall=$(cd "$FLEET_HOME/cwB" && fleet since --all 0)
if printf '%s\n' "$inB" | grep -q "^$TB " \
   && ! printf '%s\n' "$inB" | grep -q "^$TA " \
   && printf '%s\n' "$inBall" | grep -q "^$TA "; then
  ok "cwd scope: hidden by default, --all shows everything"
else
  no "cwd scope: hidden by default, --all shows everything"
fi

# 7. since --goal: only that goal's tasks, and an independent watermark scope
G7=$(fleet goal add "g7")
TG=$(fleet add "goal task" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --goal "$G7")
fleet run "$TG" >/dev/null
wait_status "$TG" done
goal_out=$(FLEET_CONSUMER=g7 fleet since --goal "$G7" 0)
FLEET_CONSUMER=g7 fleet since --goal "$G7" >/dev/null
all_out=$(FLEET_CONSUMER=g7 fleet since 0)
if printf '%s\n' "$goal_out" | grep -q "^$TG " \
   && ! printf '%s\n' "$goal_out" | grep -q "^$T1 " \
   && printf '%s\n' "$all_out" | grep -q "^$TG "; then
  ok "since --goal: scoped output, independent watermark"
else
  no "since --goal: scoped output, independent watermark"
fi

# 8. large message body spills to disk; inbox reads it back transparently
body="$(python3 -c 'print("M"*5000, end="")')TAILMARK8"
fleet msg send --from a --to b "$body" >/dev/null
dbbody=$(python3 -c "import sqlite3; print(sqlite3.connect('$FLEET_HOME/fleet.db').execute('SELECT body FROM message ORDER BY id DESC LIMIT 1').fetchone()[0])")
inbox=$(fleet msg inbox --for b)
if printf '%s' "$dbbody" | grep -q "_spill" \
   && printf '%s\n' "$inbox" | grep -q "TAILMARK8"; then
  ok "message body >4096 spilled, inbox reads it back"
else
  no "message body >4096 spilled, inbox reads it back"
fi

# 9. large event payload spills to disk; since --raw reads it back
q="$(python3 -c 'print("Q"*5000, end="")')TAILMARK9"
fleet decide "$q" >/dev/null
dbpay=$(python3 -c "import sqlite3; print(sqlite3.connect('$FLEET_HOME/fleet.db').execute(\"SELECT payload FROM event WHERE kind='decision.add' ORDER BY id DESC LIMIT 1\").fetchone()[0])")
raw=$(fleet since --raw 0)
if printf '%s' "$dbpay" | grep -q "_spill" \
   && printf '%s\n' "$raw" | grep -q "TAILMARK9"; then
  ok "event payload >4096 spilled, since --raw reads it back"
else
  no "event payload >4096 spilled, since --raw reads it back"
fi

# 10. archive --before moves terminal tasks (with their rows) to the archive db
OLD=$(fleet add "old done" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$OLD" >/dev/null
wait_status "$OLD" done
fleet claim add "$OLD" "old claim" --evidence "spec:1" >/dev/null
python3 - "$FLEET_HOME/fleet.db" "$OLD" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE task SET ended_at=? WHERE id=?", (int(time.time()) - 864000, sys.argv[2]))
c.commit()
EOF
QUEUED=$(fleet add "still queued" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
arch_out=$(fleet archive --before "$(date +%F)")
M10=$(python3 - "$FLEET_HOME/fleet.db" "$FLEET_HOME/fleet-archive.db" "$OLD" "$QUEUED" <<'EOF'
import sqlite3, sys
hot, arch, old, queued = sys.argv[1:]
h = sqlite3.connect(hot)
a = sqlite3.connect(arch)
assert h.execute("SELECT COUNT(*) FROM task WHERE id=?", (old,)).fetchone()[0] == 0
assert h.execute("SELECT COUNT(*) FROM event WHERE task_id=?", (old,)).fetchone()[0] == 0
assert h.execute("SELECT COUNT(*) FROM claim WHERE task_id=?", (old,)).fetchone()[0] == 0
assert h.execute("SELECT COUNT(*) FROM task WHERE id=?", (queued,)).fetchone()[0] == 1
assert a.execute("SELECT COUNT(*) FROM task WHERE id=?", (old,)).fetchone()[0] == 1
assert a.execute("SELECT COUNT(*) FROM event WHERE task_id=?", (old,)).fetchone()[0] >= 1
assert a.execute("SELECT COUNT(*) FROM claim WHERE task_id=?", (old,)).fetchone()[0] >= 1
print("ok")
EOF
)
if printf '%s\n' "$arch_out" | grep -q "archived 1" && [ "$M10" = "ok" ]; then
  ok "archive: terminal task moved with rows, non-terminal untouched"
else
  no "archive: terminal task moved with rows, non-terminal untouched ($M10)"
fi

# 11. archive --dry-run reports counts without touching data
OLD2=$(fleet add "old done 2" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$OLD2" >/dev/null
wait_status "$OLD2" done
python3 - "$FLEET_HOME/fleet.db" "$OLD2" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE task SET ended_at=? WHERE id=?", (int(time.time()) - 864000, sys.argv[2]))
c.commit()
EOF
before=$(fleet --json status --all | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
dry_out=$(fleet archive --before "$(date +%F)" --dry-run)
after=$(fleet --json status --all | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
if printf '%s\n' "$dry_out" | grep -q "would archive 1" \
   && [ "$before" = "$after" ] \
   && fleet show "$OLD2" >/dev/null 2>&1; then
  ok "archive --dry-run: counts only, data unchanged"
else
  no "archive --dry-run: counts only, data unchanged"
fi

# 12. project-agnostic: no concrete project names anywhere in the tree.
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
