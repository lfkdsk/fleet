#!/usr/bin/env bash
# cursor-agent channel adapter.
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

# The prompt goes via stdin, never argv: cursor-agent reads the prompt from
# stdin when no positional prompt is given (verified empirically on
# 2026.08.25: a piped question was answered correctly), so argv stays small
# no matter the prompt size. The old `-p "$(cat "$PROMPT")"` form put the
# whole prompt in argv and died with E2BIG past ~128 KiB (MAX_ARG_STRLEN) --
# and because the shell opens `> "$OUT"` before exec, out.md was truncated to
# empty first, so the failure looked like "success with no output". A
# side benefit of stdin: the prompt text no longer sits in the process table,
# so substring-based self-detection (e.g. `pgrep -f <pattern>`) cannot match
# the agent's own argv. -f --trust is mandatory: without it headless mode
# stalls on the tool-approval prompt forever.
ARGS=(-p --output-format text -f --trust --workspace "$CWD")
if [ -n "${FLEET_MODEL:-}" ]; then
    ARGS+=(--model "$FLEET_MODEL")
fi

# MCP: cursor-agent has no --mcp-config flag, and of the three places it
# reads servers from, two are shared state this adapter must not touch. The
# workspace file <cwd>/.cursor/mcp.json was the old choice (P7) and is what
# this replaces: an untracked .cursor/ makes the task's worktree permanently
# dirty, and `fleet worktree prune --merged-only` reads a dirty worktree as
# unmerged, so every cursor task's worktree became unreclaimable -- and a
# reviewer pointed at the *reviewed* task's worktree with --cwd wrote its
# residue into someone else's diff. ~/.cursor/mcp.json is worse: one file
# shared by the operator and every concurrent task, so its FLEET_TASK_ID
# would be whichever task wrote last, and claims would land on the wrong row.
#
# The third source is a local plugin: `--plugin-dir <dir>` loads
# <dir>/.cursor-plugin/plugin.json plus the plugin's own .mcp.json from
# anywhere on disk, per invocation. Fleet supplies the current attempt's run
# dir ($FLEET_HOME/runs/<id>/attempt-<n>/), so retries and concurrent tasks
# each read their own FLEET_TASK_ID/FLEET_ATTEMPT and no cwd is written to.
# Direct adapter invocations without FLEET_RUN_DIR retain the old task-level
# fallback for compatibility. That
# also retires the "no --worktree means no MCP" degradation: the config no
# longer needs a fleet-managed worktree to live in, so every cursor task gets
# a ledger, wherever its cwd points.
if [ -n "${FLEET_MCP_JSON:-}" ]; then
    PLUGIN_DIR="${FLEET_RUN_DIR:-${FLEET_HOME:-$HOME/.fleet}/runs/$TASK_ID}/cursor-plugin"
    # Still one way to lose MCP: the run dir is unwritable. Say so loudly
    # rather than launch a mute agent -- an agent that silently cannot file a
    # claim is exactly how a fake-successful task gets through.
    if mkdir -p "$PLUGIN_DIR/.cursor-plugin" 2>/dev/null \
       && printf '%s\n' '{"name": "fleet", "version": "0.1.0"}' \
            > "$PLUGIN_DIR/.cursor-plugin/plugin.json" 2>/dev/null \
       && printf '%s\n' "$FLEET_MCP_JSON" > "$PLUGIN_DIR/.mcp.json" 2>/dev/null; then
        ARGS+=(--plugin-dir "$PLUGIN_DIR" --approve-mcps)
    else
        echo "warning: cursor task $TASK_ID could not write $PLUGIN_DIR: no MCP configured, the agent cannot file claims" >&2
    fi
fi

if [ "${FLEET_ADAPTER_DRYRUN:-}" = "1" ]; then
    # Print the command line, do not execute: tests assert on argv shape.
    printf 'DRYRUN:'
    printf ' %q' cursor-agent "${ARGS[@]}"
    printf '\n'
    exit 0
fi

cursor-agent "${ARGS[@]}" < "$PROMPT" > "$OUT" 2>> "$LOG"
