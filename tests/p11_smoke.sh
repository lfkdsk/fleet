#!/usr/bin/env bash
# fleet P11 smoke tests: the four holes in the family invariant (drift at
# launch, FLEET_MODEL never reaching ssh/switchboard remotes, the family=none
# bypass, rule dedup keys that expired on plan re-issue), the shared
# review-task constructor (rule engine and `fleet add --review-of`), and
# daemon stale-code detection. Zero model quota: model-backed channels use
# the shell adapter with a declared model (family follows the model; the
# prompt still runs as a shell script) or FLEET_ADAPTER_DRYRUN=1.
set -u

# An ambient FLEET_MODEL from the calling session would change the dryrun
# argv below; cases that need a model set one explicitly.
unset FLEET_MODEL
# A parent fleet process may leak its lock fd (see run-all.sh); `daemon
# start` would then inherit a stale lock. Suites exercise the real path.
unset _FLEET_LOCK_FD
# Direct claim/artifact commands in this suite are operator writes, not writes
# by the worker task running this test under Fleet.
unset FLEET_TASK_ID FLEET_ATTEMPT FLEET_RUN_DIR FLEET_SB_MCP_CMD

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p11-test-XXXX)"
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
cleanup(){ fleet daemon stop >/dev/null 2>&1 || true; rm -rf "$FLEET_HOME"; }
trap cleanup EXIT

fleet init >/dev/null
# The echo spec also files a claim: review tasks that exit 0 with zero claims
# are failed (C3), so a review task that is supposed to complete must produce
# one. Non-review runs are unaffected.
printf 'echo hi\nfleet claim add "${FLEET_TASK_ID:-0}" "spec ran" --evidence "spec_echo.sh" >/dev/null 2>&1 || true\n' \
  > "$FLEET_HOME/spec_echo.sh"

# Test channels: shell-backed channels with declared models (family follows
# the model, execution is still a shell script), ssh/switchboard channels
# with and without a wired remote_cmd, and family=none contradictions.
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# models list required since P12b: a reviewer's model must be listed or probed,
# otherwise "different family" is an unverified assertion. Both the pre- and
# post-drift ids are listed so the drift itself is what the case measures.
d["channels"]["drift"] = {"adapter": "shell.sh", "model": "GPT-drift-a",
                          "models": ["GPT-drift-a", "claude-drift-b"]}
d["channels"]["driftb"] = {"adapter": "shell.sh", "model": "claude-drift-b"}
d["channels"]["ssh-model"] = {"adapter": "ssh.sh", "model": "GPT-remote-x",
                              "ssh_host": "h.invalid", "remote_cmd": "bash"}
d["channels"]["ssh-wired"] = {"adapter": "ssh.sh", "model": "GPT-remote-x",
                              "ssh_host": "h.invalid",
                              "remote_cmd": 'bash -c \'claude -p --model "$FLEET_MODEL"\''}
d["channels"]["ssh-dq"] = {"adapter": "ssh.sh", "model": "GPT-remote-x",
                           "ssh_host": "h.invalid",
                           "remote_cmd": 'bash -c "claude -p --model $FLEET_MODEL"'}
d["channels"]["sb-model"] = {"adapter": "switchboard.sh", "model": "GPT-remote-x",
                             "node": "n", "remote_cmd": "cat"}
d["channels"]["none-with-model"] = {"adapter": "shell.sh", "family": "none",
                                    "model": "GPT-x"}
d["channels"]["none-with-models"] = {"adapter": "shell.sh", "family": "none",
                                     "models": ["GPT-x"]}
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY

# 1. A1: family frozen at enqueue is re-checked at launch. A review enqueued
#    cross-family (gpt reviews claude) must refuse to start after the
#    reviewer channel's default model is edited to a claude model: launching
#    would silently turn it into a same-family review.
TT=$(fleet add "drift target" --channel driftb)
T1=$(fleet add "drift review" --channel drift --review-of "$TT" \
     --spec "$FLEET_HOME/spec_echo.sh" --no-preamble)
