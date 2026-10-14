#!/usr/bin/env bash
# fleet P6: family belongs to the model, not to the source. Zero model quota
# except where noted: every case here resolves families and gates enqueues,
# which needs no agent to run.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# API environment belongs to the individual adapter fixture, never the process
# launching the suite.
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS

export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p6-test-XXXX)"
trap 'rm -rf "$FLEET_HOME"' EXIT
export PATH="$ROOT/bin:$PATH"

PASS=0
FAIL=0
N=0
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }
field(){ fleet show "$1" | awk -v f="$2" '$1==f":"{print $2}'; }
wait_status(){ local id="$1" want="$2" i; for i in $(seq 1 150); do
  [ "$(field "$id" status)" = "$want" ] && return 0; sleep 0.2; done; return 1; }

fleet init >/dev/null
printf 'echo hi\n' > "$FLEET_HOME/spec_echo.sh"
printf 'exit 0\n'  > "$FLEET_HOME/spec_silent.sh"

# The multi-family and misleading-alias cases own their channel/model fixtures.
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["model_families"] = {
    "gpt-looking-claude": "claude",
    "grok-fixture": "grok",
    "deepseek-fixture": "deepseek",
    **d["model_families"],
}
d["channels"]["multi-fixture"] = {
    "adapter": "shell.sh", "model": "gpt-5.6-sol",
    "models": ["gpt-5.6-sol", "grok-fixture", "gpt-looking-claude"],
}
d["channels"]["no-menu-fixture"] = {
    "adapter": "shell.sh", "model": "gpt-5.6-sol",
}
json.dump(d, open(p, "w"), indent=2)
PY

# 1. with no family on the channel, the default model decides it
a=$(fleet add "grok default"   --channel grok    --spec "$FLEET_HOME/spec_echo.sh")
b=$(fleet add "codex default"  --channel codex   --spec "$FLEET_HOME/spec_echo.sh")
c=$(fleet add "cursor default"  --channel cursor  --spec "$FLEET_HOME/spec_echo.sh")
if [ "$(field "$a" family)" = "grok" ] && [ "$(field "$b" family)" = "gpt" ] \
   && [ "$(field "$c" family)" = "claude" ]; then
  ok "family comes from each source's default model"
else
  no "family comes from each source's default model ($(field "$a" family)/$(field "$b" family)/$(field "$c" family))"
fi
for x in "$a" "$b" "$c"; do fleet cancel "$x" >/dev/null 2>&1; done

# 2. switching the model switches the family, same source
g=$(fleet add "multi on grok" --channel multi-fixture --model grok-fixture \
      --spec "$FLEET_HOME/spec_echo.sh")
[ "$(field "$g" family)" = "grok" ] \
  && ok "switching model switches family within one source" \
  || no "switching model switches family within one source (got $(field "$g" family))"
fleet cancel "$g" >/dev/null 2>&1

# 3. a model the source does not drive is a typo, not a request
fleet add "not on the menu" --channel multi-fixture --model claude-not-offered \
  --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>"$FLEET_HOME/e3"
rc=$?
if [ "$rc" = "5" ] && grep -q "does not offer" "$FLEET_HOME/e3"; then
  ok "model outside the source's menu refused with exit 5"
else
  no "model outside the source's menu refused with exit 5 (rc=$rc)"
fi

# 4. an unclassifiable model is refused, never assumed
fleet add "unclassifiable" --channel no-menu-fixture --model "totally-unknown-xyz" \
  --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>&1
[ "$?" = "3" ] && ok "unclassifiable model refused with exit 3" \
                || no "unclassifiable model refused with exit 3"

# 5. pattern order: a neutral alias whose real base is Claude must not read gpt
o=$(fleet add "alias" --channel multi-fixture --model gpt-looking-claude \
      --spec "$FLEET_HOME/spec_echo.sh")
[ "$(field "$o" family)" = "claude" ] \
  && ok "gpt-looking alias resolves to claude, not gpt" \
  || no "gpt-looking alias resolves to claude, not gpt (got $(field "$o" family))"

