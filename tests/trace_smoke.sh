#!/usr/bin/env bash
# fleet trace: parsers, transcript copies, wrapper hook. Isolated FLEET_HOMEs.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/trace_test.py"
