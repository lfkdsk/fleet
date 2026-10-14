#!/usr/bin/env bash
# Claude Code `-p` is one-shot: an adapter success must not mean task success
# while a descendant is alive or when the final response explicitly says the
# worker is still waiting. A fake claude binary exercises both adapters and
# the real detached Fleet wrapper without spending model quota.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-claude-early-exit-XXXX)"
TEST_HOME="$FLEET_HOME/user-home"
FAKE_BIN="$FLEET_HOME/fake-bin"
mkdir -p "$TEST_HOME/.claude" "$FAKE_BIN" "$FLEET_HOME/work"
export HOME="$TEST_HOME"
export PATH="$FAKE_BIN:$ROOT/bin:$PATH"
export ANTHROPIC_BASE_URL=https://api.example.test
export ANTHROPIC_AUTH_TOKEN=fake-api-token
unset _FLEET_LOCK_FD FLEET_TASK_ID FLEET_RUN_DIR FLEET_ATTEMPT

PASS=0 FAIL=0 N=0
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }
field(){ fleet show "$1" | awk -v f="$2" '$1==f":"{print $2}'; }
sql(){ sqlite3 -cmd '.timeout 10000' "$FLEET_HOME/fleet.db" "$1"; }
wait_status(){
  local id="$1" want="$2" i got
  for i in $(seq 1 120); do
    got=$(field "$id" status)
    [ "$got" = "$want" ] && return 0
    sleep 0.05
  done
  return 1
}
wait_terminal(){
  local id="$1" i got
  for i in $(seq 1 120); do
    got=$(field "$id" status)
    case "$got" in done|failed|cancelled) return 0 ;; esac
    sleep 0.05
  done
  return 1
}
review_started(){
  [ -f "$FLEET_HOME/reviews.started" ] \
    && grep -qx "$1" "$FLEET_HOME/reviews.started"
}
run_daemon_until_review(){
  local id="$1" i
  for i in $(seq 1 120); do
    fleet daemon run --once >/dev/null 2>&1
    review_started "$id" && return 0
    sleep 0.05
  done
  return 1
}
cleanup(){
  local child id
  child=$(cat "$FLEET_HOME/background.pid" 2>/dev/null || true)
  [ -z "$child" ] || kill "$child" 2>/dev/null || true
  if [ -f "$FLEET_HOME/fleet.db" ]; then
    while read -r id; do
      [ -z "$id" ] || fleet cancel "$id" >/dev/null 2>&1 || true
    done < <(sql "SELECT id FROM task WHERE status IN ('queued','running')" 2>/dev/null)
  fi
  rm -rf "$FLEET_HOME"
}
trap cleanup EXIT

cat > "$FAKE_BIN/claude" <<'SH'
#!/usr/bin/env bash
set -u
prompt="$FLEET_HOME/captured-$FLEET_TASK_ID.prompt"
tee "$prompt" >/dev/null
fleet claim add "$FLEET_TASK_ID" "fake Claude reached its final response" \
  --evidence "command: fake claude mode for task $FLEET_TASK_ID" >/dev/null

if grep -q '^MODE=BACKGROUND$' "$prompt"; then
  nohup python3 -c 'import time; time.sleep(60)' fleet-claude-background-demo \
    </dev/null >/dev/null 2>&1 &
  echo $! > "$FLEET_HOME/background.pid"
  printf 'The foreground response is complete and the demonstration is running.\n'
elif grep -q '^MODE=WAIT$' "$prompt"; then
  printf 'Demo rerun is past the restart phase, but the report is unfinished.\n'
  printf 'Nothing else can proceed until it finishes, so I\x27m waiting on its completion notification.\n'
else
  printf 'I was waiting for the foreground command earlier; it completed.\n'
  printf 'All requested deliverables are complete.\n'
fi
SH
chmod +x "$FAKE_BIN/claude"

printf '%s\n' \
  'printf "%s\n" "$FLEET_TASK_ID" >> "$FLEET_HOME/reviews.started"' \
  'printf "review ran\n"' > "$FLEET_HOME/review.sh"
