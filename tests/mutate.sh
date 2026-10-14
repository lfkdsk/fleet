#!/usr/bin/env bash
# Fleet mutation runner with --check-only and parallel-job support.
#
# Manifest: tests/mutations.tsv, one mutation per line:
#   name<TAB>target<TAB>sed-expr<TAB>suite<TAB>expected-red-cases
# (Override the manifest path with FLEET_MUTATIONS; name args filter the run.)
#
# The inert guard is the whole reason this script exists. A sed that matches
# nothing leaves the target byte-identical; the suite then runs green and the
# green result reads as "the tests are solid" when in fact nothing was tested.
# An unchanged sha256 is therefore reported INERT and fails the run; the suite
# is never judged.
#
# --check-only runs just the sed/sha half: it answers "does every mutation
# still match the current code?" in seconds instead of the ~27-min full run.
# A refactor that quietly breaks a sed turns that mutation into a dead entry
# guarding nothing; this mode makes the rot visible in CI.
#
# --jobs N runs mutations in parallel (each already gets its own repo copy).
# Results are reported in manifest order, so output never interleaves.
#
# The batch must leave the CALLER's workspace exactly as it found it. A suite
# inherits this script's cwd, and a mutated binary can write relative paths
# (note-writes-file plants findings.md in whatever cwd the suite sees): the
# residue once landed in a reviewed worktree and was misread as fixture
# garbage. So every suite runs from inside its own temp copy with a clean
# FLEET_HOME, and the caller's `git status --porcelain` is snapshotted before
# and compared after -- any addition fails the run.
#
# Verdict per mutation (full run):
#   HAS-TEETH  every expected case went red (extra reds are shown, not fatal)
#   NO-TEETH   at least one expected case stayed green
#   INERT      the sed changed nothing (or failed); suite not run
# Verdict per mutation (--check-only):
#   APPLIES    the sed changed the target's sha256
#   INERT      target missing, sed failed, or sha unchanged
# Exit non-zero if any mutation is not HAS-TEETH / APPLIES.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TSV="${FLEET_MUTATIONS:-$ROOT/tests/mutations.tsv}"

# Snapshot the caller's workspace before anything runs. Suites execute inside
# their own temp copies, but a mutated binary writing a relative path would
# still land in the caller's checkout if the suite's cwd pointed there -- the
# batch asserts no additions at the end.
CALLER_DIR="$PWD"
caller_porcelain() {
  git -C "$CALLER_DIR" status --porcelain 2>/dev/null || true
}
PORCELAIN_BEFORE="$(caller_porcelain)"

JOBS=1
CHECK_ONLY=0
FILTERS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs)
      [ $# -ge 2 ] || { echo "mutate: --jobs needs a number" >&2; exit 2; }
      JOBS="$2"; shift 2
      case "$JOBS" in ''|*[!0-9]*) echo "mutate: --jobs needs a number" >&2; exit 2 ;; esac
      [ "$JOBS" -ge 1 ] || JOBS=1
      ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --) shift; FILTERS+=("$@"); break ;;
    *) FILTERS+=("$1"); shift ;;
  esac
done