fleet cancel "$TT" >/dev/null 2>&1 || true
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"]["drift"]["model"] = "claude-drift-b"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
fleet run "$T1" 2>"$FLEET_HOME/e1"
rc1=$?
st1=$(field "$T1" status)
ev1=$(fleet since --raw 0 | grep -c " task.blocked $T1 .*family drift" || true)
dec1=$(fleet --json decisions | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len([r for r in rows if r["task_id"] == '"$T1"' and r["needs_user"] == 1]))')
if [ "$rc1" != "0" ] && [ "$st1" = "queued" ] && [ "$ev1" -ge 1 ] \
   && [ "$dec1" = "1" ] \
   && grep -q "family drift" "$FLEET_HOME/e1"; then
  ok "A1: launch refused on family drift, blocked event + needs-user decision"
else
  no "A1: family drift refusal (rc=$rc1 st=$st1 ev=$ev1 dec=$dec1)"
fi

# 2. A1: the daemon path blocks too, and the decision is written once per
#    task, not once per poll round (a decision per round would be spam).
fleet daemon run --once >/dev/null 2>&1
fleet daemon run --once >/dev/null 2>&1
dec2=$(fleet --json decisions | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len([r for r in rows if r["task_id"] == '"$T1"' and r["needs_user"] == 1]))')
st2=$(field "$T1" status)
if [ "$dec2" = "1" ] && [ "$st2" = "queued" ]; then
  ok "A1: daemon blocks on drift, decision deduped across rounds"
else
  no "A1: daemon drift block / decision dedup (dec=$dec2 st=$st2)"
fi

# 3. A1: fixing the channel unblocks the task -- the block is about drift,
#    not a permanent wedge.
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"]["drift"]["model"] = "GPT-drift-a"
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
fleet run "$T1" >/dev/null 2>&1
if wait_status "$T1" done; then
  ok "A1: task launches once the channel model is restored"
else
  no "A1: task launches once the channel model is restored (st=$(field "$T1" status))"
fi

# 4. A2: the ssh adapter exports FLEET_MODEL into the remote command line.
d4=$(FLEET_ADAPTER_DRYRUN=1 FLEET_SSH_HOST=h.example \
     FLEET_REMOTE_CMD='bash -c "claude -p --model $FLEET_MODEL"' FLEET_MODEL=GPT-remote-x \
     bash "$ROOT/adapters/ssh.sh" 4 "$FLEET_HOME/spec_echo.sh" /tmp \
     "$FLEET_HOME/o4" "$FLEET_HOME/l4")
if printf '%s\n' "$d4" | grep -qF "FLEET_MODEL=" \
   && printf '%s\n' "$d4" | grep -qF "GPT-remote-x"; then
  ok "A2: ssh dryrun carries FLEET_MODEL into the remote line"
else
  no "A2: ssh dryrun carries FLEET_MODEL ($d4)"
fi

# 5. A2: the switchboard adapter exports FLEET_MODEL into the remote env too.
d5=$(FLEET_ADAPTER_DRYRUN=1 FLEET_ATTEMPT=p11-attempt-5 FLEET_SB_NODE=n5 FLEET_SB_REMOTE_CMD=cat \
     FLEET_SB_MCP_CMD=cb FLEET_MODEL=GPT-remote-x \
     bash "$ROOT/adapters/switchboard.sh" 5 "$FLEET_HOME/spec_echo.sh" /tmp \
     "$FLEET_HOME/o5" "$FLEET_HOME/l5")
if printf '%s\n' "$d5" | grep -qF "FLEET_MODEL=" \
   && printf '%s\n' "$d5" | grep -qF "GPT-remote-x"; then
  ok "A2: switchboard dryrun carries FLEET_MODEL into the remote env"
else
  no "A2: switchboard dryrun carries FLEET_MODEL ($d5)"
fi

# 6. A2: a model-declaring ssh channel whose remote_cmd ignores $FLEET_MODEL
#    is refused at enqueue -- the declared model (and its family) is fiction.
fleet add "ssh model ignored" --channel ssh-model \
  --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>"$FLEET_HOME/e6"
rc6=$?
if [ "$rc6" = "13" ] && grep -q "FLEET_MODEL" "$FLEET_HOME/e6"; then
  ok "A2: ssh channel with model-ignoring remote_cmd refused (exit 13)"
else
  no "A2: ssh model-ignoring refusal (rc=$rc6)"
fi

