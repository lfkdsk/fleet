#!/usr/bin/env bash
# P16: cursor.sh and grok.sh keep their per-task MCP config out of the task's
# workspace (and out of the operator's home).
#
# The bug this suite pins: both adapters used to write their MCP config into
# the task's cwd -- <cwd>/.cursor/mcp.json and <cwd>/.grok/config.toml. An
# untracked file makes the worktree dirty, `fleet worktree prune --merged-only`
# reads a dirty worktree as unmerged, and so every cursor/grok task's worktree
# became unreclaimable. The same guard ("only write inside $FLEET_HOME/
# worktrees/*") let a reviewer pointed at the *reviewed* task's worktree drop
# its residue into someone else's diff.
#
# Both configs now live under the task's run dir ($FLEET_HOME/runs/<id>/):
# cursor loads it with --plugin-dir, grok by way of a per-task $GROK_HOME.
# Cases 1-8 and 12-14 are dryruns or file assertions and cost zero model quota.
# Cases 9-11 launch the real CLIs (case 10 spends one small grok turn), because
# "we stopped writing the config" is worthless if the agent lost its ledger.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p16-test-XXXX)"
export PATH="$ROOT/bin:$PATH"
trap 'rm -rf "$FLEET_HOME"' EXIT

PASS=0
FAIL=0
N=0
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }

fleet init >/dev/null

# A real git worktree, so "did the adapter dirty the workspace" is answered by
# git itself rather than by a hand-written list of filenames that rots as the
# CLIs change.
REPO="$FLEET_HOME/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'base\n' > "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
wt(){ # wt <task-id> -> path of a fresh worktree for that task
  local id="$1" p="$FLEET_HOME/worktrees/task-$1"
  git -C "$REPO" worktree add -q "$p" -b "fleet/task-$id"
  echo "$p"
}
mcp_json(){ # mcp_json <task-id>
  python3 -c 'import json,sys
print(json.dumps({"mcpServers": {"fleet": {
    "command": sys.argv[1], "args": [],
    "env": {"FLEET_HOME": sys.argv[2], "FLEET_TASK_ID": sys.argv[3]}}}}))' \
    "$ROOT/bin/fleet-mcp" "$FLEET_HOME" "$1"
}

printf 'print the word READY and stop\n' > "$FLEET_HOME/spec.md"

# ---------------------------------------------------------------------------
# 1-4. A dryrun writes nothing into the task's cwd, and the config it does
# write lands in the task's run dir.
# ---------------------------------------------------------------------------
W1="$(wt 101)"
FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 101)" \
  bash "$ROOT/adapters/cursor.sh" 101 "$FLEET_HOME/spec.md" "$W1" \
    /dev/null /dev/null > "$FLEET_HOME/d1.txt" 2>&1
if [ -z "$(git -C "$W1" status --porcelain -uall)" ] && [ ! -e "$W1/.cursor" ]; then
  ok "cursor dryrun leaves the task's worktree byte-for-byte clean"
else
  no "cursor dryrun leaves the task's worktree clean ($(git -C "$W1" status --porcelain -uall | tr '\n' ' '))"
fi

json_ok=1
python3 - "$FLEET_HOME/runs/101/cursor-plugin/.mcp.json" "$ROOT/bin/fleet-mcp" <<'PY' || json_ok=0
import json, sys
d = json.load(open(sys.argv[1]))
srv = d["mcpServers"]["fleet"]
assert srv["command"] == sys.argv[2], srv
assert srv["env"]["FLEET_TASK_ID"] == "101", srv
PY
if [ "$json_ok" = 1 ] \
   && [ -f "$FLEET_HOME/runs/101/cursor-plugin/.cursor-plugin/plugin.json" ] \
   && grep -q -- "--plugin-dir $FLEET_HOME/runs/101/cursor-plugin" "$FLEET_HOME/d1.txt" \
   && grep -q -- "--approve-mcps" "$FLEET_HOME/d1.txt"; then
  ok "cursor's MCP config is a plugin in the run dir, passed by --plugin-dir"
else
  no "cursor's MCP config is a plugin in the run dir ($(cat "$FLEET_HOME/d1.txt"))"
fi

W2="$(wt 102)"
FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 102)" \
  bash "$ROOT/adapters/grok.sh" 102 "$FLEET_HOME/spec.md" "$W2" \
    /dev/null /dev/null > "$FLEET_HOME/d2.txt" 2>&1
if [ -z "$(git -C "$W2" status --porcelain -uall)" ] && [ ! -e "$W2/.grok" ]; then
  ok "grok dryrun leaves the task's worktree byte-for-byte clean"
else
  no "grok dryrun leaves the task's worktree clean ($(git -C "$W2" status --porcelain -uall | tr '\n' ' '))"
fi

if python3 - "$FLEET_HOME/runs/102/grok-home/config.toml" "$ROOT/bin/fleet-mcp" <<'PY'
import sys, tomllib
cfg = tomllib.load(open(sys.argv[1], "rb"))
srv = cfg["mcp_servers"]["fleet"]
assert srv["command"] == sys.argv[2], srv
assert srv["env"]["FLEET_TASK_ID"] == "102", srv
PY
then
  ok "grok's MCP config is a config.toml in the run dir's own GROK_HOME"
else
  no "grok's MCP config is a config.toml in the run dir's own GROK_HOME"
fi

# ---------------------------------------------------------------------------
# 5. Concurrency. A per-task path is the whole reason this is safe: the two
# global files the CLIs read (~/.cursor/mcp.json, ~/.grok/config.toml) are one
# file for the whole box, so two tasks launching at once would leave both
# agents pinned to whichever FLEET_TASK_ID was written last -- and every claim
# from the loser would land on the other task's row. Both adapters are started
# in parallel here, not one after the other, so a shared path would race.
# ---------------------------------------------------------------------------
W3="$(wt 201)"
W4="$(wt 202)"
FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 201)" \
  bash "$ROOT/adapters/cursor.sh" 201 "$FLEET_HOME/spec.md" "$W3" \
    /dev/null /dev/null >/dev/null 2>&1 &
p1=$!
FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 202)" \
  bash "$ROOT/adapters/cursor.sh" 202 "$FLEET_HOME/spec.md" "$W4" \
    /dev/null /dev/null >/dev/null 2>&1 &
p2=$!
FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 201)" \
  bash "$ROOT/adapters/grok.sh" 201 "$FLEET_HOME/spec.md" "$W3" \
    /dev/null /dev/null >/dev/null 2>&1 &
p3=$!
FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 202)" \
  bash "$ROOT/adapters/grok.sh" 202 "$FLEET_HOME/spec.md" "$W4" \
    /dev/null /dev/null >/dev/null 2>&1 &
p4=$!
wait $p1 $p2 $p3 $p4
if python3 - "$FLEET_HOME" <<'PY'
import json, sys, tomllib
home = sys.argv[1]
for tid in ("201", "202"):
    d = json.load(open(f"{home}/runs/{tid}/cursor-plugin/.mcp.json"))
    assert d["mcpServers"]["fleet"]["env"]["FLEET_TASK_ID"] == tid, (tid, d)
    c = tomllib.load(open(f"{home}/runs/{tid}/grok-home/config.toml", "rb"))
    assert c["mcp_servers"]["fleet"]["env"]["FLEET_TASK_ID"] == tid, (tid, c)
PY
then
  ok "two tasks launching at once each read their own FLEET_TASK_ID"
else
  no "two tasks launching at once each read their own FLEET_TASK_ID"
fi

# ---------------------------------------------------------------------------
# 6. The reviewer case, which is how the residue spread furthest: a
# cross-family reviewer is enqueued with --cwd pointing at the *reviewed*
# task's worktree and no --worktree of its own. The old guard only asked
# whether the cwd was under $FLEET_HOME/worktrees/, which that cwd is, so the
# reviewer wrote its own MCP config into the worktree it was supposed to be
# reading -- and the task under review then owned the dirt.
# ---------------------------------------------------------------------------
FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 301)" \
  bash "$ROOT/adapters/cursor.sh" 301 "$FLEET_HOME/spec.md" "$W1" \
    /dev/null /dev/null >/dev/null 2>&1
FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 302)" \
  bash "$ROOT/adapters/grok.sh" 302 "$FLEET_HOME/spec.md" "$W1" \
    /dev/null /dev/null >/dev/null 2>&1
if [ -z "$(git -C "$W1" status --porcelain -uall)" ] \
   && [ -f "$FLEET_HOME/runs/301/cursor-plugin/.mcp.json" ] \
   && [ -f "$FLEET_HOME/runs/302/grok-home/config.toml" ]; then
  ok "a reviewer whose --cwd is another task's worktree writes nothing into it"
else
  no "a reviewer whose --cwd is another task's worktree writes nothing into it ($(git -C "$W1" status --porcelain -uall | tr '\n' ' '))"
fi

# ---------------------------------------------------------------------------
# 7-8. Degradation stays loud. Moving the config out of the workspace removed
# the old reason a task could end up with no MCP (no --worktree), but not the
# principle: an agent that silently cannot file a claim is how a
# fake-successful task gets through. A run dir that cannot be
# written is the remaining way to lose it, forced here by putting a plain file
# where the run dir would go.
# ---------------------------------------------------------------------------
mkdir -p "$FLEET_HOME/runs"
printf 'not a directory\n' > "$FLEET_HOME/runs/401"
e7=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 401)" \
     bash "$ROOT/adapters/cursor.sh" 401 "$FLEET_HOME/spec.md" "$W1" \
       /dev/null /dev/null 2>&1 >"$FLEET_HOME/d7.txt")
