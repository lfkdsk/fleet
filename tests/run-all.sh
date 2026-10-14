#!/usr/bin/env bash
# Run every smoke suite, in parallel (default: nproc-2 jobs, capped at 8).
# The full matrix runs once with the default python3 and once with python3.14.
#
# Safe to parallelize because each suite isolates itself with its own
# mktemp FLEET_HOME, and P10 namespaced the per-task TMPDIR by FLEET_HOME
# (before that, every ledger's task 1 shared /var/tmp/fleet/1, so parallel
# runs -- and cross-ledger cleanups -- collided).
#
# Usage: tests/run-all.sh [--jobs N]
# Output is one sorted summary at the end -- per-suite lines never
# interleave; a failing suite lists its red cases. Exits non-zero if any
# suite fails. Full outputs are kept in a temp dir on failure.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="$ROOT/tests"

# A parent fleet process may leak its internal lock fd into this runner's
# environment; `fleet daemon start` would then "inherit" a stale fd and skip
# the real lock acquisition. Drop it so suites exercise the real path.
unset _FLEET_LOCK_FD

# Same class of leak, one layer up. API credentials in the launching session
# reach every suite as ordinary inherited environment, and API adapters
# prefer the environment over their rc alias by design -- so p6 case 7 and p15
# case 3 read red for the caller's shell rather than for the code. The two
# suites unset these themselves; dropping them here as well means a new suite
# that dry-runs an API adapter cannot inherit the same false red.
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS

# And the worker identity, when run-all itself runs inside a fleet task (a
# reviewer verifying a branch): FLEET_TASK_ID/FLEET_RUN_DIR/FLEET_ATTEMPT make
# every suite look like a managed worker, so dry runs may write under the
# reviewer's own attempt dir. The adapter
# stderr flag is launcher-only too: a directly invoked adapter must write its
# own diagnostic file, while a Fleet wrapper already captures stderr there.
unset FLEET_TASK_ID FLEET_RUN_DIR FLEET_ATTEMPT FLEET_SB_MCP_CMD \
      FLEET_ADAPTER_STDERR_LOGGED

jobs=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs)
      [ $# -ge 2 ] || { echo "run-all: --jobs needs a number" >&2; exit 2; }
      jobs="$2"; shift 2
      case "$jobs" in ''|*[!0-9]*) echo "run-all: --jobs needs a number" >&2; exit 2 ;; esac
      [ "$jobs" -ge 1 ] || jobs=1
      ;;
    *) echo "run-all: unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$jobs" ]; then
  jobs=$(( $(nproc) - 2 ))
  [ "$jobs" -lt 1 ] && jobs=1
  [ "$jobs" -gt 8 ] && jobs=8
fi

# Every suite is a *smoke*.sh file (smoke.sh + pN_smoke.sh); nothing else in
# tests/ matches the glob, so the list tracks new suites automatically.
mapfile -t SUITES < <(cd "$TESTS" && ls | grep 'smoke.*\.sh$' | sort)
[ "${#SUITES[@]}" -gt 0 ] || { echo "run-all: no suites found" >&2; exit 2; }

OUT=$(mktemp -d /var/tmp/fleet-runall-XXXX)
PY314_SHIM=""
if command -v python3.14 >/dev/null 2>&1; then
  PY314_SHIM="$OUT/python3.14-bin"
  mkdir -p "$PY314_SHIM"
  ln -s "$(command -v python3.14)" "$PY314_SHIM/python3"
else
  echo "run-all: python3.14 not found" >&2
  exit 2
fi

run_one() {
  local label="$1" path_prefix="$2" name="$3"
  PATH="${path_prefix:+$path_prefix:}$PATH" bash "$TESTS/$name" \
    >"$OUT/$label.$name.out" 2>&1
  echo "$?" >"$OUT/$label.$name.rc"
}

rc=0
run_batch() {
  local label="$1" path_prefix="$2" name s_rc line
  for name in "${SUITES[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do
      wait -n
    done
    run_one "$label" "$path_prefix" "$name" &
  done
  wait

  for name in "${SUITES[@]}"; do
    s_rc=$(cat "$OUT/$label.$name.rc")
    line=$(grep -E '^passed [0-9]+ / [0-9]+$' \
      "$OUT/$label.$name.out" | tail -1)
    if [ "$s_rc" = "0" ] && [ -n "$line" ]; then
      echo "$label/${name%.sh} $line"
    else
      echo "$label/${name%.sh} FAILED (rc=$s_rc)${line:+  $line}"
      # The red cases are what the reader needs first.
      grep '^not ok' "$OUT/$label.$name.out" | sed 's/^/  /'
      rc=1
    fi
  done
}

run_batch "py-default" ""
run_batch "py3.14" "$PY314_SHIM"
if [ "$rc" != "0" ]; then
  echo "full outputs kept in $OUT" >&2
else
  rm -rf "$OUT"
fi
exit "$rc"
