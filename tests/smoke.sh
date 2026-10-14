#!/usr/bin/env bash
# fleet P0 smoke tests. Zero model quota: only the shell channel is used.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-test-XXXX)"
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

# spec fixtures (shell channel executes the prompt as a script)
printf 'echo hello\n'      > "$FLEET_HOME/spec_echo.sh"
printf 'exit 3\n'          > "$FLEET_HOME/spec_fail.sh"
printf 'sleep 2; exit 4\n' > "$FLEET_HOME/spec_retry.sh"
printf 'sleep 5\n'         > "$FLEET_HOME/spec_sleep5.sh"
printf 'sleep 10\n'        > "$FLEET_HOME/spec_sleep10.sh"
printf 'sleep 30\n'        > "$FLEET_HOME/spec_sleep30.sh"

# 1. init is idempotent
if fleet init >/dev/null && fleet init >/dev/null; then
  ok "init idempotent"
else
  no "init idempotent"
fi

# Tests that need a misleading alias own that fixture instead of depending on
# the shipped channel table. The exact pattern is inserted before broad gpt-*.
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["model_families"] = {"gpt-looking-claude": "claude", **d["model_families"]}
d["channels"]["alias-fixture"] = {
    "adapter": "shell.sh", "model": "gpt-5.6-sol",
    "models": ["gpt-5.6-sol", "gpt-looking-claude"],
}
d["channels"]["no-menu-fixture"] = {
    "adapter": "shell.sh", "model": "gpt-5.6-sol",
}
json.dump(d, open(p, "w"), indent=2)
PY

