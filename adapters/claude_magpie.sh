#!/usr/bin/env bash
# claude-magpie channel adapter: Claude Code as the client, every model served
# through the local Magpie gateway (usemagpie.ai, http://127.0.0.1:3425).
#
# Magpie translates Claude Code's Anthropic Messages calls to whatever the
# provider speaks, so one client drives every provider Magpie has
# (`deepseek/<model>`, `openrouter/<model>`, a self-hosted gateway, ...). The model id is the Magpie id, `provider/model`; channels.json
# `model_families` classifies it like any other model.
#
# Credentials: none here. Magpie holds the upstream keys; the gateway listens
# on localhost only. FLEET_MAGPIE_KEY may carry a Magpie gateway key (which can
# restrict a goal to some models); otherwise the local placeholder is used.

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
cd "$CWD" || die "claude_magpie adapter: cannot enter task cwd $CWD"

# This adapter uses Claude Code as its client, but its API-style environment
# token takes precedence over subscription OAuth. Give it an isolated transcript
# home with user configuration links but no .credentials.json: an API task must
# never be able to rotate the user's refresh token.
fleet_claude_config_init api || exit 1

# --- Magpie routing --------------------------------------------------------
export ANTHROPIC_BASE_URL="${FLEET_MAGPIE_URL:-http://127.0.0.1:3425}"
# Gateway key: FLEET_MAGPIE_KEY, else a per-provider key file
# (~/.config/fleet-magpie/<provider>.key, provider = the model id's prefix), else
# the local placeholder. A per-provider key lets Magpie attribute fleet's usage
# and restrict it to that provider's models (e.g. `relay/*` only).
KEY="${FLEET_MAGPIE_KEY:-}"
if [ -z "$KEY" ] && [ -n "${FLEET_MODEL:-}" ]; then
    KEYFILE="${FLEET_MAGPIE_KEY_DIR:-$HOME/.config/fleet-magpie}/${FLEET_MODEL%%/*}.key"
    [ -r "$KEYFILE" ] && KEY="$(head -n1 "$KEYFILE")"
fi
export ANTHROPIC_AUTH_TOKEN="${KEY:-magpie}"
unset ANTHROPIC_API_KEY
if [ "${FLEET_ADAPTER_DRYRUN:-}" != "1" ] \
   && ! curl -fsS -m 5 -o /dev/null "$ANTHROPIC_BASE_URL/v1/models" -H "x-api-key: $ANTHROPIC_AUTH_TOKEN"; then
    fleet_claude_adapter_fail "claude_magpie adapter: Magpie gateway not answering at $ANTHROPIC_BASE_URL (systemctl --user status magpie-web)"
    exit 2
fi
# The attribution header means nothing to a non-Anthropic upstream; turn it off.
export CLAUDE_CODE_ATTRIBUTION_HEADER=0

# Claude Code does not recognize Magpie's provider/model ids, so it assumes a 200k
# window and auto-compacts against that. Many gateway models serve 1M (Magpie
# reports each model's window via /v1/models). An
# overlong window only costs a later compaction; an undersized one silently
# truncates the context a review depends on.
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-1000000}"

# --- model split --------------------------------------------------------
# Main loop = FLEET_MODEL (the channel's effective model, which family was
# resolved from). Subagents = FLEET_SUBAGENT_MODEL when the channel sets
# `subagent_model`, else the same model.
M="${FLEET_MODEL:-}"
if [ -z "$M" ]; then
    fleet_claude_adapter_fail \
        "claude_magpie adapter: no model (FLEET_MODEL unset)"
    exit 2
fi
S="${FLEET_SUBAGENT_MODEL:-$M}"
export ANTHROPIC_MODEL="$M" ANTHROPIC_DEFAULT_OPUS_MODEL="$M" \
       ANTHROPIC_DEFAULT_SONNET_MODEL="$S" ANTHROPIC_DEFAULT_HAIKU_MODEL="$S" \
       CLAUDE_CODE_SUBAGENT_MODEL="$S"

# --- claude argv (unchanged from the wrapper era) -----------------------
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
# No --model: the model is pinned through the environment above, and passing
# an API-side id to claude as well only gives the two a chance to disagree.
ARGS=(-p --output-format text --permission-mode bypassPermissions --add-dir "$CWD" --mcp-config "$MCPJSON")
# Optional named agent (channels.json "agent"): reuses ~/.claude/agents/<name>.
# It changes neither model nor family -- family follows the effective model.
if [ -n "${FLEET_AGENT:-}" ]; then
    ARGS+=(--agent "$FLEET_AGENT")
fi

# Channel-level reasoning effort (channels.json "effort"): claude -p accepts
# low|medium|high|xhigh|max. Empty means the CLI default, exactly as before.
if [ -n "${FLEET_EFFORT:-}" ]; then
    ARGS+=(--effort "$FLEET_EFFORT")
fi

if [ "${FLEET_ADAPTER_DRYRUN:-}" = "1" ]; then
    # Print the environment this adapter owns and the command line; never the
    # token. Tests assert on the model split and on the token staying out.
    printf 'DRYRUN: env ANTHROPIC_BASE_URL=%s ANTHROPIC_AUTH_TOKEN=<set> ANTHROPIC_MODEL=%s CLAUDE_CODE_SUBAGENT_MODEL=%s CLAUDE_CODE_MAX_CONTEXT_TOKENS=%s\n' \
        "$ANTHROPIC_BASE_URL" "$ANTHROPIC_MODEL" "$CLAUDE_CODE_SUBAGENT_MODEL" "$CLAUDE_CODE_MAX_CONTEXT_TOKENS"
    printf 'DRYRUN:'
    printf ' %q' claude "${ARGS[@]}"
    printf '\n'
    exit 0
fi

# This is still Claude Code in `-p` mode, so it has the same one-shot prompt
# and postflight completeness guard as the direct subscription adapter.
fleet_claude_one_shot_prompt "$PROMPT" \
    | claude "${ARGS[@]}" > "$OUT" 2>> "$LOG"
claude_rc=$?
if [ "$claude_rc" -eq 0 ] \
   && fleet_claude_reject_waiting_output "$OUT"; then
    claude_rc=75
fi
exit "$claude_rc"
