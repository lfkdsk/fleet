#!/usr/bin/env bash
# Focused smoke suite using isolated FLEET_HOMEs and shell tasks.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/p25_test.py"