if printf '%s\n' "$e7" | grep -q 'no MCP configured' \
   && ! grep -q -- '--plugin-dir' "$FLEET_HOME/d7.txt"; then
  ok "cursor warns loudly when the run dir cannot hold its MCP config"
else
  no "cursor warns loudly when the run dir cannot hold its MCP config (stderr='$e7')"
fi

printf 'not a directory\n' > "$FLEET_HOME/runs/402"
e8=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 402)" \
     bash "$ROOT/adapters/grok.sh" 402 "$FLEET_HOME/spec.md" "$W1" \
       /dev/null /dev/null 2>&1 >/dev/null)
if printf '%s\n' "$e8" | grep -q 'no MCP configured'; then
  ok "grok warns loudly when the run dir cannot hold its MCP config"
else
  no "grok warns loudly when the run dir cannot hold its MCP config (stderr='$e8')"
fi

# ---------------------------------------------------------------------------
# 9-11. The real CLIs. Not writing the config is only half the job: if the
# agent can no longer reach fleet-mcp, every task goes mute and the ledger
# stops recording -- so these cases launch the actual binaries.
# ---------------------------------------------------------------------------
CUR_HOME_MCP_BEFORE="none"
[ -f "$HOME/.cursor/mcp.json" ] && CUR_HOME_MCP_BEFORE="$(sha256sum "$HOME/.cursor/mcp.json" | cut -d' ' -f1)"
GROK_HOME_CFG_BEFORE="none"
[ -f "$HOME/.grok/config.toml" ] && GROK_HOME_CFG_BEFORE="$(sha256sum "$HOME/.grok/config.toml" | cut -d' ' -f1)"

# 9. cursor. The server the plugin declares is a recorder that tees the
# JSON-RPC it receives before handing it to the real fleet-mcp, so the case
# asserts cursor-agent actually found the plugin in the run dir, launched the
# server and completed the MCP handshake with it. It stops one step short of
# the model calling a tool on purpose: on this box the Cursor account is over
# its org's monthly limit ("ActionRequiredError: You've reached your monthly
# usage limit"), so every cursor model turn fails before any tool is chosen.
# The handshake is upstream of the model and runs anyway, which is why this is
# the part worth pinning; grok's case below does drive a real tool call.
REC="$FLEET_HOME/rec-mcp.sh"
cat > "$REC" <<REC_EOF
#!/usr/bin/env bash
tee -a "$FLEET_HOME/mcp-in.log" | "$ROOT/bin/fleet-mcp"
REC_EOF
chmod +x "$REC"
W9="$(wt 501)"
REC_MCP=$(python3 -c 'import json,sys
print(json.dumps({"mcpServers": {"fleet": {
    "command": sys.argv[1], "args": [],
    "env": {"FLEET_HOME": sys.argv[2], "FLEET_TASK_ID": "501"}}}}))' \
  "$REC" "$FLEET_HOME")
if ! command -v cursor-agent >/dev/null 2>&1; then
  no "cursor-agent really loads the fleet server out of the run dir (cursor-agent not installed)"
else
  FLEET_MCP_JSON="$REC_MCP" timeout 300 \
    bash "$ROOT/adapters/cursor.sh" 501 "$FLEET_HOME/spec.md" "$W9" \
      "$FLEET_HOME/out9.txt" "$FLEET_HOME/log9.txt" >/dev/null 2>&1
  if grep -q '"method":"initialize"' "$FLEET_HOME/mcp-in.log" 2>/dev/null \
     && grep -q '"name":"Cursor"' "$FLEET_HOME/mcp-in.log" 2>/dev/null \
     && [ -z "$(git -C "$W9" status --porcelain -uall)" ]; then
    ok "cursor-agent really loads the fleet server out of the run dir, workspace still clean"
  else
    no "cursor-agent really loads the fleet server out of the run dir ($(cat "$FLEET_HOME/mcp-in.log" 2>/dev/null | head -c 200); wt=$(git -C "$W9" status --porcelain -uall | tr '\n' ' '))"
  fi
fi

# 10. grok, end to end: a real task row, a real launch, and the agent has to
# come back with the title only fleet_task_get could have told it.
TG=$(fleet add "p16-grok-ledger-marker" --channel shell --no-preamble)
W10="$(wt "$TG")"
printf 'Call the MCP tool fleet_task_get with no arguments, then print the value of the task title field, verbatim, and nothing else. If you have no fleet tools, print NO-MCP.\n' \
  > "$FLEET_HOME/spec10.md"
if ! command -v grok >/dev/null 2>&1; then
  no "a grok task calls fleet_task_get through the relocated GROK_HOME (grok not installed)"
else
  FLEET_MCP_JSON="$(mcp_json "$TG")" FLEET_MODEL=grok-4.6 timeout 300 \
    bash "$ROOT/adapters/grok.sh" "$TG" "$FLEET_HOME/spec10.md" "$W10" \
      "$FLEET_HOME/out10.txt" "$FLEET_HOME/log10.txt" >/dev/null 2>&1
  if grep -q 'p16-grok-ledger-marker' "$FLEET_HOME/out10.txt" 2>/dev/null \
     && [ -z "$(git -C "$W10" status --porcelain -uall)" ]; then
    ok "a grok task calls fleet_task_get through the relocated GROK_HOME, workspace still clean"
  else
    no "a grok task calls fleet_task_get through the relocated GROK_HOME (out='$(head -c 200 "$FLEET_HOME/out10.txt" 2>/dev/null)'; wt=$(git -C "$W10" status --porcelain -uall | tr '\n' ' '))"
  fi
fi

# 11. The other shared file. ~/.cursor/mcp.json and ~/.grok/config.toml are
# the operator's own; a task that edited them would silently re-point the
# operator's interactive CLI at a dead ledger.
CUR_HOME_MCP_AFTER="none"
[ -f "$HOME/.cursor/mcp.json" ] && CUR_HOME_MCP_AFTER="$(sha256sum "$HOME/.cursor/mcp.json" | cut -d' ' -f1)"
GROK_HOME_CFG_AFTER="none"
[ -f "$HOME/.grok/config.toml" ] && GROK_HOME_CFG_AFTER="$(sha256sum "$HOME/.grok/config.toml" | cut -d' ' -f1)"
if [ "$CUR_HOME_MCP_BEFORE" = "$CUR_HOME_MCP_AFTER" ] \
   && [ "$GROK_HOME_CFG_BEFORE" = "$GROK_HOME_CFG_AFTER" ]; then
  ok "two real launches leave the operator's own ~/.cursor and ~/.grok configs untouched"
else
  no "two real launches leave the operator's own configs untouched (cursor $CUR_HOME_MCP_BEFORE->$CUR_HOME_MCP_AFTER, grok $GROK_HOME_CFG_BEFORE->$GROK_HOME_CFG_AFTER)"
fi

# ---------------------------------------------------------------------------
# 12. Retries re-enter the adapter with the same run dir. A second
# [mcp_servers.fleet] is not "last one wins" but a TOML parse error, and the
# attempt would then start with no ledger at all.
# ---------------------------------------------------------------------------
for _ in 1 2 3; do
  FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 601)" \
    bash "$ROOT/adapters/grok.sh" 601 "$FLEET_HOME/spec.md" "$W1" \
      /dev/null /dev/null >/dev/null 2>&1
  FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 601)" \
    bash "$ROOT/adapters/cursor.sh" 601 "$FLEET_HOME/spec.md" "$W1" \
      /dev/null /dev/null >/dev/null 2>&1
done
if [ "$(grep -c '^\[mcp_servers\.fleet\]' "$FLEET_HOME/runs/601/grok-home/config.toml")" = "1" ] \
   && python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' \
        "$FLEET_HOME/runs/601/grok-home/config.toml" \
   && python3 -c 'import sys,json; json.load(open(sys.argv[1]))' \
        "$FLEET_HOME/runs/601/cursor-plugin/.mcp.json"; then
  ok "a retried task rewrites its config in place instead of doubling it"
else
  no "a retried task rewrites its config in place instead of doubling it"
fi

# ---------------------------------------------------------------------------
# 13-14. The relocated GROK_HOME is a symlink farm over the operator's real
# one, which is what keeps the task logged in (a bare GROK_HOME has no
# auth.json) and what keeps the operator's global settings in force. Asserted
# against a fake HOME so the case does not depend on this box's ~/.grok.
# ---------------------------------------------------------------------------
FAKE="$FLEET_HOME/fakehome"
mkdir -p "$FAKE/.grok"
printf '[ui]\np16_marker_setting = "kept"\n' > "$FAKE/.grok/config.toml"
printf 'fake-token\n' > "$FAKE/.grok/auth.json"
printf '["/some/other/worktree"]\n' > "$FAKE/.grok/trusted_folders.toml"
HOME="$FAKE" FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 701)" \
  bash "$ROOT/adapters/grok.sh" 701 "$FLEET_HOME/spec.md" "$W1" \
    /dev/null /dev/null >/dev/null 2>&1
if python3 - "$FLEET_HOME/runs/701/grok-home/config.toml" <<'PY'
import sys, tomllib
cfg = tomllib.load(open(sys.argv[1], "rb"))
assert cfg["ui"]["p16_marker_setting"] == "kept", cfg
assert cfg["mcp_servers"]["fleet"]["env"]["FLEET_TASK_ID"] == "701", cfg
PY
then
  ok "the task's grok config keeps the operator's global settings and adds fleet's"
