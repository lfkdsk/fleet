#!/usr/bin/env bash
# P14: channel fallback degradation and blocked reasons in brief.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
unset _FLEET_LOCK_FD
PASS=0 FAIL=0 N=0 HOMES=()
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }
field(){ fleet show "$1" | awk -v f="$2" '$1==f":"{print $2}'; }
sql(){ sqlite3 "$FLEET_HOME/fleet.db" "$1"; }
cleanup(){
  local h id
  for h in "${HOMES[@]}"; do
    FLEET_HOME="$h" fleet daemon stop >/dev/null 2>&1 || true
    while read -r id; do FLEET_HOME="$h" fleet cancel "$id" >/dev/null 2>&1 || true; done \
      < <(sqlite3 "$h/fleet.db" "select id from task where status='running'" 2>/dev/null)
    rm -rf "$h"
  done
}
trap cleanup EXIT

fresh(){
  export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p14-test-XXXX)"
  HOMES+=("$FLEET_HOME")
  fleet init >/dev/null
  jq '.channels += {
    "p14-src":{"adapter":"shell.sh","model":"gpt-old","models":["gpt-old"],"quota":0,"fallback":["p14-claude","p14-full","p14-grok"]},
    "p14-cap":{"adapter":"shell.sh","model":"gpt-cap","models":["gpt-cap"],"max_parallel":0,"fallback":["p14-claude"]},
    "p14-cap-none":{"adapter":"shell.sh","model":"gpt-cap-none","models":["gpt-cap-none"],"max_parallel":0},
    "p14-claude":{"adapter":"shell.sh","model":"claude-new","models":["claude-new"],"prompt_extra":"# NEW NOTES","fallback":["p14-grok"]},
    "p14-grok":{"adapter":"shell.sh","model":"grok-new","models":["grok-new"]},
    "p14-full":{"adapter":"shell.sh","model":"grok-full","models":["grok-full"],"quota":0},
    "p14-none":{"adapter":"shell.sh","model":"gpt-none","models":["gpt-none"],"quota":0},
    "p14-oldnotes":{"adapter":"shell.sh","model":"gpt-notes","models":["gpt-notes"],"quota":0,"prompt_extra":"# OLD NOTES","fallback":["p14-claude"]}
  }' "$FLEET_HOME/channels.json" > "$FLEET_HOME/channels.new"
  mv "$FLEET_HOME/channels.new" "$FLEET_HOME/channels.json"
  printf 'sleep 30\n' > "$FLEET_HOME/sleep.sh"
}
add(){ fleet add "$1" --channel "$2" --no-preamble --spec "$FLEET_HOME/sleep.sh" "${@:3}"; }

# 1. Budget exhaustion degrades, launches, clears model, records the complete
# event, and tells commander.
fresh
T1=$(add budget p14-src --model gpt-old)
fleet run --ready >/dev/null
P1=$(sql "select payload from event where task_id=$T1 and kind='task.degraded'")
M1=$(sql "select body from message where to_agent='commander' and topic='degraded'")
if [ "$(field "$T1" status)" = running ] && [ "$(field "$T1" channel)" = p14-claude ] \
 && [ -z "$(sql "select model from task where id=$T1")" ] \
 && printf '%s' "$P1" | jq -e '.from=="p14-src" and .to=="p14-claude" and .reason=="budget" and has("model_before") and .family_before=="gpt" and .family_after=="claude"' >/dev/null \
 && printf '%s' "$M1" | grep -q 'p14-src -> p14-claude: budget'; then
  ok "budget fallback launches and records event/message/model reset"
else no "budget fallback (payload=$P1 message=$M1)"; fi

# 2. Per-channel capacity degrades; global capacity never does.
fresh
T2=$(add cap p14-cap)
fleet run --ready >/dev/null
T2G=$(add global p14-src)
fleet run --ready --max-parallel 0 >/dev/null
if [ "$(field "$T2" channel)" = p14-claude ] \
 && [ "$(sql "select count(*) from event where task_id=$T2 and kind='task.degraded' and json_extract(payload,'$.reason')='channel max_parallel'")" = 1 ] \
 && [ "$(field "$T2G" channel)" = p14-src ] \
 && [ "$(sql "select count(*) from event where task_id=$T2G and kind='task.degraded'")" = 0 ]; then
  ok "channel max_parallel degrades; global max_parallel does not"
else no "capacity fallback gates"; fi

# 3. An unmet dependency is checked before channel-local fallback gates.
fresh
D3=$(add dep p14-grok)
T3=$(add child p14-src --dep "$D3")
fleet run --ready --max-parallel 8 >/dev/null
if [ "$(field "$T3" channel)" = p14-src ] \
 && [ "$(sql "select json_extract(payload,'$.reason') from event where task_id=$T3 and kind='task.blocked' order by id desc limit 1")" = dep ]; then
  ok "unmet dependency blocks without degradation"
