#!/bin/bash
set -euo pipefail
REPOSITORY_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 "$REPOSITORY_ROOT/tests/parakeet-model-tests.py"