else
  no "the task's grok config keeps the operator's global settings and adds fleet's"
fi

# The farm links auth.json (without it the task is logged out) but never
# trusted_folders.toml: grok would write a trust row for this throwaway
# worktree straight through the symlink into the operator's real store, which
# is the same residue one directory over.
if [ -L "$FLEET_HOME/runs/701/grok-home/auth.json" ] \
   && [ "$(readlink "$FLEET_HOME/runs/701/grok-home/auth.json")" = "$FAKE/.grok/auth.json" ] \
   && [ ! -e "$FLEET_HOME/runs/701/grok-home/trusted_folders.toml" ]; then
  ok "the farm links the operator's auth but never their folder-trust store"
else
  no "the farm links the operator's auth but never their folder-trust store ($(ls -A "$FLEET_HOME/runs/701/grok-home" | tr '\n' ' '))"
fi

# 15. The operator may have a fleet server of their own in ~/.grok/config.toml
# (one `grok mcp add fleet ...` does it). Copying it in verbatim next to ours
# would declare [mcp_servers.fleet] twice, which is a TOML parse error rather
# than "last one wins" -- every grok task on the box would then start with an
# unreadable config and no ledger.
printf '[cli]\ninstaller = "internal"\n\n[mcp_servers.fleet]\ncommand = "/bin/false"\nargs = []\n\n[mcp_servers.fleet.env]\nFLEET_TASK_ID = "999"\n\n[ui]\np16_marker_setting = "kept"\n' \
  > "$FAKE/.grok/config.toml"
HOME="$FAKE" FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$(mcp_json 702)" \
  bash "$ROOT/adapters/grok.sh" 702 "$FLEET_HOME/spec.md" "$W1" \
    /dev/null /dev/null >/dev/null 2>&1
if python3 - "$FLEET_HOME/runs/702/grok-home/config.toml" "$ROOT/bin/fleet-mcp" <<'PY'
import sys, tomllib
cfg = tomllib.load(open(sys.argv[1], "rb"))
assert cfg["mcp_servers"]["fleet"]["command"] == sys.argv[2], cfg
assert cfg["mcp_servers"]["fleet"]["env"]["FLEET_TASK_ID"] == "702", cfg
assert cfg["ui"]["p16_marker_setting"] == "kept", cfg
PY
then
  ok "an operator's own [mcp_servers.fleet] is replaced, not duplicated into a parse error"
else
  no "an operator's own [mcp_servers.fleet] is replaced, not duplicated into a parse error"
fi

# 16. An adapter whose `cd "$CWD"` fails must not fall through. Every adapter
#     is `set -u`, not `set -eu`, so an unguarded cd only prints to stderr and
#     execution continues -- the tool then reads and writes whatever directory
#     fleet happened to be in, exits 0, and the ledger records a clean run.
#     Driven through the real shell.sh (family=none, zero quota); the
#     model-backed adapters cannot be executed here, so case 17 pins them
#     statically instead.
BADCWD="$FLEET_HOME/no-such-dir"
printf 'echo SHOULD-NOT-RUN\n' > "$FLEET_HOME/cdprobe.sh"
: > "$FLEET_HOME/cd.out"
bash "$ROOT/adapters/shell.sh" 1 "$FLEET_HOME/cdprobe.sh" "$BADCWD" \
  "$FLEET_HOME/cd.out" "$FLEET_HOME/cd.log" >/dev/null 2>&1
rc16=$?
if [ "$rc16" != 0 ] && [ ! -s "$FLEET_HOME/cd.out" ]; then
  ok "an adapter with an unreachable cwd fails instead of running elsewhere"
else
  no "an adapter with an unreachable cwd fails instead of running elsewhere (rc=$rc16 out='$(cat "$FLEET_HOME/cd.out")')"
fi

