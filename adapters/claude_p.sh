#!/usr/bin/env bash
# claude -p channel adapter.
set -u

TASK_ID="$1"
PROMPT="$2"
CWD="$3"
OUT="$4"
LOG="$5"

# Load the preflight reporter before the cwd check so even that first failure
# reaches the attempt's log.txt and out.md.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/adapters/claude_config.sh"
die() { fleet_claude_adapter_fail "$1"; exit "${2:-1}"; }

# A failed cd must not fall through: every adapter is `set -u`, not -eu, so
# without this guard the model would run in whatever directory fleet happened
# to be in and read/write the wrong tree, exit 0, and look like a clean run.
cd "$CWD" || die "claude_p adapter: cannot enter task cwd $CWD"

# Keep Fleet's one-shot transcripts out of the operator's Claude Code session
# list while retaining login and user-authored configuration.
fleet_claude_config_init || exit 1

# --- optional main/subagent split --------------------------------------
# An empty FLEET_SUBAGENT_MODEL deliberately performs no environment work:
# existing claude-p channels therefore keep their byte-for-byte behaviour.
if [ -n "${FLEET_SUBAGENT_MODEL:-}" ]; then
    export CLAUDE_CODE_SUBAGENT_MODEL="$FLEET_SUBAGENT_MODEL" \
           ANTHROPIC_DEFAULT_SONNET_MODEL="$FLEET_SUBAGENT_MODEL" \
           ANTHROPIC_DEFAULT_HAIKU_MODEL="$FLEET_SUBAGENT_MODEL"
fi

# Inline MCP config: one stdio server, the fleet ledger, pinned to this task.
# Built as a JSON string (not a file) so nothing extra lands in the workspace.
# The isolated config home deliberately does not link ~/.claude.json, whose
# project history and unrelated MCP registry belong to the interactive user.
MCPJSON=$(python3 - "$ROOT/bin/fleet-mcp" "${FLEET_HOME:-$HOME/.fleet}" "$TASK_ID" <<'PY'
import json, os, sys
print(json.dumps({"mcpServers": {"fleet": {
    "command": sys.argv[1], "args": [],
    "env": {"FLEET_HOME": sys.argv[2], "FLEET_TASK_ID": str(sys.argv[3]),
            "FLEET_ATTEMPT": os.environ.get("FLEET_ATTEMPT", "")},
}}}))
PY
)

# Prompt via stdin (`-p` reads the prompt from stdin): no tty inheritance.
ARGS=(-p --output-format text --permission-mode bypassPermissions --add-dir "$CWD" --mcp-config "$MCPJSON")
if [ -n "${FLEET_MODEL:-}" ]; then
    ARGS+=(--model "$FLEET_MODEL")
fi
# Channel-level reasoning effort (channels.json "effort"): claude -p accepts
# low|medium|high|xhigh|max. Empty means the CLI default, exactly as before.
if [ -n "${FLEET_EFFORT:-}" ]; then
    ARGS+=(--effort "$FLEET_EFFORT")
fi
# Optional named agent (channels.json "agent"): reuses ~/.claude/agents/<name>.
# It changes neither model nor family -- family follows the effective model.
if [ -n "${FLEET_AGENT:-}" ]; then
    ARGS+=(--agent "$FLEET_AGENT")
fi

if [ "${FLEET_ADAPTER_DRYRUN:-}" = "1" ]; then
    if [ -n "${FLEET_SUBAGENT_MODEL:-}" ]; then
        printf 'DRYRUN: env CLAUDE_CODE_SUBAGENT_MODEL=%s ANTHROPIC_DEFAULT_SONNET_MODEL=%s ANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n' \
            "${CLAUDE_CODE_SUBAGENT_MODEL:-}" "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" \
            "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}"
    fi
    # Print the command line, do not execute: tests assert on argv shape.
    printf 'DRYRUN:'
    printf ' %q' claude "${ARGS[@]}"
    printf '\n'
    exit 0
fi

# Feed the durable task prompt plus the adapter-owned one-shot constraint.
# A pipeline returns the status of its last command, so claude_rc remains the
# CLI's status just as it was with the former stdin redirection.
fleet_claude_one_shot_prompt "$PROMPT" \
    | claude "${ARGS[@]}" > "$OUT" 2>> "$LOG"
claude_rc=$?
if [ "$claude_rc" -eq 0 ] \
   && fleet_claude_reject_waiting_output "$OUT"; then
    # EX_TEMPFAIL: a retry may finish the work; the final attempt becomes
    # failed through Fleet's existing nonzero-adapter settlement path.
    claude_rc=75
fi

# Claude refreshes the OAuth token DURING a run, by renaming a new file over
# the managed .credentials.json -- which replaces Fleet's symlink, so the fresh
# token lands only in CLAUDE_CONFIG_DIR. Preflight already promotes it back,
# but waiting for the next Claude task can leave the operator's own session
# holding a rotated-away refresh token for hours, which is exactly the "Claude
# keeps asking me to log in" symptom. Sync once more here, at the end of the
# run that did the refreshing.
#
# In a subshell with OUT cleared: fleet_claude_adapter_fail prepends its
# diagnostic to $OUT, and $OUT is now the model's deliverable. A sync problem
# must reach the log, never the answer. Never fatal -- the task has already
# produced its result, and the user's source still holds working credentials.
# Only the shared-login mode has a credential link to sync; the token mode's
# config home deliberately has none.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "${FLEET_CLAUDE_AUTH:-}" = oauth ]; then
    (
        OUT=""
        fleet_claude_link_config_entry \
            "$HOME/.claude/.credentials.json" \
            "$CLAUDE_CONFIG_DIR/.credentials.json"
    ) >/dev/null 2>> "$LOG" || true
fi
exit "$claude_rc"
