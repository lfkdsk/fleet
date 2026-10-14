#!/usr/bin/env bash
# grok channel adapter (xAI Grok CLI, headless).
set -u

TASK_ID="$1"
PROMPT="$2"
CWD="$3"
OUT="$4"
LOG="$5"

# A failed cd must not fall through: every adapter is `set -u`, not -eu, so
# without this guard the model would run in whatever directory fleet happened
# to be in and read/write the wrong tree, exit 0, and look like a clean run.
cd "$CWD" || exit 1

# The prompt goes in by path, never argv. grok has no stdin prompt mode -- `-p`
# takes the text as an argument -- so the cursor.sh E2BIG failure mode
# (MAX_ARG_STRLEN past ~128 KiB, with $OUT already truncated to empty by the
# shell's redirect, so it looks like "success with no output") would apply
# verbatim here. --prompt-file reads the same spec file fleet already wrote, so
# the text never enters the process table either. --verbatim stops grok from
# rewriting or expanding the spec: a spec routinely contains @paths and lines
# starting with `/`, which are prompt syntax without it.
#
# No --sandbox flag: grok's default profile is `off` (unrestricted), and that
# is the trade codex.sh already makes -- containment comes from
# fleet's worktree + TMPDIR isolation, not from the agent's own sandbox. Naming
# a profile here would additionally cut the task off from $TMPDIR outside cwd.
# grok scans the *other* harnesses' configs by default. On this box that means
# a fleet task would silently inherit ~/.claude.json's MCP servers (cursor,
# codex, ...) and ~/.claude/settings.json's Stop hook.
# Both are wrong for a dispatched worker, and the first is wrong in the way
# this project cares most about: a grok reviewer able to call cursor__cursor_run
# (claude) or codex__codex (gpt) is no longer a heterogeneous reviewer, and the
# models it reaches that way are spent off fleet's books entirely. The Stop hook
# is the commander's own `contrib/surface-decisions.py`, which has no business
# firing inside the worker it supervises. Measured with `grok inspect`: with
# these set the task sees exactly one MCP server, fleet's.
export GROK_CLAUDE_MCPS_ENABLED=0 GROK_CURSOR_MCPS_ENABLED=0
export GROK_CLAUDE_HOOKS_ENABLED=0 GROK_CURSOR_HOOKS_ENABLED=0

ARGS=(--prompt-file "$PROMPT" --verbatim --cwd "$CWD"
      --output-format plain --permission-mode bypassPermissions
      --no-auto-update)
if [ -n "${FLEET_MODEL:-}" ]; then
    ARGS+=(-m "$FLEET_MODEL")
fi
# grok only accepts low/medium/high/xhigh (no `max`); an
# unknown level is a hard error, not a fallback, so only pass what the channel
# actually set.
if [ -n "${FLEET_EFFORT:-}" ]; then
    ARGS+=(--reasoning-effort "$FLEET_EFFORT")
fi