suite_path() {
  case "$1" in
    smoke)  echo "tests/smoke.sh" ;;
    mcp)    echo "tests/mcp_smoke.sh" ;;
    ctx)    echo "tests/ctx_smoke.sh" ;;
    daemon) echo "tests/daemon_smoke.sh" ;;
    control) echo "tests/commander_control_smoke.sh" ;;
    p4)     echo "tests/p4_smoke.sh" ;;
    p5)     echo "tests/p5_smoke.sh" ;;
    p6)     echo "tests/p6_smoke.sh" ;;
    p7)     echo "tests/p7_smoke.sh" ;;
    p8)     echo "tests/p8_smoke.sh" ;;
    p10)    echo "tests/p10_smoke.sh" ;;
    p12)    echo "tests/p12_smoke.sh" ;;
    p13)    echo "tests/p13_smoke.sh" ;;
    p14)    echo "tests/p14_smoke.sh" ;;
    p15)    echo "tests/p15_smoke.sh" ;;
    p16)    echo "tests/p16_smoke.sh" ;;
    p18)    echo "tests/p18_smoke.sh" ;;
    p17)    echo "tests/p17_smoke.sh" ;;
    p19)    echo "tests/p19_smoke.sh" ;;
    p20)    echo "tests/p20_smoke.sh" ;;
    p22)    echo "tests/p22_smoke.sh" ;;
    p21)    echo "tests/p21_smoke.sh" ;;
    p24resolver) echo "tests/p24_resolver_smoke.sh" ;;
    detached_child) echo "tests/detached_child_smoke.sh" ;;
    claude_early_exit) echo "tests/claude_p_early_exit_smoke.sh" ;;
    exec)   echo "tests/commander_execution_smoke.sh" ;;
    p9)     echo "tests/p9_smoke.sh" ;;
    p11)    echo "tests/p11_smoke.sh" ;;
    contrib) echo "tests/contrib_smoke.sh" ;;
    # Named so `--check-only` over the commander manifest reports APPLIES
    # rather than "unknown suite" INERT. The real teeth run stays in
    # tests/commander_prompt_mutate.sh, which keeps the shared manifest --
    # and the batches other tasks run against it -- untouched.
    commander_prompt) echo "tests/commander_prompt_smoke.sh" ;;
    *) echo "" ;;
  esac
}

selected() {
  local name="$1" w
  [ "${#FILTERS[@]}" -eq 0 ] && return 0
  for w in "${FILTERS[@]}"; do [ "$w" = "$name" ] && return 0; done
  return 1
}

WORK=$(mktemp -d /var/tmp/fleet-mutate-XXXX)
trap 'rm -rf "$WORK"' EXIT

# Writes $WORK/<name>.res: "<status>\t<reds>\t<expect>\t<copy_or_->"
# and optionally $WORK/<name>.note with a detail suffix.
run_one() {
  local name="$1" target="$2" expr="$3" suite="$4" expect="$5"
  local res="$WORK/$name.res"

  if [ "$CHECK_ONLY" = "1" ]; then
    # The sed/sha half only, against a throwaway copy of the target file:
    # does the mutation still match the current code at all?
    local SRC="$WORK/$name.src"
    if [ ! -f "$ROOT/$target" ]; then
      printf 'INERT\t-\t%s\t-\n' "$expect" >"$res"
      echo "target missing: $target" >"$WORK/$name.note"
      return
    fi
    cp "$ROOT/$target" "$SRC"
    local before after
    before=$(sha256sum "$SRC" | awk '{print $1}')
    if ! sed -i "$expr" "$SRC" 2>"$WORK/$name.err"; then
      printf 'INERT\t-\t%s\t-\n' "$expect" >"$res"
      echo "sed failed: $(head -1 "$WORK/$name.err")" >"$WORK/$name.note"
      return
    fi
    after=$(sha256sum "$SRC" | awk '{print $1}')
    if [ "$before" = "$after" ]; then
      printf 'INERT\t-\t%s\t-\n' "$expect" >"$res"
    else
      printf 'APPLIES\t-\t%s\t-\n' "$expect" >"$res"
    fi
    return
  fi

  local COPY
  COPY=$(mktemp -d /var/tmp/fleet-mut-XXXX)
  # Copy the repo without .git: the suites derive ROOT from their own path,
  # so the mutated copy is what gets exercised.
  cp -a "$ROOT/." "$COPY/"
  rm -rf "$COPY/.git"

  local SRC="$COPY/$target"
  if [ ! -f "$SRC" ]; then
    printf 'INERT\t-\t%s\t-\n' "$expect" >"$res"
    echo "target missing: $target" >"$WORK/$name.note"
    rm -rf "$COPY"
    return
  fi

  local before after
  before=$(sha256sum "$SRC" | awk '{print $1}')
  if ! sed -i "$expr" "$SRC" 2>"$COPY/sed.err"; then
    printf 'INERT\t-\t%s\t-\n' "$expect" >"$res"
    echo "sed failed: $(head -1 "$COPY/sed.err")" >"$WORK/$name.note"
    rm -rf "$COPY"
    return
  fi
  after=$(sha256sum "$SRC" | awk '{print $1}')
  if [ "$before" = "$after" ]; then
    # The mutation changed nothing. Judging the suite now would judge noise.
    printf 'INERT\t-\t%s\t-\n' "$expect" >"$res"
    rm -rf "$COPY"
    return
  fi

  local SUITE
  SUITE=$(suite_path "$suite")
  if [ -z "$SUITE" ] || [ ! -f "$COPY/$SUITE" ]; then
    printf 'INERT\t-\t%s\t-\n' "$expect" >"$res"
    echo "unknown suite: $suite" >"$WORK/$name.note"
    rm -rf "$COPY"
    return
  fi

  local OUT reds status
  # Run from inside the copy with a clean FLEET_HOME: the suite's cwd and
  # ledger must never be the caller's repo -- a mutated binary writing a
  # relative path (see note-writes-file) would otherwise plant files in the
  # reviewed worktree. Suites derive ROOT from their own path and set their
  # own FLEET_HOME, so neither is inherited here.
  OUT=$(cd "$COPY" && env -u FLEET_HOME bash "$SUITE" 2>&1)
  reds=$(printf '%s\n' "$OUT" | sed -n 's/^not ok \([0-9][0-9]*\) .*/\1/p' | paste -sd, -)

  status=HAS-TEETH
  local IFS=','
  local c
  for c in $expect; do
    case ",$reds," in *",$c,"*) ;; *) status=NO-TEETH ;; esac
  done
  if [ "$status" != "HAS-TEETH" ]; then
    # Keep the mutated copy for post-mortem; the suite output is inside it.
    printf '%s\n' "$OUT" > "$COPY/suite.out"
    printf '%s\t%s\t%s\t%s\n' "$status" "${reds:-none}" "$expect" "$COPY" >"$res"
    return
  fi
  printf '%s\t%s\t%s\t-\n' "$status" "${reds:-none}" "$expect" >"$res"
  # A mutation can disable a guard that normally keeps model-backed tasks
  # from launching (e.g. no-cross-family lets review tasks enqueue, and the
  # suite's own `run --ready` starts them for real). Kill anything still
  # executing out of this copy before removing it: a mutation runner must
  # not leave real agents running behind it.
  pkill -TERM -f "$COPY" 2>/dev/null || true
  sleep 0.5
  pkill -KILL -f "$COPY" 2>/dev/null || true
  rm -rf "$COPY"
}