# 2. successful task: done, digest carries output, exit 0
T2=$(fleet add "echo task" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$T2" >/dev/null
if wait_status "$T2" done \
   && fleet digest "$T2" | grep -q hello \
   && [ "$(field "$T2" exit_code)" = "0" ]; then
  ok "success task: done, digest, exit 0"
else
  no "success task: done, digest, exit 0"
fi

# 3. failing task: failed with exit code preserved
T3=$(fleet add "fail task" --channel shell --spec "$FLEET_HOME/spec_fail.sh")
fleet run "$T3" >/dev/null
if wait_status "$T3" failed && [ "$(field "$T3" exit_code)" = "3" ]; then
  ok "failure task: failed exit 3"
else
  no "failure task: failed exit 3"
fi

# The launcher owns stderr capture from the adapter's first instruction, and
# settlement synthesizes a small out.md when a failing adapter wrote none.
# This pins diagnostic artifacts for every adapter, including future preflight
# checks that fail before installing their own redirections.
if grep -q '^# Adapter failed$' "$FLEET_HOME/runs/$T3/attempt-1/out.md" \
   && grep -q '^adapter exited 3$' "$FLEET_HOME/runs/$T3/attempt-1/out.md"; then
  ok "failure without output still leaves a diagnostic out.md"
else
  no "failure without output left no diagnostic out.md"
fi

# 4. retry: first failure requeues with attempt=1; second attempt fails final
T4=$(fleet add "retry task" --channel shell --spec "$FLEET_HOME/spec_retry.sh" --max-attempts 2)
fleet run "$T4" >/dev/null
requeued=""
for i in $(seq 1 100); do
  if [ "$(field "$T4" status)" = "queued" ] && [ "$(field "$T4" attempt)" = "1" ]; then
    requeued=1
    break
  fi
  sleep 0.2
done
if [ -n "$requeued" ]; then
  fleet run "$T4" >/dev/null
  if wait_status "$T4" failed \
     && [ "$(field "$T4" exit_code)" = "4" ] \
     && [ "$(field "$T4" attempt)" = "2" ]; then
    ok "retry: requeued attempt=1, then failed at attempt=2"
  else
    no "retry: second attempt outcome"
  fi
else
  no "retry: requeued with attempt=1"
fi

# 5. dep gating: B held while A is open, starts once A is done
A=$(fleet add "dep A" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
B=$(fleet add "dep B" --channel shell --spec "$FLEET_HOME/spec_echo.sh" --dep "$A")
fleet run --ready >/dev/null
if [ "$(field "$B" status)" = "queued" ] && wait_status "$A" done; then
  fleet run --ready >/dev/null
  if wait_status "$B" done; then
    ok "dep gating"
  else
    no "dep gating (B after A)"
  fi
else
  no "dep gating (B held while A open)"
fi

# 6. cross-family review is rejected at enqueue time
T=$(fleet add "review target" --channel cursor)
fleet add "same-family review" --channel claude-p --review-of "$T" \
  >/dev/null 2>"$FLEET_HOME/err6"
rc6=$?
if [ "$rc6" = "2" ] && grep -q "cross-family violation" "$FLEET_HOME/err6"; then
  ok "cross-family: same family rejected with exit 2"
else
  no "cross-family: same family rejected with exit 2 (rc=$rc6)"
fi
R2=$(fleet add "other-family review" --channel codex --review-of "$T" 2>/dev/null)
if [ -n "$R2" ]; then
  ok "cross-family: other-family channel allowed"
else
  no "cross-family: other-family channel allowed"
fi

# 7. alias trap: a gpt-looking name is served by a gpt-defaulted fixture,
# but its real base is Claude, so reviewing a Claude task with it must still be
# refused. The pattern order in model_families is what makes this hold.
fleet add "alias review" --channel alias-fixture --model gpt-looking-claude \
  --review-of "$T" >/dev/null 2>&1
rc7=$?
if [ "$rc7" = "2" ]; then
  ok "alias trap: gpt-looking alias rejected (real base is claude)"
else
  no "alias trap: gpt-looking alias rejected (real base is claude) (rc=$rc7)"
fi
# The target task is never meant to run; cancel it so later `run --ready`
# calls do not pick it up (and so no model-backed channel ever fires here).
fleet cancel "$T" >/dev/null 2>&1 || true
[ -n "$R2" ] && fleet cancel "$R2" >/dev/null 2>&1 || true

# 8. lease mutex: same resource, only one starts
L1=$(fleet add "lease 1" --channel shell --spec "$FLEET_HOME/spec_sleep5.sh" --lease resX)
L2=$(fleet add "lease 2" --channel shell --spec "$FLEET_HOME/spec_sleep5.sh" --lease resX)
fleet run --ready >/dev/null
s1=$(field "$L1" status)
s2=$(field "$L2" status)
if [ "$s1" != "$s2" ] \
   && { [ "$s1" = "running" ] || [ "$s2" = "running" ]; } \
   && { [ "$s1" = "queued" ] || [ "$s2" = "queued" ]; }; then
  ok "lease mutex: exactly one started"
else
  no "lease mutex: exactly one started ($s1/$s2)"
fi
fleet cancel "$L1" >/dev/null 2>&1 || true
fleet cancel "$L2" >/dev/null 2>&1 || true

# 9. budget: quota allows one, the second is blocked with an event
used=$(fleet channels | awk '$1=="shell"{split($4,a,"/"); print a[1]}')
fleet budget set shell "$(date +%Y-%m)" "$((used+1))" >/dev/null
BG1=$(fleet add "budget 1" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
BG2=$(fleet add "budget 2" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run --ready >/dev/null
b1=$(field "$BG1" status)
b2=$(field "$BG2" status)
if { [ "$b1" = "running" ] || [ "$b1" = "done" ]; } \
   && [ "$b2" = "queued" ] \
   && [ "$(fleet since --raw 0 | grep -c " task.blocked $BG2 .*\"reason\": \"budget\"")" -ge 1 ]; then
  ok "budget: second task blocked, event written"
else
  no "budget: second task blocked, event written ($b1/$b2)"
fi
fleet cancel "$BG2" >/dev/null 2>&1 || true
fleet budget set shell "$(date +%Y-%m)" 1000000 >/dev/null

# 10. concurrency cap: max_parallel=2 starts 2 of 4
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["max_parallel"] = 2
json.dump(d, open(p, "w"), indent=2)
EOF
P1=$(fleet add "par 1" --channel shell --spec "$FLEET_HOME/spec_sleep10.sh")
P2=$(fleet add "par 2" --channel shell --spec "$FLEET_HOME/spec_sleep10.sh")
P3=$(fleet add "par 3" --channel shell --spec "$FLEET_HOME/spec_sleep10.sh")
P4=$(fleet add "par 4" --channel shell --spec "$FLEET_HOME/spec_sleep10.sh")
fleet run --ready >/dev/null
running=0
for p in "$P1" "$P2" "$P3" "$P4"; do
  [ "$(field "$p" status)" = "running" ] && running=$((running+1))
done
if [ "$running" = "2" ]; then
  ok "max_parallel=2: 2 of 4 started"
else
  no "max_parallel=2: 2 of 4 started (got $running)"
fi
for p in "$P1" "$P2" "$P3" "$P4"; do
  fleet cancel "$p" >/dev/null 2>&1 || true
done

# 11. since: no replay across calls, watermark advances
out1=$(fleet since)
wm1=$(printf '%s\n' "$out1" | tail -1 | sed 's/^watermark=//')
fleet goal add "wm probe" >/dev/null
out2=$(fleet since)
wm2=$(printf '%s\n' "$out2" | tail -1 | sed 's/^watermark=//')
overlap=$(printf '%s\n' "$out2" | grep -v '^watermark=' \
  | awk -v w="$wm1" '$1<=w{c++} END{print c+0}')
if [ "$overlap" = "0" ] && [ "$wm2" -gt "$wm1" ]; then
  ok "since: no replay, watermark advances"
else
  no "since: no replay, watermark advances (wm1=$wm1 wm2=$wm2 overlap=$overlap)"
fi

# 12. wait: timeout 124 while running, 0 once settled
S=$(fleet add "sleeper" --channel shell --spec "$FLEET_HOME/spec_sleep30.sh")
fleet run "$S" >/dev/null
fleet wait --any --ids "$S" --timeout 1 >/dev/null 2>&1
rcw=$?
Q=$(fleet add "quick" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$Q" >/dev/null
wait_status "$Q" done >/dev/null 2>&1
fleet wait --any --ids "$Q" >/dev/null 2>&1
rcq=$?
if [ "$rcw" = "124" ] && [ "$rcq" = "0" ]; then
  ok "wait: timeout 124, settled 0"
else
  no "wait: timeout 124, settled 0 (rcw=$rcw rcq=$rcq)"
fi
fleet cancel "$S" >/dev/null 2>&1 || true

# 13. terminal decoupling: launcher shell exits, task still settles
D=$(fleet add "detached" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
bash -c "fleet run $D" >/dev/null
if wait_status "$D" done; then
  ok "decoupled: task settles after launcher exits"
else
  no "decoupled: task settles after launcher exits"
fi

# 14. project-agnostic: no concrete project names anywhere in the tree.
# The names come from FLEET_FORBIDDEN_NAMES (an extended regex; set it to the
# names of the projects you use Fleet on); the default is a placeholder. The
# default is split with "" so this file does not contain what it checks for. Documentation is checked
# separately; the tool itself (bin/, adapters/, templates/, and tests/) must
# stay agnostic.
PAT="${FLEET_FORBIDDEN_NAMES:-Acme""Corp|acme""-internal}"
if grep -rIn -E "$PAT" "$ROOT" \
    --exclude-dir=.git \
    --exclude-dir=docs; then
  no "project-agnostic: no concrete project names"
else
  ok "project-agnostic: no concrete project names"
fi

# 16. orphan reaping: nothing supervises the wrappers, so a SIGKILLed wrapper
# must not leave the task 'running' forever holding its lease and a slot.
printf 'sleep 300\n' > "$FLEET_HOME/spec_sleep2.sh"
O=$(fleet add "orphan" --channel shell --spec "$FLEET_HOME/spec_sleep2.sh" --lease orphan-res)
fleet run "$O" >/dev/null
sleep 1
OPID=$(cat "$FLEET_HOME/runs/$O/wrapper.pid" 2>/dev/null || echo 0)
kill -9 -"$OPID" 2>/dev/null || kill -9 "$OPID" 2>/dev/null || true
sleep 1
ost=$(FLEET_ORPHAN_GRACE_S=1 fleet status --all | awk -v i="$O" '$1==i {print $2}')
lease_left=$(FLEET_ORPHAN_GRACE_S=1 fleet lease list | grep -c orphan-res || true)
if [ "$ost" = "failed" ] && [ "$lease_left" = "0" ]; then
  ok "orphan reaped: status failed and lease released"
else
  no "orphan reaped: status failed and lease released (status=$ost lease_left=$lease_left)"
fi

# 17. launch() strips inherited model-selection env vars. An ambient
# ANTHROPIC_MODEL from the calling session would otherwise reach a
# model-backed adapter, which then runs against an id it does not recognise
# and can fail silently (task 'done', nothing produced). Model choice belongs
# to the channel table, never to whoever happened to launch fleet.
# Unrelated variables must survive: the strip is targeted, not a wipe.
cat > "$FLEET_HOME/spec_env.sh" <<'EOS'
echo "M=[${ANTHROPIC_MODEL:-}] O=[${ANTHROPIC_DEFAULT_OPUS_MODEL:-}] S=[${CLAUDE_CODE_SUBAGENT_MODEL:-}] KEEP=[${FLEET_ENV_PROBE:-}]"
EOS
E=$(fleet add "env strip" --channel shell --spec "$FLEET_HOME/spec_env.sh")
ANTHROPIC_MODEL=bogus/model ANTHROPIC_DEFAULT_OPUS_MODEL=bogus/opus \
  CLAUDE_CODE_SUBAGENT_MODEL=bogus/sub FLEET_ENV_PROBE=kept \
  fleet run "$E" >/dev/null
wait_status "$E" done >/dev/null
got=$(fleet digest "$E" | tr -d '\n')
if [ "$got" = "M=[] O=[] S=[] KEEP=[kept]" ]; then
  ok "launch strips inherited model env, keeps the rest"
else
  no "launch strips inherited model env, keeps the rest (got: $got)"
fi

# 18-20. family follows the model actually used, not the channel. Every real
# channel here can drive several model families, so binding family to the
# channel would let `--channel <gpt channel> --model <a claude model>` sail
# through a cross-family review check while Claude reviews Claude.
MIX=$(fleet add "gpt-default source, claude-based model" --channel alias-fixture \
        --model gpt-looking-claude --spec "$FLEET_HOME/spec_echo.sh")
if [ "$(field "$MIX" family)" = "claude" ]; then
  ok "family follows --model override, not the channel"
else
  no "family follows --model override, not the channel (got $(field "$MIX" family))"
fi

fleet add "same-family review of mixed task" --channel claude-p \
  --review-of "$MIX" --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>&1
rc18=$?
fleet add "cross-family review of mixed task" --channel codex \
  --review-of "$MIX" --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>&1
rc19=$?
if [ "$rc18" = "2" ] && [ "$rc19" = "0" ]; then
  ok "mixed task: claude reviewer rejected, gpt reviewer allowed"
else
  no "mixed task: claude reviewer rejected, gpt reviewer allowed (rc=$rc18/$rc19)"
fi

# This case needs a real channel with no models list, so the menu check cannot
# fire and family resolution is what refuses.
fleet add "unclassifiable" --channel no-menu-fixture --model "totally-unknown-xyz" \
  --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>&1
if [ "$?" = "3" ]; then
  ok "unclassifiable --model refused rather than assumed"
else
  no "unclassifiable --model refused rather than assumed (rc=$?)"
fi

# 21. brief: the only view that carries intent. status/claim/decisions answer
# what is happening; none answer why the work was cut this way, so a fresh
# session re-walks routes an earlier one already rejected.
GB=$(fleet goal add "refactor and review" --gate '*/prod/*')
printf '%s' '[]' | fleet plan set "$GB" --rules - \
  --rationale "dropped the whole-tree rewrite: it timed out in CI" >/dev/null
BT=$(fleet add "impl" --channel shell --spec "$FLEET_HOME/spec_sleep10.sh" --goal "$GB")
fleet run "$BT" >/dev/null
fleet claim add "$BT" "it works" --evidence "file.py:1" >/dev/null
fleet decide "widen the threshold?" --goal "$GB" --needs-user >/dev/null
brief=$(fleet brief)
if echo "$brief" | grep -q "timed out in CI" \
   && echo "$brief" | grep -q "NEEDS YOU" \
   && echo "$brief" | grep -q "unverified 1 claim"; then
  ok "brief carries intent, in-flight work and what needs the user"
else
  no "brief carries intent, in-flight work and what needs the user"
fi
fleet cancel "$BT" >/dev/null 2>&1 || true

# 22. brief's INBOX section. brief is the documented opening command, and it
# read every table but message: mail sent by another machine, another session
# or an agent's fleet_message sat in the ledger with no reader, while brief
# happily reported NEEDS YOU decisions, unverified claims and STALLED.
fleet msg send --from x --to commander --topic ask "开会吗" >/dev/null
brief=$(fleet brief)
if echo "$brief" | grep -q "INBOX" && echo "$brief" | grep -q "开会吗"; then
  ok "brief INBOX: unread commander mail is named, with its body"
else
  no "brief INBOX: unread commander mail is named, with its body"
fi

# 23. An emptied mailbox prints nothing at all: brief's sections are what
# still wants attention, and a permanent "INBOX 0" line teaches the reader to
# skip the place the signal arrives.
fleet msg inbox --for commander --mark-read >/dev/null
if ! fleet brief | grep -q "INBOX"; then
  ok "brief INBOX: silent once the mailbox is read"
else
  no "brief INBOX: silent once the mailbox is read"
fi

# 24. Proposal topics are excluded: `fleet proposals` and `fleet notes` are
# their reader, and unlike ordinary mail they are never marked read, so they
# would accumulate forever and crowd out the mail INBOX exists to surface.
fleet msg send --from z --to commander --topic spawn-proposal "enqueue a fix task" >/dev/null
if ! fleet brief | grep -q "INBOX"; then
  ok "brief INBOX: proposal topics stay out of the section"
else
  no "brief INBOX: proposal topics stay out of the section"
fi

# 25. The count covers every unread message, the listing is capped: a burst of
# mail must not push the rest of brief off the screen, and must not hide that
# there is more than what is shown.
for i in 1 2 3 4 5; do
  fleet msg send --from "peer$i" --to commander "message body $i" >/dev/null
done
brief=$(fleet brief)
n_head=$(printf '%s\n' "$brief" | grep -c '^INBOX  5 ')
n_body=$(printf '%s\n' "$brief" | awk '/^INBOX/{f=1;next} f&&/^  /{c++} END{print c+0}')
if [ "$n_head" = "1" ] && [ "$n_body" = "3" ]; then
  ok "brief INBOX: counts all 5 unread, lists 3"
else
  no "brief INBOX: counts all 5 unread, lists 3 (head=$n_head body=$n_body)"
fi

# 26. brief must not swallow mail. It is a writer command (it reaps orphans),
# so nothing structural stops it from marking what it printed as read -- and
# then a glance at brief would consume exactly the messages this section
# exists to surface. Two consecutive briefs therefore show the same mail.
# `msg inbox` cannot prove this on its own: it lists read and unread alike.
fleet brief >/dev/null
brief=$(fleet brief)
if echo "$brief" | grep -q '^INBOX  5 ' \
   && fleet msg inbox --for commander | grep -q "message body 5"; then
  ok "brief INBOX: reading brief does not mark mail read"
else
  no "brief INBOX: reading brief does not mark mail read"
fi

# 27. A broadcast reaches the commander: mail addressed to everyone is just
# what a session with no context needs, so '--to all' must not be a way to go
# unread. Clearing it takes '--for all' -- '--for commander' matches the
# literal recipient only -- and this case leaves the mailbox empty for
# whatever asserts on brief after it.
fleet msg send --from bcast --to all "all-hands note" >/dev/null
b1=$(fleet brief)
fleet msg inbox --for all --mark-read >/dev/null
fleet msg inbox --for commander --mark-read >/dev/null
b2=$(fleet brief)
if echo "$b1" | grep -q "all-hands note" && ! echo "$b2" | grep -q "INBOX"; then
  ok "brief INBOX: --to all reaches the commander, --for all clears it"
else
  no "brief INBOX: --to all reaches the commander, --for all clears it"
fi

# The child environment is an allowlist. A denylist only excludes what someone
# remembered to name, while a launching session's bearer token could otherwise
# reach tasks running on a third-party relay or another machine.
cat > "$FLEET_HOME/spec_env2.sh" <<'EOS'
echo "TOK=[${CLAUDE_CODE_SESSION_ACCESS_TOKEN:-}] MSG=[${CLAUDE_CODE_MESSAGING_TOKEN:-}] SID=[${CLAUDE_CODE_SESSION_ID:-}] SECRET=[${MY_UNRELATED_SECRET:-}] PATH_OK=[${PATH:+yes}] FLEET=[${FLEET_HOME:+yes}]"
EOS
E2=$(fleet add "env allowlist" --channel shell --spec "$FLEET_HOME/spec_env2.sh")
CLAUDE_CODE_SESSION_ACCESS_TOKEN=sk-leak CLAUDE_CODE_MESSAGING_TOKEN=message-leak \
  CLAUDE_CODE_SESSION_ID=sid-leak MY_UNRELATED_SECRET=nope \
  fleet run "$E2" >/dev/null
wait_status "$E2" done >/dev/null
got2=$(fleet digest "$E2" | tr -d '\n')
if [ "$got2" = "TOK=[] MSG=[] SID=[] SECRET=[] PATH_OK=[yes] FLEET=[yes]" ]; then
  ok "child env is an allowlist: no session credentials, no stray vars, basics kept"
else
  no "child env is an allowlist (got: $got2)"
fi

# The child environment is an allowlist: a caller variable the channel does
# not grant is filtered out, and `env_passthrough` is the explicit escape hatch
# that lets one exact key through.
cat > "$FLEET_HOME/spec_passthrough_env.sh" <<'EOS'
echo "SMOKE_PASSTHROUGH_PROBE=[${SMOKE_PASSTHROUGH_PROBE:-}]"
EOS
PT_DEFAULT=$(fleet add "passthrough default" --channel shell \
  --spec "$FLEET_HOME/spec_passthrough_env.sh")
SMOKE_PASSTHROUGH_PROBE=0 fleet run "$PT_DEFAULT" >/dev/null
wait_status "$PT_DEFAULT" done >/dev/null
pt_default=$(fleet digest "$PT_DEFAULT" | tr -d '\n')
if [ "$pt_default" = "SMOKE_PASSTHROUGH_PROBE=[]" ]; then
  ok "an ungranted caller variable does not reach the child"
else
  no "an ungranted caller variable does not reach the child (got: $pt_default)"
fi

python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as src:
    data = json.load(src)
data["channels"]["shell"]["env_passthrough"] = ["SMOKE_PASSTHROUGH_PROBE"]
with open(p, "w") as dst:
    json.dump(data, dst, indent=2)
PY
PT_OVERRIDE=$(fleet add "passthrough granted" --channel shell \
  --spec "$FLEET_HOME/spec_passthrough_env.sh")
SMOKE_PASSTHROUGH_PROBE=0 fleet run "$PT_OVERRIDE" >/dev/null
wait_status "$PT_OVERRIDE" done >/dev/null
pt_override=$(fleet digest "$PT_OVERRIDE" | tr -d '\n')
if [ "$pt_override" = "SMOKE_PASSTHROUGH_PROBE=[0]" ]; then
  ok "env_passthrough lets the granted caller value through"
else
  no "env_passthrough lets the granted caller value through (got: $pt_override)"
fi

# Overlong human titles warn on stderr but still enqueue: the warning names
# the habit that taught commanders to propose overlong titles (which used to
# void the whole round); refusal is not the point.
LONG_EN="$(python3 -c 'print("w"*41)')"
LONG_CN="超长标题超长标题超长标题超长标题超长标题超长标题超长标题超长标题超长标题超长标题超长标题"
add_out=$(fleet add "$LONG_EN" --channel shell \
  --spec "$FLEET_HOME/spec_echo.sh" 2>"$FLEET_HOME/add-warn.txt")
add_rc=$?
warn=$(cat "$FLEET_HOME/add-warn.txt")
got_warn=0
if [ "$add_rc" = 0 ] && [ -n "$add_out" ] && printf '%s' "$warn" | grep -q 'warning' \
   && printf '%s' "$warn" | grep -q '41' \
   && printf '%s' "$warn" | grep -q '40'; then
  got_warn=1
fi
add_out2=$(fleet add "$LONG_CN" --channel shell \
  --spec "$FLEET_HOME/spec_echo.sh" 2>"$FLEET_HOME/add-warn2.txt")
warn2=$(cat "$FLEET_HOME/add-warn2.txt")
if [ "$got_warn" = 1 ] && printf '%s' "$warn2" | grep -q 'warning' \
   && [ -n "$add_out2" ]; then
  ok "fleet add warns on stderr for overlong EN/CJK titles but still enqueues"
else
  no "fleet add overlong-title warning (rc=$add_rc warn='$warn' warn2='$warn2')"
fi
# A title at the cap stays silent: the warning must not fire on legal input.
AT_CAP="$(python3 -c 'print("q"*40)')"
if fleet add "$AT_CAP" --channel shell --spec "$FLEET_HOME/spec_echo.sh" \
     2>"$FLEET_HOME/add-ok.txt" >/dev/null && [ ! -s "$FLEET_HOME/add-ok.txt" ]; then
  ok "fleet add stays silent for a 40-char title"
else
  no "fleet add overlong-title warning fired at the cap ($(cat "$FLEET_HOME/add-ok.txt"))"
fi

mkdir -p "$FLEET_HOME/specs"
FILE_SPEC="$FLEET_HOME/specs/source-spec.sh"
printf 'echo from-file\n' >"$FILE_SPEC"
SRC_TASK=$(fleet add "file spec source" --channel shell --spec "$FILE_SPEC")
SRC_PROMPT="$FLEET_HOME/runs/$SRC_TASK/prompt.md"
SRC_META="$FLEET_HOME/runs/$SRC_TASK/meta.json"
src_meta=$(python3 - "$SRC_META" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get("spec_source", ""))
PY
)
src_show=$(fleet show "$SRC_TASK" | awk '$1=="spec_source:"{print $2}')
needle_file="规格原文件：\`$FILE_SPEC\`"
needle_dir="相对于 \`$FLEET_HOME/specs/\`。"
if grep -Fq "$needle_file" "$SRC_PROMPT" \
   && grep -Fq "$needle_dir" "$SRC_PROMPT" \
   && [ "$src_meta" = "$FILE_SPEC" ] \
   && [ "$src_show" = "$FILE_SPEC" ]; then
  ok "file --spec records and displays the absolute source path"
else
  no "file --spec source path (prompt=$(sed -n '1p' "$SRC_PROMPT") meta='$src_meta' show='$src_show')"
fi

STDIN_TASK=$(printf 'echo from-stdin\n' | fleet add "stdin spec source" --channel shell --spec -)
STDIN_PROMPT="$FLEET_HOME/runs/$STDIN_TASK/prompt.md"
STDIN_META="$FLEET_HOME/runs/$STDIN_TASK/meta.json"
stdin_meta=$(python3 - "$STDIN_META" <<'PY'
import json,sys
print("spec_source" in json.load(open(sys.argv[1])))
PY
)
stdin_show=$(fleet show "$STDIN_TASK" | awk '$1=="spec_source:"{print $2}')
GCMD=$(fleet goal add "commander source probe")
DRIVER="$FLEET_HOME/commander-driver.sh"
printf '#!/usr/bin/env bash\nprintf FLEET_DRIVER_MARK\n' >"$DRIVER"
chmod +x "$DRIVER"
CMD_TASK=$(fleet add --role commander --goal "$GCMD" --channel shell --spec "$DRIVER")
CMD_PROMPT="$FLEET_HOME/runs/$CMD_TASK/prompt.md"
CMD_META="$FLEET_HOME/runs/$CMD_TASK/meta.json"
cmd_meta=$(python3 - "$CMD_META" <<'PY'
import json,sys
print("spec_source" in json.load(open(sys.argv[1])))
PY
)
if ! grep -q "规格原文件" "$STDIN_PROMPT" \
   && [ "$stdin_meta" = "False" ] \
   && [ -z "$stdin_show" ] \
   && ! grep -q "规格原文件" "$CMD_PROMPT" \
   && [ "$cmd_meta" = "False" ]; then
  ok "stdin specs and commander prompts do not get a spec_source notice"
else
  no "stdin/commander spec source suppression (stdin_meta=$stdin_meta show='$stdin_show' cmd_meta=$cmd_meta)"
fi

echo "---"
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = "0" ]