# MCP: grok has no per-invocation MCP flag -- servers come from config files,
# and the two config files it reads by default are both shared state. The
# repo-scoped <cwd>/.grok/config.toml was the old choice and is what this
# replaces: an untracked .grok/ leaves the task's worktree permanently dirty,
# `fleet worktree prune --merged-only` reads a dirty worktree as unmerged, and
# so every grok task's worktree became unreclaimable -- while a reviewer whose
# --cwd points at the *reviewed* task's worktree wrote its residue into
# someone else's diff. The operator's own ~/.grok/config.toml is worse: one
# file for every concurrent task, so its FLEET_TASK_ID would be whichever task
# wrote last and claims would land on the wrong row.
#
# What makes a third place possible is that grok's whole user layer is
# relocatable: $GROK_HOME (default ~/.grok) names the directory its
# config.toml is read from, and that layer is user-scoped, so unlike the
# repo-scoped file it is not gated on folder trust (measured with
# `grok inspect --json`: the fleet server appears with source type configToml
# and role user, with GROK_FOLDER_TRUST unset). The task therefore gets a
# GROK_HOME of its own under the current attempt's run dir, which fleet owns.
# Retries and concurrent tasks each read their own FLEET_TASK_ID/FLEET_ATTEMPT,
# and the directory is outside every workspace. Direct adapter invocations
# without FLEET_RUN_DIR retain the old task-level fallback. The GROK_CONFIG /
# GROK_CONFIG_PATH overlays
# would be neater still, but grok confines them to an allowlist of soft
# settings (models, features, toolset, shell_environment_policy) and drops
# every other table at the choke point, `mcp_servers` included, so they cannot
# carry a server.
#
# The per-task home is a symlink farm over the real one: auth.json, sessions,
# bundled assets and the rest stay exactly where they are (a bare GROK_HOME
# would log the task out), and only config.toml is this task's own.
# trusted_folders.toml is deliberately left out of the farm -- a trust row for
# a throwaway worktree would otherwise be written through the symlink into the
# operator's real store, which is the same residue in a different directory.
# GROK_FOLDER_TRUST=0 keeps anything from asking for one; it is process-scoped
# and grants nothing beyond what bypassPermissions already grants here.
#
# This also retires the "no --worktree means no MCP" degradation: the config
# no longer needs a fleet-managed worktree to live in, so every grok task gets
# a ledger wherever its cwd points.
if [ -n "${FLEET_MCP_JSON:-}" ]; then
    SRC_HOME="${GROK_HOME:-$HOME/.grok}"
    TASK_HOME="${FLEET_RUN_DIR:-${FLEET_HOME:-$HOME/.fleet}/runs/$TASK_ID}/grok-home"
    CFG="$TASK_HOME/config.toml"
    if mkdir -p "$TASK_HOME" 2>/dev/null; then
        for entry in "$SRC_HOME"/* "$SRC_HOME"/.[!.]*; do
            [ -e "$entry" ] || continue
            base=${entry##*/}
            case "$base" in
                config.toml|trusted_folders.toml|trusted_folders.toml.lock) continue ;;
            esac
            ln -sfn "$entry" "$TASK_HOME/$base"
        done
        # The operator's global settings survive: the task's config is their
        # config.toml plus our block. Written whole on every run, never
        # appended: even a repeated invocation in one attempt must not add a
        # second [mcp_servers.fleet], which is a TOML parse error rather than
        # "last one wins" and would start the attempt with no ledger.
        {
            if [ -f "$SRC_HOME/config.toml" ]; then
                # Their file, minus an [mcp_servers.fleet] of their own: two
                # tables of one name is a TOML parse error, not "last one
                # wins", so a single `grok mcp add fleet ...` in the
                # operator's home would leave every grok task with an
                # unparseable config and no ledger at all.
                python3 - "$SRC_HOME/config.toml" <<'PYSRC'
import re, sys
FLEET_TABLE = re.compile(r"\s*\[\[?mcp_servers\.fleet[].]")
keep, skip = [], False
for line in open(sys.argv[1]):
    if FLEET_TABLE.match(line):
        skip = True
        continue
    if skip and re.match(r"\s*\[", line):
        skip = False
    if not skip:
        keep.append(line)
sys.stdout.write("".join(keep))
PYSRC
                printf '\n'
            fi
            printf '%s\n' '# >>> fleet mcp (generated per task) >>>'
            python3 - <<'PYCFG'
import json, os
srv = json.loads(os.environ["FLEET_MCP_JSON"])["mcpServers"]


def s(v):
    return json.dumps(str(v))


for name, cfg in srv.items():
    print(f"[mcp_servers.{name}]")
    print(f"command = {s(cfg['command'])}")
    print("args = [" + ", ".join(s(a) for a in cfg.get("args") or []) + "]")
    env = cfg.get("env") or {}
    print("env = { " + ", ".join(f"{k} = {s(v)}" for k, v in env.items()) + " }")
PYCFG
        } > "$CFG" 2>/dev/null
    fi
    # One way is left to lose MCP: an unwritable run dir. Say so loudly rather
    # than launch a mute agent -- an agent that silently cannot file a claim is
    # exactly how a fake-successful task gets through.
    if grep -q '^\[mcp_servers\.' "$CFG" 2>/dev/null; then
        export GROK_HOME="$TASK_HOME"
        export GROK_FOLDER_TRUST=0
    else
        echo "warning: grok task $TASK_ID could not write $CFG: no MCP configured, the agent cannot file claims" >&2
    fi
fi

if [ "${FLEET_ADAPTER_DRYRUN:-}" = "1" ]; then
    # Print the command line, do not execute: tests assert on argv shape.
    printf 'DRYRUN:'
    printf ' %q' grok "${ARGS[@]}"
    printf '\n'
    exit 0
fi

grok "${ARGS[@]}" > "$OUT" 2>> "$LOG"