# 7. A2: a remote_cmd that references $FLEET_MODEL is accepted.
T7=$(fleet add "ssh wired" --channel ssh-wired \
     --spec "$FLEET_HOME/spec_echo.sh" 2>"$FLEET_HOME/e7")
rc7=$?
fleet cancel "$T7" >/dev/null 2>&1 || true
if [ "$rc7" = "0" ] && [ -n "$T7" ]; then
  ok "A2: ssh channel with FLEET_MODEL-wired remote_cmd accepted"
else
  no "A2: ssh wired acceptance (rc=$rc7 err=$(cat "$FLEET_HOME/e7"))"
fi

# 7b. A2: a $FLEET_MODEL reference in DOUBLE quotes is refused: the remote
#     shell expands it at parse time, before the adapter's FLEET_MODEL=<value>
#     prefix assignment applies, so the agent gets an empty model (measured
#     on a clean remote: model=[]). The reference must be single-quoted so it
#     reaches the inner shell, which expands it from the injected env.
fleet add "ssh doublequoted" --channel ssh-dq \
  --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>"$FLEET_HOME/e7b"
rc7b=$?
if [ "$rc7b" = "13" ] && grep -q "single quotes" "$FLEET_HOME/e7b"; then
  ok "A2: double-quoted \$FLEET_MODEL reference refused (parse-time expansion)"
else
  no "A2: double-quoted reference refusal (rc=$rc7b err=$(cat "$FLEET_HOME/e7b"))"
fi

# 8. A2: same refusal for switchboard channels.
fleet add "sb model ignored" --channel sb-model \
  --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>"$FLEET_HOME/e8"
rc8=$?
if [ "$rc8" = "13" ] && grep -q "FLEET_MODEL" "$FLEET_HOME/e8"; then
  ok "A2: switchboard channel with model-ignoring remote_cmd refused (exit 13)"
else
  no "A2: switchboard model-ignoring refusal (rc=$rc8)"
fi

# 9. A3: family=none plus a declared model is a bypass, not an exemption.
fleet add "none with model" --channel none-with-model \
  --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>"$FLEET_HOME/e9"
rc9=$?
if [ "$rc9" = "14" ] && grep -q "family=none" "$FLEET_HOME/e9"; then
  ok "A3: family=none + model refused (exit 14)"
else
  no "A3: family=none + model refusal (rc=$rc9)"
fi

# 10. A3: same for a models menu.
fleet add "none with models" --channel none-with-models \
  --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>"$FLEET_HOME/e10"
rc10=$?
if [ "$rc10" = "14" ] && grep -q "family=none" "$FLEET_HOME/e10"; then
  ok "A3: family=none + models menu refused (exit 14)"
else
  no "A3: family=none + models menu refusal (rc=$rc10)"
fi