while IFS=$'\t' read -r name target expr suite expect; do
  [ -n "${name:-}" ] || continue
  case "$name" in '#'*) continue ;; esac
  selected "$name" || continue
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do
    wait -n
  done
  run_one "$name" "$target" "$expr" "$suite" "$expect" &
done < "$TSV"
wait

rc=0
while IFS=$'\t' read -r name target expr suite expect; do
  [ -n "${name:-}" ] || continue
  case "$name" in '#'*) continue ;; esac
  selected "$name" || continue
  res="$WORK/$name.res"
  [ -f "$res" ] || continue
  IFS=$'\t' read -r status reds exp copy <"$res"
  note=""
  [ -f "$WORK/$name.note" ] && note=" ($(cat "$WORK/$name.note"))"
  if [ "$CHECK_ONLY" = "1" ]; then
    echo "$name  $status  $exp$note"
    [ "$status" = "APPLIES" ] || rc=1
  else
    if [ "$copy" != "-" ]; then
      echo "$name  $status  $reds/$exp  (copy kept: $copy)" >&2
    fi
    echo "$name  $status  $reds/$exp"
    [ "$status" = "HAS-TEETH" ] || rc=1
  fi
done < "$TSV"

# The batch must leave the caller's workspace exactly as it found it: a
# mutated suite that writes a relative path (note-writes-file) used to plant
# files in the reviewed worktree. Only additions are flagged -- pre-existing
# dirt in the caller's tree is not ours to judge.
PORCELAIN_AFTER="$(caller_porcelain)"
if [ "$PORCELAIN_AFTER" != "$PORCELAIN_BEFORE" ]; then
  echo "mutate: caller workspace gained changes during the batch:" >&2
  comm -13 <(printf '%s\n' "$PORCELAIN_BEFORE" | sort) \
           <(printf '%s\n' "$PORCELAIN_AFTER" | sort) | sed 's/^/  /' >&2
  rc=1
fi
exit "$rc"
