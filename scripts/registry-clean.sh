#!/usr/bin/env bash
# Harbor data deletion is intentionally not automated.
set -euo pipefail
echo "[ERROR] Refusing to purge Harbor data automatically." >&2
echo "Create and restore-test a backup before manually deleting Harbor data." >&2
exit 2
