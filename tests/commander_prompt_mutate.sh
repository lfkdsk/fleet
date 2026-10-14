#!/usr/bin/env bash
# Teeth check for tests/commander_prompt_smoke.sh, on its own manifest.
#
# Why not tests/mutate.sh: that runner resolves suite names through its own
# suite_path() table and reads the shared tests/mutations.tsv, which other
# tasks are running batches against. This runner takes the same TSV format,
# always runs tests/commander_prompt_smoke.sh, and keeps the shared manifest
# untouched. The INERT guard is copied deliberately -- a sed that no longer
# matches leaves the binary byte-identical and the suite then runs green,
# which reads as "the tests are solid" when nothing was tested at all.
#
# Verdict per mutation:
#   HAS-TEETH  every expected case went red
#   NO-TEETH   at least one expected case stayed green
#   INERT      the sed changed nothing; suite not run
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TSV="${FLEET_MUTATIONS:-$ROOT/tests/mutations.commander_prompt.tsv}"
SUITE="tests/commander_prompt_smoke.sh"
FILTERS=("$@")

selected() {
  local name="$1" w
  [ "${#FILTERS[@]}" -eq 0 ] && return 0
  for w in "${FILTERS[@]}"; do [ "$w" = "$name" ] && return 0; done
  return 1
}

rc=0
while IFS=$'\t' read -r name target expr suite expect; do
  [ -n "${name:-}" ] || continue
  case "$name" in '#'*) continue ;; esac
  selected "$name" || continue

  COPY=$(mktemp -d /var/tmp/fleet-cpmut-XXXX)
  cp -a "$ROOT/." "$COPY/"
  rm -rf "$COPY/.git"
  SRC="$COPY/$target"
  before=$(sha256sum "$SRC" | awk '{print $1}')
  if ! sed -i "$expr" "$SRC" 2>"$COPY/sed.err"; then
    echo "$name  INERT  (sed failed: $(head -1 "$COPY/sed.err"))"; rc=1
    rm -rf "$COPY"; continue
  fi
  after=$(sha256sum "$SRC" | awk '{print $1}')
  if [ "$before" = "$after" ]; then
    echo "$name  INERT  (sed matched nothing)"; rc=1
    rm -rf "$COPY"; continue
  fi

  # Run from inside the copy with no inherited FLEET_HOME: the suite makes its
  # own isolated homes under /var/tmp, and a mutated binary must never see the
  # caller's ledger or cwd.
  OUT=$(cd "$COPY" && env -u FLEET_HOME bash "$SUITE" 2>&1)
  reds=$(printf '%s\n' "$OUT" | sed -n 's/^not ok \([0-9][0-9]*\) .*/\1/p' | paste -sd, -)
  status=HAS-TEETH
  IFS=',' read -ra want <<<"$expect"
  for c in "${want[@]}"; do
    case ",$reds," in *",$c,"*) ;; *) status=NO-TEETH ;; esac
  done
  echo "$name  $status  ${reds:-none}/$expect"
  if [ "$status" != HAS-TEETH ]; then
    printf '%s\n' "$OUT" >"$COPY/suite.out"
    echo "  (copy kept for post-mortem: $COPY)" >&2
    rc=1
  else
    rm -rf "$COPY"
  fi
done <"$TSV"
exit "$rc"