else no "dependency gate before fallback"; fi

# 4. A reviewer skips a same-family fallback, uses the next; if there is no
# eligible next choice it remains blocked.
fresh
R4=$(add reviewed p14-claude)
T4=$(add reviewer p14-src --review-of "$R4")
fleet run --ready >/dev/null
T4B=$(add reviewer-blocked p14-src --review-of "$R4")
sql "update task set channel='p14-oldnotes' where id=$T4B; update task set family='gpt' where id=$T4B;" >/dev/null
jq '.channels["p14-oldnotes"].fallback=["p14-claude"]' "$FLEET_HOME/channels.json" > "$FLEET_HOME/c" && mv "$FLEET_HOME/c" "$FLEET_HOME/channels.json"
fleet run --ready >/dev/null
if [ "$(field "$T4" channel)" = p14-grok ] && [ "$(field "$T4B" channel)" = p14-oldnotes ] \
 && [ "$(sql "select json_extract(payload,'$.reason') from event where task_id=$T4B and kind='task.blocked' order by id desc limit 1")" = budget ]; then
  ok "reviewer skips same-family fallback, then uses next or stays blocked"
else no "review-of fallback family check"; fi

# 5. The reviewed side also may not move into its live reviewer's family.
fresh
T5=$(add subject p14-src)
R5=$(add reviewer p14-claude --review-of "$T5")
fleet run --ready >/dev/null
if [ "$(field "$T5" channel)" = p14-grok ]; then
  ok "reviewed task skips fallback matching queued/running reviewer family"
else no "reverse review family check (channel=$(field "$T5" channel))"; fi

# 6. Structured re-rendering matches the pre-P14 renderer even when title,
# context, or spec contains the old placeholder literal.  A fallback changes
# only the notes inserted between the stored head and tail.
fresh
BASELINE6=$("$ROOT/tests/p14_prompt_baseline.sh")
T6=$(add prompt p14-oldnotes)
META6="$FLEET_HOME/runs/$T6/meta.json"
EXPECTED6="$FLEET_HOME/expected6"
jq -j '.prompt_base.head' "$META6" >"$EXPECTED6"
printf '%s\n' '--- channel notes ---' '# NEW NOTES' >>"$EXPECTED6"
jq -j '.prompt_base.body // ""' "$META6" >>"$EXPECTED6"
jq -j '.prompt_base.source_notice // ""' "$META6" >>"$EXPECTED6"
jq -j '.prompt_base.tail' "$META6" >>"$EXPECTED6"
fleet run --ready >/dev/null
PROMPT6=$(cat "$FLEET_HOME/runs/$T6/prompt.md")
if [ "$BASELINE6" = "skip: no git baseline" ]; then
  ok "structured prompt baseline (skipped: no git baseline)"
elif printf '%s' "$PROMPT6" | grep -q '# NEW NOTES' \
 && ! printf '%s' "$PROMPT6" | grep -q '# OLD NOTES' \
 && cmp -s "$EXPECTED6" "$FLEET_HOME/runs/$T6/prompt.md" \
 && printf '%s' "$BASELINE6" | grep -q 'title/context/spec literals'; then
  ok "structured prompt matches baseline and fallback changes only notes"
else no "prompt re-render ($PROMPT6)"; fi

# 7. A task with a degraded event cannot follow a second fallback hop.
fleet cancel "$T6" >/dev/null
sql "update task set status='queued',ended_at=null where id=$T6; insert into budget(channel,period,used,quota) values('p14-claude',strftime('%Y-%m','now'),1,0) on conflict(channel,period) do update set used=1,quota=0;" >/dev/null
fleet run --ready >/dev/null
if [ "$(field "$T6" channel)" = p14-claude ] \
 && [ "$(sql "select count(*) from event where task_id=$T6 and kind='task.degraded'")" = 1 ] \
 && [ "$(sql "select json_extract(payload,'$.reason') from event where task_id=$T6 and kind='task.blocked' order by id desc limit 1")" = budget ]; then
  ok "task degrades only once, then remains blocked on its adopted channel"
else no "single degradation guard"; fi

