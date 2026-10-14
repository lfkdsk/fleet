#!/usr/bin/env bash
# fleet grok channel: adapter argv + repo-scoped MCP wiring + family.
# Every case is an adapter dryrun or an enqueue-only check -- zero model quota,
# nothing is ever run.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-grok-test-XXXX)"
export PATH="$ROOT/bin:$PATH"

PASS=0
FAIL=0
N=0
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }

fleet init >/dev/null

WT="$FLEET_HOME/worktrees/task-99"
NOWT="$FLEET_HOME/notawt"
mkdir -p "$WT" "$NOWT"
printf 'prompt body\n' > "$FLEET_HOME/spec.md"
export FLEET_MCP_JSON="$(python3 - <<PY
import json
print(json.dumps({"mcpServers": {"fleet": {
    "command": "$ROOT/bin/fleet-mcp", "args": [],
    "env": {"FLEET_HOME": "$FLEET_HOME", "FLEET_TASK_ID": "99"}}}}))
PY
)"

# 1. The prompt reaches grok by path, not argv. grok's -p takes the prompt as
#    an argument, so a big spec would hit MAX_ARG_STRLEN the way cursor's old
#    `-p "$(cat ...)"` form did -- and with $OUT already truncated by the
#    shell's redirect, that failure reads as "success with no output".
d1=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MODEL=grok-4.6 FLEET_EFFORT=xhigh \
     bash "$ROOT/adapters/grok.sh" 99 "$FLEET_HOME/spec.md" "$WT" \
       /dev/null /dev/null 2>/dev/null)
if printf '%s\n' "$d1" | grep -q '^DRYRUN: grok ' \
   && printf '%s\n' "$d1" | grep -q -- "--prompt-file $FLEET_HOME/spec.md" \
   && ! printf '%s\n' "$d1" | grep -q -- '-p '; then
  ok "grok dryrun passes the spec by --prompt-file, never as an argv prompt"
else
  no "grok dryrun --prompt-file (dryrun='$d1')"
fi

# 2. --verbatim: a spec routinely contains @paths and lines starting with '/',
#    which grok would otherwise read as prompt syntax rather than as text.
if printf '%s\n' "$d1" | grep -q -- '--verbatim'; then
  ok "grok dryrun passes --verbatim so the spec is not re-interpreted"
else
  no "grok dryrun --verbatim (dryrun='$d1')"
fi

# 3. Model and effort are injected only from the channel's values.
if printf '%s\n' "$d1" | grep -q -- '-m grok-4.6' \
   && printf '%s\n' "$d1" | grep -q -- '--reasoning-effort xhigh'; then
  ok "grok dryrun injects FLEET_MODEL and FLEET_EFFORT"
else
  no "grok dryrun model/effort (dryrun='$d1')"
fi

# 4. An unset effort must not render an empty flag: grok rejects an unknown
#    level outright (it takes low/medium/high/xhigh and errors on anything
#    else), so an empty string would fail the whole task, not degrade.
d4=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MODEL=grok-4.6 FLEET_EFFORT= \
     bash "$ROOT/adapters/grok.sh" 99 "$FLEET_HOME/spec.md" "$WT" \
       /dev/null /dev/null 2>/dev/null)
if ! printf '%s\n' "$d4" | grep -q -- '--reasoning-effort'; then
  ok "grok dryrun omits --reasoning-effort when the channel sets none"
else
  no "grok dryrun empty effort (dryrun='$d4')"
fi

# 5. MCP: grok has no per-invocation MCP flag, so the per-task server goes into
#    a config.toml -- but into one the task owns, under its run dir, which grok
#    reads because $GROK_HOME is relocated to it. Writing it into the worktree
#    (the old form) left an untracked .grok/ that pinned the worktree forever;
#    see tests/p16_smoke.sh.
if [ ! -e "$WT/.grok" ] \
   && python3 - "$FLEET_HOME/runs/99/grok-home/config.toml" "$ROOT/bin/fleet-mcp" <<'PY'
import sys, tomllib
cfg = tomllib.load(open(sys.argv[1], "rb"))
srv = cfg["mcp_servers"]["fleet"]
assert srv["command"] == sys.argv[2], srv
assert srv["env"]["FLEET_TASK_ID"] == "99", srv
PY
then
  ok "the run dir's config.toml is valid TOML with the fleet server and FLEET_TASK_ID"