# 17. The same guard on every adapter that changes directory. A new adapter
#     copied from an old one is exactly how the fall-through would come back,
#     and case 16 can only execute the one adapter that runs no model.
missing17=""
for f in "$ROOT"/adapters/*.sh; do
  grep -q 'cd "$CWD"' "$f" || continue
  grep -qE 'cd "\$CWD" \|\| (exit|die)' "$f" || missing17="$missing17 $(basename "$f")"
done
if [ -z "$missing17" ]; then
  ok "every adapter that cds into the task cwd guards the failure"
else
  no "every adapter that cds into the task cwd guards the failure (unguarded:$missing17)"
fi

# ---------------------------------------------------------------------------
# 18-32. Claude's whole config root is relocatable too. Direct use through
# claude_p.sh retains the user's refreshable credential/config/extension links.
# API use gets a separate Fleet-owned home with configuration links but no user
# credential: its environment token makes subscription OAuth unnecessary, and
# removing that path makes it unable to rotate the user's refresh token. Both
# homes leave session stores out of the user's session chooser.
# ---------------------------------------------------------------------------
CLAUDE_USER_HOME="$FLEET_HOME/claude-user-home"
mkdir -p "$CLAUDE_USER_HOME/.claude/agents" "$CLAUDE_USER_HOME/.claude/hooks" \
  "$CLAUDE_USER_HOME/.claude/plugins" "$CLAUDE_USER_HOME/.claude/projects" \
  "$CLAUDE_USER_HOME/.claude/session-env" "$FLEET_HOME/fake-claude-bin"
printf 'refreshable-credential\n' > "$CLAUDE_USER_HOME/.claude/.credentials.json"
printf '{"permissions":{}}\n' > "$CLAUDE_USER_HOME/.claude/settings.json"
printf 'agent\n' > "$CLAUDE_USER_HOME/.claude/agents/reviewer.md"
printf 'hook\n' > "$CLAUDE_USER_HOME/.claude/hooks/hook.sh"
printf '{}\n' > "$CLAUDE_USER_HOME/.claude/plugins/installed_plugins.json"
printf 'legacy transcript\n' > "$CLAUDE_USER_HOME/.claude/projects/user-session.jsonl"
cat > "$FLEET_HOME/fake-claude-bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${CLAUDE_CONFIG_DIR:-missing}"
SH
chmod +x "$FLEET_HOME/fake-claude-bin/claude"
HOME="$CLAUDE_USER_HOME" PATH="$FLEET_HOME/fake-claude-bin:$PATH" \
  bash "$ROOT/adapters/claude_p.sh" 801 "$FLEET_HOME/spec.md" "$W1" \
    "$FLEET_HOME/claude-p.out" "$FLEET_HOME/claude-p.log"
HOME="$CLAUDE_USER_HOME" PATH="$FLEET_HOME/fake-claude-bin:$PATH" \
  ANTHROPIC_BASE_URL=https://api.example.test ANTHROPIC_AUTH_TOKEN=fake \
  FLEET_MODEL=claude-test bash "$ROOT/adapters/claude_api.sh" 802 \
    "$FLEET_HOME/spec.md" "$W1" "$FLEET_HOME/api.out" "$FLEET_HOME/api.log"
CLAUDE_TASK_HOME="$FLEET_HOME/claude-home"
CLAUDE_API_HOME="$FLEET_HOME/claude-api-home"
links_ok=1
for entry in .credentials.json settings.json agents hooks plugins; do
  [ -L "$CLAUDE_TASK_HOME/$entry" ] || links_ok=0
  [ "$(readlink "$CLAUDE_TASK_HOME/$entry" 2>/dev/null)" = \
    "$CLAUDE_USER_HOME/.claude/$entry" ] || links_ok=0
done
api_links_ok=1
for entry in settings.json agents hooks plugins; do
  [ -L "$CLAUDE_API_HOME/$entry" ] || api_links_ok=0
  [ "$(readlink "$CLAUDE_API_HOME/$entry" 2>/dev/null)" = \
    "$CLAUDE_USER_HOME/.claude/$entry" ] || api_links_ok=0
done
if [ "$links_ok" = 1 ] \
   && [ "$api_links_ok" = 1 ] \
   && [ ! -e "$CLAUDE_API_HOME/.credentials.json" ] \
   && [ ! -L "$CLAUDE_API_HOME/.credentials.json" ] \
   && [ "$(cat "$FLEET_HOME/claude-p.out")" = "$CLAUDE_TASK_HOME" ] \
   && [ "$(cat "$FLEET_HOME/api.out")" = "$CLAUDE_API_HOME" ]; then
  ok "claude-p retains OAuth while API use has a credential-free config home"
else
  no "Claude auth isolation is wrong (oauth=$(find "$CLAUDE_TASK_HOME" -maxdepth 1 -printf '%f:%l ' 2>/dev/null) api=$(find "$CLAUDE_API_HOME" -maxdepth 1 -printf '%f:%l ' 2>/dev/null))"
fi

# Re-entering with already-correct managed symlinks is the normal case. None
# may manufacture a backup when no replacement occurred.
rm -rf "$CLAUDE_TASK_HOME/backups"
HOME="$CLAUDE_USER_HOME" LOG="$FLEET_HOME/managed-stable.log" \
  OUT="$FLEET_HOME/managed-stable.out" FLEET_HOME="$FLEET_HOME" \
  bash -c '. "$1/adapters/claude_config.sh"; fleet_claude_config_init' _ "$ROOT"
stable_rc=$?
stable_links=1
for entry in .credentials.json settings.json agents hooks plugins; do
  [ -L "$CLAUDE_TASK_HOME/$entry" ] || stable_links=0
  [ "$(readlink "$CLAUDE_TASK_HOME/$entry" 2>/dev/null)" = \
    "$CLAUDE_USER_HOME/.claude/$entry" ] || stable_links=0
done
if [ "$stable_rc" = 0 ] && [ "$stable_links" = 1 ] \
   && [ ! -e "$CLAUDE_TASK_HOME/backups" ] \
   && [ ! -s "$FLEET_HOME/managed-stable.log" ]; then
  ok "existing managed Claude symlinks remain unchanged"
else
  no "an existing managed Claude symlink was disturbed (rc=$stable_rc)"
fi

if [ ! -e "$CLAUDE_TASK_HOME/projects" ] \
   && [ ! -e "$CLAUDE_TASK_HOME/session-env" ] \
   && [ ! -e "$CLAUDE_TASK_HOME/history.jsonl" ] \
   && [ ! -e "$CLAUDE_TASK_HOME/cache" ] \
   && [ ! -e "$CLAUDE_API_HOME/projects" ] \
   && [ ! -e "$CLAUDE_API_HOME/session-env" ] \
   && [ ! -e "$CLAUDE_API_HOME/history.jsonl" ] \
   && [ ! -e "$CLAUDE_API_HOME/cache" ]; then
  ok "Claude session/history/cache stores remain isolated from the user home"
else
  no "Claude session stores were linked into the Fleet config home"
fi

# Claude may replace any Fleet-managed link while saving credentials, settings,
# or extensions. Exercise every managed name, including all three directories.
# Each displaced entry must be kept under its own <name>-<epoch> path at 0600,
# while the source in the fake user home stays byte-for-byte authoritative.
managed_repair_ok=1
rm -rf "$CLAUDE_TASK_HOME/backups"
for entry in .credentials.json settings.json agents hooks plugins; do
  target="$CLAUDE_TASK_HOME/$entry"
  source="$CLAUDE_USER_HOME/.claude/$entry"
  repair_log="$FLEET_HOME/managed-repair-${entry#.}.log"
  rm -- "$target"
  case "$entry" in
    .credentials.json|settings.json)
      printf 'fleet-replaced-%s\n' "$entry" > "$target.next"
      mv -Tf -- "$target.next" "$target"
      ;;
    *)
      mkdir "$target"
      printf 'fleet-replaced-%s\n' "$entry" > "$target/replaced.txt"
      ;;
  esac
  : > "$repair_log"
  HOME="$CLAUDE_USER_HOME" LOG="$repair_log" \
    OUT="$FLEET_HOME/managed-repair-${entry#.}.out" \
    FLEET_HOME="$FLEET_HOME" bash -c \
    '. "$1/adapters/claude_config.sh"; fleet_claude_config_init' _ "$ROOT"
  repair_rc=$?
  mapfile -t entry_backups < <(find "$CLAUDE_TASK_HOME/backups" \
    -mindepth 1 -maxdepth 1 -name "$entry-[0-9]*" -print 2>/dev/null)
  backup="${entry_backups[0]:-}"
  [ "$repair_rc" = 0 ] || managed_repair_ok=0
  [ -L "$target" ] || managed_repair_ok=0
  [ "$(readlink "$target" 2>/dev/null)" = "$source" ] || managed_repair_ok=0
  [ "${#entry_backups[@]}" = 1 ] || managed_repair_ok=0
  [ -n "$backup" ] && [ "$(stat -c %a "$backup" 2>/dev/null)" = 600 ] \
    || managed_repair_ok=0
  if [ -n "$backup" ]; then
    case "$entry" in
      .credentials.json|settings.json)
        [ "$(cat "$backup" 2>/dev/null)" = "fleet-replaced-$entry" ] \
          || managed_repair_ok=0
        ;;
      *)
        chmod 700 "$backup" 2>/dev/null || managed_repair_ok=0
        [ "$(cat "$backup/replaced.txt" 2>/dev/null)" = "fleet-replaced-$entry" ] \
          || managed_repair_ok=0
        chmod 600 "$backup" 2>/dev/null || managed_repair_ok=0
        ;;
    esac
  fi
  grep -Fq "managed entry $entry replaced" "$repair_log" \
    || managed_repair_ok=0
  [ -z "$backup" ] || grep -Fq "backup=$backup" "$repair_log" \
    || managed_repair_ok=0
done
managed_backup_count=$(find "$CLAUDE_TASK_HOME/backups" -mindepth 1 \
  -maxdepth 1 -print 2>/dev/null | wc -l)
if [ "$managed_repair_ok" = 1 ] && [ "$managed_backup_count" = 5 ] \
   && [ "$(stat -c %a "$CLAUDE_TASK_HOME/backups")" = 700 ] \
   && [ "$(cat "$CLAUDE_USER_HOME/.claude/.credentials.json")" = \
        refreshable-credential ] \
   && [ "$(cat "$CLAUDE_USER_HOME/.claude/settings.json")" = \
        '{"permissions":{}}' ] \
   && [ "$(cat "$CLAUDE_USER_HOME/.claude/agents/reviewer.md")" = agent ] \
   && [ "$(cat "$CLAUDE_USER_HOME/.claude/hooks/hook.sh")" = hook ] \
   && [ "$(cat "$CLAUDE_USER_HOME/.claude/plugins/installed_plugins.json")" = '{}' ]; then
  ok "all five managed Claude entries self-heal with one mode-600 backup and untouched user sources"
else
  no "managed Claude entry repair failed (ok=$managed_repair_ok backups=$managed_backup_count files='$(find "$CLAUDE_TASK_HOME/backups" -maxdepth 1 -printf '%f:%m ' 2>/dev/null)')"
fi
# Directory backups are deliberately mode 0600. Restore owner traversal only
# after the permission assertion so this isolated fixture can be removed.
find "$CLAUDE_TASK_HOME/backups" -mindepth 1 -maxdepth 1 -type d \
  -exec chmod 700 {} +

# Concurrent adapters share claude-home. A directory lock must serialize the
# repair so every invocation succeeds and exactly one copy of the displaced
# entry survives.
rm -rf "$CLAUDE_TASK_HOME/backups"
printf 'fleet-concurrent-credential\n' > "$CLAUDE_TASK_HOME/.credentials.next"
mv -Tf "$CLAUDE_TASK_HOME/.credentials.next" "$CLAUDE_TASK_HOME/.credentials.json"
concurrent_pids=()
for n in 1 2 3 4; do
  HOME="$CLAUDE_USER_HOME" LOG="$FLEET_HOME/credential-concurrent-$n.log" \
    OUT="$FLEET_HOME/credential-concurrent-$n.out" FLEET_HOME="$FLEET_HOME" \
    bash -c '. "$1/adapters/claude_config.sh"; fleet_claude_config_init' \
      _ "$ROOT" >/dev/null 2>&1 &
  concurrent_pids+=("$!")
done
concurrent_rc=0
for pid in "${concurrent_pids[@]}"; do wait "$pid" || concurrent_rc=1; done
mapfile -t concurrent_backups < <(find "$CLAUDE_TASK_HOME/backups" -maxdepth 1 \
  -type f -name '.credentials.json-[0-9]*' -print 2>/dev/null)
if [ "$concurrent_rc" = 0 ] \
   && [ -L "$CLAUDE_TASK_HOME/.credentials.json" ] \
   && [ "${#concurrent_backups[@]}" = 1 ] \
   && [ "$(cat "${concurrent_backups[0]}")" = fleet-concurrent-credential ] \
   && [ "$(stat -c %a "${concurrent_backups[0]}")" = 600 ]; then
  ok "concurrent Claude adapters preserve one backup and converge on the symlink"
else
  no "concurrent Claude credential repair lost or duplicated state (rc=$concurrent_rc backups=${#concurrent_backups[@]})"
fi

# The repair exception is deliberately bounded, not a general permission to
# replace files. Both a managed basename outside FLEET_HOME and an unmanaged
# basename inside claude-home must retain the old guard.
CLAUDE_OUTSIDE="$CLAUDE_USER_HOME/.claude/settings.json"
: > "$FLEET_HOME/outside-refusal.log"
HOME="$CLAUDE_USER_HOME" LOG="$FLEET_HOME/outside-refusal.log" \
  OUT="$FLEET_HOME/outside-refusal.out" FLEET_HOME="$FLEET_HOME" \
  bash -c '. "$1/adapters/claude_config.sh"; \
    fleet_claude_link_config_entry "$2" "$3"' _ "$ROOT" \
    "$CLAUDE_USER_HOME/.claude/.credentials.json" "$CLAUDE_OUTSIDE"
outside_rc=$?
UNMANAGED="$CLAUDE_TASK_HOME/history.jsonl"
printf 'private-session-history\n' > "$UNMANAGED"
backup_count_before=$(find "$CLAUDE_TASK_HOME/backups" -mindepth 1 \
  -maxdepth 1 -print | wc -l)
: > "$FLEET_HOME/unmanaged-refusal.log"
HOME="$CLAUDE_USER_HOME" LOG="$FLEET_HOME/unmanaged-refusal.log" \
  OUT="$FLEET_HOME/unmanaged-refusal.out" FLEET_HOME="$FLEET_HOME" \
  bash -c '. "$1/adapters/claude_config.sh"; \
    fleet_claude_link_config_entry "$2" "$3"' _ "$ROOT" \
    "$CLAUDE_USER_HOME/.claude/settings.json" "$UNMANAGED"
unmanaged_rc=$?
backup_count_after=$(find "$CLAUDE_TASK_HOME/backups" -mindepth 1 \
  -maxdepth 1 -print | wc -l)
if [ "$outside_rc" != 0 ] \
   && [ ! -L "$CLAUDE_OUTSIDE" ] \
   && [ "$(cat "$CLAUDE_OUTSIDE")" = '{"permissions":{}}' ] \
   && grep -q "refusing to replace non-symlink $CLAUDE_OUTSIDE" \
        "$FLEET_HOME/outside-refusal.log" \
   && [ "$unmanaged_rc" != 0 ] && [ ! -L "$UNMANAGED" ] \
   && [ "$(cat "$UNMANAGED")" = private-session-history ] \
   && [ "$backup_count_before" = "$backup_count_after" ]; then
  ok "Claude config guard refuses targets outside claude-home and names Fleet does not manage"
else
  no "Claude config guard crossed its managed boundary (rc=$outside_rc/$unmanaged_rc log='$(cat "$FLEET_HOME/outside-refusal.log")')"
fi

# A textual child path is not ownership when claude-home itself is a symlink.
# Never let that redirect repair into another directory. This case kills a
# mutation that removes the task_home non-symlink check.
ESCAPE_HOME="$FLEET_HOME/symlink-escape"
ESCAPE_VICTIM="$FLEET_HOME/symlink-victim"
mkdir -p "$ESCAPE_HOME" "$ESCAPE_VICTIM"
printf 'victim-setting\n' > "$ESCAPE_VICTIM/settings.json"
ln -s "$ESCAPE_VICTIM" "$ESCAPE_HOME/claude-home"
: > "$FLEET_HOME/symlink-refusal.log"
HOME="$CLAUDE_USER_HOME" LOG="$FLEET_HOME/symlink-refusal.log" \
  OUT="$FLEET_HOME/symlink-refusal.out" FLEET_HOME="$ESCAPE_HOME" \
  bash -c '. "$1/adapters/claude_config.sh"; \
    fleet_claude_link_config_entry "$2" "$3"' _ "$ROOT" \
    "$CLAUDE_USER_HOME/.claude/settings.json" \
    "$ESCAPE_HOME/claude-home/settings.json"
symlink_rc=$?
if [ "$symlink_rc" != 0 ] \
   && [ ! -L "$ESCAPE_VICTIM/settings.json" ] \
   && [ "$(cat "$ESCAPE_VICTIM/settings.json")" = victim-setting ] \
   && [ ! -e "$ESCAPE_VICTIM/backups" ] \
   && grep -q 'refusing to replace non-symlink' \
        "$FLEET_HOME/symlink-refusal.log"; then
  ok "Claude managed-entry repair cannot escape through a symlinked claude-home"
else
  no "Claude managed-entry repair followed a symlinked claude-home (rc=$symlink_rc)"
fi

# Dot segments are not accepted merely because they resolve back into the
# managed directory. The literal target remains untouched and no backup exists.
DOT_HOME="$FLEET_HOME/dot-segment"
mkdir -p "$DOT_HOME/claude-home"
printf 'dot-setting\n' > "$DOT_HOME/claude-home/settings.json"
: > "$FLEET_HOME/dot-refusal.log"
HOME="$CLAUDE_USER_HOME" LOG="$FLEET_HOME/dot-refusal.log" \
  OUT="$FLEET_HOME/dot-refusal.out" FLEET_HOME="$DOT_HOME" \
  bash -c '. "$1/adapters/claude_config.sh"; \
    fleet_claude_link_config_entry "$2" "$3"' _ "$ROOT" \
    "$CLAUDE_USER_HOME/.claude/settings.json" \
    "$DOT_HOME/claude-home/../claude-home/settings.json"
dot_rc=$?
if [ "$dot_rc" != 0 ] && [ ! -e "$DOT_HOME/claude-home/backups" ] \
   && [ "$(cat "$DOT_HOME/claude-home/settings.json")" = dot-setting ]; then
  ok "Claude managed-entry repair refuses a target spelled with dot segments"
else
  no "Claude managed-entry repair accepted a dot-segment target (rc=$dot_rc)"
fi

# The parent must canonically be claude-home itself. A nested symlink with a
# managed basename is an outside target even though its text starts with the
# managed path. This case kills a mutation that removes canonical comparison.
CANON_HOME="$FLEET_HOME/canonical-escape"
CANON_VICTIM="$FLEET_HOME/canonical-victim"
mkdir -p "$CANON_HOME/claude-home" "$CANON_VICTIM"
ln -s "$CANON_VICTIM" "$CANON_HOME/claude-home/portal"
printf 'canonical-victim\n' > "$CANON_VICTIM/settings.json"
: > "$FLEET_HOME/canonical-refusal.log"
HOME="$CLAUDE_USER_HOME" LOG="$FLEET_HOME/canonical-refusal.log" \
  OUT="$FLEET_HOME/canonical-refusal.out" FLEET_HOME="$CANON_HOME" \
  bash -c '. "$1/adapters/claude_config.sh"; \
    fleet_claude_link_config_entry "$2" "$3"' _ "$ROOT" \
    "$CLAUDE_USER_HOME/.claude/settings.json" \
    "$CANON_HOME/claude-home/portal/settings.json"
canonical_rc=$?
if [ "$canonical_rc" != 0 ] && [ ! -e "$CANON_HOME/claude-home/backups" ] \
   && [ ! -L "$CANON_VICTIM/settings.json" ] \
   && [ "$(cat "$CANON_VICTIM/settings.json")" = canonical-victim ]; then
  ok "Claude managed-entry repair refuses a non-canonical parent outside claude-home"
else
  no "Claude managed-entry repair escaped through a nested parent symlink (rc=$canonical_rc)"
fi

# Changing FLEET_HOME does not confer ownership over an entry in the old home.
DECLARED_HOME="$FLEET_HOME/declared-home"
OTHER_HOME="$FLEET_HOME/other-home"
mkdir -p "$DECLARED_HOME/claude-home/plugins" "$OTHER_HOME/claude-home"
printf 'declared-plugin\n' > "$DECLARED_HOME/claude-home/plugins/marker"
: > "$FLEET_HOME/home-mismatch.log"
HOME="$CLAUDE_USER_HOME" LOG="$FLEET_HOME/home-mismatch.log" \
  OUT="$FLEET_HOME/home-mismatch.out" FLEET_HOME="$OTHER_HOME" \
  bash -c '. "$1/adapters/claude_config.sh"; \
    fleet_claude_link_config_entry "$2" "$3"' _ "$ROOT" \
    "$CLAUDE_USER_HOME/.claude/plugins" \
    "$DECLARED_HOME/claude-home/plugins"
home_mismatch_rc=$?
if [ "$home_mismatch_rc" != 0 ] \
   && [ -d "$DECLARED_HOME/claude-home/plugins" ] \
   && [ "$(cat "$DECLARED_HOME/claude-home/plugins/marker")" = declared-plugin ] \
   && [ ! -e "$OTHER_HOME/claude-home/backups" ]; then
  ok "Claude managed-entry repair refuses a target owned by another FLEET_HOME"
else
  no "Claude managed-entry repair crossed FLEET_HOME ownership (rc=$home_mismatch_rc)"
fi

# Cover the failure after the displaced entry has been secured but before it
# reaches backups/. The mv shim only rejects that second move. The adapter must
# fail loudly and retain the 0600 displaced copy instead of dropping data.
MVFAIL_HOME="$FLEET_HOME/mv-failure"
MVFAIL_BIN="$FLEET_HOME/mv-failure-bin"
mkdir -p "$MVFAIL_HOME/claude-home" "$MVFAIL_BIN"
printf 'mv-failure-setting\n' > "$MVFAIL_HOME/claude-home/settings.json"
cat > "$MVFAIL_BIN/mv" <<'SH'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last="$arg"; done
case "$last" in
  */backups/settings.json-[0-9]*) exit 73 ;;