# 8. Placeholder-looking user text is data, never an in-band insertion point.
# Notes occur once after the complete preamble and before context/spec; the
# title literal occurs twice because the preamble deliberately repeats title.
fresh
TITLE8='title has {CHANNEL_NOTES} literal'
printf '%s\n' 'context has {CHANNEL_NOTES} literal' >"$FLEET_HOME/context8.txt"
printf '%s\n' 'spec has {CHANNEL_NOTES} literal' >"$FLEET_HOME/spec8.md"
T8=$(fleet add "$TITLE8" --channel p14-oldnotes --context "$FLEET_HOME/context8.txt" --spec "$FLEET_HOME/spec8.md")
fleet run --ready >/dev/null
PROMPT8="$FLEET_HOME/runs/$T8/prompt.md"
NOTES8=$(grep -nFx -- '--- channel notes ---' "$PROMPT8" | cut -d: -f1)
PREAMBLE_END8=$(grep -nFx -- '---' "$PROMPT8" | head -1 | cut -d: -f1)
CONTEXT8=$(grep -n '^--- context:' "$PROMPT8" | head -1 | cut -d: -f1)
if ! head -1 "$PROMPT8" | grep -q -- '--- channel notes ---' \
 && [ "$(grep -cFx -- '--- channel notes ---' "$PROMPT8")" = 1 ] \
 && grep -qFx -- '# NEW NOTES' "$PROMPT8" \
 && ! grep -qFx -- '# OLD NOTES' "$PROMPT8" \
 && [ "$NOTES8" -gt "$PREAMBLE_END8" ] && [ "$NOTES8" -lt "$CONTEXT8" ] \
 && [ "$(grep -cF -- 'title has {CHANNEL_NOTES} literal' "$PROMPT8")" = 2 ] \
 && [ "$(grep -cF -- 'context has {CHANNEL_NOTES} literal' "$PROMPT8")" = 1 ] \
 && [ "$(grep -cF -- 'spec has {CHANNEL_NOTES} literal' "$PROMPT8")" = 1 ]; then
  ok "prompt notes are structurally spliced; placeholder literals stay data"
else no "structured prompt placement/literal preservation"; fi

# 9. Brief uses event order, including a real same-second block, and suppresses
# an old block after a genuine later start.
fresh
G8=$(fleet goal add brief)
TB=$(add brief-budget p14-none --goal "$G8")
TC=$(add brief-channel p14-cap-none --goal "$G8")
D8=$(add brief-parent p14-grok --goal "$G8")
TD=$(add brief-dep p14-grok --goal "$G8" --dep "$D8")
fleet run --ready --max-parallel 8 >/dev/null
sql "update task set created_at=(select ts from event where task_id=$TB and kind='task.blocked' order by id desc limit 1) where id=$TB;" >/dev/null
B8=$(fleet brief)
DEP8=$(sql "select json_extract(payload,'$.dep') from event where task_id=$TD and kind='task.blocked' order by id desc limit 1")
jq 'del(.channels["p14-none"].quota)' "$FLEET_HOME/channels.json" >"$FLEET_HOME/c" && mv "$FLEET_HOME/c" "$FLEET_HOME/channels.json"
fleet run "$TB" >/dev/null
B8_STARTED=$(fleet brief)
if printf '%s' "$B8" | grep -q "$TB queued(p14-none, blocked: budget)" \
 && printf '%s' "$B8" | grep -q "$TC queued(p14-cap-none, blocked: channel max_parallel)" \
 && printf '%s' "$B8" | grep -q "$TD queued(p14-grok, blocked: dep $DEP8)" \
 && printf '%s' "$B8_STARTED" | grep -q "$TB running(p14-none)" \
 && ! printf '%s' "$B8_STARTED" | grep -q "$TB running(p14-none, blocked:"; then
  ok "brief uses blocked/start event ids, including same-second block"
else no "brief blocked reasons ($B8)"; fi

# 10. A channel without fallback retains the old queued+blocked behavior.
fresh
T9=$(add nofallback p14-none)
fleet run --ready >/dev/null
if [ "$(field "$T9" status)" = queued ] && [ "$(field "$T9" channel)" = p14-none ] \
 && [ "$(sql "select count(*) from event where task_id=$T9 and kind='task.degraded'")" = 0 ] \
 && [ "$(sql "select json_extract(payload,'$.reason') from event where task_id=$T9 and kind='task.blocked' order by id desc limit 1")" = budget ]; then
  ok "channel without fallback remains queued and blocked exactly as before"
else no "no-fallback compatibility"; fi

# 11. A live holder's lease is checked before fallback; once it releases the
# lease, the blocked task may spend its one hop and launch.
fresh
A10=$(add lease-holder p14-grok --lease shared-p14)
fleet run "$A10" >/dev/null
B10=$(add lease-waiter p14-src --lease shared-p14)
fleet run --ready >/dev/null
before10="$(field "$B10" channel):$(sql "select count(*) from event where task_id=$B10 and kind='task.degraded'"):$(sql "select json_extract(payload,'$.reason') from event where task_id=$B10 and kind='task.blocked' order by id desc limit 1")"
fleet cancel "$A10" >/dev/null
fleet run --ready >/dev/null
if [ "$before10" = "p14-src:0:lease" ] \
 && [ "$(field "$B10" channel)" = p14-claude ] \
 && [ "$(field "$B10" status)" = running ]; then
  ok "lease precheck preserves fallback hop until live holder releases"