else
  no "the run dir's config.toml is valid TOML with the fleet server and FLEET_TASK_ID"
fi

# 6. A task whose cwd is not a fleet worktree gets MCP like any other one now:
#    the config no longer needs a worktree to live in, so the old "no worktree,
#    no ledger" degradation is gone -- and its cwd is still not written to.
d6=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MODEL=grok-4.6 \
     bash "$ROOT/adapters/grok.sh" 100 "$FLEET_HOME/spec.md" "$NOWT" \
       /dev/null /dev/null 2>/dev/null)
if [ -z "$(ls -A "$NOWT")" ] \
   && [ -f "$FLEET_HOME/runs/100/grok-home/config.toml" ] \
   && printf '%s\n' "$d6" | grep -q '^DRYRUN: grok '; then
  ok "a task outside a fleet worktree still gets MCP and still writes nothing into its cwd"
else
  no "a task outside a fleet worktree still gets MCP and writes nothing into its cwd ($(ls -A "$NOWT" | tr '\n' ' '))"
fi

# 7. A checked-out repo may ship its own .grok/config.toml. The adapter used to
#    append to it -- correct as far as it went, but the appended block was
#    still residue in the task's diff. Now it is left alone entirely.
WT2="$FLEET_HOME/worktrees/task-98"
mkdir -p "$WT2/.grok"
printf '[permission]\ndefaultMode = "default"\n' > "$WT2/.grok/config.toml"
before7=$(sha256sum "$WT2/.grok/config.toml" | cut -d' ' -f1)
FLEET_ADAPTER_DRYRUN=1 FLEET_MODEL=grok-4.6 \
  bash "$ROOT/adapters/grok.sh" 98 "$FLEET_HOME/spec.md" "$WT2" \
    /dev/null /dev/null >/dev/null 2>&1
after7=$(sha256sum "$WT2/.grok/config.toml" | cut -d' ' -f1)
if [ "$before7" = "$after7" ] \
   && [ -f "$FLEET_HOME/runs/98/grok-home/config.toml" ]; then
  ok "a repo's own .grok/config.toml is left byte-identical, fleet's goes elsewhere"
else
  no "a repo's own .grok/config.toml is left byte-identical, fleet's goes elsewhere"
fi

# 8. A retried task re-enters the adapter with the same run dir. Appending a
#    second [mcp_servers.fleet] is not "last one wins" but a TOML parse error,
#    so the retry would run with no ledger at all -- found by case 5 of this
#    suite when the first three dryruns shared one config file.
for _ in 1 2; do
  FLEET_ADAPTER_DRYRUN=1 FLEET_MODEL=grok-4.6 \
    bash "$ROOT/adapters/grok.sh" 98 "$FLEET_HOME/spec.md" "$WT2" \
      /dev/null /dev/null >/dev/null 2>&1
done
CFG98="$FLEET_HOME/runs/98/grok-home/config.toml"
if [ "$(grep -c '^\[mcp_servers.fleet\]' "$CFG98")" = "1" ] \
   && python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$CFG98"; then
  ok "re-running the adapter on one task rewrites the config, never doubles it"
else
  no "re-running the adapter on one task rewrites the config, never doubles it"
fi

# 9. The adapter must not reach outside its run dir. It once wrote into the
#    worktree and was nearly taught to hide that with an ignore rule: git reads
#    info/exclude only from the common git dir, so the rule would have landed in
#    the user's own repository and hidden a real .grok/config.toml in their main
#    checkout (measured on git 2.43). Nothing is written into either now.
REPO="$FLEET_HOME/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'x\n' > "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
WT3="$FLEET_HOME/worktrees/task-97"
git -C "$REPO" worktree add -q "$WT3" -b wtb
before=$(cat "$REPO/.git/info/exclude" 2>/dev/null || true)
FLEET_ADAPTER_DRYRUN=1 FLEET_MODEL=grok-4.6 \
  bash "$ROOT/adapters/grok.sh" 97 "$FLEET_HOME/spec.md" "$WT3" \
    /dev/null /dev/null >/dev/null 2>&1