esac
exec /usr/bin/mv "$@"
SH
chmod +x "$MVFAIL_BIN/mv"
: > "$FLEET_HOME/mv-failure.log"
HOME="$CLAUDE_USER_HOME" PATH="$MVFAIL_BIN:$PATH" \
  LOG="$FLEET_HOME/mv-failure.log" OUT="$FLEET_HOME/mv-failure.out" \
  FLEET_HOME="$MVFAIL_HOME" bash -c \
  '. "$1/adapters/claude_config.sh"; \
    fleet_claude_link_config_entry "$2" "$3"' _ "$ROOT" \
    "$CLAUDE_USER_HOME/.claude/settings.json" \
    "$MVFAIL_HOME/claude-home/settings.json"
mv_failure_rc=$?
mapfile -t displaced_entries < <(find "$MVFAIL_HOME/claude-home" -maxdepth 1 \
  -name '.fleet-displaced-settings.json.*' -print)
if [ "$mv_failure_rc" != 0 ] && [ "${#displaced_entries[@]}" = 1 ] \
   && [ "$(stat -c %a "${displaced_entries[0]}")" = 600 ] \
   && [ "$(cat "${displaced_entries[0]}")" = mv-failure-setting ] \
   && [ ! -e "$MVFAIL_HOME/claude-home/settings.json" ] \
   && grep -Fq 'cannot move replaced settings.json' "$FLEET_HOME/mv-failure.log" \
   && grep -Fq "preserved at ${displaced_entries[0]}" "$FLEET_HOME/mv-failure.log" \
   && [ "$(cat "$CLAUDE_USER_HOME/.claude/settings.json")" = '{"permissions":{}}' ]; then
  ok "a failed backup mv reports the error and preserves the displaced entry at mode 600"
