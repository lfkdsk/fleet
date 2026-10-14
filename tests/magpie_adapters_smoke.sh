#!/usr/bin/env bash
# Dry-run checks for the public Magpie adapter (no gateway, no model calls):
# claude_magpie.sh points Claude Code at the gateway, pins the model, and never
# prints the key.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo hi > "$T/p.md"
N=0; PASS=0; FAIL=0
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }
run(){ FLEET_ADAPTER_DRYRUN=1 FLEET_HOME="$T/fleet" "$@" 1 "$T/p.md" "$T" "$T/o.md" "$T/l.log" 2>&1; }

cc=$(FLEET_MODEL=openrouter/gpt-5.6-sol FLEET_MAGPIE_KEY=secret-key-value run bash "$ROOT/adapters/claude_magpie.sh")
case "$cc" in *ANTHROPIC_BASE_URL=http://127.0.0.1:3425*) ok "claude_magpie targets the gateway";; *) no "claude_magpie base url wrong: $cc";; esac
case "$cc" in *ANTHROPIC_MODEL=openrouter/gpt-5.6-sol*) ok "claude_magpie pins the model";; *) no "claude_magpie model wrong";; esac
case "$cc" in *secret-key-value*) no "claude_magpie printed the gateway key";; *) ok "claude_magpie never prints the key";; esac

echo "passed $PASS / $N"
[ "$FAIL" = "0" ] || exit 1