after=$(cat "$REPO/.git/info/exclude" 2>/dev/null || true)
if [ -f "$FLEET_HOME/runs/97/grok-home/config.toml" ] && [ "$before" = "$after" ] \
   && [ -z "$(git -C "$WT3" status --porcelain -uall)" ] \
   && [ -z "$(git -C "$REPO" status --porcelain)" ]; then
  ok "the adapter writes only inside its run dir, never into the worktree or the repo"
else
  no "the adapter writes only inside its run dir, never into the worktree or the repo"
fi

# 10. Isolation from the other harnesses. grok scans ~/.claude.json and the
#     cursor configs by default, so without this a fleet task inherits the
#     operator's MCP servers (cursor/codex) and Stop hook: a "grok"
#     reviewer that can call cursor__cursor_run is not a cross-family reviewer
#     at all, and what it spends there is off fleet's books. Asserted against a
#     stub `grok` on PATH -- a real launch, not a dryrun, so it also pins that
#     the adapter really execs with the argv case 1-4 describe.
STUB="$FLEET_HOME/stubbin"
mkdir -p "$STUB"
cat > "$STUB/grok" <<'STUBEOF'
#!/usr/bin/env bash
env | grep '^GROK_' | sort
echo "ARGV: $*"
STUBEOF
chmod +x "$STUB/grok"
o10="$FLEET_HOME/out10.txt"
PATH="$STUB:$PATH" FLEET_MODEL=grok-4.6 \
  bash "$ROOT/adapters/grok.sh" 99 "$FLEET_HOME/spec.md" "$WT" \
    "$o10" /dev/null 2>/dev/null
if grep -q "^GROK_HOME=$FLEET_HOME/runs/99/grok-home$" "$o10" \
   && grep -q '^GROK_CLAUDE_MCPS_ENABLED=0$' "$o10" \
   && grep -q '^GROK_CURSOR_MCPS_ENABLED=0$' "$o10" \
   && grep -q '^GROK_CLAUDE_HOOKS_ENABLED=0$' "$o10" \
   && grep -q '^GROK_FOLDER_TRUST=0$' "$o10" \
   && grep -q 'ARGV: .*--prompt-file' "$o10"; then
  ok "a launched task is cut off from the other harnesses' MCP servers and hooks"
else
  no "a launched task is cut off from the other harnesses' MCP servers and hooks ($(cat "$o10"))"
fi

# 11. Family. grok is its own family, which is the whole point of the channel:
#    it makes a real heterogeneous reviewer for claude/gpt/seed work. If
#    grok-4.6 ever fell through model_families the enqueue would die instead.
fam=$(fleet --json channels | python3 -c \
  'import json,sys; print(next(c["family"] for c in json.load(sys.stdin) if c["name"]=="grok"))')
if [ "$fam" = "grok" ]; then
  ok "the grok channel resolves to family 'grok'"
else
  no "the grok channel resolves to family 'grok' (got '$fam')"
fi

# 12. The cross-family guard sees that family: a grok task may review a claude
#    one, and may not review another grok one.
printf 'body\n' > "$FLEET_HOME/s.md"
B=$(fleet add "base claude" --channel cursor --spec "$FLEET_HOME/s.md" \
      --cwd "$FLEET_HOME" --skip-probe-check 2>/dev/null)
G=$(fleet add "base grok" --channel grok --spec "$FLEET_HOME/s.md" \
      --cwd "$FLEET_HOME" --skip-probe-check 2>/dev/null)
fleet add "review of claude" --channel grok --review-of "$B" \
  --spec "$FLEET_HOME/s.md" --cwd "$FLEET_HOME" --skip-probe-check \
  >/dev/null 2>&1
rc_cross=$?
fleet add "review of grok" --channel grok --review-of "$G" \
  --spec "$FLEET_HOME/s.md" --cwd "$FLEET_HOME" --skip-probe-check \
  >/dev/null 2>&1
rc_same=$?
if [ "$rc_cross" = "0" ] && [ "$rc_same" = "2" ]; then
  ok "grok may review a claude task, and is refused as a reviewer of a grok one"
else
  no "grok cross-family guard (cross rc=$rc_cross, same rc=$rc_same)"
fi

echo "passed $PASS / $N"
[ "$FAIL" = "0" ] || exit 1
