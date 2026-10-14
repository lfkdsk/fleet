#!/usr/bin/env bash
# switchboard channel adapter: the remote machine is only an executor; the
# ledger stays on the local machine. Detached jobs do not inherit stdin
# (switchboard closes it: cli/peer.js `!opts.detach`), so the prompt is
# copied to the remote first and fed to the remote command there. The remote
# job's exit code is the adapter's exit code, so an offline or unreachable
# node walks the normal failed/retry path instead of silently succeeding.
#
# The MCP callback (FLEET_SB_MCP_CMD, built by bin/fleet) and the model
# (FLEET_MODEL) are exported into the remote job's environment; the channel's
# remote_cmd wires them into its agent CLI however that CLI expects. The
# default remote_cmd `cat` ignores them (test channel). A model-declaring
# channel whose remote_cmd ignores FLEET_MODEL is refused at enqueue
# (P11 A2): the declared model and its family would be fiction.
set -u

TASK_ID="$1"
PROMPT="$2"
CWD="$3"
OUT="$4"
LOG="$5"

NODE="${FLEET_SB_NODE:-}"
REMOTE_CMD="${FLEET_SB_REMOTE_CMD:-cat}"
MCP_CMD="${FLEET_SB_MCP_CMD:-}"
ATTEMPT_ID="${FLEET_ATTEMPT:-}"

if [ -z "$NODE" ]; then
    echo "switchboard adapter: FLEET_SB_NODE is empty (set node in channels.json)" >&2
    exit 2
fi
case "$ATTEMPT_ID" in
    ""|*[!A-Za-z0-9._-]*)
        echo "switchboard adapter: FLEET_ATTEMPT is missing or unsafe" >&2
        exit 2
        ;;
esac

# Remote scratch files are attempt-namespaced: a replacement attempt may run
# while its predecessor is still alive, so task id alone is not isolation.
RPROMPT="/tmp/fleet-task-$TASK_ID-attempt-$ATTEMPT_ID-prompt.md"
ROUT="/tmp/fleet-task-$TASK_ID-attempt-$ATTEMPT_ID-out.md"

# Single-quote for the remote /bin/sh -c: quoted content cannot expand
# variables, substitute, or glob.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# The remote command is shell text from the channel registry. The env prefix
# puts the callback and the model where remote_cmd can reference them as
# $FLEET_SB_MCP_CMD / $FLEET_MODEL.
MODEL_PREFIX=""
if [ -n "${FLEET_MODEL:-}" ]; then
    MODEL_PREFIX="FLEET_MODEL=$(sq "$FLEET_MODEL") "
fi
REMOTE="${MODEL_PREFIX}FLEET_SB_MCP_CMD=$(sq "$MCP_CMD") $REMOTE_CMD < $RPROMPT > $ROUT"

# Single source for the command lines: these arrays are what actually runs;
# the dryrun renders them, never a hand-written copy (two copies drifted
# three times). $JOB is a runtime value, so the logs/wait lines render it as
# a literal -- their stable prefixes are shared arrays.
CP_IN=(switchboard cp "$PROMPT" "$NODE:$RPROMPT")
EXEC=(switchboard exec "$NODE" --detach --cwd "$CWD" "$REMOTE")
LOGS=(switchboard logs "$NODE")
WAIT=(switchboard wait "$NODE")
CP_OUT=(switchboard cp "$NODE:$ROUT" "$OUT")

if [ "${FLEET_ADAPTER_DRYRUN:-}" = "1" ]; then
    # Print the command lines, do not execute. The prompt content never
    # appears here: it travels as a file (cp), never as argv.
    printf 'DRYRUN:'; printf ' %q' "${CP_IN[@]}"; printf '\n'
    printf 'DRYRUN:'; printf ' %q' "${EXEC[@]}"; printf '\n'
    printf 'DRYRUN:'; printf ' %q' "${LOGS[@]}"; printf ' %q' '$JOB'; printf ' %q' --follow; printf '\n'
    printf 'DRYRUN:'; printf ' %q' "${WAIT[@]}"; printf ' %q' '$JOB'; printf '\n'
    printf 'DRYRUN:'; printf ' %q' "${CP_OUT[@]}"; printf '\n'
    exit 0
fi

# 1. Prompt across. Detached jobs have no stdin, so piping is impossible;
#    the file is the only channel.
if ! "${CP_IN[@]}" 2>>"$LOG"; then
    echo "switchboard adapter: failed to copy prompt to $NODE:$RPROMPT" >&2
    exit 1
fi

# 2. Detach the remote job. `exec --detach` prints the job id on stdout and
#    exits 0; anything else means the node could not take the job.
JOB=$("${EXEC[@]}" 2>>"$LOG")
rc=$?
if [ "$rc" != "0" ] || [ -z "$JOB" ]; then
    echo "switchboard adapter: failed to start job on $NODE (rc=$rc)" >&2
    exit 1
fi

# 3. Stream the job log into LOG in the background. `logs --follow` exits on
#    its own once the job is no longer running (peer.js cmdLogs loop), so the
#    trap kill is belt-and-braces, not the normal path. The remote command
#    redirects its stdout to ROUT, so what lands here is remote stderr.
( "${LOGS[@]}" "$JOB" --follow >> "$LOG" 2>&1 ) &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT

# 4. Wait: `switchboard wait` exits with the remote job's exit code
#    (peer.js cmdWait), so pass it straight through.
"${WAIT[@]}" "$JOB" 2>>"$LOG"
rc=$?

# 5. Fetch the remote stdout as the task output. A failed fetch is a failed
#    task even when the job itself exited 0: without the output the task
#    cannot be reviewed.
if ! "${CP_OUT[@]}" 2>>"$LOG"; then
    echo "switchboard adapter: failed to fetch $NODE:$ROUT" >&2
    exit 1
fi

# Best-effort scratch cleanup on the remote; never changes the verdict.
switchboard exec "$NODE" "rm -f $RPROMPT $ROUT" >/dev/null 2>&1 || true

exit "$rc"
