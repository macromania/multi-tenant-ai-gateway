#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../scripts/common.sh"
section 'OFFLINE AUTOMATION TESTS'
need python3
for script in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do /bin/bash -n "$script"; done
python3 -m unittest discover -s "$ROOT/tests" -p 'test_*.py' -v