# 11. A3: a model-less family=none channel (shell) still works -- it runs no
#     model, so the exemption is real.
T11=$(fleet add "none plain" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$T11" >/dev/null
if wait_status "$T11" done; then
  ok "A3: model-less family=none channel still runs"
else
  no "A3: model-less family=none channel (st=$(field "$T11" status))"
fi

# 12-14. A4: the dedup key is (goal, plan revision, rule content hash, task).
#    A re-issued plan must re-arm its rules, and a rule whose content changed
#    must fire even though its index was used before.
G12=$(fleet goal add "g12")
cat > "$FLEET_HOME/rules12.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"shell","lens":"correctness"}}]
EOF
cat > "$FLEET_HOME/rules12b.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"shell","lens":"security"}}]
EOF
fleet plan set "$G12" --rules "$FLEET_HOME/rules12.json" --rationale r1 >/dev/null
T12=$(fleet add "r12 task" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --goal "$G12")
fleet daemon run --once >/dev/null 2>&1
wait_status "$T12" done
fleet daemon run --once >/dev/null 2>&1
n12=$(fleet --json status --all | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len([r for r in rows if r["review_of"] == '"$T12"']))')
# same revision, re-eval: idempotent
fleet daemon run --once >/dev/null 2>&1
n12b=$(fleet --json status --all | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len([r for r in rows if r["review_of"] == '"$T12"']))')
# new revision, identical rule: re-arms (revision is in the key)
fleet plan set "$G12" --rules "$FLEET_HOME/rules12.json" --rationale r2 >/dev/null
fleet daemon run --once >/dev/null 2>&1
n12c=$(fleet --json status --all | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len([r for r in rows if r["review_of"] == '"$T12"']))')
# new revision, different content at the same index: re-arms (hash in the key)
fleet plan set "$G12" --rules "$FLEET_HOME/rules12b.json" --rationale r3 >/dev/null
fleet daemon run --once >/dev/null 2>&1
n12d=$(fleet --json status --all | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len([r for r in rows if r["review_of"] == '"$T12"']))')
if [ "$n12" = "1" ] && [ "$n12b" = "1" ] && [ "$n12c" = "2" ] && [ "$n12d" = "3" ]; then
  ok "A4: dedup keyed by revision+content: idempotent, re-arms on re-issue"
else
  no "A4: dedup key ($n12/$n12b/$n12c/$n12d)"
fi

# 15. C1: `fleet add --review-of` shares the rule engine's construction:
#     the review opens the reviewed task's worktree (not the repo), and its
#     spec carries the branch, the diff --stat and the task's claims.
GR="$FLEET_HOME/gr"
mkdir -p "$GR"
git init -q "$GR"
printf 'orig\n' > "$GR/tracked.txt"
git -C "$GR" add tracked.txt
git -C "$GR" -c user.email=t@t -c user.name=t commit -qm init
printf "printf 'changed\\n' >> tracked.txt\n" > "$FLEET_HOME/spec_wt.sh"
T15=$(fleet add "wt task" --channel shell --spec "$FLEET_HOME/spec_wt.sh" \
      --cwd "$GR" --worktree)
fleet run "$T15" >/dev/null
wait_status "$T15" done
fleet claim add "$T15" "changed tracked.txt" --evidence "tracked.txt:1" >/dev/null
RV=$(fleet add "manual review" --channel shell --review-of "$T15")
rcwd=$(field "$RV" cwd)
wt15=$(field "$T15" worktree)
prompt15=$(cat "$(field "$RV" spec_path)")
if [ "$rcwd" = "$wt15" ] && [ -n "$wt15" ] \
   && printf '%s\n' "$prompt15" | grep -q "fleet/task-$T15" \
   && printf '%s\n' "$prompt15" | grep -q "tracked.txt" \
   && printf '%s\n' "$prompt15" | grep -q "changed tracked.txt" \
   && printf '%s\n' "$prompt15" | grep -q "Review the work of task $T15"; then
  ok "C1: manual --review-of opens the worktree, spec carries branch/diff/claims"
else
  no "C1: manual --review-of construction (rcwd=$rcwd wt=$wt15)"
fi

# 16. C1: the rule-engine path still constructs the same review (regression:
#     P8's fix now lives in the shared constructor, not in the engine).
G16=$(fleet goal add "g16")
cat > "$FLEET_HOME/rules16.json" <<'EOF'
[{"on":"task_done","do":"enqueue_review","with":{"channel":"shell"}}]
EOF
fleet plan set "$G16" --rules "$FLEET_HOME/rules16.json" --rationale r16 >/dev/null
T16=$(fleet add "wt16 task" --channel shell --spec "$FLEET_HOME/spec_wt.sh" \
      --cwd "$GR" --worktree --goal "$G16")
fleet daemon run --once >/dev/null 2>&1
wait_status "$T16" done
fleet daemon run --once >/dev/null 2>&1
RV16=$(fleet --json status --all | python3 -c '
import json, sys
rows = json.load(sys.stdin)
rv = [r for r in rows if r["review_of"] == '"$T16"']
print(rv[0]["id"] if len(rv) == 1 else "")')
if [ -n "$RV16" ] && [ "$(field "$RV16" cwd)" = "$(field "$T16" worktree)" ]; then
  ok "C1: rule-engine review still opens the worktree (shared constructor)"
else
  no "C1: rule-engine review construction (rv=$RV16)"
fi

# 17. C1: explicit --cwd/--spec still win over the constructed defaults.
RV17=$(fleet add "explicit review" --channel shell --review-of "$T15" --cwd /tmp)
if [ "$(field "$RV17" cwd)" = "/tmp" ]; then
  ok "C1: explicit --cwd overrides the constructed worktree cwd"
else
  no "C1: explicit --cwd override (cwd=$(field "$RV17" cwd))"
fi

# 18. C2: a daemon detects that its own binary changed on disk. It runs its
#     start-time code forever, so an upgrade must be surfaced (event +
#     status + brief) and left for a human to restart -- never auto-restarted.
DEP="$FLEET_HOME/deploy"
mkdir -p "$DEP/bin"
cp "$ROOT/bin/fleet" "$DEP/bin/fleet"
cp "$ROOT/bin/fleet_checks.py" "$DEP/bin/fleet_checks.py"
cp "$ROOT/schema.sql" "$ROOT/channels.json" "$DEP/"
"$DEP/bin/fleet" init >/dev/null
"$DEP/bin/fleet" daemon start --interval 1 >/dev/null
sleep 2
printf '\n# stale-code detection test marker\n' >> "$DEP/bin/fleet"
sleep 3
st18=$("$DEP/bin/fleet" daemon status 2>&1)
br18=$("$DEP/bin/fleet" brief | head -1)
ev18=$(python3 -c "
import sqlite3
print(sqlite3.connect('$FLEET_HOME/fleet.db').execute(
 \"SELECT COUNT(*) FROM event WHERE kind='daemon.stale_code'\").fetchone()[0])")
"$DEP/bin/fleet" daemon stop >/dev/null
if printf '%s\n' "$st18" | grep -q "code changed since start -- restart to pick it up" \
   && printf '%s\n' "$br18" | grep -q "code changed since start -- restart to pick it up" \
   && [ "$ev18" -ge 1 ]; then
  ok "C2: stale code detected: event, status and brief say restart"
else
  no "C2: stale code detection (st=$st18 br=$br18 ev=$ev18)"
fi

# 19. codex dryrun renders the real argv, including the model flag.
d19=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MODEL=GPT-x FLEET_HOME="$FLEET_HOME" \
      bash "$ROOT/adapters/codex.sh" 19 "$FLEET_HOME/spec_echo.sh" /tmp \
      "$FLEET_HOME/o19" "$FLEET_HOME/l19" 2>&1)
if printf '%s\n' "$d19" | grep -q -- '-m GPT-x' \
   && printf '%s\n' "$d19" | grep -q '^DRYRUN: codex '; then
  ok "codex dryrun includes the selected model"
else
  no "codex dryrun model flag ($d19)"
fi

# 20. C3: a review task that exits 0 with ZERO claims is failed, not done --
#     exit 0 plus an out.md of preamble otherwise reads as a passed review
#     that never checked anything. It writes task.review_empty and a
#     needs-user decision; a review with claims still completes done.
printf 'true\n' > "$FLEET_HOME/spec_true.sh"
TC3=$(fleet add "c3 target" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$TC3" >/dev/null 2>&1
wait_status "$TC3" done
RV=$(fleet add "c3 empty review" --channel shell --review-of "$TC3" \
     --spec "$FLEET_HOME/spec_true.sh")
fleet run "$RV" >/dev/null 2>&1
if wait_status "$RV" failed; then
  ev=$(fleet since --raw 0 | grep -c " task.review_empty $RV " || true)
  dec=$(fleet --json decisions | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len([r for r in rows if r["task_id"] == '"$RV"' and r["needs_user"] == 1]))')
  if [ "$ev" -ge 1 ] && [ "$dec" -ge 1 ]; then
    ok "C3: zero-claim review failed + task.review_empty + needs-user decision"
  else
    no "C3: zero-claim review markers (ev=$ev dec=$dec)"
  fi
else
  no "C3: zero-claim review failed (st=$(field "$RV" status))"
fi

# 21. C3: a non-review task that exits 0 with zero claims is unaffected --
#     some tasks legitimately write nothing, and only reviews are judged by
#     their claims.
TN=$(fleet add "c3 nonreview" --channel shell --spec "$FLEET_HOME/spec_true.sh")
fleet run "$TN" >/dev/null 2>&1
if wait_status "$TN" done; then
  ok "C3: non-review zero-claim task still done"
else
  no "C3: non-review zero-claim task (st=$(field "$TN" status))"
fi

# 22. D1: a channel deleted while a task is queued is the same wedge as
#     family drift -- explicit run AND daemon must write
#     task.blocked{reason:"unknown channel"} + a needs-user decision, not
#     just print and move on. The task stays queued so restoring the
#     channel unblocks it.
TD=$(fleet add "d1 task" --channel drift --spec "$FLEET_HOME/spec_echo.sh")
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
del d["channels"]["drift"]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
fleet run "$TD" 2>"$FLEET_HOME/e22"
rc22=$?
st22=$(field "$TD" status)
ev22=$(fleet since --raw 0 | grep -c " task.blocked $TD .*unknown channel" || true)
dec22=$(fleet --json decisions | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len([r for r in rows if r["task_id"] == '"$TD"' and r["needs_user"] == 1]))')
# daemon round: same wedge, decision deduped (not written twice)
fleet daemon run --once >/dev/null 2>&1
dec22b=$(fleet --json decisions | python3 -c '
import json, sys
rows = json.load(sys.stdin)
print(len([r for r in rows if r["task_id"] == '"$TD"' and r["needs_user"] == 1]))')
st22b=$(field "$TD" status)
# restore the channel so the task can be cleaned up
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"]["drift"] = {"adapter": "shell.sh", "model": "GPT-drift-a"}
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
if [ "$rc22" != "0" ] && [ "$st22" = "queued" ] && [ "$ev22" -ge 1 ] \
   && [ "$dec22" -ge 1 ] && [ "$dec22b" = "$dec22" ] && [ "$st22b" = "queued" ] \
   && grep -q "unknown channel" "$FLEET_HOME/e22"; then
  ok "D1: deleted channel blocks with event + decision, task stays queued"
else
  no "D1: deleted channel block (rc=$rc22 st=$st22 ev=$ev22 dec=$dec22/$dec22b)"
fi
fleet cancel "$TD" >/dev/null 2>&1 || true

# 23. D4: a review of a NO-worktree task still gets the task's claims in
#     its spec -- the claim paragraph used to be nested inside the
#     worktree branch, so a no-worktree review got a spec with no claims.
TX=$(fleet add "d4 target" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$TX" >/dev/null 2>&1
wait_status "$TX" done
fleet claim add "$TX" "d4 claim marker" --evidence "d4-ev file:1" >/dev/null
RY=$(fleet add "d4 review" --channel shell --review-of "$TX")
spec23=$(cat "$(field "$RY" spec_path)")
if printf '%s\n' "$spec23" | grep -q "d4 claim marker" \
   && printf '%s\n' "$spec23" | grep -q "d4-ev file:1"; then
  ok "D4: no-worktree review spec carries the task's claims"
else
  no "D4: no-worktree review claims (spec missing the claim)"
fi

# 24. project-agnostic
PAT="${FLEET_FORBIDDEN_NAMES:-Acme""Corp|acme""-internal}"
if grep -rIn -E "$PAT" "$ROOT" --exclude-dir=.git --exclude-dir=docs; then
  no "project-agnostic: no concrete project names"
else
  ok "project-agnostic: no concrete project names"
fi

# A remote channel may run work but may not certify it: the model behind its
# declared family is injected by the adapter and honoured (or not) by a remote
# command this machine cannot inspect. An unverifiable family certifying another
# family is the fake independence the whole check exists to stop.
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"]["remote-box"] = {"adapter": "ssh.sh", "ssh_host": "remote.invalid",
                               "model": "gpt-5.6-sol",
                               "remote_cmd": "sh -c 'codex exec - -m \"$FLEET_MODEL\"'"}
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
LOCAL=$(fleet add "local work" --channel cursor --spec "$FLEET_HOME/spec_echo.sh")
fleet add "remote reviews local" --channel remote-box --review-of "$LOCAL" \
  --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>"$FLEET_HOME/err_remote"
rcr=$?
R2=$(fleet add "remote runs work" --channel remote-box --allow-offline \
     --spec "$FLEET_HOME/spec_echo.sh" 2>/dev/null)
if [ "$rcr" = "2" ] && grep -q "may not review it" "$FLEET_HOME/err_remote" && [ -n "$R2" ]; then
  ok "a remote channel may run work but not review it"
else
  no "a remote channel may run work but not review it (rc=$rcr R2=$R2)"
fi
fleet cancel "$LOCAL" >/dev/null 2>&1 || true
fleet cancel "$R2" >/dev/null 2>&1 || true

echo "---"
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = "0" ]
