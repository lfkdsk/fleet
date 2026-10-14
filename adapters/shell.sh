#!/usr/bin/env bash
# shell channel adapter (test only, family=none): the prompt file is executed
# as a shell script. Never wire this to a model-backed channel.
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

# stdin from /dev/null: no child may ever inherit a tty.
bash "$PROMPT" > "$OUT" 2>>"$LOG" < /dev/null