else
  no "failed backup mv lost data or diagnostics (rc=$mv_failure_rc displaced=${#displaced_entries[@]} log='$(cat "$FLEET_HOME/mv-failure.log")')"
fi

# The replacement becomes a credential copy as soon as the first rename
# succeeds. Even if backups/ cannot be selected, that retained copy must
# already be owner-only; securing it after backup setup is too late.
BLOCKED_BACKUP_HOME="$FLEET_HOME/blocked-backup"
mkdir -p "$BLOCKED_BACKUP_HOME/claude-home"
printf 'blocked-backup-credential\n' > \
  "$BLOCKED_BACKUP_HOME/claude-home/.credentials.json"
chmod 644 "$BLOCKED_BACKUP_HOME/claude-home/.credentials.json"
printf 'not-a-directory\n' > "$BLOCKED_BACKUP_HOME/claude-home/backups"
: > "$FLEET_HOME/blocked-backup.log"
HOME="$CLAUDE_USER_HOME" LOG="$FLEET_HOME/blocked-backup.log" \
  OUT="$FLEET_HOME/blocked-backup.out" FLEET_HOME="$BLOCKED_BACKUP_HOME" \
  bash -c '. "$1/adapters/claude_config.sh"; \
    fleet_claude_link_config_entry "$2" "$3"' _ "$ROOT" \
    "$CLAUDE_USER_HOME/.claude/.credentials.json" \
    "$BLOCKED_BACKUP_HOME/claude-home/.credentials.json"
blocked_backup_rc=$?
mapfile -t blocked_displaced < <(find "$BLOCKED_BACKUP_HOME/claude-home" \
  -maxdepth 1 -type f -name '.fleet-displaced-.credentials.json.*' -print)
if [ "$blocked_backup_rc" != 0 ] && [ "${#blocked_displaced[@]}" = 1 ] \
   && [ "$(stat -c %a "${blocked_displaced[0]}")" = 600 ] \
   && [ "$(cat "${blocked_displaced[0]}")" = blocked-backup-credential ] \
   && [ ! -e "$BLOCKED_BACKUP_HOME/claude-home/.credentials.json" ] \
   && [ "$(cat "$BLOCKED_BACKUP_HOME/claude-home/backups")" = not-a-directory ] \
   && grep -Fq 'cannot create managed-entry backup dir' \
        "$FLEET_HOME/blocked-backup.log" \
   && [ "$(cat "$CLAUDE_USER_HOME/.claude/.credentials.json")" = \
        refreshable-credential ]; then
  ok "a displaced credential is mode 600 before an unusable backups path fails"
else
  no "an early backup-dir failure left an unsecured credential copy (rc=$blocked_backup_rc displaced=${#blocked_displaced[@]})"
fi

# Retry the genuine failed backup move above without the shim. A successful
# repair must sweep the same-entry recovery file into backups/ rather than
# leaving an accumulating orphan beside the managed links.
: > "$FLEET_HOME/orphan-retry.log"
HOME="$CLAUDE_USER_HOME" LOG="$FLEET_HOME/orphan-retry.log" \
  OUT="$FLEET_HOME/orphan-retry.out" FLEET_HOME="$MVFAIL_HOME" \
  bash -c '. "$1/adapters/claude_config.sh"; \
    fleet_claude_link_config_entry "$2" "$3"' _ "$ROOT" \
    "$CLAUDE_USER_HOME/.claude/settings.json" \
    "$MVFAIL_HOME/claude-home/settings.json"
orphan_retry_rc=$?
mapfile -t remaining_orphans < <(find "$MVFAIL_HOME/claude-home" -maxdepth 1 \
  -name '.fleet-displaced-settings.json.*' -print)
mapfile -t recovered_backups < <(find "$MVFAIL_HOME/claude-home/backups" \
  -maxdepth 1 -type f -name 'settings.json-[0-9]*' -print 2>/dev/null)
if [ "$orphan_retry_rc" = 0 ] \
   && [ -L "$MVFAIL_HOME/claude-home/settings.json" ] \
   && [ "$(readlink "$MVFAIL_HOME/claude-home/settings.json")" = \
        "$CLAUDE_USER_HOME/.claude/settings.json" ] \
   && [ "${#remaining_orphans[@]}" = 0 ] \
   && [ "${#recovered_backups[@]}" = 1 ] \
   && [ "$(stat -c %a "${recovered_backups[0]}")" = 600 ] \
   && [ "$(cat "${recovered_backups[0]}")" = mv-failure-setting ] \
   && [ "$(cat "$CLAUDE_USER_HOME/.claude/settings.json")" = \
        '{"permissions":{}}' ]; then
  ok "a successful retry archives the mode-600 displaced orphan"
else
  no "a successful retry left or changed the displaced orphan (rc=$orphan_retry_rc orphans=${#remaining_orphans[@]} backups=${#recovered_backups[@]})"
fi

# Exercise a real detached Fleet launch, not just the helper. A broken managed
# root fails before Claude starts; launcher stderr capture makes log.txt and the
# beginning of out.md durable evidence.
mv "$CLAUDE_TASK_HOME" "$FLEET_HOME/claude-home-before-diagnostic"
printf 'blocked-managed-root\n' > "$CLAUDE_TASK_HOME"
PREFLIGHT_TASK=$(HOME="$CLAUDE_USER_HOME" fleet add \
  "claude preflight diagnosis" --channel claude-p --spec "$FLEET_HOME/spec.md" \
  --cwd "$W1" --max-attempts 1)
HOME="$CLAUDE_USER_HOME" fleet run "$PREFLIGHT_TASK" >/dev/null
preflight_status=""
for _ in $(seq 1 100); do
  preflight_status=$(fleet show "$PREFLIGHT_TASK" | \
    awk '$1=="status:" {print $2}')
  [ "$preflight_status" = failed ] && break
  sleep 0.1
done
PREFLIGHT_DIR="$FLEET_HOME/runs/$PREFLIGHT_TASK/attempt-1"
if [ "$preflight_status" = failed ] \
   && grep -q "refusing non-directory isolated config path $CLAUDE_TASK_HOME" \
        "$PREFLIGHT_DIR/log.txt" \
   && fleet tail "$PREFLIGHT_TASK" | \
        grep -q "refusing non-directory isolated config path $CLAUDE_TASK_HOME" \
   && head -n 1 "$PREFLIGHT_DIR/out.md" | \
        grep -q '^# Adapter startup failed$' \
   && grep -q "refusing non-directory isolated config path $CLAUDE_TASK_HOME" \
        "$PREFLIGHT_DIR/out.md" \
   && [ "$(cat "$CLAUDE_TASK_HOME")" = blocked-managed-root ]; then
  ok "detached Claude preflight failures are visible in fleet tail and out.md"
else
  no "detached Claude preflight failure left no durable diagnosis (status=$preflight_status)"
fi

# Probe uses the same adapter path but has no durable attempt directory. Its
# own output must therefore carry the final stderr diagnosis, not just exit 1.
probe_failure=$(HOME="$CLAUDE_USER_HOME" fleet probe claude-p 2>&1)
probe_rc=$?
if [ "$probe_rc" = 0 ] \
   && printf '%s\n' "$probe_failure" | grep -Fq \
        "FAIL exit 1: claude adapter: refusing non-directory isolated config path $CLAUDE_TASK_HOME"; then
  ok "fleet probe reports the Claude adapter's concrete preflight failure"
else
  no "fleet probe hid the Claude preflight failure (rc=$probe_rc out='$probe_failure')"
fi

# ---------------------------------------------------------------------------
# 33-36. When Claude refreshes the token it RENAMES a new file over
# the managed link, so the refreshed credentials land inside Fleet's directory
# and the user's source keeps a refresh token the server has already rotated
# away -- which is what "Claude keeps asking me to log in" looks like from the
# operator's side. The refreshed set is promoted back, but only when it is
# newer than the source AND structurally complete: a truncated or foreign file
# must never overwrite live credentials. Non-JSON contents never promote at
# all, which is why cases 18-32 above still see an untouched user source.
# ---------------------------------------------------------------------------
promote_source="$CLAUDE_USER_HOME/.claude/.credentials.json"
promote_target="$CLAUDE_TASK_HOME/.credentials.json"
promote_log="$FLEET_HOME/promote.log"

promote_setup() {
  # $1 = user-source JSON, $2 = what Claude wrote over the link,
  # $3 = mtime for the replacement relative to the source.
  # Cases 18-32 above deliberately leave CLAUDE_TASK_HOME as a non-directory
  # (the isolated-config-path guard). Rebuild it: fleet_claude_config_init
  # recreates every managed link from the user source anyway.
  rm -rf "$CLAUDE_TASK_HOME"
  mkdir -p -m 700 "$CLAUDE_TASK_HOME"
  printf '%s\n' "$1" > "$promote_source"
  touch -d '2026-09-22 12:00:00' "$promote_source"
  rm -f -- "$promote_target"
  printf '%s\n' "$2" > "$promote_target.next"
  mv -Tf -- "$promote_target.next" "$promote_target"
  touch -d "$3" "$promote_target"
  : > "$promote_log"
  HOME="$CLAUDE_USER_HOME" LOG="$promote_log" \
    OUT="$FLEET_HOME/promote.out" FLEET_HOME="$FLEET_HOME" bash -c \
    '. "$1/adapters/claude_config.sh"; fleet_claude_config_init' _ "$ROOT"
}