else no "lease precheck (before=$before10 after=$(field "$B10" channel)/$(field "$B10" status))"; fi

# 12. A spawn failure after degradation follows the existing requeue path and
# never rolls the adopted channel back to the source.
fresh
T11=$(add launch-fail p14-src --max-attempts 2)
set +e
FLEET_LAUNCH_FAIL=1 fleet run --ready >"$FLEET_HOME/fail.out" 2>"$FLEET_HOME/fail.err"
RC11=$?
set -e
if [ "$RC11" != 0 ] && grep -q 'simulated spawn failure' "$FLEET_HOME/fail.err" \
 && [ "$(field "$T11" status)" = queued ] \
 && [ "$(field "$T11" channel)" = p14-claude ] \
 && [ "$(sql "select count(*) from event where task_id=$T11 and kind='task.degraded'")" = 1 ]; then
  ok "post-degrade launch failure requeues without channel rollback"
else no "post-degrade launch failure (rc=$RC11 err=$(cat "$FLEET_HOME/fail.err"))"; fi

# 13. A legacy string prompt_base is visibly blocked instead of being
# re-rendered through the unsafe in-band placeholder protocol.
fresh
T12=$(add legacy-meta p14-src)
jq '.prompt_base=(.prompt_base.head + "{CHANNEL_NOTES}" + .prompt_base.tail)' \
  "$FLEET_HOME/runs/$T12/meta.json" >"$FLEET_HOME/meta.new"
mv "$FLEET_HOME/meta.new" "$FLEET_HOME/runs/$T12/meta.json"
fleet run --ready >/dev/null
if [ "$(field "$T12" channel)" = p14-src ] \
 && [ "$(sql "select json_extract(payload,'$.reason') from event where task_id=$T12 and kind='task.blocked' order by id desc limit 1")" = prompt_base_legacy ] \
 && [ "$(sql "select json_extract(payload,'$.shape.type') from event where task_id=$T12 and kind='task.blocked' order by id desc limit 1")" = str ]; then
  ok "legacy prompt_base skips fallback with visible blocked reason"
else no "legacy prompt_base fallback guard"; fi

# 14. Malformed structured prompt bases are blocked without aborting the ready
# batch.  Cover each key being absent and a present key having the wrong type.
for CASE14 in missing-tail missing-head non-string-head; do
  fresh
  BAD14=$(add "bad-$CASE14" p14-src)
  GOOD14=$(add "good-$CASE14" p14-grok)
  META14="$FLEET_HOME/runs/$BAD14/meta.json"
  case "$CASE14" in
    missing-tail) FILTER14='del(.prompt_base.tail)' ; EXPECT_KEY14=tail ; EXPECT_SHAPE14=missing ;;
    missing-head) FILTER14='del(.prompt_base.head)' ; EXPECT_KEY14=head ; EXPECT_SHAPE14=missing ;;
    non-string-head) FILTER14='.prompt_base.head=17' ; EXPECT_KEY14=head ; EXPECT_SHAPE14=int ;;
  esac
  jq "$FILTER14" "$META14" >"$FLEET_HOME/meta.new"
  mv "$FLEET_HOME/meta.new" "$META14"
  RUN14=0
  fleet run --ready >/dev/null 2>&1 || RUN14=$?
  REASON14=$(sql "select json_extract(payload,'$.reason') from event where task_id=$BAD14 and kind='task.blocked' order by id desc limit 1")
  SHAPE14=$(sql "select json_extract(payload,'$.shape.$EXPECT_KEY14') from event where task_id=$BAD14 and kind='task.blocked' order by id desc limit 1")
  if [ "$RUN14" = 0 ] \
   && [ "$(field "$BAD14" status)" = queued ] \
   && [ "$(field "$BAD14" channel)" = p14-src ] \
   && [ "$REASON14" = prompt_base_legacy ] \
   && [ "$SHAPE14" = "$EXPECT_SHAPE14" ] \
   && [ "$(field "$GOOD14" status)" = running ]; then
    ok "$CASE14 prompt_base blocks only the malformed task"
  else
    no "$CASE14 prompt_base guard (run=$RUN14 reason=$REASON14 shape=$SHAPE14 good=$(field "$GOOD14" status))"
  fi
done

# 15. Project-agnostic scan, excluding historical/data-only directories.
PAT="${FLEET_FORBIDDEN_NAMES:-Acme""Corp|acme""-internal}"
if grep -rIn -E "$PAT" "$ROOT" --exclude-dir=.git --exclude-dir=docs; then
  no "project-agnostic: no concrete project names"
else ok "project-agnostic: no concrete project names"; fi

echo "---"
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = 0 ]
