#!/usr/bin/env bash
# Claude Code through a generic Anthropic-compatible API endpoint.
set -u

TASK_ID="$1"
PROMPT="$2"
CWD="$3"
OUT="$4"
LOG="$5"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/adapters/claude_config.sh"
die() { fleet_claude_adapter_fail "$1"; exit "${2:-1}"; }

cd "$CWD" || die "claude_api adapter: cannot enter task cwd $CWD"
fleet_claude_config_init api || exit 1

BASE_URL="${ANTHROPIC_BASE_URL:-${FLEET_API_BASE_URL:-}}"
AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-${FLEET_API_KEY:-}}"
if [ -z "$BASE_URL" ] || [ -z "$AUTH_TOKEN" ]; then
    die "claude_api adapter: ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN (or FLEET_API_BASE_URL and FLEET_API_KEY) are required" 2
fi
export ANTHROPIC_BASE_URL="$BASE_URL"
export ANTHROPIC_AUTH_TOKEN="$AUTH_TOKEN"
unset ANTHROPIC_API_KEY

M="${FLEET_MODEL:-}"
if [ -z "$M" ]; then
    die "claude_api adapter: no model (FLEET_MODEL unset)" 2
fi
S="${FLEET_SUBAGENT_MODEL:-$M}"
export ANTHROPIC_MODEL="$M" ANTHROPIC_DEFAULT_OPUS_MODEL="$M" \
       ANTHROPIC_DEFAULT_SONNET_MODEL="$S" ANTHROPIC_DEFAULT_HAIKU_MODEL="$S" \
       CLAUDE_CODE_SUBAGENT_MODEL="$S"

MCPJSON=$(python3 - "$ROOT/bin/fleet-mcp" "${FLEET_HOME:-$HOME/.fleet}" "$TASK_ID" <<'PY'
import json, os, sys
print(json.dumps({"mcpServers": {"fleet": {
    "command": sys.argv[1], "args": [],
    "env": {"FLEET_HOME": sys.argv[2], "FLEET_TASK_ID": str(sys.argv[3]),
            "FLEET_ATTEMPT": os.environ.get("FLEET_ATTEMPT", "")},
}}}))
PY
)

ARGS=(-p --output-format text --permission-mode bypassPermissions --add-dir "$CWD" --mcp-config "$MCPJSON")
if [ -n "${FLEET_AGENT:-}" ]; then
    ARGS+=(--agent "$FLEET_AGENT")
fi
if [ -n "${FLEET_EFFORT:-}" ]; then
    ARGS+=(--effort "$FLEET_EFFORT")
fi

if [ "${FLEET_ADAPTER_DRYRUN:-}" = "1" ]; then
    printf 'DRYRUN: env ANTHROPIC_BASE_URL=%s ANTHROPIC_AUTH_TOKEN=<set> ANTHROPIC_MODEL=%s CLAUDE_CODE_SUBAGENT_MODEL=%s\n' \
        "$ANTHROPIC_BASE_URL" "$ANTHROPIC_MODEL" "$CLAUDE_CODE_SUBAGENT_MODEL"
    printf 'DRYRUN:'
    printf ' %q' claude "${ARGS[@]}"
    printf '\n'
    exit 0
fi

fleet_claude_one_shot_prompt "$PROMPT" \
    | claude "${ARGS[@]}" > "$OUT" 2>> "$LOG"
claude_rc=$?
if [ "$claude_rc" -eq 0 ] \
   && fleet_claude_reject_waiting_output "$OUT"; then
    claude_rc=75
fi
exit "$claude_rc"