promote_setup '{"claudeAiOauth":{"accessToken":"at-old","refreshToken":"rt-old","expiresAt":1000},"mcpOAuth":{}}' \
              '{"claudeAiOauth":{"accessToken":"at-new","refreshToken":"rt-new","expiresAt":2000},"mcpOAuth":{}}' '2026-09-22 13:00:00'
promote_rc=$?
promote_backups=$(find "$CLAUDE_TASK_HOME/backups" -mindepth 1 -maxdepth 1 \
  -name '.credentials.json.user-source-[0-9]*' -print 2>/dev/null | wc -l)
if [ "$promote_rc" = 0 ] \
   && grep -Fq '"refreshToken":"rt-new"' "$promote_source" \
   && [ "$promote_backups" = 1 ] \
   && [ -L "$promote_target" ] \
   && [ "$(readlink "$promote_target")" = "$promote_source" ] \
   && grep -Fq "promoted refreshed credentials" "$promote_log"; then
  ok "a newer refreshed credential set is promoted to the user source, with the previous copy kept"
else
  no "credential promotion failed (rc=$promote_rc backups=$promote_backups source='$(cat "$promote_source")')"
fi

promote_setup '{"claudeAiOauth":{"accessToken":"at-live","refreshToken":"rt-live","expiresAt":2000},"mcpOAuth":{}}' \
              '{"claudeAiOauth":{"accessToken":"at-stale","refreshToken":"rt-stale","expiresAt":1000},"mcpOAuth":{}}' '2026-09-22 13:00:00'
promote_rc=$?
if [ "$promote_rc" = 0 ] \
   && grep -Fq '"refreshToken":"rt-live"' "$promote_source" \
   && ! grep -Fq "promoted refreshed credentials" "$promote_log"; then
  ok "an older credential set never overwrites the user source"
else
  no "stale credential was promoted (rc=$promote_rc source='$(cat "$promote_source")')"
fi

promote_setup '{"claudeAiOauth":{"accessToken":"at-live","refreshToken":"rt-live","expiresAt":1000},"mcpOAuth":{}}' \
              '{"claudeAiOauth":{"accessToken":"at-truncated","refreshToken":null,"expiresAt":2000},"mcpOAuth":{}}' '2026-09-22 13:00:00'
promote_rc=$?
if [ "$promote_rc" = 0 ] \
   && grep -Fq '"refreshToken":"rt-live"' "$promote_source" \
   && ! grep -Fq "promoted refreshed credentials" "$promote_log"; then
  ok "a newer but structurally incomplete credential file is refused"
else
  no "incomplete credential was promoted (rc=$promote_rc source='$(cat "$promote_source")')"
fi

# 36. The refresh happens DURING a run, not between runs, so claude_p.sh syncs
#     again after Claude exits. Waiting for the next task's preflight can leave
#     the operator's own session holding a rotated-away refresh token for
#     hours. The adapter's exit code must survive the extra step.
rm -rf "$CLAUDE_TASK_HOME"
mkdir -p -m 700 "$CLAUDE_TASK_HOME"
printf '%s\n' '{"claudeAiOauth":{"accessToken":"at-before-run","refreshToken":"rt-before-run","expiresAt":1000},"mcpOAuth":{}}' > "$promote_source"
touch -d '2026-09-22 12:00:00' "$promote_source"
cat > "$FLEET_HOME/fake-claude-bin/claude" <<'SH'
#!/usr/bin/env bash
# Stand in for an OAuth refresh mid-run: rename a new credential file over the
# managed link, exactly as Claude Code does.
printf '%s\n' '{"claudeAiOauth":{"accessToken":"at-rotated-mid-run","refreshToken":"rt-rotated-mid-run","expiresAt":2000},"mcpOAuth":{}}' \
  > "$CLAUDE_CONFIG_DIR/.credentials.json.next"
mv -Tf -- "$CLAUDE_CONFIG_DIR/.credentials.json.next" \
  "$CLAUDE_CONFIG_DIR/.credentials.json"
touch -d '2026-09-22 14:00:00' "$CLAUDE_CONFIG_DIR/.credentials.json"
printf 'model answer\n'
exit 7
SH
chmod +x "$FLEET_HOME/fake-claude-bin/claude"
HOME="$CLAUDE_USER_HOME" PATH="$FLEET_HOME/fake-claude-bin:$PATH" \
  FLEET_HOME="$FLEET_HOME" bash "$ROOT/adapters/claude_p.sh" 836 \
    "$FLEET_HOME/spec.md" "$W1" "$FLEET_HOME/postrun.out" \
    "$FLEET_HOME/postrun.log"
postrun_rc=$?
if [ "$postrun_rc" = 7 ] \
   && grep -Fq '"refreshToken":"rt-rotated-mid-run"' "$promote_source" \
   && [ "$(cat "$FLEET_HOME/postrun.out")" = "model answer" ] \
   && grep -Fq "promoted refreshed credentials" "$FLEET_HOME/postrun.log"; then
  ok "a token refreshed mid-run is synced back when the adapter finishes, without disturbing output or exit code"
else
  no "post-run credential sync failed (rc=$postrun_rc source='$(cat "$promote_source")' out='$(cat "$FLEET_HOME/postrun.out" 2>/dev/null)')"
fi

# 37-38. A logged-out file can keep the same top-level shape as live credentials
#     while carrying a null token inside claudeAiOauth. Promoting that would
#     cause the very logout this path exists to prevent. Case 38 pins the other
#     side: a genuinely rotated pair at
#     equal expiry still promotes, so the tightening does not refuse rotation.
promote_setup '{"claudeAiOauth":{"accessToken":"at-live","refreshToken":"rt-live","expiresAt":9},"mcpOAuth":{}}' \
              '{"claudeAiOauth":{"accessToken":"at-new","refreshToken":null,"expiresAt":9},"mcpOAuth":{}}' \
              '2026-09-22 13:00:00'
promote_rc=$?
if [ "$promote_rc" = 0 ] \
   && grep -Fq '"refreshToken":"rt-live"' "$promote_source" \
   && ! grep -Fq "promoted refreshed credentials" "$promote_log"; then
  ok "a logged-out-shaped credential file is refused even though its top-level keys match"
else
  no "logged-out credential was promoted (rc=$promote_rc source='$(cat "$promote_source")')"
fi

promote_setup '{"claudeAiOauth":{"accessToken":"at-old","refreshToken":"rt-old","expiresAt":9},"mcpOAuth":{}}' \
              '{"claudeAiOauth":{"accessToken":"at-new","refreshToken":"rt-new","expiresAt":9},"mcpOAuth":{}}' \
              '2026-09-22 13:00:00'
promote_rc=$?
if [ "$promote_rc" = 0 ] \
   && grep -Fq '"refreshToken":"rt-new"' "$promote_source" \
   && grep -Fq "promoted refreshed credentials" "$promote_log"; then
  ok "a real-shaped rotated credential pair still promotes"
else
  no "real-shaped rotation was refused (rc=$promote_rc source='$(cat "$promote_source")')"
fi

# 39. File mtime is not OAuth recency. The user's document can be rewritten
#     after Fleet's (for example, to update a connector) while still carrying
#     the older claudeAiOauth refresh pair. The newer OAuth block must win, but
#     only that block: user-side connector and unrelated state stay authoritative.
promote_setup '{"claudeAiOauth":{"accessToken":"at-old-fixture","refreshToken":"rt-old-fixture","expiresAt":1000},"mcpOAuth":{"connector":{"accessToken":"mcp-user-fixture"}},"userState":{"theme":"dark"}}' \
              '{"claudeAiOauth":{"accessToken":"at-new-fixture","refreshToken":"rt-new-fixture","expiresAt":2000},"mcpOAuth":{"connector":{"accessToken":"mcp-fleet-stale-fixture"}},"fleetOnly":true}' \
              '2026-09-22 11:00:00'
promote_rc=$?
oauth_merge_ok=1
promote_backup=$(find "$CLAUDE_TASK_HOME/backups" -mindepth 1 -maxdepth 1 \
  -name '.credentials.json.user-source-[0-9]*' -print 2>/dev/null | head -n1)
python3 - "$promote_source" "$promote_backup" <<'PY' || oauth_merge_ok=0
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    backup = json.load(handle)
assert value["claudeAiOauth"]["expiresAt"] == 2000
assert value["claudeAiOauth"]["refreshToken"] == "rt-new-fixture"
assert value["mcpOAuth"]["connector"]["accessToken"] == "mcp-user-fixture"
assert value["userState"] == {"theme": "dark"}
assert "fleetOnly" not in value
assert backup["claudeAiOauth"]["refreshToken"] == "rt-old-fixture"
assert backup["mcpOAuth"] == value["mcpOAuth"]
PY
if [ "$promote_rc" = 0 ] && [ "$oauth_merge_ok" = 1 ] \
   && [ "$(stat -c %a "$promote_source")" = 600 ] \
   && [ "$(stat -c %a "$promote_backup")" = 600 ] \
   && [ -L "$promote_target" ] \
   && grep -Fq "promoted refreshed credentials" "$promote_log"; then
  ok "OAuth recency overrides file mtime while user-side mcpOAuth and other state survive"
