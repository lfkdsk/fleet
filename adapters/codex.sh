#!/usr/bin/env bash
# codex channel adapter.
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

# MCP wiring via `-c` config override (TOML value, dotted key): one stdio
# server, the fleet ledger, pinned to this task.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_OVERRIDE=$(python3 - "$ROOT/bin/fleet-mcp" "${FLEET_HOME:-$HOME/.fleet}" "$TASK_ID" <<'PY'
import os, sys
cmd, home, tid = sys.argv[1], sys.argv[2], sys.argv[3]
def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
print(
    "mcp_servers.fleet={"
    f"command={q(cmd)},args=[],"
    f"env={{FLEET_HOME={q(home)},FLEET_TASK_ID={q(str(tid))},"
    f"FLEET_ATTEMPT={q(os.environ.get('FLEET_ATTEMPT', ''))}}}"
    "}"
)
PY
)

# Prompt via stdin (`exec -`): no tty inheritance, argv stays small.
# --skip-git-repo-check: a task's cwd is not always a git repo (a scratch
# dir, a worktree of a different repo), and codex refuses to run in a
# non-git directory without it.
# --dangerously-bypass-approvals-and-sandbox: codex's Linux sandbox is bubblewrap
# and needs user namespaces. Hosts that deny them fail before commands run, so
# containment comes from fleet's worktree + TMPDIR isolation instead.
ARGS=(exec - --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -c "$MCP_OVERRIDE")
if [ -n "${FLEET_MODEL:-}" ]; then
    ARGS+=(-m "$FLEET_MODEL")
fi

if [ "${FLEET_ADAPTER_DRYRUN:-}" = "1" ]; then
    # Print the command line, do not execute: tests assert on argv shape.
    printf 'DRYRUN:'
    printf ' %q' codex "${ARGS[@]}"
    printf '\n'
    exit 0
fi

codex "${ARGS[@]}" < "$PROMPT" > "$OUT" 2>> "$LOG"