# 6. two different CLIs can still be the same family -- that is the whole point
S=$(fleet add "grok work" --channel grok --spec "$FLEET_HOME/spec_echo.sh")
fleet add "grok reviews grok" --channel multi-fixture --model grok-fixture \
  --review-of "$S" --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>&1
rcs=$?
R=$(fleet add "claude reviews grok" --channel cursor --review-of "$S" \
      --spec "$FLEET_HOME/spec_echo.sh" 2>/dev/null)
if [ "$rcs" = "2" ] && [ -n "$R" ]; then
  ok "different CLIs, same base: refused; genuinely different base: allowed"
else
  no "different CLIs, same base: refused; genuinely different base: allowed (rc=$rcs R=$R)"
fi
for x in "$S" "$R" "$o"; do fleet cancel "$x" >/dev/null 2>&1; done

# 7. the API adapter owns routing: the endpoint/key come from its neutral
#    Fleet variables, the main model comes from FLEET_MODEL, and secrets are
#    never printed.
out=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MODEL=vendor/claude-main \
      FLEET_API_BASE_URL=https://api.example.test FLEET_API_KEY=tok_SECRET_MUST_NOT_PRINT \
      FLEET_HOME="$FLEET_HOME" bash "$ROOT/adapters/claude_api.sh" \
      1 "$FLEET_HOME/spec_echo.sh" /var/tmp "$FLEET_HOME/o" "$FLEET_HOME/l" 2>&1)
if echo "$out" | grep -q "ANTHROPIC_BASE_URL=https://api.example.test" \
   && echo "$out" | grep -q "ANTHROPIC_MODEL=vendor/claude-main" \
   && echo "$out" | grep -q "CLAUDE_CODE_SUBAGENT_MODEL=vendor/claude-main" \
   && ! echo "$out" | grep -q "tok_SECRET" \
   && ! echo "$out" | grep -q -- "--model"; then
  ok "API adapter owns endpoint/model routing and keeps token private"
else
  no "API adapter routing (got: $(echo "$out" | head -c 200))"
fi
out=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MODEL=vendor/claude-main \
      FLEET_SUBAGENT_MODEL=vendor/claude-fast \
      FLEET_API_BASE_URL=https://api.example.test FLEET_API_KEY=test-key \
      FLEET_HOME="$FLEET_HOME" bash "$ROOT/adapters/claude_api.sh" \
      1 "$FLEET_HOME/spec_echo.sh" /var/tmp "$FLEET_HOME/o" "$FLEET_HOME/l" 2>&1)
if echo "$out" | grep -q "ANTHROPIC_MODEL=vendor/claude-main" \
   && echo "$out" | grep -q "CLAUDE_CODE_SUBAGENT_MODEL=vendor/claude-fast"; then
  ok "API adapter splits main/subagent models when FLEET_SUBAGENT_MODEL is set"
else
  no "API adapter splits main/subagent models (got: $(echo "$out" | head -c 200))"
fi

# 8. `fleet probe` really probes: upsert, family=none skip, models-vs-model
#    fallback, and "rc=0 but empty output is a fail". The old case INSERTed
#    a model_probe row and SELECTed it back -- zero probe coverage. The fake
#    adapter's absolute path works because ROOT/"adapters"/<abs> resolves to
#    the absolute path; it lives in FLEET_HOME so parallel suites never race.
FAKE="$FLEET_HOME/fake-probe.sh"
cat > "$FAKE" <<'EOS'
#!/usr/bin/env bash
# probe test adapter: behavior branches on FLEET_MODEL
set -u
OUT="$4"
case "${FLEET_MODEL:-}" in
  *silent*) exit 0 ;;            # rc=0, empty stdout -> FAIL
  *logfail*) echo log-detail > "$5"; echo stderr-detail >&2; exit 4 ;;
  *longfail*)
    { printf 'long-head:'; printf '%0300d' 0 | tr 0 x; \
      printf ':tail-diagnostic\n'; } >&2
    exit 5
    ;;
  *fail*)   echo boom >&2; exit 3 ;;
  *)        echo OK > "$OUT"; exit 0 ;;
