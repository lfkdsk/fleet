#!/usr/bin/env bash
# C control boundary: atomic goal-attempt budget and autonomy policy generation.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/commander_control_test.py"