else
  no "OAuth promotion followed file mtime or replaced non-OAuth user state (rc=$promote_rc merge=$oauth_merge_ok)"
fi

# 40. A user login after the Fleet copy was stranded has the later OAuth
#     expiry. It must win even when the stale Fleet file has the later mtime.
promote_setup '{"claudeAiOauth":{"accessToken":"at-user-login","refreshToken":"rt-user-login","expiresAt":3000},"mcpOAuth":{}}' \
              '{"claudeAiOauth":{"accessToken":"at-fleet-stale","refreshToken":"rt-fleet-stale","expiresAt":2000},"mcpOAuth":{}}' \
              '2026-09-22 13:00:00'
promote_rc=$?
if [ "$promote_rc" = 0 ] \
   && grep -Fq '"refreshToken":"rt-user-login"' "$promote_source" \
   && ! grep -Fq "promoted refreshed credentials" "$promote_log"; then
  ok "a later user login is never overwritten by a stale Fleet OAuth block"
else
  no "a stale Fleet OAuth block overwrote a later user login (rc=$promote_rc)"
fi

# ---------------------------------------------------------------------------
# 41-46. A dedicated subscription token (`claude setup-token`) moves claude-p
# off the operator's refreshable login. With the token file present the
# adapter must run in a config home that has no credential entry at all,
# hand the token to Claude, leave the operator's credential file untouched,
# and skip the end-of-run credential sync. A present but unusable file is an
# error, never a silent fallback to the shared login.
# ---------------------------------------------------------------------------
TOKEN_FILE="$FLEET_HOME/claude-oauth-token"
TOKEN_HOME="$FLEET_HOME/claude-token-home"
printf 'sk-ant-oat01-fixture-token-value_0123456789\n' > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
cat > "$FLEET_HOME/fake-claude-bin/claude" <<'SH'
#!/usr/bin/env bash
# Report the auth environment without echoing the token itself.
printf 'dir=%s\n' "${CLAUDE_CONFIG_DIR:-missing}"
if [ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = sk-ant-oat01-fixture-token-value_0123456789 ]; then
  printf 'token=fixture\n'
else
  printf 'token=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:+other}"
fi
# Simulate a refresh that would replace a managed credential link.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "${FAKE_CLAUDE_NO_REFRESH:-}" != 1 ]; then
  printf '{"claudeAiOauth":{"accessToken":"at-fake-refresh","refreshToken":"rt-fake-refresh","expiresAt":9999}}\n' \
    > "$CLAUDE_CONFIG_DIR/.credentials.next" \
    && mv -Tf "$CLAUDE_CONFIG_DIR/.credentials.next" "$CLAUDE_CONFIG_DIR/.credentials.json"
fi
SH
chmod +x "$FLEET_HOME/fake-claude-bin/claude"
user_cred_before="$(sha256sum "$CLAUDE_USER_HOME/.claude/.credentials.json" | cut -d' ' -f1)"
# A stale link in the token home (as an older adapter could leave) must go.
mkdir -p "$TOKEN_HOME"
ln -sfn "$CLAUDE_USER_HOME/.claude/.credentials.json" "$TOKEN_HOME/.credentials.json"
HOME="$CLAUDE_USER_HOME" PATH="$FLEET_HOME/fake-claude-bin:$PATH" \
  bash "$ROOT/adapters/claude_p.sh" 841 "$FLEET_HOME/spec.md" "$W1" \
    "$FLEET_HOME/token.out" "$FLEET_HOME/token.log"
token_rc=$?
if [ "$token_rc" = 0 ] \
   && grep -qx "dir=$TOKEN_HOME" "$FLEET_HOME/token.out" \
   && grep -qx 'token=fixture' "$FLEET_HOME/token.out"; then
  ok "with a token file, claude-p runs in the token home and hands Claude the token"
else
  no "token mode did not reach Claude (rc=$token_rc out=$(tr '\n' ' ' < "$FLEET_HOME/token.out"))"
fi
if [ "$(sha256sum "$CLAUDE_USER_HOME/.claude/.credentials.json" | cut -d' ' -f1)" = "$user_cred_before" ] \
   && ! grep -q 'promoted refreshed credentials' "$FLEET_HOME/token.log"; then
  ok "a refresh inside the token home never reaches the operator's credential file"
else
  no "token mode changed the operator's credential file"
fi
# The fake refresh wrote a regular file; the next invocation must move it to
# backups/ instead of linking or promoting it.
HOME="$CLAUDE_USER_HOME" PATH="$FLEET_HOME/fake-claude-bin:$PATH" \
  bash "$ROOT/adapters/claude_p.sh" 842 "$FLEET_HOME/spec.md" "$W1" \
    "$FLEET_HOME/token2.out" "$FLEET_HOME/token2.log"
token2_backups="$(find "$TOKEN_HOME/backups" -maxdepth 1 -type f -name '.credentials.json-*' 2>/dev/null | wc -l)"
if [ "$token2_backups" -ge 1 ] \
   && grep -q 'moved a credential file out of the token home' "$FLEET_HOME/token2.log" \
   && [ "$(sha256sum "$CLAUDE_USER_HOME/.claude/.credentials.json" | cut -d' ' -f1)" = "$user_cred_before" ]; then
  ok "a credential file found in the token home is archived, never linked or promoted"
else
  no "token home kept or promoted a credential file (backups=$token2_backups)"
fi
# Stale link removed: after the first run the token home had no link to the
# operator's file (the fake refresh's file is the only entry, archived above).
if [ ! -L "$TOKEN_HOME/.credentials.json" ] \
   && [ "$(readlink "$TOKEN_HOME/.credentials.json" 2>/dev/null)" != "$CLAUDE_USER_HOME/.claude/.credentials.json" ]; then
  ok "the token home never keeps a link to the operator's login"
else
  no "the token home still links the operator's login"
fi
# A run without any refresh must leave the token home with no credential
# entry at all: the end-of-run sync belongs to the shared-login mode only.
rm -f "$TOKEN_HOME/.credentials.json"
HOME="$CLAUDE_USER_HOME" PATH="$FLEET_HOME/fake-claude-bin:$PATH" FAKE_CLAUDE_NO_REFRESH=1 \
  bash "$ROOT/adapters/claude_p.sh" 846 "$FLEET_HOME/spec.md" "$W1" \
    "$FLEET_HOME/token6.out" "$FLEET_HOME/token6.log"
if grep -qx 'token=fixture' "$FLEET_HOME/token6.out" \
   && [ ! -e "$TOKEN_HOME/.credentials.json" ] && [ ! -L "$TOKEN_HOME/.credentials.json" ]; then
  ok "a token-mode run leaves no credential entry behind in the token home"
else
  no "a token-mode run left a credential entry ($(ls -la "$TOKEN_HOME" 2>/dev/null | grep credentials))"
fi
# An unusable token file fails the task instead of falling back.
chmod 644 "$TOKEN_FILE"
HOME="$CLAUDE_USER_HOME" PATH="$FLEET_HOME/fake-claude-bin:$PATH" \
  bash "$ROOT/adapters/claude_p.sh" 843 "$FLEET_HOME/spec.md" "$W1" \
    "$FLEET_HOME/token3.out" "$FLEET_HOME/token3.log"
token3_rc=$?
if [ "$token3_rc" != 0 ] \
   && grep -q 'unusable subscription token file' "$FLEET_HOME/token3.out" \
   && ! grep -q '^dir=' "$FLEET_HOME/token3.out"; then
  ok "a group/other-readable token file fails the task without a shared-login fallback"
else
  no "a bad token file fell back or ran (rc=$token3_rc)"
fi
chmod 600 "$TOKEN_FILE"
printf 'two\nlines-of-token-material-xxxxxxxxxx\n' > "$TOKEN_FILE"
HOME="$CLAUDE_USER_HOME" PATH="$FLEET_HOME/fake-claude-bin:$PATH" \
  bash "$ROOT/adapters/claude_p.sh" 844 "$FLEET_HOME/spec.md" "$W1" \
    "$FLEET_HOME/token4.out" "$FLEET_HOME/token4.log"
token4_rc=$?
rm -f "$TOKEN_FILE"
if [ "$token4_rc" != 0 ] && grep -q 'exactly one token line' "$FLEET_HOME/token4.out"; then
  ok "a malformed token file fails the task"
else
  no "a malformed token file was accepted (rc=$token4_rc)"
fi
# Without the token file, claude-p is back on the shared-login home.
HOME="$CLAUDE_USER_HOME" PATH="$FLEET_HOME/fake-claude-bin:$PATH" \
  bash "$ROOT/adapters/claude_p.sh" 845 "$FLEET_HOME/spec.md" "$W1" \
    "$FLEET_HOME/token5.out" "$FLEET_HOME/token5.log"
if grep -qx "dir=$CLAUDE_TASK_HOME" "$FLEET_HOME/token5.out" \
   && grep -qx 'token=' "$FLEET_HOME/token5.out"; then
  ok "without a token file, claude-p keeps the shared-login home and no token env"
else
  no "the shared-login fallback changed ($(tr '\n' ' ' < "$FLEET_HOME/token5.out"))"
fi

echo "passed $PASS / $N"
[ "$FAIL" = "0" ] || exit 1