esac
EOS
chmod +x "$FAKE"
python3 - "$FLEET_HOME/channels.json" "$FAKE" <<'PY'
import json, sys
p, fake = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["channels"]["probe-ok"] = {"adapter": fake, "model": "GPT-probe-ok"}
d["channels"]["probe-multi"] = {"adapter": fake,
                                "models": ["GPT-probe-ok", "GPT-probe-silent",
                                           "GPT-probe-fail", "GPT-probe-logfail",
                                           "GPT-probe-longfail"]}
# family=none WITH a model: the probe skip must cover it too, not just the
# model-less shell channel. Without the skip, the fake adapter would probe
# it and leave a row.
d["channels"]["probe-none"] = {"adapter": fake, "family": "none",
                               "model": "GPT-probe-x"}
json.dump(d, open(p, "w"), indent=2)
PY
p8out=$(fleet probe probe-ok probe-multi probe-none shell 2>&1)
rc8=$?
rows=$(python3 -c "
import sqlite3
print(sqlite3.connect('$FLEET_HOME/fleet.db').execute(
 'SELECT channel, model, ok, note FROM model_probe ORDER BY channel, model'
 ).fetchall())")
long_note=$(python3 -c "
import sqlite3
print(sqlite3.connect('$FLEET_HOME/fleet.db').execute(
 \"SELECT note FROM model_probe WHERE channel='probe-multi' AND model='GPT-probe-longfail'\"
 ).fetchone()[0])")
if [ "$rc8" = "0" ] \
   && printf '%s\n' "$p8out" | grep -q '^probe-ok GPT-probe-ok ok ' \
   && printf '%s\n' "$p8out" | grep -q '^probe-multi GPT-probe-ok ok ' \
   && printf '%s\n' "$p8out" | grep -q '^probe-multi GPT-probe-silent FAIL exit 0 but empty output' \
   && printf '%s\n' "$p8out" | grep -q '^probe-multi GPT-probe-fail FAIL exit 3: boom$' \
   && printf '%s\n' "$p8out" | grep -q '^probe-multi GPT-probe-logfail FAIL exit 4: stderr-detail$' \
   && printf '%s\n' "$p8out" | grep -q '^probe-multi GPT-probe-longfail FAIL exit 5: long-head:' \
   && printf '%s\n' "$p8out" | grep -q ':tail-diagnostic$' \
   && [ "${#long_note}" = 248 ] \
   && ! printf '%s\n' "$p8out" | grep -q '^shell ' \
   && ! printf '%s\n' "$p8out" | grep -q '^probe-none ' \
   && printf '%s\n' "$rows" | grep -q "probe-ok.*GPT-probe-ok.*1" \
   && printf '%s\n' "$rows" | grep -q "probe-silent.*0.*exit 0 but empty output" \
   && printf '%s\n' "$rows" | grep -q "probe-fail.*0.*exit 3: boom" \
   && printf '%s\n' "$rows" | grep -q "probe-logfail.*0.*exit 4: stderr-detail" \
   && printf '%s\n' "$rows" | grep -q "probe-longfail.*0.*tail-diagnostic" \
   && ! printf '%s\n' "$rows" | grep -q "'shell'" \
   && ! printf '%s\n' "$rows" | grep -q "probe-none"; then
  ok "probe: real run, bounded head+tail stderr reason, family=none skipped, empty-output=FAIL"
else
  no "probe: real run (rc=$rc8 out=$p8out rows=$rows)"
fi

# 8b. upsert: a second probe UPDATES the same row (checked_at advances)
#     instead of duplicating it or leaving the stale row in place. An
#     INSERT OR IGNORE would pass the no-duplicate check but never update.
ca8b=$(python3 -c "
import sqlite3;print(sqlite3.connect('$FLEET_HOME/fleet.db').execute(
 \"SELECT checked_at FROM model_probe WHERE channel='probe-ok' AND model='GPT-probe-ok'\"
 ).fetchone()[0])")
sleep 1
fleet probe probe-ok >/dev/null 2>&1
n8b=$(python3 -c "
import sqlite3;print(sqlite3.connect('$FLEET_HOME/fleet.db').execute(
 \"SELECT COUNT(*) FROM model_probe WHERE channel='probe-ok' AND model='GPT-probe-ok'\"
 ).fetchone()[0])")
ca8b2=$(python3 -c "
import sqlite3;print(sqlite3.connect('$FLEET_HOME/fleet.db').execute(
 \"SELECT checked_at FROM model_probe WHERE channel='probe-ok' AND model='GPT-probe-ok'\"
 ).fetchone()[0])")
if [ "$n8b" = "1" ] && [ "$ca8b2" -gt "$ca8b" ]; then
  ok "probe: repeat run upserts (row updated, checked_at advanced)"
else
  no "probe: repeat run upserts (rows=$n8b $ca8b->$ca8b2)"
fi

# 9. a model that failed its last probe must not be enqueued by accident
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["channels"]["multi-fixture"]["models"].append("deepseek-fixture")
json.dump(d, open(p, "w"), indent=2)
PY
python3 -c "
import sqlite3, time
c = sqlite3.connect('$FLEET_HOME/fleet.db')
c.execute('INSERT OR REPLACE INTO model_probe(channel,model,ok,checked_at,note) '
          \"VALUES('multi-fixture','deepseek-fixture',0,?,'exit 0 but empty output')\",
          (int(time.time()),))
c.commit()"
fleet add "dead model" --channel multi-fixture --model deepseek-fixture \
  --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>&1
rc9=$?
d9=$(fleet add "dead model anyway" --channel multi-fixture --model deepseek-fixture \
      --skip-probe-check --spec "$FLEET_HOME/spec_echo.sh" 2>/dev/null)
if [ "$rc9" = "6" ] && [ -n "$d9" ]; then
  ok "failed-probe model refused with exit 6; --skip-probe-check overrides"
else
  no "failed-probe model refused with exit 6; --skip-probe-check overrides (rc=$rc9 d=$d9)"
fi
fleet cancel "$d9" >/dev/null 2>&1

# 10. exiting 0 having produced nothing must not look like a delivery
E=$(fleet add "silent success" --channel shell --spec "$FLEET_HOME/spec_silent.sh")
fleet run "$E" >/dev/null
wait_status "$E" done
if fleet status --all | grep -q "^$E .*EMPTY" \
   && fleet since --raw 0 | grep -q "task.empty"; then
  ok "exit 0 with no output is marked EMPTY and recorded"
else
  no "exit 0 with no output is marked EMPTY and recorded"
fi

# 11. a task that did deliver is not marked
F=$(fleet add "real success" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$F" >/dev/null
wait_status "$F" done
fleet status --all | grep "^$F " | grep -q EMPTY \
  && no "a delivering task is not marked EMPTY" \
  || ok "a delivering task is not marked EMPTY"

# 12. per-channel concurrency cap, independent of the global one
python3 - "$FLEET_HOME/channels.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["max_parallel"] = 16
d["channels"]["shell"]["max_parallel"] = 2
json.dump(d, open(p, "w"), indent=2)
PY
printf 'sleep 10\n' > "$FLEET_HOME/spec_sleep.sh"
for i in 1 2 3 4; do
  fleet add "cap $i" --channel shell --spec "$FLEET_HOME/spec_sleep.sh" >/dev/null
done
fleet run --ready >/dev/null
r=$(fleet status --all | grep -c " running ")
[ "$r" = "2" ] && ok "per-channel cap holds under a larger global cap" \
                || no "per-channel cap holds under a larger global cap (running=$r)"
fleet status --all | awk '$2=="running"||$2=="queued"{print $1}' \
  | while read -r i; do fleet cancel "$i" >/dev/null 2>&1; done

# 13. project-agnostic
PAT="${FLEET_FORBIDDEN_NAMES:-Acme""Corp|acme""-internal}"
if grep -rIn -E "$PAT" "$ROOT" --exclude-dir=.git --exclude-dir=docs; then
  no "project-agnostic: no concrete project names"
else
  ok "project-agnostic: no concrete project names"
fi

echo "---"
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = "0" ]