printf 'MODE=NORMAL\n' > "$FLEET_HOME/normal.spec"
printf 'MODE=WAIT\n' > "$FLEET_HOME/wait.spec"
printf 'MODE=BACKGROUND\n' > "$FLEET_HOME/background.spec"

fleet init >/dev/null
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as source:
    doc = json.load(source)
doc["channels"] = {
    "fake-claude-p": {
        "adapter": "claude_p.sh",
        "model": "claude-test",
        "models": ["claude-test"],
    },
    "fake-claude-api": {
        "adapter": "claude_api.sh",
        "model": "vendor/claude-test",
        "models": ["vendor/claude-test"],
        "env_passthrough": ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN"],
    },
    "review-shell": {"adapter": "shell.sh", "family": "none"},
}
with open(path, "w") as destination:
    json.dump(doc, destination, indent=2)
PY

# Normal direct and API invocations make the injected prompt observable and
# establish that a completed response -- including a historical "was waiting"
# sentence -- is not rejected.
NP=$(fleet add "normal direct Claude" --channel fake-claude-p \
  --cwd "$FLEET_HOME/work" --no-preamble --spec "$FLEET_HOME/normal.spec")
NR=$(fleet add "normal API Claude" --channel fake-claude-api \
  --cwd "$FLEET_HOME/work" --no-preamble --spec "$FLEET_HOME/normal.spec")
RNP=$(fleet add "review normal direct Claude" --channel review-shell \
  --review-of "$NP" --dep "$NP" --cwd "$FLEET_HOME/work" --no-preamble \
  --spec "$FLEET_HOME/review.sh")
RNR=$(fleet add "review normal API Claude" --channel review-shell \
  --review-of "$NR" --dep "$NR" --cwd "$FLEET_HOME/work" --no-preamble \
  --spec "$FLEET_HOME/review.sh")
fleet run "$NP" >/dev/null
wait_status "$NP" done || true
fleet run "$NR" >/dev/null
wait_status "$NR" done || true

prompt_contract_ok=1
for id in "$NP" "$NR"; do
  capture="$FLEET_HOME/captured-$id.prompt"
  grep -qF 'running through `claude -p`, which is a single-turn process' \
    "$capture" || prompt_contract_ok=0
  grep -qF 'a later background-task completion' "$capture" \
    || prompt_contract_ok=0
  grep -qF 'foreground with a bounded timeout, or poll them until' "$capture" \
    || prompt_contract_ok=0
  grep -qF 'finish and verify every required deliverable' "$capture" \
    || prompt_contract_ok=0
done
if [ "$prompt_contract_ok" = 1 ]; then
  ok "direct and API adapters append the claude -p one-shot contract"
else
  no "direct and API adapters append the claude -p one-shot contract"
fi

np_review=0 nr_review=0
run_daemon_until_review "$RNP" && np_review=1
run_daemon_until_review "$RNR" && nr_review=1
if [ "$(field "$NP" status):$(field "$NR" status)" = "done:done" ] \
   && [ "$np_review:$nr_review" = "1:1" ]; then
  ok "completed direct and API responses remain done and admit reviews"
else
  no "normal completion changed (tasks=$(field "$NP" status)/$(field "$NR" status) reviews=$np_review/$nr_review)"
fi

# The exact incident shape: rc=0 and a final sentence that promises to wait.
# A prequeued --review-of task makes the downstream consequence observable.
WP=$(fleet add "direct Claude ends while waiting" --channel fake-claude-p \
  --cwd "$FLEET_HOME/work" --no-preamble --spec "$FLEET_HOME/wait.spec")
RWP=$(fleet add "review incomplete direct Claude" --channel review-shell \
  --review-of "$WP" --dep "$WP" --cwd "$FLEET_HOME/work" --no-preamble \
  --spec "$FLEET_HOME/review.sh")
fleet run "$WP" >/dev/null
wait_terminal "$WP" || true
fleet daemon run --once >/dev/null 2>&1
wp_log=$(fleet tail "$WP")
wp_digest=$(fleet digest "$WP")
if [ "$(field "$WP" status):$(field "$WP" exit_code)" = "failed:75" ] \
   && [ "$(field "$RWP" status)" = queued ] \
   && ! review_started "$RWP" \
   && printf '%s\n' "$wp_log" | grep -q 'final response says it is still waiting' \
   && printf '%s\n' "$wp_digest" | grep -q '^# Incomplete Claude response'; then
  ok "direct Claude waiting response fails explicitly and blocks its review"
