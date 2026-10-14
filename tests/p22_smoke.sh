#!/usr/bin/env bash
# P22/B: opt-in, commit-bound external acceptance checks. No model calls.
set -eu
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/tests/p22_checks.py"
