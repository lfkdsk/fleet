#!/usr/bin/env bash
# eligible_channel is the shared "where can this run now" resolver.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/p24_resolver_test.py"
