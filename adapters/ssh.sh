#!/usr/bin/env bash
# ssh channel adapter: the remote host is only an executor. The prompt is
# streamed over stdin (never argv, never remote disk), remote stdout lands in
# the local OUT file and stderr in LOG, and the ssh exit code is passed
# through so an unreachable host walks the normal failed/retry path.
# The ledger stays on the local machine -- this adapter never touches it.
set -u

TASK_ID="$1"
PROMPT="$2"
CWD="$3"
OUT="$4"
LOG="$5"

HOST="${FLEET_SSH_HOST:-}"
REMOTE_CMD="${FLEET_REMOTE_CMD:-bash}"
if [ -z "$HOST" ]; then
    echo "ssh adapter: FLEET_SSH_HOST is empty (set ssh_host in channels.json)" >&2
    exit 2
fi

# Single-quote for the remote /bin/sh -c: quoted content cannot expand
# variables, substitute, or glob.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# FLEET_MODEL is exported into the remote env: a model-declaring ssh channel
# must reference it in remote_cmd (enforced at enqueue, P11 A2), so the model
# the family was resolved from is the model the remote agent actually runs.
REMOTE_LINE="$REMOTE_CMD"
if [ -n "${FLEET_MODEL:-}" ]; then
    REMOTE_LINE="FLEET_MODEL=$(sq "$FLEET_MODEL") $REMOTE_CMD"
fi

# One argv array for both paths: the dryrun renders the real command line,
# never a hand-written copy of it (two copies drifted three times).
ARGS=(ssh -o BatchMode=yes "$HOST" "$REMOTE_LINE")

# BatchMode=yes is mandatory: without it a headless run hangs forever on an
# interactive password prompt. The prompt feeds stdin via the redirect below,
# which also keeps the local tty from being inherited. `-n` would detach
# stdin entirely and cannot be used here -- the prompt IS the stdin stream.
if [ "${FLEET_ADAPTER_DRYRUN:-}" = "1" ]; then
    # Print the command line, do not execute. The prompt content never
    # appears here: it travels via stdin, not argv.
    printf 'DRYRUN:'
    printf ' %q' "${ARGS[@]}"
    printf '\n'
    exit 0
fi

"${ARGS[@]}" < "$PROMPT" > "$OUT" 2>> "$LOG"
