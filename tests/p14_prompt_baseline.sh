#!/usr/bin/env bash
# Compare structured prompt rendering with the pre-P14 implementation.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CURRENT="$ROOT/bin/fleet"
if [ ! -e "$ROOT/.git" ]; then
  echo "skip: no git baseline"
  exit 0
fi

BASELINE_ROOT="$(mktemp -d /var/tmp/fleet-p14-baseline-XXXX)"
OLD="$BASELINE_ROOT/bin/fleet"
HOMES=()
cleanup() {
  rm -rf "$BASELINE_ROOT"
  local h
  for h in "${HOMES[@]}"; do rm -rf "$h"; done
}
trap cleanup EXIT
mkdir -p "$BASELINE_ROOT/bin"
if ! git -C "$ROOT" show 319a2be:bin/fleet >"$OLD"; then
  echo "skip: no git baseline"
  exit 0
fi
cp "$ROOT/channels.json" "$ROOT/schema.sql" "$BASELINE_ROOT/"
cp -R "$ROOT/templates" "$BASELINE_ROOT/"
chmod +x "$OLD"

render() {
  local fleet_bin="$1" shape="$2" home title spec context_arg=()
  home="$(mktemp -d /var/tmp/fleet-p14-render-XXXX)"
  HOMES+=("$home")
  FLEET_HOME="$home" "$fleet_bin" init >/dev/null
  jq '.channels["p14-render"]={"adapter":"shell.sh","model":"gpt-4.1","models":["gpt-4.1"],"prompt_extra":"# RENDER NOTES"}' \
    "$home/channels.json" >"$home/channels.new"
  mv "$home/channels.new" "$home/channels.json"
  title="ordinary title"
  spec="ordinary spec"
  printf '%s\n' 'ordinary context' >"$home/context.txt"
  case "$shape" in
    title) title='title has {CHANNEL_NOTES} literal' ;;
    context) printf '%s\n' 'context has {CHANNEL_NOTES} literal' >"$home/context.txt" ;;
    spec) spec='spec has {CHANNEL_NOTES} literal' ;;
  esac
  printf '%s\n' "$spec" >"$home/spec.md"
  context_arg=(--context "$home/context.txt")
  FLEET_HOME="$home" "$fleet_bin" add "$title" --channel p14-render \
    --spec "$home/spec.md" "${context_arg[@]}" >/dev/null
  printf '%s\n' "$home/runs/1/prompt.md"
}

for shape in title context spec; do
  old_prompt="$(render "$OLD" "$shape")"
  new_prompt="$(render "$CURRENT" "$shape")"
  normalized_new="$new_prompt.normalized"
  sed '/^# 规格原文件：/,+1d' "$new_prompt" >"$normalized_new"
  if ! cmp -s "$old_prompt" "$normalized_new"; then
    echo "prompt differs from 319a2be for $shape literal" >&2
    diff -u "$old_prompt" "$normalized_new" >&2 || true
    exit 1
  fi
done
echo "prompt baseline matches for title/context/spec literals"