else
  no "direct wait guard (task=$(field "$WP" status)/$(field "$WP" exit_code) review=$(field "$RWP" status) started=$(review_started "$RWP" && echo yes || echo no) log='$wp_log')"
fi

WR=$(fleet add "API Claude ends while waiting" --channel fake-claude-api \
  --cwd "$FLEET_HOME/work" --no-preamble --spec "$FLEET_HOME/wait.spec")
RWR=$(fleet add "review incomplete API Claude" --channel review-shell \
  --review-of "$WR" --dep "$WR" --cwd "$FLEET_HOME/work" --no-preamble \
  --spec "$FLEET_HOME/review.sh")
fleet run "$WR" >/dev/null
wait_terminal "$WR" || true
fleet daemon run --once >/dev/null 2>&1
wr_log=$(fleet tail "$WR")
if [ "$(field "$WR" status):$(field "$WR" exit_code)" = "failed:75" ] \
   && [ "$(field "$RWR" status)" = queued ] \
   && ! review_started "$RWR" \
   && printf '%s\n' "$wr_log" | grep -q 'final response says it is still waiting'; then
  ok "API Claude waiting response has the same failure and review gate"
else
  no "API wait guard (task=$(field "$WR" status)/$(field "$WR" exit_code) review=$(field "$RWR" status) started=$(review_started "$RWR" && echo yes || echo no) log='$wr_log')"
fi

# Independent signal: even with a completion-looking final response, Fleet's
# existing task.background snapshot must keep the task and downstream review
# nonterminal while the fake Claude descendant is alive. Once it really exits,
# the ordinary successful settlement remains intact.
BG=$(fleet add "Claude leaves a live background process" --channel fake-claude-p \
  --cwd "$FLEET_HOME/work" --no-preamble --spec "$FLEET_HOME/background.spec")
RBG=$(fleet add "review background Claude" --channel review-shell \
  --review-of "$BG" --dep "$BG" --cwd "$FLEET_HOME/work" --no-preamble \
  --spec "$FLEET_HOME/review.sh")
fleet run "$BG" >/dev/null
bg_pid=""
bg_events=0
for _ in $(seq 1 120); do
  bg_pid=$(cat "$FLEET_HOME/background.pid" 2>/dev/null || true)
  bg_events=$(sql "SELECT COUNT(*) FROM event WHERE task_id=$BG AND kind='task.background'" 2>/dev/null || echo 0)
  [ -n "$bg_pid" ] && [ "$bg_events" -ge 1 ] && break
  sleep 0.05
done
fleet daemon run --once >/dev/null 2>&1
if [ -n "$bg_pid" ] && kill -0 "$bg_pid" 2>/dev/null \
   && [ "$(field "$BG" status):$(field "$RBG" status)" = "running:queued" ] \
   && ! review_started "$RBG" && [ "$bg_events" -ge 1 ]; then
  ok "a live Claude descendant keeps the task running and its review queued"
else
  no "background gate (pid=$bg_pid events=$bg_events task=$(field "$BG" status) review=$(field "$RBG" status) started=$(review_started "$RBG" && echo yes || echo no))"
fi

[ -z "$bg_pid" ] || kill "$bg_pid" 2>/dev/null || true
for _ in $(seq 1 120); do
  fleet daemon run --once >/dev/null 2>&1
  [ "$(field "$BG" status)" = done ] && break
  sleep 0.05
done
bg_review=0
run_daemon_until_review "$RBG" && bg_review=1
if [ "$(field "$BG" status):$(field "$BG" exit_code)" = "done:0" ] \
   && [ "$bg_review" = 1 ]; then
  ok "completed background work follows the existing success path"
else
  no "background completion changed (task=$(field "$BG" status)/$(field "$BG" exit_code) review=$bg_review)"
fi

echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = 0 ]
